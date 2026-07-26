# Three-machine lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document the apps VM (Coolify) and a new home-assistant VM as first-class machines, move the machine dimension to the repo root, re-size all three VMs for a 32-thread / 64 GB / 2 TB host, and rebuild the README diagram.

**Architecture:** Docs-and-declarative-config only — there is no application to build. The repo root becomes the machine map (`infra/`, `apps/`, `home-assistant/`) while `docs/` and `scripts/` stay flat so no path reference breaks. Two real config changes carry the rest: Traefik gains a **file provider** (a service on another VM has no container to hang labels on), and Alloy gains two off-box scrape targets following the existing `proxmox_host` pattern.

**Tech Stack:** Proxmox VE 8/9 (KVM), Docker Compose, Traefik v3, Grafana Alloy, Home Assistant OS, Coolify, bash, Markdown.

**Spec:** [2026-07-26-three-machine-lab-design.md](../specs/2026-07-26-three-machine-lab-design.md)

## Global Constraints

- **No test suite exists.** CLAUDE.md: "correctness is verified by reading, not by executing locally." Verification in this plan means syntax gates + consistency greps, never "run the app."
- **Line endings: LF everywhere**, enforced by `.gitattributes`. `*.sh` must stay LF or shebangs break on the VM.
- **Image pins stay major-only** (`traefik:v3`, `postgres:16-alpine`, …) except the four documented exceptions (Authentik `2025.6`, `grafana/grafana:13.1`, `grafana/alloy:v1.18.0`, `grafana/tempo:2.9.4`). This plan bumps nothing.
- **No per-router TLS labels, ever.** The entrypoint-level `tls.domains` wildcard in `infra/traefik/compose.yaml` covers every `websecure` router, file-provider routers included.
- **Every guide command gets its own fenced block.** No `&&`-chained multi-step blocks in docs.
- **Guide structure is fixed** (CLAUDE.md): headline; `**Runs on:**`; one-line prerequisite linking the previous guide; short explanation; numbered steps with verification; jump-off to next; troubleshooting; layout on the server; detailed explanation; jump-off repeated.
- **Guides describe from-scratch bring-up of the current checkout.** No migration paths, no phase history, no `git pull` outside the initial clone.
- **`docs/superpowers/**` and `docs/review/**` are historical records** — never retro-edit them. This plan's own spec and plan files are the only exception (they are being authored now).
- **Scripts:** `set -euo pipefail`, `run_root()` helper, paths resolved from `$BASH_SOURCE`, re-runnable, closing next-steps block.
- **Exact hostnames/IPs:** Proxmox `pve.thefipster.de` `192.168.1.40`; infra `192.168.1.41`; apps `192.168.1.42`; home-assistant `192.168.1.43`; HA URL `ha.thefipster.de` → **`.41`** (not `.43`).

### Verification commands available on this machine

```bash
bash -n scripts/<name>.sh
```

```bash
python -c "import yaml,sys; yaml.safe_load(open(sys.argv[1])); print('yaml ok')" <file>
```

```bash
cd infra/<stack> && docker compose config --quiet
```

`docker compose config` validates schema without a daemon. `infra/monitoring` has no local `.env`, so supply required vars inline (shown in the task that needs it). There is **no** `shellcheck` and **no** running Docker daemon, so `alloy fmt` is unavailable — the Alloy config is gated by a brace-balance check plus review against the upstream argument names confirmed in the spec.

### Shared link-checker

Several tasks reuse this. Create it once, in the scratchpad (not the repo):

```bash
cat > "$SCRATCH/linkcheck.py" <<'PY'
import re, sys, pathlib
root = pathlib.Path('.').resolve()
bad = []
for md in root.rglob('*.md'):
    if '.git' in md.parts:
        continue
    text = md.read_text(encoding='utf-8')
    for m in re.finditer(r'\[[^\]]*\]\(([^)#\s]+)(?:#[^)\s]*)?\)', text):
        target = m.group(1)
        if target.startswith(('http://', 'https://', 'mailto:')):
            continue
        if not (md.parent / target).exists():
            bad.append(f'{md.relative_to(root)} -> {target}')
for b in bad:
    print(b)
print(f'{len(bad)} broken relative link(s)')
sys.exit(1 if bad else 0)
PY
```

`$SCRATCH` = `C:\Users\felix\AppData\Local\Temp\claude\C--Users-felix-Source-home-lab\c90f7695-2b37-4d65-8487-4c5ee81df295\scratchpad`.

Run the baseline **before Task 1** and record the count — the repo may already have broken links, and the gate is "no *new* ones":

```bash
python "$SCRATCH/linkcheck.py"
```

---

## File Structure

**New files**

| Path | Responsibility |
|---|---|
| `docs/home-assistant-setup.md` | HA VM guide: qcow2 import, UEFI, Traefik route, config fragment |
| `docs/coolify-setup.md` | apps VM guide: init-host, init-coolify, onboarding, wildcard cert |
| `scripts/init-coolify.sh` | apps VM: preflight, swap, vendor installer, `apps/.env` seed |
| `scripts/init-node-exporter.sh` | machine-agnostic node_exporter unit; apps VM is its only caller |
| `apps/.env.example` | `NETCUP_*` names Coolify's proxy needs for its own DNS-01 |
| `home-assistant/README.md` | what lives here and why there is no compose file |
| `home-assistant/configuration.yaml` | fragment **appended** inside HAOS (`http:`, `prometheus:`) |
| `infra/traefik/dynamic/ha.yaml` | file-provider router for `ha.thefipster.de` → `.43:8123` |

**Modified files**

| Path | Change |
|---|---|
| `README.md` | diagram, build order by machine, layout, architecture table, status |
| `CLAUDE.md` | topology, guide skeleton, deploy order, SSO exception #2, file provider, new scripts |
| `docs/proxmox-setup.md` | three VMs, new sizings, apps VM runs `init-host.sh`, chrony drop-in removed |
| `docs/dns-records.md` | `.43` reservation, `ha.` row, Coolify non-row |
| `docs/sso-applications.md` | HA as stated exception #2 |
| `docs/traefik-setup.md` | file provider, `dynamic/` in the server layout |
| `docs/grafana-setup.md` | HA token, apps node exporter, expected-red note |
| `docs/uptime-kuma-setup.md` | two new monitors |
| `apps/README.md` | rewritten from "planned" to real |
| `infra/traefik/compose.yaml` | file provider flags + `dynamic/` read-only mount |
| `infra/monitoring/compose.yaml` | `HA_PROMETHEUS_TOKEN` passthrough to `alloy` |
| `infra/monitoring/.env.example` | `HA_PROMETHEUS_TOKEN` |
| `infra/monitoring/alloy/config.alloy` | apps + HA scrape targets |
| `infra/authentik/compose.yaml` | commented HA non-integration marker |
| all `docs/*.md` | `**Runs on:**` line |

**Task order rationale:** labels first (mechanical, touches every guide, so it must not race a rewrite); then the registry, because the repo's own convention is that a new hostname gets its row first; then config changes; then the two new guides; then monitoring; then README and CLAUDE.md last, because both link and summarize everything above.

---

## Task 1: `Runs on:` labels and the guide-skeleton rule

Adds the machine dimension to every guide and records the rule that makes it mandatory. Mechanical and touches 12 files, so it goes first — no later task has to merge into it.

