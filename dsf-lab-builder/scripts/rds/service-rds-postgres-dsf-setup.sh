#!/bin/bash
# DSF Hub onboarding: Amazon RDS for PostgreSQL via CloudWatch
# Follows: Thales DSF Hub Reference Guide (2 June 2026)
# Covers Steps 1-2 (AWS CLI path) + CloudWatch log group setup + pgaudit extension

set -e

# Shared defaults (AWS endpoint/creds, DB master user/pass, retention, etc.)
# come from rds/00-env.sh. Override anything via floci-local-aws/.env, or
# inline `VAR=value sh service-rds-postgres-dsf-setup.sh`.
# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────
RUN_TEST=0
for _arg in "$@"; do [ "$_arg" = "--test" ] && RUN_TEST=1; done; unset _arg
_s="$(basename "${BASH_SOURCE[0]}")"; _e="${_s#service-rds-}"; _e="${_e%%-*}"
TEST_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/service-rds-${_e}-test-audit-cloudwatch.sh"
unset _s _e

# ─── Engine-specific configuration ────────────────────────────────────────────
DB_INSTANCE_ID="${DB_INSTANCE_ID:-mypostgres${ENV_SUFFIX:-}-dsf}"

PG_MAJOR_VERSION="${PG_MAJOR_VERSION:-16}"     # drives param group family + log_connections value
PARAM_GROUP_NAME="${PARAM_GROUP_NAME:-dsf-postgres-audit-params}"
PARAM_GROUP_DESC="DSF Hub audit parameter group for PostgreSQL ${PG_MAJOR_VERSION}"

SLOW_QUERY_MS="${SLOW_QUERY_MS:-}"             # set to a number (ms) to enable slow-query monitoring

CLOUDWATCH_LOG_GROUP="/aws/rds/instance/${DB_INSTANCE_ID}/postgresql"

# ─── log_connections value differs by PG version (< 18 → 1; ≥ 18 → enum) ────
if [ "$PG_MAJOR_VERSION" -ge 18 ] 2>/dev/null; then
    LOG_CONNECTIONS_VALUE="receipt,authentication,authorization"
else
    LOG_CONNECTIONS_VALUE="1"
fi

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

# ─── STEP 1: Create RDS PostgreSQL instance ───────────────────────────────────
step "STEP 1: Creating PostgreSQL RDS instance '$DB_INSTANCE_ID'"

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
        --engine postgres \
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

# ─── STEP 2a: Create DB parameter group ──────────────────────────────────────
step "STEP 2a: Creating DB parameter group '$PARAM_GROUP_NAME'"

if aws rds describe-db-parameter-groups \
        --db-parameter-group-name "$PARAM_GROUP_NAME" \
        --endpoint-url "$AWS_ENDPOINT_URL" \
        --query 'DBParameterGroups[0].DBParameterGroupName' \
        --output text 2>/dev/null | grep -q "$PARAM_GROUP_NAME"; then
    info "Parameter group already exists, skipping creation."
else
    aws rds create-db-parameter-group \
        --db-parameter-group-name "$PARAM_GROUP_NAME" \
        --db-parameter-group-family "postgres${PG_MAJOR_VERSION}" \
        --description "$PARAM_GROUP_DESC" \
        --endpoint-url "$AWS_ENDPOINT_URL"
fi

# ─── STEP 2b: Set required audit parameters ───────────────────────────────────
step "STEP 2b: Configuring audit parameters (PostgreSQL ${PG_MAJOR_VERSION})"
info "log_connections value: ${LOG_CONNECTIONS_VALUE}"

aws rds modify-db-parameter-group \
    --db-parameter-group-name "$PARAM_GROUP_NAME" \
    --parameters \
        "ParameterName=shared_preload_libraries,ParameterValue=pgaudit,ApplyMethod=pending-reboot" \
        "ParameterName=pgaudit.log,ParameterValue=all,ApplyMethod=immediate" \
        "ParameterName=log_connections,ParameterValue=${LOG_CONNECTIONS_VALUE},ApplyMethod=immediate" \
        "ParameterName=log_disconnections,ParameterValue=1,ApplyMethod=immediate" \
        "ParameterName=log_error_verbosity,ParameterValue=verbose,ApplyMethod=immediate" \
    --endpoint-url "$AWS_ENDPOINT_URL"

# ─── STEP 2c: Optional slow-query monitoring ──────────────────────────────────
if [ -n "$SLOW_QUERY_MS" ]; then
    step "STEP 2c: Enabling slow-query monitoring (threshold: ${SLOW_QUERY_MS} ms)"
    # log_statement must be 'none' and log_duration must be 0 for correct ingestion
    aws rds modify-db-parameter-group \
        --db-parameter-group-name "$PARAM_GROUP_NAME" \
        --parameters \
            "ParameterName=log_min_duration_statement,ParameterValue=${SLOW_QUERY_MS},ApplyMethod=immediate" \
            "ParameterName=log_statement,ParameterValue=none,ApplyMethod=immediate" \
            "ParameterName=log_duration,ParameterValue=0,ApplyMethod=immediate" \
        --endpoint-url "$AWS_ENDPOINT_URL"
else
    info "Slow-query monitoring skipped (set SLOW_QUERY_MS=<ms> to enable)."
fi

