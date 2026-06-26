# Floci Local AWS Environment

Local AWS emulation stack using [floci](https://floci.io), providing RDS (PostgreSQL), DynamoDB, Athena, S3, and CloudWatch — all running locally via Docker Compose. Designed for developing and testing applications that target AWS services without incurring cloud costs.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ docker-compose stack                                         │
│                                                              │
│  docker-proxy  ──TCP:2375──►  /var/run/docker.sock          │
│      ▲                                                       │
│      │ FLOCI_DOCKER_DOCKER_HOST                              │
│  floci (port 4566)          ◄── AWS CLI / SDKs              │
│      │ spawns                                                │
│      ▼                                                       │
│  floci-rds-<id>  (postgres containers)                       │
│      │ docker logs                                           │
│      ▼                                                       │
│  rds-log-shipper ──put-log-events──► floci CloudWatch        │
└─────────────────────────────────────────────────────────────┘
```

**Why docker-proxy?** On macOS Docker Desktop, floci's GraalVM binary cannot bind to the Docker Unix socket directly (permissions issue). The `alpine/socat` proxy exposes the socket over TCP, which floci connects to without any socket permissions problem. This works identically on Linux/Ubuntu.

## Prerequisites

- **Docker Desktop** (macOS/Windows) or **Docker Engine** (Linux): [https://www.docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop)
- **AWS CLI**: [https://aws.amazon.com/cli/](https://aws.amazon.com/cli/)
- **jq**: `brew install jq` / `apt install jq`

## First-Time Setup

### 1. Build the custom PostgreSQL image

The default `postgres:16-alpine` does not include `pgaudit`. Build the custom image once:

```bash
docker build -f Dockerfile.postgres-pgaudit -t local/postgres-pgaudit:16 .
```

### 2. Start the stack

```bash
docker compose up -d
```

Watch floci come up:

```bash
docker compose logs -f floci
```

Wait until you see floci accepting requests (health check passes) before running setup scripts.

### 3. Verify all services are running

```bash
docker compose ps
```

Expected services: `docker-proxy`, `floci`, `rds-log-shipper`.

## Services

| Service | Description |
|---|---|
| `docker-proxy` | socat bridge — exposes Docker socket over TCP for floci |
| `floci` | Local AWS emulator (RDS, DynamoDB, S3, Athena, CloudWatch, ...) on port 4566 |
| `rds-log-shipper` | Sidecar that tails RDS container logs and ships them to floci's CloudWatch |

## Connecting to PostgreSQL via DBeaver

After creating an RDS instance, get the endpoint:

```bash
aws rds describe-db-instances \
  --db-instance-identifier mypostgres-dsf \
  --query 'DBInstances[0].Endpoint' \
  --endpoint-url http://localhost:4566 \
  --output json
```

Use the returned `Address` and `Port` in DBeaver with:

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | (from output, e.g. `7001`) |
| Database | `postgres` |
| Username | `admin` |
| Password | `secret123` |

Disable SSL for local connections.

## Common AWS CLI Examples

All commands require `--endpoint-url http://localhost:4566`.

```bash
# List S3 buckets
aws s3 ls --endpoint-url http://localhost:4566

# Describe an RDS instance
aws rds describe-db-instances \
  --db-instance-identifier mypostgres-dsf \
  --endpoint-url http://localhost:4566

# List CloudWatch log groups
aws logs describe-log-groups --endpoint-url http://localhost:4566

# Create an SQS queue
aws sqs create-queue --queue-name my-test-queue --endpoint-url http://localhost:4566
```

## Available Scripts

| Script | Purpose |
|---|---|
| `service-iam-dsf-setup.sh` | Create IAM user + policy for DSF Agentless Gateway (least-privilege) |
| `service-rds-postgres-dsf-setup.sh` | Create and configure a PostgreSQL RDS instance for DSF Hub audit |
| `service-rds-postgres-test-audit-cloudwatch.sh` | Generate audit events and validate they appear in CloudWatch |
| `service-dynamodb-cli.sh` | Interactive DynamoDB table and data management |
| `service-athena-cli.sh` | Interactive Athena query runner |
| `service-rds-init.sh` | Basic RDS init (non-DSF) |
| `service-dynamodb-init.sh` | DynamoDB table initialization |
| `service-s3-init.sh` | S3 bucket initialization |

See [DSF_README.md](DSF_README.md) for full DSF Hub audit source setup documentation.

## Stopping the Environment

```bash
docker compose down
```

To also remove persisted floci data:

```bash
docker compose down && rm -rf data/
```
