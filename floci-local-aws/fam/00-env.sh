#!/usr/bin/env bash
# Shared env for the FAM-against-floci lab. Sourced by every fam/* script.
# AWS endpoint/creds/region come from ../00-env.sh; this file only adds the
# FAM-specific bits on top.
#
# Override pattern: see ../00-env.sh — anything you put in floci-local-aws/.env,
# or export inline, beats the defaults below.

# shellcheck source=../00-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/00-env.sh"

# FAM_ACCOUNT_ID must match FLOCI_DEFAULT_ACCOUNT_ID (set in docker-compose.yml
# or .env). The DSF Hub stores this as the cloud account's bucket_account_id
# and the gateway looks for log files under AWSLogs/<FAM_ACCOUNT_ID>/CloudTrail.
# If these differ, the gateway connects successfully but finds zero log files.
# Default mirrors floci's stock default; override via .env or inline export.
: "${FAM_ACCOUNT_ID:=${FLOCI_DEFAULT_ACCOUNT_ID:-000000000000}}"

# ENV_SUFFIX (e.g. "-env1") lets duplicated folders run side-by-side without
# colliding on FAM resource names. update-docker-env.sh writes it into .env;
# leave it unset for the default (no suffix).
: "${FAM_USER_NAME:=fam-user${ENV_SUFFIX:-}}"
: "${FAM_SOURCE_BUCKET:=fam-lab-source${ENV_SUFFIX:-}}"
: "${FAM_LOG_DESTINATION_BUCKET:=fam-lab-logs${ENV_SUFFIX:-}}"
: "${FAM_TRAIL_NAME:=fam-cloudtrail${ENV_SUFFIX:-}}"

# Where 05-create-actors writes actors.json and 06-simulate-activity reads it.
: "${DATA_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/data}"
mkdir -p "$DATA_DIR"

export FAM_ACCOUNT_ID FAM_USER_NAME FAM_SOURCE_BUCKET FAM_LOG_DESTINATION_BUCKET
export FAM_TRAIL_NAME DATA_DIR
