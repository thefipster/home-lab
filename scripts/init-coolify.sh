#!/usr/bin/env bash
#
# init-coolify.sh — install Coolify (self-hosted PaaS) on the APPS VM.
#
# Assumes scripts/init-host.sh and scripts/init-unattended-upgrades.sh have run
# on this machine (docs/apps-vm-setup.md). It does NOT assume Docker:
# the apps VM skips init-docker.sh on purpose, because the Coolify installer
# below brings its own Engine. Steps:
#   1. Preflight: OS family, Docker Engine version IF one is present, disk, RAM.
#   2. Create a swapfile if none is active.
#   3. Point Docker's data-root at /data/docker, BEFORE any Engine exists.
#   4. Fetch Coolify's official installer to a temp file, show where it came
#      from and its sha256, then run it — then re-check the data-root survived.
#   5. Seed apps/.env from apps/.env.example if missing.
#
# Unlike every other init script in this repo, this one does NOT produce a
# compose stack: Coolify owns this VM's Docker and manages applications through
# its own web UI. That is why apps/ holds no compose.yaml.
#
# Re-runnable: Coolify's installer is itself an upgrade path, the swapfile step
# is a no-op once swap is active, and .env is never overwritten.
# Usage (from the repo root):
#   scripts/init-coolify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPS_DIR="${REPO_ROOT}/apps"

INSTALLER_URL="https://cdn.coollabs.io/coolify/install.sh"
SWAPFILE="/swapfile"
SWAP_SIZE_MB=4096
DATA_MOUNT="/data"
DOCKER_DATA_ROOT="/data/docker"
DAEMON_JSON="/etc/docker/daemon.json"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# --- 1. preflight -----------------------------------------------------------

echo "==> Preflight"

# Coolify's installer officially supports Ubuntu 20.04/22.04/24.04 LTS and
# Debian 11/12. This lab targets Ubuntu 26.04, which is not on that list yet, so
# an unrecognised release WARNS and continues rather than blocking — the
# installer is Debian-family generic and the failure mode, if any, is loud.
if [ ! -f /etc/os-release ]; then
  echo "cannot read /etc/os-release — this script targets Debian-family hosts." >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
# `case` globs rather than `[ x != *glob* ]`, which compares literally and would
# pass anything. Plain Debian sets ID=debian with NO ID_LIKE, so matching on
# ID_LIKE alone would reject it.
case "${ID:-}:${ID_LIKE:-}" in
  ubuntu:*|debian:*|*:*debian*) : ;;
  *)
    echo "This script targets Debian-family hosts; found ID=${ID:-?}." >&2
    exit 1 ;;
esac

case "${VERSION_ID:-}" in
  20.04|22.04|24.04|11|12)
    echo "    OS: ${PRETTY_NAME} (on Coolify's supported list)" ;;
  *)
    echo "    OS: ${PRETTY_NAME}"
    echo "    WARNING: Coolify officially lists Ubuntu 20.04/22.04/24.04 and"
    echo "             Debian 11/12. Continuing anyway." ;;
esac

# Docker is OPTIONAL here — the one preflight in this repo that does not demand
# it. The apps VM deliberately skips scripts/init-docker.sh
# (docs/apps-vm-setup.md): Coolify's installer brings its own Engine, so a
# missing docker binary
# is the NORMAL state on a first run and must not abort. When one IS already
# present — a re-run, or an Engine that arrived some other way — Coolify needs
# major version 24 or newer, so check that instead of assuming.
if ! command -v docker >/dev/null 2>&1; then
  echo "    Docker: not installed — Coolify's installer will provide it"
else
  DOCKER_MAJOR="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || true)"
  if [ -z "$DOCKER_MAJOR" ]; then
    echo "    WARNING: Docker is installed but its version could not be read"
    echo "             (daemon down, or this user is not in the docker group)."
  elif [ "$DOCKER_MAJOR" -lt 24 ]; then
    echo "Docker Engine ${DOCKER_MAJOR} is too old — Coolify needs 24 or newer." >&2
    exit 1
  else
    echo "    Docker Engine major: ${DOCKER_MAJOR}"
  fi
