# Internal domains via Traefik + Let's Encrypt (netcup DNS-01)

**Date:** 2026-07-25
**Status:** Approved design, pending implementation plan

## Goal

Replace hostname/IP references (`homelab`, `homelab:3000`, `*.homelab.lan`) with
real domain names under `thefipster.de`, served over trusted HTTPS. Certificates
come from Let's Encrypt via the DNS-01 challenge against the netcup DNS API, so
nothing is exposed to the internet and no inbound connectivity is required.

## Constraints & decisions made

- **Public CA requires a real domain.** Let's Encrypt cannot issue for `.home`
  / `.lan` / `.internal`. All names live under `thefipster.de` (flat on the
  apex: `git.thefipster.de`, `dockge.thefipster.de`, app names directly under
  the apex).
- **`thefipster.de` is lab-only.** Nothing public depends on it, so a local
  wildcard DNS record is safe.
- **Scope: infra VM now, apps-ready.** Traefik is built on the infra VM
  (Forgejo + Dockge). The apps VM (Coolify, not yet installed) is documented
  but not built: Coolify's bundled Traefik gets the same netcup env vars later
  and issues its own wildcard cert independently.
- **Greenfield — no migration.** The lab is being rebuilt from scratch, so
  there is no coexistence or rollback plan. The repo's docs are rewritten as a
  bare-server-to-current-state setup guide in which the domain scheme exists
  from day one; `homelab` / `*.homelab.lan` never appear.
- **Approach chosen: Traefik per VM, each doing its own DNS-01** (over a
  central proxy, which would couple the VMs; and over a standalone cert
  fetcher, which adds cert-distribution plumbing).

## Architecture

```
UniFi Dream Router — local DNS (split horizon)
  git.thefipster.de     → .41 (infra VM)     exact host record
  dockge.thefipster.de  → .41 (infra VM)     exact host record
  pve.thefipster.de     → .40 (Proxmox)      exact host record (optional)
  *.thefipster.de       → .42 (apps VM)      wildcard — future Coolify apps
        │
  infra VM (.41)
  ┌─────────────────────────────────────────────┐
  │ Traefik  :80 :443                           │
  │   ├─ git.thefipster.de    → forgejo:3000    │
  │   │    (web UI + container registry)        │
  │   └─ dockge.thefipster.de → dockge:5001     │
  │ ACME DNS-01 via netcup → *.thefipster.de    │
  └─────────────────────────────────────────────┘
```

### DNS: two independent layers

- **Public zone (netcup):** stays empty of A records. Traefik uses the netcup
  API only to create/delete temporary `_acme-challenge` TXT records during
  issuance. The LAN layout never appears in public DNS.
- **Local zone (UDR):** the wildcard setup from `docs/wildcard-dns-udr.md`,
  rooted at `*.thefipster.de`. Wildcard points at the apps VM so future
  Coolify apps need zero DNS work; exact-host overrides for infra services
  point at `.41`.

### Certificates

- One wildcard cert per VM: `thefipster.de` + `*.thefipster.de`, requested via
  a default `tls.domains` entry so a single cert serves every router.
- Only the wildcard entry appears in Certificate Transparency logs; individual
  hostnames stay private.
- Port 80 exists solely for a permanent redirect to HTTPS. DNS-01 needs no
  inbound connectivity.

## Components

### New stack: `infra/traefik/`

Managed via Dockge like the other stacks.

- **`compose.yaml`** — Traefik v3, ports 80/443, static config via command
  flags. Key configuration:
  - `certificatesresolvers.letsencrypt.acme.dnschallenge.provider=netcup`
  - `NETCUP_CUSTOMER_NUMBER`, `NETCUP_API_KEY`, `NETCUP_API_PASSWORD` from `.env`
  - `NETCUP_PROPAGATION_TIMEOUT=900`, `NETCUP_POLLING_INTERVAL=30` — netcup's
    nameservers publish TXT records slowly; without generous timeouts, first
    issuance fails. First issuance may take 10–15 minutes; renewals are
    unattended.
  - ACME storage (`acme.json`) bind-mounted under the same data-tree
    convention as the Forgejo stack, so certs survive stack recreation.
  - A Let's Encrypt **staging** resolver configured alongside production
    (commented) for first-run testing without burning rate limits.
- **`.env.example`** — committed template with placeholder netcup values. The
  real `.env` is gitignored and lives only on the VM. Netcup API credentials
  are created in the netcup Customer Control Panel (Master Data → API).

### Routing via labels on target stacks

