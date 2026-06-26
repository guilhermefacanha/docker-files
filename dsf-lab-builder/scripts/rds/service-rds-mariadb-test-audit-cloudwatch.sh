#!/bin/bash
# Validates that MARIADB_AUDIT_PLUGIN is generating logs and
# that CloudWatch (via floci) is receiving them for MariaDB.
# Uses docker exec into the mariadb container — no local mysql client required.
# MariaDB exports TWO log types: "audit" and "error"

set -e

# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

DB_INSTANCE_ID="${DB_INSTANCE_ID:-mymariadb${ENV_SUFFIX:-}-dsf}"

CONTAINER="floci-rds-${DB_INSTANCE_ID}"
AUDIT_LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/audit"
ERROR_LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/error"

# ─── Helpers ──────────────────────────────────────────────────────────────────
step()  { echo; echo "=== $* ==="; }
pass()  { echo "  [PASS] $*"; }
fail()  { echo "  [FAIL] $*"; }
info()  { echo "    $*"; }

# mariadb:11 ships the 'mariadb' client; the 'mysql' symlink was dropped in
# this major. Detect once so we keep working on older mariadb images too.
MYSQL_BIN=$(docker exec "$CONTAINER" sh -c \
    'command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null' 2>/dev/null \
    || echo mariadb)

mysql_exec() {
    docker exec "$CONTAINER" \
        "$MYSQL_BIN" -u "$DB_MASTER_USER" -p"$DB_MASTER_PASS" --connect-timeout=10 -e "$1" 2>/dev/null
}

mysql_exec_db() {
    local db="$1"; shift
    docker exec "$CONTAINER" \
        "$MYSQL_BIN" -u "$DB_MASTER_USER" -p"$DB_MASTER_PASS" --connect-timeout=10 "$db" -e "$1" 2>/dev/null
}

# ─── Preflight ────────────────────────────────────────────────────────────────
step "Preflight checks"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "ERROR: container '${CONTAINER}' is not running." >&2
    echo "       Run service-rds-mariadb-dsf-setup.sh first." >&2
    exit 1
fi
pass "MariaDB container '${CONTAINER}' is running"

DB_VERSION=$(mysql_exec "SELECT VERSION();" | tail -1)
info "MariaDB version: ${DB_VERSION}"

# ─── Floci-local fixup (self-heal if setup state was lost on restart) ─────────
# Floci's stock mariadb:11 image grants the master user only on the bootstrap
# database; real AWS RDS gives ALL PRIVILEGES on *.*. Re-apply via root if the
# master user looks under-privileged so the test can run standalone.
step "Floci-local fixup: master-user privileges"

GRANTS=$(docker exec "$CONTAINER" \
    "$MYSQL_BIN" -u root -p"$DB_MASTER_PASS" -e "SHOW GRANTS FOR '${DB_MASTER_USER}'@'%';" 2>/dev/null \
    | grep -v Warning || true)
if echo "$GRANTS" | grep -q "ALL PRIVILEGES ON \*\.\*"; then
    pass "${DB_MASTER_USER} already has ALL PRIVILEGES on *.*"
else
    info "Granting ALL PRIVILEGES to ${DB_MASTER_USER}@%..."
    docker exec "$CONTAINER" \
        "$MYSQL_BIN" -u root -p"$DB_MASTER_PASS" -e "
GRANT ALL PRIVILEGES ON *.* TO '${DB_MASTER_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;" 2>&1 | grep -v Warning || true
    pass "Granted ALL PRIVILEGES to ${DB_MASTER_USER}@%"
fi

# ─── Step 1: Enable MARIADB_AUDIT_PLUGIN ──────────────────────────────────────
step "Step 1: Configure and activate MARIADB_AUDIT_PLUGIN"

# MariaDB ships with server_audit.so built-in; it can be enabled directly
PLUGIN_STATUS=$(mysql_exec "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='SERVER_AUDIT';" 2>/dev/null | tail -1 || true)
info "server_audit plugin status (before): '${PLUGIN_STATUS}'"

if [ "$PLUGIN_STATUS" = "ACTIVE" ]; then
    pass "server_audit plugin already ACTIVE"
else
    info "Attempting to install server_audit plugin..."
    mysql_exec "INSTALL SONAME 'server_audit';" 2>/dev/null || \
    mysql_exec "INSTALL PLUGIN server_audit SONAME 'server_audit.so';" 2>/dev/null || \
        info "(plugin install skipped — may already be registered or not available)"

    PLUGIN_STATUS=$(mysql_exec "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='SERVER_AUDIT';" 2>/dev/null | tail -1 || true)
    if [ "$PLUGIN_STATUS" = "ACTIVE" ]; then
        pass "server_audit plugin installed and ACTIVE"
    else
        fail "server_audit plugin not active (status: '${PLUGIN_STATUS}')"
        info "In real AWS RDS MariaDB it is managed automatically via the Option Group."
    fi
