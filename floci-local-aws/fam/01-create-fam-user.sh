#!/usr/bin/env bash
# floci variant of aws_client/scripts/01-create-fam-user.sh.
# Creates the IAM user FAM uses to onboard the S3 data source:
#   - inline policy: s3:ListBucket, s3:GetObject, s3:ListAllMyBuckets
#   - managed policy: AWSCloudTrail_FullAccess (seeded by floci)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

echo "==> Verifying current identity"
aws sts get-caller-identity

if aws iam get-user --user-name "$FAM_USER_NAME" >/dev/null 2>&1; then
    echo "User $FAM_USER_NAME already exists, skipping creation."
else
    echo "==> Creating IAM user: $FAM_USER_NAME"
    aws iam create-user --user-name "$FAM_USER_NAME" >/dev/null
fi

echo "==> Attaching inline policy with FAM S3 read permissions"
INLINE_POLICY=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "FAMS3ReadAccess",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:ListAllMyBuckets"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

aws iam put-user-policy \
    --user-name "$FAM_USER_NAME" \
    --policy-name "FAMS3ReadAccess" \
    --policy-document "$INLINE_POLICY"

echo "==> Attaching AWSCloudTrail_FullAccess managed policy"
aws iam attach-user-policy \
    --user-name "$FAM_USER_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AWSCloudTrail_FullAccess

EXISTING_KEYS=$(aws iam list-access-keys \
    --user-name "$FAM_USER_NAME" \
    --query 'AccessKeyMetadata[].AccessKeyId' \
    --output text)

if [ -n "$EXISTING_KEYS" ]; then
    echo "  $FAM_USER_NAME already has access key(s): $EXISTING_KEYS"
    # Check if the stored key in fam-user.env matches what is in floci.
    if [ -r "$DATA_DIR/fam-user.env" ]; then
        STORED_KEY=$(grep FAM_ACCESS_KEY_ID "$DATA_DIR/fam-user.env" | cut -d= -f2)
        if echo "$EXISTING_KEYS" | grep -qF "$STORED_KEY"; then
            echo "  Stored key $STORED_KEY is still valid in floci. No rotation needed."
        else
            echo "  WARNING: stored key $STORED_KEY no longer exists in floci (was floci restarted?)."
            echo "  Deleting old keys and creating a new one..."
            for k in $EXISTING_KEYS; do
                aws iam delete-access-key --user-name "$FAM_USER_NAME" --access-key-id "$k"
            done
            # Fall through to create a new key below.
        fi
    else
        echo "  Skipping new key creation (no fam-user.env found; run again to rotate)."
        exit 0
    fi

    # If we still have keys (stored key is valid), exit.
    REMAINING=$(aws iam list-access-keys \
        --user-name "$FAM_USER_NAME" \
        --query 'AccessKeyMetadata[].AccessKeyId' \
        --output text)
    if [ -n "$REMAINING" ]; then
        exit 0
    fi
fi

echo "==> Creating access key for $FAM_USER_NAME"
KEY_OUTPUT=$(aws iam create-access-key --user-name "$FAM_USER_NAME")
ACCESS_KEY_ID=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.AccessKeyId')
SECRET_ACCESS_KEY=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.SecretAccessKey')

# Persist the FAM key for downstream scripts and FAM onboarding.
cat > "$DATA_DIR/fam-user.env" <<EOF
FAM_ACCESS_KEY_ID=$ACCESS_KEY_ID
FAM_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY
EOF
chmod 600 "$DATA_DIR/fam-user.env"

cat <<EOF

================================================================
FAM cloud-account credentials (paste these into the DSF Hub
"Add Cloud Account" dialog: Auth Mechanism = Key, Secret
Manager = OFF):

  AWS_ACCESS_KEY_ID=$ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY

Also written to $DATA_DIR/fam-user.env (chmod 600).
================================================================
EOF
