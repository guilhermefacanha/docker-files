#!/bin/bash

# DynamoDB — create a table
aws dynamodb create-table \
  --table-name Users \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --endpoint-url $AWS_ENDPOINT_URL

aws dynamodb list-tables --endpoint-url $AWS_ENDPOINT_URL

aws sts get-session-token --endpoint-url $AWS_ENDPOINT_URL