- **`infra/forgejo/compose.yaml`:** router rule ``Host(`git.thefipster.de`)``
  → service port 3000. `ROOT_URL` becomes `https://git.thefipster.de/`. Port
  3000 is no longer published on the host; Traefik reaches Forgejo over a
  shared Docker network. SSH (port 22 mapping) is unchanged.
- **`infra/dockge/compose.yaml`:** same treatment for `dockge.thefipster.de`
  → port 5001, no longer published.
- **Shared external Docker network `proxy`** joins Traefik to both stacks;
  created by an init script or documented one-liner.

### Registry consequence

Forgejo's container registry shares its web port, so
`docker login git.thefipster.de` and `docker pull git.thefipster.de/<owner>/<repo>`
work over trusted HTTPS on 443. Because the build is greenfield, the
insecure-registry machinery is **never introduced at all**:

- no `insecure-registries` entry in daemon.json (drop the step from
  `scripts/init-forgejo.sh` and all docs)
- no `REGISTRY_ADDR` plumbing in `scripts/init-forgejo.sh`
- the Actions runner registers directly against `https://git.thefipster.de`.

## Build order (greenfield, bare server → current state)

The repo's guides describe this sequence; the domain scheme exists from the
first step:

1. **Proxmox** (`proxmox-setup.md`) — host installed as `pve.thefipster.de`,
   infra VM (.41) and apps VM (.42) created.
2. **DNS** (`wildcard-dns-udr.md`) — DHCP reservations; exact host records
   `git.thefipster.de` → .41, `dockge.thefipster.de` → .41; wildcard
   `*.thefipster.de` → .42.
3. **Host prep on infra VM** — `init-host.sh` (Docker), `init-dockge.sh`.
4. **Traefik** (`traefik-setup.md`, new) — netcup API credentials into `.env`,
   bring up with the **staging** resolver first to validate credentials and
   propagation timing (the slow, failure-prone part), then flip to production,
   delete `acme.json`, reissue.
5. **Forgejo** (`forgejo-setup.md`) — stack comes up behind Traefik from the
   start; first-run setup happens at `https://git.thefipster.de`. Runner
   registers against that URL.
6. **Coolify on the apps VM** — later; apps-ready notes only.

### Verification

- `curl -I https://git.thefipster.de` and `https://dockge.thefipster.de` serve
  a Let's Encrypt production cert.
- `docker login git.thefipster.de` succeeds from a clean daemon — no
  insecure-registries anywhere.
- An Actions build pushes to `git.thefipster.de/<owner>/<repo>` successfully.

## Documentation changes (part of this work)

Every guide is rewritten as if the domain scheme always existed — no
"later/until then" hedging, no `homelab` names:

- **`README.md`** — architecture diagram and Networking & DNS section
  re-rooted; `infra/traefik/` added to the repo layout; Traefik inserted into
  the build order; status table updated.
- **`docs/proxmox-setup.md`** — installer FQDN `pve.thefipster.de`; Part 6 DNS
  records become the final scheme above; the interim "Forgejo is plain
  `homelab:3000` until the proxy exists" notes are removed.
- **`docs/wildcard-dns-udr.md`** — re-rooted to `*.thefipster.de` → apps VM
  with exact-host overrides for infra services; the speculative "TLS (the
  other half, for later)" section is replaced by a pointer to
  `traefik-setup.md`.
- **`docs/forgejo-setup.md`** — reordered so Traefik precedes Forgejo
  first-run; all `homelab:3000` / insecure-registry content deleted; runner
  registration, registry usage, and verification use
  `https://git.thefipster.de`.
- **`docs/traefik-setup.md`** (new) — netcup API credential creation, `.env`
  handling, staging→production first issuance, troubleshooting propagation
  timeouts.

## Error handling

- **Failed issuance (propagation timeout):** Traefik retries automatically;
  staging-first ordering means production rate limits are never at risk during
  setup. If timeouts persist, raise `NETCUP_PROPAGATION_TIMEOUT`.
- **netcup API outage at renewal time:** Traefik renews 30 days before expiry
  and retries; a multi-day outage would be needed to cause impact.
- **Escape hatch if netcup propagation becomes unbearable:** delegate
  `_acme-challenge.thefipster.de` via CNAME to a faster ACME-DNS service
  (acme-dns, deSEC). Documented as an option, not built.

## Out of scope

- Coolify installation and its proxy configuration (documented as "apps-ready"
  notes only: same three netcup env vars, own wildcard cert).
- TLS for Proxmox (`pve.thefipster.de`) — possible later with the same
  wildcard approach, separate effort.
- Internal CA (step-ca) — rejected in favor of a real domain.
