#!/usr/bin/env bash
# floci variant of aws_client/scripts/99-cleanup.sh.
# Tears down everything 01, 02, and 05 created. Destructive.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

: "${FAM_ACTOR_PREFIX:=fam-actor}"
: "${SKIP_CONFIRM:=0}"

if [ "$SKIP_CONFIRM" != "1" ]; then
    read -rp "This will DELETE the FAM lab resources. Continue? (y/N) " confirm
    [ "$confirm" = "y" ] || { echo "Aborted."; exit 0; }
fi

delete_iam_user() {
    local user="$1"
    if ! aws iam get-user --user-name "$user" >/dev/null 2>&1; then
        return
    fi
    for arn in $(aws iam list-attached-user-policies \
                    --user-name "$user" \
                    --query 'AttachedPolicies[].PolicyArn' \
                    --output text); do
        aws iam detach-user-policy --user-name "$user" --policy-arn "$arn"
    done
    for pname in $(aws iam list-user-policies \
                       --user-name "$user" \
                       --query 'PolicyNames[]' \
                       --output text); do
        aws iam delete-user-policy --user-name "$user" --policy-name "$pname"
    done
    for key in $(aws iam list-access-keys \
                    --user-name "$user" \
                    --query 'AccessKeyMetadata[].AccessKeyId' \
                    --output text); do
        aws iam delete-access-key --user-name "$user" --access-key-id "$key"
    done
    aws iam delete-user --user-name "$user"
    echo "  deleted $user"
}

echo "==> Stopping and deleting CloudTrail trail"
aws cloudtrail stop-logging --name "$FAM_TRAIL_NAME" 2>/dev/null || true
aws cloudtrail delete-trail --name "$FAM_TRAIL_NAME" 2>/dev/null || true

echo "==> Emptying and deleting S3 buckets"
for bucket in "$FAM_SOURCE_BUCKET" "$FAM_LOG_DESTINATION_BUCKET"; do
    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true
        aws s3api delete-bucket --bucket "$bucket" 2>/dev/null || true
        echo "  deleted $bucket"
    fi
done

echo "==> Deleting actor users (prefix: ${FAM_ACTOR_PREFIX}-)"
ACTORS=$(aws iam list-users \
            --query "Users[?starts_with(UserName, '${FAM_ACTOR_PREFIX}-')].UserName" \
            --output text)
for actor in $ACTORS; do
    delete_iam_user "$actor"
done

echo "==> Deleting FAM user $FAM_USER_NAME"
delete_iam_user "$FAM_USER_NAME"

echo "==> Removing local actor + user data"
rm -f "$DATA_DIR/actors.json" "$DATA_DIR/fam-user.env"

echo "Cleanup complete."
