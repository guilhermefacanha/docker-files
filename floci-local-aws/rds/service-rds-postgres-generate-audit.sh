#!/bin/bash
# Generate pgaudit activity: INSERT / UPDATE / DELETE / DROP on a temp table

set -e

# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

# ─── Configuration ────────────────────────────────────────────────────────────
DB_INSTANCE_ID="${DB_INSTANCE_ID:-mypostgres${ENV_SUFFIX:-}-dsf}"
DB_NAME="${DB_NAME:-postgres}"

ROW_COUNT="${ROW_COUNT:-300}"          # total rows to insert
UPDATE_RATIO="${UPDATE_RATIO:-40}"     # % of rows to update
DELETE_RATIO="${DELETE_RATIO:-20}"     # % of rows to delete

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

export PGPASSWORD="$DB_MASTER_PASS"
PSQL="psql -h $RDS_ADDRESS -p $RDS_PORT -U $DB_MASTER_USER -d $DB_NAME"

# ─── Derived counts ───────────────────────────────────────────────────────────
UPDATE_COUNT=$(( ROW_COUNT * UPDATE_RATIO / 100 ))
DELETE_COUNT=$(( ROW_COUNT * DELETE_RATIO / 100 ))
REMAINING=$(( ROW_COUNT - DELETE_COUNT ))

# ─── STEP 1: Create table ─────────────────────────────────────────────────────
step "STEP 1: Creating table '$TABLE_NAME'"

$PSQL <<SQL
CREATE TABLE ${TABLE_NAME} (
    id          SERIAL PRIMARY KEY,
    username    TEXT        NOT NULL,
    email       TEXT        NOT NULL,
    score       INTEGER     NOT NULL DEFAULT 0,
    status      TEXT        NOT NULL DEFAULT 'active',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ
);
SQL
info "Table created."

# ─── STEP 2: Insert rows ──────────────────────────────────────────────────────
step "STEP 2: Inserting ${ROW_COUNT} rows"

$PSQL <<SQL
INSERT INTO ${TABLE_NAME} (username, email, score, status)
SELECT
    'user_' || i,
    'user_' || i || '@example.com',
    (random() * 1000)::int,
    CASE WHEN i % 5 = 0 THEN 'inactive' ELSE 'active' END
FROM generate_series(1, ${ROW_COUNT}) AS s(i);
SQL
info "${ROW_COUNT} rows inserted."

# ─── STEP 3: Update rows ──────────────────────────────────────────────────────
step "STEP 3: Updating ${UPDATE_COUNT} rows (score boost + timestamp)"

$PSQL <<SQL
UPDATE ${TABLE_NAME}
SET    score      = score + 100,
       status     = 'updated',
       updated_at = now()
WHERE  id IN (
    SELECT id FROM ${TABLE_NAME} ORDER BY random() LIMIT ${UPDATE_COUNT}
);
SQL
info "${UPDATE_COUNT} rows updated."

# ─── STEP 4: Delete rows ──────────────────────────────────────────────────────
step "STEP 4: Deleting ${DELETE_COUNT} rows"

$PSQL <<SQL
DELETE FROM ${TABLE_NAME}
WHERE id IN (
    SELECT id FROM ${TABLE_NAME} ORDER BY random() LIMIT ${DELETE_COUNT}
);
SQL
info "${DELETE_COUNT} rows deleted."

# ─── STEP 5: Verify live state ────────────────────────────────────────────────
step "STEP 5: Live table state"

$PSQL <<SQL
SELECT
    COUNT(*)                                          AS total_rows,
    COUNT(*) FILTER (WHERE status = 'active')         AS active,
    COUNT(*) FILTER (WHERE status = 'inactive')       AS inactive,
    COUNT(*) FILTER (WHERE status = 'updated')        AS updated,
    ROUND(AVG(score), 1)                              AS avg_score,
    MIN(score)                                        AS min_score,
    MAX(score)                                        AS max_score
FROM ${TABLE_NAME};
SQL

# ─── STEP 6: Drop table ───────────────────────────────────────────────────────
step "STEP 6: Dropping table '$TABLE_NAME'"

$PSQL -c "DROP TABLE ${TABLE_NAME};"
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

  All operations were executed under pgaudit logging and should appear
  in CloudWatch log group:
    /aws/rds/instance/${DB_INSTANCE_ID}/postgresql

EOF
