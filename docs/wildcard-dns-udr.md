# Wildcard DNS on a UniFi Dream Router

Goal: make **every** `*.homelab.lan` name resolve to one host — the box that runs
the reverse proxy (Coolify, in our case) — so new services need **zero** router
edits. You add the wildcard once; Coolify/Traefik then routes each hostname to
the right container by the HTTP `Host` header, and terminates TLS.

```
foo.homelab.lan ─┐
bar.homelab.lan ─┼─►  <coolify-host-ip>  ─►  Coolify / Traefik  ─►  right container
git.homelab.lan ─┘        (one wildcard A record does this)
```

DNS answers "which IP"; the proxy answers "which container". This guide only
covers the DNS half.

## Prerequisites

- The clients you'll test from use the **UDR as their DNS server** (the default
  for DHCP clients — the same reason your existing `homelab` host entry already
  resolves). Local DNS records only apply to clients resolving *through* the UDR.
- A **DHCP reservation** for the Coolify host so its IP never changes. UDR:
  *Client Devices → (select host) → Settings → **Fixed IP Address*** (assign the
  IP you'll point the wildcard at).

## Add the wildcard record (UniFi UI)

Current UniFi Network path (v9.x / 2026):

1. Open **Settings** (gear, lower-left) → **Routing** → **DNS** tab.
2. Click **Create Entry**.
3. **Type:** leave on **Host (A)**.
4. **Domain Name:** `*.homelab.lan`
5. **IP Address:** the Coolify host's reserved IP (e.g. `192.168.1.40`).
6. **TTL:** leave on **Auto**.
7. Click **Add**.

> **Wildcard caveat.** UniFi's Local DNS is backed by `dnsmasq`, which supports
> wildcard *A* records natively (`address=/homelab.lan/<ip>`), and current
> firmware accepts `*.homelab.lan` in the Domain Name field. Wildcard **CNAME**
> is *not* supported — use Host (A). If your firmware rejects the `*` entry, see
> [Fallbacks](#fallbacks) below.

Keep your existing exact `homelab` → IP host entry too — a `*.homelab.lan`
wildcard covers `foo.homelab.lan` but **not** the bare apex `homelab.lan`.

## Verify at all three layers

These are the three consumers that matter for the pipeline. Test each:

From your **Windows workstation** (PowerShell):

```powershell
Resolve-DnsName foo.homelab.lan
```

From the **lab host** itself (Linux — this is who the host Docker daemon uses):

```bash
getent hosts foo.homelab.lan
```

From **inside a container** (Docker's embedded DNS forwards to the host resolver
→ UDR):

```bash
docker run --rm alpine getent hosts foo.homelab.lan
```

All three should return the Coolify host IP. `foo` is arbitrary — the wildcard
answers for any label, so pick anything to prove it.

## Fallbacks

If the UI won't take a wildcard on your firmware:

- **Per-subdomain A records.** Add one Host (A) per service (`git.homelab.lan`,
  `foo.homelab.lan`, …), all pointing at the Coolify host. Works immediately, but
  you touch the router for every new service — the thing the wildcard avoids.
- **Dedicated resolver on the lab.** Run AdGuard Home / Pi-hole / dnsmasq /
  CoreDNS in the stack, give it the wildcard, and set it as the network's DNS
  server (UDR: *Settings → Networks → (your LAN) → DHCP Name Server → Manual*).
  Then all names — including wildcards — are managed **in this repo**, and the
  router change is one-time. Best long-term fit; heavier to set up.

> `config.gateway.json` (the classic UniFi wildcard hack) targets self-hosted
> controllers and is **not** reliable on UniFi OS consoles like the UDR — prefer
> the UI record or a dedicated resolver instead.

## TLS (the other half, for later)

`.lan` isn't a public domain, so public CAs can't issue for it over HTTP. Two
routes when you wire up Coolify:

- **Internal CA** — Coolify/Traefik (or `step-ca`/`mkcert`) issues certs for
  `*.homelab.lan`; install the CA root once on each device. Fully offline.
- **Real domain + DNS-01 wildcard cert** — own a domain, point
  `*.apps.example.com` at the lab's **private** IP in public DNS (split-horizon),
  and get a genuine Let's Encrypt wildcard via the DNS-01 challenge. No browser
  warnings, nothing exposed to the internet.

## Sources

- UniFi Local DNS path & record types — https://lazyadmin.nl/home-network/unifi-local-and-server-dns-settings/
- UniFi DNS records overview — https://help.ui.com/hc/en-us/articles/15179064940439-UniFi-DNS-Records-and-Local-Hostnames
- Wildcard via dnsmasq background — https://www.grantcohoe.com/unifi/docker/dns/traefik/2022/01/14/unifi-wildcard-dns.html
