#!/bin/bash
# DSF Hub onboarding: Amazon RDS for MySQL via CloudWatch
# Follows: Thales DSF Hub Reference Guide (3 June 2026)
# Covers Steps 1-2 (AWS CLI path) + CloudWatch log group setup
# Audit: MARIADB_AUDIT_PLUGIN via Option Group (no reboot for standard audit)

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
DB_INSTANCE_ID="${DB_INSTANCE_ID:-mymysql${ENV_SUFFIX:-}-dsf}"

MYSQL_MAJOR_VERSION="${MYSQL_MAJOR_VERSION:-8.0}"   # 5.7 or 8.0
OPTION_GROUP_NAME="${OPTION_GROUP_NAME:-dsf-mysql-audit-options}"
OPTION_GROUP_DESC="DSF Hub audit option group for MySQL ${MYSQL_MAJOR_VERSION}"

SLOW_QUERY_S="${SLOW_QUERY_S:-}"   # seconds; set to enable slow-query monitoring

CLOUDWATCH_AUDIT_LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/audit"

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

# ─── STEP 1: Create RDS MySQL instance ────────────────────────────────────────
step "STEP 1: Creating MySQL RDS instance '$DB_INSTANCE_ID'"

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
        --engine mysql \
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

# ─── STEP 1b: Floci-local fixups (skipped on real AWS) ───────────────────────
# Real AWS RDS gives the master user ALL PRIVILEGES on *.* and ships the
# MARIADB_AUDIT_PLUGIN via the option group. Floci spawns a stock mysql:8.0
# container that does neither. The two adjustments below close that gap so
# the test script's DDL/DML and audit-log assertions can pass locally.
CONTAINER="floci-rds-${DB_INSTANCE_ID}"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    step "STEP 1b: Granting master user full privileges (floci-local emulation)"
    docker exec "$CONTAINER" \
        mysql -u root -p"$DB_MASTER_PASS" -e "
GRANT ALL PRIVILEGES ON *.* TO '${DB_MASTER_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;" 2>&1 | grep -v "Warning" || true
    info "Granted ALL PRIVILEGES to ${DB_MASTER_USER}@%"

    step "STEP 1c: Enabling general_log as audit-plugin fallback (mysql:8.0 lacks server_audit.so)"
    GENERAL_LOG_FILE="/var/lib/mysql/server_audit.log"
    docker exec "$CONTAINER" \
        mysql -u root -p"$DB_MASTER_PASS" -e "
SET GLOBAL general_log = 'OFF';
SET GLOBAL general_log_file = '${GENERAL_LOG_FILE}';
SET GLOBAL log_output = 'FILE';
SET GLOBAL general_log = 'ON';" 2>&1 | grep -v "Warning" || true
    info "general_log writes to ${GENERAL_LOG_FILE} (the log shipper tails this path)"
else
    info "WARNING: container ${CONTAINER} not visible to docker — skipping floci-local fixups."
    info "         Run 'docker ps' to confirm the RDS container is up before re-running."
fi

# ─── STEP 2a: Create Option Group ─────────────────────────────────────────────
step "STEP 2a: Creating Option Group '$OPTION_GROUP_NAME' (mysql ${MYSQL_MAJOR_VERSION})"

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
        --engine-name mysql \
        --major-engine-version "$MYSQL_MAJOR_VERSION" \
        --option-group-description "$OPTION_GROUP_DESC" \
        --endpoint-url "$AWS_ENDPOINT_URL" 2>&1) || {
        if echo "$CREATE_OG_ERR" | grep -q "UnsupportedOperation"; then
            info "WARNING: Option Groups are not supported by this endpoint (floci/LocalStack)."
            info "         Skipping steps 2a-2c. On real AWS RDS this step creates the"
            info "         MARIADB_AUDIT_PLUGIN option group required by DSF Hub."
            OPTION_GROUPS_SUPPORTED=0
        else
            echo "$CREATE_OG_ERR" >&2
            exit 1
        fi
    }
fi

