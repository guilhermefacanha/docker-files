# DSF Lab Builder

A browser-based control panel for managing multiple Floci (LocalStack) AWS environments for DSF integration testing.

---

## Feasibility Assessment

**Overall: Fully feasible.** All the hard primitives already exist in `floci-local-aws/`. The builder is a thin orchestration layer: a Go HTTP server that wraps the existing scripts, exposes them via a REST API, and streams output to a jQuery/Bootstrap frontend.

The only non-trivial piece is Docker-in-Docker access — solved by mounting `/var/run/docker.sock` into the container (no full `--privileged` needed; socket access is sufficient for `docker ps`, `docker exec`, `docker compose`).

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Browser  (HTML + jQuery + Bootstrap via CDN)   │
│                                                 │
│  /           → Home Dashboard (env list)        │
│  /#/env/:id  → Env Detail (RDS, S3, FAM, data)  │
└────────────────────┬────────────────────────────┘
                     │ REST + SSE (port 8080)
┌────────────────────▼────────────────────────────┐
│  Go HTTP Server  (net/http + os/exec)           │
│                                                 │
│  GET  /api/envs             list running envs   │
│  POST /api/envs             deploy new env      │
│  GET  /api/envs/:id         env details         │
│  POST /api/envs/:id/rds     create RDS instance │
│  POST /api/envs/:id/s3-fam  create FAM bucket   │
│  POST /api/envs/:id/test    test a resource     │
│  POST /api/envs/:id/generate start/stop gen     │
│  GET  /api/envs/:id/stream  SSE output stream   │
└────────────────────┬────────────────────────────┘
                     │ /var/run/docker.sock (volume mount)
                     │ floci-local-aws/ (volume mount, read+exec)
┌────────────────────▼────────────────────────────┐
│  Docker Engine  (host)                          │
│                                                 │
│  floci-env1  (localstack + rds-proxy, port 4567)│
│  floci-env2  (localstack + rds-proxy, port 4568)│
│  ...                                            │
└─────────────────────────────────────────────────┘
```

---

## How Each Requirement Is Achieved

### RF01 — Privileged container with Docker access

Mount the Docker socket as a volume. The Go backend calls `docker ps`, `docker exec`, and `docker compose` via `os/exec`. No full `--privileged` flag needed.

```dockerfile
# Dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY . .
RUN go build -o dsf-lab-builder ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache docker-cli docker-cli-compose python3 aws-cli bash
COPY --from=builder /app/dsf-lab-builder /usr/local/bin/
COPY static/ /app/static/
EXPOSE 8080
ENTRYPOINT ["dsf-lab-builder"]
```

```yaml
# docker-compose.yml (for the builder itself)
services:
  dsf-lab-builder:
    build: .
    ports:
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ../floci-local-aws:/workspace/floci-local-aws
    environment:
      - FLOCI_WORKSPACE=/workspace/floci-local-aws
