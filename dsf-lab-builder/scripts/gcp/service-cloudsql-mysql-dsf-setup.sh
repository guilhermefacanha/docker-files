#!/usr/bin/env bash
# DSF Hub onboarding: GCP Cloud SQL for MySQL via Pub/Sub
# Follows: Thales DSF Hub Reference Guide — GCP Data Sources (Jun 2026)
# Pipeline: Cloud SQL → Cloud Logging → Pub/Sub → DSF Agentless Gateway

set -e
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

echo ""
echo "  NOTE: MySQL Cloud SQL is not yet supported by floci-gcp (v0.4.0+)."
echo "  Only PostgreSQL Cloud SQL instances are available in the current emulator."
echo "  Watch https://github.com/floci-io/floci for future MySQL support."
echo ""
exit 1

# ── Instance configuration ────────────────────────────────────────────────────
INSTANCE_NAME="${CLOUDSQL_INSTANCE_NAME:-mymysql${ENV_SUFFIX:-}-dsf}"
DB_VERSION="MYSQL_8_0"
DB_PORT=3306
TOPIC_NAME="${INSTANCE_NAME}-audit-topic"
SUB_NAME="${INSTANCE_NAME}-dsf-sub"
SA_EMAIL="${SERVICE_ACCOUNT_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
CONTAINER_NAME="floci-cloudsql-${GCP_PROJECT_ID}-${INSTANCE_NAME}"

step()  { echo; echo "=== $* ==="; }
info()  { echo "    $*"; }
gcp()   { gcurl -sf -H "Content-Type: application/json" "$@"; }
gcp_get() { gcurl -sf "${GCP_ENDPOINT_URL}$1"; }

# Run mysql inside the Cloud SQL container (no direct port exposure from floci-gcp)
db_mysql() { docker exec "${CONTAINER_NAME}" mysql -u root -p"${DB_MASTER_PASS}" "$@"; }

wait_runnable() {
    local name="$1" state tries=0
    info "Waiting for container '${CONTAINER_NAME}' and instance to become RUNNABLE..."
    while [ "$tries" -lt 40 ]; do
        state=$(gcp_get "/sql/v1beta4/projects/${GCP_PROJECT_ID}/instances/${name}" \
                | command grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "PENDING")
        if [ "$state" = "RUNNABLE" ]; then
            if docker exec "${CONTAINER_NAME}" mysqladmin -u root -p"${DB_MASTER_PASS}" ping --silent 2>/dev/null; then
                return 0
            fi
        fi
        tries=$((tries + 1)); sleep 3
    done
    echo "ERROR: instance '$name' did not become RUNNABLE (state: $state)" >&2; exit 1
}

# ── STEP 1: Create Cloud SQL MySQL instance ───────────────────────────────────
step "STEP 1: Creating Cloud SQL MySQL instance '${INSTANCE_NAME}'"

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
              {"name": "general_log",    "value": "ON"},
              {"name": "slow_query_log", "value": "ON"}
            ],
            "backupConfiguration": {"enabled": false}
          }
        }' > /dev/null
    info "Instance creation requested."
fi

wait_runnable "$INSTANCE_NAME"

RESP=$(gcp_get "/sql/v1beta4/projects/${GCP_PROJECT_ID}/instances/${INSTANCE_NAME}")
DB_IP=$(echo "$RESP" | command grep -o '"ipAddress":"[^"]*"' | head -1 | cut -d'"' -f4)
info "Instance is RUNNABLE — container: ${CONTAINER_NAME}, internal IP: ${DB_IP}:${DB_PORT}"

# ── STEP 2: Enable audit logging inside the MySQL container ──────────────────
step "STEP 2: Enabling general query log (audit) inside MySQL instance"

db_mysql -e "SET GLOBAL general_log = 'ON';
SET GLOBAL general_log_file = '/var/lib/mysql/general.log';
SET GLOBAL slow_query_log = 'ON';
SHOW VARIABLES LIKE 'general_log%';" 2>/dev/null || \
  info "Note: general_log may already be set via databaseFlags on instance create."

# ── STEP 3: Create audit user ─────────────────────────────────────────────────
step "STEP 3: Creating MySQL audit user '${DB_AUDIT_USER}'"

db_mysql -e "CREATE USER IF NOT EXISTS '${DB_AUDIT_USER}'@'%' IDENTIFIED BY '${DB_AUDIT_PASS}';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO '${DB_AUDIT_USER}'@'%';
GRANT SELECT ON performance_schema.* TO '${DB_AUDIT_USER}'@'%';
FLUSH PRIVILEGES;
SELECT User, Host FROM mysql.user WHERE User = '${DB_AUDIT_USER}';" 2>/dev/null

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

gcp -X PUT "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}" \
    -d '{}' > /dev/null
info "Topic: projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}"

step "STEP 5b: Creating Pub/Sub subscription '${SUB_NAME}'"
gcp -X PUT "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/subscriptions/${SUB_NAME}" \
    -d '{"topic":"projects/'"${GCP_PROJECT_ID}"'/topics/'"${TOPIC_NAME}"'","ackDeadlineSeconds":60}' \
    > /dev/null
info "Subscription: projects/${GCP_PROJECT_ID}/subscriptions/${SUB_NAME}"

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
        "textPayload": "SETUP: Cloud SQL MySQL instance '"${INSTANCE_NAME}"' onboarded for DSF Hub"
      }]
    }' > /dev/null
info "Cloud Logging entry written."

# ── Summary ───────────────────────────────────────────────────────────────────
step "Setup complete — DSF Hub asset hierarchy for GCP Cloud SQL MySQL"
cat <<EOF

  GCP Cloud Account asset
    Project ID  : ${GCP_PROJECT_ID}
    Auth Mech   : service_account
    Service Acct: ${SA_EMAIL}

    └── Cloud SQL MySQL instance asset
          Instance    : ${INSTANCE_NAME}
          Database Ver: ${DB_VERSION}
          Region      : ${GCP_REGION}
          Internal IP : ${DB_IP}:${DB_PORT}
          Container   : ${CONTAINER_NAME}
          Root User   : root
          Root Pass   : ${DB_MASTER_PASS}
          Audit User  : ${DB_AUDIT_USER}
          Audit Pass  : ${DB_AUDIT_PASS}
          Audit Mode  : general_log=ON (all queries logged to file)

          └── GCP Pub/Sub subscription asset (log aggregator)
                Topic        : projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}
                Subscription : projects/${GCP_PROJECT_ID}/subscriptions/${SUB_NAME}
                Floci URL    : ${GCP_ENDPOINT_URL}

  Required IAM roles for DSF Agentless Gateway:
    roles/pubsub.subscriber   (pull from subscription)
    roles/pubsub.viewer       (view subscription metadata)
    roles/viewer              (read Cloud SQL metadata)

  Log flow (lab):
    MySQL general_log → gcp-log-shipper (docker logs + /var/lib/mysql/general.log)
    → Pub/Sub topic → DSF Agentless Gateway
EOF

if [ -n "$KEY_DATA" ]; then
    echo
    echo "  Service account key (base64 JSON — decode to use with DSF):"
    echo "    ${KEY_DATA}" | cut -c1-80
    echo "    ...(truncated)"
fi

echo
