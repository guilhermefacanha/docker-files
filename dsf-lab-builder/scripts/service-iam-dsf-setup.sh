#!/bin/bash
# Creates an IAM user + policy for DSF Agentless Gateway with least-privilege permissions.
# Idempotent — safe to re-run.

set -e

export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

IAM_USER="${IAM_USER:-dsf-agentless-gateway}"
POLICY_NAME="${POLICY_NAME:-DSFAgentlessGatewayPolicy}"
# Derive account ID from env: FAM_ACCOUNT_ID (set by update-docker-env.sh for
# per-env instances) → FLOCI_DEFAULT_ACCOUNT_ID → 000000000000 base default.
ACCOUNT_ID="${FAM_ACCOUNT_ID:-${FLOCI_DEFAULT_ACCOUNT_ID:-000000000000}}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

step() { echo; echo "=== $* ==="; }
info() { echo "    $*"; }
pass() { echo "  [PASS] $*"; }

# ── Step 1: IAM user ──────────────────────────────────────────────────────────
step "Step 1: IAM user '$IAM_USER'"

if aws iam get-user --user-name "$IAM_USER" --endpoint-url "$AWS_ENDPOINT_URL" \
      --query 'User.UserName' --output text 2>/dev/null | grep -q "$IAM_USER"; then
  info "User already exists, skipping creation."
else
  aws iam create-user --user-name "$IAM_USER" --endpoint-url "$AWS_ENDPOINT_URL" --no-cli-pager
  pass "User '$IAM_USER' created."
fi

# ── Step 2: IAM policy ────────────────────────────────────────────────────────
step "Step 2: Policy '$POLICY_NAME'"

POLICY_DOC='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "rds:DescribeDBInstances",
      "rds:DescribeDBClusters",
      "rds:DescribeDBParameterGroups",
      "s3:ListBucket",
      "s3:GetObject"
    ],
    "Resource": "*"
  }]
}'

if aws iam get-policy --policy-arn "$POLICY_ARN" --endpoint-url "$AWS_ENDPOINT_URL" \
      --query 'Policy.PolicyName' --output text 2>/dev/null | grep -q "$POLICY_NAME"; then
  info "Policy already exists, skipping creation."
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_DOC" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --no-cli-pager
  pass "Policy '$POLICY_NAME' created."
fi

# ── Step 3: Attach policy ─────────────────────────────────────────────────────
step "Step 3: Attach policy to user"

ATTACHED=$(aws iam list-attached-user-policies \
  --user-name "$IAM_USER" \
  --endpoint-url "$AWS_ENDPOINT_URL" \
  --query 'AttachedPolicies[?PolicyArn==`'"$POLICY_ARN"'`].PolicyArn' \
  --output text 2>/dev/null || true)

if [ -n "$ATTACHED" ]; then
  info "Policy already attached, skipping."
else
  aws iam attach-user-policy \
    --user-name "$IAM_USER" \
    --policy-arn "$POLICY_ARN" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --no-cli-pager
  pass "Policy attached."
fi

# ── Step 4: Create access key ─────────────────────────────────────────────────
step "Step 4: Access key"

KEY_COUNT=$(aws iam list-access-keys \
  --user-name "$IAM_USER" \
  --endpoint-url "$AWS_ENDPOINT_URL" \
  --query 'length(AccessKeyMetadata)' \
  --output text 2>/dev/null || echo 0)

if [ "${KEY_COUNT:-0}" -gt 0 ]; then
  info "Access key already exists. To rotate it, delete it first:"
  info "  aws iam list-access-keys --user-name $IAM_USER --endpoint-url $AWS_ENDPOINT_URL"
  info "  aws iam delete-access-key --user-name $IAM_USER --access-key-id <ID> --endpoint-url $AWS_ENDPOINT_URL"
  info "  Then re-run this script."
else
  KEY_JSON=$(aws iam create-access-key \
    --user-name "$IAM_USER" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --no-cli-pager)
  ACCESS_KEY_ID=$(echo "$KEY_JSON" | jq -r '.AccessKey.AccessKeyId')
  SECRET_ACCESS_KEY=$(echo "$KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')
  pass "Access key created."
  echo
  echo "  ┌─────────────────────────────────────────────────────────────────┐"
  echo "  │  DSF Agentless Gateway credentials (save these now)            │"
  echo "  ├─────────────────────────────────────────────────────────────────┤"
  printf "  │  AWS_ACCESS_KEY_ID     : %-38s│\n" "$ACCESS_KEY_ID"
  printf "  │  AWS_SECRET_ACCESS_KEY : %-38s│\n" "$SECRET_ACCESS_KEY"
  echo "  │  AWS_DEFAULT_REGION    : us-east-1                             │"
  printf "  │  AWS_ENDPOINT_URL      : %-38s│\n" "$AWS_ENDPOINT_URL"
  echo "  └─────────────────────────────────────────────────────────────────┘"
fi

# ── Step 5: Verify ────────────────────────────────────────────────────────────
step "Step 5: Verify attached permissions"

aws iam list-attached-user-policies \
  --user-name "$IAM_USER" \
  --endpoint-url "$AWS_ENDPOINT_URL" \
  --query 'AttachedPolicies[].{Policy:PolicyName,Arn:PolicyArn}' \
  --output table \
  --no-cli-pager

echo
info "User ARN : arn:aws:iam::${ACCOUNT_ID}:user/${IAM_USER}"
info "Policy   : $POLICY_ARN"
info "Note     : floci accepts these credentials but does not enforce IAM boundaries."
info "           On real AWS, only the listed actions will be authorized."
