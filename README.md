# podman-lab

A local software development lifecycle (SDLC) laboratory running entirely on
**Podman Quadlets** as rootless systemd services. Every component — from Git
hosting to CI/CD to artifact storage — is declaratively defined in quadlet
files and managed with `systemctl --user`.

## Architecture

```
Internet -> Cloudflare -> Cloudflared (host network, existing tunnel)
                                |
   localhost:3000  localhost:8000   localhost:9002   localhost:5000  localhost:9000/9001
       |               |               |                  |              |
    gitea        woodpecker-server   wp-grpc           registry       minio
       |               |               |                  |              |
       +---------------+---------------+------------------+--------------+
                               |
                         lab-net bridge
                (postgres, redis, 5 wp-agents, backups,
                 dev containers: python/node/go/rust/java)
```

### Services

| Service | Role | Port | Subdomain |
|---------|------|:----:|-----------|
| **PostgreSQL** | Shared database backend | — | *internal* |
| **Redis** | Cache & job queue | — | *internal* |
| **Gitea** | Self-hosted Git with LFS, issues, PRs | 3000 | `git.runemal.cloud` |
| **Woodpecker** | CI/CD server + per-language agents | 8000 / 9002→9000† | `ci.runemal.cloud` |
| **Registry** | Private container image storage | 5000 | `registry.runemal.cloud` |
| **MinIO** | S3-compatible artifact & log storage | 9000/9001 | `minio.runemal.cloud` |
| **Dev containers** | Python, Node, Go, Rust, Java envs | 8001† / 5001†, 3001† / 5174†, 8081†, 8082†, 8083† | *local only* |
| **Backup** | Daily pg_dump + tar with 30-day rotation | — | *timer: 03:00* |

> † Woodpecker gRPC (agent communication) — internal container port 9000 is
> mapped to host port 9002 to avoid conflict with MinIO's S3 API on port 9000.
> Agents connect to `woodpecker-server:9000` over the internal `lab-net` bridge.
>
> ‡ Dev containers use shifted host ports to avoid conflicts with infrastructure
> services — see the table below for exact mappings.

### SDLC Pipeline

```
PLAN    -> Gitea Issues/Wiki
CODE    -> Gitea repos + dev containers (podman exec)
BUILD   -> Woodpecker agent picks up push webhook
TEST    -> Agent runs steps in ephemeral containers
PACKAGE -> Image -> Registry | Artifacts -> MinIO
DEPLOY  -> systemctl --user restart <quadlet>
```

## Quick Start

### Prerequisites

- Podman >= 4.6 (known to work with 4.9; quadlet `.network`/`.volume` files must omit `Description` key for compatibility)
- systemd --user available
- `loginctl enable-linger $USER` (run automatically by setup)

### Deploy

```bash
git clone <repo-url> podman-lab
cd podman-lab
./setup.sh               # deploy only
./setup.sh --start       # deploy + start all services
```

`setup.sh`:
1. Checks prerequisites and enables linger
2. Creates `~/.local/share/podman-lab/` directory tree
3. **Preserves all existing secrets** from `secrets.env` across re-runs
   (passwords, tokens, OAuth credentials — everything stays the same)
4. Generates new secrets only on first run (no existing `secrets.env`)
5. Generates PostgreSQL init script with matching passwords
6. Generates `woodpecker-pipeline.env` — injected into CI pipeline steps
   (MinIO credentials, registry URL — separate from main secrets for security)
7. On fresh installs only: syncs PostgreSQL passwords and restarts Gitea + Woodpecker
8. Interpolates placeholders in quadlet files:
   - `__USER__`, `__UID__`, `__DOMAIN__` — identity/domain
   - `__POSTGRES_IP__`, `__REDIS_IP__`, `__GITEA_IP__`, `__WOODPECKER_IP__` — static IPs
9. Copies quadlets → `~/.config/containers/systemd/`
10. Copies systemd timer → `~/.config/systemd/user/`
11. Runs `systemctl --user daemon-reload`
12. Prints post-setup instructions

> **Force regeneration**: Delete `~/.local/share/podman-lab/secrets.env` before
> running `setup.sh` to generate all-new secrets. You'll need to re-create the
> Gitea admin account and re-paste OAuth credentials.

