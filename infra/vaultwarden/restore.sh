#!/usr/bin/env bash
#
# restore.sh — put Vaultwarden back from a restic snapshot.
#
# Usage:  sudo infra/vaultwarden/restore.sh [snapshot-id]     (default: latest)
#
# THE TRAP THIS EXISTS TO AVOID: Postgres keeps the password its data directory
# was FIRST INITIALISED with. Restoring this stack's .env next to a
# /opt/vaultwarden/postgres initialised with a different VAULTWARDEN_DB_PASSWORD
# leaves a stack that cannot log into its own database — a failure that presents
# as a corrupt backup and is not one. So postgres/ is left EMPTY, the container
# initialises a fresh cluster from the restored .env, and the dump loads into it.
#
# THE SECOND TRAP IS SPECIFIC TO THIS STACK: `rsa_key.pem` under data/ signs
# every access token the server issues, and the database holds what those tokens
# address. Restoring one without the other gives you a working server, an intact
# vault, and every client logged out with no way to prove anything. Both come
# from the same snapshot here, which is the point — but it is also why a partial
# hand-restore of this stack is a bad idea: take the whole snapshot or none of it.

set -euo pipefail

STACK="vaultwarden"
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
# needs to know where their data went — and for this stack, that data is the
# only copy of everything else's credentials.
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
echo "THIS IS THE VAULT. Anything added to it since that snapshot — a new"
echo "login, a changed password, an attachment — is not in this backup and"
echo "will be gone. The old tree is kept, not deleted, but read that sentence"
echo "again before continuing."
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
  "${STAGE}/opt/${STACK}/data" \
  "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" \
  "$dump"
do
  if [ ! -e "$src" ]; then
    echo "  ! missing from the snapshot: ${src}" >&2
    missing=1
  fi
done

# Named separately because losing it is the failure this stack's whole backup
# shape exists to prevent, and "data/ exists" does not imply it is in there.
if [ ! -f "${STAGE}/opt/${STACK}/data/rsa_key.pem" ]; then
  echo "  ! missing from the snapshot: data/rsa_key.pem" >&2
  echo "    Without it every client is logged out of the restored vault." >&2
  missing=1
fi

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
  fi

  if [ ! -e "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" ]; then
    echo >&2
    echo "The .env is missing, which usually means the checkout moved: the" >&2
    echo "snapshot stores it under the ABSOLUTE path it had when it was taken," >&2
    echo "and this script looks for it under ${REPO_ROOT}. Copy it out of the" >&2
    echo "staged tree by hand — and copy it, do not retype it: the Argon2id" >&2
    echo "ADMIN_TOKEN inside must keep its single quotes intact." >&2
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

echo "==> Restoring files"
mkdir -p "/opt/${STACK}"
cp -a "${STAGE}/opt/${STACK}/data" "/opt/${STACK}/data"

# EMPTY on purpose — see the header. Postgres initialises into it using the
# password from the .env restored on the next line. No chown: the postgres
# image handles its own PGDATA ownership.
mkdir -p "/opt/${STACK}/postgres"

# cp, never an edit: the Argon2id ADMIN_TOKEN in here is single-quoted, and
# every `$`-segment of it has to survive byte-for-byte.
echo "==> Restoring ${REPO_ROOT}/infra/${STACK}/.env"
cp -a "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" "${REPO_ROOT}/infra/${STACK}/.env"

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
# and the script prints its success message over a half-restored vault.
echo "==> Loading ${dump}"
( cd "${REPO_ROOT}/infra/${STACK}" \
  && docker compose exec -T db \
       psql -v ON_ERROR_STOP=1 -U "${STACK}" -d "${STACK}" ) < "$dump"

# ---- 9. Bring the rest up --------------------------------------------------

echo "==> Starting the rest of the stack"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify, in this order — the first check is the one that matters:

  1. LOG IN FROM A CLIENT THAT WAS ALREADY PAIRED before the restore — a
     browser extension or phone app you have not re-authenticated. If it
     works, rsa_key.pem and the database came back TOGETHER. If it demands a
     fresh login, they did not, and this restore is not the success it looks
     like from a browser.
  2. https://vault.thefipster.de accepts your master password, and your items
     are there — including any attachment, which is the half of the vault that
     lives in data/ rather than in the database.
  3. https://vault.thefipster.de/admin accepts the ADMIN_TOKEN. That proves
     the Argon2id string in .env survived byte-for-byte; if it is rejected,
     the .env was retyped rather than restored somewhere along the line.
  4. Any setting you changed through /admin is still as you left it — those
     live in data/config.json, not in the database, and not in the compose.

Two trees are left behind on purpose. Delete them once the checks above
pass — not before, because the first one is your way back:

  the previous live tree
    sudo rm -rf /opt/${STACK}.bak-${ts}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}

Both hold a complete decrypted copy of the vault's data directory. They are
mode 700 under root, but they are also the reason not to leave them lying
around indefinitely.
EOF
