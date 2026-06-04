#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────
# podman-lab — Automated Deployment Script
# ───────────────────────────────────────────────────────
# Usage: ./setup.sh [--domain runemal.cloud] [--start|--stop|--status]
#
# Placeholders replaced in quadlet files:
#   __USER__        → $USER
#   __UID__         → $(id -u)
#   __DOMAIN__      → $DOMAIN (default runemal.cloud)
#   __POSTGRES_IP__    → $POSTGRES_IP    (default 10.89.1.2)
#   __REDIS_IP__       → $REDIS_IP       (default 10.89.1.3)
#   __GITEA_IP__       → $GITEA_IP       (default 10.89.1.4)
#   __WOODPECKER_IP__  → $WOODPECKER_IP  (default 10.89.1.5)
#   __MINIO_IP__       → $MINIO_IP       (default 10.89.1.6)
#   __REGISTRY_IP__    → $REGISTRY_IP    (default 10.89.1.7)
#   __LAB_PYTHON_IP__  → $LAB_PYTHON_IP  (default 10.89.1.10)
#   __LAB_NODE_IP__    → $LAB_NODE_IP    (default 10.89.1.11)
#   __LAB_GO_IP__      → $LAB_GO_IP      (default 10.89.1.12)
#   __LAB_JAVA_IP__    → $LAB_JAVA_IP    (default 10.89.1.13)
#   __LAB_RUST_IP__    → $LAB_RUST_IP    (default 10.89.1.14)
#
# Also generates random secrets, copies everything
# into place, and reloads systemd.
# ───────────────────────────────────────────────────────

DOMAIN="${DOMAIN:-runemal.cloud}"

# ── CLI argument parsing ───────────────────────────

ACTION="setup"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)
      ACTION="start"
      shift
      ;;
    --stop)
      ACTION="stop"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --domain=*)
      DOMAIN="${1#*=}"
      shift
      ;;
    *)
      echo "Usage: $0 [--domain runemal.cloud] [--start|--stop|--status]"
      exit 1
      ;;
  esac
done

# ── Start / Stop helpers ──────────────────────────

start_lab() {
  echo "Starting podman-lab services ..."
  # Ordered by dependency graph
  systemctl --user start postgres redis
  systemctl --user start gitea
  systemctl --user start woodpecker-server
  systemctl --user start wp-agent-python wp-agent-node wp-agent-go wp-agent-rust wp-agent-java
  systemctl --user start registry minio
  systemctl --user enable --now lab-backup.timer 2>/dev/null || true
  echo "All services started."
}

stop_lab() {
  echo "Stopping podman-lab services ..."
  # Reverse dependency order
  systemctl --user stop lab-backup.timer 2>/dev/null || true
  systemctl --user stop wp-agent-python wp-agent-node wp-agent-go wp-agent-rust wp-agent-java
  systemctl --user stop woodpecker-server
  systemctl --user stop gitea
  systemctl --user stop registry minio redis postgres
  echo "All services stopped."
}

status_lab() {
  echo "podman-lab service status"
  echo "========================="
  for svc in postgres redis gitea woodpecker-server \
             wp-agent-python wp-agent-node wp-agent-go wp-agent-rust wp-agent-java \
             registry minio lab-backup.timer; do
    if systemctl --user is-active --quiet "$svc" 2>/dev/null; then
      printf "  \e[32m●\e[0m %s\n" "$svc"
    elif systemctl --user is-failed --quiet "$svc" 2>/dev/null; then
      printf "  \e[31m●\e[0m %s (failed)\n" "$svc"
    else
      printf "  \e[33m○\e[0m %s (inactive)\n" "$svc"
    fi
  done
}

# ── Dispatch action ───────────────────────────────

case "$ACTION" in
  start)  start_lab;  exit 0 ;;
  stop)   stop_lab;   exit 0 ;;
  status) status_lab; exit 0 ;;
  setup) ;;  # fall through to full setup below
esac

