#!/usr/bin/env bash
#
# init-homepage.sh — project-specific setup for the Homepage stack.
#
# Assumes Docker is installed (run scripts/init-docker.sh first). Steps:
#   1. Ensure the shared `proxy` network exists.
#   2. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# That is the whole script, and it is the thinnest one here. There is NO .env
# and nothing to generate — every widget is token-free — and there is NO
# /opt/homepage, because this stack has no persistent state at all: its entire
# configuration is the git-tracked YAML in infra/homepage/config, bind-mounted
# read-only. It is the first stack in the repo with no data directory, which is
# also why it has no backup.sh.
#
# Re-runnable: every step is idempotent. Run from anywhere.
# Usage (from the repo root):
#   scripts/init-homepage.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/homepage"

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

echo "==> Ensuring the shared 'proxy' network exists"
if docker network inspect proxy >/dev/null 2>&1; then
  echo "    proxy network already exists"
else
  docker network create proxy
  echo "    created proxy network"
fi

echo "==> Symlinking the stack into /opt/stacks/homepage"
run_root mkdir -p /opt/stacks
if [ -L /opt/stacks/homepage ]; then
  echo "    /opt/stacks/homepage already a symlink -> $(readlink -f /opt/stacks/homepage)"
elif [ -e /opt/stacks/homepage ]; then
  echo "    /opt/stacks/homepage exists and is NOT a symlink — leaving it alone." >&2
  exit 1
else
  run_root ln -s "${STACK_DIR}" /opt/stacks/homepage
  echo "    linked /opt/stacks/homepage -> ${STACK_DIR}"
fi

cat <<EOF

Done. Next:
  cd ${STACK_DIR} && docker compose up -d

Then https://home.thefipster.de — Authentik will ask you to log in first.
Guide: docs/homepage-setup.md
EOF
