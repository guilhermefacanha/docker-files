#!/bin/bash
# DSF Hub onboarding: Amazon RDS for MariaDB via CloudWatch
# Follows: Thales DSF Hub Reference Guide (3 June 2026)
# Covers Steps 1-2 (AWS CLI path) + CloudWatch log group setup
# Audit: MARIADB_AUDIT_PLUGIN via Option Group
# CloudWatch exports both "audit" and "error" log types

set -e

# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
RUN_TEST=0
for _arg in "$@"; do [ "$_arg" = "--test" ] && RUN_TEST=1; done; unset _arg
_s="$(basename "${BASH_SOURCE[0]}")"; _e="${_s#service-rds-}"; _e="${_e%%-*}"
TEST_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/service-rds-${_e}-test-audit-cloudwatch.sh"
unset _s _e

# ─── Engine-specific configuration ────────────────────────────────────────────
DB_INSTANCE_ID="${DB_INSTANCE_ID:-mymariadb${ENV_SUFFIX:-}-dsf}"

MARIADB_MAJOR_VERSION="${MARIADB_MAJOR_VERSION:-10.6}"
OPTION_GROUP_NAME="${OPTION_GROUP_NAME:-dsf-mariadb-audit-options}"
OPTION_GROUP_DESC="DSF Hub audit option group for MariaDB ${MARIADB_MAJOR_VERSION}"

CLOUDWATCH_AUDIT_LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/audit"
CLOUDWATCH_ERROR_LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/error"

# ─── Helpers ──────────────────────────────────────────────────────────────────
step() { echo; echo "=== $* ==="; }
info() { echo "    $*"; }

wait_for_available() {
    local id="$1" status tries=0 max=30
    info "Waiting for instance '$id' to become available..."
    while [ "$tries" -lt "$max" ]; do
        status=$(aws rds describe-db-instances \
            --db-instance-identifier "$id" \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text \
            --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null || echo "creating")
        [ "$status" = "available" ] && return 0
        tries=$((tries + 1))
        sleep 2
    done
    echo "ERROR: instance '$id' did not become available in time (status: $status)" >&2
    exit 1
}

# ─── STEP 1: Create RDS MariaDB instance ──────────────────────────────────────
step "STEP 1: Creating MariaDB RDS instance '$DB_INSTANCE_ID'"

if aws rds describe-db-instances \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'DBInstances[0].DBInstanceIdentifier' \
        --output text 2>/dev/null | grep -q "$DB_INSTANCE_ID"; then
    info "Instance already exists, skipping creation."
else
    aws rds create-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --db-instance-class "$DB_CLASS" \
        --engine mariadb \
        --master-username "$DB_MASTER_USER" \
        --master-user-password "$DB_MASTER_PASS" \
        --allocated-storage "$ALLOCATED_STORAGE" \
        --endpoint-url "$AWS_ENDPOINT_URL"
fi

wait_for_available "$DB_INSTANCE_ID"

ENDPOINT_JSON=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query 'DBInstances[0].Endpoint' \
    --output json \
    --endpoint-url "$AWS_ENDPOINT_URL")

RDS_ADDRESS=$(echo "$ENDPOINT_JSON" | jq -r '.Address')
RDS_PORT=$(echo "$ENDPOINT_JSON" | jq -r '.Port')
info "Endpoint: ${RDS_ADDRESS}:${RDS_PORT}"

# ─── STEP 1b: Floci-local fixup — grant master user full privileges ───────────
# Real AWS RDS gives the master user ALL PRIVILEGES on *.*. Floci's stock
# mariadb:11 image only grants admin privileges on the bootstrap database,
# so DDL/DML in audit_test_db would fail. Connect as root via the unix
# socket and align the master user with real-AWS behavior.
CONTAINER="floci-rds-${DB_INSTANCE_ID}"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    step "STEP 1b: Granting master user full privileges (floci-local emulation)"
    # mariadb:11 ships the 'mariadb' client; the 'mysql' symlink was dropped.
    docker exec "$CONTAINER" \
        mariadb -u root -p"$DB_MASTER_PASS" -e "
