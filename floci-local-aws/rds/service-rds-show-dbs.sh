aws rds describe-db-instances \
  --query 'DBInstances[*].DBInstanceIdentifier' \
  --output text