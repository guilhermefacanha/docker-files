#!/usr/bin/env bash
# floci variant of aws_client/scripts/04-show-fam-asset-info.sh.
# Prints what you need to fill in the FAM/DSF Hub "Onboard a new data
# source" wizard, sourced from the resources created by 01 and 02.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FAM_USER_ARN="arn:aws:iam::${ACCOUNT_ID}:user/${FAM_USER_NAME}"

bucket_region() {
    local bucket="$1"
    local loc
    loc=$(aws s3api get-bucket-location \
            --bucket "$bucket" \
            --query 'LocationConstraint' \
            --output text 2>/dev/null || echo "MISSING")
    if [ "$loc" = "None" ] || [ -z "$loc" ]; then
        echo "us-east-1"
    else
        echo "$loc"
    fi
}

SOURCE_BUCKET_REGION=$(bucket_region "$FAM_SOURCE_BUCKET")
LOGDEST_BUCKET_REGION=$(bucket_region "$FAM_LOG_DESTINATION_BUCKET")

TRAIL_LOGGING="unknown"
if aws cloudtrail describe-trails \
        --trail-name-list "$FAM_TRAIL_NAME" \
        --query 'trailList[0].Name' \
        --output text 2>/dev/null | grep -q "$FAM_TRAIL_NAME"; then
    TRAIL_LOGGING=$(aws cloudtrail get-trail-status \
                        --name "$FAM_TRAIL_NAME" \
                        --query 'IsLogging' \
                        --output text 2>/dev/null || echo "unknown")
fi

FAM_KEY_ID="<see $DATA_DIR/fam-user.env (created by 01)>"
FAM_SECRET="<see $DATA_DIR/fam-user.env (created by 01)>"
if [ -r "$DATA_DIR/fam-user.env" ]; then
    # shellcheck source=/dev/null
    source "$DATA_DIR/fam-user.env"
    FAM_KEY_ID="${FAM_ACCESS_KEY_ID:-$FAM_KEY_ID}"
    FAM_SECRET="${FAM_SECRET_ACCESS_KEY:-$FAM_SECRET}"
fi

cat <<EOF

################################################################
# FAM ASSET ONBOARDING INFORMATION (floci-backed)
# Generated from the floci resources created by scripts 01 and 02.
# Paste these values into the DSF Hub onboarding wizard.
################################################################

================================================================
STEP A - Add Cloud Account (DSF Hub USC > Cloud accounts)
----------------------------------------------------------------
  Auth Mechanism         : Key
  Secret Manager         : OFF
  AWS Access Key ID      : $FAM_KEY_ID
  AWS Secret Access Key  : $FAM_SECRET
  AWS Region             : $AWS_DEFAULT_REGION
  Endpoint Override (*)  : $AWS_ENDPOINT_URL

  (*) Real AWS doesn't need this; the DSF Hub S3 connector must be told
      to use floci's endpoint. Where you set it depends on your Hub
      version — check your gateway's AWS SDK config or the cloud
      account's advanced settings.

  IAM user name          : $FAM_USER_NAME
  IAM user ARN           : $FAM_USER_ARN
  (use this ARN as the cloud account asset_id in DSF Hub)

================================================================
STEP B - Onboard FIRST: the LOG DESTINATION bucket
----------------------------------------------------------------
1. Registration
   Type                 : AWS S3
   Display name         : FAM Lab - Log Destination
   Bucket ARN           : arn:aws:s3:::$FAM_LOG_DESTINATION_BUCKET
   Bucket name          : $FAM_LOG_DESTINATION_BUCKET
   Cloud account        : <the cloud account added in STEP A>

3. Auditing
   Used as a log destination : CHECKED
   Enable self-monitoring    : CHECKED
   Bucket Account ID         : $ACCOUNT_ID
   Advanced > Available
     Bucket Account IDs      : $ACCOUNT_ID

================================================================
STEP C - Onboard SECOND: the DATA SOURCE bucket
----------------------------------------------------------------
1. Registration
   Type                 : AWS S3
   Display name         : FAM Lab - Data Source
   Bucket ARN           : arn:aws:s3:::$FAM_SOURCE_BUCKET
   Bucket name          : $FAM_SOURCE_BUCKET
   Cloud account        : <the same cloud account from STEP A>

3. Auditing
   Used as a log destination : UNCHECKED
   Log destination           : FAM Lab - Log Destination

================================================================
Underlying floci state (FYI)
----------------------------------------------------------------
  Account ID                    : $ACCOUNT_ID
  IAM user ARN                  : $FAM_USER_ARN
  Source bucket region          : $SOURCE_BUCKET_REGION
  Log destination region        : $LOGDEST_BUCKET_REGION
  CloudTrail trail name         : $FAM_TRAIL_NAME
  CloudTrail trail ARN          : arn:aws:cloudtrail:${AWS_DEFAULT_REGION}:${ACCOUNT_ID}:trail/${FAM_TRAIL_NAME}
  Trail is currently logging    : $TRAIL_LOGGING
  Floci endpoint                : $AWS_ENDPOINT_URL

  NOTE: The account ID above must match FLOCI_DEFAULT_ACCOUNT_ID in
  docker-compose.yml AND the bucket_account_id in your DSF cloud
  account asset. Mismatch causes CloudTrail log files to land at
  AWSLogs/<wrong_id>/CloudTrail/... and the gateway finds nothing.

================================================================
EOF
