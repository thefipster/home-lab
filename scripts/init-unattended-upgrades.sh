#!/usr/bin/env bash
#
# init-unattended-upgrades.sh — automatic security updates for a lab guest.
#
# Installs `unattended-upgrades` and pins it to the distribution's SECURITY
# pocket, so a VM that nobody logs into for weeks still gets its patches. Run
# it on BOTH guests — the infra VM and the apps VM (Coolify's installer does
# not set this up either).
#
# Nothing here touches Docker, so the order relative to init-docker.sh is free.
# Prefer running it AFTER: init-docker.sh fixes the guest clock as its first
# step, and apt does TLS like everything else.
#
# What it deliberately does NOT upgrade:
#   * Anything from Docker's apt repo (origin=Docker). That repo is outside the
#     allowed origins, so docker-ce is never touched unattended — an unattended
#     daemon upgrade restarts Docker and bounces every container on the box.
#     Bump Docker by hand, when you are watching.
#   * Anything from the normal `-updates` pocket. Security only; feature
#     updates stay a decision.
#
# Reboots: ON by default, at 04:30, even with users logged in. Every stack in
# this repo is `restart: unless-stopped`, so Docker brings the lab back by
# itself, and a forgotten SSH session must not defer a kernel patch forever.
# Override per run:
#   AUTO_REBOOT=false scripts/init-unattended-upgrades.sh
#   AUTO_REBOOT_TIME=03:00 scripts/init-unattended-upgrades.sh
#
# Target platform: Ubuntu Server 26.04 LTS (the origin patterns below are
# Ubuntu's; the Proxmox host is Debian and has no checkout of this repo).
#
# Re-runnable: it rewrites its two config files and re-enables the timers.
# Usage (from the repo root):
#   scripts/init-unattended-upgrades.sh
#   sudo scripts/init-unattended-upgrades.sh   # also fine

set -euo pipefail

AUTO_REBOOT="${AUTO_REBOOT:-true}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:30}"

# Run a command as root. If we're already root, run it directly; otherwise sudo.
run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "==> Installing unattended-upgrades"
run_root apt-get update
run_root apt-get install -y unattended-upgrades

echo "==> Enabling the periodic apt jobs (/etc/apt/apt.conf.d/20auto-upgrades)"
# These four counters drive systemd's apt-daily.timer (refresh + download) and
# apt-daily-upgrade.timer (install). "1" means "every day"; without them the
# unattended-upgrades package is installed but idle.
run_root tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
// Managed by scripts/init-unattended-upgrades.sh (home-lab repo).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo "==> Writing the policy drop-in (/etc/apt/apt.conf.d/52homelab-unattended-upgrades)"
# Numbered above 50unattended-upgrades so it is read later and wins. The
# #clear directives are apt-config syntax, NOT comments: without them a second
# Origins block would be APPENDED to the distro default instead of replacing
# it, and the "security only" promise below would quietly not hold.
run_root tee /etc/apt/apt.conf.d/52homelab-unattended-upgrades > /dev/null <<EOF
// Managed by scripts/init-unattended-upgrades.sh (home-lab repo).

// Security pocket only — plus Ubuntu Pro's ESM pockets, which are where
// security fixes land once a release goes into extended maintenance.
// Docker's repo (origin=Docker) matches none of these on purpose: an
// unattended docker-ce upgrade would restart the daemon under the whole lab.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=\${distro_id},codename=\${distro_codename},label=\${distro_id}-security";
    "origin=\${distro_id}ESMApps,codename=\${distro_codename},label=\${distro_id}ESMApps";
    "origin=\${distro_id}ESM,codename=\${distro_codename},label=\${distro_id}ESM";
};

// Keep /boot from filling with old kernels — a 40 GB guest with a small /boot
// starts failing apt runs long before the root filesystem is anywhere near
// full, and a failing apt run is a security update that never happened.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Install package by package, so a run interrupted by a shutdown leaves a
// consistent dpkg state instead of one half-configured transaction.
Unattended-Upgrade::MinimalSteps "true";

// No mail: there is no MTA in this lab. Runs land in the journal and in
// /var/log/unattended-upgrades/. Outage alerting is Uptime Kuma's job.
Unattended-Upgrade::SyslogEnable "true";

Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
// Reboot even with a session open: an SSH window left open in a terminal tab
// is the normal state of a homelab, and it must not defer kernel patches
// indefinitely.
Unattended-Upgrade::Automatic-Reboot-WithUsers "${AUTO_REBOOT}";
EOF

echo "==> Enabling the apt timers"
run_root systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

echo
echo "Effective policy:"
apt-config dump 2>/dev/null \
  | grep -E '^(APT::Periodic|Unattended-Upgrade::(Origins-Pattern|Allowed-Origins|Automatic-Reboot|Remove))' \
  || true

echo
echo "Done. Verify (see docs/proxmox-setup.md, Part 7):"
echo "  1. sudo unattended-upgrade --dry-run --debug"
echo "     — prints which packages the next run would take. Nothing from"
echo "       Docker's repo should ever appear."
echo "  2. systemctl list-timers 'apt-daily*'   — both timers scheduled."
echo "  3. After the first real run: /var/log/unattended-upgrades/"
if [ "$AUTO_REBOOT" = "true" ]; then
  echo
  echo "NOTE: this host will REBOOT itself at ${AUTO_REBOOT_TIME} when an update"
  echo "      needs it. Containers come back on their own (restart:"
  echo "      unless-stopped); Uptime Kuma will notify about the gap."
fi
