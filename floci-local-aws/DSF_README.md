# DSF Hub — Local Audit Source Setup (PostgreSQL RDS via CloudWatch)

This guide covers running a full Thales DSF Hub audit pipeline locally using floci as the AWS emulator. The setup mirrors the real-AWS flow described in the Thales DSF Hub Reference Guide for Amazon RDS for PostgreSQL via CloudWatch.

## How It Works

```
PostgreSQL (floci-rds-<id> container)
    │  pgaudit generates AUDIT lines to stdout/stderr
    ▼
Docker container logs
    │  rds-log-shipper tails logs and calls put-log-events
    ▼
floci CloudWatch (/aws/rds/instance/<id>/postgresql)
    │  DSF Agentless Gateway polls
    ▼
filter-log-events / get-log-events  ←── what DSF Hub consumes
```

The `rds-log-shipper` sidecar (included in `docker-compose.yml`) handles the log forwarding automatically. It polls for `floci-rds-*` containers every 10 seconds and starts a shipper thread for each one.

## Custom PostgreSQL Image

`postgres:16-alpine` does not include pgaudit. The custom image compiles it from source:

```bash
docker build -f Dockerfile.postgres-pgaudit -t local/postgres-pgaudit:16 .
```

This image is configured as the default for floci RDS instances via:

```
FLOCI_SERVICES_RDS_DEFAULT_POSTGRES_IMAGE: local/postgres-pgaudit:16
```

## DSF Setup Script

`service-rds-postgres-dsf-setup.sh` — idempotent, safe to re-run.

### What it does

| Step | Action |
|---|---|
| 1 | Create PostgreSQL RDS instance (`mypostgres-dsf`) |
| 2a | Create DB parameter group `dsf-postgres-audit-params` (postgres16 family) |
| 2b | Set audit parameters: `shared_preload_libraries=pgaudit`, `pgaudit.log=all`, `log_connections`, `log_disconnections`, `log_error_verbosity` |
| 2c | (Optional) Slow-query monitoring via `log_min_duration_statement` |
| 2d | Attach parameter group + enable CloudWatch log export (`postgresql` log type) |
| 2e | Reboot instance so `shared_preload_libraries` takes effect |
| 3 | Create CloudWatch log group + set 90-day retention |
| 4 | `CREATE EXTENSION pgaudit` via psql (requires psql in PATH) |
| 4b | Create `auditmgr` user with `rds_superuser` + `CREATEROLE` |

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `DB_INSTANCE_ID` | `mypostgres-dsf` | RDS instance identifier |
| `DB_MASTER_USER` | `admin` | Master username |
| `DB_MASTER_PASS` | `secret123` | Master password |
| `DB_CLASS` | `db.t3.micro` | Instance class |
| `PG_MAJOR_VERSION` | `16` | PostgreSQL major version |
| `PARAM_GROUP_NAME` | `dsf-postgres-audit-params` | Parameter group name |
| `LOG_RETENTION_DAYS` | `90` | CloudWatch log retention |
| `SLOW_QUERY_MS` | _(unset)_ | Enable slow-query monitoring at this threshold (ms) |
| `AUDIT_MGR_USER` | `auditmgr` | Audit manager username |
| `AUDIT_MGR_PASS` | `AuditMgr$ecret1` | Audit manager password |
| `AWS_ENDPOINT_URL` | `http://localhost:4566` | floci endpoint |

### Run

```bash
bash service-rds-postgres-dsf-setup.sh
```

With slow-query monitoring:

```bash
SLOW_QUERY_MS=500 bash service-rds-postgres-dsf-setup.sh
```

## Audit Validation Script

`service-rds-postgres-test-audit-cloudwatch.sh` — validates the full audit pipeline end to end.

### What it does

| Step | Action |
|---|---|
| 1 | Configure pgaudit inside the container: `ALTER SYSTEM SET shared_preload_libraries=pgaudit`, restart, set `pgaudit.log=all`, reload config |
| 2 | Generate audit events: DDL (CREATE DATABASE, CREATE TABLE), DML (INSERT, UPDATE, DELETE), READ (SELECT), ROLE (CREATE USER, GRANT), EXCEPTION (invalid query) |
| 2b | Poll CloudWatch until shipper flushes the events (up to 30s) |
| 3 | Verify AUDIT lines exist in postgres container logs |
| 4 | Check CloudWatch log streams exist and retrieve events via `get-log-events` |
| 5 | Run `filter-log-events --filter-pattern AUDIT` — simulates the DSF Agentless Gateway pull |

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `DB_INSTANCE_ID` | `mypostgres-dsf` | Must match the instance created by the setup script |
| `DB_MASTER_USER` | `admin` | |
| `DB_MASTER_PASS` | `secret123` | |
| `SLOW_QUERY_MS` | _(unset)_ | If set, also generates a slow query event |
| `AWS_ENDPOINT_URL` | `http://localhost:4566` | |

