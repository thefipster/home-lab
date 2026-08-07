#!/usr/bin/env bash
#
# init-monitoring.sh — project-specific setup for the monitoring stack
# (Grafana + Postgres + Prometheus + Loki + Tempo + Alloy).
#
# Assumes Docker is installed (run scripts/init-docker.sh first). Steps:
#   1. Create the persistent data tree under /opt/monitoring and set the
#      per-image ownership each container needs.
#   2. Seed infra/monitoring/.env from .env.example; auto-generate
#      GRAFANA_DB_PASSWORD and GRAFANA_ADMIN_PASSWORD if they are still blank.
#   3. Ensure the shared `proxy` network exists.
#   4. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# The two Authentik OIDC values stay BLANK on purpose — they are copied by hand
# from Authentik (docs/grafana-setup.md, step 5), which is also when
# GRAFANA_OIDC_ENABLED flips to true. The stack comes up fine without them.
#
# Re-runnable: it never rotates a secret that is already set. Run from anywhere.
# Usage (from the repo root):
#   scripts/init-monitoring.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/monitoring"
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

echo "==> Creating persistent data tree under /opt/monitoring"
run_root mkdir -p /opt/monitoring/postgres /opt/monitoring/grafana \
  /opt/monitoring/prometheus /opt/monitoring/loki /opt/monitoring/alloy \
  /opt/monitoring/tempo
# Each image drops to a different user and must own its data dir, or it
# crash-loops on first boot. These UIDs were read from the PINNED images'
# own configs, not guessed:
#   grafana/grafana:13.1  -> 472
#   prom/prometheus:v3    -> nobody (65534)
#   grafana/loki:3        -> 10001
#   grafana/tempo:3.0.2   -> 10001
#   grafana/alloy:v1.18.1 -> root, so its dir needs no chown
# Postgres manages its own dir's ownership.
run_root chown -R 472:472 /opt/monitoring/grafana
run_root chown -R 65534:65534 /opt/monitoring/prometheus
run_root chown -R 10001:10001 /opt/monitoring/loki
run_root chown -R 10001:10001 /opt/monitoring/tempo

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

echo "==> Ensuring secrets are set in ${ENV_FILE}"
# Postgres keeps the password its data dir was FIRST initialized with, so this
# only generates for fresh installs (blank value). On an existing deployment,
# set GRAFANA_DB_PASSWORD in .env to the current password by hand.
ensure_secret GRAFANA_DB_PASSWORD "$(openssl rand -base64 36 | tr -d '\n')"
# The break-glass login. Applied only when the Grafana DB is first initialized.
ensure_secret GRAFANA_ADMIN_PASSWORD "$(openssl rand -base64 24 | tr -d '\n')"

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the monitoring stack into ${STACKS_DIR}/monitoring (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/monitoring"

echo
echo "Done. Next (see docs/grafana-setup.md):"
echo "  1. Verify the grafana.thefipster.de (and otlp.thefipster.de) host"
echo "     records resolve to the infra VM — the registry is"
echo "     docs/dns-records.md. The *.thefipster.de wildcard points at the"
echo "     APPS VM, so without an exact record the name hits the wrong box."
echo "  2. cd ${STACK_DIR} && docker compose up -d"
echo "  3. Log in at https://grafana.thefipster.de as 'admin' using"
echo "     GRAFANA_ADMIN_PASSWORD from ${ENV_FILE}; check all three datasources."
echo "  4. Step 5: create the Authentik provider + application, put the client"
echo "     id/secret in .env, set GRAFANA_OIDC_ENABLED=true, and restart."