fi

# Coolify's own installer checks for 30 GB free and fails below it. Check here
# too so the failure names the real cause before anything is downloaded.
FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [ "${FREE_GB:-0}" -lt 30 ]; then
  echo "Only ${FREE_GB} GB free on / — Coolify's installer requires 30 GB." >&2
  exit 1
fi
echo "    Free on /: ${FREE_GB} GB"

TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
echo "    RAM: ${TOTAL_MB} MB"
if [ "$TOTAL_MB" -lt 2048 ]; then
  echo "    WARNING: Coolify's minimum is 2 GB and it uses ~1 GB itself."
fi

# --- 2. swap ----------------------------------------------------------------

# Coolify does not create swap and recommends having some. Builds are what
# exhaust RAM on this box, and a build that gets OOM-killed looks like a broken
# app rather than a full machine.
echo "==> Ensuring swap exists"
if [ "$(awk 'NR>1 {print $3; exit}' /proc/swaps)" != "" ]; then
  echo "    swap already active — nothing to do"
elif [ -e "$SWAPFILE" ]; then
  echo "    ${SWAPFILE} exists but is not active — leaving it alone"
  echo "    (inspect it, then: sudo swapon ${SWAPFILE})"
else
  echo "    creating ${SWAPFILE} (${SWAP_SIZE_MB} MB)"
  run_root fallocate -l "${SWAP_SIZE_MB}M" "$SWAPFILE"
  run_root chmod 600 "$SWAPFILE"
  run_root mkswap "$SWAPFILE"
  run_root swapon "$SWAPFILE"
  if ! grep -q "^${SWAPFILE} " /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$SWAPFILE" | run_root tee -a /etc/fstab > /dev/null
  fi
fi

# --- 3. Docker's data-root --------------------------------------------------

# Left alone, Coolify's installer brings up the Engine with the default
# /var/lib/docker — on the 64 GB root disk. Images, layers, containers and
# build cache are the part of this machine that actually grows, and this repo
# assigns that growth to the 300 GB `data` mirror, so the data-root is pointed
# there BEFORE any Engine exists. Afterwards means moving a live data
# directory, the same trap docs/apps-vm-setup.md names for /data/coolify.
#
# /data/docker is the one directory on that disk which is DELIBERATELY
# disposable: every byte in it is pullable or rebuildable. That is also why the
# disk carries backup=0 on the hypervisor, and why the file-level backup job
# that eventually covers this VM must walk /data/coolify and /data/<stack>
# rather than /data.
echo "==> Pointing Docker's data-root at ${DOCKER_DATA_ROOT}"

# Not cosmetic. If /data is an ordinary directory on the root filesystem, then
# writing the data-root here recreates the exact problem this step exists to
# fix — and it would look like it worked.
if ! mountpoint -q "$DATA_MOUNT"; then
  echo "${DATA_MOUNT} is not a mountpoint — mount the 300 GB data disk first" >&2
  echo "(docs/apps-vm-setup.md, step 4)." >&2
  exit 1
fi

