#!/usr/bin/env python3
"""
GCP log shipper for dsf-lab-builder.
Watches floci-cloudsql-* containers, reads audit logs, and publishes them
to floci Pub/Sub using the Cloud Logging LogEntry format so DSF Agentless
Gateway can pull them via Pub/Sub subscription.
"""

import base64
import datetime
import json
import os
import re
import subprocess
import threading
import time

import docker
import requests

GCP_ENDPOINT_URL  = os.environ.get("GCP_ENDPOINT_URL", "http://localhost:4588")
GCP_PROJECT_ID    = os.environ.get("GCP_PROJECT_ID", "floci-gcp-lab")
GCP_REGION        = os.environ.get("GCP_REGION", "us-central1")
POLL_INTERVAL     = int(os.environ.get("POLL_INTERVAL", "10"))
FLUSH_INTERVAL    = float(os.environ.get("FLUSH_INTERVAL", "2"))
BATCH_SIZE        = int(os.environ.get("BATCH_SIZE", "100"))

_docker = docker.from_env()
_watched: dict[str, threading.Thread] = {}
_lock = threading.Lock()


# ── Helpers ───────────────────────────────────────────────────────────────────

def _now_rfc3339() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def _detect_engine(container_name: str) -> str:
    """Returns 'postgres' or 'mysql' based on the container name."""
    if "postgres" in container_name.lower() or "pg" in container_name.lower():
        return "postgres"
    return "mysql"


def _instance_name_from_container(container_name: str) -> str:
    """Strips 'floci-cloudsql-{project_id}-' prefix to get the Cloud SQL instance name."""
    name = re.sub(r"^/?floci-cloudsql-", "", container_name)
    # Strip the project ID prefix (e.g. "floci-gcp-lab-1-") to get the instance name
    project_prefix = GCP_PROJECT_ID + "-"
    if name.startswith(project_prefix):
        return name[len(project_prefix):]
    return name


def _topic_for_instance(instance: str) -> str:
    return f"{instance}-audit-topic"


def _make_log_entry(instance: str, engine: str, log_line: str) -> dict:
    """
    Wraps a raw log line in a Cloud Logging LogEntry structure.
    DSF expects this format when consuming from Pub/Sub.
    """
    return {
        "logName": f"projects/{GCP_PROJECT_ID}/logs/cloudsql.googleapis.com%2Fdatabase",
        "resource": {
            "type": "cloudsql_database",
            "labels": {
                "database_id": f"{GCP_PROJECT_ID}:{instance}",
                "region": GCP_REGION,
                "project_id": GCP_PROJECT_ID,
            },
        },
        "timestamp": _now_rfc3339(),
        "severity": "INFO",
        "textPayload": log_line,
        "labels": {
            "compute.googleapis.com/resource_name": instance,
        },
    }


def _publish_batch(topic: str, entries: list[dict]) -> None:
    if not entries:
        return
    messages = [
        {"data": base64.b64encode(json.dumps(e).encode()).decode()}
        for e in entries
    ]
    url = f"{GCP_ENDPOINT_URL}/v1/projects/{GCP_PROJECT_ID}/topics/{topic}:publish"
    try:
        resp = requests.post(url, json={"messages": messages}, timeout=5)
        if resp.status_code not in (200, 201):
            print(f"[warn] Pub/Sub publish to {topic} returned {resp.status_code}: {resp.text[:200]}")
    except Exception as exc:
        print(f"[error] Pub/Sub publish failed for {topic}: {exc}")


# ── Per-container log tail ────────────────────────────────────────────────────

def _tail_postgres(container, instance: str) -> None:
    """Stream docker logs from a PostgreSQL Cloud SQL container."""
    topic = _topic_for_instance(instance)
    print(f"[postgres] Tailing {container.name} → topic {topic}")
    buffer: list[dict] = []
    last_flush = time.time()

    try:
        for raw in container.logs(stream=True, follow=True, timestamps=True):
            line = raw.decode(errors="replace").strip()
            if not line:
                continue
            # Forward audit-relevant lines: statements, connections, disconnections, durations
            if not any(k in line for k in ("LOG:  statement:", "LOG: statement:", "connection received", "connection authorized", "disconnection:", "duration:")):
                continue
            buffer.append(_make_log_entry(instance, "postgres", line))
            now = time.time()
            if len(buffer) >= BATCH_SIZE or (now - last_flush) >= FLUSH_INTERVAL:
                _publish_batch(topic, buffer)
                buffer.clear()
                last_flush = now
    except Exception as exc:
        print(f"[postgres] Tail ended for {container.name}: {exc}")
    finally:
        if buffer:
            _publish_batch(topic, buffer)


def _tail_mysql(container, instance: str) -> None:
    """
    Stream MySQL audit log from the container.
    Tries /var/lib/mysql/server_audit.log first; falls back to docker logs.
    """
    topic = _topic_for_instance(instance)
    print(f"[mysql] Tailing {container.name} → topic {topic}")
    buffer: list[dict] = []
    last_flush = time.time()

    # Try server_audit.log via docker exec tail -F
    audit_path = "/var/lib/mysql/server_audit.log"
    use_exec = False
    try:
        rc, _ = container.exec_run(f"test -f {audit_path}", demux=False)
        use_exec = (rc == 0)
    except Exception:
        pass

    def _handle_line(line: str) -> None:
        nonlocal last_flush
        line = line.strip()
        if not line:
            return
        buffer.append(_make_log_entry(instance, "mysql", line))
        now = time.time()
        if len(buffer) >= BATCH_SIZE or (now - last_flush) >= FLUSH_INTERVAL:
            _publish_batch(topic, buffer)
            buffer.clear()
            last_flush = now

    try:
        if use_exec:
            _, stream = container.exec_run(
                f"tail -F {audit_path}", stream=True, demux=False
            )
            for chunk in stream:
                for line in chunk.decode(errors="replace").splitlines():
                    _handle_line(line)
        else:
            for raw in container.logs(stream=True, follow=True, timestamps=True):
                _handle_line(raw.decode(errors="replace"))
    except Exception as exc:
        print(f"[mysql] Tail ended for {container.name}: {exc}")
    finally:
        if buffer:
            _publish_batch(topic, buffer)


def _watch_container(container) -> None:
    name = container.name.lstrip("/")
    instance = _instance_name_from_container(name)
    engine = _detect_engine(name)
    if engine == "postgres":
        _tail_postgres(container, instance)
    else:
        _tail_mysql(container, instance)


# ── Discovery loop ────────────────────────────────────────────────────────────

def _discovery_loop() -> None:
    """Poll for new floci-cloudsql-* containers and start watcher threads."""
    while True:
        try:
            containers = _docker.containers.list(filters={"name": "floci-cloudsql-"})
            with _lock:
                for c in containers:
                    cid = c.id
                    if cid not in _watched or not _watched[cid].is_alive():
                        t = threading.Thread(
                            target=_watch_container, args=(c,), daemon=True, name=f"watch-{c.name}"
                        )
                        _watched[cid] = t
                        t.start()
        except Exception as exc:
            print(f"[discovery] Error listing containers: {exc}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    print(f"[gcp-log-shipper] Starting — endpoint={GCP_ENDPOINT_URL} project={GCP_PROJECT_ID}")
    _discovery_loop()
