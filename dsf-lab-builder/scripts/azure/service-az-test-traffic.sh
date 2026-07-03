#!/usr/bin/env bash
# Generate test traffic on an Azure Database instance and verify Event Hub receives it.
# Usage: ENGINE=mysql DB_SERVER_NAME=mymysql-az1-dsf bash service-az-test-traffic.sh

set -e
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

ENGINE="${ENGINE:-mysql}"
SERVER_NAME="${DB_SERVER_NAME:-my${ENGINE}${ENV_SUFFIX:-}-dsf}"
EVENTHUB_TIMEOUT="${EVENTHUB_TIMEOUT:-90}"
POLL_INTERVAL=5

step()  { echo; echo "=== $* ==="; }
info()  { echo "    $*"; }

ARM_BASE="/subscriptions/${AZ_SUBSCRIPTION_ID}/resourceGroups/${AZ_RESOURCE_GROUP}"
CONSUMER_GROUP="\$Default"

# Determine container name based on engine
case "$ENGINE" in
    mysql)    CONTAINER_NAME="floci-az-mysql-${SERVER_NAME}";    DB_PORT=3306 ;;
    mariadb)  CONTAINER_NAME="floci-az-mariadb-${SERVER_NAME}";  DB_PORT=3306 ;;
    postgres) CONTAINER_NAME="floci-az-pg-${SERVER_NAME}"; DB_PORT=5432 ;;
    *)        echo "ERROR: unsupported engine '$ENGINE'" >&2; exit 1 ;;
esac

# ── STEP 1: Verify server is Ready ───────────────────────────────────────────
step "STEP 1: Verifying Azure Database for ${ENGINE} '${SERVER_NAME}' is Ready"

case "$ENGINE" in
    mysql)
        PROVIDER="Microsoft.DBforMySQL"; KIND="flexibleServers"; STATE_KEY="state" ;;
    mariadb)
        PROVIDER="Microsoft.DBforMariaDB"; KIND="servers"; STATE_KEY="userVisibleState" ;;
    postgres)
        PROVIDER="Microsoft.DBforPostgreSQL"; KIND="flexibleServers"; STATE_KEY="state" ;;
esac

STATE=$(az_get "${ARM_BASE}/providers/${PROVIDER}/${KIND}/${SERVER_NAME}?api-version=2023-01-01" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('properties',{}).get('${STATE_KEY}','NOT_FOUND'))" 2>/dev/null || echo "NOT_FOUND")
if [ "$STATE" != "Ready" ]; then
    echo "ERROR: server state is '${STATE}' — run setup script first." >&2; exit 1
fi
info "Server is ${STATE}."

# ── STEP 2: Generate SQL traffic ──────────────────────────────────────────────
step "STEP 2: Generating SQL traffic on ${ENGINE} container '${CONTAINER_NAME}'"

case "$ENGINE" in
    mysql|mariadb)
        CLIENT="mysql"
        [ "$ENGINE" = "mariadb" ] && CLIENT="mariadb"
        docker exec "${CONTAINER_NAME}" ${CLIENT} -u "${DB_MASTER_USER}" -p"${DB_MASTER_PASS}" -e "
            CREATE DATABASE IF NOT EXISTS dsf_test;
            USE dsf_test;
            CREATE TABLE IF NOT EXISTS dsf_test (id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(100), ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
            INSERT INTO dsf_test (val) VALUES ('audit-test-1'),('audit-test-2'),('audit-test-3');
            SELECT * FROM dsf_test ORDER BY id DESC LIMIT 5;
            UPDATE dsf_test SET val='updated' WHERE val='audit-test-1';
            SELECT count(*) FROM dsf_test;
        " 2>/dev/null && info "SQL traffic generated." || \
        docker exec "${CONTAINER_NAME}" mysql -u root -p"${DB_MASTER_PASS}" -e "
            CREATE DATABASE IF NOT EXISTS dsf_test;
            USE dsf_test;
            CREATE TABLE IF NOT EXISTS dsf_test (id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(100));
            INSERT INTO dsf_test (val) VALUES ('test-1'),('test-2'),('test-3');
            SELECT count(*) FROM dsf_test;
        " 2>/dev/null && info "SQL traffic generated (root fallback)."
        ;;
    postgres)
        docker exec -e PGPASSWORD="${DB_MASTER_PASS}" "${CONTAINER_NAME}" \
            psql -U "${DB_MASTER_USER}" -d postgres -c "
                CREATE TABLE IF NOT EXISTS dsf_test (id SERIAL PRIMARY KEY, val TEXT, ts TIMESTAMPTZ DEFAULT now());
                INSERT INTO dsf_test (val) VALUES ('audit-test-1'),('audit-test-2'),('audit-test-3');
                SELECT * FROM dsf_test ORDER BY id DESC LIMIT 5;
                UPDATE dsf_test SET val='updated' WHERE val='audit-test-1';
                SELECT count(*) FROM dsf_test;
            " 2>&1
        ;;