**Files:**
- Modify: `docs/proxmox-setup.md`, `docs/wildcard-dns-udr.md`, `docs/dns-records.md`, `docs/traefik-setup.md`, `docs/authentik-setup.md`, `docs/sso-applications.md`, `docs/dockge-setup.md`, `docs/forgejo-setup.md`, `docs/grafana-setup.md`, `docs/uptime-kuma-setup.md`
- Modify: `CLAUDE.md` (the "Every guide follows the same structure" paragraph in *Docs layout*)

**Interfaces:**
- Produces: the exact label strings later tasks must reuse for the two new guides — `**Runs on:** apps VM` and `**Runs on:** home-assistant VM`.

- [ ] **Step 1: Record the baseline broken-link count**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: some count `N` (possibly 0). Note it; every later link check must not exceed `N`.

- [ ] **Step 2: Insert the label into each guide**

Directly after the `# Headline` line and its blank line, before the existing prerequisite sentence. Exact values:

| File | Label |
|---|---|
| `docs/proxmox-setup.md` | `**Runs on:** the bare server, then the Proxmox host shell` |
| `docs/wildcard-dns-udr.md` | `**Runs on:** the UniFi Dream Router` |
| `docs/dns-records.md` | `**Runs on:** the UniFi Dream Router — registry, not a build step` |
| `docs/traefik-setup.md` | `**Runs on:** infra VM` |
| `docs/authentik-setup.md` | `**Runs on:** infra VM` |
| `docs/sso-applications.md` | `**Runs on:** Authentik on the infra VM — registry, not a build step` |
| `docs/dockge-setup.md` | `**Runs on:** infra VM` |
| `docs/forgejo-setup.md` | `**Runs on:** infra VM` |
| `docs/grafana-setup.md` | `**Runs on:** infra VM` |
| `docs/uptime-kuma-setup.md` | `**Runs on:** infra VM` |

- [ ] **Step 3: Verify every guide carries exactly one label**

```bash
for f in docs/*.md; do printf '%-34s %s\n' "$f" "$(grep -c '^\*\*Runs on:\*\*' "$f")"; done
```

Expected: every file listed above prints `1`. No `docs/*.md` prints `2` or more.

- [ ] **Step 4: Verify no links broke**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: count ≤ the baseline `N` from Step 1.

- [ ] **Step 5: Update the CLAUDE.md guide-skeleton paragraph**

In the *Docs layout* section, change the structure sentence to include the new line. Replace:

> **Every guide follows the same structure**, in this order: headline;
> one-line prerequisite linking the previous guide (never a restatement of it);

with:

> **Every guide follows the same structure**, in this order: headline; a
> `**Runs on:** <machine>` line naming the machine whose shell you are in (the
> two registries say `— registry, not a build step` instead, because they
> describe manual operations that span machines); one-line prerequisite linking
> the previous guide (never a restatement of it);

- [ ] **Step 6: Commit**

```bash
git add docs/ CLAUDE.md && git commit -m "Label every guide with the machine it runs on

Four machines now have guides, so 'which shell am I in' stops being
inferable from context. Adds a Runs on: line to the guide skeleton and to
all ten existing guides; the two registries say so explicitly rather than
naming a machine, since they describe manual operations that span them."
```

---

## Task 2: DNS registry — the `.43` reservation, the `ha.` row, and Coolify's non-row

The repo's stated convention is that a new hostname gets its registry row **before** anything routes to it, so this precedes the Traefik change. All three `dns-records.md` edits land here so no later task touches the file.

**Files:**
- Modify: `docs/dns-records.md`

**Interfaces:**
- Produces: `ha.thefipster.de` → `192.168.1.41` as the authoritative record. Tasks 4, 6 and 8 must match this — the record points at the **infra VM**, not the HA VM.

- [ ] **Step 1: Add the HA VM to the DHCP reservations table**

Append one row:

```markdown
| home-assistant VM | `192.168.1.43` |
```

- [ ] **Step 2: Add the `ha.` record row**

Insert into the Records table, after the `uptime.` row:

```markdown
| `ha.thefipster.de` | `192.168.1.41` | Home Assistant UI (Traefik proxies to the HA VM at `.43:8123`) |
```

- [ ] **Step 3: Document Coolify's deliberate non-row**

After the existing paragraph that begins "An exact host record **beats the wildcard**", add:

```markdown
**Two rows that look missing and are not.** `coolify.thefipster.de` has no exact
record on purpose — the `*.thefipster.de` wildcard already sends it to the apps
VM, and Coolify's own proxy routes it by `Host` header like any app it hosts.
And `ha.thefipster.de` points at the **infra VM**, not at the HA VM: Traefik
terminates TLS there with the lab's one wildcard certificate and proxies to
`192.168.1.43:8123`. Pointing it at `.43` directly would reach Home Assistant
over plain HTTP with no certificate at all.
```

- [ ] **Step 4: Verify the record table is internally consistent**

```bash
grep -nE '192\.168\.1\.4[0-3]' docs/dns-records.md
```

Expected: `.40` for pve, `.41` for every infra service **and `ha.`**, `.42` for the wildcard, `.43` only in the reservation table and inside the two explanatory prose blocks.

- [ ] **Step 5: Commit**

```bash
git add docs/dns-records.md && git commit -m "Register the home-assistant VM and explain two absent rows

Adds the .43 reservation and ha.thefipster.de. The record points at the
infra VM, not the HA VM, because Traefik terminates TLS with the lab's one
wildcard cert and proxies onward — the opposite of how Coolify's names
work, so both that and Coolify's deliberately absent exact record are
stated outright. This registry exists to stop a missing row surfacing
later as a 404 behind a valid certificate; an unexplained one does the
same damage."
```

---

## Task 3: Proxmox guide — three VMs and the new sizings

**Files:**
- Modify: `docs/proxmox-setup.md` (topology block at the top; Part 5; Part 6; Part 7; Part 8)

**Interfaces:**
- Consumes: the `.43` reservation from Task 2.
- Produces: the sizing table other guides reference; the promise that the apps VM has a repo checkout at `~/home-lab` and has run `init-host.sh` (Task 5 depends on both).

- [ ] **Step 1: Update the topology block at the top of the guide**

Replace the existing three-line tree with:

```
Proxmox VE  (pve.thefipster.de · .40)   ← this guide
 ├─ VM: infra           (.41)  → Traefik + Authentik + Forgejo + Dockge + monitoring
 ├─ VM: apps            (.42)  → Coolify + your apps
 └─ VM: home-assistant  (.43)  → Home Assistant OS (Supervisor + add-ons)
```

- [ ] **Step 2: Replace Part 5's spec table**

Retitle Part 5 to `Part 5 — Create the VMs` and replace the table with:

```markdown
| Setting | infra VM | apps VM (Coolify) | home-assistant VM |
|---|---|---|---|
| Name | `infra` | `apps` | `homeassistant` |
| VMID | 101 | 102 | 103 |
| IP | `192.168.1.41` | `192.168.1.42` | `192.168.1.43` |
| Cores | 32 | 32 | 32 |
| CPU type | `host` | `host` | `host` |
| `cpuunits` | 100 (default) | 50 | 200 |
| Memory | 16384 MB | 24576 MB | 8192 MB |
| Ballooning | off | off | off |
| Disk | 150 GB | 500 GB | 64 GB |
| BIOS / machine | SeaBIOS / `q35` | SeaBIOS / `q35` | **OVMF** / `q35` |
| Network | bridge `vmbr0`, VirtIO | bridge `vmbr0`, VirtIO | bridge `vmbr0`, VirtIO |
| OS | Ubuntu Server 26.04 ISO | Ubuntu Server 26.04 ISO | Home Assistant OS image |
```

