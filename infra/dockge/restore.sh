#!/usr/bin/env bash
#
# restore.sh — put Dockge's own state back from a restic snapshot.
#
# Usage:  sudo infra/dockge/restore.sh [snapshot-id]     (default: latest)
#
# NARROW BY NECESSITY, and for a different reason than monitoring's. Dockge is
# the one stack that is COPIED into /opt/stacks rather than symlinked, so
# /opt/stacks/dockge holds three things:
#
#   data/         Dockge's accounts — the only thing in the snapshot
#   compose.yaml  a copy of infra/dockge/compose.yaml, written by init-dockge.sh
#   .env          REPO_DIR=…, also written by init-dockge.sh
#
# The last two are regenerated from the checkout and are NOT in the backup, so
# moving the whole directory aside the way most restore scripts do would delete
# the compose file this stack is started from. This one touches data/ alone.
#
# There is no database, so there is nothing to re-initialise: stop, swap the
# directory, start.

set -euo pipefail

STACK="dockge"
STACK_DIR="/opt/stacks/dockge"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE="/opt/backup/restore/${STACK}"
SNAPSHOT="${1:-latest}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it moves /opt trees around." >&2
  exit 1
fi

BACKED_UP_TO=""

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$BACKED_UP_TO" ]; then
    echo >&2
    echo "!! This restore FAILED after moving Dockge's data aside." >&2
    echo "!! Your previous data/ is at ${BACKED_UP_TO}." >&2
    echo "!! It was not deleted. Nothing is lost — put it back with:" >&2
    echo "!!   rm -rf ${STACK_DIR}/data && mv ${BACKED_UP_TO} ${STACK_DIR}/data" >&2
    echo "!! Then start Dockge: cd ${STACK_DIR} && docker compose up -d" >&2
  fi
}
trap on_exit EXIT

set -a
# shellcheck source=/dev/null
. "${REPO_ROOT}/infra/backup/.env"
set +a

# ---- 1. Resolve the snapshot and show it -----------------------------------

echo "==> Snapshots tagged ${STACK}:"
restic snapshots --tag "$STACK" --compact

if [ "$SNAPSHOT" = "latest" ]; then
  id="$(restic snapshots --tag "$STACK" --latest 1 --json \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4)"
else
  id="$SNAPSHOT"
fi

if [ -z "$id" ]; then
  echo "no snapshot '${SNAPSHOT}' tagged ${STACK} found." >&2
  exit 1
fi

echo
echo "About to restore ${STACK} from snapshot ${id}."
echo "This stops Dockge and moves ${STACK_DIR}/data aside."
echo
echo "Its compose.yaml and .env in that directory are NOT touched: they are"
echo "written by scripts/init-dockge.sh from the checkout, not backed up."
echo
read -r -p "Type '${STACK}' to continue: " answer
if [ "$answer" != "$STACK" ]; then
  echo "aborted."
  exit 1
fi

# ---- 2. Stop the stack -----------------------------------------------------

# Dockge is started from its copied compose in /opt/stacks/dockge, not from the
# checkout — the one stack where those are different directories.
echo "==> Stopping ${STACK}"
( cd "${STACK_DIR}" && docker compose down )

# ---- 3. Restore into staging, before touching anything live ----------------

echo "==> Restoring snapshot ${id} into ${STAGE}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
restic restore "$id" --target "$STAGE"

# ---- 4. Check the staged tree BEFORE touching anything live ----------------

echo "==> Checking the staged snapshot is complete"
if [ ! -d "${STAGE}${STACK_DIR}/data" ]; then
  echo "  ! missing from the snapshot: ${STAGE}${STACK_DIR}/data" >&2
  echo >&2
  echo "Aborting BEFORE anything was moved — ${STACK_DIR} is untouched and" >&2
  echo "Dockge is only stopped. Bring it back up with:" >&2
  echo "  cd ${STACK_DIR} && docker compose up -d" >&2
  echo >&2
  echo "Then look at what the snapshot does contain:" >&2
  echo "  ls -R ${STAGE}" >&2
  exit 1
fi

# ---- 5. Move the old data aside — never delete it --------------------------

ts="$(date +%Y%m%d-%H%M%S)"
if [ -d "${STACK_DIR}/data" ]; then
  echo "==> Moving ${STACK_DIR}/data to ${STACK_DIR}/data.bak-${ts}"
  mv "${STACK_DIR}/data" "${STACK_DIR}/data.bak-${ts}"
  BACKED_UP_TO="${STACK_DIR}/data.bak-${ts}"
fi

# ---- 6. Put it back --------------------------------------------------------

echo "==> Restoring ${STACK_DIR}/data"
cp -a "${STAGE}${STACK_DIR}/data" "${STACK_DIR}/data"

# ---- 7. Bring it up --------------------------------------------------------

echo "==> Starting ${STACK}"
( cd "${STACK_DIR}" && docker compose up -d )

cat <<EOF

Done. Verify:

  1. https://dockge.thefipster.de loads. It is behind Authentik's forward-auth,
     so this also needs Authentik up — a failure here may be Authentik's, not
     Dockge's.
  2. Your Dockge account still logs in. Accounts live in data/, so this is the
     one check that actually tests this restore.
  3. Every stack is listed and its state is right. That is read from
     /opt/stacks at runtime, NOT from the snapshot — it would look identical
     if this restore had done nothing, so it confirms Dockge started rather
     than that the backup worked.
  4. ${STACK_DIR}/compose.yaml and .env are still there. This script never
     touches them, but confirming it once is worth more than trusting it.

Two things are left behind on purpose. Delete them once the checks pass:

  the previous data directory
    sudo rm -rf ${BACKED_UP_TO:-${STACK_DIR}/data.bak-${ts}}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}
EOF
