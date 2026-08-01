# apps VM — third-party services

Third-party software the apps VM runs as Coolify resources. These are
applications you **use**, which makes them a third category: `infra/` holds the
services the lab itself needs, and the rest of this VM runs applications built
from your own source.

**This file records what runs and why that one.** It deliberately records no
compose file, no environment value and no image tag. Those live in the Forgejo
repo **`self-hosted-services`**, one directory per application, which is what
Coolify deploys from. Secrets and runtime state stay in Coolify, exactly as they
do for every other resource on this machine.

## The catalog

| Service | Host | What it is | Database | Also needs | SSO | Implementation |
|---|---|---|---|---|---|---|
| Paperless-ngx | `paperless.` | Scanned-document archive — OCR, tagging, full-text search | Postgres | Redis; optionally Gotenberg + Tika | OIDC | `paperless/` |
| Vaultwarden | `vault.` | Bitwarden-compatible password manager | Postgres | — | **none, deliberate** | `vaultwarden/` |
| Mealie | `mealie.` | Recipe manager — meal planning, shopping lists | Postgres | — | OIDC | `mealie/` |
| LubeLogger | `lube.` | Vehicle maintenance and fuel-mileage log | Postgres | — | OIDC | `lubelogger/` |
| BookStack | `wiki.` | Wiki and documentation | **MariaDB** | — | OIDC | `bookstack/` |

Hosts are subdomains of `thefipster.de`. Implementation is a directory in
`self-hosted-services` — that column is a directory name and nothing more, so
this table does not rot every time an image is bumped.

Each application is put on **Postgres wherever it offers the choice**, matching
the database Authentik, Forgejo and Grafana already run. Three of them
(Vaultwarden, Mealie, LubeLogger) default to SQLite and are moved off it
deliberately; Paperless already ships Postgres; BookStack has no choice to make.

## Two decisions that look like mistakes

Both are recorded here because they are exactly what a later reader would try to
"fix".

### BookStack uses MariaDB, and that is not fixable

BookStack supports **MySQL >= 8.0 or MariaDB >= 10.6** and no PostgreSQL at all.
It is the one service that drags a second database engine into the lab. The
Postgres-native alternatives were checked and each costs more than one extra
container:

| Alternative | Why not |
|---|---|
| Docmost | OIDC is an **Enterprise** feature, billed per seat. A wiki that cannot join Authentik without a subscription is a downgrade for this lab specifically. |
| Outline | Has **no local login** — it requires an external OIDC provider. That makes an Authentik outage take the break-glass documentation with it, which is the same failure Uptime Kuma is deliberately kept out of SSO to avoid. |
| Wiki.js | Appears stale — last commit months old as of June 2026, while BookStack commits weekly. |

BookStack is small (~256 MB), actively maintained, and its OIDC is free. One
extra database is the cheaper price.

### Vaultwarden has no SSO, and it is the only one

Vaultwarden **does** support OIDC — it landed upstream and shipped in 1.36.0. It
is kept on local login anyway, which makes it the third stated exception to the
repo's "anything with native OIDC uses it" rule, alongside
[Uptime Kuma and Home Assistant](../docs/sso-applications.md).

The reason is the same shape as Kuma's: a password manager that dies with the
identity provider is the one outage you cannot recover from, because the
credentials needed to repair Authentik are inside it. Break-glass would mean
SSH at precisely the moment you are already locked out.

Vaultwarden also needs `SIGNUPS_ALLOWED=false` once the first account exists,
and an argon2-hashed `ADMIN_TOKEN`. Both live in its Forgejo directory.

## What this machine gives them for free

- **No DNS record — for any of them.** `*.thefipster.de` already resolves to
  this VM, so a new application needs no entry in
  [docs/dns-records.md](../docs/dns-records.md), the same way `coolify.` and
  `apps.` need none. Do not "fix" this by pinning exact records at this machine:
  riding the wildcard is what makes an address change correct itself everywhere
  at once.
- **TLS.** Coolify's proxy terminates HTTPS with its own Let's Encrypt wildcard.
  Traefik on the infra VM never sees this traffic and needs no configuration for
  any application here.
- **Host metrics.** `init-node-exporter.sh` already runs on this VM and Alloy on
  the infra VM already scrapes it. Nothing here changes that, and none of these
  five is an exporter.

## What it does not give them

- **No container logs.** Alloy tails the *infra* VM's Docker socket, so nothing
  running here reaches Loki — these five, and Coolify's own containers alike.
  This is a gap for the whole machine, not for these applications:
  [docs/roadmap/apps-vm-logs.md](../docs/roadmap/apps-vm-logs.md).
- **No container-state monitoring.** Uptime Kuma's container monitors read the
  infra VM's Docker socket and cannot see this machine's daemon at all. HTTP
  checks through Coolify's proxy are the only signal available for anything
  here. Worth knowing before wondering why the option does nothing.

## Backup

Tiers use the language of [docs/roadmap/backup.md](../docs/roadmap/backup.md),
where **tier 1 is irreplaceable**.

| Service | Tier | What is at stake |
|---|---|---|
| Paperless-ngx | **1** | Scanned documents. The originals are paper, or gone. |
| Vaultwarden | **1** | Vault data, attachments and `rsa_key`. Losing it locks you out of everything else, including the lab. |
| Mealie | 2 | Re-scrapable, tediously. |
| LubeLogger | 2 | Hand-entered service history — no upstream to re-fetch it from. |
| BookStack | 2 | Authored, but small. |

Whole-VM `vzdump` covers this machine today. File-level `restic` is the offsite
path and is still roadmap.

## Where the rest lives

This file is a pointer, not a registry. For any application above:

| You want | Look in |
|---|---|
| compose, env template, image tag | `self-hosted-services/<dir>/` in Forgejo |
| the OIDC client ID, secret, callback URL | `self-hosted-services/<dir>/` in Forgejo |
| Uptime Kuma monitors for it | `self-hosted-services/<dir>/` in Forgejo |
| the running configuration and secrets | Coolify, on this VM |

The three registries in `docs/` cover **infra VM** services, where the
implementation is clickwork with no other home — an Authentik application exists
only in Authentik's database, a Kuma monitor only in Kuma's SQLite, so a file in
this repo is the only durable record. These five have a git repository instead,
which is where a reader already goes to change them. A second copy here would
drift, and a drifted registry is worse than none because it reads as
authoritative.

One consequence, stated plainly: `docs/sso-applications.md` describes itself as
covering every Authentik application, and with four OIDC applications listed
above it no longer does.

See also [apps/README.md](README.md) and the main [README](../README.md).
