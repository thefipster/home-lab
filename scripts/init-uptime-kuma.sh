#!/usr/bin/env bash
#
# init-uptime-kuma.sh — project-specific setup for the Uptime Kuma stack.
#
# Assumes Docker is installed (run scripts/init-docker.sh first). Steps:
#   1. Create the persistent data dir at /opt/uptime-kuma.
#   2. Ensure the shared `proxy` network exists.
#   3. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# There is NO .env and nothing to generate — Kuma has no database and creates
# its admin account through its own first-run web form. It is the only stack
# with no .env at all (Dockge also ships no .env.example, but its init script
# generates a .env for it).
#
# No chown either: the default image runs as root (like Alloy, unlike the rest
# of the monitoring tree, where each image drops to a different UID).
#
# Re-runnable: every step is idempotent. Run from anywhere.
# Usage (from the repo root):
#   scripts/init-uptime-kuma.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/uptime-kuma"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-docker.sh first." >&2
  exit 1
fi

echo "==> Creating the persistent data dir at /opt/uptime-kuma"
run_root mkdir -p /opt/uptime-kuma

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the stack into ${STACKS_DIR}/uptime-kuma (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/uptime-kuma"

echo
echo "Done. Next (see docs/uptime-kuma-setup.md):"
echo "  1. Verify the uptime.thefipster.de host record resolves to the infra"
echo "     VM — the registry is docs/dns-records.md. The *.thefipster.de"
echo "     wildcard points at the APPS VM, so without an exact record the"
echo "     name hits the wrong box and returns a 404 behind a valid cert."
echo "  2. cd ${STACK_DIR} && docker compose up -d"
echo "  3. Open https://uptime.thefipster.de and create the admin account."
echo "     There is NO Authentik login in front of this — that is deliberate;"
echo "     see docs/sso-applications.md."
