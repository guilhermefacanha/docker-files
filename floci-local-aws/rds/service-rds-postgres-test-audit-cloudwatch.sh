#!/bin/bash
# Validates that PostgreSQL pgaudit is generating logs and
# that CloudWatch (via floci) is receiving them.
# Uses docker exec into the postgres container — no local psql required.

set -e

# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

DB_INSTANCE_ID="${DB_INSTANCE_ID:-mypostgres${ENV_SUFFIX:-}-dsf}"
SLOW_QUERY_MS="${SLOW_QUERY_MS:-}"

CONTAINER="floci-rds-${DB_INSTANCE_ID}"
LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/postgresql"

# ─── Helpers ──────────────────────────────────────────────────────────────────
step()  { echo; echo "=== $* ==="; }
pass()  { echo "  [PASS] $*"; }
fail()  { echo "  [FAIL] $*"; }
info()  { echo "    $*"; }

psql_exec() {
    docker exec "$CONTAINER" \
        env PGPASSWORD="$DB_MASTER_PASS" \
        psql -U "$DB_MASTER_USER" -d postgres -At -c "$1"
}

psql_exec_db() {
    local db="$1"; shift
    docker exec "$CONTAINER" \
        env PGPASSWORD="$DB_MASTER_PASS" \
        psql -U "$DB_MASTER_USER" -d "$db" -At -c "$1"
}

# ─── Preflight ────────────────────────────────────────────────────────────────
step "Preflight checks"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "ERROR: container '${CONTAINER}' is not running." >&2
    echo "       Run service-rds-postgres-dsf-setup.sh first." >&2
    exit 1
fi
pass "Postgres container '${CONTAINER}' is running"

PG_VERSION=$(psql_exec "SHOW server_version;")
info "PostgreSQL version: ${PG_VERSION}"

# ─── Step 1: Install pgaudit extension ────────────────────────────────────────
step "Step 1: Configure and install pgaudit extension"

# floci emulates the RDS parameter group API but does NOT inject those settings
# into the running postgres container. We apply them directly via ALTER SYSTEM
# (writes to postgresql.auto.conf) then restart the container.

PRELOAD=$(psql_exec "SHOW shared_preload_libraries;" 2>/dev/null || true)
info "shared_preload_libraries (before): '${PRELOAD}'"

if echo "$PRELOAD" | grep -q "pgaudit"; then
    pass "pgaudit already in shared_preload_libraries"
else
    # Phase 1: set shared_preload_libraries and restart so pgaudit.so is loaded
    info "Setting shared_preload_libraries=pgaudit and restarting..."
    psql_exec "ALTER SYSTEM SET shared_preload_libraries = 'pgaudit';"
    docker restart "$CONTAINER" >/dev/null
    sleep 5

    PRELOAD=$(psql_exec "SHOW shared_preload_libraries;" 2>/dev/null || true)
    if echo "$PRELOAD" | grep -q "pgaudit"; then
        pass "pgaudit loaded (shared_preload_libraries: ${PRELOAD})"
    else
        fail "shared_preload_libraries still missing pgaudit: '${PRELOAD}'"
    fi

    # Phase 2: now that pgaudit.so is loaded, set its parameters
    info "Configuring pgaudit and connection logging parameters..."
    psql_exec "ALTER SYSTEM SET pgaudit.log = 'all';"
    psql_exec "ALTER SYSTEM SET log_connections = '1';"
    psql_exec "ALTER SYSTEM SET log_disconnections = '1';"
    psql_exec "ALTER SYSTEM SET log_error_verbosity = 'verbose';"
    psql_exec "SELECT pg_reload_conf();"
    pass "pgaudit parameters applied"
fi

psql_exec "CREATE EXTENSION IF NOT EXISTS pgaudit;"
EXT=$(psql_exec "SELECT installed_version FROM pg_available_extensions WHERE name='pgaudit';")
if [ -n "$EXT" ]; then
    pass "pgaudit extension installed (version ${EXT})"
else
    fail "pgaudit extension not found — check custom image has pgaudit.so"
    exit 1
fi

PGAUDIT_LOG=$(psql_exec "SHOW pgaudit.log;" 2>/dev/null || true)
info "pgaudit.log: ${PGAUDIT_LOG}"

# ─── Step 2: Generate audit events ────────────────────────────────────────────
step "Step 2: Generating audit events (DDL, DML, READ, ROLE)"

TEST_DB="audit_test_db"
TEST_TABLE="orders"

# DDL — CREATE DATABASE
psql_exec "CREATE DATABASE ${TEST_DB};" 2>/dev/null || info "(database ${TEST_DB} already exists)"
pass "DDL: CREATE DATABASE"

# DDL — CREATE TABLE
psql_exec_db "$TEST_DB" "
    CREATE TABLE IF NOT EXISTS ${TEST_TABLE} (
        id      SERIAL PRIMARY KEY,
        item    TEXT NOT NULL,
        amount  NUMERIC(10,2),
        created TIMESTAMPTZ DEFAULT now()
    );"
