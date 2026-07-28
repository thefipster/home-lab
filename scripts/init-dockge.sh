#!/usr/bin/env bash
#
# init-dockge.sh — bring up Dockge, the compose-stack management UI.
#
# Dockge manages the stacks under /opt/stacks from a web UI (start/stop, view
# logs, edit compose), itself included. Stacks at /opt/stacks/<name>/compose.yaml
# show up in the UI — the other init scripts symlink theirs in, and this script
# records the repo path in .env so those symlinks resolve inside the container.
#
# Build order: run AFTER init-traefik.sh and init-authentik.sh (with both
# stacks up) — Dockge's router is gated by the authentik@docker middleware and
# won't load until Authentik is running. See docs/authentik-setup.md.
#
# Assumes Docker is installed (run scripts/init-docker.sh first).
# Usage (from the repo root):
#   scripts/init-dockge.sh

set -euo pipefail

# Must match DOCKGE_STACKS_DIR (and the volume) in infra/dockge/compose.yaml.
STACKS_DIR="/opt/stacks"
DOCKGE_DIR="${STACKS_DIR}/dockge"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# Dockge's compose joins the external `proxy` network (Traefik routes to it).
# In the normal build order Traefik already created it; creating is idempotent.
echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

# Dockge lives under the stacks dir so it manages itself too (it'll list a
# "dockge" stack alongside the others). Its own data goes in ./data there.
echo "==> Creating ${DOCKGE_DIR}"
run_root mkdir -p "${DOCKGE_DIR}"

echo "==> Installing Dockge compose from the repo"
run_root cp "${REPO_ROOT}/infra/dockge/compose.yaml" "${DOCKGE_DIR}/compose.yaml"

# The compose mounts the repo checkout at an identical inside/outside path so
# the /opt/stacks/<stack> symlinks (created by the other init scripts) resolve
# inside the Dockge container. Overwriting is fine — .env holds only this.
echo "==> Recording REPO_DIR=${REPO_ROOT} in ${DOCKGE_DIR}/.env"
echo "REPO_DIR=${REPO_ROOT}" | run_root tee "${DOCKGE_DIR}/.env" > /dev/null

echo "==> Starting Dockge"
( cd "${DOCKGE_DIR}" && docker compose up -d )

echo
echo "Done. Dockge is coming up at https://dockge.thefipster.de (login goes"
echo "through Authentik — Traefik + Authentik must both be up, see the build"
echo "order in the README). It manages stacks under ${STACKS_DIR}. Link others"
echo "in (e.g. Forgejo via scripts/init-forgejo.sh), then drive them from the UI."
