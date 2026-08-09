#!/usr/bin/env bash
#
# restore.sh — put Homepage's widget credentials back from a restic snapshot.
#
# Usage:  sudo infra/homepage/restore.sh [snapshot-id]     (default: latest)
#
# The shortest restore in the lab: one file, no database, and no /opt tree to
# move aside because this stack has none.
#
# THE TRAP HERE IS THE SAME ONE TRAEFIK HAS. Homepage comes back looking
# perfectly healthy whether or not this restore worked — the page renders, every
# tile is there, and container state is live — because none of that came from
# the snapshot. The ONLY thing this restore delivers is the widget credentials,
# so the only check that means anything is whether the Authentik, Forgejo and
# Grafana tiles show FIGURES.

set -euo pipefail

STACK="homepage"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE="/opt/backup/restore/${STACK}"
SNAPSHOT="${1:-latest}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it reads /opt/backup and the restic repository." >&2
  exit 1
fi

BACKED_UP_TO=""

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$BACKED_UP_TO" ]; then
    echo >&2
    echo "!! This restore FAILED after moving the old .env aside." >&2
    echo "!! It is at ${BACKED_UP_TO} and was not deleted. Put it back with:" >&2
    echo "!!   mv ${BACKED_UP_TO} ${REPO_ROOT}/infra/${STACK}/.env" >&2
    echo "!! Then start the stack: cd ${REPO_ROOT}/infra/${STACK} && docker compose up -d" >&2
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
echo "This stops the stack and REPLACES ${REPO_ROOT}/infra/${STACK}/.env."
echo
echo "NOTE: while Homepage is down nothing else is affected — it is a page of"
echo "links, and no other stack depends on it."
echo
read -r -p "Type '${STACK}' to continue: " answer
if [ "$answer" != "$STACK" ]; then
  echo "aborted."
  exit 1
fi

# ---- 2. Stop the stack -----------------------------------------------------

echo "==> Stopping ${STACK}"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose down )

# ---- 3. Restore into staging, before touching anything live ----------------

echo "==> Restoring snapshot ${id} into ${STAGE}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
restic restore "$id" --target "$STAGE"

# ---- 4. Check the staged file BEFORE touching anything live ----------------

staged_env="${STAGE}${REPO_ROOT}/infra/${STACK}/.env"

if [ ! -s "$staged_env" ]; then
  echo "  ! the snapshot's .env is missing or EMPTY: ${staged_env}" >&2
  echo >&2
  echo "Aborting BEFORE anything was moved — the checkout is untouched and the" >&2
  echo "stack is only stopped. Bring it back up with:" >&2
  echo "  cd ${REPO_ROOT}/infra/${STACK} && docker compose up -d" >&2
  echo >&2
  echo "Then look at what the snapshot does contain:" >&2
  echo "  ls -R ${STAGE}" >&2
  exit 1
fi

# A .env still holding .env.example's placeholders restores "successfully" and
# then fails every widget with a 401, which reads as a credential problem rather
# than as a bad backup. Catch it here, while the live file is still in place.
if grep -q '=changeme$' "$staged_env"; then
  echo "  ! the snapshot's .env still holds 'changeme' placeholders." >&2
  echo "    It was taken before the credentials were filled in, so restoring" >&2
  echo "    it would replace working credentials with placeholders." >&2
  echo >&2
  echo "Aborting BEFORE anything was moved. Pick a different snapshot:" >&2
  echo "  restic snapshots --tag ${STACK}" >&2
  exit 1
fi

# ---- 5. Move the old .env aside — never delete it --------------------------

ts="$(date +%Y%m%d-%H%M%S)"
live_env="${REPO_ROOT}/infra/${STACK}/.env"
if [ -f "$live_env" ]; then
  echo "==> Moving ${live_env} to ${live_env}.bak-${ts}"
  mv "$live_env" "${live_env}.bak-${ts}"
  BACKED_UP_TO="${live_env}.bak-${ts}"
fi

# ---- 6. Put it back --------------------------------------------------------

echo "==> Restoring ${live_env}"
cp -a "$staged_env" "$live_env"

# ---- 7. Bring it up --------------------------------------------------------

echo "==> Starting ${STACK}"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify — and note that only the FIRST check tests this restore at all:

  1. The Authentik, Forgejo and Grafana tiles show FIGURES, not just a status
     dot. That is the only thing that came out of the snapshot.

       https://home.thefipster.de

  2. The stack started at all. A guard failure here means the restored .env is
     missing a variable that compose.yaml requires:

       cd ${REPO_ROOT}/infra/${STACK} && docker compose ps

  3. Everything else — the page, the links, container state on every tile —
     would look exactly like this even if the restore had done nothing, because
     it all comes from the checkout rather than from the backup.

Two things are left behind on purpose. Delete them once the checks pass:

  the previous .env
    sudo rm -f ${BACKED_UP_TO:-${live_env}.bak-${ts}}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}
EOF
