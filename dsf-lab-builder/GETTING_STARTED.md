# Getting Started

The builder runs as a native binary on your Mac or Linux machine. It controls Docker directly — no container needed for the app itself.

## Prerequisites

- Docker Desktop (Mac) or Docker Engine + Compose plugin (Linux)
- AWS CLI v2 (`aws --version`)
- Go 1.22+ — only if building from source

---

## Build

Build for your platform (output lands in `dist/`):

```bash
cd dsf-lab-builder

make build-mac-arm    # macOS Apple Silicon  → dist/dsf-lab-builder-darwin-arm64
make build-mac-intel  # macOS Intel          → dist/dsf-lab-builder-darwin-amd64
make build-linux      # Linux x86-64         → dist/dsf-lab-builder-linux-amd64

# or build everything at once:
make build-all
```

| Platform            | Binary                               |
|---------------------|--------------------------------------|
| macOS Apple Silicon | `dist/dsf-lab-builder-darwin-arm64`  |
| macOS Intel         | `dist/dsf-lab-builder-darwin-amd64`  |
| Linux x86-64        | `dist/dsf-lab-builder-linux-amd64`   |

> **Must run from the `dsf-lab-builder/` directory** so the binary can find `./scripts/` and `./static/`.

---

## Run

### Development (foreground, from source)

```bash
cd dsf-lab-builder
make run
# open http://localhost:8080
```

### Foreground (pre-built binary)

```bash
cd dsf-lab-builder
./dist/dsf-lab-builder-darwin-arm64   # macOS Apple Silicon
./dist/dsf-lab-builder-linux-amd64    # Linux
# open http://localhost:8080
```

Press `Ctrl+C` to stop.

---

## Run in the background

### macOS

```bash
cd dsf-lab-builder

# Start
nohup ./dist/dsf-lab-builder-darwin-arm64 > dsf-lab.log 2>&1 &
echo $! > dsf-lab.pid
echo "Started (PID $(cat dsf-lab.pid))"

# Tail the log
tail -f dsf-lab.log

# Stop
kill $(cat dsf-lab.pid) && rm dsf-lab.pid
```

### Linux (background process)

```bash
cd dsf-lab-builder

# Start
nohup ./dist/dsf-lab-builder-linux-amd64 > dsf-lab.log 2>&1 &
echo $! > dsf-lab.pid
echo "Started (PID $(cat dsf-lab.pid))"

# Tail the log
tail -f dsf-lab.log

# Stop
kill $(cat dsf-lab.pid) && rm dsf-lab.pid
```

---

## Linux systemd service (auto-start on boot)

Create a service unit so the builder starts automatically when the machine boots.

### 1. Copy the binary to a system path

```bash
sudo cp dist/dsf-lab-builder-linux-amd64 /usr/local/bin/dsf-lab-builder
sudo chmod +x /usr/local/bin/dsf-lab-builder
```

### 2. Create the service file

```bash
sudo nano /etc/systemd/system/dsf-lab-builder.service
```

Paste the following — adjust `User`, `WorkingDirectory`, and `PORT` as needed:

```ini
[Unit]
Description=DSF Lab Builder
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/dsf-lab-builder
ExecStart=/usr/local/bin/dsf-lab-builder
Restart=on-failure
RestartSec=5

# Optional overrides — remove lines you don't need
Environment=PORT=8080
Environment=WORKSPACE=/home/ubuntu/dsf-lab-builder/workspace
Environment=SCRIPTS_DIR=/home/ubuntu/dsf-lab-builder/scripts

StandardOutput=journal
StandardError=journal
SyslogIdentifier=dsf-lab-builder

[Install]
WantedBy=multi-user.target
```

### 3. Enable and start

```bash
# Reload systemd so it picks up the new unit
sudo systemctl daemon-reload

# Enable auto-start on boot
sudo systemctl enable dsf-lab-builder

# Start now
sudo systemctl start dsf-lab-builder

# Check status
sudo systemctl status dsf-lab-builder
```

### 4. Common service commands

```bash
sudo systemctl stop    dsf-lab-builder   # stop
sudo systemctl restart dsf-lab-builder   # restart
sudo systemctl disable dsf-lab-builder   # remove from auto-start

# Live logs (follows the journal)
sudo journalctl -u dsf-lab-builder -f

# Last 100 lines
sudo journalctl -u dsf-lab-builder -n 100
```

---

## Environment variables

| Variable      | Default                    | Description                         |
|---------------|----------------------------|-------------------------------------|
| `PORT`        | `8080`                     | HTTP port the server listens on     |
| `WORKSPACE`   | `./workspace`              | Directory where env copies are kept |
| `SCRIPTS_DIR` | `./scripts`                | Read-only scripts directory         |

---

## Usage

### Deploy a new environment

Click **Deploy New Env** on the dashboard. A streaming log shows the copy, `.env` generation, and `docker compose up --build`. Up to 5 environments can run simultaneously:

| Slot | Floci Port | RDS Port Range | Account ID   |
|------|------------|----------------|--------------|
| 1    | 4567       | 7101–7199      | 111111111111 |
| 2    | 4568       | 7201–7299      | 222222222222 |
| 3    | 4569       | 7301–7399      | 333333333333 |
| 4    | 4570       | 7401–7499      | 444444444444 |
| 5    | 4571       | 7501–7599      | 555555555555 |

Each env is a full copy of `scripts/` in `workspace/envN/`, with its own `.env`, data directory, and Docker Compose project.

### Environment detail

Click **Open** on an env card:

- **Resources** — live RDS instances, S3 buckets, and the asset export panel
- **Create RDS** — PostgreSQL / MySQL / MariaDB with streamed setup output; ⓘ button previews every AWS CLI command that will run
- **FAM / S3** — full FAM pipeline (IAM user + S3 buckets + CloudTrail) with DSF Hub onboarding info and copy buttons; ⓘ button previews every AWS CLI command
- **Data Generator** — start/stop continuous SQL traffic generators (3-user rotation + permission simulation) and the FAM S3 activity simulator

### Server IP setting

The **Server IP** field in the top-right navbar replaces `localhost` everywhere endpoint URLs are displayed:
- FAM onboarding info (Server Host Name, endpoint URLs)
- AWS CLI command previews
- Asset export spreadsheet

Set this to your machine's actual IP address before sharing onboarding info with colleagues or exporting the asset spreadsheet for DSF Hub import.

### Export DSF Hub import spreadsheet

In the **Resources** tab, scroll to the export panel:
1. Set **Server IP** to your host's actual IP (or leave as `localhost` for local use)
2. Optionally set the **Agentless Gateway Name**
3. Click **Download Assets XLSX**

The downloaded `.xlsx` has two sheets:
- **Cloud Account** — AWS cloud account asset (IAM ARN, FAM access key/secret, endpoint URLs)
- **RDS & Log Groups** — one RDS asset + one CloudWatch Log Group asset per RDS instance

### Destroy an environment

Trash icon on the env card — runs `docker compose down --volumes` and removes `workspace/envN/`.

### Cleanup everything

```bash
# Stop all running envs first (via the UI), then:
rm -rf workspace/
```