fi

# Apply audit settings if plugin is active
if [ "$PLUGIN_STATUS" = "ACTIVE" ]; then
    mysql_exec "SET GLOBAL server_audit_logging=ON;" 2>/dev/null || true
    mysql_exec "SET GLOBAL server_audit_events='CONNECT,QUERY,TABLE';" 2>/dev/null || true
    AUDIT_LOGGING=$(mysql_exec "SHOW GLOBAL VARIABLES LIKE 'server_audit_logging';" 2>/dev/null | awk '/server_audit_logging/{print $2}' || true)
    info "server_audit_logging: ${AUDIT_LOGGING}"
fi

# ─── Step 2: Generate audit events ────────────────────────────────────────────
step "Step 2: Generating audit events (DDL, DML, READ, ROLE)"

TEST_DB="audit_test_db"
TEST_TABLE="orders"

# DDL — CREATE DATABASE
mysql_exec "CREATE DATABASE IF NOT EXISTS ${TEST_DB};" 2>/dev/null || info "(database ${TEST_DB} may already exist)"
pass "DDL: CREATE DATABASE"

# DDL — CREATE TABLE
mysql_exec_db "$TEST_DB" "
    CREATE TABLE IF NOT EXISTS ${TEST_TABLE} (
        id      INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
        item    VARCHAR(64)  NOT NULL,
        amount  DECIMAL(10,2),
        created DATETIME     DEFAULT CURRENT_TIMESTAMP
    );"
pass "DDL: CREATE TABLE"

# DML — INSERT
mysql_exec_db "$TEST_DB" "
    INSERT INTO ${TEST_TABLE} (item, amount) VALUES
        ('laptop', 1299.99),
        ('keyboard', 79.00),
        ('monitor', 499.50);"
pass "DML: INSERT (3 rows)"

# READ — SELECT
ROW_COUNT=$(mysql_exec_db "$TEST_DB" "SELECT COUNT(*) FROM ${TEST_TABLE};" | tail -1)
pass "READ: SELECT COUNT(*) = ${ROW_COUNT}"

# DML — UPDATE
mysql_exec_db "$TEST_DB" "UPDATE ${TEST_TABLE} SET amount = amount * 1.10 WHERE item = 'laptop';"
pass "DML: UPDATE"

# DML — DELETE
mysql_exec_db "$TEST_DB" "DELETE FROM ${TEST_TABLE} WHERE item = 'keyboard';"
pass "DML: DELETE"

# ROLE — CREATE USER
mysql_exec "CREATE USER IF NOT EXISTS 'audit_test_reader'@'%' IDENTIFIED BY 'ReadOnly1';" 2>/dev/null || true
mysql_exec_db "$TEST_DB" "GRANT SELECT ON ${TEST_TABLE} TO 'audit_test_reader'@'%';" 2>/dev/null || true
pass "ROLE: CREATE USER + GRANT"

# DDL — intentional error (generates an audit event)
mysql_exec "SELECT no_such_column FROM no_such_table;" 2>/dev/null || true
pass "EXCEPTION: invalid query (generates audit ERROR event)"

# ─── Step 2b: Wait for log shipper to flush events to CloudWatch ──────────────
step "Step 2b: Waiting for log shipper to flush events to CloudWatch (audit log group)"

WAIT_MAX=30
WAIT_STEP=3
waited=0
EARLY_COUNT=0
info "Polling filter-log-events on ${AUDIT_LOG_GROUP} (up to ${WAIT_MAX}s)..."
while [ "$waited" -lt "$WAIT_MAX" ]; do
    EARLY_COUNT=$(aws logs filter-log-events \
        --log-group-name "$AUDIT_LOG_GROUP" \
        --filter-pattern "QUERY" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'length(events)' \
        --output text 2>/dev/null || echo 0)
    if [ "${EARLY_COUNT:-0}" -gt 0 ]; then
        pass "Log shipper flushed ${EARLY_COUNT} QUERY event(s) after ${waited}s"
        break
    fi
    sleep "$WAIT_STEP"
    waited=$((waited + WAIT_STEP))
    info "  ...${waited}s elapsed, events in CW so far: ${EARLY_COUNT:-0}"
done
if [ "${EARLY_COUNT:-0}" -eq 0 ]; then
    info "No QUERY events in CloudWatch after ${WAIT_MAX}s — sidecar may need more time"
fi

# ─── Step 3: Read audit log from inside the container ─────────────────────────
step "Step 3: Checking server_audit.log inside the container"

AUDIT_FILE=$(mysql_exec "SHOW GLOBAL VARIABLES LIKE 'server_audit_file_path';" 2>/dev/null | awk '/server_audit_file_path/{print $2}' || true)
info "server_audit_file_path: ${AUDIT_FILE:-/var/lib/mysql/server_audit.log (default)}"

