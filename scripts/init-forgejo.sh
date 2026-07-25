#!/usr/bin/env bash
#
# init-forgejo.sh — project-specific setup for this compose stack.
#
# Assumes Docker is already installed (run scripts/init-host.sh first). It
# performs the remaining, Forgejo-specific Part 0 steps (see the setup guide):
#   1. Create the persistent data tree under /opt/forgejo and set ownership.
#   2. Record the host docker group's numeric GID in .env (compose reads it).
#   3. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# The registry needs NO daemon configuration: Traefik serves it at
# https://git.thefipster.de with a publicly trusted cert (see
# docs/traefik-setup.md — bring Traefik up before Forgejo's first run).
#
# Run from anywhere; .env is written to infra/forgejo/ next to the compose file.
# Usage (from the repo root):
#   scripts/init-forgejo.sh

set -euo pipefail

# Resolve paths from the script's own location so it works regardless of the
# caller's working directory. .env must sit next to the compose file — Docker
# Compose reads it from the project directory — i.e. infra/forgejo/.env.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/infra/forgejo/.env"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run ./init-host.sh first." >&2
  exit 1
fi

echo "==> Creating persistent data tree under /opt/forgejo"
run_root mkdir -p /opt/forgejo/postgres /opt/forgejo/forgejo /opt/forgejo/runner
# Forgejo + runner run as UID/GID 1000 (see USER_UID/GID in compose.yaml)
# and must own their data dirs. Postgres manages its own dir's ownership.
run_root chown -R 1000:1000 /opt/forgejo/forgejo /opt/forgejo/runner

echo "==> Recording DOCKER_GID in ${ENV_FILE}"
DOCKER_GID="$(getent group docker | cut -d: -f3)"
if [ -z "$DOCKER_GID" ]; then
  echo "Could not read the docker group GID. Is Docker installed (./init-host.sh)?" >&2
  exit 1
fi
# Rewrite any existing DOCKER_GID line so re-runs don't accumulate duplicates.
if [ -f "$ENV_FILE" ] && grep -q '^DOCKER_GID=' "$ENV_FILE"; then
  # Use a temp file to keep the edit atomic and portable (no sed -i quirks).
  grep -v '^DOCKER_GID=' "$ENV_FILE" > "${ENV_FILE}.tmp" || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
fi
echo "DOCKER_GID=${DOCKER_GID}" >> "$ENV_FILE"

# Expose the stack to Dockge by symlinking it into the stacks dir. Dockge lists
# whatever lives under /opt/stacks/<name>/compose.yaml; the symlink keeps this
# repo the single source of truth (edits + .env stay in infra/forgejo/), so
# Dockge just drives start/stop/logs. Harmless if you don't run Dockge.
STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the Forgejo stack into ${STACKS_DIR}/forgejo (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${REPO_ROOT}/infra/forgejo" "${STACKS_DIR}/forgejo"

echo
echo "Done. Next steps (see docs/forgejo-setup.md):"
echo "  - Make sure the Traefik stack is up first (scripts/init-traefik.sh +"
echo "    docs/traefik-setup.md) — Forgejo is served at https://git.thefipster.de"
echo "  - Part A: start the stack — via Dockge (stack 'forgejo'), or from"
echo "            ${REPO_ROOT}/infra/forgejo run: docker compose up -d db forgejo"
echo "  - Part B: register the runner (one-time, needs a token from the UI)"
