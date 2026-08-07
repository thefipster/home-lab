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

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it moves /opt trees around." >&2
  exit 1
fi

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

# ---- 4. Move the live tree aside — never delete it -------------------------

ts="$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/${STACK}" ]; then
  echo "==> Moving /opt/${STACK} to /opt/${STACK}.bak-${ts}"
  mv "/opt/${STACK}" "/opt/${STACK}.bak-${ts}"
fi

# ---- 5. Put the files back -------------------------------------------------

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

# ---- 6. Bring the database up, alone ---------------------------------------

echo "==> Starting the database"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d db )

echo -n "==> Waiting for Postgres"
for _ in $(seq 1 60); do
  if ( cd "${REPO_ROOT}/infra/${STACK}" \
       && docker compose exec -T db pg_isready -U "${STACK}" >/dev/null 2>&1 ); then
    echo " ready"
    break
  fi
  echo -n "."
  sleep 2
done

# ---- 7. Load the dump ------------------------------------------------------

dump="${STAGE}/opt/backup/dumps/${STACK}/${STACK}.sql"
if [ ! -f "$dump" ]; then
  echo "no dump at ${dump} — the snapshot has no SQL. See the last-resort" >&2
  echo "PGDATA path in docs/backup-setup.md." >&2
  exit 1
fi

echo "==> Loading ${dump}"
( cd "${REPO_ROOT}/infra/${STACK}" \
  && docker compose exec -T db psql -U "${STACK}" -d "${STACK}" ) < "$dump"

# ---- 8. Bring the rest up --------------------------------------------------

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
