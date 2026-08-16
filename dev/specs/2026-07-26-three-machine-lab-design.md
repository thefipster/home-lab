# Three-machine lab: Home Assistant VM, Coolify apps host, machine-scoped repo

**Date:** 2026-07-26
**Status:** design approved, ready for implementation plan

Introduces the two machines the lab has always had room for but never
documented — the **apps VM** (Coolify) and a new **home-assistant VM** — and
reshapes the repo so its root reads as the machine map instead of an
infra-VM-with-an-empty-`apps/`-folder. Also re-sizes all three VMs for the real
target host (32 threads, 64 GB RAM, 2 TB disk) and rebuilds the README diagram,
which currently wraps text inside ~24-character boxes.

Four decisions were settled before design and are treated as fixed here:
machine directories at the repo root only (not per-machine `docs/` and
`scripts/` trees); Home Assistant reached through Traefik with **no** SSO;
`init-coolify.sh` does preflight + swap + netcup seeding; and both new machines
are wired into monitoring now, metrics included.

---

## 1. Repository structure

### What changes

Nothing moves. Three new paths join the two that already exist:

```
.
├── docs/                    every guide, flat — all paths unchanged
├── scripts/                 every init script, flat — all paths unchanged
├── infra/                   infra VM stacks (unchanged)
├── apps/                    apps VM — Coolify
│   ├── README.md            rewritten: no longer "planned"
│   └── .env.example         NETCUP_* names Coolify's bundled proxy needs
└── home-assistant/          HA VM
    ├── README.md            what lives here, and why there is no compose
    └── configuration.yaml   fragment to paste inside HAOS
```

The repo **root** becomes the machine map. `docs/` and `scripts/` stay flat.

### Why not per-machine `docs/` and `scripts/` trees

A `docs/{lab,infra,apps,ha}/` + `scripts/{common,infra,apps}/` split would touch
roughly 60 path references: every cross-guide link gains `../`, every
`scripts/init-*.sh` command in every guide changes, and each script's
`REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"` shifts a level. It buys a browse
experience nobody uses — you never browse `docs/`, you follow the build-order
chain from the README. The flat filenames are already unambiguous
(`init-<stack>.sh`, `<service>-setup.md`).

What *was* genuinely missing is the machine dimension, and that is added two
cheaper ways: the root directories above, and a new line in the guide skeleton.

### Guide skeleton change

Every guide gains one line directly under its headline:

```markdown
**Runs on:** infra VM
```