# Resolve a relative path against the mariadb datadir (default /var/lib/mysql).
case "$AUDIT_FILE" in
    /*)  ;;  # already absolute
    "")  AUDIT_FILE="/var/lib/mysql/server_audit.log" ;;
    *)
        DATADIR=$(mysql_exec "SHOW GLOBAL VARIABLES LIKE 'datadir';" 2>/dev/null | awk '/datadir/{print $2}')
        AUDIT_FILE="${DATADIR:-/var/lib/mysql/}${AUDIT_FILE}"
        ;;
esac
info "Resolved audit file path: ${AUDIT_FILE}"

AUDIT_LINES=$(docker exec "$CONTAINER" sh -c "test -f ${AUDIT_FILE} && grep -c 'QUERY' ${AUDIT_FILE} 2>/dev/null || echo 0" 2>/dev/null || echo 0)
TOTAL_LINES=$(docker exec "$CONTAINER" sh -c "test -f ${AUDIT_FILE} && wc -l < ${AUDIT_FILE} || echo 0" 2>/dev/null || echo 0)

info "Total audit log lines : ${TOTAL_LINES}"
if [ "${AUDIT_LINES:-0}" -gt 0 ]; then
    pass "Found ${AUDIT_LINES} QUERY lines in server_audit.log"
    echo
    echo "  Sample audit entries:"
    docker exec "$CONTAINER" sh -c "grep 'QUERY' ${AUDIT_FILE} 2>/dev/null | tail -6" 2>/dev/null | sed 's/^/    /' || true
else
    fail "No QUERY lines found in audit log"
    info "(MariaDB Audit Plugin may not be enabled — check the Option Group)"
    info "Docker container logs as fallback:"
    docker logs "$CONTAINER" 2>&1 | grep -i "audit\|QUERY\|error" | tail -5 | sed 's/^/    /' || true
fi

# ─── Step 4: Check CloudWatch audit log streams ───────────────────────────────
step "Step 4: Checking CloudWatch audit log group '${AUDIT_LOG_GROUP}'"

check_log_group() {
    local lg="$1"
    local STREAMS EVENT_COUNT=0 STREAM_COUNT=0

    STREAMS=$(aws logs describe-log-streams \
        --log-group-name "$lg" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'logStreams[].logStreamName' \
        --output json 2>/dev/null)

    STREAM_COUNT=$(echo "$STREAMS" | jq 'length')
    info "Log streams found: ${STREAM_COUNT}"
    echo "$STREAMS" | jq -r '.[]' | sed 's/^/    - /'

    if [ "$STREAM_COUNT" -gt 0 ]; then
        pass "CloudWatch log group '${lg}' has ${STREAM_COUNT} stream(s)"

        FIRST_STREAM=$(echo "$STREAMS" | jq -r '.[0]')
        # server_audit messages can contain raw tabs/control chars that break
        # `--output json | jq`; use --output text with a list-wrapped query
        # so each event lands on its own line.
        EVENTS=$(aws logs get-log-events \
            --log-group-name "$lg" \
            --log-stream-name "$FIRST_STREAM" \
            --limit 20 \
            --endpoint-url "$AWS_ENDPOINT_URL" \
            --query 'events[*].[message]' \
            --output text 2>/dev/null)

        EVENT_COUNT=$(printf '%s\n' "$EVENTS" | grep -c . || true)
        if [ "$EVENT_COUNT" -gt 0 ]; then
            pass "CloudWatch is delivering ${EVENT_COUNT} log event(s)"
            printf '%s\n' "$EVENTS" | tail -5 | sed 's/^/    /'
        else
            fail "No events in CloudWatch stream yet"
        fi
    else
        fail "No CloudWatch log streams yet for '${lg}'"
    fi

    echo "$STREAM_COUNT $EVENT_COUNT"
}

AUDIT_RESULT=$(check_log_group "$AUDIT_LOG_GROUP")
AUDIT_STREAMS=$(echo "$AUDIT_RESULT" | tail -1 | awk '{print $1}')
AUDIT_EVENTS=$(echo "$AUDIT_RESULT" | tail -1 | awk '{print $2}')

step "Step 4b: Checking CloudWatch error log group '${ERROR_LOG_GROUP}'"
ERROR_RESULT=$(check_log_group "$ERROR_LOG_GROUP")
ERROR_STREAMS=$(echo "$ERROR_RESULT" | tail -1 | awk '{print $1}')
ERROR_EVENTS=$(echo "$ERROR_RESULT" | tail -1 | awk '{print $2}')

# ─── Step 5: Resolve log-group ARNs and query streams via ARN (DSF flow) ──────
step "Step 5: Resolve log-group ARNs via describe-log-groups, then describe streams via ARN"

# DSF discovers log groups by name prefix and then pins all subsequent calls to
# the resolved ARN (--log-group-identifier). This step mirrors that flow for
# both the audit and error log groups.

resolve_and_describe_via_arn() {
    local lg="$1"
    local arn streams count

    arn=$(aws logs describe-log-groups \
        --log-group-name-prefix "$lg" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'logGroups[0].arn' \
        --output text 2>/dev/null)

    if [ -z "$arn" ] || [ "$arn" = "None" ]; then
        fail "Could not resolve ARN for log group '${lg}' via describe-log-groups"
        echo " 0"
        return
    fi
    pass "Resolved ARN for '${lg}': ${arn}"

    streams=$(aws logs describe-log-streams \
        --log-group-identifier "$arn" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'logStreams[].logStreamName' \
        --output json 2>/dev/null)

    count=$(echo "$streams" | jq 'length' 2>/dev/null || echo 0)
    if [ "${count:-0}" -gt 0 ]; then
        pass "describe-log-streams via ARN returned ${count} stream(s) — DSF ARN flow works"
        echo "$streams" | jq -r '.[]' | sed 's/^/    - /'
    else
        fail "describe-log-streams via ARN returned 0 streams for '${lg}'"
    fi

    echo "${arn} ${count:-0}"
}

AUDIT_ARN_RESULT=$(resolve_and_describe_via_arn "$AUDIT_LOG_GROUP")
AUDIT_LOG_GROUP_ARN=$(echo "$AUDIT_ARN_RESULT" | tail -1 | awk '{print $1}')
AUDIT_ARN_STREAMS=$(echo "$AUDIT_ARN_RESULT" | tail -1 | awk '{print $2}')

ERROR_ARN_RESULT=$(resolve_and_describe_via_arn "$ERROR_LOG_GROUP")
ERROR_LOG_GROUP_ARN=$(echo "$ERROR_ARN_RESULT" | tail -1 | awk '{print $1}')
ERROR_ARN_STREAMS=$(echo "$ERROR_ARN_RESULT" | tail -1 | awk '{print $2}')

# ─── Step 6: filter-log-events (DSF Agentless Gateway uses this) ──────────────
step "Step 6: Simulating DSF audit pull via logs:FilterLogEvents"

FILTER_RESULT=$(aws logs filter-log-events \
    --log-group-name "$AUDIT_LOG_GROUP" \
    --filter-pattern "QUERY" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'events[*].[message]' \
    --output text 2>/dev/null)

FILTER_COUNT=$(printf '%s\n' "$FILTER_RESULT" | grep -c . || true)

if [ "$FILTER_COUNT" -gt 0 ]; then
    pass "filter-log-events returned ${FILTER_COUNT} QUERY event(s) — DSF pull works"
    printf '%s\n' "$FILTER_RESULT" | head -5 | sed 's/^/    /'
else
    info "filter-log-events returned 0 results (streams may still be empty in floci)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Summary"
cat <<EOF
  Container audit log    : ${AUDIT_LINES} QUERY lines in server_audit.log
  CW audit streams       : ${AUDIT_STREAMS:-0}
  CW audit events        : ${AUDIT_EVENTS:-0}
  CW error streams       : ${ERROR_STREAMS:-0}
  CW error events        : ${ERROR_EVENTS:-0}
  CW audit log-group ARN : ${AUDIT_LOG_GROUP_ARN:-<unresolved>}
  CW audit via ARN       : ${AUDIT_ARN_STREAMS:-0} streams
  CW error log-group ARN : ${ERROR_LOG_GROUP_ARN:-<unresolved>}
  CW error via ARN       : ${ERROR_ARN_STREAMS:-0} streams
  CW audit filter        : ${FILTER_COUNT} events

  Useful commands to keep polling CloudWatch:

    # List audit streams
    aws logs describe-log-streams \\
      --log-group-name "${AUDIT_LOG_GROUP}" \\
      --endpoint-url ${AWS_ENDPOINT_URL}

    # Filter audit events
    aws logs filter-log-events \\
      --log-group-name "${AUDIT_LOG_GROUP}" \\
      --filter-pattern "QUERY" \\
      --endpoint-url ${AWS_ENDPOINT_URL}

    # List error streams
    aws logs describe-log-streams \\
      --log-group-name "${ERROR_LOG_GROUP}" \\
      --endpoint-url ${AWS_ENDPOINT_URL}

    # Watch container audit log live
    docker exec ${CONTAINER} tail -f /var/lib/mysql/server_audit.log

    # DSF Gateway service (on Agentless Gateway host):
    #   systemctl status gateway-aws@mariadb.service
    #   \$JSONAR_LOGDIR/gateway/cloud/aws/mariadb/sonargateway.log

EOF
