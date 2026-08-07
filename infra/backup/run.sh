#!/usr/bin/env bash
#
# run.sh — the nightly file-level backup. Layer 2 of docs/roadmap/backup.md.
#
# For every infra/<stack>/backup.sh: stage that stack's dumps, then take one
# restic snapshot tagged with the stack name. Per-stack tags are what make
# "restore Authentik, all of it, in one command" possible.
#
# Runs as ROOT. The /opt trees are owned by the UIDs their images run as
# (postgres 999, forgejo 1000, grafana 472), so nothing else can read all of
# them, and pg_dump needs the Docker socket regardless.
#
# Usage:  infra/backup/run.sh [stack ...]      (no arguments = every stack)

# NOT `set -e`. One stack failing must not cost the other six their snapshots —
# failures are collected and reported at the end instead. `-u` and `-o pipefail`
# still apply.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export REPO_ROOT

STAGE_ROOT="/opt/backup/dumps"

if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  echo "no ${SCRIPT_DIR}/.env — run scripts/init-backup.sh first." >&2
  exit 1
fi

# restic reads RESTIC_REPOSITORY and RESTIC_PASSWORD from the environment.
set -a
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/.env"
set +a

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY in infra/backup/.env}"
: "${RESTIC_PASSWORD:?set RESTIC_PASSWORD in infra/backup/.env}"

# Which stacks? Anything with a backup.sh — there is no list to keep in sync,
# so adding a stack is one file.
stacks=()
if [ "$#" -gt 0 ]; then
  stacks=("$@")
else
  for f in "${REPO_ROOT}"/infra/*/backup.sh; do
    [ -e "$f" ] || continue
    stacks+=("$(basename "$(dirname "$f")")")
  done
fi

if [ "${#stacks[@]}" -eq 0 ]; then
  echo "no infra/*/backup.sh found — nothing to do." >&2
  exit 1
fi

failed=()

for stack in "${stacks[@]}"; do
  script="${REPO_ROOT}/infra/${stack}/backup.sh"

  if [ ! -x "$script" ]; then
    echo "  ! ${stack}: ${script} is missing or not executable" >&2
    failed+=("$stack")
    continue
  fi

  stage="${STAGE_ROOT}/${stack}"
  echo "==> ${stack}: staging"

  # Overwritten every run. History lives in restic, not in a pile of timestamped
  # local files that grows until the disk is full.
  rm -rf "$stage"
  mkdir -p "$stage"

  degraded=0
  if ! BACKUP_STAGE="$stage" "$script"; then
    echo "  ! ${stack}: backup.sh failed" >&2
    failed+=("$stack")
    degraded=1
  fi

  # A stack script that died partway may still have declared paths before it
  # did — every infra/<stack>/backup.sh puts its file includes BEFORE the
  # database dump for exactly this reason. Snapshot what it managed to declare.
  #
  # A DEGRADED snapshot — files present, dump missing — is worth far more than
  # no snapshot at all: it still carries data/, certs/ and the .env holding
  # AUTHENTIK_SECRET_KEY, none of which need the database, and it is the one
  # situation the raw PGDATA in the include list exists for. The stack stays in
  # `failed` either way, so the run still exits non-zero and still says nothing
  # to Kuma. A degraded snapshot must never read as a good night.
  if [ ! -s "${stage}/paths.txt" ]; then
    echo "  ! ${stack}: no paths declared — nothing to snapshot" >&2
    [ "$degraded" -eq 1 ] || failed+=("$stack")
    continue
  fi

  if [ "$degraded" -eq 1 ]; then
    echo "  ! ${stack}: snapshotting DEGRADED — the paths declared before the failure" >&2
  fi

  echo "==> ${stack}: snapshot"
  if ! restic backup --tag "$stack" --files-from "${stage}/paths.txt"; then
    echo "  ! ${stack}: restic backup failed" >&2
    # Guard: already counted above if the stack script failed too, and one
    # stack must appear in the FAILED line once.
    [ "$degraded" -eq 1 ] || failed+=("$stack")
    continue
  fi
done

# Retention runs once, over the whole repository.
#
# --group-by host,tags is NOT optional. restic applies the policy per group, and
# its default grouping is host,paths — so --keep-daily 7 across several stacks
# in one repository would be decided by a grouping that silently re-partitions
# the moment a stack's backup.sh gains or loses an include. Grouping by tag
# makes the policy mean "seven dailies of Authentik", which is how it reads.
# `host` is in there because the apps VM joins this same repository later.
echo "==> forget + prune"
if ! restic forget --group-by host,tags \
       --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; then
  echo "  ! forget/prune failed" >&2
  failed+=("forget")
fi

if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi

# Only a fully clean run reports success, and the deadman does the rest: Kuma
# goes red when the heartbeat does not arrive. A partial success must therefore
# look like a failure rather than a green tick. Same shape as the hypervisor's
# zfs-health-push.sh — see proxmox-setup.md Part 9.
if [ -n "${KUMA_PUSH_URL:-}" ]; then
  curl -fsS --max-time 10 --get "$KUMA_PUSH_URL" \
    --data-urlencode "status=up" \
    --data-urlencode "msg=${#stacks[@]} stacks: ${stacks[*]}" >/dev/null \
    || echo "  ! Kuma push failed (the backup itself succeeded)" >&2
fi

echo "OK: ${stacks[*]}"
