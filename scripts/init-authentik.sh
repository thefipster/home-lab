#!/usr/bin/env bash
#
# init-authentik.sh — project-specific setup for the Authentik SSO stack.
#
# Assumes Docker is installed (run scripts/init-docker.sh first). Steps:
#   1. Create the persistent data tree under /opt/authentik.
#   2. Seed infra/authentik/.env from .env.example; auto-generate the two
#      secrets (AUTHENTIK_SECRET_KEY, PG_PASS) if they are still blank.
#   3. Ensure the shared `proxy` network exists.
#   4. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# Re-runnable: it never rotates a secret that is already set. Run from anywhere.
# Usage (from the repo root):
#   scripts/init-authentik.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/authentik"
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

echo "==> Creating persistent data tree under /opt/authentik"
# `data` is the file-storage mount Authentik has expected since 2025.12 (it
# replaced `media`, which now lives inside it as data/media and is served at
# the /files prefix). No `redis` dir — Authentik dropped Redis in 2025.10.
run_root mkdir -p /opt/authentik/postgres /opt/authentik/data/media \
  /opt/authentik/certs /opt/authentik/templates
# server + worker run as UID/GID 1000 (non-root image) and must be able to
# write these mounts — both create subdirectories under /data on boot and
# crash-loop on a root-owned dir. Postgres manages its own.
run_root chown -R 1000:1000 /opt/authentik/data /opt/authentik/certs \
  /opt/authentik/templates

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Seeding ${ENV_FILE} from .env.example"
  cp "${STACK_DIR}/.env.example" "$ENV_FILE"
fi

# Fill a blank KEY= line with a generated secret. Idempotent: only rewrites a
# line whose value is EMPTY, so re-runs never rotate an existing secret. Uses a
# temp file for a portable in-place edit (same approach as init-forgejo.sh).
ensure_secret() {
  local key="$1" value="$2"
  if grep -q "^${key}=$" "$ENV_FILE"; then
    grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
    echo "${key}=${value}" >> "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
    echo "==> Generated ${key} in .env"
  fi
}

echo "==> Ensuring secrets are set in ${ENV_FILE}"
ensure_secret AUTHENTIK_SECRET_KEY "$(openssl rand -base64 60 | tr -d '\n')"
ensure_secret PG_PASS "$(openssl rand -base64 36 | tr -d '\n')"
# Applied only when akadmin is FIRST created — generate a real value up front
# so no placeholder can slip through the compose guard and become the password.
ensure_secret AUTHENTIK_BOOTSTRAP_PASSWORD "$(openssl rand -base64 24 | tr -d '\n')"

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the Authentik stack into ${STACKS_DIR}/authentik (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/authentik"

echo
echo "Done. Next (see docs/authentik-setup.md):"
echo "  1. Read AUTHENTIK_BOOTSTRAP_PASSWORD from ${ENV_FILE} — it is the"
echo "     initial akadmin password (applied only when akadmin is first created)."
echo "  2. cd ${STACK_DIR} && docker compose up -d"
echo "  3. Log in at https://auth.thefipster.de as akadmin, then wire providers."
