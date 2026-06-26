#!/bin/bash
# Generate MARIADB_AUDIT_PLUGIN activity: INSERT / UPDATE / DELETE / DROP on a temp table

set -e

# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# ─── Configuration ────────────────────────────────────────────────────────────
DB_INSTANCE_ID="${DB_INSTANCE_ID:-mymariadb${ENV_SUFFIX:-}-dsf}"
DB_NAME="${DB_NAME:-mysql}"

ROW_COUNT="${ROW_COUNT:-300}"        # total rows to insert
UPDATE_RATIO="${UPDATE_RATIO:-40}"   # % of rows to update
DELETE_RATIO="${DELETE_RATIO:-20}"   # % of rows to delete

TABLE_NAME="audit_load_$(date +%s)"

# ─── Helpers ──────────────────────────────────────────────────────────────────
step() { echo; echo "=== $* ==="; }
info() { echo "    $*"; }

# ─── Resolve RDS endpoint ─────────────────────────────────────────────────────
step "Resolving RDS endpoint for '$DB_INSTANCE_ID'"

ENDPOINT_JSON=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query 'DBInstances[0].Endpoint' \
    --output json \
    --endpoint-url "$AWS_ENDPOINT_URL")

RDS_ADDRESS=$(echo "$ENDPOINT_JSON" | jq -r '.Address')
RDS_PORT=$(echo "$ENDPOINT_JSON" | jq -r '.Port')
info "Endpoint: ${RDS_ADDRESS}:${RDS_PORT}"

if ! command -v mysql >/dev/null 2>&1; then
    echo "ERROR: mysql client not found. Install it to generate audit events." >&2
    exit 1
fi

MYSQL="mysql -h $RDS_ADDRESS -P $RDS_PORT -u $DB_MASTER_USER -p${DB_MASTER_PASS} $DB_NAME --connect-timeout=10"

# ─── Derived counts ───────────────────────────────────────────────────────────
UPDATE_COUNT=$(( ROW_COUNT * UPDATE_RATIO / 100 ))
DELETE_COUNT=$(( ROW_COUNT * DELETE_RATIO / 100 ))
REMAINING=$(( ROW_COUNT - DELETE_COUNT ))

# ─── STEP 1: Create table ─────────────────────────────────────────────────────
step "STEP 1: Creating table '$TABLE_NAME'"

$MYSQL <<SQL
CREATE TABLE ${TABLE_NAME} (
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(64)  NOT NULL,
    email       VARCHAR(128) NOT NULL,
    score       INT          NOT NULL DEFAULT 0,
    status      VARCHAR(16)  NOT NULL DEFAULT 'active',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME
);
SQL
info "Table created."

# ─── STEP 2: Insert rows (batched VALUES list) ────────────────────────────────
step "STEP 2: Inserting ${ROW_COUNT} rows"

VALUES=""
for i in $(seq 1 "$ROW_COUNT"); do
    status="active"
    [ $(( i % 5 )) -eq 0 ] && status="inactive"
    score=$(( (RANDOM * RANDOM) % 1000 ))
    if [ -n "$VALUES" ]; then VALUES="${VALUES},"; fi
    VALUES="${VALUES}('user_${i}','user_${i}@example.com',${score},'${status}')"
done

$MYSQL -e "INSERT INTO ${TABLE_NAME} (username, email, score, status) VALUES ${VALUES};"
info "${ROW_COUNT} rows inserted."

# ─── STEP 3: Update rows ──────────────────────────────────────────────────────
step "STEP 3: Updating ${UPDATE_COUNT} rows (score boost + timestamp)"

$MYSQL <<SQL
UPDATE ${TABLE_NAME}
SET    score      = score + 100,
       status     = 'updated',
       updated_at = NOW()
ORDER BY RAND()
LIMIT ${UPDATE_COUNT};
SQL
info "${UPDATE_COUNT} rows updated."

# ─── STEP 4: Delete rows ──────────────────────────────────────────────────────
step "STEP 4: Deleting ${DELETE_COUNT} rows"

$MYSQL <<SQL
DELETE FROM ${TABLE_NAME}
ORDER BY RAND()
LIMIT ${DELETE_COUNT};
SQL
info "${DELETE_COUNT} rows deleted."

# ─── STEP 5: Verify live state ────────────────────────────────────────────────
step "STEP 5: Live table state"

$MYSQL <<SQL
SELECT
    COUNT(*)                                              AS total_rows,
    SUM(status = 'active')                                AS active,
    SUM(status = 'inactive')                              AS inactive,
    SUM(status = 'updated')                               AS updated,
    ROUND(AVG(score), 1)                                  AS avg_score,
    MIN(score)                                            AS min_score,
    MAX(score)                                            AS max_score
FROM ${TABLE_NAME};
SQL

# ─── STEP 6: Drop table ───────────────────────────────────────────────────────
step "STEP 6: Dropping table '$TABLE_NAME'"

$MYSQL -e "DROP TABLE ${TABLE_NAME};"
info "Table dropped."

# ─── Summary ──────────────────────────────────────────────────────────────────
step "Audit generation complete — operation summary"
cat <<EOF

  Table name   : ${TABLE_NAME}
  DB instance  : ${DB_INSTANCE_ID}  (${RDS_ADDRESS}:${RDS_PORT})

  Operations
  ──────────────────────────────
  CREATE TABLE : 1
  INSERT       : ${ROW_COUNT}   rows
  UPDATE       : ${UPDATE_COUNT}   rows  (${UPDATE_RATIO}% of total)
  DELETE       : ${DELETE_COUNT}   rows  (${DELETE_RATIO}% of total)
  Remaining    : ${REMAINING}  rows  (before DROP)
  DROP TABLE   : 1

  All operations were executed under MARIADB_AUDIT_PLUGIN logging and should
  appear in CloudWatch log groups:
    /aws/rds/instance/${DB_INSTANCE_ID}/audit
    /aws/rds/instance/${DB_INSTANCE_ID}/error

EOF
