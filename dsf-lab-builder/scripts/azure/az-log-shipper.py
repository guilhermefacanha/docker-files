#!/usr/bin/env python3
"""
Azure log shipper for dsf-lab-builder.
Watches floci-az managed database containers, reads audit logs from stdout,
and publishes them to floci-az Event Hubs via AMQP (Apache Artemis) so DSF
Agentless Gateway can consume them via Event Hub subscription.

Pipeline: MySQL/MariaDB/PostgreSQL container stdout
          → az-log-shipper (this script)
          → Artemis AMQP broker (started by floci-az EventHub emulator)
          → DSF Agentless Gateway
"""

import base64
import datetime
import json
import os
import threading
import time

import docker
import requests

FLOCI_AZ_ENDPOINT      = os.environ.get("FLOCI_AZ_ENDPOINT", "http://localhost:6001")
AZ_SUBSCRIPTION_ID     = os.environ.get("AZ_SUBSCRIPTION_ID", "00000000-0000-0000-0000-000000000001")
AZ_RESOURCE_GROUP      = os.environ.get("AZ_RESOURCE_GROUP", "dsf-lab-rg")
AZ_EVENTHUB_NS         = os.environ.get("AZ_EVENTHUB_NAMESPACE", "dsf-eventhub-az1")
AZ_EVENTHUB_NAME       = os.environ.get("AZ_EVENTHUB_NAME", "dsf-audit-logs")
AZ_EH_ACCOUNT_PREFIX   = os.environ.get("AZ_EVENTHUB_ACCOUNT_PREFIX", "dsf-lab")
ARTEMIS_HOST           = os.environ.get("ARTEMIS_HOST", f"floci-az-artemis-{AZ_EVENTHUB_NS}")
ARTEMIS_PORT           = int(os.environ.get("ARTEMIS_PORT", "5672"))
POLL_INTERVAL          = int(os.environ.get("POLL_INTERVAL", "10"))
FLUSH_INTERVAL         = float(os.environ.get("FLUSH_INTERVAL", "2"))
BATCH_SIZE             = int(os.environ.get("BATCH_SIZE", "100"))

# Container name prefixes managed by floci-az
# Note: PostgreSQL containers use "floci-az-pg-" prefix (not "floci-az-postgres-")
_CONTAINER_PREFIXES = ("floci-az-mysql-", "floci-az-mariadb-", "floci-az-pg-")

_docker = docker.from_env()
_watched: dict[str, threading.Thread] = {}
_lock = threading.Lock()

# AMQP state
_amqp_lock = threading.Lock()
_amqp_conn = None
_amqp_sender = None
_amqp_ready = False


# ── Helpers ───────────────────────────────────────────────────────────────────

def _now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def _detect_engine(container_name: str) -> str:
    name = container_name.lstrip("/").lower()
    if "mariadb" in name:
        return "mariadb"
    if "mysql" in name:
        return "mysql"
    return "postgres"


def _server_name_from_container(container_name: str) -> str:
    name = container_name.lstrip("/")
    for prefix in _CONTAINER_PREFIXES:
        if name.startswith(prefix):
            return name[len(prefix):]
    return name


def _resource_id(engine: str, server_name: str) -> str:
    provider = {
        "mysql":    "Microsoft.DBforMySQL/flexibleServers",
        "mariadb":  "Microsoft.DBforMariaDB/servers",
        "postgres": "Microsoft.DBforPostgreSQL/flexibleServers",
    }.get(engine, "Microsoft.DBforMySQL/flexibleServers")
    return (f"/subscriptions/{AZ_SUBSCRIPTION_ID}/resourceGroups/{AZ_RESOURCE_GROUP}"
            f"/providers/{provider}/{server_name}")


def _log_category(engine: str) -> str:
    if engine == "postgres":
        return "PostgreSQLLogs"
    return "MySqlAuditLogs"


def _make_event(engine: str, server_name: str, log_line: str) -> dict:
    return {
        "time": _now_iso(),
        "resourceId": _resource_id(engine, server_name),
        "operationName": "LogEvent",
        "category": _log_category(engine),
        "level": "Informational",
        "resultType": "Success",
        "properties": {
            "Message": log_line,
            "serverName": server_name,
            "engine": engine,
        },
    }


# ── Event Hub namespace creation (floci-az native API) ───────────────────────