# ─── STEP 2d: Attach parameter group + enable CloudWatch log export ───────────
step "STEP 2d: Attaching parameter group and enabling CloudWatch log export"

aws rds modify-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --db-parameter-group-name "$PARAM_GROUP_NAME" \
    --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql"]}' \
    --apply-immediately \
    --endpoint-url "$AWS_ENDPOINT_URL"

# ─── STEP 2e: Reboot to load shared_preload_libraries (pgaudit) ───────────────
step "STEP 2e: Rebooting instance to apply shared_preload_libraries"

aws rds reboot-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --endpoint-url "$AWS_ENDPOINT_URL"

wait_for_available "$DB_INSTANCE_ID"

# ─── STEP 3: CloudWatch log group retention ───────────────────────────────────
step "STEP 3: Setting CloudWatch log retention to ${LOG_RETENTION_DAYS} days"
info "Log group: ${CLOUDWATCH_LOG_GROUP}"

# Create the log group if floci hasn't auto-created it yet
aws logs create-log-group \
    --log-group-name "$CLOUDWATCH_LOG_GROUP" \
    --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null || true

aws logs put-retention-policy \
    --log-group-name "$CLOUDWATCH_LOG_GROUP" \
    --retention-in-days "$LOG_RETENTION_DAYS" \
    --endpoint-url "$AWS_ENDPOINT_URL"

# Verify the log group is visible (required by DSF Discovery: logs:DescribeLogGroups)
aws logs describe-log-groups \
    --log-group-name-prefix "/aws/rds/instance/${DB_INSTANCE_ID}" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'logGroups[].logGroupName' \
    --output table

# ─── STEP 4: Create pgaudit extension via psql ────────────────────────────────
step "STEP 4: Creating pgaudit extension on the PostgreSQL instance"

if command -v psql >/dev/null 2>&1; then
    info "Connecting to ${RDS_ADDRESS}:${RDS_PORT} as ${DB_MASTER_USER}..."
    PGPASSWORD="$DB_MASTER_PASS" psql \
        -h "$RDS_ADDRESS" \
        -p "$RDS_PORT" \
        -U "$DB_MASTER_USER" \
        -d postgres \
        -c "CREATE EXTENSION IF NOT EXISTS pgaudit;" \
        -c "SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name = 'pgaudit';"

    # ─── STEP 4b: Optional audit management user ──────────────────────────────
    step "STEP 4b: Creating audit management user '${AUDIT_MGR_USER}'"
    PGPASSWORD="$DB_MASTER_PASS" psql \
        -h "$RDS_ADDRESS" \
        -p "$RDS_PORT" \
        -U "$DB_MASTER_USER" \
        -d postgres \
        -c "DO \$\$
            BEGIN
              -- rds_superuser is an AWS RDS built-in role; create it locally if absent
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rds_superuser') THEN
                CREATE ROLE rds_superuser;
              END IF;
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${AUDIT_MGR_USER}') THEN
                CREATE USER ${AUDIT_MGR_USER} WITH PASSWORD '${AUDIT_MGR_PASS}';
                GRANT rds_superuser TO ${AUDIT_MGR_USER};
                ALTER USER ${AUDIT_MGR_USER} WITH CREATEROLE;
                RAISE NOTICE 'User ${AUDIT_MGR_USER} created.';
              ELSE
                RAISE NOTICE 'User ${AUDIT_MGR_USER} already exists, skipping.';
              END IF;
            END
            \$\$;"
else
    echo
    echo "  psql not found — complete these steps manually by connecting to"
    echo "  ${RDS_ADDRESS}:${RDS_PORT} as ${DB_MASTER_USER}:"
    echo
    echo "    CREATE EXTENSION IF NOT EXISTS pgaudit;"
    echo
    echo "    -- Audit management user (optional):"
    echo "    CREATE USER ${AUDIT_MGR_USER} WITH PASSWORD '${AUDIT_MGR_PASS}';"
    echo "    GRANT rds_superuser TO ${AUDIT_MGR_USER};"
    echo "    ALTER USER ${AUDIT_MGR_USER} WITH CREATEROLE;"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Setup complete — DSF Hub asset hierarchy"
cat <<EOF

  AWS Cloud Account asset
    └── RDS PostgreSQL Instance asset
          DB identifier : ${DB_INSTANCE_ID}
          Endpoint      : ${RDS_ADDRESS}:${RDS_PORT}
          Engine        : postgres ${PG_MAJOR_VERSION}
          Param group   : ${PARAM_GROUP_NAME}
          └── AWS Log Group asset
                Log group : ${CLOUDWATCH_LOG_GROUP}
                Retention : ${LOG_RETENTION_DAYS} days

  Required IAM permissions for DSF Agentless Gateway:
    logs:DescribeLogGroups
    logs:DescribeLogStreams
    logs:FilterLogEvents
    logs:GetLogEvents
    rds:DescribeDBInstances
    rds:DescribeDBParameterGroups

  CloudWatch audit log stream (once pgaudit is active):
    /aws/rds/instance/${DB_INSTANCE_ID}/postgresql

EOF

if [ "$RUN_TEST" -eq 1 ]; then
    echo
    echo "=== --test: running $(basename "$TEST_SCRIPT") ==="
    bash "$TEST_SCRIPT"
fi