# ── Container IPs ──────────────────────────────────
# podman 4.9 (CNI backend) lacks container DNS, so
# each service gets a fixed IP and dependent containers
# inject /etc/hosts entries via --add-host (PodmanArgs).
# Override via env vars or --network-subnet flag:
#   NETWORK_SUBNET=10.89.1 POSTGRES_IP=10.89.1.10 ./setup.sh
NETWORK_SUBNET="${NETWORK_SUBNET:-10.89.1}"
POSTGRES_IP="${POSTGRES_IP:-${NETWORK_SUBNET}.2}"
REDIS_IP="${REDIS_IP:-${NETWORK_SUBNET}.3}"
GITEA_IP="${GITEA_IP:-${NETWORK_SUBNET}.4}"
WOODPECKER_IP="${WOODPECKER_IP:-${NETWORK_SUBNET}.5}"
MINIO_IP="${MINIO_IP:-${NETWORK_SUBNET}.6}"
REGISTRY_IP="${REGISTRY_IP:-${NETWORK_SUBNET}.7}"
LAB_PYTHON_IP="${LAB_PYTHON_IP:-${NETWORK_SUBNET}.10}"
LAB_NODE_IP="${LAB_NODE_IP:-${NETWORK_SUBNET}.11}"
LAB_GO_IP="${LAB_GO_IP:-${NETWORK_SUBNET}.12}"
LAB_JAVA_IP="${LAB_JAVA_IP:-${NETWORK_SUBNET}.13}"
LAB_RUST_IP="${LAB_RUST_IP:-${NETWORK_SUBNET}.14}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
QUADLET_SRC="$REPO_DIR/quadlets"
SYSTEMD_SRC="$REPO_DIR/systemd"
CONFIG_SRC="$REPO_DIR/config"

CONTAINERS_DIR="$HOME/.config/containers/systemd"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
DATA_DIR="$HOME/.local/share/podman-lab"
SECRETS_FILE="$DATA_DIR/secrets.env"

echo "=========================================="
echo "  podman-lab Setup"
echo "=========================================="
echo "Domain:      $DOMAIN"
echo "User:        $USER"
echo "UID:         $(id -u)"
echo "Subnet:      ${NETWORK_SUBNET}.0/24"
echo "IPs:         postgres=$POSTGRES_IP  redis=$REDIS_IP  gitea=$GITEA_IP  woodpecker=$WOODPECKER_IP  minio=$MINIO_IP  registry=$REGISTRY_IP  lab-python=$LAB_PYTHON_IP  lab-node=$LAB_NODE_IP  lab-go=$LAB_GO_IP  lab-java=$LAB_JAVA_IP  lab-rust=$LAB_RUST_IP"
echo "Repo:        $REPO_DIR"
echo "Quadlets ->  $CONTAINERS_DIR"
echo "Data    ->   $DATA_DIR"
echo "=========================================="

# ── Prerequisites ────────────────────────────────

command -v podman >/dev/null 2>&1 || { echo "ERROR: podman not found"; exit 1; }

if ! systemctl --user status >/dev/null 2>&1; then
  echo "ERROR: systemd --user not available"
  exit 1
fi

if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
  echo "Enabling linger for $USER ..."
  loginctl enable-linger "$USER"
fi

# ── Create directory tree ────────────────────────

mkdir -p "$DATA_DIR"/{postgres/init.d,gitea,woodpecker,registry,minio,redis,backups,caddy}
mkdir -p "$CONTAINERS_DIR"
mkdir -p "$USER_SYSTEMD_DIR"

# ── Generate secrets ─────────────────────────────

echo "Generating random secrets ..."

POSTGRES_PASSWORD=$(openssl rand -hex 32)
GITEA_DB_PASS=$(openssl rand -hex 32)
WOODPECKER_DB_PASS=$(openssl rand -hex 32)
GITEA_SECRET_KEY=$(openssl rand -hex 32)
GITEA_INTERNAL_TOKEN=$(openssl rand -hex 32)
GITEA_LFS_JWT_SECRET=$(openssl rand -hex 32)
WOODPECKER_AGENT_SECRET=$(openssl rand -hex 32)
MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)

