# FAM lab against floci

End-to-end FAM (File Activity Monitoring) S3 onboarding flow run against a
local floci endpoint at `http://localhost:4566` instead of real AWS.
The scripts here are the floci variants of the real-AWS scripts in
`aws_client/scripts/` — same flow, same defaults adjusted for floci.

```
fam/
├─ 00-env.sh                  shared env (sourced by every script)
├─ 01-create-fam-user.sh      IAM user + access key for FAM
├─ 02-setup-fam-resources.sh  buckets, bucket policy, CloudTrail trail
├─ 03-test-traffic.sh         small one-shot traffic check
├─ 04-show-fam-asset-info.sh  values to paste into the DSF Hub UI
├─ 05-create-actors.sh        N IAM actors (privileged + regular tiers)
├─ 06-simulate-activity.py    continuous traffic simulator
└─ 99-cleanup.sh              tears everything down
```

## Table of Contents

* [Prerequisites](#prerequisites)
* [1. Start floci](#1-start-floci)
* [2. Run the flow](#2-run-the-flow)
* [3. Verify logs are landing](#3-verify-logs-are-landing)
* [4. Onboard in DSF Hub](#4-onboard-in-dsf-hub)
* [5. Cleanup](#5-cleanup)
* [Overriding defaults](#overriding-defaults)
* [Troubleshooting](#troubleshooting)


## Prerequisites

- Docker Desktop with `docker compose`
- `aws` CLI v2, `jq`, `python3`, `boto3` (`pip install boto3`)

## 1. Start floci

From `floci-local-aws/`:

```bash
docker compose up -d floci
```

The compose file pins `FLOCI_DEFAULT_ACCOUNT_ID=000000000000` by default. To
align with the real-AWS sample account in `aws_client/sample/`, override
it to `264284393402` (matches `FAM_ACCOUNT_ID` in `00-env.sh`):

```bash
FLOCI_DEFAULT_ACCOUNT_ID=000000000000 docker compose up -d floci
```

Verify floci is up:

```bash
aws --endpoint-url http://localhost:4566 sts get-caller-identity
```

## 2. Run the flow

From `floci-local-aws/fam/`:

```bash
./01-create-fam-user.sh           # IAM user + access key (saved to ./data/fam-user.env)
./02-setup-fam-resources.sh       # source + log buckets, CloudTrail trail
./05-create-actors.sh             # 10 IAM actors (3 privileged, 7 regular)
./04-show-fam-asset-info.sh       # print values to paste into DSF Hub UI
FAM_SOURCE_BUCKET=fam-lab-source python3 ./06-simulate-activity.py # continuous traffic — Ctrl+C to stop
```

Use `./03-test-traffic.sh` between steps 02 and 05 for a quick smoke check
(single PUT/GET/LIST/DELETE) before unleashing the simulator.

## 3. Verify logs are landing

Floci flushes pending CloudTrail records every ~60s
(`FLOCI_SERVICES_CLOUDTRAIL_FLUSH_INTERVAL_SECONDS` in `docker-compose.yml`,
drop to ~10 for faster iteration). After a minute of simulator traffic:

```bash
aws --endpoint-url http://localhost:4566 \
    s3 ls s3://fam-lab-logs/AWSLogs/ --recursive
```

You should see CloudTrail JSON objects under `AWSLogs/<account-id>/CloudTrail/`.

## 4. Onboard in DSF Hub

Run `./04-show-fam-asset-info.sh` and paste the printed values into the
DSF Hub onboarding wizard. Order matters:

1. **Add cloud account** — Auth Mechanism: Key, Secret Manager: OFF, paste
   the FAM access key + secret. Set the endpoint override to floci's URL
   (the script prints exact wording).
2. **Onboard the LOG DESTINATION bucket first** (`fam-lab-logs`) with
   "Used as a log destination" checked.
3. **Onboard the DATA SOURCE bucket** (`fam-lab-source`) and point its
   "Log destination" at the bucket from step 2.

## 5. Cleanup

```bash
./99-cleanup.sh                   # interactive; SKIP_CONFIRM=1 to skip prompt
```

Removes the trail, both buckets, the FAM user, all actor users, and the
local `fam/data/` artifacts.

## Overriding defaults

Each script sources `fam/00-env.sh`, which in turn sources the project-wide
`floci-local-aws/00-env.sh`. Both files are pure defaults — anything you
already have in the environment wins.

**Priority** (earliest wins):

1. **Inline** — `FAM_SOURCE_BUCKET=mybucket ./02-setup-fam-resources.sh`
2. **Pre-exported** — `export FAM_SOURCE_BUCKET=mybucket` in your shell, then run scripts
3. **`.env` file** — drop a `floci-local-aws/.env` (gitignored) with `KEY=value` lines.
   Shared with the `rds/*` scripts, so it's the right place for project-wide
   overrides. Copy `floci-local-aws/.env.example` to start.
4. **Defaults** — the `: "${VAR:=…}"` lines in `00-env.sh`

The `.env` loader only sets vars that are currently unset, so inline / pre-exported
always beats `.env`.

| Var | Default | Why |
|---|---|---|
| `AWS_ENDPOINT_URL` | `http://localhost:4566` | Where floci listens (defined in root `00-env.sh`) |
| `FAM_ACCOUNT_ID` | `000000000000` | Should match `FLOCI_DEFAULT_ACCOUNT_ID` |
| `FAM_USER_NAME` | `fam-user` | The FAM IAM user |
| `FAM_SOURCE_BUCKET` | `fam-lab-source` | The audited bucket |
| `FAM_LOG_DESTINATION_BUCKET` | `fam-lab-logs` | Where CloudTrail logs land |
| `FAM_TRAIL_NAME` | `fam-cloudtrail` | CloudTrail trail name |
| `FAM_ACTOR_COUNT` | `10` | Total actors (script 05) |
| `FAM_PRIVILEGED_COUNT` | `3` | Privileged actors out of the total |
| `DATA_DIR` | `<fam/data>` | Where `actors.json` and `fam-user.env` live |

## Troubleshooting

- **`./01-create-fam-user.sh` says key already exists** — delete it first
  if you need a new one:
  `aws iam delete-access-key --user-name fam-user --access-key-id <id>`
- **Logs never appear in `fam-lab-logs`** — confirm the trail is logging:
  `aws cloudtrail get-trail-status --name fam-cloudtrail`. If `IsLogging`
  is false, re-run `./02-setup-fam-resources.sh`.
- **Account-ID mismatch warning from script 02** — restart floci with
  `FLOCI_DEFAULT_ACCOUNT_ID=000000000000` so emitted CloudTrail records
  line up with what FAM was onboarded against.
- **Simulator can't find `actors.json`** — run `./05-create-actors.sh`
  first; it writes to `./data/actors.json`.
