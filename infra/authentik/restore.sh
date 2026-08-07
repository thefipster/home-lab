#!/usr/bin/env bash
#
# restore.sh — put Authentik back from a restic snapshot.
#
# Usage:  sudo infra/authentik/restore.sh [snapshot-id]     (default: latest)
#
# THE TRAP THIS EXISTS TO AVOID: Postgres keeps the password its data directory
# was FIRST INITIALISED with. Restoring Authentik's .env next to a
# /opt/authentik/postgres that was initialised with a different PG_PASS leaves a
# stack that cannot log into its own database — a failure that presents as a
# corrupt backup and is not one.
#
# So this script restores data/, templates/, certs/ and .env, and leaves
# postgres/ EMPTY: the container initialises a fresh cluster from the restored
# .env, and the dump then loads into it. The raw PGDATA in the snapshot is never
# restored automatically — it is the last resort for when no dump exists, and
# docs/backup-setup.md says how to use it by hand.

set -euo pipefail

STACK="authentik"
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
# non-zero exit. The "your old data is at ..." line used to live only in the
# success heredoc at the very bottom — which is the one path where nobody needs
# it. An operator whose restore just died mid-way is the one who does.
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
# does, so resolve it here rather than passing it through. grep instead of jq:
# one less thing to install on a machine you are restoring.
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

# Everything below this point is destructive, and every one of these sources is
# consumed unconditionally once it starts. Check them ALL here, while the stack
# is merely stopped and /opt/<stack> is still where it belongs.
#
# THE DUMP IS IN THIS LIST, and it is the reason the list is checked rather than
# discovered. A dump-less snapshot is not a corrupt snapshot — infra/backup/
# run.sh produces one deliberately when pg_dump fails (a DEGRADED snapshot),
# and docs/backup-setup.md's raw-PGDATA procedure is the documented next move.
# That procedure operates on /opt/<stack>, so this script must not have moved
# it. Checked after the rename instead, the operator would be told the restore
# failed and handed a command to undo the very tree the guide's next step needs.
echo "==> Checking the staged snapshot is complete"
missing=0
for src in \
  "${STAGE}/opt/${STACK}/data" \
  "${STAGE}/opt/${STACK}/templates" \
  "${STAGE}/opt/${STACK}/certs" \
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
    echo "when pg_dump failed and the runner snapshotted the files anyway. There" >&2
    echo "is nothing to load, so this script stops here BY DESIGN — and it stops" >&2
    echo "with /opt/${STACK} untouched, because the next move needs it that way." >&2
    echo >&2
    echo "That next move is 'Last resort: the raw PGDATA' in" >&2
    echo "docs/backup-setup.md. Its steps operate on /opt/${STACK} exactly as it" >&2
    echo "stands right now. Do not undo anything first." >&2
  fi

  if [ ! -e "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" ]; then
    echo >&2
    echo "The .env is missing, which usually means the checkout moved: the" >&2
    echo "snapshot stores it under the ABSOLUTE path it had when it was taken," >&2
    echo "and this script looks for it under ${REPO_ROOT}. Copy it out of the" >&2
    echo "staged tree by hand." >&2
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
cp -a "${STAGE}/opt/${STACK}/data"      "/opt/${STACK}/data"
cp -a "${STAGE}/opt/${STACK}/templates" "/opt/${STACK}/templates"
cp -a "${STAGE}/opt/${STACK}/certs"     "/opt/${STACK}/certs"

# EMPTY on purpose — see the header. Postgres initialises into it using the
# password from the .env restored on the next line.
mkdir -p "/opt/${STACK}/postgres"

echo "==> Restoring ${REPO_ROOT}/infra/${STACK}/.env"
cp -a "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" "${REPO_ROOT}/infra/${STACK}/.env"

# ---- 7. Bring the database up, alone ---------------------------------------

echo "==> Starting the database"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d db )

# PG_ISREADY IS NOT ENOUGH ON A FRESH CLUSTER, and this script always creates
# one (postgres/ is left empty on purpose — see the header). The official
# entrypoint runs `initdb`, then starts a TEMPORARY server to create the role
# and database — `docker_temp_server_start` passes `-c listen_addresses=''`, so
# it is reachable on the unix socket, which is exactly where `pg_isready` looks
# when it runs inside the container. It answers "ready", the loop breaks, the
# dump starts streaming, and then `docker_temp_server_stop` (`pg_ctl -m fast`)
# cuts it off mid-load.
#
# So gate on the entrypoint's own marker first: it prints one of these two
# lines AFTER the temporary server is stopped and immediately before it execs
# the real one. Only then is pg_isready answering for the server that stays.
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

# Falling out of the loop used to be silent, and the operator's first hint was
# a raw psql connection error two lines later.
if [ "$ready" -ne 1 ]; then
  echo
  echo "Postgres never became ready — gave up after 60 checks. NOTHING has" >&2
  echo "been loaded. The restored files are in place, and your previous tree" >&2
  echo "was moved aside intact, not modified — its path is printed below." >&2
  echo "Read the database's log — a wrong password against a non-empty PGDATA" >&2
  echo "and a failed initdb both show up here:" >&2
  echo "  cd ${REPO_ROOT}/infra/${STACK} && docker compose logs db" >&2
  exit 1
fi

# ---- 8. Load the dump ------------------------------------------------------

# No existence check here: section 4 already refused to start without the dump,
# and it did so while /opt/<stack> was still untouched. A second check at this
# point could only fire after the rename, which is exactly the wrong side of it.
#
# -v ON_ERROR_STOP=1 is what makes `set -e` mean anything here. psql's exit
# status ignores SQL errors by default, so a dump that only half applied still
# exits 0 and this script would print its success message over a half-restored
# Authentik. With it, the first failing statement stops the load and fails.
echo "==> Loading ${dump}"
( cd "${REPO_ROOT}/infra/${STACK}" \
  && docker compose exec -T db \
       psql -v ON_ERROR_STOP=1 -U "${STACK}" -d "${STACK}" ) < "$dump"

# ---- 9. Bring the rest up --------------------------------------------------

echo "==> Starting the rest of the stack"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify, in this order:

  1. https://auth.thefipster.de loads and you can log in.
  2. Applications and Providers are all present (docs/sso-applications.md).
  3. https://dockge.thefipster.de redirects through Authentik and back —
     that is the forward-auth middleware working, which proves the outpost
     and its token survived.
  4. Grafana's "Sign in with Authentik" button completes a login — that is
     OIDC, the other pattern.

The previous tree is at /opt/${STACK}.bak-${ts}. Delete it once you are
satisfied, not before.
EOF