# The preflight's Docker check above is deliberately soft, so an Engine that is
# already running is REACHABLE here. Switching the data-root under one orphans
# every image, volume and container it holds, so change nothing and say why.
if [ -d /var/lib/docker ] \
   && [ -n "$(run_root find /var/lib/docker -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "    WARNING: /var/lib/docker exists and is not empty."
  echo "             Leaving ${DAEMON_JSON} alone — changing the data-root under"
  echo "             a live Engine orphans everything it holds. To move it on"
  echo "             purpose: stop docker, move the tree, then set \"data-root\""
  echo "             in ${DAEMON_JSON} by hand."
elif ! command -v python3 >/dev/null 2>&1; then
  echo "    WARNING: python3 not found, so ${DAEMON_JSON} cannot be edited"
  echo "             without risking whatever else is in it. Set"
  echo "             \"data-root\": \"${DOCKER_DATA_ROOT}\" by hand, then re-run."
else
  run_root mkdir -p "$DOCKER_DATA_ROOT" /etc/docker

  # MERGE, never overwrite. On a re-run this file already holds whatever
  # Coolify's installer put in it, and clobbering that would be a silent
  # regression somewhere else. python3 is in Ubuntu Server's base install;
  # the branch above covers its absence rather than assuming.
  run_root python3 - "$DAEMON_JSON" "$DOCKER_DATA_ROOT" <<'PY'
import json, os, sys

path, root = sys.argv[1], sys.argv[2]

try:
    with open(path) as fh:
        cfg = json.load(fh)
except FileNotFoundError:
    cfg = {}
except json.JSONDecodeError as exc:
    sys.exit(f"{path} is not valid JSON ({exc}); fix it by hand and re-run.")

if cfg.get("data-root") == root:
    print(f"    {path} already sets data-root to {root} — nothing to do")
    sys.exit(0)

cfg["data-root"] = root

# Write beside the target and rename, so an interrupted run cannot leave the
# Engine with a half-written config it refuses to start on.
tmp = path + ".new"
with open(tmp, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print(f"    wrote data-root={root} to {path}")
PY
fi

# --- 4. install -------------------------------------------------------------

# Deliberately NOT `curl ... | sudo bash`. Same operation, but the script lands
# on disk first so its origin and checksum are printed and it can be read before
# it runs as root. Record the checksum: if a re-run shows a different one, the
# vendor changed the installer.
echo "==> Fetching Coolify's installer"
TMP_INSTALLER="$(mktemp -t coolify-install.XXXXXX.sh)"
trap 'rm -f "$TMP_INSTALLER"' EXIT

curl -fsSL "$INSTALLER_URL" -o "$TMP_INSTALLER"

echo "    source: ${INSTALLER_URL}"
echo "    sha256: $(sha256sum "$TMP_INSTALLER" | cut -d' ' -f1)"
echo "    bytes:  $(wc -c < "$TMP_INSTALLER")"
echo "    saved:  ${TMP_INSTALLER}"
echo
echo "    Read it first if you like:  less ${TMP_INSTALLER}"
echo

echo "==> Running the installer as root (this takes a few minutes)"
# Coolify requires root and documents non-root as not fully supported.
run_root bash "$TMP_INSTALLER"

# Coolify's installer writes /etc/docker/daemon.json for its own reasons, and
# whether it merges or replaces is not documented — so verify rather than
# assume. A clobbered data-root sends every future image layer back to the
# 64 GB root disk, and nothing else would look wrong for weeks.
ACTUAL_ROOT="$(run_root docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
if [ "$ACTUAL_ROOT" = "$DOCKER_DATA_ROOT" ]; then
  echo "    data-root confirmed: ${ACTUAL_ROOT}"
else
  echo "    WARNING: Docker reports data-root '${ACTUAL_ROOT:-unknown}', not"
  echo "             ${DOCKER_DATA_ROOT}. The installer probably rewrote"
  echo "             ${DAEMON_JSON}. Put the key back, then:"
  echo "             sudo systemctl restart docker"
fi

# --- 5. .env ----------------------------------------------------------------

if [ ! -f "${APPS_DIR}/.env" ]; then
  echo "==> Seeding ${APPS_DIR}/.env from .env.example"
  cp "${APPS_DIR}/.env.example" "${APPS_DIR}/.env"
fi

# --- done -------------------------------------------------------------------

IP="$(hostname -I | awk '{print $1}')"

echo
echo "Done. Next (see docs/coolify-setup.md):"
echo "  1. Open http://${IP}:8000 and create the admin account NOW — the"
echo "     instance is unauthenticated until you do."
echo "  2. Fill in ${APPS_DIR}/.env with your netcup credentials, then type"
echo "     the same values into the proxy's compose in Coolify's UI"
echo "     (Servers -> Proxy -> Configuration) so it can issue the"
echo "     *.thefipster.de wildcard via DNS-01. Coolify regenerates that"
echo "     compose from its own store; the .env file is the recovery copy."
echo "  3. Install the host metrics exporter so the infra VM can watch this"
echo "     machine:  scripts/init-node-exporter.sh"
echo "  4. coolify.thefipster.de needs NO DNS record — the *.thefipster.de"
echo "     wildcard already points here. See docs/dns-records.md."
