#!/usr/bin/env bash
# DSF Hub onboarding: GCP Cloud SQL for PostgreSQL via Pub/Sub
# Follows: Thales DSF Hub Reference Guide — GCP Data Sources (Jun 2026)
# Pipeline: Cloud SQL → Cloud Logging → Pub/Sub → DSF Agentless Gateway

set -e
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# ── Instance configuration ────────────────────────────────────────────────────
INSTANCE_NAME="${CLOUDSQL_INSTANCE_NAME:-mypostgres${ENV_SUFFIX:-}-dsf}"
DB_VERSION="POSTGRES_16"
TOPIC_NAME="${INSTANCE_NAME}-audit-topic"
SUB_NAME="${INSTANCE_NAME}-dsf-sub"
SA_EMAIL="${SERVICE_ACCOUNT_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
CONTAINER_NAME="floci-cloudsql-${GCP_PROJECT_ID}-${INSTANCE_NAME}"

step()  { echo; echo "=== $* ==="; }
info()  { echo "    $*"; }
gcp()   { gcurl -s --fail-with-body -H "Content-Type: application/json" "$@"; }
gcp_get() { gcurl -s --fail-with-body "${GCP_ENDPOINT_URL}$1"; }

# Run psql inside the container as the bootstrap postgres user (floci-gcp default)
db_psql() { docker exec -e PGPASSWORD=postgres "${CONTAINER_NAME}" psql -U postgres -d postgres "$@"; }

wait_runnable() {
    local name="$1" state tries=0
    info "Waiting for container '${CONTAINER_NAME}' and instance to become RUNNABLE..."
    while [ "$tries" -lt 40 ]; do
        state=$(gcp_get "/sql/v1beta4/projects/${GCP_PROJECT_ID}/instances/${name}" \
                | command grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "PENDING")
        if [ "$state" = "RUNNABLE" ]; then
            # Use bootstrap postgres/postgres for liveness — admin user is created in STEP 2
            if docker exec "${CONTAINER_NAME}" sh -c "PGPASSWORD=postgres psql -U postgres -c 'SELECT 1' >/dev/null 2>&1"; then
                return 0
            fi
        fi
        tries=$((tries + 1)); sleep 3
    done
    echo "ERROR: instance '$name' did not become RUNNABLE (state: $state)" >&2; exit 1
}

# ── STEP 1: Create Cloud SQL PostgreSQL instance ──────────────────────────────
step "STEP 1: Creating Cloud SQL PostgreSQL instance '${INSTANCE_NAME}'"

existing=$(gcp_get "/sql/v1beta4/projects/${GCP_PROJECT_ID}/instances/${INSTANCE_NAME}" 2>/dev/null \
           | command grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

if [ -n "$existing" ] && [ "$existing" != "SUSPENDED" ]; then
    info "Instance already exists (state: $existing) — skipping creation."
else
    gcp -X POST "${GCP_ENDPOINT_URL}/sql/v1beta4/projects/${GCP_PROJECT_ID}/instances" \
        -d '{
          "name": "'"${INSTANCE_NAME}"'",
          "databaseVersion": "'"${DB_VERSION}"'",
          "region": "'"${GCP_REGION}"'",
          "rootPassword": "'"${DB_MASTER_PASS}"'",
          "settings": {
            "tier": "db-custom-1-3840",
            "databaseFlags": [
              {"name": "log_connections",    "value": "on"},
              {"name": "log_disconnections", "value": "on"},
              {"name": "log_statement",      "value": "all"},
              {"name": "log_duration",       "value": "on"}
            ],
            "backupConfiguration": {"enabled": false}
          }
        }' > /dev/null
    info "Instance creation requested."
fi

wait_runnable "$INSTANCE_NAME"

RESP=$(gcp_get "/sql/v1beta4/projects/${GCP_PROJECT_ID}/instances/${INSTANCE_NAME}")
DB_IP=$(echo "$RESP" | command grep -o '"ipAddress":"[^"]*"' | head -1 | cut -d'"' -f4)
DB_PORT=5432
info "Instance is RUNNABLE — container: ${CONTAINER_NAME}, internal IP: ${DB_IP}:${DB_PORT}"

# ── STEP 1b: Start host-accessible socat proxy ────────────────────────────────
step "STEP 1b: Starting host port proxy for DBeaver / external clients"