# Preserve manually configured OAuth credentials
EXISTING_WC_CLIENT=""
EXISTING_WC_SECRET=""
if [ -f "$SECRETS_FILE" ]; then
  EXISTING_WC_CLIENT=$(grep '^WOODPECKER_GITEA_CLIENT=' "$SECRETS_FILE" | cut -d= -f2-)
  EXISTING_WC_SECRET=$(grep '^WOODPECKER_GITEA_SECRET=' "$SECRETS_FILE" | cut -d= -f2-)
fi

cat > "$SECRETS_FILE" <<SECEOF
# podman-lab secrets — generated $(date)
# This file is sourced by quadlet containers via EnvironmentFile.
# Protect it: chmod 600

# --- PostgreSQL ---
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# --- Gitea ---
GITEA__database__PASSWD=$GITEA_DB_PASS
GITEA__server__SECRET_KEY=$GITEA_SECRET_KEY
GITEA__server__INTERNAL_TOKEN=$GITEA_INTERNAL_TOKEN
GITEA__server__LFS_JWT_SECRET=$GITEA_LFS_JWT_SECRET

# --- Woodpecker ---
WOODPECKER_GITEA_CLIENT=${EXISTING_WC_CLIENT}
WOODPECKER_GITEA_SECRET=${EXISTING_WC_SECRET}
WOODPECKER_AGENT_SECRET=$WOODPECKER_AGENT_SECRET
WOODPECKER_DATABASE_DRIVER=postgres
WOODPECKER_DATABASE_DATASOURCE=postgres://woodpecker:${WOODPECKER_DB_PASS}@postgres:5432/woodpecker?sslmode=disable

# --- MinIO ---
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
SECEOF

chmod 600 "$SECRETS_FILE"
echo "Secrets written to $SECRETS_FILE"

# ── Generate init.sql for PostgreSQL ──────────────

cat > "$DATA_DIR/postgres/init.d/init.sql" <<SQLEOF
-- Generated by setup.sh $(date)
CREATE USER gitea WITH PASSWORD '${GITEA_DB_PASS}';
CREATE DATABASE gitea OWNER gitea;
CREATE USER woodpecker WITH PASSWORD '${WOODPECKER_DB_PASS}';
CREATE DATABASE woodpecker OWNER woodpecker;
SQLEOF

echo "PostgreSQL init script written with secrets"

# ── Sync PostgreSQL passwords with secrets ───────
# init.sql only runs on first init; if postgres is
# already running, update passwords to match the
# freshly generated secrets.

if systemctl --user is-active --quiet postgres 2>/dev/null; then
  echo "Syncing PostgreSQL user passwords with new secrets ..."
  podman exec -i postgres psql -U postgres <<SYNCEOF
ALTER USER gitea WITH PASSWORD '${GITEA_DB_PASS}';
ALTER USER woodpecker WITH PASSWORD '${WOODPECKER_DB_PASS}';
SYNCEOF
  echo "PostgreSQL passwords updated"
  echo "Restarting services to pick up new secrets ..."
  systemctl --user restart gitea woodpecker-server 2>/dev/null || true
elif [ -d "$DATA_DIR/postgres" ] && [ "$(ls -A "$DATA_DIR/postgres" 2>/dev/null)" ]; then
  echo "Starting PostgreSQL temporarily to sync passwords ..."
  systemctl --user start postgres
  sleep 3
  podman exec -i postgres psql -U postgres <<SYNCEOF
ALTER USER gitea WITH PASSWORD '${GITEA_DB_PASS}';
ALTER USER woodpecker WITH PASSWORD '${WOODPECKER_DB_PASS}';
SYNCEOF
  echo "PostgreSQL passwords updated"
else
  echo "Fresh install — passwords will be set by init.sql on first start"
fi

# ── Copy & interpolate quadlet files ─────────────

REPLACE_USER="$USER"
REPLACE_UID="$(id -u)"
REPLACE_DOMAIN="$DOMAIN"

echo "Deploying quadlet files ..."