pass "DDL: CREATE TABLE"

# DML — INSERT
psql_exec_db "$TEST_DB" "
    INSERT INTO ${TEST_TABLE} (item, amount) VALUES
        ('laptop', 1299.99),
        ('keyboard', 79.00),
        ('monitor', 499.50);"
pass "DML: INSERT (3 rows)"

# READ — SELECT
ROW_COUNT=$(psql_exec_db "$TEST_DB" "SELECT COUNT(*) FROM ${TEST_TABLE};")
pass "READ: SELECT COUNT(*) = ${ROW_COUNT}"

# DML — UPDATE
psql_exec_db "$TEST_DB" "UPDATE ${TEST_TABLE} SET amount = amount * 1.10 WHERE item = 'laptop';"
pass "DML: UPDATE"

# DML — DELETE
psql_exec_db "$TEST_DB" "DELETE FROM ${TEST_TABLE} WHERE item = 'keyboard';"
pass "DML: DELETE"

# ROLE — CREATE USER
psql_exec "CREATE USER audit_test_reader WITH PASSWORD 'ReadOnly1';" 2>/dev/null || true
psql_exec_db "$TEST_DB" "GRANT SELECT ON ${TEST_TABLE} TO audit_test_reader;" 2>/dev/null || true
pass "ROLE: CREATE USER + GRANT"

# DDL — intentional error (caught exception generates an audit event too)
psql_exec "SELECT no_such_column FROM no_such_table;" 2>/dev/null || true
pass "EXCEPTION: invalid query (generates pgaudit ERROR event)"

# Slow query (only if SLOW_QUERY_MS is configured)
if [ -n "$SLOW_QUERY_MS" ]; then
    DELAY_S=$(echo "scale=3; $SLOW_QUERY_MS / 1000 + 0.5" | bc)
    psql_exec_db "$TEST_DB" "SELECT pg_sleep(${DELAY_S}), 'slow query test';" >/dev/null
    pass "SLOW_QUERY: pg_sleep(${DELAY_S}s) — should appear in slow_query collection"
fi

# ─── Step 2b: Wait for log shipper to flush events to CloudWatch ──────────────
step "Step 2b: Waiting for log shipper to flush events to CloudWatch"

WAIT_MAX=30
WAIT_STEP=3
waited=0
info "Polling filter-log-events (up to ${WAIT_MAX}s)..."
while [ "$waited" -lt "$WAIT_MAX" ]; do
    EARLY_COUNT=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --filter-pattern "AUDIT" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'length(events)' \
        --output text 2>/dev/null || echo 0)
    if [ "${EARLY_COUNT:-0}" -gt 0 ]; then
        pass "Log shipper flushed ${EARLY_COUNT} AUDIT event(s) after ${waited}s"
        break
    fi
    sleep "$WAIT_STEP"
    waited=$((waited + WAIT_STEP))
    info "  ...${waited}s elapsed, events in CW so far: ${EARLY_COUNT:-0}"
done
if [ "${EARLY_COUNT:-0}" -eq 0 ]; then
    info "No AUDIT events in CloudWatch after ${WAIT_MAX}s — sidecar may need more time or be misconfigured"
fi

# ─── Step 3: Read postgres logs from inside the container ─────────────────────
step "Step 3: Checking postgres logs inside the container for AUDIT entries"

# Alpine postgres logs to stderr; docker logs captures it
AUDIT_LINES=$(docker logs "$CONTAINER" 2>&1 | grep -c "AUDIT:" || true)
TOTAL_LINES=$(docker logs "$CONTAINER" 2>&1 | wc -l | tr -d ' ')

info "Total log lines: ${TOTAL_LINES}"
if [ "$AUDIT_LINES" -gt 0 ]; then
    pass "Found ${AUDIT_LINES} AUDIT lines in postgres container logs"
    echo
    echo "  Sample audit entries:"
    docker logs "$CONTAINER" 2>&1 | grep "AUDIT:" | tail -6 | sed 's/^/    /'
else
    fail "No AUDIT lines found in container logs yet"
    info "(pgaudit may need a moment, or shared_preload_libraries was not applied)"
fi

# ─── Step 4: Check CloudWatch log streams ─────────────────────────────────────
step "Step 4: Checking CloudWatch log group '${LOG_GROUP}'"

STREAMS=$(aws logs describe-log-streams \
    --log-group-name "$LOG_GROUP" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'logStreams[].logStreamName' \
    --output json 2>/dev/null)

STREAM_COUNT=$(echo "$STREAMS" | jq 'length')
info "Log streams found: ${STREAM_COUNT}"
echo "$STREAMS" | jq -r '.[]' | sed 's/^/    - /'