# Pick next free port in the slot range (CLOUDSQL_PROXY_BASE_PORT from .env)
PROXY_BASE="${CLOUDSQL_PROXY_BASE_PORT:-15432}"
PROXY_MAX="${CLOUDSQL_PROXY_MAX_PORT:-15499}"
PROXY_PORT=""
PROXY_CONTAINER="cloudsql-proxy-${INSTANCE_NAME}"
NETWORK="${FLOCI_GCP_NETWORK:-floci-gcp1_default}"

# Remove any stale proxy for this instance
docker rm -f "${PROXY_CONTAINER}" 2>/dev/null || true

# Find a free port in the range
for p in $(seq "$PROXY_BASE" "$PROXY_MAX"); do
    if ! docker ps --format "{{.Ports}}" | grep -q ":${p}->"; then
        PROXY_PORT=$p
        break
    fi
done

if [ -z "$PROXY_PORT" ]; then
    info "WARNING: no free proxy port found in ${PROXY_BASE}-${PROXY_MAX}, skipping proxy."
else
    docker run -d --rm \
        --name "${PROXY_CONTAINER}" \
        --network "${NETWORK}" \
        -p "${PROXY_PORT}:${PROXY_PORT}" \
        alpine/socat \
        TCP-LISTEN:${PROXY_PORT},fork,reuseaddr "TCP:${DB_IP}:${DB_PORT}" >/dev/null
    info "Proxy started: localhost:${PROXY_PORT} → ${DB_IP}:${DB_PORT}"
    info "DBeaver: host=localhost  port=${PROXY_PORT}  user=${DB_MASTER_USER}  pass=${DB_MASTER_PASS}"
fi

# ── STEP 2: Configure auth, create admin user, enable audit logging ───────────
step "STEP 2: Creating admin user '${DB_MASTER_USER}' and enabling audit logging"

# floci-gcp forces POSTGRES_PASSWORD=postgres; patch pg_hba to allow md5 over Docker network
docker exec "${CONTAINER_NAME}" sh -c "
  grep -q '172.16.0.0/12' /var/lib/postgresql/data/pg_hba.conf || \
  sed -i 's|^host all all all scram-sha-256|host all all 172.16.0.0/12 md5\nhost all all all scram-sha-256|' \
    /var/lib/postgresql/data/pg_hba.conf
" 2>/dev/null || true
db_psql -c "SELECT pg_reload_conf();" > /dev/null

# Create admin user matching the AWS RDS convention (admin / secret123)
db_psql -c "DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_MASTER_USER}') THEN
        CREATE USER ${DB_MASTER_USER} WITH SUPERUSER PASSWORD '${DB_MASTER_PASS}';
        RAISE NOTICE 'User ${DB_MASTER_USER} created.';
      ELSE
        ALTER USER ${DB_MASTER_USER} WITH SUPERUSER PASSWORD '${DB_MASTER_PASS}';
        RAISE NOTICE 'User ${DB_MASTER_USER} updated.';
      END IF;
    END
    \$\$;"
info "User '${DB_MASTER_USER}' ready with password '${DB_MASTER_PASS}'."

db_psql -c "ALTER SYSTEM SET log_statement = 'all';" \
        -c "ALTER SYSTEM SET log_connections = 'on';" \
        -c "ALTER SYSTEM SET log_disconnections = 'on';" \
        -c "ALTER SYSTEM SET log_duration = 'on';" \
        -c "SELECT pg_reload_conf();"
info "Audit logging enabled. Queries will appear in docker logs for ${CONTAINER_NAME}."

# ── STEP 3: Create audit management user ─────────────────────────────────────
step "STEP 3: Creating audit management user '${DB_AUDIT_USER}'"

db_psql -c "DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_AUDIT_USER}') THEN
        CREATE USER ${DB_AUDIT_USER} WITH PASSWORD '${DB_AUDIT_PASS}';
        GRANT pg_monitor TO ${DB_AUDIT_USER};
        RAISE NOTICE 'User ${DB_AUDIT_USER} created.';
      ELSE
        RAISE NOTICE 'User ${DB_AUDIT_USER} already exists.';
      END IF;
    END
    \$\$;"

# ── STEP 4: IAM Service Account ───────────────────────────────────────────────
step "STEP 4: Creating IAM service account '${SERVICE_ACCOUNT_ID}'"

gcp -X POST "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/serviceAccounts" \
    -d '{"accountId":"'"${SERVICE_ACCOUNT_ID}"'","serviceAccount":{"displayName":"DSF Gateway Service Account"}}' \
    > /dev/null 2>&1 || info "Service account may already exist."