```

---

### RF02 — Home dashboard: detect all running AWS envs

The Go backend parses `docker ps` output and groups containers by their Compose project name (the `com.docker.compose.project` label). Any project whose name matches `floci-env*` or `floci-local-aws*` is an env.

```go
// Detect envs: docker ps --format json, group by label
cmd := exec.Command("docker", "ps", "--format", "{{json .}}")
// Group by: com.docker.compose.project label
// Extract: floci port, account ID, network, env number
```

From each group the API reads the mapped host ports and `docker inspect` labels to build the env summary.

**Frontend**: a Bootstrap card grid, one card per env, showing env number, floci port, account ID, and status badges. Cards are refreshed by polling `GET /api/envs` every 5 seconds.

---

### RF03 — Deploy a new AWS env

1. The backend copies (or symlinks) the `floci-local-aws/` template to a new directory, e.g. `floci-local-aws-3/`.
2. It runs `update-docker-env.sh` (auto-picks next free slot) inside a shell, streaming stdout/stderr back to the browser via SSE.
3. After the script exits it runs `docker compose up -d` in the new directory.

Output is streamed to the browser in a `<pre>` code block using an `EventSource` connection to `/api/envs/stream/:jobId`.

```javascript
// Frontend (jQuery)
const es = new EventSource(`/api/envs/stream/${jobId}`);
es.onmessage = e => $output.append(e.data + '\n');
```

---

### RF04 — Env detail page

#### Info panel

Calls `GET /api/envs/:id` which runs:

- `docker inspect` on the compose project containers → ports, network, account ID
- `aws rds describe-db-instances` via `docker exec` into the localstack container → RDS list
- `aws s3 ls` → bucket list
- Reads `.env` for `FAM_*` variables → FAM asset onboarding info (same data as `fam/04-show-fam-asset-info.sh`)

All output is returned as JSON; the frontend renders it in styled sections with copy buttons.

#### Create RDS instance (postgres / mysql / mariadb)

A modal form with engine selector. On submit, streams the matching setup script:

```
rds/service-rds-postgres-dsf-setup.sh   → postgres
rds/service-rds-mysql-dsf-setup.sh      → mysql
rds/service-rds-mariadb-dsf-setup.sh    → mariadb
```

Scripts are executed with the env's `.env` loaded so they hit the correct endpoint and use the correct port range.

#### Create FAM S3 bucket

Runs the FAM pipeline:

```
fam/01-create-fam-user.sh
fam/02-setup-fam-resources.sh
```

Then shows the onboarding info block (output of `fam/04-show-fam-asset-info.sh`) in a styled, copyable panel.

#### Test resource

- RDS: runs `rds/service-rds-<engine>-test-audit-cloudwatch.sh`, streams output.
- S3/FAM: runs `fam/03-test-traffic.sh`, streams output.

#### Background data generator

- Start: `POST /api/envs/:id/generate` → spawns `fam/06-simulate-acvitiy-start-background.sh` (nohup python3) as a tracked Go goroutine / subprocess; stores PID.
- Status: `GET /api/envs/:id` includes generator status (running/stopped) and last N lines from `activity.log`.
- Stop: `POST /api/envs/:id/generate/stop` → kills the tracked subprocess.

The frontend shows a live badge ("Generating…") and a scrollable log tail that polls every 3 seconds.

---

## Project Structure

```
dsf-lab-builder/
├── cmd/
│   └── server/
│       └── main.go          # entry point, wires routes
├── internal/
│   ├── docker/
│   │   └── client.go        # docker ps / inspect helpers
│   ├── env/
│   │   └── manager.go       # detect, deploy, describe envs
│   ├── runner/
│   │   └── runner.go        # exec scripts, stream stdout via SSE
│   └── api/
│       └── handlers.go      # HTTP handlers
├── static/
│   ├── index.html           # SPA shell (Bootstrap + jQuery from CDN)
│   ├── app.js               # routing, API calls, SSE handling
│   └── style.css            # minor overrides
├── Dockerfile
├── docker-compose.yml
└── design.md
```

---

## Key Technical Decisions

| Decision | Choice | Reason |
|---|---|---|
| Script reuse | Reuse existing `.sh` scripts as-is | They are well-parameterized; wrapping them avoids duplication and drift |
| Script execution | `os/exec` with env vars injected | Cleanest way to pass per-env config (endpoint, account ID, suffix) |
| Streaming output | SSE (`text/event-stream`) | Simple, browser-native, no WebSocket library needed |
| Frontend routing | Hash-based (`/#/env/1`) | No server-side routing needed; works inside a container |
| Docker access | Socket mount (`/var/run/docker.sock`) | Avoids `--privileged`; sufficient for all required docker operations |
| Multi-env dirs | Copy template dir per env | Mirrors how the scripts are designed to work (`cp -r floci-local-aws floci-local-aws-2`) |
| Data generator tracking | Go `cmd.Process` stored in memory map | Simple; process survives as long as the builder container is up |

---

## Limitations / Open Questions

- **Max 5 envs**: the `update-docker-env.sh` slot scheme supports env 1–9 only.
- **Generator state**: background generator PID is in-memory; if the builder container restarts, running generators become orphaned. A PID file on disk would fix this.
- **Security**: the Docker socket mount gives the container full control over the host Docker daemon. This is intentional for a lab tool but should never be exposed publicly.
