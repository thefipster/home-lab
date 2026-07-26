# Proxmox host on the node dashboard

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan
**Builds on:** the monitoring stack (Grafana + Prometheus + Loki + Tempo +
Alloy), deployed and verified on the infra VM —
[docs/grafana-setup.md](../../grafana-setup.md).

## Goal

Make the **Proxmox host** (`pve.thefipster.de`, `192.168.1.40`) a second node on
the existing **Node Exporter Full** dashboard, selectable from the same
dropdowns that today offer only `infra`.

The hypervisor is currently the lab's largest blind spot. Everything it runs is
observed; it is not. A full root filesystem or exhausted RAM on `.40` takes both
VMs with it, and nothing in the lab would say so beforehand.

## Why the dashboard needs no changes

`infra/monitoring/grafana/provisioning/dashboards/node-exporter-full.json`
drives three chained template variables:

```
job      → label_values(node_uname_info, job)
nodename → label_values(node_uname_info{job="$job"}, nodename)
node     → label_values(node_uname_info{job="$job", nodename="$nodename"}, instance)
```

It is keyed on **labels, not collectors**. Today exactly one producer emits
`node_*`: Alloy's embedded `prometheus.exporter.unix "host"`, relabelled to
`job="node"` / `instance="infra"`, with `hostname: infra` on the container so
`nodename` is stable across recreates.

