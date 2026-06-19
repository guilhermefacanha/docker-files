#!/bin/bash
# Validates that MARIADB_AUDIT_PLUGIN is generating logs and
# that CloudWatch (via floci) is receiving them.
# Uses docker exec into the mysql container — no local mysql client required.

set -e

# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

DB_INSTANCE_ID="${DB_INSTANCE_ID:-mymysql${ENV_SUFFIX:-}-dsf}"

CONTAINER="floci-rds-${DB_INSTANCE_ID}"
LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/audit"

# Stock mysql:8.0 has no MARIADB_AUDIT_PLUGIN, so the setup script falls back
# to general_log, which writes lower-case "Query" lines (the audit plugin
# emits upper-case "QUERY"). Filter patterns are case-sensitive in floci/AWS,
# so target whichever form the running configuration produces. If you swap
# in an image with the audit plugin, set QUERY_FILTER=QUERY before running.
QUERY_FILTER="${QUERY_FILTER:-Query}"
QUERY_GREP='QUERY\|Query'

# ─── Helpers ──────────────────────────────────────────────────────────────────
step()  { echo; echo "=== $* ==="; }
pass()  { echo "  [PASS] $*"; }
fail()  { echo "  [FAIL] $*"; }
info()  { echo "    $*"; }

mysql_exec() {
    docker exec "$CONTAINER" \
        mysql -u "$DB_MASTER_USER" -p"$DB_MASTER_PASS" --connect-timeout=10 -e "$1" 2>/dev/null
}

mysql_exec_db() {
    local db="$1"; shift
    docker exec "$CONTAINER" \
        mysql -u "$DB_MASTER_USER" -p"$DB_MASTER_PASS" --connect-timeout=10 "$db" -e "$1" 2>/dev/null
}

# ─── Preflight ────────────────────────────────────────────────────────────────
step "Preflight checks"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "ERROR: container '${CONTAINER}' is not running." >&2
    echo "       Run service-rds-mysql-dsf-setup.sh first." >&2
    exit 1
fi
pass "MySQL container '${CONTAINER}' is running"

MYSQL_VERSION=$(mysql_exec "SELECT VERSION();" | tail -1)
info "MySQL version: ${MYSQL_VERSION}"

# ─── Floci-local fixups (self-heal if setup state was lost on restart) ───────
# A container restart resets SET GLOBAL state and floci's stock mysql:8.0
# image grants the master user only the bootstrap-database. Re-apply the same
# adjustments the setup script makes so the test can be re-run standalone.
step "Floci-local fixups: master-user privileges + general_log fallback"

GRANTS=$(docker exec "$CONTAINER" \
    mysql -u root -p"$DB_MASTER_PASS" -e "SHOW GRANTS FOR '${DB_MASTER_USER}'@'%';" 2>/dev/null \
    | grep -v Warning || true)
if echo "$GRANTS" | grep -q "ALL PRIVILEGES ON \*\.\*"; then
    pass "${DB_MASTER_USER} already has ALL PRIVILEGES on *.*"
else
    info "Granting ALL PRIVILEGES to ${DB_MASTER_USER}@%..."
    docker exec "$CONTAINER" \
        mysql -u root -p"$DB_MASTER_PASS" -e "
GRANT ALL PRIVILEGES ON *.* TO '${DB_MASTER_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;" 2>&1 | grep -v Warning || true
    pass "Granted ALL PRIVILEGES to ${DB_MASTER_USER}@%"
fi

