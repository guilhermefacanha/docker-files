#!/usr/bin/env bash
# floci variant of aws_client/scripts/03-test-traffic.sh.
# Drops a handful of objects on the source bucket and reads them back so
# CloudTrail has data events to emit. Floci's writer flushes records every
# 60s (configurable via FLOCI_SERVICES_CLOUDTRAIL_FLUSH_INTERVAL_SECONDS),
# so logs land in the destination bucket within ~1 minute.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

TEST_FILE=$(mktemp)
echo "FAM lab test data generated at $(date -u)" > "$TEST_FILE"

KEY="test-uploads/test-$(date -u +%Y%m%d-%H%M%S).txt"

echo "==> PUT s3://$FAM_SOURCE_BUCKET/$KEY"
aws s3 cp "$TEST_FILE" "s3://$FAM_SOURCE_BUCKET/$KEY"

echo "==> LIST s3://$FAM_SOURCE_BUCKET/"
aws s3 ls "s3://$FAM_SOURCE_BUCKET/" --recursive

echo "==> GET s3://$FAM_SOURCE_BUCKET/$KEY"
aws s3 cp "s3://$FAM_SOURCE_BUCKET/$KEY" -

rm -f "$TEST_FILE"

cat <<EOF

Traffic generated. Floci flushes pending CloudTrail records every ~60s.
Check the log destination after a minute:

  aws --endpoint-url $AWS_ENDPOINT_URL \\
      s3 ls s3://$FAM_LOG_DESTINATION_BUCKET/AWSLogs/ --recursive
EOF
