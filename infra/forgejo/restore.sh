#!/usr/bin/env bash
#
# restore.sh — put Forgejo back from a restic snapshot.
#
# Usage:  sudo infra/forgejo/restore.sh [snapshot-id]     (default: latest)
#
# THE TRAP THIS EXISTS TO AVOID: Postgres keeps the password its data directory
# was FIRST INITIALISED with. Restoring this stack's .env next to a
# /opt/forgejo/postgres initialised with a different FORGEJO_DB_PASSWORD leaves
# a stack that cannot log into its own database — a failure that presents as a
# corrupt backup and is not one. So postgres/ is left EMPTY, the container
# initialises a fresh cluster from the restored .env, and the dump loads into it.
#
# THE SECOND TRAP IS SPECIFIC TO THIS STACK, and it is quiet: the
# container-registry BLOBS live under forgejo/ while their package METADATA
# lives in the database. Restore one without the other and the registry either
# lists images it cannot serve or holds blobs nothing can address. Both come
# from the same snapshot here, which is the point — do not hand-restore half of
# this stack.

set -euo pipefail

STACK="forgejo"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE="/opt/backup/restore/${STACK}"
SNAPSHOT="${1:-latest}"
dump="${STAGE}/opt/backup/dumps/${STACK}/${STACK}.sql"

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it moves /opt trees around." >&2
  exit 1
fi

# Set the moment the live tree is renamed, and printed by the trap on any
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
echo "This stops the stack, moves /opt/${STACK} aside, and REPLACES"
echo "${REPO_ROOT}/infra/${STACK}/.env."
echo
echo "This is the largest snapshot in the repository — the registry blobs are"
echo "in it — so the staged copy below needs room for a second copy of them."
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

# Everything below this point is destructive, and every source here is consumed
# unconditionally once it starts. Check them ALL now, while the stack is merely
# stopped and /opt/<stack> is still where it belongs.
#
# THE DUMP IS IN THIS LIST on purpose. A dump-less snapshot is not a corrupt one
# — infra/backup/run.sh produces a DEGRADED snapshot deliberately when pg_dump
# fails — and the documented next move operates on /opt/<stack> as it stands, so
# this script must not have moved it by the time it finds out.
echo "==> Checking the staged snapshot is complete"
missing=0
for src in \
  "${STAGE}/opt/${STACK}/${STACK}" \
  "${STAGE}/opt/${STACK}/runner" \
  "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" \
  "$dump"
do
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
    echo "when pg_dump failed and the runner snapshotted the files anyway. It" >&2
    echo "stops here BY DESIGN, with /opt/${STACK} untouched, because the next" >&2
    echo "move needs it that way — 'Last resort: the raw PGDATA' in" >&2
    echo "docs/backup-setup.md. Do not undo anything first." >&2
    echo >&2
    echo "Note for THIS stack: the registry blobs under forgejo/ are intact in" >&2
    echo "that snapshot; it is only their package metadata that is missing." >&2
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

# ---- 6. Put the files back -------------------------------------------------

# cp -a preserves ownership, which matters here: Forgejo and its runner both run
# as UID/GID 1000 (USER_UID/USER_GID in the compose), and restic stored those
# ids. scripts/init-forgejo.sh chowns them on a fresh build; a restore must not
# undo that by writing the tree as root.
echo "==> Restoring files"
mkdir -p "/opt/${STACK}"
cp -a "${STAGE}/opt/${STACK}/${STACK}" "/opt/${STACK}/${STACK}"
cp -a "${STAGE}/opt/${STACK}/runner"   "/opt/${STACK}/runner"

# EMPTY on purpose — see the header. Postgres initialises into it using the
# password from the .env restored on the next line. No chown: the postgres
# image handles its own PGDATA ownership.
mkdir -p "/opt/${STACK}/postgres"

echo "==> Restoring ${REPO_ROOT}/infra/${STACK}/.env"
cp -a "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" "${REPO_ROOT}/infra/${STACK}/.env"

# DOCKER_GID is machine-specific, not secret. On a rebuilt VM the docker group
# can land on a different gid than the snapshot recorded, and the only symptom
# is a runner that cannot reach the socket — the web UI, git and the registry
# all work perfectly, so nothing else in the verification below would catch it.
restored_gid="$(grep -E '^DOCKER_GID=' "${REPO_ROOT}/infra/${STACK}/.env" | cut -d= -f2 || true)"
live_gid="$(getent group docker | cut -d: -f3 || true)"
if [ -n "$live_gid" ] && [ -n "$restored_gid" ] && [ "$restored_gid" != "$live_gid" ]; then
  echo
  echo "  ! DOCKER_GID in the restored .env is ${restored_gid}, but the docker" >&2
  echo "  ! group on THIS machine is ${live_gid}. The runner will start and be" >&2
  echo "  ! unable to reach the Docker socket; nothing else will look wrong." >&2
  echo "  ! Fix it before relying on CI:" >&2
  echo "  !   sed -i 's/^DOCKER_GID=.*/DOCKER_GID=${live_gid}/' ${REPO_ROOT}/infra/${STACK}/.env" >&2
  echo
