#!/usr/bin/env bash
#
# init-host.sh — general host setup (machine-level, not Forgejo-specific).
#
# Installs Docker Engine + the compose plugin from Docker's official apt repo
# and adds the invoking user to the `docker` group so they can run docker
# without sudo. Safe to re-run (idempotent-ish: apt install is a no-op when
# already current, and usermod -aG is harmless if the user is already a member).
#
# Target platform: Ubuntu Server 26.04 LTS.
# Usage:
#   ./init-host.sh          # run as your normal user; sudo is invoked as needed
#   sudo ./init-host.sh     # also fine — the real user is read from $SUDO_USER
#
# After it finishes you must LOG OUT / BACK IN (or run `newgrp docker`) for the
# new group membership to take effect in your shell.

set -euo pipefail

# The user who should end up in the `docker` group. When the script is run via
# sudo, $USER is "root", so prefer $SUDO_USER (the human who invoked sudo).
TARGET_USER="${SUDO_USER:-$USER}"

if [ "$TARGET_USER" = "root" ]; then
  echo "Refusing to add 'root' to the docker group. Run this as a normal user" >&2
  echo "(sudo will be invoked where needed), or set SUDO_USER appropriately." >&2
  exit 1
fi

# Run a command as root. If we're already root, run it directly; otherwise sudo.
run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "==> Removing any distro-packaged Docker that would conflict with docker-ce"
# These are the packages Docker's docs tell you to remove first. Ignore errors:
# most won't be installed on a fresh box.
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  run_root apt-get remove -y "$pkg" 2>/dev/null || true
done

echo "==> Installing prerequisites and Docker's apt signing key"
run_root apt-get update
run_root apt-get install -y ca-certificates curl
run_root install -m 0755 -d /etc/apt/keyrings
run_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
run_root chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Adding Docker's apt repository"
# Codename is detected from /etc/os-release so this tracks the host release
# (noble, resolute, …) instead of being hard-coded.
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  | run_root tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> Installing Docker Engine, CLI, containerd, buildx and compose plugin"
run_root apt-get update
run_root apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Adding user '${TARGET_USER}' to the docker group"
run_root usermod -aG docker "$TARGET_USER"

echo
echo "Done. Installed:"
docker --version
docker compose version
echo
echo "NOTE: log out and back in (or run 'newgrp docker') so '${TARGET_USER}'"
echo "      picks up the docker group and can run docker without sudo."
