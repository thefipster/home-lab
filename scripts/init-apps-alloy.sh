#!/usr/bin/env bash
#
# init-apps-alloy.sh — bring up the APPS VM's log collector.
#
# WHICH MACHINE RUNS THIS: the apps VM, and only the apps VM. The infra VM's
# Alloy is part of infra/monitoring and is started with that stack; running this
# there would tail the same containers twice.
#
# Named for the machine rather than the stack because `init-alloy.sh` would read
# as the OTHER Alloy — the one inside infra/monitoring.
#
# It STARTS THE STACK ITSELF, which only init-dockge.sh otherwise does, and for a
# stronger version of the same reason. Dockge starts itself because Dockge is
# what you would otherwise start stacks with and it is not up yet. This machine
# has no Dockge AT ALL — no /opt/stacks, nothing to drive start/stop/logs from —
# so a script that prepared the stack and left it stopped would hand you a
# `docker compose up` with no home. Hence also no symlink step.
#
# Assumes Docker exists, which on this machine means scripts/init-coolify.sh has
# run (Coolify's installer brings the Engine — init-docker.sh is deliberately
# skipped here).
#
# Re-runnable: mkdir -p and `compose up -d` are both idempotent.
# Usage (from anywhere):
#   scripts/init-apps-alloy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/apps/alloy"

# Alloy's read positions. Not backed up anywhere on purpose: losing them
# re-reads logs rather than losing them.
DATA_DIR="/opt/alloy"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-coolify.sh first; its installer" >&2
  echo "brings the Engine on this machine." >&2
  exit 1
fi

echo "==> Creating ${DATA_DIR}"
# No chown: this image runs as root in-container, like the infra VM's Alloy.
run_root mkdir -p "${DATA_DIR}"

echo "==> Starting the collector"
# run_root, NOT a bare `docker compose`. This machine skips init-docker.sh, so
# nothing ever added the invoking user to the `docker` group — Coolify's
# installer brings the Engine and does not do it either. A bare call here fails
# with "permission denied ... unix:///var/run/docker.sock". init-coolify.sh
# already takes this precaution for the same reason.
( cd "${STACK_DIR}" && run_root docker compose up -d )

cat <<EOF

Done. Nothing else runs on this machine.

Verify from here (sudo: this machine has no docker group membership):
  sudo docker compose -f ${STACK_DIR}/compose.yaml logs alloy

Then in Grafana (Explore -> Loki), from any browser:
  {job="docker", instance="apps"}

If that stays empty, check the DNS record FIRST — the wildcard answers with
this VM, so a missing loki.thefipster.de record 404s the push against
Coolify's own proxy:
  getent hosts loki.thefipster.de

Guide: docs/apps-logs-setup.md
EOF