CLAUDE.md prescribes the guide structure, so its "Every guide follows the same
structure" paragraph is updated to include this line. Values in use: `Proxmox
host`, `infra VM`, `apps VM`, `home-assistant VM`, `UniFi Dream Router`, and
`—` for the two registries (`dns-records.md`, `sso-applications.md`), which
describe manual operations spanning machines.

### `home-assistant/configuration.yaml` is a fragment, not config

HAOS is an appliance. There is no shell of ours inside it and no way to
bind-mount a checkout, so the repo cannot be the live source of truth the way it
is for `infra/*`. The file follows the existing
`infra/forgejo/build-and-push.yml` precedent: a real, reviewable file in the
repo whose header comment states plainly that it lives somewhere else and must
be pasted by hand. The HA guide is the only place that copy step appears.

It is **merged into** HAOS's existing `/config/configuration.yaml`, never used to
replace it: a fresh HAOS install ships that file with `default_config:` and the
`homeassistant:`/`automation:` scaffolding, and overwriting it would strip the
default integration set. The file's header comment and the guide both say
"append these blocks", and the fragment contains only top-level keys HAOS does
not already define (`http:`, `prometheus:`) so an append cannot produce a
duplicate-key error. Editing is done in HA's own File Editor or Studio Code
Server add-on.

---

## 2. Machine sizing

Target host: **32 threads, 64 GB RAM, 2 TB disk**, single socket.

| | infra | apps | home-assistant |
|---|---|---|---|
| VMID · IP | 101 · `.41` | 102 · `.42` | 103 · `.43` |
| Cores / CPU type | 32 · `host` | 32 · `host` | 32 · `host` |
| Sockets | 1 | 1 | 1 |
| `cpuunits` | 100 *(default)* | 50 | 200 |
| `cpulimit` | 0 *(none)* | 0 *(none)* | 0 *(none)* |
| Memory | 16384 MB | 24576 MB | 8192 MB |
| Ballooning | off (`balloon: 0`) | off (`balloon: 0`) | off (`balloon: 0`) |
| Disk | 150 GB | 500 GB | 64 GB |
| Firmware / machine | SeaBIOS · q35 | SeaBIOS · q35 | **OVMF + EFI disk** · q35 |
| Guest OS | Ubuntu Server 26.04 | Ubuntu Server 26.04 | Home Assistant OS |
| Install path | ISO installer | ISO installer | import HAOS qcow2 |

Current values being replaced: infra 2 cores / 10 GB / 40 GB, apps 4 cores /
8 GB / 80 GB.

### CPU — 32 to every VM

All 32 threads are exposed to all three VMs, as intended: 96 vCPU over 32
threads is 3:1 overcommit, the right shape for three workloads that each spike
(infra compiles in CI, HA compiles ESPHome firmware, apps serves real user
load) but rarely spike together. The boundary that actually degrades
performance is a *single* VM configured wider than the host; 32 = 32 stays on
the correct side of it.

Contention is arbitrated by **`cpuunits`**, not by core count. It is a relative
scheduler weight, clamped to `[1, 10000]`, default **100** under cgroup v2 —
which Proxmox VE 8 and 9 use. (Under cgroup v1 the default was 1024; the guide
states the v2 numbers and that they are relative, so the values stay correct
either way.) HA outweighs apps 4:1, so a runaway Coolify build cannot make home
automation laggy, and no VM is capped — `cpulimit` stays 0 everywhere.

### RAM — ballooning off, deliberately

16 + 24 + 8 = 48 GB of roughly 60 GB usable after hypervisor overhead.
Ballooning only earns its keep when the sum of configured maxima *exceeds*
physical RAM. Here it does not, so the only thing the balloon driver could do is
reclaim memory from a VM mid-compile. It is disabled on all three.

The remaining ~12 GB is the growth pool, held back on purpose: the split of load
between infra and apps is not yet known, and raising a VM's memory later is an
edit plus a reboot.

Per-VM reasoning for the increases:

- **infra 10 → 16 GB.** The Forgejo Actions runner *compiles*, alongside six
  monitoring containers, Authentik, two Postgres instances, Traefik and Dockge.
  The existing 10 GB was sized before the monitoring stack landed.
- **apps 8 → 24 GB.** This is where "intense user workloads" live. Coolify's own
  baseline is ~1 GB; everything above that is apps, their databases, and build
  containers.
- **HA 8 GB.** HAOS idles near 2 GB. The spike is ESPHome/PlatformIO firmware
  builds and add-ons, and 8 GB covers several concurrent builds.

### Disk — 714 GB provisioned of 2 TB

- **infra 40 → 150 GB.** Prometheus 15 d, Loki 14 d, Tempo 7 d, Docker image
  layers, and Forgejo's **container registry**, which today accumulates an image
  per CI run. Registry retention is a known gap owned by the CI roadmap rather
  than by this spec, so 150 GB is sized to be comfortable until that lands, not
  to absorb unbounded growth forever.
- **apps 80 → 500 GB.** App volumes, databases, build cache and image layers.
  Coolify's installer itself requires 30 GB free.
- **HA 64 GB.** HAOS's own default is 32 GB; the recorder database, ESPHome
  build caches and add-ons make 64 GB comfortable.

The 2 TB is **dedicated to VM disks** — snapshots, `vzdump` backups and Proxmox
itself get separate storage in the final build. So the provisioned sum (714 GB)
is not competing with a backup pool, and there is roughly 1.3 TB of headroom for
growing these three or adding a fourth machine. Under the default ext4 install
the disks land on `local-lvm` (LVM-thin) and are thin-provisioned, costing only
what is written.

These numbers are a **starting point that will change** as the storage layout is
finalized. The guide states them as suggestions with the reasoning attached, so
the reasoning survives the numbers being revised — which is the same treatment
the current guide gives the infra VM's 10 GB.

One caveat the guide must state: the provisioned `DiskAlmostFull` alert reads
`node_filesystem_*`, so it sees filesystems **inside** guests and on the
hypervisor. It cannot see the LVM thin pool. Checking that is `lvs` on the host.

---

## 3. Home Assistant VM

Full Home Assistant OS, Supervisor and add-ons included — chosen precisely so
ESPHome, Mosquitto and friends install from the add-on store rather than being
hand-assembled.

### Install path — not the Ubuntu path

HAOS ships a **`.qcow2.xz`** disk image for KVM/Proxmox (there is no ISO) and
**requires UEFI to boot**. The guide therefore deliberately does not mirror
Part 5 of `proxmox-setup.md`:

1. On the Proxmox host: download the latest `haos_ova-*.qcow2.xz`, `xz -d` it.
2. Create the VM: machine **q35**, BIOS **OVMF**, add an EFI disk with
   **Pre-Enroll keys unchecked** — HA requires a non-secureboot OVMF build.
   Delete the wizard's default disk. Attach no CD-ROM.
3. `qm importdisk 103 haos_ova-*.qcow2 local-lvm`
4. Attach the imported disk as **SCSI** on the VirtIO SCSI single controller,
   then set boot order to it.
5. `qm disk resize 103 scsi0 64G` — HAOS grows its data partition on first boot,
   so resize before starting.
6. Start, and onboard at `http://192.168.1.43:8123`.

Tick **Qemu Agent** in the wizard as with the other VMs; HAOS ships the guest
agent, so Proxmox sees its IP and can shut it down cleanly.

### Routing — a file provider for Traefik

This is the one real change to an existing stack. `infra/traefik/compose.yaml`
runs `--providers.docker` **only**, so a service on another VM is invisible to
it — there is no container to hang labels on.

Traefik gains a **file provider**:

- `--providers.file.directory=/etc/traefik/dynamic` and
  `--providers.file.watch=true` on the command list.
- `infra/traefik/dynamic/` bind-mounted read-only into the container, keeping
  the repo the source of truth — the same arrangement as Forgejo's `config.yml`.
- A `ha.yaml` in that directory declaring a router on the `websecure`
  entrypoint with rule ``Host(`ha.thefipster.de`)`` and a service pointing at
  `http://192.168.1.43:8123`.

No per-router TLS labels, per the repo's routing convention: the entrypoint-level
`tls.domains` wildcard already covers every `websecure` router, file-provider
routers included. WebSocket upgrade needs no configuration — Traefik passes it
through, which matters because the HA frontend is websocket-driven.

Consequence worth its own sentence in the registry: **`ha.thefipster.de`
resolves to `.41`, the infra VM — not to `.43`.** That is the opposite of how
Coolify's hostnames work and is the price of reusing the existing wildcard
certificate.

`scripts/init-traefik.sh` needs no change: the dynamic directory is inside the
repo checkout and is mounted, not copied.

Bringing the file provider up before the HA VM exists is harmless — Traefik logs
an unreachable backend and `ha.thefipster.de` returns 502 until the VM answers.

### SSO — stated exception #2

Home Assistant has no native OIDC, so the repo's convention would point at
forward-auth. It is **deliberately not applied**, for the same class of reason
that already exempts Uptime Kuma:

- Forward-auth breaks the **companion mobile app**, webhooks, and every local
  API caller — all of which authenticate with long-lived tokens against the same
  endpoints a browser uses.
- The break-glass would be editing Traefik config over SSH, mid-incident, in a
  house whose lights are the thing that stopped working.

HA keeps its own local login. This is recorded in `sso-applications.md` as an
exception with reasoning — not as a gap to close — and marked in place with a
comment in `infra/traefik/dynamic/ha.yaml` (no `middlewares` key) and in
`infra/authentik/compose.yaml` (no outpost router for this host), matching how
the Kuma non-integration is documented.

### `configuration.yaml` fragment

Two blocks, both mandatory, both classic failure modes:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.1.41

prometheus:
```

`trusted_proxies` is the infra VM's **LAN** address, not a Docker subnet:
Traefik's container reaches `.43` outbound through the Docker bridge, SNAT'd to
the host's LAN IP, so that is the source address HA observes. Without both keys
HA rejects every proxied request with `400 Bad Request` and a log line about an
untrusted proxy — which reads like a Traefik fault and is not one.

Adding HA's **System Monitor** integration is called out as the cheap way to get
CPU / RAM / disk of the HA VM into the same metrics feed, since HAOS cannot run
a node exporter as a systemd unit.

---

## 4. Coolify on the apps VM

### `init-host.sh` is reused, and that removes a manual step

Coolify's installer only installs Docker when absent and requires Engine ≥ 24,
so a Docker CE installed by `init-host.sh` beforehand is compatible. More
importantly, `init-host.sh` carries the time-sync step-policy fix that
`docs/proxmox-setup.md` currently instructs you to apply **by hand** on the apps
VM. Running the script there deletes that manual chrony drop-in from Part 8 and
the "The apps VM needs none of this" claim from Part 7 — the apps VM now clones
the repo like the infra VM does.

### `scripts/init-coolify.sh`

House style throughout: `set -euo pipefail`, `run_root()` helper, paths resolved
from `$BASH_SOURCE`, re-runnable, closing next-steps block.

1. **Preflight.** Debian-family check; `docker` present and Engine ≥ 24;
   ≥ 30 GB free on `/`; report RAM. Coolify's installer officially lists Ubuntu
   20.04 / 22.04 / 24.04 LTS — 26.04 is not on that list, so an unlisted release
   **warns and continues** rather than blocking.
2. **Swap.** Create a swapfile if none is active (`/swapfile`, `fstab` entry,
   idempotent). Coolify does not create one and recommends having it; builds are
   what exhaust RAM.
3. **Install.** Download the official installer
   (`https://cdn.coollabs.io/coolify/install.sh`) to a temp file, print its
   source URL and **sha256**, then execute it as root. Not `curl | sudo bash` —
   the same operation with the script on disk and reviewable first.
4. **Seed `apps/.env`** from `apps/.env.example` if missing, carrying the
   `NETCUP_CUSTOMER_NUMBER` / `NETCUP_API_KEY` / `NETCUP_API_PASSWORD` names
   Coolify's bundled proxy needs for its own DNS-01 wildcard. The values are
   entered in Coolify's UI; the repo documents *which* names are needed so the
   requirement is not invisible.
5. **Next steps.** Open `http://<ip>:8000` and create the admin account
   **immediately** — the instance is unauthenticated until you do.

Documented honestly in the guide: Coolify wants **root**, and non-root operation
is upstream-documented as not fully supported.

### DNS — a deliberate non-row

`coolify.thefipster.de` needs **no** record: `*.thefipster.de` → `.42` already
covers it, and Coolify's proxy routes by `Host` header. `dns-records.md` states
this as an explicit non-row, because its absence otherwise looks like the exact
oversight that registry exists to prevent.

The DHCP reservation table does gain the HA VM at `.43`, and the records table
gains `ha.thefipster.de` → `.41`.

---

## 5. Monitoring both new machines

Both follow the existing `prometheus.scrape "proxmox_host"` pattern in
`infra/monitoring/alloy/config.alloy` — off-box targets addressed by DNS name so
Alloy re-resolves per scrape.

### apps VM — node exporter

A new **`scripts/init-node-exporter.sh`** installs Debian's
`prometheus-node-exporter` as a systemd unit. Deliberately its own script rather
than part of `init-host.sh`, because `init-host.sh` also runs on the infra VM,
where Alloy's embedded `prometheus.exporter.unix` already collects host metrics
— installing a second exporter there would produce a duplicate or unscraped
target. The Proxmox host keeps its documented-manual `apt install` because the
hypervisor has no checkout of this repo.

The script is **machine-agnostic** — it installs a package and enables a unit,
with no path or hostname assumptions — but in this lab the **apps VM is its only
caller**, and its header comment says so, naming the infra VM and the Proxmox
host as the two machines that deliberately do not run it and why. It does not
open a firewall port: no host firewall is configured in this lab, and the
exporter binds `:9100` on all interfaces, which is what lets Alloy reach it from
the infra VM.

Scraped as `job="node", instance="apps"`. That shared `job="node"` plus a
distinct `instance` is what puts the apps VM on the vendored Node Exporter Full
dashboard with **zero** edits to its JSON — exactly as `pve` does today.

### HA VM — the Prometheus integration

`prometheus:` in the HAOS configuration exposes `/api/prometheus`, which
requires a **long-lived access token** as a bearer credential. In Alloy:

```
prometheus.scrape "home_assistant" {
  targets      = [{"__address__" = "ha.thefipster.de:443", "job" = "homeassistant"}]
  scheme       = "https"
  metrics_path = "/api/prometheus"

  authorization {
    type        = "Bearer"
    credentials = sys.env("HA_PROMETHEUS_TOKEN")
  }
  ...
}
```

`metrics_path`, `scheme` and the `authorization` block are all supported
arguments of `prometheus.scrape`, and `sys.env` is the Alloy stdlib function for
reading an environment variable. `HA_PROMETHEUS_TOKEN` is added to
`infra/monitoring/.env.example` and passed through to the `alloy` service in
`infra/monitoring/compose.yaml`. It is **not** generated by
`init-monitoring.sh`: the token is minted in HA's own UI, so the script leaves it
empty and the guide fills it in.

Scraping over `https://ha.thefipster.de` rather than `http://192.168.1.43:8123`
keeps the target consistent with the rest of the lab (names, not addresses) and
traverses the same Traefik route the browser does — so a broken route shows up
here too, rather than being silently bypassed.

These are Home Assistant **entity** metrics — sensor states, not machine
counters. `job="homeassistant"` therefore gets its own dashboard and is
explicitly *not* expected on Node Exporter Full.

### Uptime Kuma

Two HTTP monitors added to `uptime-kuma-setup.md`: `ha.thefipster.de` and
`coolify.thefipster.de`.

### Targets ship live, not commented

Following the build order, neither the apps VM nor the HA VM exists when the
monitoring stack first comes up, so `ServiceDown` goes red for both. This is
accepted rather than worked around with commented config: `rules.yaml` provisions
**no contact point and no notification policy**, so alerts are UI-only and send
nothing outward. `grafana-setup.md` states that the two targets are expected red
until their guides are done.

---

## 6. README

- **Diagram rebuilt** at ~92 characters wide instead of ~24, three VM columns
  with a service and its role on one line each — the current version wraps
  inside its boxes and leaves most of the width empty. Header lines carry the
  router, the LAN, and the hypervisor with its specs.
- **Build order regrouped by machine**: *lab* (Proxmox host + DNS) → *infra VM*
  (Traefik → Authentik → Dockge → Forgejo → Monitoring → Uptime Kuma,
  unchanged) → *apps VM* (Coolify) → *home-assistant VM*. The Coolify entry
  stops being "guide TBD".
- **Layout section** updated for the three new root paths and the two new
  scripts.
- **Architecture table** gains a home-assistant row; the infra row gains the
  file provider; the two-VM justification becomes three.
- **Status table** gains rows for the apps VM, Coolify, the HA VM, and the
  monitoring of both.

---

## 7. Files touched

**New**

- `docs/home-assistant-setup.md`
- `docs/coolify-setup.md`
- `scripts/init-coolify.sh`
- `scripts/init-node-exporter.sh`
- `home-assistant/README.md`
- `home-assistant/configuration.yaml`
- `apps/.env.example`
- `infra/traefik/dynamic/ha.yaml`

**Modified**

- `README.md` — diagram, build order, layout, architecture, status
- `CLAUDE.md` — topology, guide skeleton (`Runs on:`), deploy order, the second
  SSO exception, the Traefik file provider, the new scripts
- `docs/proxmox-setup.md` — three VMs, new sizings, HA install path, apps VM
  runs `init-host.sh`, manual chrony drop-in removed
- `docs/dns-records.md` — `.43` reservation, `ha.` row, Coolify non-row
- `docs/sso-applications.md` — HA as stated exception #2
- `docs/traefik-setup.md` — file provider, `dynamic/` layout
- `docs/grafana-setup.md` — HA token, apps node exporter, expected-red note
- `docs/uptime-kuma-setup.md` — two new monitors
- `apps/README.md` — rewritten from "planned" to real
- `infra/traefik/compose.yaml` — file provider flags + `dynamic/` mount
- `infra/monitoring/compose.yaml` — `HA_PROMETHEUS_TOKEN` passthrough
- `infra/monitoring/.env.example` — `HA_PROMETHEUS_TOKEN`
- `infra/monitoring/alloy/config.alloy` — apps + HA scrape targets
- `infra/authentik/compose.yaml` — commented HA non-integration marker
- Every `docs/*-setup.md` — the `**Runs on:**` line

Nothing is moved or renamed, so no path reference breaks.

---

## 8. Out of scope

- A Grafana dashboard for `job="homeassistant"` beyond noting that Node Exporter
  Full does not cover it. Picking or vendoring an HA dashboard is its own task.
- Coolify application definitions. Those live in Coolify by design; `apps/` holds
  only the guide, its README and the netcup env template.
- ESPHome, Mosquitto, Zigbee2MQTT or any other add-on configuration. The guide
  installs HAOS with the Supervisor so the add-on store is available; what gets
  installed from it is not this spec's concern.
- Zigbee/Z-Wave USB passthrough to the HA VM — **not deferred, not needed.** The
  lab's Zigbee coordinators are Ethernet adapters, so HA reaches them over the
  LAN like any other network device and the hypervisor is not involved at all.
  The HA guide should say this explicitly, because "pass the USB stick through"
  is the standard advice for HA-on-Proxmox and its absence would otherwise read
  as an omission.
- Notification channels for Grafana alerts. Still UI-only, still Kuma's job.
- Migrating an existing Home Assistant installation. Guides describe
  from-scratch bring-up only.
