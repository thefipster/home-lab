#!/usr/bin/env bash
#
# init-traefik.sh — set up the Traefik reverse-proxy stack on the infra VM.
#
# Assumes Docker is installed (run scripts/init-host.sh first). Steps:
#   1. Create the shared `proxy` Docker network (all proxied stacks join it).
#   2. Create the persistent ACME dir under /opt/traefik.
#   3. Seed infra/traefik/.env from .env.example if missing (you fill it in).
#   4. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# Usage (from the repo root):
#   scripts/init-traefik.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/traefik"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-host.sh first." >&2
  exit 1
fi

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

echo "==> Creating persistent ACME dir /opt/traefik/letsencrypt"
run_root mkdir -p /opt/traefik/letsencrypt

if [ ! -f "${STACK_DIR}/.env" ]; then
  echo "==> Seeding ${STACK_DIR}/.env from .env.example — FILL IN REAL VALUES"
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
fi

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the Traefik stack into ${STACKS_DIR}/traefik (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/traefik"

echo
echo "Done. Next (see docs/traefik-setup.md):"
echo "  1. Edit ${STACK_DIR}/.env with your netcup credentials."
echo "  2. cd ${STACK_DIR} && docker compose up -d   (staging CA first)"
echo "  3. Watch: docker compose logs -f traefik — wait for the staging cert."
echo "  4. Switch to production per the guide."
