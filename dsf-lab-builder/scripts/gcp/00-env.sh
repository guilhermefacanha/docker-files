#!/usr/bin/env bash
# Shared env for all GCP floci scripts.
# Override pattern: .env file → inline VAR=value → defaults below.

_FLOCI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_FLOCI_ROOT/.env" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|\#*|[[:space:]]*\#*) continue ;; esac
        case "$_line" in *=*) ;; *) continue ;; esac
        _key="${_line%%=*}"; _val="${_line#*=}"
        case "$_val" in \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;; \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;; esac
        case "$_key" in [a-zA-Z_]*) ;; *) continue ;; esac
        case "$_key" in *[!a-zA-Z0-9_]*) continue ;; esac
        eval "_is_set=\${$_key+x}"
        if [ -z "$_is_set" ]; then export "$_key=$_val"; fi
    done < "$_FLOCI_ROOT/.env"
    unset _line _key _val _is_set
fi

# ── GCP / floci-gcp endpoint ─────────────────────────────────────────────────
: "${GCP_ENDPOINT_URL:=http://localhost:4588}"
: "${GCP_PROJECT_ID:=floci-gcp-lab}"
: "${GCP_REGION:=us-central1}"

export GCP_ENDPOINT_URL GCP_PROJECT_ID GCP_REGION

# ── DB credentials ────────────────────────────────────────────────────────────
: "${DB_MASTER_USER:=admin}"
: "${DB_MASTER_PASS:=secret123}"
: "${DB_AUDIT_USER:=auditmgr}"
: "${DB_AUDIT_PASS:=AuditMgr\$ecret1}"

export DB_MASTER_USER DB_MASTER_PASS DB_AUDIT_USER DB_AUDIT_PASS

# ── GCP resource naming ───────────────────────────────────────────────────────
: "${LOG_SINK_NAME:=dsf-cloudsql-sink}"
: "${SERVICE_ACCOUNT_ID:=dsf-gateway}"

export LOG_SINK_NAME SERVICE_ACCOUNT_ID

# ── Educational command tracer ────────────────────────────────────────────────
gcurl() {
    printf '[CMD] $ curl %s\n' "$*" >&2
    command curl "$@"
}
export -f gcurl