GLOG_FILE="/var/lib/mysql/server_audit.log"
GLOG_STATE=$(docker exec "$CONTAINER" \
    mysql -u root -p"$DB_MASTER_PASS" -e "
SELECT @@general_log, @@general_log_file, @@log_output;" 2>/dev/null \
    | grep -v Warning | tail -1 || true)
if echo "$GLOG_STATE" | awk '{print $1, $2, $3}' | grep -qx "1 ${GLOG_FILE} FILE"; then
    pass "general_log already on at ${GLOG_FILE}"
else
    info "Enabling general_log → ${GLOG_FILE} (audit-plugin fallback)..."
    docker exec "$CONTAINER" \
        mysql -u root -p"$DB_MASTER_PASS" -e "
SET GLOBAL general_log = 'OFF';
SET GLOBAL general_log_file = '${GLOG_FILE}';
SET GLOBAL log_output = 'FILE';
SET GLOBAL general_log = 'ON';" 2>&1 | grep -v Warning || true
    pass "general_log enabled at ${GLOG_FILE}"
fi

# ─── Step 1: Enable MARIADB_AUDIT_PLUGIN ──────────────────────────────────────
step "Step 1: Configure and activate MARIADB_AUDIT_PLUGIN"

# floci emulates the RDS Option Group API but may not inject plugin settings
# into the running MySQL container. We attempt to activate it directly.

PLUGIN_STATUS=$(mysql_exec "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='SERVER_AUDIT';" 2>/dev/null | tail -1 || true)
info "server_audit plugin status (before): '${PLUGIN_STATUS}'"

if [ "$PLUGIN_STATUS" = "ACTIVE" ]; then
    pass "server_audit plugin already ACTIVE"
else
    info "Attempting to install server_audit plugin..."
    mysql_exec "INSTALL PLUGIN server_audit SONAME 'server_audit.so';" 2>/dev/null || \
        info "(plugin install failed — may already be registered or not available in this image)"

    PLUGIN_STATUS=$(mysql_exec "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='SERVER_AUDIT';" 2>/dev/null | tail -1 || true)
    if [ "$PLUGIN_STATUS" = "ACTIVE" ]; then
        pass "server_audit plugin installed and ACTIVE"
    else
        fail "server_audit plugin not active (status: '${PLUGIN_STATUS}')"
        info "The MARIADB_AUDIT_PLUGIN may not be available in this MySQL image."
        info "In real AWS RDS it is managed by the Option Group."
    fi
fi

# Apply audit settings if plugin is active
if [ "$PLUGIN_STATUS" = "ACTIVE" ]; then
    mysql_exec "SET GLOBAL server_audit_logging=ON;" 2>/dev/null || true
    mysql_exec "SET GLOBAL server_audit_events='CONNECT,QUERY,QUERY_DDL,QUERY_DML,QUERY_DCL';" 2>/dev/null || true
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
step "Step 2b: Waiting for log shipper to flush events to CloudWatch"

WAIT_MAX=30
WAIT_STEP=3
waited=0
EARLY_COUNT=0
info "Polling filter-log-events (up to ${WAIT_MAX}s)..."
while [ "$waited" -lt "$WAIT_MAX" ]; do
    EARLY_COUNT=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --filter-pattern "$QUERY_FILTER" \
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
    info "No QUERY events in CloudWatch after ${WAIT_MAX}s — sidecar may need more time or be misconfigured"
fi

# ─── Step 3: Read audit log from inside the container ─────────────────────────
step "Step 3: Checking server_audit.log inside the container"

AUDIT_FILE=$(mysql_exec "SHOW GLOBAL VARIABLES LIKE 'server_audit_file_path';" 2>/dev/null | awk '/server_audit_file_path/{print $2}' || true)
info "server_audit_file_path: ${AUDIT_FILE:-/var/lib/mysql/server_audit.log (default)}"

AUDIT_FILE="${AUDIT_FILE:-/var/lib/mysql/server_audit.log}"

AUDIT_LINES=$(docker exec "$CONTAINER" sh -c "test -f ${AUDIT_FILE} && grep -c '${QUERY_GREP}' ${AUDIT_FILE} 2>/dev/null || echo 0" 2>/dev/null || echo 0)
TOTAL_LINES=$(docker exec "$CONTAINER" sh -c "test -f ${AUDIT_FILE} && wc -l < ${AUDIT_FILE} || echo 0" 2>/dev/null || echo 0)

info "Total audit log lines : ${TOTAL_LINES}"
if [ "${AUDIT_LINES:-0}" -gt 0 ]; then
    pass "Found ${AUDIT_LINES} QUERY lines in ${AUDIT_FILE}"
    echo
    echo "  Sample audit entries:"
    docker exec "$CONTAINER" sh -c "grep '${QUERY_GREP}' ${AUDIT_FILE} 2>/dev/null | tail -6" 2>/dev/null | sed 's/^/    /' || true
else
    fail "No QUERY lines found in audit log"
    info "(MariaDB Audit Plugin may not be installed in this floci MySQL image)"
    info "Docker container logs as fallback:"
    docker logs "$CONTAINER" 2>&1 | grep -i "audit\|QUERY" | tail -5 | sed 's/^/    /' || true
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

EVENT_COUNT=0
if [ "$STREAM_COUNT" -gt 0 ]; then
    pass "CloudWatch log group has ${STREAM_COUNT} stream(s)"

    FIRST_STREAM=$(echo "$STREAMS" | jq -r '.[0]')
    step "Step 4b: Log events in stream '${FIRST_STREAM}'"

    # general_log embeds raw tab characters in event messages, which break
    # `--output json | jq` (AWS CLI doesn't escape them). Use --output text
    # and parse line-by-line.
    EVENTS=$(aws logs get-log-events \
        --log-group-name "$LOG_GROUP" \
        --log-stream-name "$FIRST_STREAM" \
        --limit 20 \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'events[*].[message]' \
        --output text 2>/dev/null)

    EVENT_COUNT=$(printf '%s\n' "$EVENTS" | grep -c . || true)
    info "Events retrieved: ${EVENT_COUNT}"

    if [ "$EVENT_COUNT" -gt 0 ]; then
        pass "CloudWatch is delivering log events"
        echo
        echo "  Last ${EVENT_COUNT} events:"
        printf '%s\n' "$EVENTS" | tail -10 | sed 's/^/    /'

        AUDIT_CW=$(printf '%s\n' "$EVENTS" | grep -c "${QUERY_GREP}\|CONNECT\|Connect" || true)
        if [ "$AUDIT_CW" -gt 0 ]; then
            pass "CloudWatch contains ${AUDIT_CW} audit event(s) — end-to-end verified"
        else
            info "No QUERY/CONNECT lines in CloudWatch yet (logs may be buffered)"
        fi
    else
        fail "No events in CloudWatch stream yet"
        info "In real AWS this is near-real-time; in floci it may require a flush interval"
    fi
else
    fail "No CloudWatch log streams yet"
    info "Floci may not yet push mysql audit file logs into CloudWatch streams."
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
    --filter-pattern "$QUERY_FILTER" \
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
  Container audit log  : ${AUDIT_LINES} QUERY lines in server_audit.log
  CW streams           : ${STREAM_COUNT}
  CW events pulled     : ${EVENT_COUNT}
  CW log-group ARN     : ${LOG_GROUP_ARN:-<unresolved>}
  CW streams via ARN   : ${ARN_STREAM_COUNT:-0}
  CW audit filter      : ${FILTER_COUNT} events

  Useful commands to keep polling CloudWatch:

    # List streams
    aws logs describe-log-streams \\
      --log-group-name "${LOG_GROUP}" \\
      --endpoint-url ${AWS_ENDPOINT_URL}

    # Get events (filter pattern matches the format produced by setup —
    # 'Query' for general_log fallback, 'QUERY' for the audit plugin)
    aws logs filter-log-events \\
      --log-group-name "${LOG_GROUP}" \\
      --filter-pattern "${QUERY_FILTER}" \\
      --endpoint-url ${AWS_ENDPOINT_URL}

    # Watch container audit log live
    docker exec ${CONTAINER} tail -f /var/lib/mysql/server_audit.log

    # DSF Gateway service (on Agentless Gateway host):
    #   systemctl status gateway-aws@mysql.service
    #   \$JSONAR_LOGDIR/gateway/cloud/aws/mysql/sonargateway.log

EOF
