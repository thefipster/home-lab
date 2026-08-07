#!/usr/bin/env bash
#
# init-vaultwarden.sh — project-specific setup for the Vaultwarden stack.
#
# Assumes Docker is installed (run scripts/init-docker.sh first). Steps:
#   1. Create the persistent data tree under /opt/vaultwarden.
#   2. Seed infra/vaultwarden/.env from .env.example and generate
#      VAULTWARDEN_DB_PASSWORD if it is still blank.
#   3. Ensure the shared `proxy` network exists.
#   4. Symlink the stack into /opt/stacks so Dockge can manage it later.
#
# It does NOT generate VAULTWARDEN_ADMIN_TOKEN. That value is an Argon2id PHC
# string produced by `vaultwarden hash`, which prompts for the password twice
# and wants a terminal — so it is minted by hand in docs/vaultwarden-setup.md,
# step 3. The compose file fails fast while it is empty.
#
# No chown: the vaultwarden image runs as root (like Uptime Kuma and Alloy),
# and Postgres manages its own data dir's ownership.
#
# Re-runnable: it never rotates a secret that is already set. Run from anywhere.
# Usage (from the repo root):
#   scripts/init-vaultwarden.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/vaultwarden"
ENV_FILE="${STACK_DIR}/.env"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-docker.sh first." >&2
  exit 1
fi

echo "==> Creating persistent data tree under /opt/vaultwarden"
run_root mkdir -p /opt/vaultwarden/postgres /opt/vaultwarden/data

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Seeding ${ENV_FILE} from .env.example"
  cp "${STACK_DIR}/.env.example" "$ENV_FILE"
fi

# Fill a blank KEY= line with a generated secret. Idempotent: only rewrites a
# line whose value is EMPTY, so re-runs never rotate an existing secret. Uses a
# temp file for a portable in-place edit (same helper as init-authentik.sh).
ensure_secret() {
  local key="$1" value="$2"
  if grep -q "^${key}=$" "$ENV_FILE"; then
    grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
    echo "${key}=${value}" >> "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
    echo "==> Generated ${key} in .env"
  fi
}

# HEX, not base64 like the other stacks: this password is substituted into
# DATABASE_URL, which libpq parses as a URI, so base64's + / = would each need
# percent-encoding. 32 bytes of hex sidesteps that entirely.
echo "==> Ensuring VAULTWARDEN_DB_PASSWORD is set in ${ENV_FILE}"
ensure_secret VAULTWARDEN_DB_PASSWORD "$(openssl rand -hex 32)"

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the Vaultwarden stack into ${STACKS_DIR}/vaultwarden (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/vaultwarden"

echo
echo "Done. Next (see docs/vaultwarden-setup.md):"
echo "  1. Verify the vault.thefipster.de host record resolves to the infra VM"
echo "     — the registry is docs/dns-records.md. The *.thefipster.de wildcard"
echo "     points at the APPS VM, so without an exact record the name hits the"
echo "     wrong box and returns a 404 behind a valid cert."
echo "  2. Mint the admin token and put it in ${ENV_FILE}, SINGLE-QUOTED:"
echo "       docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash"
echo "  3. cd ${STACK_DIR} && docker compose up -d"
echo "  4. Open https://vault.thefipster.de/admin, invite yourself, then"
echo "     register at https://vault.thefipster.de/#/signup — signups are"
echo "     closed, so the invite is the only way in."
echo "     There is NO Authentik login in front of this — that is deliberate;"
echo "     see docs/sso-applications.md."