def _ensure_eventhub_namespace() -> bool:
    """
    Create Event Hub namespace via floci-az native API (starts Artemis broker).
    Returns True once Artemis is ready (amqpPort > 0), False if mocked.
    """
    url = f"{FLOCI_AZ_ENDPOINT}/{AZ_EH_ACCOUNT_PREFIX}-eventhub/namespaces/{AZ_EVENTHUB_NS}"
    body = json.dumps({"entities": AZ_EVENTHUB_NAME, "consumerGroups": "$Default"})
    headers = {"Content-Type": "application/json"}

    print(f"[eventhub] Creating namespace '{AZ_EVENTHUB_NS}' (entity: {AZ_EVENTHUB_NAME}) ...")
    for attempt in range(30):
        try:
            resp = requests.put(url, data=body, headers=headers, timeout=10)
            d = resp.json()
            if d.get("mocked", False):
                print("[eventhub] Namespace is in mocked mode — AMQP not available, skipping publish.")
                return False
            amqp_port = d.get("amqpPort", 0)
            if amqp_port > 0:
                print(f"[eventhub] Namespace ready, Artemis AMQP port {amqp_port} (host-side)")
                return True
            # Namespace created but Artemis still starting — GET to poll
            resp2 = requests.get(url, timeout=5)
            d2 = resp2.json()
            if d2.get("amqpPort", 0) > 0:
                print(f"[eventhub] Artemis ready after {attempt+1} poll(s)")
                return True
        except Exception as exc:
            print(f"[eventhub] Attempt {attempt+1} failed: {exc}")
        time.sleep(3)
    print("[eventhub] Artemis did not become ready after 30 attempts — skipping AMQP publish.")
    return False


# ── AMQP publisher (Artemis via proton) ──────────────────────────────────────

def _init_amqp() -> bool:
    global _amqp_conn, _amqp_sender, _amqp_ready
    try:
        from proton.utils import BlockingConnection
        from proton import Message as _ProtonMessage  # noqa: import check
    except ImportError:
        print("[amqp] python-qpid-proton not available — using fallback logging.")
        return False

    with _amqp_lock:
        try:
            from proton.utils import BlockingConnection
            # Artemis is configured with security-enabled=false → disable SASL
            _amqp_conn = BlockingConnection(
                f"amqp://{ARTEMIS_HOST}:{ARTEMIS_PORT}",
                timeout=30,
                sasl_enabled=False,
            )
            _amqp_sender = _amqp_conn.create_sender(AZ_EVENTHUB_NAME)
            _amqp_ready = True
            print(f"[amqp] Connected to Artemis at {ARTEMIS_HOST}:{ARTEMIS_PORT} (anonymous), "
                  f"sender → '{AZ_EVENTHUB_NAME}'")
            return True
        except Exception as exc:
            print(f"[amqp] Connection failed: {exc}")
            _amqp_conn = None
            _amqp_sender = None
            _amqp_ready = False
            return False


def _publish_batch(records: list[dict]) -> None:
    if not records:
        return
    global _amqp_ready, _amqp_conn, _amqp_sender

    if _amqp_ready:
        with _amqp_lock:
            try:
                from proton import Message
                for r in records:
                    msg = Message(body=json.dumps(r))
                    _amqp_sender.send(msg, timeout=10)
                print(f"[amqp] published {len(records)} record(s) to '{AZ_EVENTHUB_NAME}'")
                return
            except Exception as exc:
                print(f"[amqp] publish failed: {exc} — reconnecting next batch")
                _amqp_ready = False
                try:
                    _amqp_conn.close()
                except Exception:
                    pass
                _amqp_conn = None
                _amqp_sender = None

    # Fallback: log locally so the pipeline is visible even without AMQP
    print(f"[fallback] {len(records)} record(s) (AMQP not connected):")
    for r in records[:3]:
        props = r.get("properties", {})
        print(f"  [{r.get('category')}] {props.get('serverName')}: "
              f"{props.get('Message','')[:100]}")
    if len(records) > 3:
        print(f"  ... and {len(records) - 3} more")


# ── Audit log filters ─────────────────────────────────────────────────────────

def _is_audit_line_postgres(line: str) -> bool:
    return any(k in line for k in (
        "LOG:  statement:", "LOG: statement:",
        "connection received", "connection authorized",
        "disconnection:", "duration:",
    ))


def _is_audit_line_mysql_general(line: str) -> bool:
    """Match lines from MySQL/MariaDB general_log file format: timestamp\t{id} command\targ"""
    # Actual format: {ts}\t{spaces+id} {Command}\t{arg}  — command is NOT preceded by a bare \t
    return " Query\t" in line or " Connect\t" in line or " Quit\t" in line or " Init DB\t" in line


# ── Per-container log tail ────────────────────────────────────────────────────

def _find_mysql_general_log(container) -> str:
    """Find the general_log_file path inside the MySQL/MariaDB container."""
    # Prefer the known fixed path set by setup scripts; skip MariaDB internal files
    _SKIP = {"ddl_recovery.log", "aria_log_control"}
    for cmd in [
        # Query the DB variable directly (works when general log is enabled)
        "mysql -u root -e \"SELECT @@general_log_file\" 2>/dev/null | tail -1 || "
        "mariadb -u root -e \"SELECT @@general_log_file\" 2>/dev/null | tail -1",
        # Fallback: glob, skipping internal non-query-log files
        "ls /var/lib/mysql/*.log 2>/dev/null | grep -v ddl_recovery | head -1",
    ]:
        try:
            result = container.exec_run(
                ["bash", "-c", cmd], stdout=True, stderr=False,
            )
            path = result.output.decode(errors="replace").strip()
            if path and not any(path.endswith(s) for s in _SKIP) and path != "@@general_log_file":
                return path
        except Exception:
            continue
    return ""


