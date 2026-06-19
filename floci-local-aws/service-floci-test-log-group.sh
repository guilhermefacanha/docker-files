#!/bin/bash
# Test CloudWatch log group access by name and by ARN (log-group-identifier).
# The ARN-based test currently FAILS in floci — use this to validate the fork fix.

set -e

export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

DB_INSTANCE_ID="${DB_INSTANCE_ID:-mypostgres-dsf}"
LOG_GROUP_NAME="/aws/rds/instance/${DB_INSTANCE_ID}/postgresql"

pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; }
step() { echo; echo "=== $* ==="; }

# ─── STEP 1: Resolve log group ARN ───────────────────────────────────────────
step "STEP 1: Resolve log group ARN"

LOG_GROUP_ARN=$(aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP_NAME" \
    --query 'logGroups[0].arn' \
    --output text 2>/dev/null || echo "")

if [ -z "$LOG_GROUP_ARN" ] || [ "$LOG_GROUP_ARN" = "None" ]; then
    fail "Log group '$LOG_GROUP_NAME' not found in floci"
    exit 1
fi

pass "Log group found"
echo "    Name : $LOG_GROUP_NAME"
echo "    ARN  : $LOG_GROUP_ARN"

# ─── STEP 2: describe-log-streams by NAME ────────────────────────────────────
step "STEP 2: describe-log-streams --log-group-name (name-based)"

NAME_RESULT=$(aws logs describe-log-streams \
    --log-group-name "$LOG_GROUP_NAME" \
    --query 'logStreams[].logStreamName' \
    --output text 2>&1 || true)

if echo "$NAME_RESULT" | grep -q "does not exist\|error\|Error"; then
    fail "Name-based lookup failed: $NAME_RESULT"
else
    STREAM_COUNT=$(aws logs describe-log-streams \
        --log-group-name "$LOG_GROUP_NAME" \
        --query 'length(logStreams)' \
        --output text 2>/dev/null || echo 0)
    pass "Name-based lookup succeeded — $STREAM_COUNT stream(s) found"
    echo "    Streams: $NAME_RESULT"
fi

# ─── STEP 3: describe-log-streams by ARN (log-group-identifier) ──────────────
step "STEP 3: describe-log-streams --log-group-identifier (ARN-based) [FORK FIX TARGET]"

ARN_RESULT=$(aws logs describe-log-streams \
    --log-group-identifier "$LOG_GROUP_ARN" \
    --query 'logStreams[].logStreamName' \
    --output text 2>&1 || true)

if echo "$ARN_RESULT" | grep -q "does not exist\|ResourceNotFoundException"; then
    fail "ARN-based lookup FAILED (floci does not support log-group-identifier) — fix this in your fork"
    echo "    Identifier used: $LOG_GROUP_ARN"
    echo "    Error: $ARN_RESULT"
elif echo "$ARN_RESULT" | grep -q "error\|Error"; then
    fail "ARN-based lookup failed with unexpected error: $ARN_RESULT"
else
    pass "ARN-based lookup succeeded — fork fix is working!"
    echo "    Streams: $ARN_RESULT"
fi

# ─── STEP 4: filter-log-events by NAME ───────────────────────────────────────
step "STEP 4: filter-log-events --log-group-name (name-based)"

FILTER_RESULT=$(aws logs filter-log-events \
    --log-group-name "$LOG_GROUP_NAME" \
    --filter-pattern "AUDIT" \
    --query 'length(events)' \
    --output text 2>&1 || true)

if echo "$FILTER_RESULT" | grep -q "error\|Error\|does not exist"; then
    fail "filter-log-events (name) failed: $FILTER_RESULT"
else
    pass "filter-log-events (name) succeeded — $FILTER_RESULT AUDIT event(s)"
fi

# ─── STEP 5: filter-log-events by ARN ────────────────────────────────────────
step "STEP 5: filter-log-events --log-group-identifier (ARN-based) [FORK FIX TARGET]"

FILTER_ARN_RESULT=$(aws logs filter-log-events \
    --log-group-identifier "$LOG_GROUP_ARN" \
    --filter-pattern "AUDIT" \
    --query 'length(events)' \
    --output text 2>&1 || true)

if echo "$FILTER_ARN_RESULT" | grep -q "does not exist\|ResourceNotFoundException"; then
    fail "filter-log-events (ARN) FAILED — fix this in your fork"
    echo "    Error: $FILTER_ARN_RESULT"
elif echo "$FILTER_ARN_RESULT" | grep -q "error\|Error"; then
    fail "filter-log-events (ARN) failed with unexpected error: $FILTER_ARN_RESULT"
else
    pass "filter-log-events (ARN) succeeded — fork fix is working!"
    echo "    AUDIT events: $FILTER_ARN_RESULT"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
step "Summary"
cat <<EOF

  Log group name : $LOG_GROUP_NAME
  Log group ARN  : $LOG_GROUP_ARN
  Endpoint       : $AWS_ENDPOINT_URL

  Steps 2 & 4 (name-based)  — should PASS on stock floci
  Steps 3 & 5 (ARN-based)   — FAIL on stock floci, target of your fork fix

EOF