if [ "$STREAM_COUNT" -gt 0 ]; then
    pass "CloudWatch log group has ${STREAM_COUNT} stream(s)"

    # Pull events from the first stream
    FIRST_STREAM=$(echo "$STREAMS" | jq -r '.[0]')
    step "Step 4b: Log events in stream '${FIRST_STREAM}'"

    EVENTS=$(aws logs get-log-events \
        --log-group-name "$LOG_GROUP" \
        --log-stream-name "$FIRST_STREAM" \
        --limit 20 \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'events[].message' \
        --output json 2>/dev/null)

    EVENT_COUNT=$(echo "$EVENTS" | jq 'length')
    info "Events retrieved: ${EVENT_COUNT}"

    if [ "$EVENT_COUNT" -gt 0 ]; then
        pass "CloudWatch is delivering log events"
        echo
        echo "  Last ${EVENT_COUNT} events:"
        echo "$EVENTS" | jq -r '.[]' | tail -10 | sed 's/^/    /'

        # Verify audit events are in CloudWatch
        AUDIT_CW=$(echo "$EVENTS" | jq -r '.[]' | grep -c "AUDIT:" || true)
        if [ "$AUDIT_CW" -gt 0 ]; then
            pass "CloudWatch contains ${AUDIT_CW} pgaudit AUDIT event(s) — end-to-end verified"
        else
            info "No AUDIT: lines in CloudWatch yet (logs may be buffered — try filter-log-events)"
        fi
    else
        fail "No events in CloudWatch stream yet"
        info "In real AWS this is near-real-time; in floci it may require a flush interval"
    fi
else
    fail "No CloudWatch log streams yet"
    info "Floci may not yet push postgres file logs into CloudWatch streams."
    info "Use 'filter-log-events' below to poll once a stream appears."
fi

# ─── Step 5: Resolve log-group ARN and query streams via ARN (DSF flow) ───────
step "Step 5: Resolve log-group ARN via describe-log-groups, then describe streams via ARN"

# DSF discovers log groups by name prefix and then pins all subsequent calls to
# the resolved ARN (--log-group-identifier). This step mirrors that flow.
LOG_GROUP_ARN=$(aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'logGroups[0].arn' \
    --output text 2>/dev/null)

if [ -n "$LOG_GROUP_ARN" ] && [ "$LOG_GROUP_ARN" != "None" ]; then
    pass "Resolved log-group ARN: ${LOG_GROUP_ARN}"

    ARN_STREAMS=$(aws logs describe-log-streams \
        --log-group-identifier "$LOG_GROUP_ARN" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'logStreams[].logStreamName' \
        --output json 2>/dev/null)

    ARN_STREAM_COUNT=$(echo "$ARN_STREAMS" | jq 'length' 2>/dev/null || echo 0)
    if [ "${ARN_STREAM_COUNT:-0}" -gt 0 ]; then
        pass "describe-log-streams via ARN returned ${ARN_STREAM_COUNT} stream(s) — DSF ARN flow works"
        echo "$ARN_STREAMS" | jq -r '.[]' | sed 's/^/    - /'
    else
        fail "describe-log-streams via ARN returned 0 streams"
    fi
else
    fail "Could not resolve ARN for log group '${LOG_GROUP}' via describe-log-groups"
    LOG_GROUP_ARN=""
    ARN_STREAM_COUNT=0
fi

# ─── Step 6: filter-log-events (DSF Agentless Gateway uses this) ──────────────
step "Step 6: Simulating DSF audit pull via logs:FilterLogEvents"

FILTER_RESULT=$(aws logs filter-log-events \
    --log-group-name "$LOG_GROUP" \
    --filter-pattern "AUDIT" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'events[].message' \
    --output json 2>/dev/null)

FILTER_COUNT=$(echo "$FILTER_RESULT" | jq 'length')

if [ "$FILTER_COUNT" -gt 0 ]; then
    pass "filter-log-events returned ${FILTER_COUNT} AUDIT event(s) — DSF pull works"
    echo "$FILTER_RESULT" | jq -r '.[]' | head -5 | sed 's/^/    /'
else
    info "filter-log-events returned 0 results (streams may still be empty in floci)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Summary"
cat <<EOF
  Container logs       : ${AUDIT_LINES} pgaudit AUDIT lines
  CW streams           : ${STREAM_COUNT}
  CW events pulled     : ${EVENT_COUNT:-0}
  CW log-group ARN     : ${LOG_GROUP_ARN:-<unresolved>}
  CW streams via ARN   : ${ARN_STREAM_COUNT:-0}
  CW audit filter      : ${FILTER_COUNT} events

  Useful commands to keep polling CloudWatch:

    # List streams
    aws logs describe-log-streams \\
      --log-group-name "${LOG_GROUP}" \\
      --endpoint-url ${AWS_ENDPOINT_URL}

    # Get events
    aws logs filter-log-events \\
      --log-group-name "${LOG_GROUP}" \\
      --filter-pattern "AUDIT" \\
      --endpoint-url ${AWS_ENDPOINT_URL}

    # Watch container logs live
    docker logs -f ${CONTAINER} 2>&1 | grep --line-buffered AUDIT

EOF
