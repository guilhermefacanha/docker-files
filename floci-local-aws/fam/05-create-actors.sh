#!/usr/bin/env bash
# floci variant of aws_client/scripts/05-create-actors.sh.
# Creates N IAM actor users that the simulator drives to produce audit
# traffic. Each actor has Get/Put/Delete on the source bucket; the
# "regular" tier also has an explicit Deny on restricted/, confidential/
# so denial events show up in CloudTrail.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

: "${FAM_ACTOR_PREFIX:=fam-actor}"
: "${FAM_ACTOR_COUNT:=10}"
: "${FAM_PRIVILEGED_COUNT:=3}"

OUT_FILE="$DATA_DIR/actors.json"

POLICY_DOC_PRIVILEGED=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "FAMActorBucketAccess",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::${FAM_SOURCE_BUCKET}"
        },
        {
            "Sid": "FAMActorObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::${FAM_SOURCE_BUCKET}/*"
        }
    ]
}
EOF
)

POLICY_DOC_REGULAR=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "FAMActorBucketAccess",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::${FAM_SOURCE_BUCKET}"
        },
        {
            "Sid": "FAMActorObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::${FAM_SOURCE_BUCKET}/*"
        },
        {
            "Sid": "FAMActorDenyRestricted",
            "Effect": "Deny",
            "Action": "*",
            "Resource": [
                "arn:aws:s3:::${FAM_SOURCE_BUCKET}/restricted/*",
                "arn:aws:s3:::${FAM_SOURCE_BUCKET}/confidential/*"
            ]
        }
    ]
}
EOF
)

if [ "$FAM_PRIVILEGED_COUNT" -gt "$FAM_ACTOR_COUNT" ]; then
    echo "FAM_PRIVILEGED_COUNT ($FAM_PRIVILEGED_COUNT) must be <= FAM_ACTOR_COUNT ($FAM_ACTOR_COUNT)" >&2
    exit 1
fi

echo "==> Creating $FAM_ACTOR_COUNT actor users scoped to s3://$FAM_SOURCE_BUCKET"
echo "    First $FAM_PRIVILEGED_COUNT will be 'privileged' (full access),"
echo "    remaining $((FAM_ACTOR_COUNT - FAM_PRIVILEGED_COUNT)) will be 'regular' (denied on restricted/, confidential/)."

ACTOR_ENTRIES=()
idx=0

for i in $(seq -f "%02g" 1 "$FAM_ACTOR_COUNT"); do
    idx=$((idx + 1))
    actor="${FAM_ACTOR_PREFIX}-${i}"

    if [ "$idx" -le "$FAM_PRIVILEGED_COUNT" ]; then
        tier="privileged"
        policy_doc="$POLICY_DOC_PRIVILEGED"
    else
        tier="regular"
        policy_doc="$POLICY_DOC_REGULAR"
    fi

    if aws iam get-user --user-name "$actor" >/dev/null 2>&1; then
        echo "  $actor ($tier) exists, refreshing policy and key."
    else
        aws iam create-user --user-name "$actor" >/dev/null
        echo "  created $actor ($tier)"
    fi

    aws iam put-user-policy \
        --user-name "$actor" \
        --policy-name "FAMActorBucketAccess" \
        --policy-document "$policy_doc"

    for k in $(aws iam list-access-keys --user-name "$actor" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
        aws iam delete-access-key --user-name "$actor" --access-key-id "$k"
    done

    key_json=$(aws iam create-access-key --user-name "$actor")
    ak=$(echo "$key_json" | jq -r '.AccessKey.AccessKeyId')
    sk=$(echo "$key_json" | jq -r '.AccessKey.SecretAccessKey')

    ACTOR_ENTRIES+=("$(jq -n \
        --arg name "$actor" \
        --arg ak "$ak" \
        --arg sk "$sk" \
        --arg tier "$tier" \
        '{name:$name, access_key_id:$ak, secret_access_key:$sk, tier:$tier}')")
done

printf '%s\n' "${ACTOR_ENTRIES[@]}" | jq -s '{actors: .}' > "$OUT_FILE"
chmod 600 "$OUT_FILE"

cat <<EOF

Wrote $OUT_FILE (chmod 600). $FAM_ACTOR_COUNT actors ready.

Start the simulator with:
  python3 $(dirname "${BASH_SOURCE[0]}")/06-simulate-activity.py \\
      --actors $OUT_FILE

Stop it any time with Ctrl+C.
EOF
