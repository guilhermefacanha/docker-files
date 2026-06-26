#!/usr/bin/env bash
# Shared env for the RDS-against-floci scripts. Sourced by every rds/* script.
# AWS endpoint/creds/region come from ../00-env.sh; this file adds the
# DB-shared defaults on top. Engine-specific values (DB_INSTANCE_ID, version,
# parameter/option group names) stay in the per-engine scripts because they
# differ across postgres/mysql/mariadb.
#
# Override pattern: see ../00-env.sh — anything you put in floci-local-aws/.env,
# or export inline, beats the defaults below.

# shellcheck source=../00-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/00-env.sh"

# ─── DB-wide defaults (apply to all engines unless overridden) ───────────────
: "${DB_MASTER_USER:=admin}"
: "${DB_MASTER_PASS:=secret123}"
: "${DB_CLASS:=db.t3.micro}"
: "${ALLOCATED_STORAGE:=20}"
: "${LOG_RETENTION_DAYS:=90}"

# ─── Audit management user (used by postgres + mariadb setup scripts) ────────
: "${AUDIT_MGR_USER:=auditmgr}"
: "${AUDIT_MGR_PASS:=AuditMgr\$ecret1}"

export DB_MASTER_USER DB_MASTER_PASS DB_CLASS ALLOCATED_STORAGE LOG_RETENTION_DAYS
export AUDIT_MGR_USER AUDIT_MGR_PASS
