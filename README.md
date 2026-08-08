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
Proxmox VE · pve.thefipster.de · i5-10600K · 12 threads · 96 GB · hypervisor only, no Docker
    │  rpool     2×500 GB NVMe mirror  → Proxmox + VM root disks
    │  backup    2×1 TB  SATA mirror   → vzdump whole-VM archives
    │  data      2×500 GB SATA mirror  → the apps VM's second disk
    │  usbbackup 1×1 TB USB NVMe       → restic container backups (offsite-capable)
    │
    ├─ infra VM · 12 vCPU · 24 GB · 150 GB · Ubuntu Server 26.04
    │    Traefik       TLS termination + routing — the lab's only certificate
    │    Vaultwarden   password manager · local login, no SSO — built before it
    │    Authentik     SSO / identity provider (OIDC + forward-auth)
    │    Forgejo       git · CI · container registry
    │    Dockge        compose management UI
    │    Grafana       metrics · logs · traces (Prometheus · Loki · Tempo · Alloy)
    │    Uptime Kuma   black-box status + every notification the lab sends
    │
    ├─ apps VM · 12 vCPU · 32 GB · 80 GB + 300 GB on data · Ubuntu Server 26.04
    │    Coolify         self-hosted PaaS — owns its own Docker and its own cert
    │      your apps     *.thefipster.de, routed by Host header — no new DNS record
    │      third-party   self-hosted software you use — catalog in apps/services.md
    │
    └─ home-assistant VM · 12 vCPU · 8 GB · 64 GB · Home Assistant OS (UEFI)
         Prometheus     /api/prometheus scraped by Alloy · local login, no SSO
         Supervisor     full HAOS — the add-on store the four below come from
           ESPHome      firmware for the lab's own ESP devices, built on this VM
           Mosquitto    the MQTT broker both Zigbee2MQTT and HA talk to
           Zigbee2MQTT  Zigbee radios → MQTT · Ethernet coordinators, no USB passthrough
           Node-RED     flow-based automation beside HA's own
