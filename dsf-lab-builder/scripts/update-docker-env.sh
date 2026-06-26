#!/usr/bin/env bash
# Rewrites THIS folder's docker-compose.yml + .env so it runs on a port
# slot that doesn't collide with any container currently shown by `docker ps`.
#
# Use case:
#   cp -r floci-local-aws floci-local-aws-2
#   cd floci-local-aws-2
#   sh update-docker-env.sh        # picks next free slot
#   docker compose up -d           # plain run, no extra flags
#
# Port / account scheme (env N >= 1):
#   floci host port  : 4566 + N         (env 1 = 4567, env 2 = 4568, ...)
#   RDS host range   : (7001+N*100) to (7099+N*100)
#                      (env 1 = 7101-7199, env 2 = 7201-7299, ...)
#   account ID       : str(N) repeated 12 times  (env 1 = 111111111111, ...)
#   network          : floci-env<N>_default
#
# Detection:
#   Scans `docker ps` host-port mappings. Finds the smallest N (1..9) whose
#   floci port (4566+N) AND every port in the RDS range are unbound.
#
# Files edited in place (a .bak alongside each):
#   docker-compose.yml  — port mappings, FLOCI_DEFAULT_ACCOUNT_ID, network
#   .env                — AWS_ENDPOINT_URL + FAM_ACCOUNT_ID for rds/fam scripts
#                         (created if missing; updated if present)
#
# Usage:
#   sh update-docker-env.sh          # auto-pick next available env
#   sh update-docker-env.sh 3        # force env 3 (warns if its ports are busy)
#   sh update-docker-env.sh --show   # report this folder's current values
#   sh update-docker-env.sh --reset  # restore the env-0 defaults

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

COMPOSE="$ROOT/docker-compose.yml"
ENV_FILE="$ROOT/.env"