Then, immediately after the table:

```markdown
**Only the first two are built with the Create VM wizard below.** The
home-assistant VM needs a UEFI firmware and an imported disk image rather than
an ISO installer, so its creation lives in its own guide —
[home-assistant-setup.md](home-assistant-setup.md). Its row is here so the whole
host budget is visible in one place.
```

- [ ] **Step 3: Add the sizing rationale below the fold**

The guide is doing-path-first, so this goes in a new section **after** Part 8, before the cloud-init optional section. Heading `## Why these sizes`. It must state, in prose:

- 96 vCPU over 32 threads is deliberate 3:1 overcommit — three workloads that each spike (CI compiles, ESPHome firmware builds, user load) and rarely spike together. The boundary that degrades performance is a *single* VM wider than the host; 32 = 32 stays on the right side of it.
- `cpuunits` is a **relative** scheduler weight, clamped `[1, 10000]`, default **100** under cgroup v2 (Proxmox 8/9). HA outweighs apps 4:1 so a runaway Coolify build cannot make home automation laggy. `cpulimit` stays 0 — nothing is capped.
- Ballooning is off because 16+24+8 = 48 GB of ~60 GB usable: the sum of maxima does not exceed physical RAM, so the balloon driver's only possible action is reclaiming memory from a VM mid-compile. The ~12 GB left over is the growth pool.
- infra 10 → 16 GB because the Forgejo runner compiles beside six monitoring containers, Authentik and two Postgres instances; the old 10 GB predates the monitoring stack.
- infra 40 → 150 GB for Prometheus 15 d / Loki 14 d / Tempo 7 d plus the container registry, which today accumulates an image per CI run — registry retention is owned by the CI roadmap, so 150 GB buys time rather than absorbing growth forever.
- The 2 TB is dedicated to VM disks; snapshots, `vzdump` backups and Proxmox itself get separate storage. 714 GB provisioned leaves ~1.3 TB of headroom.
- These are a starting point that the final storage layout will revise.
- The `DiskAlmostFull` alert reads `node_filesystem_*` and therefore cannot see the LVM thin pool; checking that is `lvs` on the host.

- [ ] **Step 4: Point Part 6 and Part 7 at all three machines**

Part 6 (in-guest setup): note that HAOS ships the guest agent already, so the `qemu-guest-agent` install applies to the two Ubuntu VMs only.

Part 7: retitle to `Part 7 — Repo and Docker on the infra and apps VMs`. Replace the closing paragraph

> The **apps VM** needs none of this — Coolify installs its own Docker via its
> install script.

with:

```markdown
Do the same on the **apps VM**. Coolify's installer would install Docker itself,
but running `init-host.sh` there first is still the right move: Coolify accepts a
pre-existing Docker Engine (it only installs one when absent), and the script
carries the time-sync fix from [Part 8](#part-8--snapshot-before-you-build) that
a snapshot rollback otherwise leaves you to apply by hand.

The **home-assistant VM** needs neither — HAOS is an appliance with no shell of
ours in it. Its clock is managed by the OS image.
```

- [ ] **Step 5: Delete the now-redundant manual chrony drop-in from Part 8**

Remove the final block of the Part 8 blockquote — the paragraph beginning "The **apps VM** never runs `init-host.sh`" and the two fenced commands under it. Replace with:

```markdown
> Both Ubuntu VMs run `init-host.sh` (Part 7), so both are already fixed. The
> home-assistant VM is not: if you snapshot it — you should — force a resync
> from HA's own terminal after a rollback, or simply reboot the VM.
```

- [ ] **Step 6: Verify the guide no longer claims two VMs**

```bash
grep -nEi 'two VMs|both VMs|the two (infra|apps)' docs/proxmox-setup.md
```

Expected: no hit that still means "the lab has two VMs". `both Ubuntu VMs` in Step 5's replacement is correct and may appear.

- [ ] **Step 7: Verify links still resolve**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: `docs/proxmox-setup.md -> home-assistant-setup.md` is the **only** new break (that file arrives in Task 6). Count = baseline + 1.

- [ ] **Step 8: Commit**

```bash
git add docs/proxmox-setup.md && git commit -m "Size all three VMs for the 32-thread / 64 GB / 2 TB host

Adds the home-assistant VM to the topology and the spec table, and raises
the other two off numbers that predate the monitoring stack. All 32
threads go to all three VMs on purpose — 3:1 overcommit is right for
workloads that each spike and rarely spike together — with cpuunits, not
core count, arbitrating a collision so an apps-VM build storm cannot make
home automation laggy. Ballooning is off because the sum of maxima fits in
physical RAM, leaving the driver nothing useful to do and one harmful
thing.

The apps VM now runs init-host.sh, which deletes the manual chrony
drop-in Part 8 used to hand you."
```

---

## Task 4: Traefik file provider and the HA router

The one structural change to a stack that already works. `infra/traefik/` is symlinked into `/opt/stacks`, and Compose resolves relative paths against the compose file's own directory through that symlink — so a `./dynamic` mount needs no change to `init-traefik.sh`.

**Files:**
- Create: `infra/traefik/dynamic/ha.yaml`
- Modify: `infra/traefik/compose.yaml` (providers block, volumes block)
- Modify: `docs/traefik-setup.md` (routing convention section, server-layout table)

**Interfaces:**
- Consumes: `ha.thefipster.de` → `.41` from Task 2.
- Produces: the router name `ha` and the backend URL `http://192.168.1.43:8123`, both referenced by Task 6's guide.

- [ ] **Step 1: Add the file provider flags to the compose command list**

In `infra/traefik/compose.yaml`, under `# --- providers ---`, after the three `--providers.docker*` lines:

```yaml
      # A second provider for services that are NOT containers on this VM and
      # therefore have no labels to read — currently just Home Assistant, on
      # its own VM at .43. Watched, so editing a file in dynamic/ takes effect
      # without restarting Traefik.
      - --providers.file.directory=/etc/traefik/dynamic
      - --providers.file.watch=true
```

- [ ] **Step 2: Mount the dynamic directory read-only**

In the same file's `volumes:` block, after the `acme.json` mount:

```yaml
      # Dynamic (file-provider) routers. Read-only: the repo stays the source
      # of truth, same arrangement as Forgejo's config.yml.
      - ./dynamic:/etc/traefik/dynamic:ro
```

- [ ] **Step 3: Create the HA router**

`infra/traefik/dynamic/ha.yaml`:

```yaml
# Home Assistant — the lab's only file-provider router.
#
# HA runs on its OWN VM (192.168.1.43), so there is no container here for the
# Docker provider to read labels from. Hence this file. ha.thefipster.de
# resolves to the INFRA VM (.41) and Traefik proxies onward — see
# docs/dns-records.md.
#
# No TLS section: the websecure entrypoint's tls.domains wildcard in
# compose.yaml covers every router on it, this one included. Adding a resolver
# or a domain here would be the mistake the routing convention exists to
# prevent.
#
# WebSocket upgrade needs no configuration — Traefik passes it through, which
# is what makes the HA frontend work at all.
#
# DELIBERATELY NO `middlewares` KEY. Home Assistant has no OIDC, so the SSO
# convention would point at the authentik@docker forward-auth middleware. It is
# not applied: forward-auth breaks the companion mobile app, webhooks and every
# local API caller, and the break-glass would be editing this file over SSH
# mid-incident in a house whose lights just stopped responding. HA keeps its own
# local login. Second stated exception after Uptime Kuma —
# see docs/sso-applications.md.

http:
  routers:
    ha:
      rule: Host(`ha.thefipster.de`)
      entrypoints: websecure
      service: ha

  services:
    ha:
      loadBalancer:
        servers:
          # Plain HTTP over the LAN, terminated with TLS by Traefik above.
          - url: http://192.168.1.43:8123
```

- [ ] **Step 4: Validate both files**

```bash
python -c "import yaml,sys; yaml.safe_load(open('infra/traefik/dynamic/ha.yaml')); print('yaml ok')"
```

Expected: `yaml ok`

```bash
cd infra/traefik && docker compose config --quiet
```

Expected: exit 0, no output.

- [ ] **Step 5: Confirm no per-router TLS crept in**

```bash
grep -niE 'certresolver|tls' infra/traefik/dynamic/ha.yaml
```

Expected: matches **only** inside comment lines. No YAML key.

- [ ] **Step 6: Document it in `traefik-setup.md`**

Two edits:

1. In the routing-convention section (the part that currently says a stack becomes reachable by joining `proxy` and adding labels), add that there is now a **second** way, used by exactly one service: a file in `infra/traefik/dynamic/`, for backends that are not containers on this VM. State that the label path remains the default and that the file path exists because HA is on another VM.
2. In the "layout on the server" table, add a row:

```markdown
| Dynamic routers (this repo) | `infra/traefik/dynamic/` | mounted read-only; watched, so edits apply without a restart |
```

- [ ] **Step 7: Commit**

```bash
git add infra/traefik docs/traefik-setup.md && git commit -m "Give Traefik a file provider for the Home Assistant VM

Traefik ran the Docker provider only, which cannot see a service on
another machine — there is no container to read labels from. A watched
file provider over infra/traefik/dynamic/ fixes that with one router.

The router carries no TLS section and no middlewares key, both
deliberately: the entrypoint wildcard already covers it, and gating HA
behind forward-auth would break the companion app and every local API
caller for a break-glass that means SSH mid-incident."
```

---

## Task 5: Coolify on the apps VM

**Files:**
- Create: `scripts/init-coolify.sh`, `scripts/init-node-exporter.sh`, `apps/.env.example`, `docs/coolify-setup.md`
- Modify: `apps/README.md` (full rewrite)

**Interfaces:**
- Consumes: the apps VM has a `~/home-lab` checkout and has run `init-host.sh` (Task 3, Part 7).
- Produces: `scripts/init-node-exporter.sh` installing a systemd unit listening on `:9100` — Task 7 adds the Alloy target that scrapes it as `job="node", instance="apps"`.

- [ ] **Step 1: Write `apps/.env.example`**

```bash
# Coolify's bundled proxy issues its OWN Let's Encrypt wildcard for
# *.thefipster.de via the netcup DNS-01 challenge — the same mechanism and the
# same credentials as Traefik on the infra VM, but a separate certificate and a
# separate ACME account. Nothing is exposed to the internet either way.
#
# These values are entered in Coolify's WEB UI, not read from this file: Coolify
# owns its own configuration store. The file exists so the requirement is
# visible in the repo instead of living only inside Coolify — copied to
# apps/.env by scripts/init-coolify.sh, gitignored like every other .env.
#
# Same netcup caveats as infra/traefik/.env: propagation is slow (~10 min), and
# a wildcard with no apex SAN avoids two TXT records racing at the same
# _acme-challenge FQDN. See docs/traefik-setup.md.

NETCUP_CUSTOMER_NUMBER=
NETCUP_API_KEY=
NETCUP_API_PASSWORD=
```

- [ ] **Step 2: Write `scripts/init-node-exporter.sh`**

```bash
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
```

- [ ] **Step 3: Write `scripts/init-coolify.sh`**

```bash
#!/usr/bin/env bash
#
# init-coolify.sh — install Coolify (self-hosted PaaS) on the APPS VM.
#
# Assumes Docker is installed (run scripts/init-host.sh first — see
# docs/proxmox-setup.md Part 7). Steps:
#   1. Preflight: OS family, Docker Engine version, free disk, RAM.
#   2. Create a swapfile if none is active.
#   3. Fetch Coolify's official installer to a temp file, show where it came
#      from and its sha256, then run it.
#   4. Seed apps/.env from apps/.env.example if missing.
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

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-host.sh first." >&2
  exit 1
fi

# Coolify requires Engine >= 24. init-host.sh installs current docker-ce, so
# this only trips if Docker came from somewhere unexpected.
DOCKER_MAJOR="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || true)"
if [ -z "$DOCKER_MAJOR" ]; then
  echo "    WARNING: could not read the Docker Engine version (daemon down?)."
elif [ "$DOCKER_MAJOR" -lt 24 ]; then
  echo "Docker Engine ${DOCKER_MAJOR} is too old — Coolify needs 24 or newer." >&2
  exit 1
else
  echo "    Docker Engine major: ${DOCKER_MAJOR}"
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

# --- 3. install -------------------------------------------------------------

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

# --- 4. .env ----------------------------------------------------------------

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
echo "  2. Fill in ${APPS_DIR}/.env with your netcup credentials, then enter"
echo "     the same values in Coolify's UI so its proxy can issue the"
echo "     *.thefipster.de wildcard via DNS-01. Coolify keeps its own config"
echo "     store; the file is the repo's record of what is needed."
echo "  3. Install the host metrics exporter so the infra VM can watch this"
echo "     machine:  scripts/init-node-exporter.sh"
echo "  4. coolify.thefipster.de needs NO DNS record — the *.thefipster.de"
echo "     wildcard already points here. See docs/dns-records.md."
```

- [ ] **Step 4: Verify both scripts parse and are LF**

```bash
bash -n scripts/init-coolify.sh && bash -n scripts/init-node-exporter.sh && echo "syntax ok"
```

Expected: `syntax ok`

```bash
file scripts/init-coolify.sh scripts/init-node-exporter.sh
```

Expected: no "with CRLF line terminators".

- [ ] **Step 5: Verify house style is present in both**

```bash
grep -cE 'set -euo pipefail|run_root\(\)' scripts/init-coolify.sh scripts/init-node-exporter.sh
```

Expected: `2` for each file.

- [ ] **Step 6: Write `docs/coolify-setup.md`**

Follow the fixed guide skeleton. Content per section:

- Headline `# Coolify (apps VM)`; `**Runs on:** apps VM`.
- Prerequisite: one line linking [uptime-kuma-setup.md](uptime-kuma-setup.md) as the previous step.
- Explanation: Coolify is a self-hosted PaaS that owns this VM's Docker and manages apps through its UI — which is why `apps/` has no compose file, unlike every `infra/` stack.
- Steps, each command in its own fence:
  1. Clone the repo and run `scripts/init-host.sh` (link Part 7 of proxmox-setup.md), then log out and back in for the `docker` group.
  2. `scripts/init-coolify.sh` — describe what it does, that it prints the installer's checksum before running it, and that it creates a 4 GB swapfile.
  3. Open `http://192.168.1.42:8000` and create the admin account immediately.
  4. Set the instance domain to `coolify.thefipster.de` and note that **no DNS record is needed** — link `dns-records.md`.
  5. Give Coolify's proxy the netcup credentials so it issues its own `*.thefipster.de` wildcard; cross-link `traefik-setup.md` for the netcup caveats (900 s propagation, no apex SAN) rather than restating them.
  6. `scripts/init-node-exporter.sh`, and point at `grafana-setup.md` for confirming `instance="apps"` appears.
- Jump-off: [home-assistant-setup.md](home-assistant-setup.md).
- Troubleshooting: installer refuses on OS version (the warning is expected on 26.04); "30 GB free" failure; port 8000 unreachable; the wildcard cert not issuing (netcup propagation).
- Layout on the server: Coolify's own directories, plus `apps/.env` in the repo checkout.
- Detailed explanation: why two certificates exist in the lab rather than sharing one (Coolify's proxy is not Traefik on the infra VM and cannot read its `acme.json`); why Coolify wants root; why app definitions are not in this repo.
- Jump-off repeated.

- [ ] **Step 7: Rewrite `apps/README.md`**

Replace the "Planned" framing entirely. It must state: Coolify runs here; there is no compose file by design and why; `.env.example` documents the netcup names Coolify's UI consumes; the guide is [docs/coolify-setup.md](../docs/coolify-setup.md); the two scripts that run on this machine are `init-host.sh` and `init-coolify.sh`, plus `init-node-exporter.sh` for monitoring.

- [ ] **Step 8: Verify links**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: the only new break is `docs/coolify-setup.md -> home-assistant-setup.md` (arrives in Task 6). Total = baseline + 1 (Task 3's break is now resolved only if Task 6 has run; if not, baseline + 2).

- [ ] **Step 9: Commit**

```bash
git add scripts/init-coolify.sh scripts/init-node-exporter.sh apps/ docs/coolify-setup.md && git commit -m "Bring up Coolify on the apps VM

The apps VM stops being a placeholder. init-coolify.sh preflights the box,
creates the swapfile Coolify recommends but does not make, then fetches
the vendor installer to disk and prints its source and sha256 before
running it as root — the same operation as curl|bash, except reviewable.

init-node-exporter.sh is separate and machine-agnostic on purpose: the
infra VM must NOT run it, because Alloy already collects host metrics
there, and folding it into init-host.sh would create a duplicate target.

apps/.env.example records the netcup names Coolify's proxy needs for its
own wildcard. The values live in Coolify's config store, so without the
file the requirement would be invisible in the repo."
```

---

## Task 6: The Home Assistant VM

**Files:**
- Create: `docs/home-assistant-setup.md`, `home-assistant/README.md`, `home-assistant/configuration.yaml`
- Modify: `docs/sso-applications.md`, `infra/authentik/compose.yaml`

**Interfaces:**
- Consumes: the `ha` router and backend URL from Task 4; the `ha.thefipster.de` row from Task 2.
- Produces: the instruction that HA's long-lived token goes into `infra/monitoring/.env` as `HA_PROMETHEUS_TOKEN` — Task 7 wires the variable.

- [ ] **Step 1: Write `home-assistant/configuration.yaml`**

```yaml
# Home Assistant configuration — FRAGMENT, NOT A FILE TO COPY OVER.
#
# This lives inside the HA VM at /config/configuration.yaml, which this repo
# cannot mount: HAOS is an appliance with no shell of ours in it. So the repo
# holds the fragment and you paste it by hand, exactly like
# infra/forgejo/build-and-push.yml, which belongs in an app repo rather than
# here.
#
# APPEND these blocks to the existing /config/configuration.yaml. Do NOT
# replace that file — a fresh HAOS install ships it with `default_config:` and
# overwriting it strips the entire default integration set. Both keys below are
# ones HAOS does not define itself, so appending cannot collide.
#
# Edit it from HA's File Editor or Studio Code Server add-on, then
# Developer Tools -> YAML -> Restart.
#
# See docs/home-assistant-setup.md.

# --- reachable through Traefik ----------------------------------------------
# ha.thefipster.de resolves to the INFRA VM (.41), where Traefik terminates TLS
# with the lab's wildcard certificate and proxies here over plain HTTP. Home
# Assistant refuses proxied requests unless it is told to trust the hop, with a
# 400 and a log line about an untrusted proxy — which reads like a Traefik fault
# and is not one.
#
# The address is the infra VM's LAN IP, NOT a Docker subnet: Traefik's container
# reaches this VM outbound through the Docker bridge, SNAT'd to its host's LAN
# address, so that is the source HA actually observes.
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.1.41

# --- metrics ----------------------------------------------------------------
# Exposes /api/prometheus, scraped by Alloy on the infra VM as
# job="homeassistant". These are ENTITY metrics — sensor states, not machine
# counters — so they do not belong on the Node Exporter Full dashboard. Add the
# System Monitor integration if you want this VM's CPU/RAM/disk in the same
# feed; HAOS cannot run a node exporter as a systemd unit.
#
# The endpoint requires a long-lived access token, minted in HA's own UI and
# stored in infra/monitoring/.env as HA_PROMETHEUS_TOKEN.
prometheus:
```

- [ ] **Step 2: Validate the fragment**

```bash
python -c "import yaml,sys; d=yaml.safe_load(open('home-assistant/configuration.yaml')); print(sorted(d)); assert sorted(d)==['http','prometheus']"
```

Expected: `['http', 'prometheus']` and no assertion error. (Confirms exactly the two top-level keys the header promises, so an append cannot duplicate a HAOS default.)

- [ ] **Step 3: Write `docs/home-assistant-setup.md`**

Fixed skeleton. Headline `# Home Assistant OS (home-assistant VM)`; `**Runs on:** the Proxmox host shell, then the HA VM's web UI`; prerequisite links [coolify-setup.md](coolify-setup.md).

Explanation: full HAOS with Supervisor, chosen so ESPHome and other add-ons install from the add-on store instead of being hand-assembled. State up front that this is **not** the ISO path from `proxmox-setup.md` — HAOS ships a qcow2 disk image and requires UEFI.

Steps, one command per fence:

1. On the Proxmox host, download the latest `haos_ova-*.qcow2.xz` and decompress it.
2. Create the VM in the wizard: machine `q35`, BIOS **OVMF**, add an EFI disk with **Pre-Enroll keys unchecked** (HA needs non-secureboot OVMF), delete the wizard's default disk, attach no CD-ROM, tick Qemu Agent, specs from the `proxmox-setup.md` table.
3. `qm importdisk 103 haos_ova-*.qcow2 local-lvm`
4. Attach the imported disk as SCSI on the VirtIO SCSI single controller, then set boot order to it.
5. `qm disk resize 103 scsi0 64G` — **before** first boot, because HAOS grows its data partition then.
6. Start, and onboard at `http://192.168.1.43:8123`.
7. Append the `home-assistant/configuration.yaml` fragment via the File Editor add-on, restart, and verify `https://ha.thefipster.de` now loads with a valid certificate.
8. Mint a long-lived access token (profile → Security → Long-lived access tokens) and put it in `infra/monitoring/.env` as `HA_PROMETHEUS_TOKEN` — link `grafana-setup.md` for restarting Alloy and confirming the target.

Jump-off: back to the [README build order](../README.md#build-order) — this is the last machine.

Troubleshooting: VM will not boot (SeaBIOS instead of OVMF, or secureboot OVMF); `ha.thefipster.de` returns 502 (HA VM down, or the wrong backend IP in the dynamic router); HA returns 400 with an untrusted-proxy log line (`trusted_proxies` missing or set to a Docker subnet instead of `192.168.1.41`); the frontend loads but stays blank (a websocket problem, though Traefik needs no config for it); `/api/prometheus` returns 401 (token wrong or absent).

Layout on the server: `/config` inside HAOS, and what the repo holds instead.

Detailed explanation: why UEFI; why `ha.` points at the infra VM and not `.43`; the file-provider router (link `traefik-setup.md`); the SSO exception (link `sso-applications.md`); **and that no USB passthrough is configured because the lab's Zigbee coordinators are Ethernet adapters** — stated explicitly, since "pass the USB stick through" is the standard HA-on-Proxmox advice and its absence would otherwise look like an omission.

- [ ] **Step 4: Write `home-assistant/README.md`**

Must state: this directory is the HA VM's corner of the repo; there is **no compose file and no init script** because HAOS is an appliance that manages itself through the Supervisor; the only file here is a configuration fragment that gets **appended** by hand inside the VM; the guide is [docs/home-assistant-setup.md](../docs/home-assistant-setup.md); HA is reached through Traefik on the infra VM and deliberately has no SSO — link [docs/sso-applications.md](../docs/sso-applications.md).

- [ ] **Step 5: Add HA as stated exception #2 in `sso-applications.md`**

The file already documents Uptime Kuma's non-integration. Add a parallel entry for Home Assistant covering: no native OIDC, so the convention points at forward-auth; not applied because it breaks the companion mobile app, webhooks and every local API caller; break-glass would be SSH mid-incident with the lights already down; HA keeps its own local login. Mark it, like Kuma, as a **stated exception rather than a gap to close**, and name the two files that carry the in-place comments (`infra/traefik/dynamic/ha.yaml`, `infra/authentik/compose.yaml`).

Also add a row to the applications table with method `none (local login)`.

- [ ] **Step 6: Add the in-place marker to `infra/authentik/compose.yaml`**

Next to the existing commented Uptime Kuma non-integration note, add a comment recording that there is deliberately no `/outpost.goauthentik.io/` router for `ha.thefipster.de` either, with a pointer to `docs/sso-applications.md`. Comment only — no YAML change.

- [ ] **Step 7: Verify the Authentik stack still parses**

```bash
cd infra/authentik && docker compose config --quiet
```

Expected: exit 0.

- [ ] **Step 8: Verify links, including the two Task 3/5 forward references**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: back to the baseline `N` — `docs/home-assistant-setup.md` now exists, resolving the breaks from Tasks 3 and 5.

- [ ] **Step 9: Commit**

```bash
git add docs/home-assistant-setup.md docs/sso-applications.md home-assistant/ infra/authentik/compose.yaml && git commit -m "Add the Home Assistant VM

Full HAOS with the Supervisor, so ESPHome and friends come from the
add-on store. Its bring-up deliberately looks nothing like the Ubuntu
VMs': HAOS ships a qcow2 disk image, requires non-secureboot UEFI, and is
resized before first boot because that is when it grows its data
partition.

Home Assistant becomes the lab's second stated SSO exception. It has no
OIDC, so the convention points at forward-auth — which would break the
companion app, webhooks and every local API caller, for a break-glass
that means SSH mid-incident. Recorded as a decision, with in-place
comments in the two files where someone would go to 'fix' it.

The configuration fragment is appended, never copied over: HAOS ships
that file with default_config: and replacing it strips the default
integration set."
```

---

## Task 7: Monitor both new machines

**Files:**
- Modify: `infra/monitoring/alloy/config.alloy`, `infra/monitoring/compose.yaml`, `infra/monitoring/.env.example`, `docs/grafana-setup.md`, `docs/uptime-kuma-setup.md`

**Interfaces:**
- Consumes: `:9100` on the apps VM (Task 5); `/api/prometheus` and the token instruction (Task 6).
- Produces: `job="node", instance="apps"` and `job="homeassistant"` series.

- [ ] **Step 1: Add the apps VM scrape target**

In `infra/monitoring/alloy/config.alloy`, directly after the `prometheus.scrape "proxmox_host"` block:

```
// The APPS VM — same shape as the Proxmox host above and for the same reason:
// not a container, reached outbound over the LAN, addressed by NAME so a host
// IP change corrects itself. Debian's prometheus-node-exporter as a systemd
// unit, installed by scripts/init-node-exporter.sh.
//
// NOTE the name: apps.thefipster.de is NOT a DNS record — the *.thefipster.de
// wildcard answers it, and the wildcard points at this VM, so the name happens
// to resolve correctly. That is fragile reasoning, so the LAN address is used
// directly here instead. This is the one target in the lab addressed by IP, and
// that is why.
//
// Same job="node" as infra and pve, distinct instance — which is the whole
// reason all three land on the vendored Node Exporter Full dashboard with no
// edit to its JSON.
prometheus.scrape "apps_host" {
  targets = [
    {"__address__" = "192.168.1.42:9100", "job" = "node", "instance" = "apps"},
  ]

  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

- [ ] **Step 2: Add the Home Assistant scrape target**

Immediately after the block from Step 1:

```
// HOME ASSISTANT — the only target that needs a credential, and the only one
// scraped over HTTPS through Traefik rather than directly.
//
// Going through ha.thefipster.de (rather than 192.168.1.43:8123) is deliberate:
// it is the same path a browser takes, so a broken route shows up here too
// instead of being silently bypassed. The wildcard certificate covers the name,
// and Alloy's image trusts public CAs, so no tls_config is needed.
//
// /api/prometheus requires a long-lived access token, minted in HA's own UI —
// which is why init-monitoring.sh does not generate this one. It arrives from
// infra/monitoring/.env via the alloy service's environment (see compose.yaml).
// An empty value yields 401s on every scrape and no series.
//
// These are ENTITY metrics (sensor states), NOT machine counters: job is
// "homeassistant", not "node", and Node Exporter Full will not show them.
prometheus.scrape "home_assistant" {
  targets = [
    {"__address__" = "ha.thefipster.de:443", "job" = "homeassistant"},
  ]

  scheme       = "https"
  metrics_path = "/api/prometheus"

  authorization {
    type        = "Bearer"
    credentials = sys.env("HA_PROMETHEUS_TOKEN")
  }

  scrape_interval = "60s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

Note the deliberate 60 s interval: entity states are not 15 s data, and HA's API is heavier than a node exporter.

- [ ] **Step 3: Verify the Alloy config's braces balance**

There is no `alloy fmt` available (no Docker daemon), so use a structural check:

```bash
python -c "
s=open('infra/monitoring/alloy/config.alloy').read()
d=0
for ch in s:
    if ch=='{': d+=1
    elif ch=='}': d-=1
    assert d>=0, 'unbalanced: closed too many'
print('brace depth at EOF:', d)
assert d==0
print('balanced ok')
"
```

Expected: `brace depth at EOF: 0` then `balanced ok`.

- [ ] **Step 4: Confirm the new blocks use only verified argument names**

```bash
grep -nE 'scheme|metrics_path|authorization|credentials|sys\.env' infra/monitoring/alloy/config.alloy
```

Expected: `scheme`, `metrics_path`, `authorization`, `credentials`, `sys.env` — all confirmed supported by `prometheus.scrape` and the Alloy stdlib. No `bearer_token` (the legacy spelling) and no invented argument.

- [ ] **Step 5: Pass the token through to Alloy**

In `infra/monitoring/compose.yaml`, on the `alloy` service, add an `environment:` entry (create the block if the service has none):

```yaml
    environment:
      # Read by config.alloy via sys.env for the Home Assistant scrape. NOT
      # generated by init-monitoring.sh: the token is minted in HA's own UI, so
      # the script leaves it empty and docs/home-assistant-setup.md fills it in.
      # Empty is survivable — that target 401s and nothing else is affected.
      HA_PROMETHEUS_TOKEN: ${HA_PROMETHEUS_TOKEN:-}
```

Note `:-` and **not** `:?`: the repo uses `${VAR:?message}` to fail fast on missing secrets, but this one is legitimately empty until the HA VM exists, and a hard failure would stop the whole monitoring stack from starting during bring-up.

- [ ] **Step 6: Add the variable to `.env.example`**

```bash
# Long-lived access token for Home Assistant's /api/prometheus endpoint, minted
# in HA's own UI (profile -> Security -> Long-lived access tokens). Left EMPTY
# by init-monitoring.sh on purpose — unlike the two passwords above, this one
# cannot be generated locally. Filled in during docs/home-assistant-setup.md.
# While empty, the homeassistant scrape target 401s and nothing else changes.
HA_PROMETHEUS_TOKEN=
```

- [ ] **Step 7: Validate the monitoring stack**

`infra/monitoring` has no local `.env`, so supply the required vars inline:

```bash
cd infra/monitoring && GRAFANA_DB_PASSWORD=x GRAFANA_ADMIN_PASSWORD=x docker compose config --quiet
```

Expected: exit 0. (This also proves `HA_PROMETHEUS_TOKEN` is genuinely optional — it is unset here.)

- [ ] **Step 8: Document both in `grafana-setup.md`**

Three additions:

1. In the step that covers host metrics, note that the apps VM appears as `instance="apps"` on Node Exporter Full once `scripts/init-node-exporter.sh` has run there, alongside `infra` and `pve`.
2. A new step for the HA token: paste it into `infra/monitoring/.env`, restart Alloy, and confirm in Grafana's Explore that `job="homeassistant"` returns series. State that these are entity metrics and will **not** appear on Node Exporter Full.
3. In the troubleshooting section, add the expected-red note:

```markdown
**`ServiceDown` is red for `apps` or `homeassistant` and both are fine.**
Expected, if you are following the build order: monitoring comes up on the infra
VM before either of those machines exists. Nothing is sent anywhere — no contact
point or notification policy is provisioned, so these alerts are visible in
Grafana and nowhere else. They clear as
[coolify-setup.md](coolify-setup.md) and
[home-assistant-setup.md](home-assistant-setup.md) are completed.
```

- [ ] **Step 9: Add the two Uptime Kuma monitors**

In `docs/uptime-kuma-setup.md`, extend the list of monitors to create with `https://ha.thefipster.de` and `https://coolify.thefipster.de`, both HTTP(s), matching the existing entries' format and interval.

- [ ] **Step 10: Verify links**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: baseline `N`.

- [ ] **Step 11: Commit**

```bash
git add infra/monitoring docs/grafana-setup.md docs/uptime-kuma-setup.md && git commit -m "Scrape the apps and home-assistant VMs

Both follow the proxmox_host pattern already in config.alloy. The apps VM
shares job=\"node\" with infra and pve, so it lands on the vendored Node
Exporter Full dashboard with no edit to its JSON.

Home Assistant is the odd one out twice over: it needs a credential, and
it is scraped over HTTPS through Traefik rather than directly, so a broken
route surfaces here instead of being silently bypassed. Its token is
optional (\${VAR:-}, not the repo's usual :?) because it cannot be
generated locally and is legitimately empty until the HA VM exists —
failing fast there would stop the whole monitoring stack during bring-up.

ServiceDown goes red for both until their guides run. Documented rather
than worked around with commented config: alerts are UI-only, so nothing
is sent anywhere."
```

---

## Task 8: README — diagram, build order, layout, status

Last but one, because it links and summarizes everything above.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: every file created in Tasks 1–7.

- [ ] **Step 1: Replace the architecture diagram**

The current version wraps text inside ~24-character boxes and leaves most of the width unused. Replace the whole fenced block with:

```
UniFi Dream Router · 192.168.1.1 · DHCP + split-horizon DNS
    exact infra records → .41       ha. → .41       *.thefipster.de → .42
                                    │
                          LAN · 192.168.1.0/24
                                    │
Proxmox VE · pve.thefipster.de · .40 · 32 threads · 64 GB · 2 TB · hypervisor only, no Docker
    │
    ├─ infra VM · .41 · 32 vCPU · 16 GB · 150 GB · Ubuntu Server 26.04
    │    Traefik       TLS termination + routing — the lab's only certificate
    │    Authentik     SSO / identity provider (OIDC + forward-auth)
    │    Forgejo       git · CI · container registry
    │    Dockge        compose management UI
    │    Grafana       metrics · logs · traces (Prometheus · Loki · Tempo · Alloy)
    │    Uptime Kuma   black-box status + every notification the lab sends
    │
    ├─ apps VM · .42 · 32 vCPU · 24 GB · 500 GB · Ubuntu Server 26.04
    │    Coolify       self-hosted PaaS — owns its own Docker and its own cert
    │    your apps     *.thefipster.de, routed by Host header — no new DNS record
    │    node_exporter scraped by Alloy over the LAN
    │
    └─ home-assistant VM · .43 · 32 vCPU · 8 GB · 64 GB · Home Assistant OS (UEFI)
         Supervisor     full HAOS — add-on store, ESPHome firmware builds
         ha. → Traefik  proxied from the infra VM via its file provider
         Prometheus     /api/prometheus scraped by Alloy · local login, no SSO
```

- [ ] **Step 2: Verify no line exceeds 100 characters**

```bash
awk 'length > 100 {print FILENAME":"FNR": "length" chars"}' README.md
```

Expected: no output. (If a line trips, shorten the role text — never wrap it, since wrapping is the defect being fixed.)

- [ ] **Step 3: Update the architecture table**

Add a `home-assistant VM` row (HAOS with Supervisor; reached through Traefik's file provider; own local login by design). Amend the infra row to mention the file provider alongside label-based routing. Replace the "Why two VMs instead of Docker-on-the-host" paragraph with a three-VM version: isolation and per-VM snapshots, Coolify wanting to own a host outright, and HA being an appliance image that cannot share one.

- [ ] **Step 4: Regroup the build order by machine**

Keep the existing nine numbered entries' content, but add machine sub-headings — **Lab foundation** (1–2), **infra VM** (3–8), **apps VM** (9), **home-assistant VM** (10). Entry 9 stops being "*guide TBD*" and links [docs/coolify-setup.md](docs/coolify-setup.md); entry 10 is new and links [docs/home-assistant-setup.md](docs/home-assistant-setup.md).

- [ ] **Step 5: Update the repository-layout tree**

Add `docs/coolify-setup.md`, `docs/home-assistant-setup.md`, `scripts/init-coolify.sh`, `scripts/init-node-exporter.sh`, `infra/traefik/dynamic/`, the `apps/` contents, and the new `home-assistant/` directory. Add a line under the tree stating that the **root directories are the machine map** — `infra/`, `apps/`, `home-assistant/` — while `docs/` and `scripts/` stay flat.

- [ ] **Step 6: Update the status table**

Flip `Coolify install (apps VM)` to complete with a guide link. Add rows for the home-assistant VM, and for monitoring the two new machines.

- [ ] **Step 7: Verify links and the "two VMs" phrasing**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: baseline `N`.

```bash
grep -nEi 'two VMs|guide TBD|near-empty|mostly empty' README.md
```

Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add README.md && git commit -m "Rebuild the README for three machines

The diagram is the point: the old one wrapped service names inside
24-character boxes and left most of the width empty. Now one wide row per
VM, service and role on one line, specs in the header — no wrapping.

Build order is grouped by machine rather than being a flat list of nine
steps, Coolify stops being 'guide TBD', and the layout tree gains a note
that the root directories are the machine map while docs/ and scripts/
stay flat."
```

---

## Task 9: CLAUDE.md

Last, because it describes the finished state of everything above. This file is the project's instruction set — getting it wrong misleads every future session.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update *Topology***

Three tiers become four machines: add the home-assistant VM at `.43` (HAOS, Supervisor, appliance — no Docker of ours, no init script). Note that `apps/` is no longer "intentionally near-empty" — it holds a guide, a README and a netcup env template, still no compose, and now `home-assistant/` sits beside it as the third machine directory.

- [ ] **Step 2: Update *The routing convention***

Add that Traefik now runs a **second provider**: a watched file provider over `infra/traefik/dynamic/`, for backends that are not containers on this VM. State that HA is its only user, that the label path remains the default for anything on the infra VM, and that file-provider routers are covered by the same entrypoint wildcard — so the "no per-router TLS labels" rule applies to them identically.

- [ ] **Step 3: Update *The SSO convention***

The section currently says "One service joins neither, deliberately: Uptime Kuma." Make it two, adding Home Assistant with its own reasoning (no OIDC; forward-auth would break the companion app, webhooks and local API callers; break-glass is SSH mid-incident). Name the in-place comment locations: `infra/traefik/dynamic/ha.yaml` and `infra/authentik/compose.yaml`.

- [ ] **Step 4: Update *Deploy model & ordering***

Add, after the existing seven infra steps:

- `scripts/init-coolify.sh` on the **apps VM** — preflight, swapfile, vendor installer fetched to disk with its checksum printed before running as root, `apps/.env` seed. The only init script that installs a whole platform rather than preparing a compose stack.
- `scripts/init-node-exporter.sh` — machine-agnostic, but the apps VM is its only caller. Explicitly **not** folded into `init-host.sh`, because the infra VM runs that too and Alloy already collects host metrics there.
- The home-assistant VM has **no** init script at all.

Also record that `init-host.sh` now runs on both Ubuntu VMs, which is what removed the manual chrony drop-in from `proxmox-setup.md`.

- [ ] **Step 5: Update *Conventions & gotchas***

Two additions:

- The Proxmox host is no longer the only non-container scrape target — the apps VM joins it via Debian's `prometheus-node-exporter`, and both share `job="node"` with distinct `instance` values. The apps VM is addressed **by IP**, uniquely in this repo, because `apps.thefipster.de` is not a real record and would only resolve through the wildcard by luck.
- `HA_PROMETHEUS_TOKEN` uses `${VAR:-}` rather than the repo's usual `${VAR:?}` fail-fast guard, because it cannot be generated locally and is legitimately empty until the HA VM exists.

- [ ] **Step 6: Update *Docs layout***

Add `coolify-setup.md` and `home-assistant-setup.md` to the build-order sequence. Confirm the `**Runs on:**` line is already recorded (Task 1, Step 5).

- [ ] **Step 7: Verify links**

```bash
python "$SCRATCH/linkcheck.py"
```

Expected: baseline `N`.

- [ ] **Step 8: Full-repo final gate**

```bash
for f in scripts/*.sh; do bash -n "$f" || echo "FAIL $f"; done; echo "shell syntax done"
```

Expected: `shell syntax done` with no `FAIL`.

```bash
for d in infra/authentik infra/traefik infra/dockge infra/forgejo infra/uptime-kuma; do (cd "$d" && docker compose config --quiet && echo "ok $d") || echo "FAIL $d"; done
```

Expected: `ok` for each; `infra/forgejo` and `infra/dockge` may fail on required `.env` vars they have never had locally — if so, confirm the failure message names only a missing variable, not a schema error.

```bash
git status --short
```

Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add CLAUDE.md && git commit -m "Update CLAUDE.md for the three-machine lab

Records the state the rest of this branch created: a fourth machine, a
second Traefik provider, a second stated SSO exception, two new init
scripts and the reason one of them must never run on the infra VM.

Two gotchas earn their place because both look like mistakes: the apps VM
is the one scrape target addressed by IP, since apps.thefipster.de is not
a real record and resolves only by wildcard luck; and
HA_PROMETHEUS_TOKEN uses \${VAR:-} instead of the repo's fail-fast
\${VAR:?}, because it cannot be generated locally and is empty until the
HA VM exists."
```

---

## Self-review

**Spec coverage.** §1 structure → Tasks 1, 5, 6 (dirs), 8, 9. §2 sizing → Task 3. §3 HA → Tasks 4 (routing), 6 (VM, SSO, fragment). §4 Coolify → Task 5, plus Task 3 for the `init-host.sh`/chrony change. §5 monitoring → Task 7, with the exporter script in Task 5. §6 README → Task 8. §7 file list → every entry appears in a task's **Files** block. §8 out-of-scope → nothing implements them; the USB-passthrough non-need is documented in Task 6, Step 3, as the spec requires.

**Deviation from the spec, recorded here rather than silently.** The spec's §5 sketch addressed the apps VM as a hostname, consistent with "names, not addresses." Task 7 uses `192.168.1.42:9100` instead, with the reason in the config comment: `apps.thefipster.de` is not a DNS record, so it would resolve only because the wildcard happens to point at that VM. That is exactly the accident `dns-records.md` warns about for `pve`, so relying on it here would contradict the convention it appears to follow.

**Placeholder scan.** No TBD/TODO. Every shell and YAML artifact is written out in full. Guide bodies are specified as exact structure, exact commands and the exact rationale each section must carry — for prose deliverables that is the content, not a placeholder — and each has a verification step that fails if the content is absent.

**Consistency check.** `HA_PROMETHEUS_TOKEN` is spelled identically in Tasks 6 and 7 (`.env.example`, compose passthrough, `sys.env`, guide). `ha.thefipster.de` → `.41` in Tasks 2, 4, 6, 8, 9. Backend `http://192.168.1.43:8123` in Task 4's router and Task 6's troubleshooting. VMID `103` in Tasks 3 and 6. `job="node"` / `instance="apps"` identical in Tasks 5, 7, 9. Script names `init-coolify.sh` / `init-node-exporter.sh` identical throughout.
