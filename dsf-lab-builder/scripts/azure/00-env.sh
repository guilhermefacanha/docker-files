#!/usr/bin/env bash
# Shared env for all Azure floci-az lab scripts.
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

# ── floci-az endpoint ─────────────────────────────────────────────────────────
: "${FLOCI_AZ_ENDPOINT:=http://localhost:6001}"

# ── Azure resource naming ─────────────────────────────────────────────────────
: "${AZ_SUBSCRIPTION_ID:=00000000-0000-0000-0000-000000000001}"
: "${AZ_RESOURCE_GROUP:=dsf-lab-rg}"
: "${AZ_LOCATION:=eastus}"

export FLOCI_AZ_ENDPOINT AZ_SUBSCRIPTION_ID AZ_RESOURCE_GROUP AZ_LOCATION

# ── DB credentials ────────────────────────────────────────────────────────────
: "${DB_MASTER_USER:=admin}"
: "${DB_MASTER_PASS:=secret123}"
: "${DB_AUDIT_USER:=auditmgr}"
: "${DB_AUDIT_PASS:=AuditMgr\$ecret1}"

export DB_MASTER_USER DB_MASTER_PASS DB_AUDIT_USER DB_AUDIT_PASS

# ── Event Hub config ──────────────────────────────────────────────────────────
: "${AZ_EVENTHUB_NAMESPACE:=dsf-eventhub-az1}"
: "${AZ_EVENTHUB_NAME:=dsf-audit-logs}"

export AZ_EVENTHUB_NAMESPACE AZ_EVENTHUB_NAME

# ── DB proxy port range (for socat host-side proxies) ─────────────────────────
: "${DB_PROXY_BASE_PORT:=9001}"
: "${DB_PROXY_MAX_PORT:=9099}"

export DB_PROXY_BASE_PORT DB_PROXY_MAX_PORT

# ── Educational command tracer ────────────────────────────────────────────────
acurl() {
    printf '[CMD] $ curl %s\n' "$*" >&2
    command curl "$@"
}
export -f acurl

# ── ARM API convenience wrappers ──────────────────────────────────────────────
az_get() {
    acurl -s --fail-with-body "${FLOCI_AZ_ENDPOINT}$1"
}
az_put() {
    local path="$1"; shift
    acurl -s --fail-with-body -X PUT -H "Content-Type: application/json" "${FLOCI_AZ_ENDPOINT}${path}" "$@"
}
az_post() {
    local path="$1"; shift
    acurl -s --fail-with-body -X POST -H "Content-Type: application/json" "${FLOCI_AZ_ENDPOINT}${path}" "$@"
}
az_delete() {
    acurl -s --fail-with-body -X DELETE "${FLOCI_AZ_ENDPOINT}$1"
}
export -f az_get az_put az_post az_delete
