# Home Lab

Infrastructure-as-notes for a personal homelab built on **Proxmox VE**. The
physical server is a hypervisor; everything real runs in VMs, split by purpose:
**infrastructure** services on one, **your own apps** on another. This repo holds
the compose stacks, setup scripts, and step-by-step guides to reproduce it.

## Architecture

```
UniFi Dream Router  —  DHCP + DNS  (homelab, *.homelab.lan)
        │  LAN 192.168.1.0/24
        │
  Proxmox VE  ·  pve.homelab.lan  ·  .40   (hypervisor only)
        │
        ├───────────────────────┐
        │                       │
  ┌─ infra VM (.41) ─┐   ┌─ apps VM (.42) ─┐
  │ Forgejo: CI +    │   │ Coolify: PaaS   │
  │   registry       │   │                 │
  │ Dockge: compose  │   │ your apps       │
  │   management UI  │   │                 │
  └──────────────────┘   └─────────────────┘
```

| Layer | Runs | Purpose |
|-------|------|---------|
| **Proxmox host** | the bare server | Type-1 hypervisor only — no Docker on the host, so a bad container day can't take the box down. |
| **infra VM** | Forgejo + Dockge | CI/CD (GitHub → mirror → build → push to the built-in registry) and a web UI for managing compose stacks. |
| **apps VM** | Coolify | A self-hosted PaaS that deploys and runs *your* applications with domains + HTTPS. Owns its own Docker. |

Why two VMs instead of Docker-on-the-host: isolation and per-VM snapshots. Coolify
wants to own a host outright; keeping it off the infra box avoids that conflict.

## Networking & DNS

Everything sits on the LAN behind a UniFi Dream Router. Names resolve via the
router's Local DNS:

- `homelab` → infra VM — Forgejo on `:3000` (plain HTTP for now).
- `*.homelab.lan` → apps VM — Coolify's proxy routes each hostname to the right
  app by the HTTP `Host` header, so new apps need **no** new DNS records.

See [docs/wildcard-dns-udr.md](docs/wildcard-dns-udr.md) for the wildcard setup.

## Repository layout

```
.
├── docs/                        Guides
│   ├── proxmox-setup.md          Proxmox host + the two VMs (start here)
│   ├── forgejo-setup.md          Forgejo CI/registry on the infra VM
│   └── wildcard-dns-udr.md       *.homelab.lan on the UniFi Dream Router
├── scripts/                     Setup automation (run on a VM)
│   ├── init-host.sh              Install Docker Engine + compose plugin
│   └── init-forgejo.sh           Forgejo Part 0: data tree, DOCKER_GID, registry
├── infra/                       Stacks for the infra VM
│   ├── forgejo/
│   │   ├── docker-compose.yml    Forgejo + Postgres + Actions runner
│   │   └── config.yml            Runner config
│   └── dockge/
│       └── compose.yaml          Dockge (compose management UI)
└── apps/                        Apps VM (Coolify) — see apps/README.md
```

## Build order

1. **[Proxmox host + VMs](docs/proxmox-setup.md)** — wipe the server, install the
   hypervisor, create the `infra` and `apps` VMs.
2. **[DNS](docs/wildcard-dns-udr.md)** — reservations + the `*.homelab.lan` wildcard.
3. **[Forgejo](docs/forgejo-setup.md)** — bring up CI/registry on the infra VM,
   plus Dockge for stack management.
4. **Coolify** on the apps VM — *guide TBD* (see [apps/README.md](apps/README.md)).

## Status

| Piece | State |
|-------|-------|
| Forgejo stack + setup scripts | ✅ done |
| Dockge management UI | ✅ done |
| Proxmox + DNS guides | ✅ written (not yet built out) |
| Coolify install + HTTPS | ⬜ TBD — TLS approach undecided (internal CA vs. real domain) |

> Still plain HTTP throughout. Terminating TLS on `*.homelab.lan` — via Coolify's
> proxy for apps, and a reverse proxy in front of Forgejo — is the next milestone.