### MinIO Credentials

MinIO access key and secret key are managed by `setup.sh` and stored in
`secrets.env`. They're also written to `woodpecker-pipeline.env` which is
mounted into the Woodpecker server and injected into CI pipeline steps.

Override via env vars before running `setup.sh`:

```bash
MINIO_ACCESS_KEY=myuser MINIO_SECRET_KEY=mysecret ./setup.sh
```

After initial deployment, use `--start` and `--stop` to control the lab:

```bash
./setup.sh --start   # start all services in dependency order
./setup.sh --stop    # stop all services (reverse order)
```

> **Note**: Host volume paths use `%h` (systemd home-directory specifier)
> rather than `__USER__` — this avoids relative-path issues. The `__USER__`
> placeholder is still used for non-path interpolation
> (e.g., `Environment=USER_UID=__UID__`).

### Start / Stop Services

Start everything in one command (respects dependency order):

```bash
./setup.sh --start
```

Or start individually:

```bash
# Core infrastructure
systemctl --user start postgres redis

# Git hosting
systemctl --user start gitea

# CI/CD
systemctl --user start woodpecker-server
systemctl --user start wp-agent-{python,node,go,rust,java}

# Storage
systemctl --user start registry minio

# Enable on boot
systemctl --user enable --now postgres redis gitea
systemctl --user enable --now woodpecker-server
systemctl --user enable --now wp-agent-{python,node,go,rust,java}
systemctl --user enable --now registry minio

# Backup timer
systemctl --user enable --now lab-backup.timer
```

Stop everything:

```bash
./setup.sh --stop
```

### Post-Setup (Manual)

1. Visit `https://git.runemal.cloud` — create admin account
2. **Settings → Applications → OAuth2** — register Woodpecker CI:
   - Redirect URI: `https://ci.runemal.cloud/authorize`
   - Copy Client ID + Secret
3. Edit `~/.local/share/podman-lab/secrets.env`:
   ```
   WOODPECKER_GITEA_CLIENT=<paste>
   WOODPECKER_GITEA_SECRET=<paste>
   ```
4. `systemctl --user restart woodpecker-server`
5. In Cloudflare dashboard → tunnel → add subdomains:
   - `git.runemal.cloud` → `localhost:3000`
   - `ci.runemal.cloud` → `localhost:8000`
   - `registry.runemal.cloud` → `localhost:5000`
   - `minio.runemal.cloud` → `localhost:9001`
6. Start cloudflared tunnel:
   ```bash
   systemctl --user start cloudflared
   ```
7. Create language repos with CI pipelines:
   ```bash
   ./create-repos.sh --token <GITEA_API_TOKEN>
   ```
8. Enable Woodpecker CI for each repo via Gitea settings

## Using Dev Containers

Each language container sleeps until attached:

```bash
systemctl --user start lab-python
podman exec -it lab-python /bin/bash
# Your project is at /workspace/
```

Available containers and pre-exposed ports:

| Container | Image | Ports |
|-----------|-------|:-----:|
| `lab-python` | python:3.12-slim | 8001, 5001 |
| `lab-node` | node:22-slim | 3001, 5174 |
| `lab-go` | golang:1.23 | 8081 |
| `lab-rust` | rust:slim | 8083 |
| `lab-java` | eclipse-temurin:21-jdk | 8082 |

Your `~/Projects/` directory is mounted at `/workspace/` in every dev container.

## Creating Language Repos

`create-repos.sh` creates a Git repo for each supported language on your
Gitea instance, with boilerplate source files and a Woodpecker CI pipeline.

```bash
./create-repos.sh                                              # interactive
./create-repos.sh --token <TOKEN>                              # non-interactive
./create-repos.sh --token <TOKEN> --git-url https://git.runemal.cloud  # custom URL
```

Options:
- `--token TOKEN` — Gitea API token (required)
- `--gitea-url URL` — Gitea API base URL (default: `http://localhost:3000`)
- `--git-url URL` — Public Git URL for display & push (default: `https://git.runemal.cloud`)

Requires a Gitea API token — create one at:
`https://git.runemal.cloud/-/user/settings/applications`

Repos are created in `~/Projects/`:

| Repo | Language | CI Pipeline |
|------|----------|-------------|
| `lab-python` | Python 3.12 | pytest + build |
| `lab-node` | Node.js 22 | npm test + pack |
| `lab-go` | Go 1.23 | go test + build |
| `lab-rust` | Rust | cargo test + build |
| `lab-java` | Java 21 | javac + jar |

After creating, enable Woodpecker CI for each repo via the Gitea settings page.

## Writing CI Pipelines

Create `.woodpecker.yml` in your repository root. Target a specific agent
via labels:

```yaml
# .woodpecker.yml
labels:
  type: python

steps:
  - name: test
    image: python:3.12-slim
    commands:
      - pip install -r requirements.txt
      - pytest

  - name: build
    image: python:3.12-slim
    commands:
      - pip install build
      - python -m build
```

Available agent labels: `python`, `node`, `go`, `rust`, `java`.

## Backup & Restore

- **Schedule**: Daily at 03:00 (systemd timer)
- **Retention**: 30 days (automatic purge)
- **Location**: `~/.local/share/podman-lab/backups/`

See [RESTORE.md](RESTORE.md) for detailed recovery procedures.

## Repository Structure

```
podman-lab/
├── quadlets/           # Source .container / .volume / .network files
│   ├── lab-net.network
│   ├── postgres.container     postgres.volume
│   ├── redis.container
│   ├── gitea.container        gitea.volume
│   ├── woodpecker-server.container
│   ├── wp-agent-{python,node,go,rust,java}.container
│   ├── registry.container     registry.volume
│   ├── minio.container        minio.volume
│   ├── lab-{python,node,go,rust,java}.container
│   └── lab-backup.container
├── systemd/
│   └── lab-backup.timer
├── config/
│   ├── postgres/init.sql
│   └── registry/config.yml
├── setup.sh             # Automated deployment + start/stop
├── create-repos.sh      # Create Gitea repos with boilerplate + CI
├── RESTORE.md           # Disaster recovery
├── README.md            # This file
├── skill.md             # Machine-readable skill definition
└── LICENSE
```

Host volume paths use the `%h` systemd specifier (resolves to `$HOME` at
runtime), while `__USER__`, `__UID__`, and `__DOMAIN__` placeholders are
replaced at deploy time by `setup.sh`. This makes the repo portable —
clone, run `./setup.sh`, and the lab deploys on any machine.

> **Podman 4.9 compatibility**: Quadlet `.network` and `.volume` files in
> this repo omit the `Description` key, which podman 4.9's quadlet generator
> does not support in `[Network]`/`[Volume]` sections. Container `[Unit]`
> sections avoid `After=`/`Requires=` references to `.network` and `.volume`
> units — the `Network=` and `Volume=` keys in `[Container]` handle
> dependencies automatically.
>
> podman 4.9 uses the CNI network backend and lacks the `dnsname` plugin,
> so containers cannot resolve each other by hostname via DNS. Each
> service is assigned a **static IP** (see below), and containers that
> reference other services by hostname inject `/etc/hosts` entries via
> `PodmanArgs=--add-host` in their quadlet files.

## Network & IP Management

podman 4.9's CNI backend does not provide built-in DNS for container name
resolution on user-defined bridge networks. To work around this, each
infrastructure service is assigned a **fixed IP** on the `lab-net` bridge,
and containers that need to reach them use `/etc/hosts` entries injected
via `PodmanArgs=--add-host`.

### Default IP assignments

| Hostname | IP | Assigned to |
|----------|:--:|-------------|
| `postgres` | `10.89.1.2` | `postgres.container` (`IP=`) |
| `redis` | `10.89.1.3` | `redis.container` (`IP=`) |
| `gitea` | `10.89.1.4` | `gitea.container` (`IP=`) |
| `woodpecker-server` | `10.89.1.5` | `woodpecker-server.container` (`IP=`) |
| `minio` | `10.89.1.6` | `minio.container` (`IP=`) |
| `registry` | `10.89.1.7` | `registry.container` (`IP=`) |

### Containers that inject `/etc/hosts`

| Container | Entries added |
|-----------|---------------|
| `gitea` | `postgres:10.89.1.2`, `redis:10.89.1.3` |
| `lab-backup` | `postgres:10.89.1.2`, `gitea:10.89.1.4` |
| `wp-agent-*` | `woodpecker-server:10.89.1.5` |

