#!/usr/bin/env bash
#
# init-host.sh — machine-level basics for a lab guest, independent of Docker.
#
# Run this FIRST on both VMs, before init-docker.sh and
# init-unattended-upgrades.sh: everything after it talks TLS (apt, curl, the
# ACME client), and TLS is exactly what a skewed clock breaks.
#
# What it does today: lets the guest's time-sync daemon STEP a badly skewed
# clock. A Proxmox snapshot rollback resumes the VM with the clock frozen at
# snapshot time, and chrony's default policy would never correct the resulting
# offset — every TLS handshake then fails with "certificate has expired or is
# not yet valid", which looks like a certificate problem and isn't.
# See docs/proxmox-setup.md, Part 8.
#
# This is the home for host setup that is not tied to a stack or to Docker;
# the two neighbours are scripts/init-docker.sh (Docker Engine + compose, infra
# VM only — the apps VM gets its Docker from Coolify's installer) and
# scripts/init-unattended-upgrades.sh (automatic security updates, both VMs).
#
# Target platform: Ubuntu Server 26.04 LTS.
# Re-runnable: it rewrites its drop-in and restarts the daemon.
# Usage (from the repo root):
#   scripts/init-host.sh
#   sudo scripts/init-host.sh   # also fine

set -euo pipefail

# Run a command as root. If we're already root, run it directly; otherwise sudo.
run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "==> Allowing the time-sync daemon to step a badly skewed clock"
# A Proxmox snapshot rollback resumes the VM with the clock frozen at snapshot
# time — potentially days behind. chrony's default step policy (makestep 1 3)
# steps the clock only during its first three updates after service start; a
# rollback happens long after those, so a large offset would only ever be
# slewed — effectively never corrected. `makestep 1 -1` allows stepping at ANY
# time; it still acts only on offsets over 1s, so normal operation is
# unaffected.
if dpkg -s chrony >/dev/null 2>&1; then
  run_root mkdir -p /etc/chrony/conf.d
  printf 'makestep 1 -1\n' \
    | run_root tee /etc/chrony/conf.d/90-step-any-offset.conf > /dev/null
  run_root systemctl restart chrony
else
  # systemd-timesyncd steps at any offset, but only when its poll timer fires
  # — by default up to ~34 min (PollIntervalMaxSec) after a rollback. Tighten
  # the interval so the stale-clock window is minutes, not half an hour.
  run_root mkdir -p /etc/systemd/timesyncd.conf.d
  printf '[Time]\nPollIntervalMaxSec=512\n' \
    | run_root tee /etc/systemd/timesyncd.conf.d/90-snapshot-rollback.conf > /dev/null
  run_root systemctl restart systemd-timesyncd
fi

echo
echo "Done. Verify (see docs/proxmox-setup.md, Part 7):"
echo "  timedatectl status   — 'System clock synchronized: yes'"
echo
echo "Next on the infra VM: scripts/init-docker.sh, then"
echo "scripts/init-unattended-upgrades.sh. On the apps VM: only the latter."
