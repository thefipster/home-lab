# Proxmox host on the node dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Proxmox host a second selectable node on the existing Node
Exporter Full dashboard, by installing Debian's `prometheus-node-exporter` on
the hypervisor and adding one scrape block to Alloy.

**Architecture:** The dashboard is keyed on labels, not collectors — a second
`node_*` series carrying `job="node"` and `instance="pve"` is the entire
requirement, so no dashboard JSON changes. Alloy scrapes
`pve.thefipster.de:9100` outbound over the LAN; no mount, network or port
change to any container. The host side is an `apt install` documented in the
guide, not an init script.

**Tech Stack:** Grafana Alloy (River/HCL config), Prometheus, Debian
`prometheus-node-exporter`, Markdown docs.

**Spec:** [2026-07-26-proxmox-node-exporter-design.md](../specs/2026-07-26-proxmox-node-exporter-design.md)

## Global Constraints

- **This repo has no build, lint or test system.** Correctness is verified by
  reading, plus runtime checks that happen *on the VMs*. "Verify" steps below
  are greps and link checks locally; the runtime checks are what the guide
  tells the operator to run. Do not invent a test framework.
- **`.gitattributes` forces LF repo-wide.** Do not let an editor rewrite line
  endings to CRLF.
- **When config and a guide disagree, the config is the source of truth** —
  update the guide to match, never the reverse.
- **Do not retro-edit historical records:** `docs/superpowers/specs/`,
  `docs/superpowers/plans/`, `docs/review/`. They record what was decided then.
