#!/usr/bin/env python3
"""
RDS → CloudWatch log shipper for floci local emulation.

Detects engine per container (Postgres / MySQL / MariaDB) and ships its
logs to the matching CloudWatch log group:

  Postgres : /aws/rds/instance/<db-id>/postgresql
  MySQL    : /aws/rds/instance/<db-id>/audit
  MariaDB  : /aws/rds/instance/<db-id>/audit

Works with zero, one, or both engines running — a shipper thread is
only spawned when a recognised floci-rds-<db-id> container is present.
Threads start/stop as containers come and go; the shipper itself can
run indefinitely with no databases.

Log source per engine:

  Postgres
    `docker logs --follow --timestamps`. pgaudit writes to the
    Postgres log stream which Postgres sends to stderr → Docker stdout,
    so docker logs is the right place.

  MySQL / MariaDB
    Real RDS writes MARIADB_AUDIT_PLUGIN events to a file at
    `/rdsdbdata/log/audit/server_audit.log`. In a local container the
    plugin writes to whatever `server_audit_file_path` points at —
    commonly `/var/lib/mysql/server_audit.log`. The shipper probes a
    list of standard paths via `docker exec test -f` and, if it finds
    one, tails it with `docker exec tail -F`. If no audit file exists
    yet (plugin not loaded by the container image), the shipper falls
    back to `docker logs` so the audit log stream at least exists and
    keeps emitting heartbeat events.
"""

import os
import shlex
import subprocess
import threading
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# ── Config ────────────────────────────────────────────────────────────────────
ENDPOINT_URL   = os.environ.get("AWS_ENDPOINT_URL",     "http://floci:4566")
REGION         = os.environ.get("AWS_DEFAULT_REGION",   "us-east-1")
ACCESS_KEY     = os.environ.get("AWS_ACCESS_KEY_ID",    "test")
SECRET_KEY     = os.environ.get("AWS_SECRET_ACCESS_KEY","test")
POLL_INTERVAL  = int(os.environ.get("POLL_INTERVAL",    "10"))   # seconds between container scans
FLUSH_INTERVAL = float(os.environ.get("FLUSH_INTERVAL", "2.0"))  # seconds between CW puts
BATCH_SIZE     = int(os.environ.get("BATCH_SIZE",       "100"))  # max events per put-log-events

CONTAINER_PREFIX = "floci-rds-"

# Per-shipper state (engine, fallback flag) so the main loop can restart a
# thread if a MySQL/MariaDB audit file appears after attach. Populated by
# ship_container() and read in main().
SHIPPER_STATE: dict[str, dict] = {}

# Per-engine configuration.
#   log_subpath        — CloudWatch log group suffix (mirrors real RDS)
#   stream_subpath     — log stream path component
#   audit_file_paths   — candidate locations for the audit file (MySQL/MariaDB)
ENGINE_CONFIG = {
    "postgresql": {
        "log_subpath":      "postgresql",
        "stream_subpath":   "postgresql",
        "audit_file_paths": [],
    },
    "mysql": {
        "log_subpath":      "audit",
        "stream_subpath":   "audit",
        "audit_file_paths": [
            "/rdsdbdata/log/audit/server_audit.log",
            "/var/lib/mysql/server_audit.log",
            "/var/log/mysql/server_audit.log",
        ],
    },
    "mariadb": {
        "log_subpath":      "audit",
        "stream_subpath":   "audit",
        "audit_file_paths": [
            "/rdsdbdata/log/audit/server_audit.log",
            "/var/lib/mysql/server_audit.log",
            "/var/log/mysql/server_audit.log",
        ],
    },
}
# ──────────────────────────────────────────────────────────────────────────────


def cw_client():
    return boto3.client(
        "logs",
        endpoint_url=ENDPOINT_URL,
        region_name=REGION,
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
    )


