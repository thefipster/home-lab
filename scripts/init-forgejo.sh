#!/usr/bin/env bash
#
# init-forgejo.sh — project-specific setup for this compose stack.
#
# Assumes Docker is already installed (run scripts/init-host.sh first). It
# performs the remaining, Forgejo-specific Part 0 steps (see the setup guide):
#   1. Create the persistent data tree under /opt/forgejo and set ownership.
#   2. Record the host docker group's numeric GID in .env (compose reads it).
#   3. Allow the plain-HTTP Forgejo registry in the host Docker daemon.
#
# Run from anywhere; .env is written to infra/forgejo/ next to the compose file.
# Usage (from the repo root):
#   scripts/init-forgejo.sh
#   REGISTRY_ADDR=forgejo.example.com:3000 scripts/init-forgejo.sh   # override addr

set -euo pipefail

# Address the CI push / pulls use for the still-plain-HTTP Forgejo registry.
# Must match ROOT_URL / the runner registration. Override via env if needed.
REGISTRY_ADDR="${REGISTRY_ADDR:-homelab:3000}"

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
# Forgejo + runner run as UID/GID 1000 (see USER_UID/GID in docker-compose.yml)
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

echo "==> Allowing insecure (HTTP) registry ${REGISTRY_ADDR} in /etc/docker/daemon.json"
DAEMON_JSON="/etc/docker/daemon.json"
if command -v jq >/dev/null 2>&1 && run_root test -f "$DAEMON_JSON"; then
  # Merge into existing config without clobbering other settings.
  MERGED="$(run_root cat "$DAEMON_JSON" \
    | jq --arg r "$REGISTRY_ADDR" '.["insecure-registries"] = ((.["insecure-registries"] // []) + [$r] | unique)')"
  echo "$MERGED" | run_root tee "$DAEMON_JSON" > /dev/null
elif run_root test -f "$DAEMON_JSON"; then
  echo "WARNING: $DAEMON_JSON already exists and 'jq' is not installed, so it" >&2
  echo "         was left untouched. Add \"${REGISTRY_ADDR}\" to its" >&2
  echo "         \"insecure-registries\" array by hand, then: sudo systemctl restart docker" >&2
else
  # Fresh box: no daemon.json yet, safe to create.
  printf '{ "insecure-registries": ["%s"] }\n' "$REGISTRY_ADDR" \
    | run_root tee "$DAEMON_JSON" > /dev/null
fi

echo "==> Restarting Docker to apply the registry change"
run_root systemctl restart docker

echo
echo "Done. Next steps (see README):"
echo "  - Part A: docker compose up -d db forgejo"
echo "  - Part B: register the runner (one-time, needs a token from the UI)"
