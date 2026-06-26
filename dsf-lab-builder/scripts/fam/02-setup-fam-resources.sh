#!/usr/bin/env bash
# floci variant of aws_client/scripts/02-setup-fam-resources.sh.
# Creates source + log destination buckets, CloudTrail trail, event
# selectors, and starts logging — everything FAM needs to onboard an
# S3 data source.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID  Region: $AWS_DEFAULT_REGION  Endpoint: $AWS_ENDPOINT_URL"

if [ "$ACCOUNT_ID" != "$FAM_ACCOUNT_ID" ]; then
    echo "WARNING: floci is running with account=$ACCOUNT_ID but FAM samples were"
    echo "         captured under $FAM_ACCOUNT_ID. To align, restart floci with:"
    echo "             FLOCI_DEFAULT_ACCOUNT_ID=$FAM_ACCOUNT_ID"
fi

create_bucket() {
    local bucket="$1"
    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        echo "Bucket $bucket already exists, skipping."
        return
    fi
    if [ "$AWS_DEFAULT_REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$bucket" >/dev/null
    else
        aws s3api create-bucket \
            --bucket "$bucket" \
            --create-bucket-configuration "LocationConstraint=$AWS_DEFAULT_REGION" >/dev/null
    fi
    echo "Created bucket: $bucket"
}

echo "==> Step 1: Creating S3 buckets"
create_bucket "$FAM_SOURCE_BUCKET"
create_bucket "$FAM_LOG_DESTINATION_BUCKET"

echo "==> Step 2: Applying CloudTrail bucket policy to $FAM_LOG_DESTINATION_BUCKET"
BUCKET_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSCloudTrailAclCheck",
            "Effect": "Allow",
            "Principal": {"Service": "cloudtrail.amazonaws.com"},
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::${FAM_LOG_DESTINATION_BUCKET}"
        },
        {
            "Sid": "AWSCloudTrailWrite",
            "Effect": "Allow",
            "Principal": {"Service": "cloudtrail.amazonaws.com"},
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${FAM_LOG_DESTINATION_BUCKET}/AWSLogs/${ACCOUNT_ID}/*",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-acl": "bucket-owner-full-control"
                }
            }
        }
    ]
}
EOF
)

aws s3api put-bucket-policy \
    --bucket "$FAM_LOG_DESTINATION_BUCKET" \
    --policy "$BUCKET_POLICY"

echo "==> Step 3: Creating CloudTrail trail '$FAM_TRAIL_NAME'"
TRAIL_EXISTS=$(aws cloudtrail describe-trails \
    --trail-name-list "$FAM_TRAIL_NAME" \
    --query 'trailList[0].Name' \
    --output text 2>/dev/null || echo "None")

if [ "$TRAIL_EXISTS" = "$FAM_TRAIL_NAME" ]; then
    echo "Trail already exists, updating storage location."
    aws cloudtrail update-trail \
        --name "$FAM_TRAIL_NAME" \
        --s3-bucket-name "$FAM_LOG_DESTINATION_BUCKET" \
        --include-global-service-events \
        --is-multi-region-trail \
        --enable-log-file-validation >/dev/null
else
    aws cloudtrail create-trail \
        --name "$FAM_TRAIL_NAME" \
        --s3-bucket-name "$FAM_LOG_DESTINATION_BUCKET" \
        --include-global-service-events \
        --is-multi-region-trail \
        --enable-log-file-validation >/dev/null
fi

echo "==> Step 4: Configuring event selectors"
# Mandatory: S3 Data events (all current/future buckets per FAM admin guide).
aws cloudtrail put-event-selectors \
    --trail-name "$FAM_TRAIL_NAME" \
    --event-selectors '[
        {
            "ReadWriteType": "All",
            "IncludeManagementEvents": true,
            "ExcludeManagementEventSources": [
                "kms.amazonaws.com",
                "rdsdata.amazonaws.com"
            ],
            "DataResources": [
                {
                    "Type": "AWS::S3::Object",
                    "Values": ["arn:aws:s3:::"]
                }
            ]
        }
    ]' >/dev/null

echo "==> Step 5: Starting trail logging"
aws cloudtrail start-logging --name "$FAM_TRAIL_NAME"

echo ""
echo "==> Done. Summary:"
echo "  Source bucket          : s3://$FAM_SOURCE_BUCKET"
echo "  Log destination bucket : s3://$FAM_LOG_DESTINATION_BUCKET"
echo "  CloudTrail trail       : $FAM_TRAIL_NAME"
echo "  Trail ARN              : arn:aws:cloudtrail:${AWS_DEFAULT_REGION}:${ACCOUNT_ID}:trail/${FAM_TRAIL_NAME}"
echo ""
aws cloudtrail get-trail-status \
    --name "$FAM_TRAIL_NAME" \
    --query '{IsLogging:IsLogging,LatestDeliveryTime:LatestDeliveryTime,LatestDeliveryError:LatestDeliveryError}' \
    --output table