GRANT ALL PRIVILEGES ON *.* TO '${DB_MASTER_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;" 2>&1 | grep -v "Warning" || true
    info "Granted ALL PRIVILEGES to ${DB_MASTER_USER}@%"
else
    info "WARNING: container ${CONTAINER} not visible to docker — skipping master-grant fixup."
fi

# ─── STEP 2a: Create Option Group ─────────────────────────────────────────────
step "STEP 2a: Creating Option Group '$OPTION_GROUP_NAME' (mariadb ${MARIADB_MAJOR_VERSION})"

OPTION_GROUPS_SUPPORTED=1

if aws rds describe-option-groups \
        --option-group-name "$OPTION_GROUP_NAME" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'OptionGroupsList[0].OptionGroupName' \
        --output text 2>/dev/null | grep -q "$OPTION_GROUP_NAME"; then
    info "Option group already exists, skipping creation."
else
    CREATE_OG_ERR=$(aws rds create-option-group \
        --option-group-name "$OPTION_GROUP_NAME" \
        --engine-name mariadb \
        --major-engine-version "$MARIADB_MAJOR_VERSION" \
        --option-group-description "$OPTION_GROUP_DESC" \
        --endpoint-url "$AWS_ENDPOINT_URL" 2>&1) || {
        if echo "$CREATE_OG_ERR" | grep -q "UnsupportedOperation"; then
            info "WARNING: Option Groups are not supported by this endpoint (floci/LocalStack)."
            info "         Skipping steps 2a-2c. mariadb:11 ships server_audit.so so the"
            info "         test script can still activate the plugin directly via SQL."
            OPTION_GROUPS_SUPPORTED=0
        else
            echo "$CREATE_OG_ERR" >&2
            exit 1
        fi
    }
fi

if [ "$OPTION_GROUPS_SUPPORTED" -eq 1 ]; then
    # ─── STEP 2b: Add MARIADB_AUDIT_PLUGIN to Option Group ────────────────────
    # CONNECT events are always logged regardless of SERVER_AUDIT_EXCL_USERS
    step "STEP 2b: Adding MARIADB_AUDIT_PLUGIN to Option Group"
    info "SERVER_AUDIT_EVENTS      : CONNECT,QUERY,TABLE"
    info "SERVER_AUDIT_EXCL_USERS  : rdsadmin"

    aws rds add-option-to-option-group \
        --option-group-name "$OPTION_GROUP_NAME" \
        --options '[{"OptionName":"MARIADB_AUDIT_PLUGIN","OptionSettings":[{"Name":"SERVER_AUDIT_EVENTS","Value":"CONNECT,QUERY,TABLE"},{"Name":"SERVER_AUDIT_EXCL_USERS","Value":"rdsadmin"}]}]' \
        --apply-immediately \
        --endpoint-url "$AWS_ENDPOINT_URL"

    # ─── STEP 2c: Attach Option Group + enable CloudWatch audit+error log exports ─
    # MariaDB requires both "error" and "audit" log types to be exported
    step "STEP 2c: Attaching option group and enabling CloudWatch log exports (audit + error)"

    aws rds modify-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --option-group-name "$OPTION_GROUP_NAME" \
        --cloudwatch-logs-export-configuration '{"EnableLogTypes":["error","audit"]}' \
        --apply-immediately \
        --endpoint-url "$AWS_ENDPOINT_URL"
else
    step "STEP 2c: Enabling CloudWatch audit+error log export (option group skipped)"
    aws rds modify-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --cloudwatch-logs-export-configuration '{"EnableLogTypes":["error","audit"]}' \
        --apply-immediately \
        --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null \
        || info "WARNING: modify-db-instance log export not supported either; continuing."
fi

# ─── STEP 3: CloudWatch log group retention ───────────────────────────────────
step "STEP 3: Setting CloudWatch log retention to ${LOG_RETENTION_DAYS} days"
info "Audit log group : ${CLOUDWATCH_AUDIT_LOG_GROUP}"
info "Error log group : ${CLOUDWATCH_ERROR_LOG_GROUP}"