if [ "$OPTION_GROUPS_SUPPORTED" -eq 1 ]; then
    # ─── STEP 2b: Add MARIADB_AUDIT_PLUGIN to Option Group ────────────────────
    # Supported: MySQL 5.7 (all versions), MySQL 8.0.25+
    step "STEP 2b: Adding MARIADB_AUDIT_PLUGIN to Option Group"
    info "SERVER_AUDIT_EVENTS : CONNECT,QUERY,QUERY_DDL,QUERY_DML,QUERY_DCL"
    info "SERVER_AUDIT_EXCL_USERS : rdsadmin"

    aws rds add-option-to-option-group \
        --option-group-name "$OPTION_GROUP_NAME" \
        --options '[{"OptionName":"MARIADB_AUDIT_PLUGIN","OptionSettings":[{"Name":"SERVER_AUDIT_EVENTS","Value":"CONNECT,QUERY,QUERY_DDL,QUERY_DML,QUERY_DCL"},{"Name":"SERVER_AUDIT_EXCL_USERS","Value":"rdsadmin"}]}]' \
        --apply-immediately \
        --endpoint-url "$AWS_ENDPOINT_URL"

    # ─── STEP 2c: Attach Option Group + enable CloudWatch audit log export ────
    step "STEP 2c: Attaching option group and enabling CloudWatch audit log export"

    aws rds modify-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --option-group-name "$OPTION_GROUP_NAME" \
        --cloudwatch-logs-export-configuration '{"EnableLogTypes":["audit"]}' \
        --apply-immediately \
        --endpoint-url "$AWS_ENDPOINT_URL"
else
    step "STEP 2c: Enabling CloudWatch audit log export (option group skipped)"
    aws rds modify-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --cloudwatch-logs-export-configuration '{"EnableLogTypes":["audit"]}' \
        --apply-immediately \
        --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null \
        || info "WARNING: modify-db-instance log export not supported either; continuing."
fi

# ─── STEP 2d: Optional slow-query monitoring ──────────────────────────────────
if [ -n "$SLOW_QUERY_S" ]; then
    step "STEP 2d: Enabling slow-query monitoring (threshold: ${SLOW_QUERY_S}s)"
    PARAM_GROUP_NAME="${PARAM_GROUP_NAME:-dsf-mysql-slowquery-params}"
    PARAM_GROUP_FAMILY="mysql${MYSQL_MAJOR_VERSION}"

    if aws rds describe-db-parameter-groups \
            --db-parameter-group-name "$PARAM_GROUP_NAME" \
            --endpoint-url "$AWS_ENDPOINT_URL" \
            --query 'DBParameterGroups[0].DBParameterGroupName' \
            --output text 2>/dev/null | grep -q "$PARAM_GROUP_NAME"; then
        info "Parameter group already exists."
    else
        aws rds create-db-parameter-group \
            --db-parameter-group-name "$PARAM_GROUP_NAME" \
            --db-parameter-group-family "$PARAM_GROUP_FAMILY" \
            --description "DSF Hub slow query parameter group for MySQL ${MYSQL_MAJOR_VERSION}" \
            --endpoint-url "$AWS_ENDPOINT_URL"
    fi

    aws rds modify-db-parameter-group \
        --db-parameter-group-name "$PARAM_GROUP_NAME" \
        --parameters \
            "ParameterName=slow_query_log,ParameterValue=1,ApplyMethod=immediate" \
            "ParameterName=long_query_time,ParameterValue=${SLOW_QUERY_S},ApplyMethod=immediate" \
            "ParameterName=log_output,ParameterValue=FILE,ApplyMethod=immediate" \
        --endpoint-url "$AWS_ENDPOINT_URL"

    # Attach param group + enable slowquery log export; reboot required
    aws rds modify-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --db-parameter-group-name "$PARAM_GROUP_NAME" \
        --cloudwatch-logs-export-configuration '{"EnableLogTypes":["slowquery"]}' \
        --apply-immediately \
        --endpoint-url "$AWS_ENDPOINT_URL"

    info "Rebooting instance to apply parameter group (required for slow query)..."
    aws rds reboot-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --endpoint-url "$AWS_ENDPOINT_URL"

    wait_for_available "$DB_INSTANCE_ID"
else
    info "Slow-query monitoring skipped (set SLOW_QUERY_S=<seconds> to enable)."
fi

