#!/usr/bin/env bash
#
# restore.sh — put the Grafana database back from a restic snapshot.
#
# Usage:  sudo infra/monitoring/restore.sh [snapshot-id]     (default: latest)
#
# THE TRAP THIS EXISTS TO AVOID is the same one every Postgres stack here has:
# Postgres keeps the password its data directory was FIRST INITIALISED with.
# Restoring this stack's .env next to a /opt/monitoring/postgres initialised
# with a different GRAFANA_DB_PASSWORD leaves a stack that cannot log into its
# own database — a failure that presents as a corrupt backup and is not one.
# So postgres/ is emptied and the container initialises a fresh cluster from
# the restored .env, with the dump loaded into it afterwards.
#
# WHAT MAKES THIS ONE DIFFERENT: it touches ONLY /opt/monitoring/postgres, not
# the whole tree. The other five directories under /opt/monitoring —
# prometheus/, loki/, tempo/, alloy/, grafana/ — are deliberately NOT in the
# snapshot (Tier 3: short-retention observability data, self-healing WAL, and a
# plugin cache). Moving the whole tree aside the way the other restore scripts
# do would destroy live data this backup never promised to bring back, and
# would throw away the per-directory ownership scripts/init-monitoring.sh sets
# up (grafana 472, prometheus 65534, loki and tempo 10001). Narrower is
# correct here, not lazier.

set -euo pipefail

STACK="monitoring"
DB_NAME="grafana"          # the stack is `monitoring`; its database is not
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE="/opt/backup/restore/${STACK}"
SNAPSHOT="${1:-latest}"
dump="${STAGE}/opt/backup/dumps/${STACK}/${STACK}.sql"

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it moves /opt trees around." >&2
  exit 1
fi

# Set the moment the live PGDATA is renamed, and printed by the trap on any
# non-zero exit. An operator whose restore just died mid-way is the one who
# needs to know where their data went.
BACKED_UP_TO=""

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$BACKED_UP_TO" ]; then
    echo >&2
    echo "!! This restore FAILED after moving the old database aside." >&2
    echo "!! Your previous PGDATA is at ${BACKED_UP_TO}." >&2
    echo "!! It was not deleted. Nothing is lost — put it back with:" >&2
    echo "!!   rm -rf /opt/${STACK}/postgres && mv ${BACKED_UP_TO} /opt/${STACK}/postgres" >&2
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
echo "About to restore the ${DB_NAME} database from snapshot ${id}."
echo "This stops the stack, moves /opt/${STACK}/postgres aside, and REPLACES"
echo "${REPO_ROOT}/infra/${STACK}/.env."
echo
echo "Prometheus, Loki, Tempo, Alloy and Grafana's file state are NOT touched."
echo "They are not in the backup and this script leaves them where they are."
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

# Both sources below are consumed unconditionally once the destructive part
# starts. Check them here, while the stack is merely stopped and the live
# PGDATA is still where it belongs.
#
# THE DUMP IS IN THIS LIST on purpose. A dump-less snapshot is not a corrupt
# one — infra/backup/run.sh produces a DEGRADED snapshot deliberately when
# pg_dump fails — and the documented next move operates on the live tree, so
# this script must not have moved it by the time it finds out.
echo "==> Checking the staged snapshot is complete"
missing=0
for src in "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" "$dump"; do
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
    echo "stops here BY DESIGN, with the live database untouched, because the" >&2
    echo "next move needs it that way — 'Last resort: the raw PGDATA' in" >&2
    echo "docs/backup-setup.md. Do not undo anything first." >&2
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

# ---- 5. Move the old database aside — never delete it ----------------------

ts="$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/${STACK}/postgres" ]; then
  echo "==> Moving /opt/${STACK}/postgres to /opt/${STACK}/postgres.bak-${ts}"
  mv "/opt/${STACK}/postgres" "/opt/${STACK}/postgres.bak-${ts}"
  BACKED_UP_TO="/opt/${STACK}/postgres.bak-${ts}"
fi

# EMPTY on purpose — see the header. Postgres initialises into it using the
# password from the .env restored below. No chown: the postgres image handles
# its own PGDATA ownership, which is why scripts/init-monitoring.sh chowns the
# other four data dirs and not this one.
mkdir -p "/opt/${STACK}/postgres"

echo "==> Restoring ${REPO_ROOT}/infra/${STACK}/.env"
cp -a "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" "${REPO_ROOT}/infra/${STACK}/.env"

# ---- 6. Bring the database up, alone ---------------------------------------

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
         && docker compose exec -T db pg_isready -U "${DB_NAME}" >/dev/null 2>&1 ); then
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
  echo "been loaded. Your previous PGDATA was moved aside intact, not" >&2
  echo "modified — its path is printed below. Read the database's log; a wrong" >&2
  echo "password against a non-empty PGDATA and a failed initdb both show up" >&2
  echo "there:" >&2
  echo "  cd ${REPO_ROOT}/infra/${STACK} && docker compose logs db" >&2
  exit 1
fi

# ---- 7. Load the dump ------------------------------------------------------

# -v ON_ERROR_STOP=1 because psql's exit status IGNORES SQL errors by default:
# without it a dump that only half-applies still exits 0, `set -e` sees nothing,
# and the script prints its success message over a half-restored Grafana.
echo "==> Loading ${dump}"
( cd "${REPO_ROOT}/infra/${STACK}" \
  && docker compose exec -T db \
       psql -v ON_ERROR_STOP=1 -U "${DB_NAME}" -d "${DB_NAME}" ) < "$dump"

# ---- 8. Bring the rest up --------------------------------------------------

echo "==> Starting the rest of the stack"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify, in this order:

  1. https://grafana.thefipster.de loads and your local admin login works.
     That account lives in the database you just restored, so it is the first
     thing that proves the dump loaded.
  2. Dashboards and datasources are present — but note these are PROVISIONED
     from this repo, so they would be there even on an empty database. They
     prove the stack came up, not that the restore worked.
  3. Anything hand-made in the UI is what actually proves it: users, API
     tokens, starred dashboards, saved playlists, and any dashboard created in
     the browser rather than committed to infra/monitoring/grafana/.
  4. "Sign in with Authentik" completes a login, if GRAFANA_OIDC_ENABLED is
     true — that exercises the restored client secret.
  5. Explore → Prometheus / Loki / Tempo still return data. They were never
     touched by this restore; if they are empty, something else is wrong.

Two things are left behind on purpose. Delete them once the checks above
pass — not before, because the first one is your way back:

  the previous database
    sudo rm -rf ${BACKED_UP_TO:-/opt/${STACK}/postgres.bak-${ts}}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}
EOF
