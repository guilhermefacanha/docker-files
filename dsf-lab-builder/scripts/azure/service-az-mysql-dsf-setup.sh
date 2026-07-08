#!/usr/bin/env bash
# DSF Hub onboarding: Azure Database for MySQL (Flexible Server) via Event Hubs
# Follows: Thales DSF Hub Reference Guide — Azure Data Sources (Jun 2026)
# Pipeline: MySQL → Diagnostic Settings → Azure Monitor → Event Hubs → DSF Agentless Gateway

set -e
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# ── Configuration ─────────────────────────────────────────────────────────────
SERVER_NAME="${DB_SERVER_NAME:-mymysql${ENV_SUFFIX:-}-dsf}"
DB_VERSION="8.0.21"
CONTAINER_NAME="floci-az-mysql-${SERVER_NAME}"
NETWORK="${FLOCI_AZ_NETWORK:-floci-az1_default}"

step()  { echo; echo "=== $* ==="; }
info()  { echo "    $*"; }

ARM_BASE="/subscriptions/${AZ_SUBSCRIPTION_ID}/resourceGroups/${AZ_RESOURCE_GROUP}"
DIAG_PATH="${ARM_BASE}/providers/Microsoft.DBforMySQL/flexibleServers/${SERVER_NAME}/providers/microsoft.insights/diagnosticSettings/dsf-audit"
EH_RULE_ID="${ARM_BASE}/providers/Microsoft.EventHub/namespaces/${AZ_EVENTHUB_NAMESPACE}/authorizationRules/RootManageSharedAccessKey"

wait_ready() {
    local name="$1" tries=0
    info "Waiting for server '${CONTAINER_NAME}' to become Ready..."
    while [ "$tries" -lt 40 ]; do
        state=$(az_get "${ARM_BASE}/providers/Microsoft.DBforMySQL/flexibleServers/${name}?api-version=2023-06-30" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('properties',{}).get('state',''))" 2>/dev/null || echo "")
        if [ "$state" = "Ready" ]; then
            if docker exec "${CONTAINER_NAME}" mysqladmin -u root -p"${DB_MASTER_PASS}" ping --silent 2>/dev/null; then
                return 0
            fi
        fi
        tries=$((tries + 1)); sleep 3
    done
    echo "ERROR: server '${name}' did not become Ready (state: ${state})" >&2; exit 1
}

# ── STEP 1: Create Event Hub namespace via floci-az native API (starts Artemis) ──
step "STEP 1: Creating Event Hub namespace '${AZ_EVENTHUB_NAMESPACE}' (Artemis AMQP)"

EH_ACCOUNT_PREFIX="${AZ_EVENTHUB_ACCOUNT_PREFIX:-dsf-lab}"
EH_NS_URL="${FLOCI_AZ_ENDPOINT}/${EH_ACCOUNT_PREFIX}-eventhub/namespaces/${AZ_EVENTHUB_NAMESPACE}"
EH_RESP=$(curl -s --fail-with-body -X PUT -H "Content-Type: application/json" "${EH_NS_URL}" \
    -d "{\"entities\":\"${AZ_EVENTHUB_NAME}\",\"consumerGroups\":\"\$Default\"}" || echo '{"mocked":true}')
EH_MOCKED=$(echo "$EH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('mocked',True)).lower())" 2>/dev/null || echo "true")

if [ "$EH_MOCKED" = "false" ]; then
    info "Artemis broker starting for namespace '${AZ_EVENTHUB_NAMESPACE}'..."
    # Wait for Artemis to be ready (poll amqpPort)
    for i in $(seq 1 30); do
        AMQP_PORT=$(curl -sf "${EH_NS_URL}" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('amqpPort',0))" 2>/dev/null || echo "0")
        [ "${AMQP_PORT:-0}" -gt 0 ] && { info "Artemis ready (AMQP port ${AMQP_PORT})"; break; }
        sleep 3
    done
else
    info "Event Hub in mocked mode — AMQP disabled. Set FLOCI_AZ_SERVICES_EVENT_HUB_MOCKED=false to enable Artemis."
fi
info "Event Hub ready: ${AZ_EVENTHUB_NAMESPACE}/${AZ_EVENTHUB_NAME}"

# ── STEP 2: Create MySQL Flexible Server ──────────────────────────────────────
step "STEP 2: Creating Azure Database for MySQL '${SERVER_NAME}'"

existing=$(az_get "${ARM_BASE}/providers/Microsoft.DBforMySQL/flexibleServers/${SERVER_NAME}?api-version=2023-06-30" 2>/dev/null \
           | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('properties',{}).get('state',''))" 2>/dev/null || echo "")

if [ -n "$existing" ] && [ "$existing" != "" ]; then
    info "Server already exists (state: ${existing}) — skipping creation."
else
    az_put "${ARM_BASE}/providers/Microsoft.DBforMySQL/flexibleServers/${SERVER_NAME}?api-version=2023-06-30" \
        -d "{
          \"location\": \"${AZ_LOCATION}\",
          \"sku\": {\"name\": \"Standard_B1ms\", \"tier\": \"Burstable\"},
          \"properties\": {
            \"administratorLogin\": \"${DB_MASTER_USER}\",
            \"administratorLoginPassword\": \"${DB_MASTER_PASS}\",
            \"version\": \"${DB_VERSION}\",
            \"storage\": {\"storageSizeGB\": 20}
          }
        }" > /dev/null
    info "Server creation requested."
fi

wait_ready "$SERVER_NAME"

RESP=$(az_get "${ARM_BASE}/providers/Microsoft.DBforMySQL/flexibleServers/${SERVER_NAME}?api-version=2023-06-30")
DB_IP=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('properties',{}).get('fullyQualifiedDomainName',''))" 2>/dev/null || echo "")
DB_PORT=3306
info "Server is Ready — container: ${CONTAINER_NAME}"

