#!/bin/bash

set -e

# shellcheck source=00-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"

echo "Configuring Floci to create RDS instance..."

# Create a PostgreSQL instance within Floci
aws rds create-db-instance \
  --db-instance-identifier mypostgres \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --master-username admin \
  --master-user-password secret123 \
  --allocated-storage 20 \
  --endpoint-url $AWS_ENDPOINT_URL

echo "RDS instance 'mypostgres' creation command sent to Floci."

echo "Getting RDS connection details..."
# Get connection details for the created RDS instance
aws rds describe-db-instances \
  --db-instance-identifier mypostgres \
  --query 'DBInstances[0].Endpoint' \
  --endpoint-url $AWS_ENDPOINT_URL

RDS_ADDRESS=$(echo $RDS_ENDPOINT_INFO | jq -r '.Address')
RDS_PORT=$(echo $RDS_ENDPOINT_INFO | jq -r '.Port')

echo "RDS Endpoint Address: $RDS_ADDRESS"
echo "RDS Endpoint Port: $RDS_PORT"

# Create a MySQL instance (as per previous request, keeping it for now)
aws rds create-db-instance \
  --db-instance-identifier mymysql \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --master-username root \
  --master-user-password secret123 \
  --allocated-storage 20 \
  --endpoint-url $AWS_ENDPOINT_URL

aws rds describe-db-instances \
  --db-instance-identifier mymysql \
  --query 'DBInstances[0].Endpoint' \
  --endpoint-url $AWS_ENDPOINT_URL