```

| Layer                 | Purpose |
|-----------------------|---------|
| **proxmox-host**      | Type-1 hypervisor only — no Docker on the host, so a bad container day can't take the box down. |
| **infra-vm**          | TLS termination and routing for real domain names, the password manager that holds every credential below, CI/CD (GitHub → mirror → build → push to the built-in registry), a web UI for managing compose stacks, and monitoring (metrics, logs, traces, dashboards, alerts) plus an independent status watcher that sends the notifications. SSO (Authentik) fronts the infra UIs — except Vaultwarden and Kuma, deliberately, so an Authentik outage takes neither the credentials to fix it nor the view of what broke. |
| **apps-vm**           | A self-hosted PaaS that deploys and runs *your* applications with domains + HTTPS. Owns its own Docker, and issues its own wildcard certificate. Also runs the third-party software you use, deployed the same way — the catalog is [apps/services.md](apps/services.md). |
| **home-assistant-vm** | Home automation as a full appliance — Supervisor included, so add-ons (ESPHome, Mosquitto) install from HA's own store. Reached at `ha.thefipster.de` through Traefik on the infra VM. Keeps its own local login, deliberately. |

Why three VMs instead of Docker-on-the-host: isolation and per-VM snapshots. Each
of the three also refuses to share for its own reason — Coolify expects to own a
host's Docker outright, HAOS *is* an OS image and cannot be a container beside
others, and the infra VM is the one machine that must survive an experiment on
either of them. Rolling back a bad Coolify upgrade should not take TLS, SSO and
monitoring with it.

## Storage

Six internal drives paired into **three ZFS mirrors**, plus one external drive.

| Pool | Devices                 | Proxmox storage | Holds |
|------|-------------------------|-----------------|-------|
| `rpool` | 2 × 500 GB NVMe, mirror | installer-created (boot pool) | Proxmox itself + all three VM **root** disks |
| `backup` | 2 × 1 TB SATA, mirror   | *Directory* on `/backup`, `--is_mountpoint 1` | `vzdump` whole-VM archives — layer 1 |
| `data` | 2 × 500 GB SATA, mirror | `zfspool`, content `images,rootdir` | the apps VM's second disk (`/data`, 300 GB) |
| `usbbackup` | 1 × 1 TB USB 3.1 NVMe   | **none** — reached over SFTP, not by Proxmox | the `restic` repository — layer 2 |

The storage *types* are not interchangeable: a pool registered as `zfspool`
accepts disk images only and cannot hold `vzdump` output, which is why the backup
mirror is a *Directory* on the pool's mountpoint instead. `usbbackup` gets no
Proxmox entry at all — restic reaches it over the hypervisor's `sshd`. Both are
built in [docs/proxmox-setup.md, Part 3](docs/proxmox-setup.md#part-3--post-install-housekeeping).

Every mirror answers a different question, which is why they are not one big pool:
`rpool` is fast flash for the hypervisor and every VM root disk; `backup` is
deliberately **double** its size, because that is what makes a retention policy
possible instead of a single copy; `data` absorbs the growth — Coolify's app
volumes, databases and image layers — on drives whose failure cannot take the
hypervisor with it.

The external USB drive is the only copy that can physically leave the building.
It holds the file-level `restic` repository, reached over SFTP so both VMs can
write to it. The infra VM's half is built in
[docs/backup-setup.md](docs/backup-setup.md); the apps VM has **not** joined the
repository yet, which is why its 300 GB data disk is still covered by nothing
([docs/roadmap/backup.md](docs/roadmap/backup.md)).

Mirrors only help if a failure is noticed, and a degraded mirror is precisely the
failure that takes *nothing* down. A timer on the hypervisor reports pool health
to an Uptime Kuma push monitor, so it lands in the same ntfy notifications as
everything else ([docs/proxmox-setup.md, Part
9](docs/proxmox-setup.md#part-9--notice-when-a-mirror-degrades)).

## Networking & DNS

Everything sits on the LAN behind a UniFi Dream Router. Names are real
subdomains of `thefipster.de`, resolved **locally** by the router (split
horizon — the public zone holds no address records, A **or** AAAA): exact host
records send the
infra services (`git.`, `auth.`, `grafana.`, …) to the infra VM, and the
`*.thefipster.de` wildcard sends everything else to the apps VM, where
Coolify's proxy routes each hostname to the right app by the HTTP `Host`
header — new apps need **no** new DNS records. The full record set is the
registry [docs/dns-records.md](docs/dns-records.md); the router how-to is
[docs/wildcard-dns-udr.md](docs/wildcard-dns-udr.md).

Certificates are genuine Let's Encrypt wildcards, issued via the DNS-01
challenge against the netcup DNS API — nothing is exposed to the internet. See
[docs/traefik-setup.md](docs/traefik-setup.md) for TLS.

## Build order

Grouped by machine. Finish the infra VM before starting either of the others —
they both lean on its TLS, and the HA VM is reachable only through its Traefik.

### Lab foundation — the hypervisor and the network

1. **[Proxmox host + VMs](docs/proxmox-setup.md)** — wipe the server, install
   the hypervisor onto the mirrored NVMe pair, build the other three ZFS pools,
   cap the ARC, then create the `infra` and `apps` VMs and snapshot them. The
   `home-assistant` VM's specs are in the same table but it is built in step 14,
   since it needs an imported disk image rather than an ISO. Its last part —
   the pool-health monitor — is done at the end, since it needs a Kuma that
   does not exist until step 10; everything before it, the whole-VM backup job
   included, is done now.
2. **[DNS](docs/wildcard-dns-udr.md)** — reservations, the `*.thefipster.de`
   wildcard, and **every** infra host record. Add the complete set now from the
   registry, **[docs/dns-records.md](docs/dns-records.md)** — every later step
   assumes they exist, and a missing record surfaces much later as a 404 behind
   a valid certificate. The one exception is
   `homeassistant.thefipster.de`, whose target VM does not exist until step 14
   and which that guide adds.

### infra VM — everything the other two lean on

3. **[infra VM setup](docs/infra-vm-setup.md)** — the first time you open a
   shell on a guest. Clone the repo to `~/home-lab`, then three scripts in
   order: clock policy + guest agent, Docker Engine, automatic security
   updates. Nothing is served yet; this is the ground everything else stands on.
4. **[Traefik](docs/traefik-setup.md)** — reverse proxy + wildcard TLS on the
   infra VM (netcup DNS-01). The certificate is requested at startup; expect
   the ~10–15 min netcup propagation wait on first issuance.
5. **[Vaultwarden](docs/vaultwarden-setup.md)** — the password manager, and the
   first stack Traefik serves. Before SSO on purpose, and the only service in
   the lab that declines an SSO pattern it qualifies for: it holds the
   credentials for repairing Authentik, so it must not depend on it. Everything
   from here on generates a secret worth keeping.
6. **[Authentik](docs/authentik-setup.md)** — SSO. It comes before everything it
   gates: the Traefik dashboard and Dockge reference its forward-auth
   middleware, so their routers do not load until it runs. Each service that
   joins SSO gets its row in the registry,
   **[docs/sso-applications.md](docs/sso-applications.md)**, first.
7. **[Dockge](docs/dockge-setup.md)** — the compose management UI. Deliberately
   after Authentik (it has no ports published and its route is gated), and
   before the remaining stacks so they can be driven from a browser.
8. **[Forgejo](docs/forgejo-setup.md)** — CI and the container registry, joined
   to Authentik by OIDC.
9. **[Monitoring](docs/grafana-setup.md)** — Grafana + Prometheus + Loki +
   Tempo + Alloy: the stack, SSO by OIDC, and verifying what it observes
   (container logs, service + host metrics, OTLP with traces, dashboards and
   alerts).
10. **[Uptime Kuma](docs/uptime-kuma-setup.md)** — independent black-box
    monitoring and the lab's notification layer. Last on purpose: it watches
    everything above it, and it is a separate stack precisely so it does not
    share a lifecycle with the monitoring pipeline it also checks. The monitors
    themselves are the registry,
    **[docs/uptime-kuma-monitors.md](docs/uptime-kuma-monitors.md)** — every new
    service gets its rows there.
11. **[Backup](docs/backup-setup.md)** — layer 2: file-level `restic` backups,
    one snapshot per stack, onto the hypervisor's USB pool over SFTP. Last on
    the infra VM because it backs up everything above it and reports through a
    Kuma push monitor. Part 1 runs on the **Proxmox host** — the machine that
    owns the drive. Then prove it:
    **[docs/backup-restore-drill.md](docs/backup-restore-drill.md)** restores
    each stack against a marker only the snapshot could bring back, because a
    backup nobody has restored from is a hypothesis. Re-run yearly.

### apps VM — your own applications

12. **[apps VM setup](docs/apps-vm-setup.md)** — the second machine's checkout
    and host scripts: `init-host.sh` and `init-unattended-upgrades.sh`, but
    **not** `init-docker.sh` — Coolify's own installer brings the Engine. Also
    mounts the 300 GB second disk at `/data`, which has to happen *before*
    Coolify exists rather than after.
13. **[Coolify](docs/coolify-setup.md)** — the self-hosted PaaS. Create its
    admin account *immediately*: a fresh instance is unauthenticated on a LAN
    port with nothing in front of it. Its bundled proxy needs switching from
    HTTP-01 to netcup DNS-01 by hand before it can issue a wildcard. Ends by
    installing the node exporter that Alloy on the infra VM already expects.

### home-assistant VM — home automation

14. **[Home Assistant OS](docs/home-assistant-setup.md)** — the only VM not built
    from an ISO: HAOS ships a qcow2 disk image and needs non-secureboot UEFI, so
    it is created empty and its disk imported. Last because it depends on the most:
    Traefik's file provider for TLS, and Alloy for metrics. It joins neither SSO
    pattern, deliberately.

## Registries & catalogs

The documents that are **not** build steps. They hold what lives outside the
compose files — manual operations, clickwork, schedules and results — and the
guides link them rather than repeating their contents, so no per-service value
is written down twice.

| Document | Holds |
|---|---|
| **[docs/dns-records.md](docs/dns-records.md)** | every record on the UniFi Dream Router, plus the no-AAAA invariant the split horizon depends on |
| **[docs/sso-applications.md](docs/sso-applications.md)** | every Authentik application, which pattern it joins (OIDC or forward-auth), and its exact config values — including which side of the pair each value lives on |
| **[docs/uptime-kuma-monitors.md](docs/uptime-kuma-monitors.md)** | every Kuma monitor, grouped by stack, with its type and target |
| **[docs/timetable.md](docs/timetable.md)** | everything that runs on a clock: the staggered night window, the short-interval jobs, and the arithmetic for sizing a heartbeat. Read it before adding a timer |
| **[docs/backup-restore-drill.md](docs/backup-restore-drill.md)** | the per-stack restore procedure, and what each stack's result actually proves. A recurring drill — yearly, and whenever a `backup.sh` changes shape |
| **[apps/services.md](apps/services.md)** | the third-party software on the apps VM — what runs and why, never how, since those compose files live in a Forgejo repo |

**The four registries list their deliberate absences beside their entries**, and
that is the point: a registry recording only what exists cannot tell you whether
a gap was a decision. Vaultwarden, Kuma and Home Assistant have no SSO row;
`coolify.` and `apps.` have no DNS row; Kuma does not monitor itself or the
hypervisor; the lab runs no CI schedule at all. When adding a service, decide
about each of them and say so in each.

## Status

What actually runs today versus what is only written down is its own document:
**[docs/status.md](docs/status.md)** — one row per piece of the lab, with the
guide or roadmap entry each one points at.
