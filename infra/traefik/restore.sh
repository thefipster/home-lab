#!/usr/bin/env bash
#
# restore.sh — put Traefik's ACME store back from a restic snapshot.
#
# Usage:  sudo infra/traefik/restore.sh [snapshot-id]     (default: latest)
#
# No database, so this is the short form: stop, restore acme.json and the .env,
# start. What it does NOT do is put Traefik's routing back, because the routing
# was never in the backup — it is labels on other stacks' containers and files
# under infra/traefik/dynamic/, all of which live in git.
#
# THAT IS THE TRAP HERE, and it is the opposite of every other stack's. Traefik
# comes back looking perfectly healthy whether or not this restore worked: the
# dashboard loads, the routers are all there, and every backend resolves —
# because none of that came from the snapshot. The ONLY thing this restore
# actually delivers is the ACME store, so the only check that means anything is
# the certificate the browser is served. See the verification list at the end.

set -euo pipefail

STACK="traefik"
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
    echo "!! This restore FAILED after moving the ACME store aside." >&2
    echo "!! Your previous store is at ${BACKED_UP_TO}." >&2
    echo "!! It was not deleted. Nothing is lost — put it back with:" >&2
    echo "!!   rm -rf /opt/${STACK}/letsencrypt && mv ${BACKED_UP_TO} /opt/${STACK}/letsencrypt" >&2
    echo "!! Then start Traefik: cd ${REPO_ROOT}/infra/${STACK} && docker compose up -d" >&2
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
echo "This stops the stack, moves /opt/${STACK}/letsencrypt aside, and REPLACES"
echo "${REPO_ROOT}/infra/${STACK}/.env."
echo
echo "NOTE: Traefik terminates TLS for the whole lab. While it is down NOTHING"
echo "is reachable by name — including Kuma, which will have nothing to report"
echo "to, and Authentik, which everything else authenticates against."
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

echo "==> Checking the staged snapshot is complete"
missing=0
for src in \
  "${STAGE}/opt/${STACK}/letsencrypt" \
  "${STAGE}${REPO_ROOT}/infra/${STACK}/.env"
do
  if [ ! -e "$src" ]; then
    echo "  ! missing from the snapshot: ${src}" >&2
    missing=1
  fi
done

# Named on its own, because an empty letsencrypt/ is a real state — Traefik
# creates the directory before it ever issues anything — and restoring it over
# a working store would silently throw the certificate away and force a
# reissue, which is the expensive thing this backup exists to avoid.
if [ ! -s "${STAGE}/opt/${STACK}/letsencrypt/acme.json" ]; then
  echo "  ! the snapshot's acme.json is missing or EMPTY" >&2
  echo "    Restoring it would discard the live certificate and force a" >&2
  echo "    reissue: ~10-15 min of netcup propagation, against a limit of 5" >&2
  echo "    duplicate certificates per week." >&2
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
  exit 1
fi

# ---- 5. Move the old store aside — never delete it -------------------------

ts="$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/${STACK}/letsencrypt" ]; then
  echo "==> Moving /opt/${STACK}/letsencrypt to /opt/${STACK}/letsencrypt.bak-${ts}"
  mv "/opt/${STACK}/letsencrypt" "/opt/${STACK}/letsencrypt.bak-${ts}"
  BACKED_UP_TO="/opt/${STACK}/letsencrypt.bak-${ts}"
fi

# ---- 6. Put it back --------------------------------------------------------

# cp -a preserves acme.json's mode. Traefik REFUSES TO START if it is more
# permissive than 600, which is a good failure — but only if the mode survives,
# so this must not be a plain cp.
echo "==> Restoring the ACME store"
mkdir -p "/opt/${STACK}"
cp -a "${STAGE}/opt/${STACK}/letsencrypt" "/opt/${STACK}/letsencrypt"

echo "==> Restoring ${REPO_ROOT}/infra/${STACK}/.env"
cp -a "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" "${REPO_ROOT}/infra/${STACK}/.env"

# ---- 7. Bring it up --------------------------------------------------------

echo "==> Starting ${STACK}"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify — and note that only the FIRST check tests this restore at all:

  1. The certificate is the RESTORED one, not a fresh reissue. Compare its
     notBefore against the snapshot's date: an issuance timestamp from minutes
     ago means acme.json did not come back and Traefik went and got a new
     certificate, burning one of five weekly duplicates.

       echo | openssl s_client -connect git.thefipster.de:443 -servername git.thefipster.de 2>/dev/null | openssl x509 -noout -issuer -dates

  2. Traefik's log shows no ACME challenge activity at startup. A restored
     store means it has nothing to do:

       cd ${REPO_ROOT}/infra/${STACK} && docker compose logs traefik | grep -i acme

  3. Everything else — the dashboard, every router, every backend — would look
     exactly like this even if the restore had done nothing at all, because
     the routing is labels and files in git, not in the snapshot. Checking it
     confirms Traefik started; it says nothing about the backup.

  4. The netcup credentials still work. Nothing exercises them until a renewal
     ~30 days before expiry, so a wrong .env is invisible until then. If you
     want certainty now, that is what the staging CA line commented out in
     compose.yaml is for.

Two things are left behind on purpose. Delete them once the checks pass:

  the previous ACME store
    sudo rm -rf ${BACKED_UP_TO:-/opt/${STACK}/letsencrypt.bak-${ts}}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}
EOF