### Customizing IPs

Override any IP at deploy time via environment variables:

```bash
NETWORK_SUBNET=10.89.1 POSTGRES_IP=10.89.1.10 ./setup.sh
```

Or change the entire subnet:

```bash
NETWORK_SUBNET=172.20.0 ./setup.sh
# Results: postgres=172.20.0.2, redis=172.20.0.3, etc.
```

The placeholders are:

| Placeholder | Default | Override env |
|-------------|:-------:|--------------|
| `__POSTGRES_IP__` | `${NETWORK_SUBNET}.2` | `POSTGRES_IP` |
| `__REDIS_IP__` | `${NETWORK_SUBNET}.3` | `REDIS_IP` |
| `__GITEA_IP__` | `${NETWORK_SUBNET}.4` | `GITEA_IP` |
| `__WOODPECKER_IP__` | `${NETWORK_SUBNET}.5` | `WOODPECKER_IP` |
| `__MINIO_IP__` | `${NETWORK_SUBNET}.6` | `MINIO_IP` |
| `__REGISTRY_IP__` | `${NETWORK_SUBNET}.7` | `REGISTRY_IP` |

The `NETWORK_SUBNET` variable defaults to `10.89.1` (the first three octets).
IPs increment from `.2` to avoid the gateway at `.1`.

### Stale CNI leases

If a container fails to start with `requested IP address X.X.X.X is not
available`, a stale CNI lease exists from a previous run. Clear it with:

```bash
rm -f /run/user/$(id -u)/libpod/tmp/rootless-netns/var/lib/cni/networks/systemd-lab-net/<IP>
```

Then restart the service.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Container won't start | `journalctl --user -u <service>` |
| Port conflict | `ss -tlnp \| grep <PORT>` |
| Agent won't connect | Verify gRPC port 9000, check `WOODPECKER_AGENT_SECRET` matches |
| Gitea can't reach Postgres | Both must be on `lab-net`; check `podman exec gitea cat /etc/hosts` has `postgres` entry |
| Container name lookup fails (DNS) | podman 4.9 lacks container DNS; uses static IPs + `/etc/hosts` — see **Network & IP Management** |
| `requested IP address not available` | Stale CNI lease — clear it (see **Stale CNI leases** above) |
| Volume permission denied | Add `:Z` to volume mounts (SELinux context) |
| Podman socket error | Ensure `/run/user/$UID/podman/podman.sock` exists |
| Woodpecker `password authentication failed` | Secrets are preserved across re-runs; this shouldn't happen. If it does: `podman exec postgres psql -U postgres -c "ALTER USER woodpecker WITH PASSWORD '<new>';"` then update `secrets.env` and restart |
| Woodpecker `Client ID not registered` | OAuth credentials are preserved across re-runs. If missing, re-paste into `secrets.env` and restart woodpecker-server |
| Woodpecker `registration is closed` | Set `WOODPECKER_OPEN=true` in `woodpecker-server.container` and restart |
| Cloudflared not routing | Check `systemctl --user status cloudflared`; restart with `systemctl --user start cloudflared` |
| Service won't start after `podman system reset` | Run `./setup.sh` to recreate network/volumes, then `./setup.sh --start` |

### Full Deployment Workflow

```bash
# 1. Clone and deploy
git clone <repo-url> podman-lab && cd podman-lab
./setup.sh                          # deploy configs + sync secrets

# 2. Start services
./setup.sh --start                  # starts all in dependency order

# 3. Start cloudflared tunnel
systemctl --user start cloudflared

# 4. Verify external access
curl -s -o /dev/null -w "%{http_code}" https://git.runemal.cloud
curl -s -o /dev/null -w "%{http_code}" https://ci.runemal.cloud

# 5. Create Gitea admin + OAuth2 app (manual)
#    Visit https://git.runemal.cloud, create user, add OAuth2 app

# 6. Update secrets.env with OAuth credentials
#    Edit ~/.local/share/podman-lab/secrets.env
#    systemctl --user restart woodpecker-server

# 7. Create language repos with CI
./create-repos.sh --token <TOKEN>

# 8. Enable Woodpecker for each repo in Gitea settings
```
