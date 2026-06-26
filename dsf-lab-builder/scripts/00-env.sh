#!/usr/bin/env bash
# Shared env for ALL floci-local-aws scripts (rds/* and fam/*).
# Sourced indirectly via rds/00-env.sh and fam/00-env.sh — you don't need
# to source it directly unless you're in another folder.
#
# Override pattern (in priority order, earliest wins):
#   1. inline    : `DB_MASTER_PASS=foo sh rds/service-rds-mysql-dsf-setup.sh`
#   2. exported  : `export DB_MASTER_PASS=foo` in your shell, then run scripts
#   3. .env file : drop floci-local-aws/.env with KEY=value lines (sourced below)
#   4. defaults  : the `: "${VAR:=...}"` lines here
#
# All `: "${VAR:=default}"` only assigns when VAR is unset/empty, so anything
# already in the environment (1, 2, 3) wins over the default.

# ─── Optional .env override file ──────────────────────────────────────────────
# floci-local-aws/.env is a flat KEY=value file. Lines are read individually
# and only applied when the var is NOT already set, so inline `VAR=foo sh ...`
# and `export VAR=foo` keep priority over .env.
_FLOCI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_FLOCI_ROOT/.env" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        # Strip leading whitespace; skip blanks and comments.
        case "$_line" in
            ''|\#*|[[:space:]]*\#*) continue ;;
        esac
        # Only handle KEY=VALUE lines.
        case "$_line" in
            *=*) ;;
            *) continue ;;
        esac
        _key="${_line%%=*}"
        _val="${_line#*=}"
        # Trim surrounding quotes if present.
        case "$_val" in
            \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;
            \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
        esac
        # Skip malformed keys (must match POSIX shell var-name pattern).
        case "$_key" in
            [a-zA-Z_]*) ;;
            *) continue ;;
        esac
        case "$_key" in
            *[!a-zA-Z0-9_]*) continue ;;
        esac
        # Only set if currently unset (so inline / pre-exported wins).
        # POSIX-safe via eval; _key was validated above.
        eval "_is_set=\${$_key+x}"
        if [ -z "$_is_set" ]; then
            export "$_key=$_val"
        fi
    done < "$_FLOCI_ROOT/.env"
    unset _line _key _val _is_set
fi

# ─── AWS / floci endpoint (shared by rds + fam) ──────────────────────────────
: "${AWS_ENDPOINT_URL:=http://localhost:4566}"
: "${AWS_ACCESS_KEY_ID:=test}"
: "${AWS_SECRET_ACCESS_KEY:=test}"
: "${AWS_DEFAULT_REGION:=us-east-1}"

export AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

# ── Educational command tracer ───────────────────────────────────────────────
# Intercepts every `aws` call and prints the full command to stderr so it
# appears in the job output log.  Variable-capture subshells ($(...)) are
# unaffected because only stdout is captured — trace always goes to stderr.
aws() {
    printf '[CMD] $ aws %s\n' "$*" >&2
    command aws "$@"
}
export -f aws
