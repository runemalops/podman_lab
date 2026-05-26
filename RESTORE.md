# Restore Guide — podman-lab

## Overview

Backups are stored in `~/.local/share/podman-lab/backups/` with 30-day retention.
Each service has its own subdirectory.

```
backups/
├── postgres/
│   └── full_YYYYMMDD.sql.gz
├── gitea/
│   └── gitea_YYYYMMDD.tar.gz
└── registry/
    └── registry_YYYYMMDD.tar.gz
```

---

## PostgreSQL

### Restore a single database
```bash
gunzip -c backups/postgres/full_20250101.sql.gz | podman exec -i postgres psql -U postgres gitea
```

### Restore all databases (full replacement)
```bash
gunzip -c backups/postgres/full_20250101.sql.gz | podman exec -i postgres psql -U postgres
```

> The dump includes `CREATE DATABASE` and `CREATE USER` statements, so
> existing objects are dropped and recreated.

---

## Gitea

### Full restore (repos, LFS, config, database)
```bash
systemctl --user stop gitea
rm -rf ~/.local/share/podman-lab/gitea/*
tar -xzf backups/gitea/gitea_20250101.tar.gz \
  -C ~/.local/share/podman-lab/gitea/
systemctl --user start gitea
```

Gitea's backup includes the embedded SQLite database (if using SQLite) or
the filesystem state. If using PostgreSQL (our default), restore the
database separately:

```bash
gunzip -c backups/postgres/full_20250101.sql.gz | podman exec -i postgres psql -U postgres gitea
```

---

## Container Registry

Images are content-addressable; the tar backup preserves the blob store.
```bash
systemctl --user stop registry
rm -rf ~/.local/share/podman-lab/registry/*
tar -xzf backups/registry/registry_20250101.tar.gz \
  -C ~/.local/share/podman-lab/registry/
systemctl --user start registry
```

> Alternative: re-pull images from upstream registries or re-push from
> CI pipelines instead of restoring from backup.

---

## MinIO

### Via `mc` client
```bash
podman exec -it minio mc alias set local \
  http://localhost:9000 admin <MINIO_ROOT_PASSWORD>

podman exec -it minio mc mirror \
  local/mybucket /path/to/backup/mybucket
```

### Via host filesystem
```bash
systemctl --user stop minio
# The data is at  ~/.local/share/podman-lab/minio/
systemctl --user start minio
```

---

## Full Disaster Recovery

If the entire `~/.local/share/podman-lab/` is lost but backups exist:

```bash
# 1. Re-run setup to recreate directory structure and secrets
./setup.sh

# 2. Restore Postgres
gunzip -c ~/.local/share/podman-lab/backups/postgres/full_latest.sql.gz \
  | podman exec -i postgres psql -U postgres

# 3. Restore Gitea
systemctl --user stop gitea
tar -xzf ~/.local/share/podman-lab/backups/gitea/gitea_latest.tar.gz \
  -C ~/.local/share/podman-lab/gitea/
systemctl --user start gitea

# 4. Restore Registry
systemctl --user stop registry
tar -xzf ~/.local/share/podman-lab/backups/registry/registry_latest.tar.gz \
  -C ~/.local/share/podman-lab/registry/
systemctl --user start registry

# 5. Restore MinIO data from backup or re-pull
```

---

## Test Backup Integrity

```bash
# Check Postgres dump
gunzip -c backups/postgres/full_latest.sql.gz | head -50

# Check Gitea tar
tar -tzf backups/gitea/gitea_latest.tar.gz | head -20

# Check Registry tar
tar -tzf backups/registry/registry_latest.tar.gz | head -20
```
