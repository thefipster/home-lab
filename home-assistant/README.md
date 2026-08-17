# home-assistant VM — Home Assistant OS

The home-assistant VM runs **Home Assistant OS** — the full
appliance including the Supervisor, so add-ons like ESPHome and Mosquitto install
from HA's own store.

**Guide: [docs/guides/home-assistant-setup.md](../docs/guides/home-assistant-setup.md).**

## Why there is no compose file and no init script

HAOS is an **appliance**. It manages its own OS, its own container runtime and
its own add-ons through the Supervisor, and there is no shell of ours inside it —
so unlike every `infra/` stack, this repo is **not** this machine's source of
truth. There is nothing here to `docker compose up`, nothing to symlink into
`/opt/stacks`, and no `.env` to seed.

That makes it the only machine in the lab with no script at all: `infra/` stacks
have one each, the apps VM has four, this has none.

| File | Purpose |
|------|---------|
| `configuration.yaml` | A **fragment** to *append* to `/config/configuration.yaml` inside the VM. One block, `prometheus:`, so Alloy can scrape it. The **only** file in this repo that belongs on a machine the repo cannot write to — the Forgejo workflow templates were the other one, and they were deleted once the real workflows lived in the app repo. This one has no other repo to move to. |

**It carries no `http:` block, and adding one is an error.** HA **2026.8** moved
the HTTP server settings — port, SSL certificate and SSL key included — out of
YAML and into *Settings → System → Network*, and raises a repair issue if an
`http:` block remains in `configuration.yaml`. The Let's Encrypt add-on's own
documentation still tells you to add one; do not. There is no `trusted_proxies`
value anywhere either, in YAML or in the UI: nothing proxies this machine, which
is why this repo records no literal IP address anywhere.

**Append it, never copy it over.** A fresh HAOS install ships
`configuration.yaml` with `default_config:`; replacing that file strips the whole
default integration set. The fragment holds only keys HAOS does not define
itself, so appending cannot collide.

## How it fits the lab

- **One name, and its own TLS.** `ha.thefipster.de` → **this VM**, which answers
  on `:443` with an exact Let's Encrypt certificate of its own, issued by the
  **Let's Encrypt add-on** over the same netcup DNS-01 challenge Traefik uses.
  Nothing on the infra VM proxies it, so the house's front door does not go down
  with a reboot over there — the same independence the Proxmox web UI keeps. The
  add-on is one-shot, so a weekly HA automation is what renews the certificate
  ([timetable.md](../docs/reference/timetable.md)).
- **No SSO, deliberately — and not available either.** HA has no OIDC, and
  forward-auth is a Traefik middleware, so with no Traefik router there is
  nothing to attach one to. Even where it was possible it was refused: it breaks
  the companion app, webhooks and every local API caller. HA keeps its own local
  login. Reasoning in
  [docs/reference/sso-applications.md](../docs/reference/sso-applications.md).
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
