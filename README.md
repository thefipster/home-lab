# Home Lab

Infrastructure-as-notes for a personal homelab built on **Proxmox VE**. The
physical server is a hypervisor; everything real runs in VMs, split by purpose:
**infrastructure** services on one, **your own apps** on another, **home
automation** on a third. This repo holds the compose stacks, setup scripts, and
step-by-step guides to reproduce it.

## Start here

Building it from scratch? Go straight to
**[docs/proxmox-setup.md](docs/proxmox-setup.md)** — each guide ends by linking
the next, in the order below. The [build order](#build-order) is the map; the
rest of this page is context you can read later.

Every guide assumes a **from-scratch** bring-up of the current checkout. There
are no migration paths and no upgrade branches — if a guide tells you to
`git pull` anywhere but the initial clone, that is a bug.

## Architecture

```
UniFi Dream Router · DHCP + split-horizon DNS
    exact infra records → infra VM      ha. → infra VM      *.thefipster.de → apps VM
                                    │
                            LAN · one flat /24
                                    │
Proxmox VE · pve.thefipster.de · i5-12500HL · 12 threads · 64 GB · hypervisor only, no Docker
    │  rpool  2×500 GB NVMe mirror  → Proxmox + VM root disks
    │  backup 2×1 TB  SATA mirror  → vzdump whole-VM archives
    │  data   2×500 GB SATA mirror  → the apps VM's second disk
    │  usb    1×500 GB USB  NVMe    → restic container backups (offsite-capable)
    │
    ├─ infra VM · 12 vCPU · 16 GB · 150 GB · Ubuntu Server 26.04
    │    Traefik       TLS termination + routing — the lab's only certificate
    │    Authentik     SSO / identity provider (OIDC + forward-auth)
    │    Forgejo       git · CI · container registry
    │    Dockge        compose management UI
    │    Grafana       metrics · logs · traces (Prometheus · Loki · Tempo · Alloy)
    │    Uptime Kuma   black-box status + every notification the lab sends
    │
    ├─ apps VM · 12 vCPU · 24 GB · 80 GB + 300 GB on data · Ubuntu Server 26.04
    │    Coolify       self-hosted PaaS — owns its own Docker and its own cert
    │    your apps     *.thefipster.de, routed by Host header — no new DNS record
    │    third-party   self-hosted software you use — catalog in apps/services.md
    │    node_exporter scraped by Alloy over the LAN
    │
    └─ home-assistant VM · 12 vCPU · 8 GB · 64 GB · Home Assistant OS (UEFI)
         Supervisor     full HAOS — add-on store, ESPHome firmware builds
         ha. → Traefik  proxied from the infra VM via its file provider
         Prometheus     /api/prometheus scraped by Alloy · local login, no SSO
```

| Layer | Runs | Purpose |
|-------|------|---------|
| **Proxmox host** | the bare server | Type-1 hypervisor only — no Docker on the host, so a bad container day can't take the box down. |
| **infra VM** | Traefik + Authentik + Forgejo + Dockge + Grafana + Uptime Kuma | TLS termination and routing for real domain names, CI/CD (GitHub → mirror → build → push to the built-in registry), a web UI for managing compose stacks, and monitoring (metrics, logs, traces, dashboards, alerts) plus an independent status watcher that sends the notifications. SSO (Authentik) fronts the infra UIs — except Kuma, deliberately, so an Authentik outage stays visible. |
| **apps VM** | Coolify | A self-hosted PaaS that deploys and runs *your* applications with domains + HTTPS. Owns its own Docker, and issues its own wildcard certificate. Also runs the third-party software you use, deployed the same way — the catalog is [apps/services.md](apps/services.md). |
| **home-assistant VM** | Home Assistant OS | Home automation as a full appliance — Supervisor included, so add-ons (ESPHome, Mosquitto) install from HA's own store. Reached at `ha.thefipster.de` through Traefik on the infra VM. Keeps its own local login, deliberately. |

Why three VMs instead of Docker-on-the-host: isolation and per-VM snapshots. Each
of the three also refuses to share for its own reason — Coolify expects to own a
host's Docker outright, HAOS *is* an OS image and cannot be a container beside
others, and the infra VM is the one machine that must survive an experiment on
either of them. Rolling back a bad Coolify upgrade should not take TLS, SSO and
monitoring with it.

## Storage

Six internal drives paired into **three ZFS mirrors**, plus one external drive.
Every mirror answers a different question, which is why they are not one big pool:
`rpool` is fast flash for the hypervisor and every VM root disk; `backup` is
deliberately **double** its size, because that is what makes a retention policy
possible instead of a single copy; `data` absorbs the growth — Coolify's app
volumes, databases and image layers — on drives whose failure cannot take the
hypervisor with it.

The external USB drive is the only copy that can physically leave the building.
It holds the file-level `restic` repository, reached over SFTP so both VMs can
write to it — see [docs/roadmap/backup.md](docs/roadmap/backup.md).

Mirrors only help if a failure is noticed, and a degraded mirror is precisely the
failure that takes *nothing* down. A timer on the hypervisor reports pool health
to an Uptime Kuma push monitor, so it lands in the same ntfy notifications as
everything else ([docs/proxmox-setup.md, Part
9](docs/proxmox-setup.md#part-9--notice-when-a-mirror-degrades)).

## Networking & DNS

Everything sits on the LAN behind a UniFi Dream Router. Names are real
subdomains of `thefipster.de`, resolved **locally** by the router (split
horizon — the public zone holds no A records): exact host records send the
infra services (`git.`, `auth.`, `grafana.`, …) to the infra VM, and the
`*.thefipster.de` wildcard sends everything else to the apps VM, where
Coolify's proxy routes each hostname to the right app by the HTTP `Host`
header — new apps need **no** new DNS records. The full record set is the
registry [docs/dns-records.md](docs/dns-records.md); the router how-to is
[docs/wildcard-dns-udr.md](docs/wildcard-dns-udr.md).

Certificates are genuine Let's Encrypt wildcards, issued via the DNS-01
challenge against the netcup DNS API — nothing is exposed to the internet. See
[docs/traefik-setup.md](docs/traefik-setup.md) for TLS.

## Repository layout

```
.
├── docs/                        Guides — flat; each names its machine up top
│   ├── proxmox-setup.md          Proxmox host + the three VMs (start here)
│   ├── wildcard-dns-udr.md       Lab DNS (thefipster.de) on the UniFi Dream Router
│   ├── dns-records.md            Registry: every DNS record the lab needs
│   ├── infra-vm-setup.md         infra VM: checkout, clock, guest agent, Docker
│   ├── traefik-setup.md          Traefik + Let's Encrypt via netcup DNS-01
│   ├── authentik-setup.md        SSO with Authentik (OIDC + forward-auth)
│   ├── sso-applications.md       Registry: every service behind Authentik
│   ├── dockge-setup.md           Dockge, the compose management UI
│   ├── forgejo-setup.md          Forgejo CI/registry on the infra VM
│   ├── grafana-setup.md          Monitoring: stack, SSO, and what it observes
│   ├── uptime-kuma-setup.md      Uptime Kuma: independent status monitoring
│   ├── uptime-kuma-monitors.md   Registry: every monitor, grouped by stack
│   ├── apps-vm-setup.md          apps VM: checkout, host scripts, data disk
│   ├── coolify-setup.md          Coolify (the PaaS) on the apps VM
│   ├── home-assistant-setup.md   Home Assistant OS on the third VM
│   ├── review/                   Findings from replaying the guides
│   └── roadmap/                  What's next (backup, CI hardening, Authentik bump)
├── scripts/                     Setup automation — flat; run on a VM, in this order
│   ├── init-host.sh              Clock-step policy + guest agent (both Ubuntu VMs)
│   ├── init-docker.sh            Docker Engine + compose plugin (infra VM only)
│   ├── init-unattended-upgrades.sh   Automatic security updates (both VMs)
│   ├── init-traefik.sh           Traefik prep: proxy network, ACME dir, .env
│   ├── init-authentik.sh         Authentik: data tree, generate secrets
│   ├── init-dockge.sh            Bring up the Dockge management UI
│   ├── init-forgejo.sh           Forgejo prep: data tree, .env secrets
│   ├── init-monitoring.sh        Monitoring: data tree, .env secrets
│   ├── init-uptime-kuma.sh       Uptime Kuma: data dir, stack symlink
│   ├── init-coolify.sh           Coolify on the apps VM: preflight, swap, install
│   └── init-node-exporter.sh     Host metrics unit — apps VM only (see its header)
├── infra/                       Stacks for the infra VM
│   ├── traefik/
│   │   ├── compose.yaml          Traefik v3 — TLS termination + routing
│   │   ├── .env.example          netcup API credentials template
│   │   └── dynamic/ha.yaml       File-provider router for the HA VM (off-box)
│   ├── authentik/
│   │   ├── compose.yaml          Authentik SSO (server, worker, postgres, redis)
│   │   └── .env.example          secret-key / DB / bootstrap template
│   ├── forgejo/
│   │   ├── compose.yaml          Forgejo + Postgres + Actions runner
│   │   ├── .env.example          DB password / DOCKER_GID template
│   │   ├── config.yml            Runner config
│   │   └── build-and-push.yml    CI workflow template (goes in your app repo)
│   ├── dockge/
│   │   └── compose.yaml          Dockge (compose management UI)
│   ├── monitoring/
│   │   ├── compose.yaml          Grafana + Postgres + Prometheus + Loki + Tempo + Alloy
│   │   ├── .env.example          Grafana DB / admin / OIDC / HA token template
│   │   ├── alloy/config.alloy    The collector: metrics, logs, OTLP intake
│   │   ├── loki/loki.yaml        Log storage, 14d retention
│   │   ├── tempo/tempo.yaml      Trace storage, 7d retention
│   │   ├── prometheus/           Metrics storage, 15d retention
│   │   └── grafana/provisioning/ Datasources, dashboards + alerts as code
│   └── uptime-kuma/
│       └── compose.yaml          Uptime Kuma (black-box monitoring + alerts)
├── apps/                        Apps VM (Coolify) — no compose, by design
│   ├── README.md                 What lives here and what deliberately doesn't
│   ├── services.md               Catalog: third-party apps this VM runs
│   └── .env.example              netcup names Coolify's own proxy needs
└── home-assistant/              HA VM (Home Assistant OS) — no compose, no script
    ├── README.md                 Why an appliance has neither
    └── configuration.yaml        Fragment to APPEND inside the VM
```

**The root directories are the machine map** — `infra/`, `apps/` and
`home-assistant/` are one per VM. `docs/` and `scripts/` stay deliberately flat:
their filenames already say which service they belong to, and nesting them would
add a `../` to every cross-guide link without making anything easier to find. Each
guide instead names its machine in a `**Runs on:**` line under the headline.

Note how little the two new machines contain. Only the infra VM's services are
declared in this repo; Coolify keeps app definitions in its own database and HAOS
manages itself through the Supervisor. For those two, the repo holds guides and
one config fragment each — not a source of truth.

## Build order

Grouped by machine. Finish the infra VM before starting either of the others —
they both lean on its TLS, and the HA VM is reachable only through its Traefik.

### Lab foundation — the hypervisor and the network

1. **[Proxmox host + VMs](docs/proxmox-setup.md)** — wipe the server, install
   the hypervisor onto the mirrored NVMe pair, build the other three ZFS pools,
   cap the ARC, then create the `infra` and `apps` VMs and snapshot them. The
   `home-assistant` VM's specs are in the same table but it is built in step 12,
   since it needs an imported disk image rather than an ISO. Its last two parts —
   the whole-VM backup job and the pool-health monitor — are done at the end,
   since the monitor needs a Kuma that does not exist until step 9.
2. **[DNS](docs/wildcard-dns-udr.md)** — reservations, the `*.thefipster.de`
   wildcard, and **every** infra host record. Add the complete set now from the
   registry, **[docs/dns-records.md](docs/dns-records.md)** — every later step
   assumes they exist, and a missing record surfaces much later as a 404 behind
   a valid certificate. The one exception is
   `homeassistant.thefipster.de`, whose target VM does not exist until step 12
   and which that guide adds.

### infra VM — everything the other two lean on

3. **[infra VM setup](docs/infra-vm-setup.md)** — the first time you open a
   shell on a guest. Clone the repo to `~/home-lab`, then three scripts in
   order: clock policy + guest agent, Docker Engine, automatic security
   updates. Nothing is served yet; this is the ground everything else stands on.
4. **[Traefik](docs/traefik-setup.md)** — reverse proxy + wildcard TLS on the
   infra VM (netcup DNS-01). The certificate is requested at startup; expect
   the ~10–15 min netcup propagation wait on first issuance.
5. **[Authentik](docs/authentik-setup.md)** — SSO. It comes before everything it
   gates: the Traefik dashboard and Dockge reference its forward-auth
   middleware, so their routers do not load until it runs. Each service that
   joins SSO gets its row in the registry,
   **[docs/sso-applications.md](docs/sso-applications.md)**, first.
6. **[Dockge](docs/dockge-setup.md)** — the compose management UI. Deliberately
   after Authentik (it has no ports published and its route is gated), and
   before the remaining stacks so they can be driven from a browser.
7. **[Forgejo](docs/forgejo-setup.md)** — CI and the container registry, joined
   to Authentik by OIDC.
8. **[Monitoring](docs/grafana-setup.md)** — Grafana + Prometheus + Loki +
   Tempo + Alloy: the stack, SSO by OIDC, and verifying what it observes
   (container logs, service + host metrics, OTLP with traces, dashboards and
   alerts).
9. **[Uptime Kuma](docs/uptime-kuma-setup.md)** — independent black-box
   monitoring and the lab's notification layer. Last on purpose: it watches
   everything above it, and it is a separate stack precisely so it does not
   share a lifecycle with the monitoring pipeline it also checks. The monitors
   themselves are the registry,
   **[docs/uptime-kuma-monitors.md](docs/uptime-kuma-monitors.md)** — every new
   service gets its rows there.

### apps VM — your own applications

10. **[apps VM setup](docs/apps-vm-setup.md)** — the second machine's checkout
    and host scripts: `init-host.sh` and `init-unattended-upgrades.sh`, but
    **not** `init-docker.sh` — Coolify's own installer brings the Engine. Also
    mounts the 300 GB second disk at `/data`, which has to happen *before*
    Coolify exists rather than after.
11. **[Coolify](docs/coolify-setup.md)** — the self-hosted PaaS. Create its
    admin account *immediately*: a fresh instance is unauthenticated on a LAN
    port with nothing in front of it. Its bundled proxy needs switching from
    HTTP-01 to netcup DNS-01 by hand before it can issue a wildcard. Ends by
    installing the node exporter that Alloy on the infra VM already expects.

### home-assistant VM — home automation

12. **[Home Assistant OS](docs/home-assistant-setup.md)** — the only VM not built
    from an ISO: HAOS ships a qcow2 disk image and needs non-secureboot UEFI, so
    it is created empty and its disk imported. Last because it depends on the most:
    Traefik's file provider for TLS, and Alloy for metrics. It joins neither SSO
    pattern, deliberately.

## Status

| Piece | State |
|-------|-------|
| Proxmox host + the infra and apps VMs | ✅ deployed |
| DNS (UDR split-horizon + wildcard) | ✅ deployed |
| Traefik + Let's Encrypt (netcup DNS-01) | ✅ deployed |
| Authentik SSO (OIDC + forward-auth) | ✅ deployed — pinned `2025.6`; moving off it is [planned](docs/roadmap/authentik-2026.md) |
| Dockge management UI | ✅ deployed — [guide](docs/dockge-setup.md) |
| Forgejo CI + registry | ✅ deployed — [guide](docs/forgejo-setup.md) |
| Monitoring: Grafana + Prometheus + Loki + Alloy + Tempo | ✅ complete — [guide](docs/grafana-setup.md), [roadmap](docs/roadmap/monitoring.md) |
| Uptime Kuma (status monitoring + notifications) | ✅ complete — [guide](docs/uptime-kuma-setup.md) |
| Backup layer 1: `vzdump` whole-VM to the `backup` mirror | 📄 documented — [Part 8](docs/proxmox-setup.md#part-8--schedule-whole-vm-backups) |
| Backup layer 2: `restic` file-level to the USB drive | ⬜ planned — [roadmap](docs/roadmap/backup.md) |
| ZFS pool health → Uptime Kuma; pool capacity → Prometheus | 📄 documented — [Part 9](docs/proxmox-setup.md#part-9--notice-when-a-mirror-degrades) |
| CI: triggers & release builds (nightly, tags) | ⬜ planned — [roadmap](docs/roadmap/ci-triggers.md) |
| CI: tests + coverage | ⬜ planned — [roadmap](docs/roadmap/ci-testing.md) |
| CI: code analysis | ⬜ planned — [roadmap](docs/roadmap/ci-code-analysis.md) |
| CI: container scanning + SBOM | ⬜ planned — [roadmap](docs/roadmap/ci-supply-chain.md) |
| Coolify install (apps VM) | 📄 guide ready, not yet built — [guide](docs/coolify-setup.md) |
| Third-party apps on the apps VM | 📄 catalog written, nothing deployed — [catalog](apps/services.md) |
| Container logs from the apps VM | ⬜ planned — [roadmap](docs/roadmap/apps-vm-logs.md) |
| home-assistant VM (HAOS + Supervisor) | 📄 guide ready, not yet built — [guide](docs/home-assistant-setup.md) |
| Monitoring the apps + HA VMs | 📄 config shipped; targets red until those VMs exist |
| Sizing for the target hardware (12 threads / 64 GB / 4 pools) | 📄 documented — [spec](docs/superpowers/specs/2026-07-31-hardware-specs-design.md) |

`✅` runs today · `📄` written and reviewed, waiting on hardware or a build step ·
`⬜` not started. The three `📄` rows above are why the guides can describe
machines you cannot yet log into: the repo documents the lab it is being built
into, and each guide is verified by reading until the box exists to run it on.