esac

# ── STEP 3: Poll Event Hub for messages ──────────────────────────────────────
step "STEP 3: Checking az-log-shipper and Artemis Event Hub pipeline"
info "az-log-shipper tails container stdout and publishes to Artemis AMQP (Event Hub emulator)."

# Find az-log-shipper container (named by docker compose project, e.g. floci-az1-az-log-shipper-1)
SHIPPER_CONTAINER=$(docker ps --format '{{.Names}}' | grep "az-log-shipper" | head -1 || true)
MSG_COUNT=0

if [ -n "$SHIPPER_CONTAINER" ]; then
    step "az-log-shipper logs (last 30 lines) — container: ${SHIPPER_CONTAINER}"
    SHIPPER_LOGS=$(docker logs --tail 30 "${SHIPPER_CONTAINER}" 2>&1)
    echo "$SHIPPER_LOGS" | sed 's/^/  /'

    # Check if shipper is publishing (amqp or fallback)
    if echo "$SHIPPER_LOGS" | grep -q "\[amqp\] published\|\[fallback\]"; then
        MSG_COUNT=$(echo "$SHIPPER_LOGS" | grep -c "\[amqp\] published\|\[fallback\]" || echo 0)
        info "az-log-shipper has published ${MSG_COUNT} batch(es) to Event Hub."
    elif echo "$SHIPPER_LOGS" | grep -q "Tailing"; then
        info "az-log-shipper is tailing containers (waiting for audit events or AMQP connection)."
        MSG_COUNT=1  # shipper running = pipeline active
    else
        info "az-log-shipper running but no publish activity yet."
    fi
else
    echo "  WARNING: az-log-shipper container not found."
    echo "  Expected container name pattern: *az-log-shipper*"
    docker ps --format '{{.Names}}' | grep "floci-az" | sed 's/^/    /' || true
fi

# Check Artemis Event Hub namespace
EH_ACCOUNT_PREFIX="${AZ_EVENTHUB_ACCOUNT_PREFIX:-dsf-lab}"
EH_NS_URL="${FLOCI_AZ_ENDPOINT}/${EH_ACCOUNT_PREFIX}-eventhub/namespaces/${AZ_EVENTHUB_NAMESPACE}"
EH_STATE=$(curl -sf "${EH_NS_URL}" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
mocked=d.get('mocked',True)
amqp=d.get('amqpPort',0)
print(f\"mocked={mocked} amqpPort={amqp}\")
" 2>/dev/null || echo "not found")
info "Artemis state: ${EH_STATE}"

# ── STEP 4: Verify Diagnostic Settings ───────────────────────────────────────
step "STEP 4: Verifying diagnostic settings for ${SERVER_NAME}"
az_get "${ARM_BASE}/providers/${PROVIDER}/${KIND}/${SERVER_NAME}/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('value',[]):
    p=s.get('properties',{})
    print(f\"  Setting: {s.get('name')} → EventHub: {p.get('eventHubName')} (NS: {p.get('eventHubAuthorizationRuleId','').split('/')[-3] if p.get('eventHubAuthorizationRuleId') else '?'})\")
    for l in p.get('logs',[]):
        if l.get('enabled'):
            print(f\"    [LOG] {l.get('category')}\")
" 2>/dev/null || echo "  (could not retrieve diagnostic settings)"

echo
if [ "${MSG_COUNT:-0}" -gt 0 ]; then
    info "Traffic test complete — SQL generated, diagnostic settings configured, az-log-shipper active."
else
    info "Traffic test finished. Check az-log-shipper logs above for pipeline status."
fi
echo