### Run

```bash
bash service-rds-postgres-test-audit-cloudwatch.sh
```

A passing run looks like:

```
=== Step 2b: Waiting for log shipper to flush events to CloudWatch ===
  [PASS] Log shipper flushed 11 AUDIT event(s) after 3s

=== Step 3: Checking postgres logs inside the container for AUDIT entries ===
  [PASS] Found 47 AUDIT lines in postgres container logs

=== Step 4: Checking CloudWatch log group '/aws/rds/instance/mypostgres-dsf/postgresql' ===
  [PASS] CloudWatch log group has 1 stream(s)
  [PASS] CloudWatch is delivering log events
  [PASS] CloudWatch contains 11 pgaudit AUDIT event(s) — end-to-end verified

=== Step 5: Simulating DSF audit pull via logs:FilterLogEvents ===
  [PASS] filter-log-events returned 11 AUDIT event(s) — DSF pull works
```

## IAM User for DSF Agentless Gateway

`service-iam-dsf-setup.sh` creates a least-privilege IAM user (`dsf-agentless-gateway`) with only the permissions DSF Hub needs. Idempotent — safe to re-run.

### What it creates

| Resource | Name |
|---|---|
| IAM User | `dsf-agentless-gateway` |
| IAM Policy | `DSFAgentlessGatewayPolicy` |
| Access Key | generated on first run (printed once — save it) |

### Run

```bash
bash service-iam-dsf-setup.sh
```

The script prints the key/secret on creation:

```
  ┌─────────────────────────────────────────────────────────────────┐
  │  DSF Agentless Gateway credentials (save these now)            │
  ├─────────────────────────────────────────────────────────────────┤
  │  AWS_ACCESS_KEY_ID     : AKIA...                               │
  │  AWS_SECRET_ACCESS_KEY : ...                                   │
  │  AWS_DEFAULT_REGION    : us-east-1                             │
  │  AWS_ENDPOINT_URL      : http://localhost:4566                 │
  └─────────────────────────────────────────────────────────────────┘
```

To rotate the key, delete it first then re-run:

```bash
KEY_ID=$(aws iam list-access-keys --user-name dsf-agentless-gateway \
  --endpoint-url http://localhost:4566 \
  --query 'AccessKeyMetadata[0].AccessKeyId' --output text)

aws iam delete-access-key --user-name dsf-agentless-gateway \
  --access-key-id "$KEY_ID" --endpoint-url http://localhost:4566

bash service-iam-dsf-setup.sh
```

> **Note:** floci accepts the credentials and creates real-format AWS keys, but does not enforce IAM permission boundaries — any key can call any API locally. The workflow is identical to real AWS and the credentials work directly in DSF Hub.

## Full First-Time Workflow

```bash
# 1. Build custom postgres image (once)
docker build -f Dockerfile.postgres-pgaudit -t local/postgres-pgaudit:16 .

# 2. Start the stack
docker compose up -d

# 3. Wait for floci to be healthy
docker compose logs -f floci   # Ctrl-C when ready

# 4. Create IAM user for DSF (save the printed key/secret)
bash service-iam-dsf-setup.sh

# 5. Create and configure the RDS instance
bash service-rds-postgres-dsf-setup.sh

# 6. Validate audit pipeline
bash service-rds-postgres-test-audit-cloudwatch.sh
```

## Subsequent Runs

The stack is already up and the instance already exists:

```bash
bash service-rds-postgres-test-audit-cloudwatch.sh
```

The setup script is idempotent and safe to re-run if you need to reset the configuration.

## DSF Hub Asset Hierarchy (for reference)

```
AWS Cloud Account
  └── RDS PostgreSQL Instance  (DB identifier: mypostgres-dsf)
        └── AWS Log Group      (/aws/rds/instance/mypostgres-dsf/postgresql)
```

## Required IAM Permissions for DSF Agentless Gateway

```
logs:DescribeLogGroups
logs:DescribeLogStreams
logs:FilterLogEvents
logs:GetLogEvents
rds:DescribeDBInstances
rds:DescribeDBParameterGroups
```

## Useful Commands

```bash

# Get Token
aws sts get-session-token --endpoint-url $AWS_ENDPOINT_URL

# Watch audit logs live from the postgres container
docker logs -f floci-rds-mypostgres-dsf 2>&1 | grep --line-buffered AUDIT

# Check CloudWatch streams
aws logs describe-log-streams \
  --log-group-name /aws/rds/instance/mypostgres-dsf/postgresql \
  --endpoint-url http://localhost:4566

# Pull audit events (what DSF Agentless Gateway does)
aws logs filter-log-events \
  --log-group-name /aws/rds/instance/mypostgres-dsf/postgresql \
  --filter-pattern "AUDIT" \
  --endpoint-url http://localhost:4566

# Watch log shipper activity
docker compose logs -f rds-log-shipper
```
