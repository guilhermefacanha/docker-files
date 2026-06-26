#!/bin/bash

set -e

echo "Configuring Floci to create S3 instance..."

# Set AWS CLI endpoint to Floci
export AWS_ENDPOINT_URL="http://localhost:4566"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

echo "S3: Creating bucket 'filesystem' and uploading 'hello.txt'..."
# Create an S3 bucket named 'filesystem'
aws s3 mb s3://filesystem --endpoint-url $AWS_ENDPOINT_URL

# List Buckets
aws s3 ls --endpoint-url http://localhost:4566

# Upload a file named 'hello.txt' with content "hello floci" to the 'filesystem' bucket
echo "hello floci" | aws s3 cp - s3://filesystem/hello.txt --endpoint-url $AWS_ENDPOINT_URL

echo "S3: Listing contents of 'filesystem' bucket:"
aws s3 ls s3://filesystem --endpoint-url $AWS_ENDPOINT_URL

