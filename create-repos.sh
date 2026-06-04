#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────
# create-repos.sh — Create Gitea repos for lab languages
# ───────────────────────────────────────────────────────
# Creates a Git repo for each supported language on the
# Gitea instance, pushes boilerplate source files and a
# Woodpecker CI pipeline.
#
# Usage:
#   ./create-repos.sh                          # interactive
#   ./create-repos.sh --token <TOKEN>          # non-interactive
#   ./create-repos.sh --git-url https://git.runemal.cloud
#   ./create-repos.sh --gitea-url http://localhost:3000
#
# Options:
#   --token TOKEN        Gitea API token (required)
#   --gitea-url URL      Gitea API base URL (default: http://localhost:3000)
#   --git-url URL        Public Git URL for display & push (default: https://git.runemal.cloud)
#
# Requires: git, curl, jq
# ───────────────────────────────────────────────────────

GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GIT_URL="${GIT_URL:-https://git.runemal.cloud}"
GITEA_API_TOKEN="${GITEA_API_TOKEN:-}"
WORKSPACE="${WORKSPACE:-$HOME/Projects}"

# ── CLI argument parsing ───────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      GITEA_API_TOKEN="$2"
      shift 2
      ;;
    --gitea-url)
      GITEA_URL="$2"
      shift 2
      ;;
    --git-url)
      GIT_URL="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--token TOKEN] [--gitea-url URL] [--git-url URL]"
      exit 1
      ;;
  esac
done

# ── Prompt for token if not provided ──────────────

if [ -z "$GITEA_API_TOKEN" ]; then
  echo "Gitea API token required."
  echo "Create one at: ${GITEA_URL}/-/user/settings/applications"
  echo ""
  read -rsp "Token: " GITEA_API_TOKEN
  echo ""
fi

# ── Validate connection ───────────────────────────

echo "Connecting to Gitea at $GITEA_URL ..."
if ! curl -sf -o /dev/null -H "Authorization: token $GITEA_API_TOKEN" "$GITEA_URL/api/v1/user"; then
  echo "ERROR: Cannot connect to Gitea API. Check URL and token."
  exit 1
fi

GITEA_USER=$(curl -sf -H "Authorization: token $GITEA_API_TOKEN" "$GITEA_URL/api/v1/user" | jq -r '.login')
echo "Authenticated as: $GITEA_USER"
echo "Git URL: $GIT_URL"

# ── Language definitions ──────────────────────────
# name:local_dir:language

declare -a LANGUAGES=(
  "lab-python:$WORKSPACE/lab-python:Python"
  "lab-node:$WORKSPACE/lab-node:Node.js"
  "lab-go:$WORKSPACE/lab-go:Go"
  "lab-rust:$WORKSPACE/lab-rust:Rust"
  "lab-java:$WORKSPACE/lab-java:Java"
)

# ── Create repos and push ─────────────────────────

echo ""
echo "Creating repositories ..."

for entry in "${LANGUAGES[@]}"; do
  IFS=':' read -r repo_name local_dir language <<< "$entry"
  repo_full="$GITEA_USER/$repo_name"

  echo ""
  echo "[$language] $repo_name"

  # Create repo via API (ignore if exists)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token $GITEA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$repo_name\",\"description\":\"$language starter project for podman-lab\",\"auto_init\":false,\"private\":false}" \
    "$GITEA_URL/api/v1/user/repos")

  if [ "$http_code" = "201" ]; then
    echo "  Created repository"
  elif [ "$http_code" = "409" ]; then
    echo "  Repository already exists, skipping creation"
  else
    echo "  ERROR: Failed to create repository (HTTP $http_code)"
    continue
  fi

  # Push files
  cd "$local_dir"

  # Build auth URL for git push (uses API URL with token)
  git_auth_url=$(echo "$GITEA_URL" | sed "s|https\?://|http://${GITEA_API_TOKEN}@|")

  if [ ! -d ".git" ]; then
    git init -q
    git remote remove origin 2>/dev/null || true
    git remote add origin "$git_auth_url/$repo_full.git"
  else
    git remote set-url origin "$git_auth_url/$repo_full.git"
  fi

  git add -A
  if git diff --cached --quiet; then
    echo "  No changes to commit"
  else
    git commit -q -m "Initial commit: $language boilerplate + CI pipeline"
    git push -q -u origin main 2>/dev/null || git push -q -u origin master 2>/dev/null || {
      # Rename branch to main if needed
      git branch -M main
      git push -q -u origin main
    }
    echo "  Pushed to $GIT_URL/$repo_full"
  fi

  # Set remote to public URL for future use
  git remote set-url origin "$GIT_URL/$repo_full.git"
done

echo ""
echo "=========================================="
echo "  Done — repositories created"
echo "=========================================="
echo ""
for entry in "${LANGUAGES[@]}"; do
  IFS=':' read -r repo_name _ language <<< "$entry"
  printf "  %-8s %s/%s\n" "[$language]" "$GIT_URL/$GITEA_USER" "$repo_name"
done
echo ""
echo "Enable Woodpecker CI for each repo:"
for entry in "${LANGUAGES[@]}"; do
  IFS=':' read -r repo_name _ language <<< "$entry"
  echo "  $GIT_URL/$GITEA_USER/$repo_name/-/settings"
done
echo ""