for src in "$QUADLET_SRC"/*.container "$QUADLET_SRC"/*.volume "$QUADLET_SRC"/*.network; do
  [ -f "$src" ] || continue
  filename=$(basename "$src")
  dest="$CONTAINERS_DIR/$filename"

  sed \
    -e "s/__USER__/$REPLACE_USER/g" \
    -e "s/__UID__/$REPLACE_UID/g" \
    -e "s/__DOMAIN__/$REPLACE_DOMAIN/g" \
    -e "s/__POSTGRES_IP__/$POSTGRES_IP/g" \
    -e "s/__REDIS_IP__/$REDIS_IP/g" \
    -e "s/__GITEA_IP__/$GITEA_IP/g" \
    -e "s/__WOODPECKER_IP__/$WOODPECKER_IP/g" \
    -e "s/__MINIO_IP__/$MINIO_IP/g" \
    -e "s/__REGISTRY_IP__/$REGISTRY_IP/g" \
    -e "s/__LAB_PYTHON_IP__/$LAB_PYTHON_IP/g" \
    -e "s/__LAB_NODE_IP__/$LAB_NODE_IP/g" \
    -e "s/__LAB_GO_IP__/$LAB_GO_IP/g" \
    -e "s/__LAB_JAVA_IP__/$LAB_JAVA_IP/g" \
    -e "s/__LAB_RUST_IP__/$LAB_RUST_IP/g" \
    "$src" > "$dest"

  echo "  $filename -> $dest"
done

# ── Copy systemd timer ──────────────────────────

if [ -f "$SYSTEMD_SRC/lab-backup.timer" ]; then
  cp "$SYSTEMD_SRC/lab-backup.timer" "$USER_SYSTEMD_DIR/lab-backup.timer"
  echo "  lab-backup.timer -> $USER_SYSTEMD_DIR/"
fi

# ── Copy registry config ───────────────────────

if [ -f "$CONFIG_SRC/registry/config.yml" ]; then
  mkdir -p "$DATA_DIR/registry"
  cp "$CONFIG_SRC/registry/config.yml" "$DATA_DIR/registry/config.yml"
  echo "  registry/config.yml -> $DATA_DIR/registry/"
fi

# ── Reload systemd ──────────────────────────────

echo "Reloading systemd user daemon ..."
systemctl --user daemon-reload

# ── Summary ─────────────────────────────────────

echo ""
echo "=========================================="
echo "  Deployment Complete"
echo "=========================================="
echo ""
echo "Start services (in order):"
echo "  systemctl --user start postgres"
echo "  systemctl --user start redis"
echo "  systemctl --user start gitea"
echo "  systemctl --user start woodpecker-server"
echo "  systemctl --user start wp-agent-{python,node,go,rust,java}"
echo "  systemctl --user start registry"
echo "  systemctl --user start minio"
echo "  systemctl --user enable --now lab-backup.timer"
echo ""
echo "Enable on boot:"
echo "  systemctl --user enable --now postgres redis gitea"
echo "  systemctl --user enable --now woodpecker-server"
echo "  systemctl --user enable --now wp-agent-{python,node,go,rust,java}"
echo "  systemctl --user enable --now registry minio"
echo ""
echo "Post-setup manual steps:"
echo "  1. Visit https://git.${DOMAIN}  and create admin account"
echo "  2. Settings -> Applications -> OAuth2"
echo "     Create app 'Woodpecker CI' with redirect:"
echo "     https://ci.${DOMAIN}/authorize"
echo "  3. Edit $SECRETS_FILE:"
echo "     WOODPECKER_GITEA_CLIENT=<from OAuth>"
echo "     WOODPECKER_GITEA_SECRET=<from OAuth>"
echo "  4. systemctl --user restart woodpecker-server"
echo "  5. Add subdomains to Cloudflare tunnel:"
echo "     git.${DOMAIN}     -> localhost:3000"
echo "     ci.${DOMAIN}      -> localhost:8000"
echo "     registry.${DOMAIN} -> localhost:5000"
echo "     minio.${DOMAIN}   -> localhost:9001"
echo "  6. systemctl --user start lab-python (or other dev env)"
echo "     podman exec -it lab-python /bin/bash"
echo ""
echo "Dev containers mount $HOME/Projects/  to /workspace/"
echo "=========================================="