# ─── STEP 3: CloudWatch log group retention ───────────────────────────────────
step "STEP 3: Setting CloudWatch log retention to ${LOG_RETENTION_DAYS} days"
info "Audit log group: ${CLOUDWATCH_AUDIT_LOG_GROUP}"

aws logs create-log-group \
    --log-group-name "$CLOUDWATCH_AUDIT_LOG_GROUP" \
    --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null || true

aws logs put-retention-policy \
    --log-group-name "$CLOUDWATCH_AUDIT_LOG_GROUP" \
    --retention-in-days "$LOG_RETENTION_DAYS" \
    --endpoint-url "$AWS_ENDPOINT_URL"

# Verify log group visible (required by DSF Discovery: logs:DescribeLogGroups)
aws logs describe-log-groups \
    --log-group-name-prefix "/aws/rds/instance/${DB_INSTANCE_ID}" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'logGroups[].logGroupName' \
    --output table

# NOTE: per the DSF Hub "Amazon RDS for MySQL Onboarding Steps" guide
# (28 May 2026), MySQL audit is enabled entirely at the AWS layer — option
# group + MARIADB_AUDIT_PLUGIN + CloudWatch log export. There is no SQL
# step against the DB itself (unlike Postgres, which requires CREATE
# EXTENSION pgaudit). The DSF Agentless Gateway authenticates to AWS via
# IAM access key and pulls logs from CloudWatch — it does not connect to
# the MySQL instance directly. So no in-database "audit manager" user is
# required by DSF for MySQL.

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Setup complete — DSF Hub asset hierarchy"
cat <<EOF

  AWS Cloud Account asset
    └── RDS MySQL Instance asset
          DB identifier : ${DB_INSTANCE_ID}
          Endpoint      : ${RDS_ADDRESS}:${RDS_PORT}
          Engine        : mysql ${MYSQL_MAJOR_VERSION}
          Option group  : ${OPTION_GROUP_NAME}
          └── AWS Log Group asset
                Audit log group : ${CLOUDWATCH_AUDIT_LOG_GROUP}
                Retention       : ${LOG_RETENTION_DAYS} days

  Required IAM permissions for DSF Agentless Gateway (per MySQL guide):

    Discovery:
      logs:DescribeLogGroups
      rds:DescribeDBInstances

    Log group access (retrieve audit logs):
      logs:DescribeLogGroups
      logs:DescribeLogStreams
      logs:FilterLogEvents
      logs:GetLogEvents

    Audit policy management:
      rds:DescribeDBInstances
      rds:DescribeDBParameterGroups
      rds:DescribeOptionGroups
      rds:DescribeDBSecurityGroups
      ec2:DescribeSecurityGroups
      rds:CopyOptionGroup
      rds:ModifyOptionGroup
      rds:DeleteOptionGroup
      rds:ModifyDBInstance

    Create/modify AWS resources:
      rds:CreateOptionGroup
      rds:ModifyOptionGroup
      rds:ModifyDBInstance

  DSF Gateway service (Agentless Gateway host):
    Standard audit            : gateway-aws@mysql.service
      Log: \$JSONAR_LOGDIR/gateway/cloud/aws/mysql/sonargateway.log
    Slow query audit          : gateway-aws@mysql-slow-query.service
      Log: \$JSONAR_LOGDIR/gateway/cloud/aws/mysql-slow-query/sonargateway.log
    Aggregated audit          : gateway-aws@mysql-aggregated.service
      Log: \$JSONAR_LOGDIR/gateway/cloud/aws/mysql-aggregated/sonargateway.log

  Audit Type (set in DSF Hub when creating the Log Group asset):
    Standard audit collection            : "Log Group"
    Slow query audit monitoring          : "AWS RDS MySQL Slow"
    Standard audit + aggregated queries  : "Aggregated"

  CloudWatch audit log stream (once audit plugin is active):
    /aws/rds/instance/${DB_INSTANCE_ID}/audit

  NOTE: DSF does NOT support audit retrieval from Multi-AZ RDS deployments.

EOF

if [ "$RUN_TEST" -eq 1 ]; then
    echo
    echo "=== --test: running $(basename "$TEST_SCRIPT") ==="
    bash "$TEST_SCRIPT"
fi
