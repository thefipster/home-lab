# Home Lab

Infrastructure-as-notes for a personal homelab built on **Proxmox VE**. The
physical server is a hypervisor; everything real runs in VMs, split by purpose:
**infrastructure** services on one, **your own apps** on another. This repo holds
the compose stacks, setup scripts, and step-by-step guides to reproduce it.

## Architecture

```
UniFi Dream Router  —  DHCP + DNS  (git/dockge → infra VM, *.thefipster.de → apps VM)
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
  └──────────────────┘   └─────────────────┘
```

| Layer | Runs | Purpose |
|-------|------|---------|
| **Proxmox host** | the bare server | Type-1 hypervisor only — no Docker on the host, so a bad container day can't take the box down. |
| **infra VM** | Traefik + Authentik + Forgejo + Dockge | TLS termination and routing for real domain names, CI/CD (GitHub → mirror → build → push to the built-in registry), and a web UI for managing compose stacks. SSO (Authentik) fronts the infra UIs. |
| **apps VM** | Coolify | A self-hosted PaaS that deploys and runs *your* applications with domains + HTTPS. Owns its own Docker. |

Why two VMs instead of Docker-on-the-host: isolation and per-VM snapshots. Coolify
wants to own a host outright; keeping it off the infra box avoids that conflict.

## Networking & DNS

Everything sits on the LAN behind a UniFi Dream Router. Names are real
subdomains of `thefipster.de`, resolved **locally** by the router (split
horizon — the public zone holds no A records):

- `git.thefipster.de` → infra VM — Forgejo web + container registry, HTTPS via
  Traefik.
- `dockge.thefipster.de` → infra VM — the Dockge management UI.
- `auth.thefipster.de` → infra VM — Authentik SSO portal, HTTPS via Traefik.
- `traefik.thefipster.de` → infra VM — Traefik dashboard, gated by Authentik.
- `*.thefipster.de` → apps VM — Coolify's proxy routes each hostname to the
  right app by the HTTP `Host` header, so new apps need **no** new DNS records.

Certificates are genuine Let's Encrypt wildcards, issued via the DNS-01
challenge against the netcup DNS API — nothing is exposed to the internet. See
[docs/wildcard-dns-udr.md](docs/wildcard-dns-udr.md) for the DNS setup and
[docs/traefik-setup.md](docs/traefik-setup.md) for TLS.

## Repository layout

```
.
├── docs/                        Guides
│   ├── proxmox-setup.md          Proxmox host + the two VMs (start here)
│   ├── wildcard-dns-udr.md       Lab DNS (thefipster.de) on the UniFi Dream Router
│   ├── traefik-setup.md          Traefik + Let's Encrypt via netcup DNS-01
│   ├── forgejo-setup.md          Forgejo CI/registry on the infra VM
│   └── authentik-setup.md        SSO with Authentik (OIDC + forward-auth)
├── scripts/                     Setup automation (run on a VM)
│   ├── init-host.sh              Install Docker Engine + compose plugin
│   ├── init-dockge.sh            Bring up the Dockge management UI
│   ├── init-traefik.sh           Traefik prep: proxy network, ACME dir, .env
│   ├── init-forgejo.sh           Forgejo Part 0: data tree, DOCKER_GID
│   └── init-authentik.sh         Authentik: data tree, generate secrets
├── infra/                       Stacks for the infra VM
│   ├── traefik/
│   │   ├── compose.yaml          Traefik v3 — TLS termination + routing
│   │   └── .env.example          netcup API credentials template
│   ├── authentik/
│   │   ├── compose.yaml          Authentik SSO (server, worker, postgres, redis)
│   │   └── .env.example          secret-key / DB / bootstrap template
│   ├── forgejo/
│   │   ├── compose.yaml          Forgejo + Postgres + Actions runner
│   │   └── config.yml            Runner config
│   └── dockge/
│       └── compose.yaml          Dockge (compose management UI)
└── apps/                        Apps VM (Coolify) — see apps/README.md
```

## Build order

1. **[Proxmox host + VMs](docs/proxmox-setup.md)** — wipe the server, install the
   hypervisor, create the `infra` and `apps` VMs.
2. **[DNS](docs/wildcard-dns-udr.md)** — reservations, the `*.thefipster.de`
   wildcard, and the infra host records.
3. **[Traefik](docs/traefik-setup.md)** — reverse proxy + wildcard TLS on the
   infra VM (netcup DNS-01).
4. **[Forgejo](docs/forgejo-setup.md)** — bring up CI/registry on the infra VM,
   plus Dockge for stack management.
5. **[Authentik](docs/authentik-setup.md)** — SSO on the infra VM; bring Forgejo
   (OIDC), Dockge and the Traefik dashboard (forward-auth) under it.
6. **Coolify** on the apps VM — *guide TBD* (see [apps/README.md](apps/README.md)).

## Status

| Piece | State |
|-------|-------|
| Forgejo stack + setup scripts | ✅ done |
| Dockge management UI | ✅ done |
| Traefik + Let's Encrypt (netcup DNS-01) | ✅ stack + guide in repo |
| Authentik SSO (OIDC + forward-auth) | ✅ stack + guide in repo |
| Proxmox + DNS guides | ✅ written (not yet built out) |
| Coolify install | ⬜ TBD — proxy gets the same netcup DNS-01 setup |