def parse_ts_ms(ts_str: str) -> int:
    """Parse Docker --timestamps output to epoch milliseconds."""
    try:
        # Docker emits e.g. "2026-06-03T01:23:45.123456789Z"
        # strptime only handles up to microseconds — truncate nanoseconds
        clean = ts_str[:26]
        dt = datetime.strptime(clean, "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1000)
    except Exception:
        return int(time.time() * 1000)


def ensure_log_stream(client, log_group: str, log_stream: str) -> None:
    try:
        client.create_log_stream(logGroupName=log_group, logStreamName=log_stream)
        print(f"[shipper] Created stream: {log_group}/{log_stream}", flush=True)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceAlreadyExistsException":
            raise


def ensure_log_group(client, log_group: str) -> None:
    try:
        client.create_log_group(logGroupName=log_group)
        print(f"[shipper] Created log group: {log_group}", flush=True)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceAlreadyExistsException":
            raise


def put_batch(client, log_group: str, log_stream: str,
              batch: list, sequence_token: str | None) -> str | None:
    """Push a sorted batch of events; return the next sequence token."""
    if not batch:
        return sequence_token

    events = sorted(batch, key=lambda e: e["timestamp"])
    kwargs = dict(logGroupName=log_group, logStreamName=log_stream, logEvents=events)
    if sequence_token:
        kwargs["sequenceToken"] = sequence_token

    try:
        resp = client.put_log_events(**kwargs)
        return resp.get("nextSequenceToken")
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("InvalidSequenceTokenException", "DataAlreadyAcceptedException"):
            # Retry without sequence token — floci may not enforce strict ordering
            kwargs.pop("sequenceToken", None)
            resp = client.put_log_events(**kwargs)
            return resp.get("nextSequenceToken")
        print(f"[shipper] put_log_events error ({code}): {e}", flush=True)
        return sequence_token


# ── Engine detection ─────────────────────────────────────────────────────────
def docker_inspect(container: str, fmt: str) -> str:
    result = subprocess.run(
        ["docker", "inspect", "--format", fmt, container],
        capture_output=True, text=True,
    )
    return result.stdout.strip()


def detect_engine(container: str) -> str | None:
    """Return 'postgresql', 'mysql', 'mariadb', or None."""
    image = docker_inspect(container, "{{.Config.Image}}").lower()

    # Order matters: 'mariadb' before 'mysql' (mariadb images may contain
    # 'mysql' in tags), and 'postgres' as its own family.
    if "postgres" in image:
        return "postgresql"
    if "mariadb" in image:
        return "mariadb"
    if "mysql" in image:
        return "mysql"

    # Fallback: inspect exposed ports
    ports = docker_inspect(
        container,
        "{{range $p, $_ := .NetworkSettings.Ports}}{{$p}} {{end}}",
    )
    if "5432" in ports:
        return "postgresql"
    if "3306" in ports:
        # Can't distinguish MySQL vs MariaDB from port alone; default to mysql
        return "mysql"

    return None


def find_audit_file(container: str, candidates: list[str]) -> str | None:
    """Probe candidate paths inside the container; return the first that exists."""
    for path in candidates:
        result = subprocess.run(
            ["docker", "exec", container, "test", "-f", path],
            capture_output=True,
        )
        if result.returncode == 0:
            return path
    return None


def build_log_source_cmd(container: str, engine: str) -> tuple[list[str], bool]:
    """Return (command, has_docker_timestamps).

    Postgres → docker logs (timestamps present).
    MySQL/MariaDB → tail audit file if present (no timestamps), else fall
    back to docker logs (timestamps present).
    """
    cfg = ENGINE_CONFIG[engine]

    if engine == "postgresql":
        return (
            ["docker", "logs", "--follow", "--timestamps", container],
            True,
        )

    # MySQL / MariaDB: prefer audit file
    audit_file = find_audit_file(container, cfg["audit_file_paths"])
    if audit_file:
        print(
            f"[shipper] {container}: tailing audit file {audit_file}",
            flush=True,
        )
        # `tail -F` keeps following across rotations
        return (
            ["docker", "exec", container, "tail", "-n", "0", "-F", audit_file],
            False,
        )

    print(
        f"[shipper] {container}: no MariaDB audit file found in "
        f"{', '.join(cfg['audit_file_paths'])} — falling back to docker logs. "
        f"DSF will see the log stream but not real audit events until the "
        f"MARIADB_AUDIT_PLUGIN is loaded in the container.",
        flush=True,
    )
    return (
        ["docker", "logs", "--follow", "--timestamps", container],
        True,
    )


# ── Shipper thread ───────────────────────────────────────────────────────────
def ship_container(container_name: str, stop_event: threading.Event) -> None:
    """Tail a single container's logs and ship to CloudWatch."""
    engine = detect_engine(container_name)
    if engine is None:
        print(
            f"[shipper] Could not determine engine for {container_name} — "
            f"skipping (no postgres/mysql/mariadb signal in image or ports).",
            flush=True,
        )
        return

    cfg = ENGINE_CONFIG[engine]
    db_id      = container_name[len(CONTAINER_PREFIX):]
    log_group  = f"/aws/rds/instance/{db_id}/{cfg['log_subpath']}"
    log_stream = datetime.utcnow().strftime("%Y/%m/%d") + f"/{cfg['stream_subpath']}/0"

    print(
        f"[shipper] Starting {engine} shipper for {container_name} → {log_group}",
        flush=True,
    )

    client = cw_client()
    ensure_log_group(client, log_group)
    ensure_log_stream(client, log_group, log_stream)

    cmd, has_docker_ts = build_log_source_cmd(container_name, engine)
    # Stash whether we're using the "docker logs" fallback so the main loop
    # can restart this thread if an audit file appears later (the audit file
    # is typically created after the plugin is INSTALLed by the test script).
    SHIPPER_STATE[container_name] = {
        "engine": engine,
        "fallback": (cmd[1] == "logs") if engine in ("mysql", "mariadb") else False,
    }
    print(f"[shipper] {container_name}: source = `{shlex.join(cmd)}`", flush=True)

    sequence_token: str | None = None
    batch: list = []
    last_flush   = time.time()

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    try:
        for raw_line in proc.stdout:
            if stop_event.is_set():
                break

            line = raw_line.rstrip()
            if not line:
                continue

            if has_docker_ts:
                parts = line.split(" ", 1)
                ts_ms   = parse_ts_ms(parts[0]) if len(parts) == 2 else int(time.time() * 1000)
                message = parts[1] if len(parts) == 2 else line
            else:
                # Audit-file tail — no leading timestamp; use arrival time
                ts_ms   = int(time.time() * 1000)
                message = line

            batch.append({"timestamp": ts_ms, "message": message})

            now = time.time()
            if len(batch) >= BATCH_SIZE or (now - last_flush) >= FLUSH_INTERVAL:
                sequence_token = put_batch(client, log_group, log_stream, batch, sequence_token)
                batch     = []
                last_flush = now

        # Flush remainder
        if batch:
            put_batch(client, log_group, log_stream, batch, sequence_token)

    finally:
        proc.kill()
        proc.wait()
        print(f"[shipper] Stopped {engine} shipper for {container_name}", flush=True)


def list_rds_containers() -> list[str]:
    result = subprocess.run(
        ["docker", "ps", "--filter", f"name={CONTAINER_PREFIX}", "--format", "{{.Names}}"],
        capture_output=True, text=True,
    )
    return [n.strip() for n in result.stdout.strip().splitlines() if n.strip()]


def main() -> None:
    print(
        f"[shipper] Log shipper started (endpoint={ENDPOINT_URL}, poll={POLL_INTERVAL}s)",
        flush=True,
    )
    print(
        f"[shipper] Supported engines: {', '.join(sorted(ENGINE_CONFIG))}. "
        f"Idle until a floci-rds-* container appears.",
        flush=True,
    )

    shippers: dict[str, tuple[threading.Thread, threading.Event]] = {}

    while True:
        active = set(list_rds_containers())

        # Start shippers for new containers
        for name in active:
            if name not in shippers or not shippers[name][0].is_alive():
                stop  = threading.Event()
                thread = threading.Thread(
                    target=ship_container, args=(name, stop), daemon=True, name=f"ship-{name}"
                )
                thread.start()
                shippers[name] = (thread, stop)
                print(f"[shipper] Launched shipper thread for {name}", flush=True)
                continue

            # Restart MySQL/MariaDB shippers that fell back to docker-logs if
            # the audit file has since appeared (e.g. test script INSTALLed
            # the plugin or enabled general_log).
            state = SHIPPER_STATE.get(name)
            if state and state.get("fallback"):
                cfg = ENGINE_CONFIG.get(state["engine"], {})
                if find_audit_file(name, cfg.get("audit_file_paths", [])):
                    print(
                        f"[shipper] {name}: audit file appeared — restarting "
                        f"thread to tail it.",
                        flush=True,
                    )
                    _, stop = shippers.pop(name)
                    stop.set()
                    SHIPPER_STATE.pop(name, None)

        # Stop shippers for containers that are gone
        for name in list(shippers):
            if name not in active:
                _, stop = shippers.pop(name)
                stop.set()
                SHIPPER_STATE.pop(name, None)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
