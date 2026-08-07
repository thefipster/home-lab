#!/usr/bin/env bash
#
# restore.sh — put Uptime Kuma back from a restic snapshot.
#
# Usage:  sudo infra/uptime-kuma/restore.sh [snapshot-id]     (default: latest)
#
# THE TRAP THIS EXISTS TO AVOID is the SQLite twin of the Postgres one. The
# snapshot carries the live kuma.db beside its -wal and -shm, and putting those
# back is the obvious move and the wrong one: they were copied from a running
# database, so they are torn by construction. Here that is not theoretical —
# the write-ahead log is routinely LARGER than the .db file, so most of the
# committed state lives in a file whose copy is mid-write.
#
# So this script restores everything in the data directory EXCEPT the kuma.db
# triplet, and rebuilds the database from the SQL dump instead — the same
# discipline as leaving postgres/ empty in the Postgres stacks. The raw copy in
# the snapshot is never restored automatically; it is the last resort for when
# no dump exists.

set -euo pipefail

STACK="uptime-kuma"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE="/opt/backup/restore/${STACK}"
SNAPSHOT="${1:-latest}"
dump="${STAGE}/opt/backup/dumps/${STACK}/${STACK}.sql"

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it moves /opt trees around." >&2
  exit 1
fi

# Set the moment the live tree is renamed, and printed by the trap below on any
# non-zero exit. An operator whose restore just died mid-way is the one who
# needs to know where their data went.
BACKED_UP_TO=""

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$BACKED_UP_TO" ]; then
    echo >&2
    echo "!! This restore FAILED after moving the live tree aside." >&2
    echo "!! Your previous /opt/${STACK} is at ${BACKED_UP_TO}." >&2
    echo "!! It was not deleted. Nothing is lost — put it back with:" >&2
    echo "!!   rm -rf /opt/${STACK} && mv ${BACKED_UP_TO} /opt/${STACK}" >&2
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

# `restic snapshots` does not accept the pseudo-id `latest` the way `restore`
# does, so resolve it here rather than passing it through.
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
echo "This stops the stack and moves /opt/${STACK} aside."
echo
echo "NOTE: Kuma is the watcher. While it is down nothing is monitoring the"
echo "lab, and any push monitor that would have gone red stays silent."
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

# ---- 4. Check the staged tree BEFORE touching anything live ----------------

# Everything below this point is destructive. Check the sources here, while the
# stack is merely stopped and /opt/<stack> is still where it belongs.
#
# THE DUMP IS IN THIS LIST on purpose. A dump-less snapshot is not a corrupt
# one — infra/backup/run.sh produces a DEGRADED snapshot deliberately when a
# dump fails — and the documented next move operates on /opt/<stack> as it
# stands, so this script must not have moved it by the time it finds out.
echo "==> Checking the staged snapshot is complete"
missing=0
for src in "${STAGE}/opt/${STACK}" "$dump"; do
  if [ ! -e "$src" ]; then
    echo "  ! missing from the snapshot: ${src}" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo >&2
  echo "Aborting BEFORE anything was moved — /opt/${STACK} is untouched and the" >&2
  echo "stack is only stopped. Bring it back up with:" >&2
  echo "  cd ${REPO_ROOT}/infra/${STACK} && docker compose up -d" >&2
  echo >&2
  echo "Then look at what the snapshot does contain:" >&2
  echo "  ls -R ${STAGE}" >&2

  if [ ! -f "$dump" ]; then
    echo >&2
    echo "THE SQL DUMP IS THE MISSING ONE. That is a DEGRADED snapshot: a night" >&2
    echo "when the dump failed and the runner snapshotted the files anyway. It" >&2
    echo "stops here BY DESIGN, with /opt/${STACK} untouched, because the next" >&2
    echo "move needs it that way — the staged tree still holds the torn kuma.db" >&2
    echo "triplet, and putting that back by hand is the last resort described in" >&2
    echo "docs/backup-setup.md. Do not undo anything first." >&2
  fi

  exit 1
fi

# ---- 5. Move the live tree aside — never delete it -------------------------

ts="$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/${STACK}" ]; then
  echo "==> Moving /opt/${STACK} to /opt/${STACK}.bak-${ts}"
  mv "/opt/${STACK}" "/opt/${STACK}.bak-${ts}"
  BACKED_UP_TO="/opt/${STACK}.bak-${ts}"
fi

# ---- 6. Put the files back, MINUS the database ------------------------------

echo "==> Restoring the data directory"
mkdir -p "/opt/${STACK}"
cp -a "${STAGE}/opt/${STACK}/." "/opt/${STACK}/"

# Copy everything, then drop the database triplet — rather than listing what to
# keep. Kuma's data directory gains files across versions (db-config.json did
# not exist in 1.x), and a keep-list would silently stop restoring whatever is
# added next. A drop-list only has to know about the thing this script rebuilds.
echo "==> Removing the torn database copy — the dump is the restore path"
rm -f "/opt/${STACK}/kuma.db" \
      "/opt/${STACK}/kuma.db-wal" \
      "/opt/${STACK}/kuma.db-shm"

# ---- 7. Rebuild the database from the dump ---------------------------------

# Through the stack's OWN image, with the app never starting: `--entrypoint
# sqlite3` replaces Kuma with the sqlite3 binary that ships beside it, and
# `--rm` throws the container away afterwards. Two things fall out of doing it
# this way rather than from the host — the client always matches the file
# format it is writing, and the new kuma.db lands owned by the UID Kuma itself
# runs as, because it is that image writing it. A file created by root here
# would be a database Kuma may not be able to write to.
echo "==> Rebuilding kuma.db from ${dump}"
( cd "${REPO_ROOT}/infra/${STACK}" \
  && docker compose run --rm --no-deps -T \
       --entrypoint sqlite3 "${STACK}" /app/data/kuma.db ) < "$dump"

# ---- 8. Bring it up --------------------------------------------------------

echo "==> Starting ${STACK}"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify, in this order:

  1. https://uptime.thefipster.de loads and your admin login works — the
     password hash lives in the database you just rebuilt, so this is the
     first thing that proves the dump loaded.
  2. Every monitor from docs/uptime-kuma-monitors.md is present, and the
     groups are intact.
  3. The ntfy notification is still attached — open any monitor and check it
     is ticked, since notification bindings are per-monitor rows.
  4. Heartbeat history is there (the bars on the dashboard). It is the
     bulkiest thing in the database and the clearest sign the whole dump
     loaded rather than just the schema.
  5. The push monitors — the backup job and the hypervisor's ZFS health —
     will read as down until their next push arrives. That is expected: they
     are waiting to be told, and nothing pushes on demand.

Two trees are left behind on purpose. Delete them once the checks above
pass — not before, because the first one is your way back:

  the previous live tree
    sudo rm -rf /opt/${STACK}.bak-${ts}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}

To see what is there before removing anything:

  sudo du -sh /opt/${STACK}.bak-* ${STAGE} 2>/dev/null
EOF
