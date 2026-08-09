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
# read-only. It is the only stack in the repo with no data directory, which is
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

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the Homepage stack into ${STACKS_DIR}/homepage (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
if [ -e "${STACKS_DIR}/homepage" ] && [ ! -L "${STACKS_DIR}/homepage" ]; then
  echo "    ${STACKS_DIR}/homepage exists and is NOT a symlink — leaving it alone." >&2
  exit 1
fi
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/homepage"
echo "    linked ${STACKS_DIR}/homepage -> ${STACK_DIR}"

cat <<EOF

Done. Next:
  cd ${STACK_DIR} && docker compose up -d

Then https://home.thefipster.de — Authentik will ask you to log in first.
Guide: docs/homepage-setup.md
EOF
