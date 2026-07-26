#!/usr/bin/env bash
#
# init-node-exporter.sh — install Debian's prometheus-node-exporter as a
# systemd unit, so Alloy on the infra VM can scrape this machine's host metrics.
#
# WHICH MACHINES RUN THIS, AND WHICH DELIBERATELY DO NOT:
#   apps VM   — YES. This is the only caller in the lab.
#   infra VM  — NO. Alloy runs there and collects host metrics itself via its
#               embedded prometheus.exporter.unix against read-only /proc, /sys
#               and / mounts. A second exporter would be a duplicate target.
#               This is also why the install is NOT folded into init-host.sh,
#               which both Ubuntu VMs run.
#   Proxmox   — NO, not because it shouldn't have one (it does, scraped as
#               instance="pve"), but because the hypervisor has no checkout of
#               this repo. It stays a documented `apt install` in
#               docs/grafana-setup.md.
#
# The unit binds :9100 on all interfaces, which is what lets Alloy reach it from
# the infra VM. No firewall rule is opened because this lab configures no host
# firewall.
#
# Machine-agnostic: no paths, hostnames or repo layout are assumed.
# Re-runnable: apt install is a no-op when current, enable --now is idempotent.
# Usage (from anywhere):
#   scripts/init-node-exporter.sh

set -euo pipefail

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "==> Installing prometheus-node-exporter"
run_root apt-get update
run_root apt-get install -y prometheus-node-exporter

echo "==> Enabling and starting the unit"
run_root systemctl enable --now prometheus-node-exporter

echo "==> Verifying it answers on :9100"
# Give the unit a moment on a cold start, then prove the endpoint is real
# rather than trusting systemctl's word for it.
for _ in 1 2 3 4 5; do
  if curl -fsS --max-time 2 http://127.0.0.1:9100/metrics >/dev/null 2>&1; then
    echo "    ok — /metrics is answering"
    break
  fi
  sleep 1
done

if ! curl -fsS --max-time 2 http://127.0.0.1:9100/metrics >/dev/null 2>&1; then
  echo "node_exporter is not answering on 127.0.0.1:9100 — check:" >&2
  echo "  systemctl status prometheus-node-exporter" >&2
  exit 1
fi

echo
echo "Done. Next (see docs/grafana-setup.md):"
echo "  1. Nothing to do on this machine — Alloy on the infra VM already has"
echo "     this host in its scrape config (job=\"node\", instance=\"apps\")."
echo "  2. Confirm in Grafana: the Node Exporter Full dashboard's instance"
echo "     dropdown should now offer 'apps' alongside 'infra' and 'pve'."
