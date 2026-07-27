# Home Lab

Infrastructure-as-notes for a personal homelab built on **Proxmox VE**. The
physical server is a hypervisor; everything real runs in VMs, split by purpose:
**infrastructure** services on one, **your own apps** on another. This repo holds
the compose stacks, setup scripts, and step-by-step guides to reproduce it.

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
UniFi Dream Router  —  DHCP + DNS  (infra host records → infra VM, *.thefipster.de → apps VM)
        │  LAN 192.168.1.0/24
        │
  Proxmox VE  ·  pve.thefipster.de  ·  .40   (hypervisor only)
        │
        ├───────────────────────┐
        │                       │
  ┌─ infra VM (.41) ─┐   ┌─ apps VM (.42) ─┐
  │ Traefik: TLS +   │   │ Coolify: PaaS   │
  │   routing        │   │                 │
  │ Authentik: SSO   │   │ your apps       │
  │ Forgejo: CI +    │   │                 │
  │   registry       │   │                 │
  │ Dockge: compose  │   │                 │
  │   management UI  │   │                 │
  │ Grafana: metrics │   │                 │
  │   + logs         │   │                 │
  │ Uptime Kuma:     │   │                 │
  │   status + alerts│   │                 │
  └──────────────────┘   └─────────────────┘
```

| Layer | Runs | Purpose |
|-------|------|---------|
| **Proxmox host** | the bare server | Type-1 hypervisor only — no Docker on the host, so a bad container day can't take the box down. |
| **infra VM** | Traefik + Authentik + Forgejo + Dockge + Grafana + Uptime Kuma | TLS termination and routing for real domain names, CI/CD (GitHub → mirror → build → push to the built-in registry), a web UI for managing compose stacks, and monitoring (metrics, logs, traces, dashboards, alerts) plus an independent status watcher that sends the notifications. SSO (Authentik) fronts the infra UIs — except Kuma, deliberately, so an Authentik outage stays visible. |
| **apps VM** | Coolify | A self-hosted PaaS that deploys and runs *your* applications with domains + HTTPS. Owns its own Docker. |

Why two VMs instead of Docker-on-the-host: isolation and per-VM snapshots. Coolify
wants to own a host outright; keeping it off the infra box avoids that conflict.

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
├── docs/                        Guides
│   ├── proxmox-setup.md          Proxmox host + the two VMs (start here)
│   ├── wildcard-dns-udr.md       Lab DNS (thefipster.de) on the UniFi Dream Router
│   ├── dns-records.md            Registry: every DNS record the lab needs
│   ├── traefik-setup.md          Traefik + Let's Encrypt via netcup DNS-01
│   ├── authentik-setup.md        SSO with Authentik (OIDC + forward-auth)
│   ├── sso-applications.md       Registry: every service behind Authentik
│   ├── dockge-setup.md           Dockge, the compose management UI
│   ├── forgejo-setup.md          Forgejo CI/registry on the infra VM
│   ├── grafana-setup.md          Monitoring: stack, SSO, and what it observes
│   ├── uptime-kuma-setup.md      Uptime Kuma: independent status monitoring
│   ├── review/                   Findings from replaying the guides
│   └── roadmap/                  What's next (CI hardening; monitoring is done)
├── scripts/                     Setup automation (run on a VM, in this order)
│   ├── init-host.sh                  Host basics: clock + guest agent (both VMs)
│   ├── init-docker.sh                Install Docker Engine + compose plugin
│   ├── init-unattended-upgrades.sh   Automatic security updates (both VMs)
│   ├── init-traefik.sh               Traefik prep: proxy network, ACME dir, .env
│   ├── init-authentik.sh             Authentik: data tree, generate secrets
│   ├── init-dockge.sh                Bring up the Dockge management UI
│   ├── init-forgejo.sh               Forgejo Part 0: data tree, .env secrets
│   ├── init-monitoring.sh            Monitoring: data tree, .env secrets
│   └── init-uptime-kuma.sh           Uptime Kuma: data dir, stack symlink
├── infra/                       Stacks for the infra VM
│   ├── traefik/
│   │   ├── compose.yaml          Traefik v3 — TLS termination + routing
│   │   └── .env.example          netcup API credentials template
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
│   │   ├── .env.example          Grafana DB / admin / OIDC template
│   │   ├── alloy/config.alloy    The collector: metrics, logs, OTLP intake
│   │   ├── loki/loki.yaml        Log storage, 14d retention
│   │   ├── tempo/tempo.yaml      Trace storage, 7d retention
│   │   ├── prometheus/           Metrics storage, 15d retention
│   │   └── grafana/provisioning/ Datasources, dashboards + alerts as code
│   └── uptime-kuma/
│       └── compose.yaml          Uptime Kuma (black-box monitoring + alerts)
└── apps/                        Apps VM (Coolify) — see apps/README.md
```