info "Generating service account key..."
SA_KEY=$(gcp -X POST \
    "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/serviceAccounts/${SA_EMAIL}/keys" \
    -d '{"privateKeyType":"TYPE_GOOGLE_CREDENTIALS_FILE"}' 2>/dev/null || echo '{}')
KEY_DATA=$(echo "$SA_KEY" | command grep -o '"privateKeyData":"[^"]*"' | cut -d'"' -f4 | head -1 || true)

# ── STEP 5: Pub/Sub topic and subscription ────────────────────────────────────
step "STEP 5: Creating Pub/Sub topic '${TOPIC_NAME}'"

# PUT is idempotent on creation but returns 409 if already exists — treat both as success
HTTP=$(gcurl -s -o /dev/null -w "%{http_code}" \
    -X PUT -H "Content-Type: application/json" \
    "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}" -d '{}')
[ "$HTTP" = "200" ] && info "Topic created: projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}" || \
  info "Topic already exists (HTTP $HTTP) — skipping."

step "STEP 5b: Creating Pub/Sub subscription '${SUB_NAME}'"
HTTP=$(gcurl -s -o /dev/null -w "%{http_code}" \
    -X PUT -H "Content-Type: application/json" \
    "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/subscriptions/${SUB_NAME}" \
    -d '{"topic":"projects/'"${GCP_PROJECT_ID}"'/topics/'"${TOPIC_NAME}"'","ackDeadlineSeconds":60}')
[ "$HTTP" = "200" ] && info "Subscription: projects/${GCP_PROJECT_ID}/subscriptions/${SUB_NAME}" || \
  info "Subscription already exists (HTTP $HTTP) — skipping."

# ── STEP 6: Write setup event to Cloud Logging ───────────────────────────────
step "STEP 6: Writing setup event to Cloud Logging"

gcp -X POST "${GCP_ENDPOINT_URL}/v2/entries:write" \
    -d '{
      "entries": [{
        "logName": "projects/'"${GCP_PROJECT_ID}"'/logs/cloudsql.googleapis.com%2Fdatabase",
        "resource": {
          "type": "cloudsql_database",
          "labels": {"database_id": "'"${GCP_PROJECT_ID}"':'"${INSTANCE_NAME}"'", "region": "'"${GCP_REGION}"'"}
        },
        "textPayload": "SETUP: Cloud SQL PostgreSQL instance '"${INSTANCE_NAME}"' onboarded for DSF Hub"
      }]
    }' > /dev/null
info "Cloud Logging entry written."

# ── Summary ───────────────────────────────────────────────────────────────────
step "Setup complete — DSF Hub asset hierarchy for GCP Cloud SQL PostgreSQL"
cat <<EOF

  GCP Cloud Account asset
    Project ID  : ${GCP_PROJECT_ID}
    Auth Mech   : service_account
    Service Acct: ${SA_EMAIL}

    └── Cloud SQL PostgreSQL instance asset
          Instance    : ${INSTANCE_NAME}
          Database Ver: ${DB_VERSION}
          Region      : ${GCP_REGION}
          Internal IP : ${DB_IP}:${DB_PORT}
          Host Proxy  : localhost:${PROXY_PORT:-N/A} (DBeaver / external clients)
          Container   : ${CONTAINER_NAME}
          Master User : ${DB_MASTER_USER}
          Master Pass : ${DB_MASTER_PASS}
          Audit User  : ${DB_AUDIT_USER}
          Audit Pass  : ${DB_AUDIT_PASS}
          Audit Mode  : log_statement=all (all SQL logged to stdout)

          └── GCP Pub/Sub subscription asset (log aggregator)
                Topic        : projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}
                Subscription : projects/${GCP_PROJECT_ID}/subscriptions/${SUB_NAME}
                Floci URL    : ${GCP_ENDPOINT_URL}

  Required IAM roles for DSF Agentless Gateway:
    roles/pubsub.subscriber   (pull from subscription)
    roles/pubsub.viewer       (view subscription metadata)
    roles/viewer              (read Cloud SQL metadata)

  Log flow (lab):
    PostgreSQL stdout → gcp-log-shipper (docker logs)
    → Pub/Sub topic → DSF Agentless Gateway
EOF

if [ -n "$KEY_DATA" ]; then
    echo
    echo "  Service account key (base64 JSON — decode to use with DSF):"
    echo "    ${KEY_DATA}" | cut -c1-80
    echo "    ...(truncated)"
fi

echo