- **Do not edit `node-exporter-full.json`.** It is vendored from grafana.com
  (#1860 rev 45) and its working-unmodified property is deliberate.
- **Exact label values, verbatim:** job `node`, instance `pve` (the Proxmox
  host) and `infra` (the existing infra VM). Scrape target
  `pve.thefipster.de:9100`. Scrape interval `15s`.
- **Guides describe a from-scratch bring-up of the current checkout.** No
  migration notes, no "if you already have X" branches.
- **Each command in a guide gets its own fenced block.**

---

### Task 1: Alloy scrape block and the DNS registry row

The collection change, plus the record it depends on. These commit together
because the scrape target is a hostname: the config is wrong without the
registry row, and the registry row has no consumer without the config.

**Files:**
- Modify: `infra/monitoring/alloy/config.alloy` (header comment ~line 3; new block after line 112)
- Modify: `docs/dns-records.md:37`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the Prometheus label set later tasks document and verify against —
  `up{job="node", instance="pve"}`, `node_uname_info{job="node"}` (two series),
  `node_filesystem_avail_bytes{instance="pve"}`.

- [ ] **Step 1: Update the config header comment to stop saying "the host" (singular)**

In `infra/monitoring/alloy/config.alloy`, the file-header comment currently
reads:

```
//   metrics — scrapes this stack, the infra services and the host, and
//             remote-writes everything into Prometheus (which has no
//             scrape_configs of its own);
```

Replace with:

```
//   metrics — scrapes this stack, the infra services, this VM and the Proxmox
//             host, and remote-writes everything into Prometheus (which has no
//             scrape_configs of its own);
```

- [ ] **Step 2: Add the scrape block**

Insert **after** the closing brace of `prometheus.scrape "host"` (currently
ends line 112) and **before** the `// --- logs ---` banner (currently line 114).
Keep one blank line either side.

```hcl
// The PROXMOX HOST — the one scrape target in the lab that is not a container.
// Alloy reaches it outbound over the LAN through the docker bridge, which is
// why adding it needed no mount, no network change and no published port.
//
// Addressed by NAME like everything else in the lab, so Prometheus re-resolves
// per scrape and a host IP change corrects itself. The failure mode is not the
// obvious one: if the exact `pve.thefipster.de` record is missing the name does
// NOT fail to resolve — the *.thefipster.de wildcard answers with the APPS VM
// and this quietly scrapes the wrong machine. See docs/dns-records.md.
//
// `instance` is set INLINE deliberately: Prometheus derives it from __address__
// only when the label is absent, and the bare `pve` is what keeps the FQDN out
// of the dashboard's dropdown. Same job="node" as the infra VM above — that
// shared label, plus a distinct instance, is the whole reason Node Exporter
// Full picks this host up with no edit to its JSON.
//
// The exporter is Debian's prometheus-node-exporter running as a systemd unit
// on the hypervisor (docs/grafana-setup.md step 6) — NOT a container, and not
// an LXC guest, which would report lxcfs's virtualized /proc instead of the
// host's.
prometheus.scrape "proxmox_host" {
  targets = [
    {"__address__" = "pve.thefipster.de:9100", "job" = "node", "instance" = "pve"},
  ]

  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

- [ ] **Step 3: Verify the block is syntactically consistent with its neighbours**

Run:

```bash
grep -n 'prometheus.scrape\|forward_to\|scrape_interval' infra/monitoring/alloy/config.alloy
```

Expected: four `prometheus.scrape` blocks (`monitoring_stack`, `infra_services`,
`host`, `proxmox_host`), each with its own `scrape_interval = "15s"` and
`forward_to = [prometheus.remote_write.default.receiver]`. Braces balanced —
the new block opens and closes like the three above it.

- [ ] **Step 4: Update the DNS registry row**

In `docs/dns-records.md:37`, replace:

```
| `pve.thefipster.de` | `192.168.1.40` | Proxmox web UI (optional) |
```

with:

```
| `pve.thefipster.de` | `192.168.1.40` | Proxmox web UI, and the host node exporter Alloy scrapes (`:9100`) |
```

- [ ] **Step 5: Verify no "optional" claim survives**

Run:

```bash
grep -n 'pve.thefipster.de' docs/dns-records.md
```

Expected: one row, no `(optional)`. The record is load-bearing now.

- [ ] **Step 6: Commit**

```bash
git add infra/monitoring/alloy/config.alloy docs/dns-records.md
git commit -m "Scrape the Proxmox host's node exporter from Alloy"
```

---

### Task 2: The guide — install step, verification, checklist, troubleshooting

All of `docs/grafana-setup.md`, in one commit: it is one guide and the step
numbering, its internal link, and the verification text have to move together
or the file is briefly self-contradictory.

**Files:**
- Modify: `docs/grafana-setup.md` (intro ~line 20; line 140; headings at 192 and a new one before it; verification 202-220; dashboards 303-306; alert table ~314; checklist 340-343 and 364; troubleshooting after line 411; "How it works" ~500-505 and 539-544)

**Interfaces:**
- Consumes: the labels produced by Task 1 (`instance="pve"`, `job="node"`).
- Produces: the section anchor `#7-verify-what-is-collected`, which Step 3
  below repoints the in-file link at.

- [ ] **Step 1: Widen the intro so it doesn't promise only one host**

Replace (lines ~20-23):

```
Everything ships in final form: your first start already tails every
container's logs, scrapes every service and the host, receives OTLP, and loads
the dashboards and alerts. The steps below bring it up, wire SSO, and then
verify each capability in turn.
```

with:

```
Everything ships in final form: your first start already tails every
container's logs, scrapes every service and this VM, receives OTLP, and loads
the dashboards and alerts. The steps below bring it up, wire SSO, add the
Proxmox host, and then verify each capability in turn.
```

- [ ] **Step 2: Insert the new Step 6 before "### 6. Verify what is collected"**

It goes *after* the SSO step so the two external links into
`#5-join-sso-oidc-via-authentik` (from `docs/sso-applications.md`) stay valid.

````markdown
### 6. Add the Proxmox host

The hypervisor is the last blind spot: it runs both VMs, and so far nothing
watches it. A full root filesystem on `.40` takes down everything else in this
guide, and without this step you would find out from the outage rather than
from the dashboard.

This is the only step in any guide that runs **on the Proxmox host** instead of
the infra VM. Open its shell (Proxmox UI → *pve* → **Shell**, or SSH to
`192.168.1.40`) and install Debian's node exporter:

```bash
apt install prometheus-node-exporter
```

It comes from **Debian main** — no Proxmox repo and no subscription — and the
package starts its own systemd unit on `:9100`. Confirm both:

```bash
systemctl is-active prometheus-node-exporter
```

```bash
curl -s localhost:9100/metrics | head -3
```

Then go **back to the infra VM** and exercise the exact path Alloy will take,
name resolution included:

```bash
docker compose exec grafana wget -qO- http://pve.thefipster.de:9100/metrics | head -3
```

Alloy already carries the scrape target, so there is nothing to enable or
restart — it picks the host up within 15 seconds. Nothing on this VM changed:
no mount, no network, no port. This is also why `up{instance="pve"}` has been
`0` since step 3, and why `ServiceDown` may already be firing for it; both
clear on their own once the exporter answers.

> **Check the name, not just the exporter.** `pve.thefipster.de` must exist as
> an **exact** record ([dns-records.md](dns-records.md)). Without it the name
> still resolves — the `*.thefipster.de` wildcard answers with the **apps VM** —
> and Alloy scrapes `192.168.1.42:9100`. That presents as
> `up{instance="pve"} == 0`, indistinguishable from a broken exporter on a host
> where the exporter is perfectly fine.

There is no init script for this one. Every *stack* in the repo has one, but
this is a single `apt install` on a machine with no checkout of this repo —
a script would have to be copied onto the hypervisor first, which is more
moving parts than the command it would wrap.
````

- [ ] **Step 3: Renumber the following section and fix the one internal link**

Change the heading:

```
### 6. Verify what is collected
```

to:

```
### 7. Verify what is collected
```

Then at line ~140, the link into it must follow. Replace:

```
([Step 6](#6-verify-what-is-collected)
```

with:

```
([Step 7](#7-verify-what-is-collected)
```

- [ ] **Step 4: Verify the renumbering left nothing dangling**

Run:

```bash
grep -n '^### [0-9]\|#[0-9]-verify-what-is-collected' docs/grafana-setup.md
```

Expected: headings 1-7 in order with no duplicates and no gap, and the only
anchor reference reading `#7-verify-what-is-collected`.

- [ ] **Step 5: Update the `up` expectation**

Replace (lines ~202-205):

```
Expect one series per `job`: the monitoring stack itself (`alloy`,
`prometheus`, `loki`, `grafana`, `tempo`), the infra services (`traefik`,
`authentik`, `forgejo`), and the host exporter (`node`). Any target sitting at
`0` is unreachable — see [Troubleshooting](#troubleshooting).
```

with:

```
Expect one series per `job` — the monitoring stack itself (`alloy`,
`prometheus`, `loki`, `grafana`, `tempo`) and the infra services (`traefik`,
`authentik`, `forgejo`) — plus **two** for `node`, one per host:
`instance="infra"` and `instance="pve"`. Any target sitting at `0` is
unreachable — see [Troubleshooting](#troubleshooting).
```

- [ ] **Step 6: Add the two-node metric check and widen the `df -h` comparison**

Replace (lines ~213-220):

````markdown
```promql
node_filesystem_avail_bytes
```

**Compare this against `df -h` on the VM — don't just confirm it returns.** If
the mounts or path arguments were wrong, the exporter would report the
*container's* filesystem: a plausible-looking number that simply isn't the
VM's. An empty result would be obvious; a wrong one is not.
````

with:

````markdown
```promql
node_uname_info{job="node"}
```

Two series with distinct `nodename` — the infra VM and the Proxmox host. This
is the query the dashboard's dropdowns are built from, so if it returns one
series they will offer one node.

```promql
node_filesystem_avail_bytes{instance="infra"}
```

**Compare this against `df -h` on the VM — don't just confirm it returns.** If
the mounts or path arguments were wrong, the exporter would report the
*container's* filesystem: a plausible-looking number that simply isn't the
VM's. An empty result would be obvious; a wrong one is not.

```promql
node_filesystem_avail_bytes{instance="pve"}
```

Same comparison, against `df -h` **on the Proxmox host**. The failure mode
differs — nothing is containerised there — but the reasoning carries: a target
resolving to the wrong machine returns entirely plausible filesystem numbers
for a box you did not mean to measure.
````

- [ ] **Step 7: Update the dashboard expectation**

Replace (lines ~303-306):

```
- **Node Exporter Full** — the `job` and `nodename`/`instance` dropdowns
  populate (`node` / `infra`) and the panels show live CPU, RAM, disk and
  network. Empty dropdowns mean the host exporter isn't labelled as expected —
  check `up{job="node"}`.
```

with:

```
- **Node Exporter Full** — the `job` dropdown offers `node`, and **Nodename**
  offers **two** entries: the infra VM and the Proxmox host. Switch between
  them and the CPU, RAM, disk and network panels redraw with different values.
  Empty dropdowns mean a host exporter isn't labelled as expected — check
  `up{job="node"}`. A panel that is populated for one node and blank for the
  other is *not* a fault: `infra` is measured by Alloy's embedded unix exporter
  and `pve` by upstream node_exporter, and their collector sets differ slightly.
```

- [ ] **Step 8: Note the alert's widened scope**

In the alert table (~line 314), replace the `DiskAlmostFull` row:

```
| `DiskAlmostFull` | a real filesystem over 80% used | 15m |
```

with:

```
| `DiskAlmostFull` | a real filesystem over 80% used, **on either host** | 15m |
```

- [ ] **Step 9: Update the metrics checklist**

Replace (lines ~340-343):

```
- [ ] `up` returns one series per job — `alloy`, `prometheus`, `loki`,
      `grafana`, `tempo`, `traefik`, `authentik`, `forgejo`, `node` — none at 0
- [ ] `traefik_service_requests_total` non-zero after loading a lab URL
- [ ] `node_filesystem_avail_bytes` matches `df -h` on the VM
```

with:

```
- [ ] `up` returns one series per job — `alloy`, `prometheus`, `loki`,
      `grafana`, `tempo`, `traefik`, `authentik`, `forgejo` — plus **two** for
      `node` (`infra` and `pve`), none at 0
- [ ] `traefik_service_requests_total` non-zero after loading a lab URL
- [ ] `node_uname_info{job="node"}` returns two series with distinct `nodename`
- [ ] `node_filesystem_avail_bytes{instance="infra"}` matches `df -h` on the
      infra VM
- [ ] `node_filesystem_avail_bytes{instance="pve"}` matches `df -h` on the
      Proxmox host
```

- [ ] **Step 10: Update the dashboards checklist line**

Replace (line ~364):

```
- [ ] Node Exporter Full: dropdowns populate, panels show data
```

with:

```
- [ ] Node Exporter Full: dropdowns populate, panels show data, and **Nodename**
      switches between the infra VM and the Proxmox host
```

- [ ] **Step 11: Add the troubleshooting entry**

Insert immediately after the **Host metrics show container values.** paragraph
(currently ends line 411), before **Forgejo `/metrics` returns 404.**:

````markdown
**`up{instance="pve"} == 0`.** Work outwards from the host. On the Proxmox
host:

```bash
systemctl is-active prometheus-node-exporter
```

If that reports `active`, suspect **DNS before the exporter**:

```bash
docker compose exec grafana getent hosts pve.thefipster.de
```

It must answer `192.168.1.40`. If it answers `192.168.1.42`, the exact
`pve.thefipster.de` record is missing and the `*.thefipster.de` wildcard is
catching the name — Alloy has been scraping the apps VM this whole time. Add
the record ([dns-records.md](dns-records.md)); nothing here needs restarting,
since the name is re-resolved on every scrape.

If the name resolves correctly and the exporter is running, check the Proxmox
firewall (*Datacenter → Firewall*). It is off by default, but if it was
enabled it needs to allow `192.168.1.41` to reach `:9100`.
````

- [ ] **Step 12: Add the Proxmox row to "What each stack had to enable"**

In the table at ~line 500-505, add a final row after `Monitoring`:

```
| Proxmox host | Debian's `prometheus-node-exporter` on `:9100` — a systemd unit, not a stack |
```

- [ ] **Step 13: Correct the `job`/`instance` explanation in "How it works"**

Replace (lines ~539-541):

```
**Metric targets use the idiomatic `job` label** (the host exporter as
`job="node"` with `instance="infra"`), which is exactly what community
dashboards assume
```

with:

```
**Metric targets use the idiomatic `job` label** (both host exporters as
`job="node"`, told apart by `instance` — `infra` and `pve`), which is exactly
what community dashboards assume
```

- [ ] **Step 14: Add the design note about scraping the hypervisor natively**

Insert as its own paragraph immediately after the paragraph edited in Step 13
(the one ending "...re-vendoring the JSON in the repo, not editing in the
browser."):

```
**The Proxmox host is scraped natively, not through a container.** It runs
Debian's `prometheus-node-exporter` as a systemd unit, so the hypervisor stays
a hypervisor with no Docker on it — which makes it the only scrape target in
the lab that is not a container, and the only one addressed by hostname rather
than by Docker service name. An LXC container would have been the "native
Proxmox" option and reports the wrong numbers: PVE virtualizes `/proc` through
lxcfs, so the exporter would measure the container rather than the host. A
second Alloy on the hypervisor would work and would also bring PVE's journald
into Loki — that, not this, is the reason to reach for it later.

**The host exporter takes no authentication either.** `:9100` on the
hypervisor answers any LAN client with its filesystems, kernel version and
network devices. Same reasoning as the OTLP endpoint above and a smaller
surface — it only *reads* — but it is a real widening of what the Proxmox host
serves, so it is stated rather than left implicit. To close it, bind the
exporter to `192.168.1.40` in `/etc/default/prometheus-node-exporter` and add a
Proxmox firewall rule allowing only the infra VM.
```

- [ ] **Step 15: Verify the guide holds together**

Run:

```bash
grep -n 'instance="infra"\|instance="pve"\|job="node"\|one series per' docs/grafana-setup.md
```

Expected: no surviving claim that there is a single host exporter, and every
`instance` reference matching the values Task 1 set.

- [ ] **Step 16: Commit**

```bash
git add docs/grafana-setup.md
git commit -m "Document adding the Proxmox host to the node dashboard"
```

---

### Task 3: CLAUDE.md note and repo-wide consistency sweep

**Files:**
- Modify: `CLAUDE.md` (the "Conventions & gotchas that aren't obvious from a single file" bullet list)

**Interfaces:**
- Consumes: everything from Tasks 1 and 2.
- Produces: nothing — terminal task.

- [ ] **Step 1: Add the gotcha bullet**

Append to the bullet list under **Conventions & gotchas that aren't obvious
from a single file**, after the `Mounted docker.sock` bullet:

```
- **The Proxmox host is a scrape target — the only one that isn't a
  container.** It runs Debian's `prometheus-node-exporter` as a systemd unit
  (`apt install`, documented in `grafana-setup.md` step 6; **no init script**,
  because the hypervisor has no checkout of this repo), and Alloy scrapes it at
  `pve.thefipster.de:9100`. Both hosts carry `job="node"` and are told apart by
  `instance` (`infra`, `pve`) — that shared job label is what puts them both on
  the vendored Node Exporter Full dashboard with no edit to its JSON. It is
  also why `dns-records.md` no longer marks that record optional: without the
  exact record the `*.thefipster.de` wildcard answers with the apps VM and
  Alloy silently scrapes the wrong box, which looks exactly like a dead
  exporter.
```

- [ ] **Step 2: Sweep for stale single-host claims across the repo**

Run:

```bash
grep -rn 'instance="infra"\|the host exporter\|and the host' --include=*.md --include=*.alloy . | grep -v 'docs/superpowers\|docs/review'
```

Expected: every hit is either correct in context or already updated. Historical
records under `docs/superpowers/` and `docs/review/` are excluded on purpose —
they must not be retro-edited.

- [ ] **Step 3: Confirm no line endings were rewritten**

Run:

```bash
git diff --cached --stat && git ls-files --eol infra/monitoring/alloy/config.alloy docs/grafana-setup.md docs/dns-records.md CLAUDE.md
```

Expected: all four files report `w/lf`. Any `w/crlf` means an editor rewrote
them — fix before committing.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Record the Proxmox scrape target in CLAUDE.md"
```

---

## What is deliberately not in this plan

- **No change to `infra/monitoring/compose.yaml`.** Alloy needs no new mount,
  network or port to reach a LAN address outbound.
- **No change to `node-exporter-full.json`.** The dashboard works unmodified;
  that is the point.
- **No change to `rules.yaml`.** `DiskAlmostFull` and `ServiceDown` match
  `job="node"` and `up` unfiltered, so they pick up the new host by
  construction. Widened coverage is the intended outcome (spec, "Constraints &
  decisions made").
- **No init script.** See Task 2 Step 2 and the spec.
- **No `docs/roadmap/monitoring.md` edit.** That file holds forward-looking
  plans; this work lands in the guide immediately, and its five phases remain
  an accurate record of what was built.

## Runtime verification (on the VMs, after merge)

Not executable from the Windows workstation. In order:

1. On the Proxmox host: `systemctl is-active prometheus-node-exporter` → `active`
2. On the infra VM: `docker compose exec grafana getent hosts pve.thefipster.de` → `192.168.1.40`
3. `git pull` on the infra VM, then `docker compose up -d alloy`
4. Grafana → Explore → Prometheus: `up{job="node"}` → two series, both `1`
5. Grafana → Dashboards → Node Exporter Full: **Nodename** offers two entries
   and the panels redraw when switching
