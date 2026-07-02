#!/usr/bin/env bash
# Generate test traffic on a Cloud SQL instance and verify Pub/Sub receives it.
# Usage: CLOUDSQL_INSTANCE_NAME=mypostgres-gcp1-dsf ENGINE=postgres bash service-cloudsql-test-traffic.sh

set -e
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

ENGINE="${ENGINE:-postgres}"
INSTANCE_NAME="${CLOUDSQL_INSTANCE_NAME:-mypostgres${ENV_SUFFIX:-}-dsf}"
TOPIC_NAME="${INSTANCE_NAME}-audit-topic"
SUB_NAME="${INSTANCE_NAME}-dsf-sub"
CONTAINER_NAME="floci-cloudsql-${GCP_PROJECT_ID}-${INSTANCE_NAME}"

# How long to wait for messages before giving up and showing diagnostics
PUBSUB_TIMEOUT="${PUBSUB_TIMEOUT:-90}"
PUBSUB_POLL_INTERVAL=5

step()  { echo; echo "=== $* ==="; }
info()  { echo "    $*"; }
gcp()   { gcurl -sf -H "Content-Type: application/json" "$@"; }

step "STEP 1: Verifying Cloud SQL instance '${INSTANCE_NAME}' is RUNNABLE"
STATE=$(gcurl -sf "${GCP_ENDPOINT_URL}/sql/v1beta4/projects/${GCP_PROJECT_ID}/instances/${INSTANCE_NAME}" \
        | command grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "NOT_FOUND")
if [ "$STATE" != "RUNNABLE" ]; then
    echo "ERROR: instance state is '${STATE}' — run setup script first." >&2; exit 1
fi
info "Instance is ${STATE}."

step "STEP 2: Generating SQL traffic on ${ENGINE} container '${CONTAINER_NAME}'"

if [ "$ENGINE" = "postgres" ]; then
    docker exec -e PGPASSWORD="${DB_MASTER_PASS}" "${CONTAINER_NAME}" \
      psql -U "${DB_MASTER_USER}" -d postgres -c "
        CREATE TABLE IF NOT EXISTS dsf_test (id SERIAL PRIMARY KEY, val TEXT, created_at TIMESTAMPTZ DEFAULT now());
        INSERT INTO dsf_test (val) VALUES ('audit-test-1'),('audit-test-2'),('audit-test-3');
        SELECT * FROM dsf_test ORDER BY id DESC LIMIT 5;
        UPDATE dsf_test SET val = 'updated' WHERE val = 'audit-test-1';
        SELECT count(*) FROM dsf_test;
      " 2>&1
elif [ "$ENGINE" = "mysql" ]; then
    docker exec "${CONTAINER_NAME}" mysql -u root -p"${DB_MASTER_PASS}" -e "
        CREATE DATABASE IF NOT EXISTS dsf_test;
        USE dsf_test;
        CREATE TABLE IF NOT EXISTS dsf_test (id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(100), created_at TIMESTAMP DEFAULT now());
        INSERT INTO dsf_test (val) VALUES ('audit-test-1'),('audit-test-2'),('audit-test-3');
        SELECT * FROM dsf_test ORDER BY id DESC LIMIT 5;
        UPDATE dsf_test SET val='updated' WHERE val='audit-test-1';
        SELECT count(*) FROM dsf_test;
    " 2>/dev/null
fi

# ── decode and print Pub/Sub pull response ────────────────────────────────────
decode_pull() {
    python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
msgs = data.get('receivedMessages', [])
print(len(msgs))
for m in msgs[:5]:
    raw = m.get('message', {}).get('data', '')
    try:
        decoded = base64.b64decode(raw).decode()
        entry = json.loads(decoded)
        print(f'  [{entry.get(\"severity\",\"INFO\")}] {entry.get(\"textPayload\",decoded[:140])}')
    except Exception:
        print(f'  (raw) {raw[:140]}')
" 2>/dev/null
}

step "STEP 3: Polling Pub/Sub subscription '${SUB_NAME}' (up to ${PUBSUB_TIMEOUT}s)"
info "Log-shipper forwards PostgreSQL stdout → Pub/Sub; first messages typically arrive in 5–15s."

ELAPSED=0
MSG_COUNT=0
while [ "$ELAPSED" -lt "$PUBSUB_TIMEOUT" ]; do
    info "Polling at ${ELAPSED}s …"
    PULL_RESP=$(gcp -X POST \
        "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/subscriptions/${SUB_NAME}:pull" \
        -d '{"maxMessages":10}' 2>/dev/null || echo '{}')

    RESULT=$(echo "$PULL_RESP" | decode_pull)
    MSG_COUNT=$(echo "$RESULT" | head -1)

    if [ "${MSG_COUNT:-0}" -gt 0 ]; then
        info "Received ${MSG_COUNT} message(s) from Pub/Sub after ${ELAPSED}s:"
        echo "$RESULT" | tail -n +2
        break
    fi

    sleep "$PUBSUB_POLL_INTERVAL"
    ELAPSED=$((ELAPSED + PUBSUB_POLL_INTERVAL))
done

if [ "${MSG_COUNT:-0}" -eq 0 ]; then
    echo
    echo "  WARNING: No Pub/Sub messages received after ${PUBSUB_TIMEOUT}s."
    echo "  Running diagnostics..."
    echo

    step "DIAGNOSTIC: gcp-log-shipper container logs (last 40 lines)"
    if docker ps --format '{{.Names}}' | grep -q "gcp-log-shipper"; then
        docker logs --tail 40 gcp-log-shipper 2>&1 | sed 's/^/  /'
    else
        echo "  ERROR: gcp-log-shipper container is NOT running."
        echo "  Start it with: docker compose -f scripts/gcp/docker-compose.yml up -d gcp-log-shipper"
    fi

    step "DIAGNOSTIC: Cloud SQL container logs (last 20 lines)"
    if docker ps --format '{{.Names}}' | grep -q "${CONTAINER_NAME}"; then
        docker logs --tail 20 "${CONTAINER_NAME}" 2>&1 | sed 's/^/  /'
    else
        echo "  ERROR: Cloud SQL container '${CONTAINER_NAME}' is NOT running."
    fi

    step "DIAGNOSTIC: Pub/Sub topic list"
    gcurl -sf "${GCP_ENDPOINT_URL}/v1/projects/${GCP_PROJECT_ID}/topics" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); [print('  ',t.get('name','')) for t in d.get('topics',[])]" 2>/dev/null || \
        echo "  (could not list topics)"
fi

step "STEP 4: Checking Cloud Logging for entries"
gcurl -sf "${GCP_ENDPOINT_URL}/v2/projects/${GCP_PROJECT_ID}/logs" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print('    ',l) for l in d.get('logNames',[])]" 2>/dev/null

echo
if [ "${MSG_COUNT:-0}" -gt 0 ]; then
    info "Traffic test complete — audit pipeline is working end-to-end."
else
    info "Traffic test finished with no messages. Check diagnostics above."
fi
echo
