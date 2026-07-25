# Lab DNS on a UniFi Dream Router

Goal: resolve the lab's real-domain names **locally**. A wildcard sends every
`*.thefipster.de` name to the apps VM (Coolify's proxy routes by HTTP `Host`
header, so new apps need **zero** router edits), and a handful of exact host
records carve out the infra services.

```
foo.thefipster.de ─┐
bar.thefipster.de ─┼─►  192.168.1.42  ─►  Coolify / Traefik  ─►  right container
baz.thefipster.de ─┘        (one wildcard A record does this)

git.thefipster.de ────►  192.168.1.41  ─►  Traefik  ─►  Forgejo
dockge.thefipster.de ─►  192.168.1.41  ─►  Traefik  ─►  Dockge
```

DNS answers "which IP"; the proxy answers "which container". This guide only
covers the DNS half — TLS is handled by [traefik-setup.md](traefik-setup.md).

**This is split-horizon DNS.** These records exist only on the LAN, answered by
the UDR. The public `thefipster.de` zone at netcup stays **empty of A
records** — publicly the names resolve to nothing, so the lab's layout is never
exposed. (The only public traces are the temporary `_acme-challenge` TXT
records during certificate issuance, and the wildcard's Certificate
Transparency log entry.) Because `thefipster.de` serves nothing public, the
local wildcard can't shadow any real service.

## Prerequisites

- The clients you'll test from use the **UDR as their DNS server** (the default
  for DHCP clients). Local DNS records only apply to clients resolving
  *through* the UDR.
- **DHCP reservations** so the target IPs never change. UDR: *Client Devices →
  (select host) → Settings → **Fixed IP Address*** — infra VM `192.168.1.41`,
  apps VM `192.168.1.42`.

## Add the wildcard record (UniFi UI)

Current UniFi Network path (v9.x / 2026):

1. Open **Settings** (gear, lower-left) → **Routing** → **DNS** tab.
2. Click **Create Entry**.
3. **Type:** leave on **Host (A)**.
4. **Domain Name:** `*.thefipster.de`
5. **IP Address:** the apps VM (`192.168.1.42`).
6. **TTL:** leave on **Auto**.
7. Click **Add**.

> **Wildcard caveat.** UniFi's Local DNS is backed by `dnsmasq`, which supports
> wildcard *A* records natively (`address=/thefipster.de/<ip>`), and current
> firmware accepts `*.thefipster.de` in the Domain Name field. Wildcard
> **CNAME** is *not* supported — use Host (A). If your firmware rejects the `*`
> entry, see [Fallbacks](#fallbacks) below.

The wildcard covers `foo.thefipster.de` but **not** the bare apex
`thefipster.de` — add an exact apex record only if you ever need one.

## Exact host records for infra services

A specific Host (A) record **beats the wildcard** — that's how the infra names
escape the apps-VM catch-all. Add these the same way (Create Entry → Host (A)):

| Domain Name | IP | Serves |
|---|---|---|
| `git.thefipster.de` | `192.168.1.41` | Forgejo web + registry (via Traefik) |
| `dockge.thefipster.de` | `192.168.1.41` | Dockge UI (via Traefik) |
| `auth.thefipster.de` | `192.168.1.41` | Authentik SSO portal (via Traefik) |
| `traefik.thefipster.de` | `192.168.1.41` | Traefik dashboard (gated by Authentik) |
| `pve.thefipster.de` | `192.168.1.40` | Proxmox web UI (optional) |

## Verify at all three layers

These are the three consumers that matter for the pipeline. Test each:

From your **Windows workstation** (PowerShell):

```powershell
Resolve-DnsName foo.thefipster.de
Resolve-DnsName git.thefipster.de
```

From the **lab host** itself (Linux — this is who the host Docker daemon uses):

```bash
getent hosts foo.thefipster.de
getent hosts git.thefipster.de
```

From **inside a container** (Docker's embedded DNS forwards to the host resolver
→ UDR):

```bash
docker run --rm alpine getent hosts foo.thefipster.de
```

`foo` is arbitrary — the wildcard answers for any label, so it should return
`.42`, while `git.thefipster.de` must return `.41` (the specific record wins).

## Fallbacks

If the UI won't take a wildcard on your firmware:

- **Per-subdomain A records.** Add one Host (A) per service, all pointing at
  the apps VM. Works immediately, but you touch the router for every new
  service — the thing the wildcard avoids.
- **Dedicated resolver on the lab.** Run AdGuard Home / Pi-hole / dnsmasq /
  CoreDNS in the stack, give it the wildcard, and set it as the network's DNS
  server (UDR: *Settings → Networks → (your LAN) → DHCP Name Server → Manual*).
  Then all names — including wildcards — are managed **in this repo**, and the
  router change is one-time. Best long-term fit; heavier to set up.

> `config.gateway.json` (the classic UniFi wildcard hack) targets self-hosted
> controllers and is **not** reliable on UniFi OS consoles like the UDR — prefer
> the UI record or a dedicated resolver instead.

## TLS (the other half)

TLS is real and automated: Traefik on the infra VM holds a genuine Let's
Encrypt wildcard for `*.thefipster.de`, issued via the DNS-01 challenge against
the netcup API — no browser warnings, no internal CA, nothing exposed to the
internet. Setup, first issuance, and troubleshooting:
[traefik-setup.md](traefik-setup.md).

## Sources

- UniFi Local DNS path & record types — https://lazyadmin.nl/home-network/unifi-local-and-server-dns-settings/
- UniFi DNS records overview — https://help.ui.com/hc/en-us/articles/15179064940439-UniFi-DNS-Records-and-Local-Hostnames
- Wildcard via dnsmasq background — https://www.grantcohoe.com/unifi/docker/dns/traefik/2022/01/14/unifi-wildcard-dns.html
