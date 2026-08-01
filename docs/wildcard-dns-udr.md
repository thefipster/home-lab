# Lab DNS on a UniFi Dream Router

**Runs on:** the UniFi Dream Router

**Prerequisite:** [proxmox-setup.md](proxmox-setup.md) complete — both VMs
exist and have DHCP reservations, so the records below have something stable to
point at.

Goal: resolve the lab's real-domain names **locally**. A wildcard sends every
`*.thefipster.de` name to the apps VM (Coolify's proxy routes by HTTP `Host`
header, so new apps need **zero** router edits), and a handful of exact host
records carve out the infra services.

```
foo.thefipster.de ─┐
bar.thefipster.de ─┼─►  apps ip   ─►  Coolify / Traefik  ─►  right container
baz.thefipster.de ─┘         (one wildcard A record does this)

git.thefipster.de ────►  infra ip  ─►  Traefik  ─►  Forgejo
dockge.thefipster.de ─►  infra ip  ─►  Traefik  ─►  Dockge
```

DNS answers "which host"; the proxy answers "which container". This guide only
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
  (select host) → Settings → **Fixed IP Address*** — the reservation targets
  are in the registry: [dns-records.md](dns-records.md).

## Add the wildcard record (UniFi UI)

Current UniFi Network path (v9.x / 2026):

1. Open **Settings** (gear, lower-left) → **Routing** → **DNS** tab.
2. Click **Create Entry**.
3. **Type:** leave on **Host (A)**.
4. **Domain Name:** `*.thefipster.de`
5. **IP Address:** the `apps ip` — see [dns-records.md](dns-records.md).
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
escape the apps-VM catch-all. The records to add are maintained in the
registry: **[dns-records.md](dns-records.md)**. Add every row there the same
way (Create Entry → Host (A)) — a missing record only surfaces much later, as
Coolify's 404 behind a valid certificate.

## Verify at all three layers

These are the three consumers that matter for the pipeline. Test each:

From your **Windows workstation** (PowerShell):

```powershell
Resolve-DnsName foo.thefipster.de
```

```powershell
Resolve-DnsName git.thefipster.de
```

From a **Linux shell in the lab** — either freshly created VM, or the Proxmox
host:

```bash
getent hosts foo.thefipster.de
```

```bash
getent hosts git.thefipster.de
```

From **inside a container** (Docker's embedded DNS forwards to the host resolver
→ UDR). Nothing in the lab has Docker yet at this point in the build — the infra
VM gets it in [infra-vm-setup.md](infra-vm-setup.md), step 3; run this layer from
there when you arrive:

```bash
docker run --rm alpine getent hosts foo.thefipster.de
```

`foo` is arbitrary — the wildcard answers for any label, so it should return the
`apps ip`, while `git.thefipster.de` must return the `infra ip` (the specific
record wins).

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

## Next

**[infra-vm-setup.md](infra-vm-setup.md)** — the checkout and the host
underneath it, on the first VM. Then
[traefik-setup.md](traefik-setup.md) gives that machine TLS, the other half of
what this guide started: Traefik holds a genuine Let's Encrypt wildcard for
`*.thefipster.de`, issued via the DNS-01 challenge against the netcup API — no
browser warnings, no internal CA, nothing exposed to the internet. DNS answers
"which IP"; Traefik
answers "which container".

The full sequence is the [README build order](../README.md#build-order).

## Sources

- UniFi Local DNS path & record types — https://lazyadmin.nl/home-network/unifi-local-and-server-dns-settings/
- UniFi DNS records overview — https://help.ui.com/hc/en-us/articles/15179064940439-UniFi-DNS-Records-and-Local-Hostnames
- Wildcard via dnsmasq background — https://www.grantcohoe.com/unifi/docker/dns/traefik/2022/01/14/unifi-wildcard-dns.html