for LOG_GROUP in "$CLOUDWATCH_AUDIT_LOG_GROUP" "$CLOUDWATCH_ERROR_LOG_GROUP"; do
    aws logs create-log-group \
        --log-group-name "$LOG_GROUP" \
        --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null || true

    aws logs put-retention-policy \
        --log-group-name "$LOG_GROUP" \
        --retention-in-days "$LOG_RETENTION_DAYS" \
        --endpoint-url "$AWS_ENDPOINT_URL"
done

# Verify log groups visible (required by DSF Discovery: logs:DescribeLogGroups)
aws logs describe-log-groups \
    --log-group-name-prefix "/aws/rds/instance/${DB_INSTANCE_ID}" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'logGroups[].logGroupName' \
    --output table

# ─── STEP 4: Create audit management user via mariadb client ──────────────────
step "STEP 4: Creating audit management user '${AUDIT_MGR_USER}'"

if [ -n "$CONTAINER" ] && docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    info "Connecting via docker exec into ${CONTAINER}..."
    docker exec "$CONTAINER" \
        mariadb -u root -p"$DB_MASTER_PASS" --connect-timeout=10 -e "
CREATE USER IF NOT EXISTS '${AUDIT_MGR_USER}'@'%' IDENTIFIED BY '${AUDIT_MGR_PASS}';
GRANT SELECT, PROCESS, SHOW DATABASES, REPLICATION CLIENT ON *.* TO '${AUDIT_MGR_USER}'@'%';
FLUSH PRIVILEGES;
SELECT user, host FROM mysql.user WHERE user='${AUDIT_MGR_USER}';" 2>&1 | grep -v "Warning" || true
else
    echo
    echo "  Container ${CONTAINER:-<unknown>} not visible — complete these steps manually by"
    echo "  connecting to ${RDS_ADDRESS}:${RDS_PORT} as ${DB_MASTER_USER}:"
    echo
    echo "    CREATE USER IF NOT EXISTS '${AUDIT_MGR_USER}'@'%' IDENTIFIED BY '${AUDIT_MGR_PASS}';"
    echo "    GRANT SELECT, PROCESS, SHOW DATABASES, REPLICATION CLIENT ON *.* TO '${AUDIT_MGR_USER}'@'%';"
    echo "    FLUSH PRIVILEGES;"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Setup complete — DSF Hub asset hierarchy"
cat <<EOF

  AWS Cloud Account asset
    └── RDS MariaDB Instance asset
          DB identifier : ${DB_INSTANCE_ID}
          Endpoint      : ${RDS_ADDRESS}:${RDS_PORT}
          Engine        : mariadb ${MARIADB_MAJOR_VERSION}
          Option group  : ${OPTION_GROUP_NAME}
          ├── AWS Log Group asset (audit)
          │     Audit log group : ${CLOUDWATCH_AUDIT_LOG_GROUP}
          │     Retention       : ${LOG_RETENTION_DAYS} days
          └── AWS Log Group asset (error)
                Error log group : ${CLOUDWATCH_ERROR_LOG_GROUP}
                Retention       : ${LOG_RETENTION_DAYS} days

  Required IAM permissions for DSF Agentless Gateway:
    logs:DescribeLogGroups
    logs:DescribeLogStreams
    logs:FilterLogEvents
    logs:GetLogEvents
    rds:DescribeDBInstances
    rds:DescribeOptionGroups

  DSF Gateway service (Agentless Gateway host):
    gateway-aws@mariadb.service
    Log: \$JSONAR_LOGDIR/gateway/cloud/aws/mariadb/sonargateway.log

  CloudWatch log streams (once audit plugin is active):
    /aws/rds/instance/${DB_INSTANCE_ID}/audit
    /aws/rds/instance/${DB_INSTANCE_ID}/error

EOF

if [ "$RUN_TEST" -eq 1 ]; then
    echo
    echo "=== --test: running $(basename "$TEST_SCRIPT") ==="
    bash "$TEST_SCRIPT"
fi
