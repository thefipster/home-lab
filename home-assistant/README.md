# home-assistant VM — Home Assistant OS

The home-assistant VM runs **Home Assistant OS** — the full
appliance including the Supervisor, so add-ons like ESPHome and Mosquitto install
from HA's own store.

**Guide: [docs/home-assistant-setup.md](../docs/home-assistant-setup.md).**

## Why there is no compose file and no init script

HAOS is an **appliance**. It manages its own OS, its own container runtime and
its own add-ons through the Supervisor, and there is no shell of ours inside it —
so unlike every `infra/` stack, this repo is **not** this machine's source of
truth. There is nothing here to `docker compose up`, nothing to symlink into
`/opt/stacks`, and no `.env` to seed.

That makes it the only machine in the lab with no script at all: `infra/` stacks
have one each, the apps VM has three, this has none.

| File | Purpose |
|------|---------|
| `configuration.yaml` | A **fragment** to *append* to `/config/configuration.yaml` inside the VM. Two blocks: `http:` (so HA trusts Traefik's proxy hop) and `prometheus:` (so Alloy can scrape it). Same idea as `infra/forgejo/build-and-push.yml` — a real file in the repo that lives somewhere else. |

**Append it, never copy it over.** A fresh HAOS install ships
`configuration.yaml` with `default_config:`; replacing that file strips the whole
default integration set. The fragment holds only keys HAOS does not define
itself, so appending cannot collide.

## How it fits the lab

- **Two names, one machine.** `ha.thefipster.de` → the **infra VM**, where
  Traefik terminates TLS with the lab's wildcard certificate; that is the
  **service**, and what every browser uses. `homeassistant.thefipster.de` → this
  VM is the **machine**, and is what Traefik dials over plain HTTP on
  `:8123`. They cannot be collapsed: the public name has to mean the proxy for
  TLS to work, so it cannot also be the proxy's backend. HA has no container on
  the infra VM to hang Traefik labels on, so its router is declared as a file:
  `infra/traefik/dynamic/ha.yaml`.
- **No SSO, deliberately.** HA has no OIDC, and forward-auth would break the
  companion app, webhooks and every local API caller. It keeps its own local
  login — the lab's second stated exception, after Uptime Kuma. Reasoning in
  [docs/sso-applications.md](../docs/sso-applications.md).
- **Monitored** via `/api/prometheus`, scraped by Alloy as `job="homeassistant"`.
  Those are entity metrics, not machine counters, so they do not appear on the
  Node Exporter Full dashboard.
- **No USB passthrough.** The lab's Zigbee coordinators are Ethernet adapters, so
  HA reaches them over the LAN and the hypervisor is not involved.

## Backups

Proxmox snapshots plus HA's own backups (*Settings → System → Backups*). Nothing
in this VM is reproducible from this repo, which is the trade an appliance asks
for.

See also the main [README](../README.md).
