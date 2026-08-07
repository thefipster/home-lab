#!/usr/bin/env bash
#
# init-backup.sh — install layer 2, the file-level restic backup.
#
# Installs restic, creates /opt/backup, seeds infra/backup/.env, generates the
# SSH key the repository is reached with, initialises the restic repository and
# enables the two timers.
#
# Build order: LAST on the infra VM. Needs Uptime Kuma for the push monitor URL,
# and needs the HOST-side prerequisites (the `resticbackup` user and its
# chroot) to already exist — that is Part 1 of docs/backup-setup.md and runs on
# the Proxmox host, not here.
#
# Usage (from the repo root):
#   scripts/init-backup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/backup"
BACKUP_ROOT="/opt/backup"

# The host serving the repository over SFTP. By NAME, never an address — the
# router is the source of truth for addresses (docs/dns-records.md).
PVE_HOST="${PVE_HOST:-pve.thefipster.de}"

UNITS="restic-backup.service restic-backup.timer restic-check.service restic-check.timer"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Like run_root, but for restic calls that need RESTIC_REPOSITORY/PASSWORD.
# Those come from the .env sourced below (via `set -a`) and must stay in the
# environment rather than on the command line — `env VAR=val restic ...`
# would put the plaintext password in this process's argv, readable by any
# local user via `ps auxww` or /proc/<pid>/cmdline. --preserve-env carries
# the already-exported variables across sudo without ever naming the value.
restic_root() {
  if [ "$(id -u)" -eq 0 ]; then
    restic "$@"
  else
    sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD restic "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-docker.sh first." >&2
  exit 1
fi

echo "==> Installing restic"
if ! command -v restic >/dev/null 2>&1; then
  run_root apt-get update
  run_root apt-get install -y restic
fi

echo "==> Creating ${BACKUP_ROOT}"
run_root mkdir -p "${BACKUP_ROOT}/dumps" "${BACKUP_ROOT}/restore"
# The dumps contain every credential the lab has, in plain SQL. Root only.
run_root chmod 700 "${BACKUP_ROOT}"

echo "==> Seeding ${STACK_DIR}/.env"
if [ ! -f "${STACK_DIR}/.env" ]; then
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
fi
# Outside the branch on purpose: a hand-created .env would otherwise keep the
# umask's 644 while the guide's layout table promises 600. chmod is idempotent.
chmod 600 "${STACK_DIR}/.env"

echo "==> Ensuring root has an SSH key for the backup repository"
run_root mkdir -p /root/.ssh
run_root chmod 700 /root/.ssh
if ! run_root test -f /root/.ssh/id_ed25519; then
  run_root ssh-keygen -t ed25519 -N '' -C "restic-backup@infra" -f /root/.ssh/id_ed25519
fi

echo
echo "Public key — install this in the resticbackup user's authorized_keys on ${PVE_HOST}:"
run_root cat /root/.ssh/id_ed25519.pub
echo

# A systemd timer cannot answer a trust-on-first-use prompt, so the host key has
# to be accepted now, by a human looking at the fingerprint.
echo "==> Recording the ${PVE_HOST} host key"
if ! run_root grep -q "${PVE_HOST}" /root/.ssh/known_hosts 2>/dev/null; then
  # `|| true`: this is a bare assignment, not an if-condition, so under
  # `set -e` a non-zero ssh-keyscan (unresolvable/unreachable host) would
  # kill the script here instead of reaching the friendly diagnostic below.
  scan="$(ssh-keyscan -t ed25519 "${PVE_HOST}" 2>/dev/null)" || true
  if [ -z "$scan" ]; then
    echo "ssh-keyscan got nothing from ${PVE_HOST}. Is the name resolving?" >&2
    exit 1
  fi
  echo "Verify this fingerprint against the host (run 'ssh-keygen -lf"
  echo "/etc/ssh/ssh_host_ed25519_key.pub' there):"
  printf '%s\n' "$scan" | ssh-keygen -lf -
  printf '%s\n' "$scan" | run_root tee -a /root/.ssh/known_hosts >/dev/null
fi

# ---- Everything past here needs a filled-in .env ---------------------------

set -a
# shellcheck source=/dev/null
. "${STACK_DIR}/.env"
set +a

if [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo
  echo "RESTIC_PASSWORD is empty in ${STACK_DIR}/.env."
  echo
  echo "Generate one, WRITE IT DOWN SOMEWHERE OUTSIDE THIS LAB, put it in the"
  echo "file, then re-run this script. Losing it means losing the repository:"
  echo
  echo "  openssl rand -base64 32"
  echo
  exit 1
fi

echo "==> Initialising the restic repository (if it isn't already)"
if restic_root cat config >/dev/null 2>&1; then
  echo "    already initialised"
else
  restic_root init
fi

echo "==> Installing the systemd units"
for unit in ${UNITS}; do
  sed "s#@REPO_ROOT@#${REPO_ROOT}#g" "${STACK_DIR}/${unit}" \
    | run_root tee "/etc/systemd/system/${unit}" >/dev/null
done
run_root systemctl daemon-reload
run_root systemctl enable --now restic-backup.timer restic-check.timer

echo
echo "Done. Timers:"
run_root systemctl list-timers 'restic-*' --no-pager
echo
echo "Run the first backup by hand rather than waiting for 01:00 — the first"
echo "one uploads everything and may take a while:"
echo
echo "  sudo ${STACK_DIR}/run.sh"
