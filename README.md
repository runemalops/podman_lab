# podman-lab

A local software development lifecycle (SDLC) laboratory running entirely on
**Podman Quadlets** as rootless systemd services. Every component — from Git
hosting to CI/CD to artifact storage — is declaratively defined in quadlet
files and managed with `systemctl --user`.

## Architecture

```
Internet -> Cloudflare -> Cloudflared (host network, existing tunnel)
                               |
       localhost:3000    localhost:8000   localhost:5000  localhost:9001
           |                  |               |               |
        gitea           woodpecker-server  registry        minio
           |                  |               |               |
           +------------------+---------------+---------------+
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
| **Woodpecker** | CI/CD server + per-language agents | 8000 | `ci.runemal.cloud` |
| **Registry** | Private container image storage | 5000 | `registry.runemal.cloud` |
| **MinIO** | S3-compatible artifact & log storage | 9000/9001 | `minio.runemal.cloud` |
| **Dev containers** | Python, Node, Go, Rust, Java envs | varied | *local only* |
| **Backup** | Daily pg_dump + tar with 30-day rotation | — | *timer: 03:00* |

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

- Podman >= 4.6
- systemd --user available
- `loginctl enable-linger $USER` (run automatically by setup)

### Deploy

```bash
git clone <repo-url> podman-lab
cd podman-lab
./setup.sh
```

`setup.sh`:
1. Checks prerequisites and enables linger
2. Creates `~/.local/share/podman-lab/` directory tree
3. Generates random secrets → `secrets.env` (chmod 600)
4. Generates PostgreSQL init script with matching passwords
5. Interpolates `__USER__`, `__UID__`, `__DOMAIN__` in quadlet files
6. Copies quadlets → `~/.config/containers/systemd/`
7. Copies systemd timer → `~/.config/systemd/user/`
8. Runs `systemctl --user daemon-reload`
9. Prints post-setup instructions

### Start Services

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
| `lab-python` | python:3.12-slim | 8000, 5000 |
| `lab-node` | node:22-slim | 3000, 5173 |
| `lab-go` | golang:1.23 | 8080 |
| `lab-rust` | rust:slim | 8080 |
| `lab-java` | eclipse-temurin:21-jdk | 8080 |

Your `~/Projects/` directory is mounted at `/workspace/` in every dev container.

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
├── setup.sh             # Automated deployment
├── RESTORE.md           # Disaster recovery
├── README.md            # This file
├── skill.md             # Machine-readable skill definition
└── LICENSE
```

All user-specific paths use `__USER__` / `__UID__` placeholders, replaced
at deploy time by `setup.sh`. This makes the repo portable — clone, run
`./setup.sh`, and the lab deploys on any machine.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Container won't start | `journalctl --user -u <service>` |
| Port conflict | `ss -tlnp \| grep <PORT>` |
| Agent won't connect | Verify gRPC port 9000, check `WOODPECKER_AGENT_SECRET` matches |
| Gitea can't reach Postgres | Both must be on `lab-net`; verify hostname `postgres` |
| Volume permission denied | Add `:Z` to volume mounts (SELinux context) |
| Podman socket error | Ensure `/run/user/$UID/podman/podman.sock` exists |