A second series of `node_*` carrying `job="node"` and a distinct `instance` is
therefore the entire requirement. The dashboard JSON is not edited, and being
a pinned community dashboard (#1860), that is a property worth preserving.

## Approach

**Debian's `prometheus-node-exporter` as a systemd service on the Proxmox host,
scraped by the existing Alloy over the LAN.**

The hypervisor stays a hypervisor: one package from Debian main, one systemd
unit, no Docker, and no repo checkout on `.40`.

### Alternatives rejected

- **node exporter in an LXC container on PVE.** Superficially attractive because
  LXC is a *native* Proxmox workload, so it does not violate the no-Docker-on-
  the-host rule. But PVE virtualizes `/proc` in containers through lxcfs — the
  exporter would report the container's CPU and memory rather than the
  hypervisor's, which is the same class of wrong-but-plausible number that
  `infra/monitoring/compose.yaml` already warns about for Alloy's host mounts.
  Correcting it needs enough privilege and host mounts that it stops being a
  container in any meaningful sense.
- **A second Alloy on the Proxmox host.** Would fit the "Alloy is the lab's only
  collector" framing and could also ship PVE's journald into Loki. Rejected as
  disproportionate: a second config file, a second remote-write path and a Go
  collector resident on the hypervisor, to answer CPU/RAM/disk questions a
  static binary already answers. Revisit if PVE's journal is ever wanted in
  Loki — that is the trigger, not this.
- **`prometheus-pve-exporter`.** Hypervisor-*specific* metrics (guest states,
  storage pools, cluster health) via the PVE API. Genuinely useful and
  genuinely different: different metric names, its own dashboard, its own API
  token. It would not put a single series on Node Exporter Full. Out of scope
  here; see [Out of scope](#out-of-scope).

## Constraints & decisions made

- **The scrape target is the hostname, not the IP.** `pve.thefipster.de:9100`,
  consistent with how every other name in the lab is addressed. Prometheus
  re-resolves per scrape, so a host IP change corrects itself. Resolution from
  inside a container is not a new assumption — it is one of the three verified
  DNS layers in
  [wildcard-dns-udr.md](../../wildcard-dns-udr.md#verify-at-all-three-layers).
- **`instance` is set inline on the static target**, not derived. Prometheus
  only defaults `instance` from `__address__` when the label is absent, so
  setting `instance = "pve"` explicitly is what keeps the FQDN out of the
  dashboard dropdown. Value `pve` is symmetric with the existing `infra` and
  matches the host's real `nodename` from `uname`, so both dropdowns read the
  same.
- **Its own `prometheus.scrape` block, not an addition to `infra_services`.**
  That block's targets are one `job` per service; this is a second `node`, and
  the existing `prometheus.scrape "host"` next to it is the thing it parallels.
- **No init script.** Every stack in the repo has one, but this is not a stack —
  it is an `apt install` on a machine with no repo checkout. A script would have
  to be cloned or `scp`'d onto the hypervisor first, which is more moving parts
  than the commands it would wrap. The guide carries the commands directly.
- **The install step lives in `grafana-setup.md`, not `proxmox-setup.md`.**
  CLAUDE.md gives that guide ownership of *all* of monitoring — the platform and
  what it observes — and the exporter is meaningless until Alloy exists to
  scrape it. Cost accepted: this is the only guide that sends the reader off the
  infra VM mid-way.
- **Default `:9100` bind, no auth, no PVE firewall rule.** Matches the lab's
  stated posture; `infra/monitoring/compose.yaml` carries the same reasoning
  verbatim for the OTLP endpoint (`No auth (LAN-only lab)`). On a single-NIC
  host, binding `192.168.1.40:9100` instead of `0.0.0.0:9100` changes the
  exposure by nothing. Recorded rather than assumed — see
  [Risks](#risks-and-known-limits).
- **`DiskAlmostFull` is left unfiltered, so it starts covering the
  hypervisor.** The rule matches `job="node"` with no `instance` selector. A
  full `/` or `/var/lib/vz` on `.40` is a more serious incident than the same on
  the infra VM, so this is the desired outcome and not a side effect.
- **Nothing in `infra/monitoring/compose.yaml` changes.** No new mounts, no
  network change, no new published port. Alloy reaches a LAN address outbound
  through the docker bridge — the one scrape target in the lab that is not a
  container.

## Changes by file

| File | Change |
|---|---|
| `infra/monitoring/alloy/config.alloy` | New `prometheus.scrape "proxmox_host"` block |
| `docs/dns-records.md` | `pve.thefipster.de` row: drop "(optional)", record its new consumer |
| `docs/grafana-setup.md` | Host-side install step; extend metrics verification, checklist and troubleshooting |
| `CLAUDE.md` | Record that the hypervisor is now a scrape target |

### `infra/monitoring/alloy/config.alloy`

Added after `prometheus.scrape "host"`:

```hcl
prometheus.scrape "proxmox_host" {
  targets = [
    {"__address__" = "pve.thefipster.de:9100", "job" = "node", "instance" = "pve"},
  ]
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

### Host side (documented, not scripted)

On the Proxmox host, as root:

```bash
apt install prometheus-node-exporter
```

The package is in **Debian main** — it needs no Proxmox repo, and in particular
no enterprise subscription. It enables and starts its own systemd unit,
`prometheus-node-exporter.service`, listening on `:9100`. Verified locally with
`curl -s localhost:9100/metrics | head`, then from the infra VM to prove the
path Alloy will take.

### `docs/dns-records.md`

The row exists already but was never load-bearing:

| Domain Name | IP | Serves |
|---|---|---|
| `pve.thefipster.de` | `192.168.1.40` | Proxmox web UI, and the host node exporter Alloy scrapes (`:9100`) |

## Verification

Extending the existing metrics checks in `grafana-setup.md`:

- `up{job="node"}` → **two** series, `infra` and `pve`, neither at `0`
- `node_uname_info{job="node"}` → two series with distinct `nodename`
- `node_filesystem_avail_bytes{instance="pve"}` compared against `df -h` **on
  the Proxmox host**. The guide already insists on this comparison for the infra
  VM; the reasoning transfers unchanged — a wrong number here looks entirely
  plausible, and only the comparison catches it.
- Node Exporter Full: the **Nodename** dropdown offers both, and switching
  between them redraws CPU, RAM, disk and network with different values.

## Risks and known limits

- **A missing DNS record fails misleadingly, not loudly.** If the exact
  `pve.thefipster.de` record is absent, the name does not fail to resolve — the
  `*.thefipster.de` wildcard answers `192.168.1.42`, and Alloy quietly scrapes
  **the apps VM** on `:9100`. The symptom is `up{instance="pve"} == 0`, which
  reads as a broken exporter on a host where the exporter is fine. This is the
  exact trap `dns-records.md` already documents, surfacing in a new place;
  `getent hosts pve.thefipster.de` settles it in one command, and it belongs in
  the guide's troubleshooting section.
- **The two nodes are measured by different implementations.** `infra` comes
  from Alloy's embedded unix exporter, `pve` from upstream node_exporter at
  whatever version Debian ships. The dashboard tolerates both, but a panel that
  is populated for one node and blank for the other is a collector difference,
  not a fault — worth knowing before debugging it as one.
- **`ServiceDown` now covers the hypervisor**, which is the point, but it will
  also fire when `.40` is merely rebooting. `for: 5m` absorbs a quick reboot;
  a long one alerts.
- **This adds an unauthenticated LAN listener on the hypervisor.** Node exporter
  exposes host telemetry — filesystems, kernel version, network devices — to any
  LAN client. Bounded by the lab being LAN-only and consistent with the OTLP
  endpoint's existing stance, but it is a real widening of what `.40` serves,
  and it is stated here rather than left implicit.
- **The PVE firewall.** Off at datacenter level by default, so nothing is
  needed. If it has been enabled, `.41 → .40:9100` requires a rule — a
  troubleshooting note, not a build step.

## Out of scope

- **`prometheus-pve-exporter`** — guest states, storage pools, cluster health.
  Different metrics, different dashboard, needs a PVE API token. A separate
  piece of work with its own spec if it is ever wanted.
- **PVE journald logs into Loki.** Would need a collector on the host; see the
  rejected second-Alloy alternative above.
- **The apps VM (`.42`).** Same technique would work, but Coolify owns that box
  and nothing here depends on it. Not bundled in.
- **Dashboard edits of any kind.** #1860 stays pinned and unmodified.