[ -f "$COMPOSE" ] || { echo "ERROR: $COMPOSE not found." >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# All TCP host ports currently published by any running container.
ports_in_use() {
    docker ps --format '{{.Ports}}' \
        | tr ',' '\n' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -oE '0\.0\.0\.0:[0-9]+(-[0-9]+)?->' \
        | sed -E 's|^0\.0\.0\.0:||; s|->$||' \
        | awk '
            /-/ { split($0,a,"-"); for (p=a[1]; p<=a[2]; p++) print p; next }
            { print $0 }
          ' \
        | sort -un
}

# In-place sed that works on both BSD (macOS) and GNU sed.
portable_sed_inplace() {
    local file="$1"
    local expr="$2"
    if sed --version >/dev/null 2>&1; then
        sed -i.bak -E "$expr" "$file"
    else
        sed -i .bak -E "$expr" "$file"
    fi
}

account_for_env() {
    local n="$1"
    if [ "$n" -lt 1 ] || [ "$n" -gt 9 ]; then
        echo "ERROR: env number must be 1..9 (account ID is N repeated 12 times)" >&2
        exit 1
    fi
    printf '%s' "$n$n$n$n$n$n$n$n$n$n$n$n"
}

# Pick the smallest N (1..9) that has a free floci port + free RDS range.
detect_next_env() {
    local used=$(ports_in_use)
    local n p start end u conflict
    n=1
    while [ "$n" -le 9 ]; do
        p=$((4566 + n))
        start=$((7001 + n * 100))
        end=$((7099 + n * 100))
        if echo "$used" | grep -qx "$p"; then
            n=$((n + 1)); continue
        fi
        conflict=0
        for u in $used; do
            if [ "$u" -ge "$start" ] && [ "$u" -le "$end" ]; then
                conflict=1; break
            fi
        done
        if [ "$conflict" -eq 1 ]; then
            n=$((n + 1)); continue
        fi
        echo "$n"
        return
    done
    echo "ERROR: no free env slot found in range 1..9 (everything is in use)" >&2
    exit 1
}

# Strip a docker-compose parameter expansion (`${VAR:-default}`) down to its
# default value, leaving literal strings untouched.
strip_compose_default() {
    sed -E 's|^\$\{[^:]+:-([^}]+)\}$|\1|'
}

# Read what's currently configured in this folder's docker-compose.yml.
report_current() {
    local floci_port rds_range account network
    floci_port=$(grep -oE '"[^"]*:4566"' "$COMPOSE" | head -1 \
                 | sed -E 's/^"(.*):4566"$/\1/' | strip_compose_default)
    # After a run the compose has literal "NNNN-NNNN:NNNN-NNNN"; in the
    # initial template it has the parameterised ${RDS_HOST_PORT_RANGE:-...} form.
    rds_range=$(grep -oE '"[0-9]+-[0-9]+:[0-9]+-[0-9]+"' "$COMPOSE" | head -1 \
                | tr -d '"' | cut -d: -f1)
    if [ -z "$rds_range" ]; then
        rds_range=$(grep -oE 'RDS_HOST_PORT_RANGE:-[0-9]+-[0-9]+' "$COMPOSE" | head -1 \
                    | sed -E 's/.*:-//')
    fi
    account=$(grep -oE 'FLOCI_DEFAULT_ACCOUNT_ID:[[:space:]]*"[^"]+"' "$COMPOSE" \
                | sed -E 's/.*"([^"]+)".*/\1/' | strip_compose_default)
    network=$(grep -oE 'FLOCI_SERVICES_DOCKER_NETWORK:[[:space:]]*"[^"]+"' "$COMPOSE" \
                | sed -E 's/.*"([^"]+)".*/\1/' | strip_compose_default)
    printf "Folder         : %s\n" "$ROOT"
    printf "floci port     : %s\n" "${floci_port:-?}"
    printf "RDS range      : %s\n" "${rds_range:-?}"
    printf "Account ID     : %s\n" "${account:-?}"
    printf "Network        : %s\n" "${network:-?}"
    if [ -f "$ENV_FILE" ]; then
        printf ".env vars      :\n"
        sed -n 's/^/    /p' "$ENV_FILE"
    else
        printf ".env           : <not present>\n"
    fi
}

# Idempotent upsert into .env: replace the line if present, else append.
upsert_env() {
    local key="$1" val="$2"
    if [ -f "$ENV_FILE" ] && grep -qE "^${key}=" "$ENV_FILE"; then
        portable_sed_inplace "$ENV_FILE" "s|^${key}=.*|${key}=${val}|"
        rm -f "$ENV_FILE.bak"
    else
        [ -f "$ENV_FILE" ] || cat > "$ENV_FILE" <<EOF
# Local env for this floci-local-aws copy. Overrides defaults from 00-env.sh.
# Values are also picked up by docker compose's automatic .env loader.
EOF
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
}

# Strip lines from .env matching a regex. No-op if the file doesn't exist.
strip_env() {
    local pattern="$1"
    [ -f "$ENV_FILE" ] || return 0
    portable_sed_inplace "$ENV_FILE" "/${pattern}/d"
    rm -f "$ENV_FILE.bak"
}

# Apply (port, range, account, network, env_label) to docker-compose.yml +
# .env in place. env_label is "env<N>" for envs >=1, or "" for env 0 (reset).
apply_env() {
    local floci_port="$1"
    local rds_range="$2"
    local account="$3"
    local network="$4"
    local env_label="$5"   # e.g. "env1", or "" for env 0
    local suffix=""
    [ -n "$env_label" ] && suffix="-${env_label}"

    # ── docker-compose.yml ───────────────────────────────────────────────
    # Replace the floci host-port mapping. Matches both the parameterized
    # form `"${FLOCI_HOST_PORT:-4566}:4566"` and any literal `"NNNN:4566"`.
    portable_sed_inplace "$COMPOSE" \
        "s|\"[^\"]+:4566\"|\"${floci_port}:4566\"|"

    # Replace the RDS range mapping (both host and container sides).
    # Two passes: one for the literal form produced by previous runs, one for
    # the parameterized ${RDS_HOST_PORT_RANGE:-...} form in the initial template.
    local rds_start="${rds_range%%-*}"
    local rds_end="${rds_range##*-}"
    portable_sed_inplace "$COMPOSE" \
        "s|\"[0-9]+-[0-9]+:[0-9]+-[0-9]+\"|\"${rds_range}:${rds_range}\"|"
    portable_sed_inplace "$COMPOSE" \
        "s|\"[^\"]*RDS_HOST_PORT_RANGE[^\"]*\"|\"${rds_range}:${rds_range}\"|"

    # Keep FLOCI_SERVICES_RDS_PROXY_BASE_PORT / MAX_PORT in sync with the range.
    portable_sed_inplace "$COMPOSE" \
        "s|(FLOCI_SERVICES_RDS_PROXY_BASE_PORT:[[:space:]]*\")[^\"]+(\")|\\1${rds_start}\\2|"
    portable_sed_inplace "$COMPOSE" \
        "s|(FLOCI_SERVICES_RDS_PROXY_MAX_PORT:[[:space:]]*\")[^\"]+(\")|\\1${rds_end}\\2|"

    # Replace FLOCI_DEFAULT_ACCOUNT_ID value.
    portable_sed_inplace "$COMPOSE" \
        "s|(FLOCI_DEFAULT_ACCOUNT_ID:[[:space:]]*\")[^\"]+(\")|\\1${account}\\2|"

    # Replace FLOCI_SERVICES_DOCKER_NETWORK value.
    portable_sed_inplace "$COMPOSE" \
        "s|(FLOCI_SERVICES_DOCKER_NETWORK:[[:space:]]*\")[^\"]+(\")|\\1${network}\\2|"

    # Replace the network's `name:` line (only one occurrence in this file).
    portable_sed_inplace "$COMPOSE" \
        "s|(name:[[:space:]]*\")[^\"]+(\")|\\1${network}\\2|"

    rm -f "$COMPOSE.bak"

    # ── .env ─────────────────────────────────────────────────────────────
    # Always set the AWS endpoint + account ID (these need to differ even
    # for env 0 if you eventually shift the default elsewhere).
    upsert_env AWS_ENDPOINT_URL "http://localhost:${floci_port}"
    upsert_env FAM_ACCOUNT_ID   "${account}"

    # Per-env names: only on apply; on reset (env_label="") strip them so
    # rds/fam scripts fall back to the un-suffixed defaults from 00-env.sh.
    if [ -n "$env_label" ]; then
        # ENV_SUFFIX drives DB_INSTANCE_ID defaults across all engines
        # (mypostgres${ENV_SUFFIX:-}-dsf, mymysql..., mymariadb...).
        upsert_env ENV_SUFFIX                 "${suffix}"
        # FAM_* are written explicitly so .env reads as self-documenting.
        # The fam/00-env.sh defaults would derive the same names from
        # ENV_SUFFIX, but having them here lets you tweak individually.
        upsert_env FAM_USER_NAME              "fam-user${suffix}"
        upsert_env FAM_SOURCE_BUCKET          "fam-lab-source${suffix}"
        upsert_env FAM_LOG_DESTINATION_BUCKET "fam-lab-logs${suffix}"
        upsert_env FAM_TRAIL_NAME             "fam-cloudtrail${suffix}"
    else
        strip_env '^(ENV_SUFFIX|FAM_USER_NAME|FAM_SOURCE_BUCKET|FAM_LOG_DESTINATION_BUCKET|FAM_TRAIL_NAME)='
    fi
}

# ── Subcommands ──────────────────────────────────────────────────────────────

cmd_show() {
    report_current
}

cmd_reset() {
    # env_label="" → no suffix, strips the per-env keys.
    apply_env "4566" "7001-7099" "000000000000" "floci-local-aws_default" ""
    # Also strip the AWS endpoint + account-ID lines so rds/fam scripts
    # fall all the way back to 00-env.sh defaults.
    strip_env '^(AWS_ENDPOINT_URL|FAM_ACCOUNT_ID)='
    echo "Reset to env 0 defaults (port 4566, account 000000000000, no ENV_SUFFIX)."
    cmd_show
}

cmd_apply() {
    local N="$1"
    if [ -z "$N" ]; then
        N=$(detect_next_env)
        echo "Auto-detected next available env: ${N}"
    else
        case "$N" in
            ''|*[!0-9]*) echo "ERROR: env number must be a positive integer" >&2; exit 1 ;;
        esac
        if [ "$N" -lt 1 ] || [ "$N" -gt 9 ]; then
            echo "ERROR: env number must be 1..9" >&2; exit 1
        fi
        # Warn if forced N's ports are busy.
        local used p start end u
        used=$(ports_in_use)
        p=$((4566 + N))
        start=$((7001 + N * 100))
        end=$((7099 + N * 100))
        if echo "$used" | grep -qx "$p"; then
            echo "WARNING: forced env ${N} but host port ${p} is already in use." >&2
        fi
        for u in $used; do
            if [ "$u" -ge "$start" ] && [ "$u" -le "$end" ]; then
                echo "WARNING: forced env ${N} but RDS host port ${u} is already in use." >&2
                break
            fi
        done
    fi

    local floci_port=$((4566 + N))
    local rds_start=$((7001 + N * 100))
    local rds_end=$((7099 + N * 100))
    local rds_range="${rds_start}-${rds_end}"
    local account
    account=$(account_for_env "$N")
    local network="floci-env${N}_default"

    apply_env "$floci_port" "$rds_range" "$account" "$network" "env${N}"

    cat <<EOF

=== Updated this folder for env ${N} ===
$(report_current)

Resolved per-env names (also written to .env so the rds/fam scripts pick
them up automatically — no manual ENV_SUFFIX override needed):
  Postgres DB instance : mypostgres-env${N}-dsf
  MySQL    DB instance : mymysql-env${N}-dsf
  MariaDB  DB instance : mymariadb-env${N}-dsf
  FAM IAM user         : fam-user-env${N}
  FAM source bucket    : fam-lab-source-env${N}
  FAM log bucket       : fam-lab-logs-env${N}
  FAM CloudTrail trail : fam-cloudtrail-env${N}

Bring it up:
  docker-compose up -d
EOF
}

main() {
    case "${1:-}" in
        ''|--auto)        cmd_apply "" ;;
        --show)           cmd_show ;;
        --reset)          cmd_reset ;;
        -h|--help)        sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#$//'; exit 0 ;;
        *)                cmd_apply "$1" ;;
    esac
}

main "$@"