def _tail_mysql_general_log(container, engine: str, server: str) -> None:
    """Tail the MySQL/MariaDB general_log file via docker exec."""
    name = container.name.lstrip("/")
    log_file = _find_mysql_general_log(container)
    if not log_file:
        print(f"[{engine}] Could not find general_log file in {name} — falling back to container logs")
        _tail_container_stdout(container, engine, server, _is_audit_line_mysql_general)
        return

    print(f"[{engine}] Tailing general_log {log_file} in {name} → Artemis {ARTEMIS_HOST}:{ARTEMIS_PORT}/{AZ_EVENTHUB_NAME}")
    buffer: list[dict] = []
    last_flush = time.time()

    try:
        result = container.exec_run(
            ["tail", "-F", "-n", "0", log_file],
            stdout=True, stderr=False, stream=True, demux=True,
        )
        for stdout_chunk, _ in result.output:
            if not stdout_chunk:
                continue
            for line in stdout_chunk.decode(errors="replace").splitlines():
                if not _is_audit_line_mysql_general(line):
                    continue
                buffer.append(_make_event(engine, server, line))
                now = time.time()
                if len(buffer) >= BATCH_SIZE or (now - last_flush) >= FLUSH_INTERVAL:
                    _publish_batch(buffer)
                    buffer.clear()
                    last_flush = now
    except Exception as exc:
        print(f"[{engine}] General log tail ended for {name}: {exc}")
    finally:
        if buffer:
            _publish_batch(buffer)


def _tail_container_stdout(container, engine: str, server: str, is_audit) -> None:
    """Tail container stdout/stderr (used for PostgreSQL)."""
    name = container.name.lstrip("/")
    print(f"[{engine}] Tailing stdout {name} → Artemis {ARTEMIS_HOST}:{ARTEMIS_PORT}/{AZ_EVENTHUB_NAME}")
    buffer: list[dict] = []
    last_flush = time.time()
    try:
        for raw in container.logs(stream=True, follow=True, timestamps=True):
            line = raw.decode(errors="replace").strip()
            if not line or not is_audit(line):
                continue
            buffer.append(_make_event(engine, server, line))
            now = time.time()
            if len(buffer) >= BATCH_SIZE or (now - last_flush) >= FLUSH_INTERVAL:
                _publish_batch(buffer)
                buffer.clear()
                last_flush = now
    except Exception as exc:
        print(f"[{engine}] Stdout tail ended for {name}: {exc}")
    finally:
        if buffer:
            _publish_batch(buffer)


def _tail_container(container) -> None:
    name = container.name.lstrip("/")
    server = _server_name_from_container(name)
    engine = _detect_engine(name)
    if engine in ("mysql", "mariadb"):
        _tail_mysql_general_log(container, engine, server)
    else:
        _tail_container_stdout(container, engine, server, _is_audit_line_postgres)


# ── Discovery loop ────────────────────────────────────────────────────────────

def _discovery_loop() -> None:
    while True:
        try:
            containers = _docker.containers.list()
            with _lock:
                for c in containers:
                    cname = c.name.lstrip("/")
                    if not any(cname.startswith(p) for p in _CONTAINER_PREFIXES):
                        continue
                    cid = c.id
                    if cid not in _watched or not _watched[cid].is_alive():
                        t = threading.Thread(
                            target=_tail_container, args=(c,),
                            daemon=True, name=f"watch-{cname}"
                        )
                        _watched[cid] = t
                        t.start()
        except Exception as exc:
            print(f"[discovery] Error listing containers: {exc}")
        time.sleep(POLL_INTERVAL)


# ── AMQP reconnect loop ───────────────────────────────────────────────────────

def _amqp_reconnect_loop() -> None:
    global _amqp_ready
    while True:
        if not _amqp_ready:
            _init_amqp()
        time.sleep(15)


if __name__ == "__main__":
    print(f"[az-log-shipper] Starting")
    print(f"  endpoint    = {FLOCI_AZ_ENDPOINT}")
    print(f"  eventhub    = {AZ_EVENTHUB_NS}/{AZ_EVENTHUB_NAME}")
    print(f"  artemis     = {ARTEMIS_HOST}:{ARTEMIS_PORT}")
    print(f"  watching    = {', '.join(_CONTAINER_PREFIXES)}")

    # Create Event Hub namespace (starts Artemis broker)
    namespace_ready = _ensure_eventhub_namespace()
    if namespace_ready:
        _init_amqp()

    # Start AMQP reconnect watcher
    threading.Thread(target=_amqp_reconnect_loop, daemon=True, name="amqp-reconnect").start()

    # Start container discovery (blocks)
    _discovery_loop()