## Build order

1. **[Proxmox host + VMs](docs/proxmox-setup.md)** — wipe the server, install
   the hypervisor, create the `infra` and `apps` VMs, then run the host
   scripts in each guest: clock + guest agent and automatic security updates on
   both, Docker on the infra VM only.
2. **[DNS](docs/wildcard-dns-udr.md)** — reservations, the `*.thefipster.de`
   wildcard, and **every** infra host record. Add the complete set now from the
   registry, **[docs/dns-records.md](docs/dns-records.md)** — every later step
   assumes they exist, and a missing record surfaces much later as a 404 behind
   a valid certificate.
3. **[Traefik](docs/traefik-setup.md)** — reverse proxy + wildcard TLS on the
   infra VM (netcup DNS-01). The certificate is requested at startup; expect
   the ~10–15 min netcup propagation wait on first issuance.
4. **[Authentik](docs/authentik-setup.md)** — SSO. It comes before everything it
   gates: the Traefik dashboard and Dockge reference its forward-auth
   middleware, so their routers do not load until it runs. Each service that
   joins SSO gets its row in the registry,
   **[docs/sso-applications.md](docs/sso-applications.md)**, first.
5. **[Dockge](docs/dockge-setup.md)** — the compose management UI. Deliberately
   after Authentik (it has no ports published and its route is gated), and
   before the remaining stacks so they can be driven from a browser.
6. **[Forgejo](docs/forgejo-setup.md)** — CI and the container registry, joined
   to Authentik by OIDC.
7. **[Monitoring](docs/grafana-setup.md)** — Grafana + Prometheus + Loki +
   Tempo + Alloy: the stack, SSO by OIDC, and verifying what it observes
   (container logs, service + host metrics, OTLP with traces, dashboards and
   alerts).
8. **[Uptime Kuma](docs/uptime-kuma-setup.md)** — independent black-box
   monitoring and the lab's notification layer. Last on purpose: it watches
   everything above it, and it is a separate stack precisely so it does not
   share a lifecycle with the monitoring pipeline it also checks.
9. **Coolify** on the apps VM — *guide TBD* (see [apps/README.md](apps/README.md)).

## Status

| Piece | State |
|-------|-------|
| Proxmox host + the two VMs | ✅ deployed |
| DNS (UDR split-horizon + wildcard) | ✅ deployed |
| Traefik + Let's Encrypt (netcup DNS-01) | ✅ deployed |
| Authentik SSO (OIDC + forward-auth) | ✅ deployed |
| Dockge management UI | ✅ deployed — [guide](docs/dockge-setup.md) |
| Forgejo CI + registry | ✅ deployed — [guide](docs/forgejo-setup.md) |
| Monitoring: Grafana + Prometheus + Loki + Alloy + Tempo | ✅ complete — [guide](docs/grafana-setup.md), [roadmap](docs/roadmap/monitoring.md) |
| Uptime Kuma (status monitoring + notifications) | ✅ complete — [guide](docs/uptime-kuma-setup.md) |
| CI: triggers & release builds (nightly, tags) | ⬜ planned — [roadmap](docs/roadmap/ci-triggers.md) |
| CI: tests + coverage | ⬜ planned — [roadmap](docs/roadmap/ci-testing.md) |
| CI: code analysis | ⬜ planned — [roadmap](docs/roadmap/ci-code-analysis.md) |
| CI: container scanning + SBOM | ⬜ planned — [roadmap](docs/roadmap/ci-supply-chain.md) |
| Coolify install (apps VM) | ⬜ after the infra VM is finished |
