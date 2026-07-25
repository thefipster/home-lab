#!/usr/bin/env bash
#
# init-dockge.sh — bring up Dockge, the compose-stack management UI.
#
# Dockge manages every OTHER stack under /opt/stacks from a web UI (start/stop,
# view logs, edit compose). It's the one stack you start by hand — it can't
# manage itself before it exists. After this, stacks dropped at
# /opt/stacks/<name>/compose.yaml show up in the UI (scripts/init-forgejo.sh
# links Forgejo in for you).
#
# Assumes Docker is installed (run scripts/init-host.sh first).
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
  echo "docker not found — run scripts/init-host.sh first." >&2
  exit 1
fi

# Dockge's compose joins the external `proxy` network (Traefik routes to it),
# so the network must exist even though Traefik comes up later.
echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

# Dockge lives under the stacks dir so it manages itself too (it'll list a
# "dockge" stack alongside the others). Its own data goes in ./data there.
echo "==> Creating ${DOCKGE_DIR}"
run_root mkdir -p "${DOCKGE_DIR}"

echo "==> Installing Dockge compose from the repo"
run_root cp "${REPO_ROOT}/infra/dockge/compose.yaml" "${DOCKGE_DIR}/compose.yaml"

echo "==> Starting Dockge"
( cd "${DOCKGE_DIR}" && docker compose up -d )

echo
echo "Done. Dockge is coming up — reachable at https://dockge.thefipster.de"
echo "once the Traefik stack is up (scripts/init-traefik.sh)."
echo "It manages stacks under ${STACKS_DIR}. Link others in (e.g. Forgejo via"
echo "scripts/init-forgejo.sh), then start/stop them from the UI."
