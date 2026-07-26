# DNS records (registry)

**Runs on:** the UniFi Dream Router — registry, not a build step

Every DNS entry the lab needs, in one place. All of these are **manual
operations on the UniFi Dream Router** — they live on the router, not in this
repo — so this registry is the record of what must exist. How to add them
(UI path, wildcard caveats, fallbacks, verification at every layer):
[wildcard-dns-udr.md](wildcard-dns-udr.md).

This is **split-horizon DNS**: these names resolve only on the LAN, answered
by the UDR. The public `thefipster.de` zone at netcup holds no A records.

## Hosts

Four machines, each needing a **fixed IP** so the records below have something
stable to point at. UDR: *Client Devices → (select host) → Settings →
**Fixed IP Address***.

| Host | Written below as |
|------|------------------|
| Proxmox host | `pve ip` |
| infra VM | `infra ip` |
| apps VM | `apps ip` |
| home-assistant VM | `ha ip` |

**The addresses themselves are deliberately not written down here** — see
[Why this registry holds no addresses](#why-this-registry-holds-no-addresses).
Read `infra ip` as "whatever address the infra VM actually has", and get it from
the router or the VM, never from a document.

## Records

All entries are type **Host (A)**:

| Domain Name | Points at | Serves |
|---|---|---|
| `*.thefipster.de` | `apps ip` | every app on the apps VM (Coolify routes by HTTP `Host` header) |
| `git.thefipster.de` | `infra ip` | Forgejo web + registry (via Traefik) |
| `dockge.thefipster.de` | `infra ip` | Dockge UI (via Traefik) |
| `auth.thefipster.de` | `infra ip` | Authentik SSO portal (via Traefik) |
| `traefik.thefipster.de` | `infra ip` | Traefik dashboard (gated by Authentik) |
| `grafana.thefipster.de` | `infra ip` | Grafana monitoring UI (via Traefik) |
| `otlp.thefipster.de` | `infra ip` | OpenTelemetry ingest (Alloy via Traefik) |
| `uptime.thefipster.de` | `infra ip` | Uptime Kuma status monitoring (via Traefik) |
| `ha.thefipster.de` | `infra ip` | Home Assistant UI — the **service** (via Traefik, which proxies to the row below) |
| `homeassistant.thefipster.de` | `ha ip` | the HA VM itself — the **machine**; Traefik's backend, and the only lab name served over plain HTTP |
| `pve.thefipster.de` | `pve ip` | Proxmox web UI, and the host node exporter Alloy scrapes (`:9100`) |

An exact host record **beats the wildcard** — that is how the infra names
escape the apps-VM catch-all. The wildcard does **not** cover the bare apex
`thefipster.de`; add an exact apex record only if you ever need one.

## Names the wildcard covers on purpose

These resolve correctly with **no exact record**, because the wildcard's answer —
the apps VM — is the machine they need. They are listed so their absence above
reads as a decision rather than an oversight:

| Domain Name | Resolves via | Used for |
|---|---|---|
| `coolify.thefipster.de` | wildcard → `apps ip` | Coolify's own UI; its proxy routes by `Host` header like any app it hosts |
| `apps.thefipster.de` | wildcard → `apps ip` | the apps VM's node exporter, scraped by Alloy at `:9100` |

**Do not "fix" these by adding exact records.** The wildcard already gives the
right answer, and letting the name follow the wildcard is what makes an apps-VM
IP change correct itself everywhere at once — including in Alloy's scrape config,
which re-resolves per scrape.

Note the contrast with `pve.thefipster.de`, which needs its exact record
precisely *because* the wildcard would answer with the apps VM — the wrong box.
Same mechanism, opposite outcome: whether the wildcard is a safety net or a trap
depends only on whether the name wants the apps VM.

## Home Assistant has two names, on purpose

They are not interchangeable, and swapping them breaks the route:

| Name | Points at | Means |
|---|---|---|
| `ha.thefipster.de` | `infra ip` | the **service**. What you and every browser use. Traefik terminates TLS here with the lab's wildcard certificate. |
| `homeassistant.thefipster.de` | `ha ip` | the **machine**. Traefik's backend, over plain HTTP on `:8123`. Nothing else uses it. |

`ha.` points at the infra VM because that is where the only certificate lives —
pointing it at the HA VM would reach Home Assistant over plain HTTP with none at
all. Which is exactly why it **cannot** double as the backend address: a backend of
`http://ha.thefipster.de:8123` resolves to the infra VM, so Traefik would dial
its own `:8123`, find nothing listening, and 502 every request. The public name
belongs to the front door.

`homeassistant.` needs an **exact** record for the `pve` reason — the wildcard
answers with the apps VM, the wrong box. Unlike the `pve` case, though, getting
this wrong is **loud**: nothing on the apps VM listens on `:8123`, so a missing
record gives connection-refused and a 502 rather than a plausible-looking wrong
page. Verify it anyway:

```bash
getent hosts homeassistant.thefipster.de
```

**When a new infra service arrives, add its row here first.** A missing exact
record silently resolves to the apps VM via the wildcard, and you get
Coolify's 404 behind a perfectly valid certificate — which looks like a
Traefik problem when it isn't.

## Verify

From any LAN client resolving through the UDR:

Each exact record should return the host named in the table above — compare the
answer against the router's reservation list, not against a document:

```bash
getent hosts git.thefipster.de
```

Any unlisted name should fall through to the wildcard and answer with the **apps
VM** — the same address as `git.` must *not* be:

```bash
getent hosts foo.thefipster.de
```

A quick way to see the whole shape at once, infra names together and the wildcard
falling elsewhere:

```bash
for n in git dockge auth traefik grafana otlp uptime ha homeassistant pve nonsense; do printf '%-16s %s\n' "$n" "$(getent hosts $n.thefipster.de | awk '{print $1}')"; done
```

Everything through `ha` should share one address, `homeassistant` and `pve`
should each differ from it, and `nonsense` should match the apps VM.

The full three-layer verification (workstation, VM, inside a container) is in
[wildcard-dns-udr.md](wildcard-dns-udr.md#verify-at-all-three-layers).

## Why this registry holds no addresses

Because they drift, and a written-down address that has drifted is worse than no
address at all — it looks authoritative while being wrong.

They have already drifted here: the build plan said the Proxmox host and the infra
VM would be adjacent, and in the running lab the hypervisor kept its planned
address while the infra VM did not. Nothing about that is broken — every name
above resolves correctly, because the router holds the mapping and the records
follow it. But any document that had recorded both numbers would now be lying in
exactly one place, and you would find out from a confusing failure rather than
from a diff.

So the rule is: **the router is the source of truth for addresses, this registry
is the source of truth for names.** Names are the stable layer; that is the whole
reason the lab addresses everything by hostname — Traefik's backends, Alloy's
scrape targets, every `curl` in every guide.

The useful consequence is that a literal address anywhere in this repo becomes a
**flag**: it means something could not be expressed as a name, which is worth
knowing about and usually worth fixing.

Exactly one thing in the lab genuinely needs an address — `trusted_proxies` in
`home-assistant/configuration.yaml`, because Home Assistant validates that field
as an address or CIDR range and will not accept a hostname. So the repo ships a
**placeholder** there, `<infra-vm-ip>`, filled in on the machine during
[home-assistant-setup.md, step 7](home-assistant-setup.md#7-make-it-reachable-through-traefik).
The value is derived from DNS rather than read off the router:

```bash
getent hosts ha.thefipster.de | awk '{print $1}'
```

That is the proxy's own name resolving to the proxy's own address — the thing HA
is being asked to trust — so the lookup stays correct through any renumbering. It
is also the one value in the lab that does **not** follow DNS automatically, which
is why leaving the placeholder in fails loudly: HA rejects the `http` config
outright instead of quietly trusting nothing.