# ── STEP 2b: Start host-accessible socat proxy ────────────────────────────────
step "STEP 2b: Starting host port proxy for DBeaver / data generator"

PROXY_CONTAINER="azdb-proxy-mysql-${SERVER_NAME}"
docker rm -f "${PROXY_CONTAINER}" 2>/dev/null || true

PROXY_PORT=""
for p in $(seq "$DB_PROXY_BASE_PORT" "$DB_PROXY_MAX_PORT"); do
    if ! docker ps --format "{{.Ports}}" | grep -q ":${p}->"; then
        PROXY_PORT=$p
        break
    fi
done

CONTAINER_IP=$(docker inspect "${CONTAINER_NAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1 || echo "")

if [ -z "$PROXY_PORT" ]; then
    info "WARNING: no free proxy port found in ${DB_PROXY_BASE_PORT}-${DB_PROXY_MAX_PORT}, skipping proxy."
elif [ -z "$CONTAINER_IP" ]; then
    info "WARNING: cannot determine container IP for ${CONTAINER_NAME}, skipping proxy."
else
    docker run -d --rm \
        --name "${PROXY_CONTAINER}" \
        --network "${NETWORK}" \
        -p "${PROXY_PORT}:${PROXY_PORT}" \
        alpine/socat \
        TCP-LISTEN:${PROXY_PORT},fork,reuseaddr "TCP:${CONTAINER_IP}:${DB_PORT}" >/dev/null
    info "Proxy started: localhost:${PROXY_PORT} → ${CONTAINER_IP}:${DB_PORT}"
    info "DBeaver: host=localhost  port=${PROXY_PORT}  user=${DB_MASTER_USER}  pass=${DB_MASTER_PASS}"
fi

# ── STEP 3: Create audit management database and user ────────────────────────
step "STEP 3: Creating audit database and management user '${DB_AUDIT_USER}'"

docker exec "${CONTAINER_NAME}" mysql -u root -p"${DB_MASTER_PASS}" -e "
    CREATE DATABASE IF NOT EXISTS dsf_lab;
    CREATE USER IF NOT EXISTS '${DB_MASTER_USER}'@'%' IDENTIFIED BY '${DB_MASTER_PASS}';
    GRANT ALL PRIVILEGES ON *.* TO '${DB_MASTER_USER}'@'%' WITH GRANT OPTION;
    CREATE USER IF NOT EXISTS '${DB_AUDIT_USER}'@'%' IDENTIFIED BY '${DB_AUDIT_PASS}';
    GRANT SELECT, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${DB_AUDIT_USER}'@'%';
    FLUSH PRIVILEGES;
" 2>/dev/null
info "User '${DB_MASTER_USER}' and '${DB_AUDIT_USER}' ready."

# ── STEP 4: Configure Diagnostic Settings → Event Hubs ───────────────────────
step "STEP 4: Configuring diagnostic settings to route audit logs → Event Hubs"

az_put "${DIAG_PATH}?api-version=2021-05-01-preview" \
    -d "{
      \"properties\": {
        \"eventHubAuthorizationRuleId\": \"${EH_RULE_ID}\",
        \"eventHubName\": \"${AZ_EVENTHUB_NAME}\",
        \"logs\": [
          {\"category\": \"MySqlAuditLogs\", \"enabled\": true},
          {\"category\": \"MySqlSlowLogs\",  \"enabled\": true}
        ],
        \"metrics\": [
          {\"category\": \"AllMetrics\", \"enabled\": false}
        ]
      }
    }" > /dev/null
info "Diagnostic settings configured: MySQL audit logs → ${AZ_EVENTHUB_NAMESPACE}/${AZ_EVENTHUB_NAME}"

# ── Summary ───────────────────────────────────────────────────────────────────
step "Setup complete — DSF Hub asset hierarchy for Azure Database for MySQL"
cat <<EOF

  Azure Subscription asset
    Subscription  : ${AZ_SUBSCRIPTION_ID}

    └── Resource Group: ${AZ_RESOURCE_GROUP}

        └── Azure Database for MySQL (Flexible Server)
              Server Name  : ${SERVER_NAME}
              Version      : ${DB_VERSION}
              Location     : ${AZ_LOCATION}
              FQDN         : ${DB_IP}:${DB_PORT}
              Host Proxy   : localhost:${PROXY_PORT:-N/A} (DBeaver / data generator)
              Container    : ${CONTAINER_NAME}
              Master User  : ${DB_MASTER_USER}
              Master Pass  : ${DB_MASTER_PASS}
              Audit User   : ${DB_AUDIT_USER}
              Audit Pass   : ${DB_AUDIT_PASS}

              └── Diagnostic Settings: dsf-audit
                    Log Category  : MySqlAuditLogs, MySqlSlowLogs
                    Routed to     : ${AZ_EVENTHUB_NAMESPACE}/${AZ_EVENTHUB_NAME}
                    Floci-AZ URL  : ${FLOCI_AZ_ENDPOINT}

        └── Event Hub Namespace: ${AZ_EVENTHUB_NAMESPACE}
              Event Hub    : ${AZ_EVENTHUB_NAME}
              Connection   : Endpoint=sb://${AZ_EVENTHUB_NAMESPACE}.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=test

  DSF Agentless Gateway connection:
    Event Hub Namespace : ${AZ_EVENTHUB_NAMESPACE}.servicebus.windows.net
    Event Hub Name      : ${AZ_EVENTHUB_NAME}
    Auth                : Connection String (SharedAccessKey)

  Log flow (lab):
    MySQL stdout → az-log-shipper (docker logs)
    → Event Hub → DSF Agentless Gateway
EOF
echo