fi

# ---- 7. Bring the database up, alone ---------------------------------------

echo "==> Starting the database"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d db )

# PG_ISREADY IS NOT ENOUGH ON A FRESH CLUSTER, and this script always creates
# one. The official entrypoint runs `initdb`, then starts a TEMPORARY server to
# create the role and database — `docker_temp_server_start` passes
# `-c listen_addresses=''`, so it is reachable on the unix socket, which is
# exactly where `pg_isready` looks when it runs inside the container. It answers
# "ready", the loop breaks, the dump starts streaming, and then
# `docker_temp_server_stop` (`pg_ctl -m fast`) cuts it off mid-load.
#
# So gate on the entrypoint's own marker first: it prints one of these two lines
# AFTER the temporary server is stopped and immediately before it execs the real
# one. Only then is pg_isready answering for the server that stays.
ready=0
echo -n "==> Waiting for Postgres"
for _ in $(seq 1 60); do
  # Into a variable and matched with [[ == ]], not piped into grep: `grep -q`
  # exits on the first match and would SIGPIPE `docker compose logs`, which
  # under `set -o pipefail` turns a successful match into a failed pipeline.
  logs="$( cd "${REPO_ROOT}/infra/${STACK}" && docker compose logs db 2>&1 )" || logs=""

  if [[ "$logs" == *"init process complete"* \
     || "$logs" == *"Skipping initialization"* ]]; then
    if ( cd "${REPO_ROOT}/infra/${STACK}" \
         && docker compose exec -T db pg_isready -U "${STACK}" >/dev/null 2>&1 ); then
      ready=1
      echo " ready"
      break
    fi
  fi
  echo -n "."
  sleep 2
done

if [ "$ready" -ne 1 ]; then
  echo
  echo "Postgres never became ready — gave up after 60 checks. NOTHING has" >&2
  echo "been loaded. The restored files are in place, and your previous tree" >&2
  echo "was moved aside intact, not modified — its path is printed below." >&2
  echo "Read the database's log; a wrong password against a non-empty PGDATA" >&2
  echo "and a failed initdb both show up there:" >&2
  echo "  cd ${REPO_ROOT}/infra/${STACK} && docker compose logs db" >&2
  exit 1
fi

# ---- 8. Load the dump ------------------------------------------------------

# -v ON_ERROR_STOP=1 because psql's exit status IGNORES SQL errors by default:
# without it a dump that only half-applies still exits 0, `set -e` sees nothing,
# and the script prints its success message over a half-restored Forgejo.
echo "==> Loading ${dump}"
( cd "${REPO_ROOT}/infra/${STACK}" \
  && docker compose exec -T db \
       psql -v ON_ERROR_STOP=1 -U "${STACK}" -d "${STACK}" ) < "$dump"

# ---- 9. Bring the rest up --------------------------------------------------

echo "==> Starting the rest of the stack"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify, in this order — each one proves something the previous did not:

  1. https://git.thefipster.de loads and your local admin login works. That
     account is in the database you just restored.
  2. "Sign in with Authentik" completes — the OIDC source is a database row,
     and its client secret is one of the things a half-restore would lose.
  3. Clone a repository over HTTPS.
  4. Clone one over SSH, from a machine that has pushed before. No
     "REMOTE HOST IDENTIFICATION HAS CHANGED" warning means the SSH host keys
     under forgejo/ came back — a fresh machine would not notice either way.
  5. \`docker pull\` an image from the registry. THIS is the check unique to
     this stack: the blobs live in the files and their metadata lives in the
     database, so a successful pull is the only thing that proves the two
     halves came from the same snapshot.
  6. Actions → Runners shows the runner ONLINE. That proves .runner survived
     — and if a DOCKER_GID warning printed above, fix it first or this will
     be the one thing that stays broken.

Two trees are left behind on purpose. Delete them once the checks above
pass — not before, because the first one is your way back. This stack's are
the biggest in the lab:

  the previous live tree
    sudo rm -rf /opt/${STACK}.bak-${ts}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}
EOF
