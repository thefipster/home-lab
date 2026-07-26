# DNS records (registry)

Every DNS entry the lab needs, in one place. All of these are **manual
operations on the UniFi Dream Router** — they live on the router, not in this
repo — so this registry is the record of what must exist. How to add them
(UI path, wildcard caveats, fallbacks, verification at every layer):
[wildcard-dns-udr.md](wildcard-dns-udr.md).

This is **split-horizon DNS**: these names resolve only on the LAN, answered
by the UDR. The public `thefipster.de` zone at netcup holds no A records.

## DHCP reservations

Fixed IPs first — every record below points at one of them. UDR: *Client
Devices → (select host) → Settings → **Fixed IP Address***.

| Host | IP |
|------|----|
| Proxmox host | `192.168.1.40` |
| infra VM | `192.168.1.41` |
| apps VM | `192.168.1.42` |

## Records

All entries are type **Host (A)**:

| Domain Name | IP | Serves |
|---|---|---|
| `*.thefipster.de` | `192.168.1.42` | every app on the apps VM (Coolify routes by HTTP `Host` header) |
| `git.thefipster.de` | `192.168.1.41` | Forgejo web + registry (via Traefik) |
| `dockge.thefipster.de` | `192.168.1.41` | Dockge UI (via Traefik) |
| `auth.thefipster.de` | `192.168.1.41` | Authentik SSO portal (via Traefik) |
| `traefik.thefipster.de` | `192.168.1.41` | Traefik dashboard (gated by Authentik) |
| `grafana.thefipster.de` | `192.168.1.41` | Grafana monitoring UI (via Traefik) |
| `otlp.thefipster.de` | `192.168.1.41` | OpenTelemetry ingest (Alloy via Traefik) |
| `pve.thefipster.de` | `192.168.1.40` | Proxmox web UI (optional) |

An exact host record **beats the wildcard** — that is how the infra names
escape the apps-VM catch-all. The wildcard does **not** cover the bare apex
`thefipster.de`; add an exact apex record only if you ever need one.

**When a new infra service arrives, add its row here first.** A missing exact
record silently resolves to the apps VM via the wildcard, and you get
Coolify's 404 behind a perfectly valid certificate — which looks like a
Traefik problem when it isn't.

## Verify

From any LAN client resolving through the UDR:

Each exact record should return the IP from the table above:

```bash
getent hosts git.thefipster.de
```

Any unlisted name should fall through to the wildcard, `192.168.1.42`:

```bash
getent hosts foo.thefipster.de
```

The full three-layer verification (workstation, VM, inside a container) is in
[wildcard-dns-udr.md](wildcard-dns-udr.md#verify-at-all-three-layers).
