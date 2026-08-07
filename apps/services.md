# apps VM — third-party services

Third-party software the apps VM runs as Coolify resources. These are
applications you **use**, which makes them a third category: `infra/` holds the
services the lab itself needs, and the rest of this VM runs applications built
from your own source.

**This file records what runs and why that one.** It deliberately records no
compose file, no environment value and no image tag. Those live in **one Forgejo
repository per application**, which is what Coolify deploys from. Secrets and
runtime state stay in Coolify, exactly as they do for every other resource on
this machine.

## The catalog

| Service | Host | What it is | Database | Also needs | SSO | Repo | Data |
|---|---|---|---|---|---|---|---|
| Paperless-ngx | `paperless.` | Scanned-document archive — OCR, tagging, full-text search. **PDFs and images only** | Postgres | Valkey | OIDC | `paperless` | `/data/paperless` |
| Mealie | `mealie.` | Recipe manager — meal planning, shopping lists | Postgres | — | OIDC | `mealie` | `/data/mealie` |
| LubeLogger | `lube.` | Vehicle maintenance and fuel-mileage log | Postgres | — | OIDC | `lubelogger` | `/data/lubelogger` |
| BookStack | `wiki.` | Wiki and documentation | **MariaDB** | — | OIDC | `bookstack` | `/data/bookstack` |

Hosts are subdomains of `thefipster.de`. Repo is a repository name under
`git.thefipster.de/<owner>/` and nothing more, so this table does not rot every
time an image is bumped.

**Data is a bind mount under `/data/<stack>`**, never a named volume — `/data` is
this VM's 300 GB second disk, the same one Coolify keeps its own store on
([apps-vm-setup.md, step 4](../docs/apps-vm-setup.md#4-mount-the-data-disk)). It is
the apps-VM analogue of the infra VM's `/opt/<stack>` convention, and it exists
for the same reason: a backup job needs a path it can walk. The subdirectories
under each of those paths are the app's business, recorded in its own repo.

Stacks not yet split into their own repo are drafted in
[stacks/](stacks/README.md) and deleted from there once pushed.

Each application is put on **Postgres wherever it offers the choice**, matching
the database Authentik, Forgejo, Vaultwarden and Grafana already run. Two of
them (Mealie, LubeLogger) default to SQLite and are moved off it deliberately;
Paperless already ships Postgres; BookStack has no choice to make.

## Vaultwarden is not on this list, and used to be

It was catalogued here, and it now runs on the **infra VM** as a first-class
stack: [infra/vaultwarden/](../infra/vaultwarden/), guide
[docs/vaultwarden-setup.md](../docs/vaultwarden-setup.md). The row is gone
rather than marked moved, because a catalog of what this machine runs should
not list something it doesn't.

The move is recorded here because the reasoning is about *this* machine. Two
things decided it:

- **Backup.** Everything under `/data` on this VM is excluded from whole-VM
  `vzdump` (`backup=0`) and covered by nothing until this VM joins the
  file-level `restic` layer — the honest state stated under [Backup](#backup)
  below. That is an acceptable gap for recipes and a maintenance log. It is not
  an acceptable gap for the only copy of every credential the lab has. On the
  infra VM the vault sits under `/opt/vaultwarden` and is inside layer 1 today.
- **Build order.** Vaultwarden joins no SSO pattern precisely so it survives an
  Authentik outage, which means it has no reason to be built after Authentik —
  and every reason to be built before it, since from that point on each guide
  generates a secret worth keeping. This VM does not exist until step 12. A
  password manager that arrives after everything it should have been storing is
  a password manager you filled in by hand afterwards.

Unlike the four above, it therefore **does** get rows in the three `docs/`
registries — a DNS record, an SSO non-entry and three Kuma monitors — because
that is what living on the infra VM means.

## Two decisions that look like mistakes

Both are recorded here because they are exactly what a later reader would try to
"fix": one is an engine that does not match the lab's standard, the other is an
absence where the rest of the repo has a stated exception.

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

**It costs a second thing worth naming: BookStack is the one service in the lab
whose local login does not survive joining SSO.** `AUTH_METHOD` takes exactly one
value, so `oidc` *replaces* the email/password form rather than sitting beside it
— there is no configuration in which both work. Every other OIDC service here and
on the infra VM keeps local login as the break-glass path
([sso-applications.md](../docs/sso-applications.md) states that rule). BookStack's
break-glass is instead setting `AUTH_METHOD` back to `standard` in Coolify and
redeploying, which restores the original admin account untouched. That is a real
downgrade — a redeploy instead of a login form — and it is the price of the row
above, not an oversight. Its repo's README says so in place.

### Every application here joins SSO, and that is not a coincidence

All four use OIDC against Authentik. The lab's stated exceptions to the
"anything with native OIDC uses it" rule — Vaultwarden, Uptime Kuma, Home
Assistant — are all **infra VM** services, and each is an exception because
something about recovering the lab depends on it staying reachable when
Authentik is not ([sso-applications.md](../docs/sso-applications.md)).

Nothing on this machine has that property. A recipe manager behind a dead
identity provider is an inconvenience, not a trap, so there is no reason for an
application here to decline the pattern. If one ever does, its repo's README is
where the reasoning goes — not this table.

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
  four is an exporter.

## What it does not give them

- **No container logs.** Alloy tails the *infra* VM's Docker socket, so nothing
  running here reaches Loki — these four, and Coolify's own containers alike.
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
| Mealie | 2 | Re-scrapable, tediously. |
| LubeLogger | 2 | Hand-entered service history — no upstream to re-fetch it from. |
| BookStack | 2 | Authored, but small. |

Every one of those lives under `/data/<stack>` on the second disk — which is
**excluded from whole-VM `vzdump`** (`backup=0`,
[proxmox-setup.md Part 5](../docs/proxmox-setup.md#part-5--create-the-vms)) and
covered by nothing else. The file-level `restic` layer now exists
([docs/backup-setup.md](../docs/backup-setup.md)), but it runs on the **infra
VM** and this machine has not joined the repository
([roadmap/backup.md](../docs/roadmap/backup.md) names that gap and scopes it out).
So the honest state today is: the apps VM's *root* disk is backed up and its
**application data is not**. Paperless is tier 1 and ships its own
`document_exporter`; run it by hand and copy `/data/paperless/export` off the box
until this VM joins that repository.

That gap is the reason Paperless is now the **only** tier 1 row here — the
other one, Vaultwarden, was moved to the infra VM partly to get out from under
it ([above](#vaultwarden-is-not-on-this-list-and-used-to-be)).

## Where the rest lives

This file is a pointer, not a registry. For any application above:

| You want | Look in |
|---|---|
| compose, env template, image tag | `git.thefipster.de/<owner>/<repo>` |
| the Authentik provider/application values and callback URL | that repo's `README.md`, section **SSO (OIDC via Authentik)** |
| the OIDC client ID and secret | Coolify's environment editor — generated per provider, never committed |
| Uptime Kuma monitors for it | that repo's `README.md`, section **Uptime Kuma monitors** |
| the running configuration and secrets | Coolify, on this VM |
| the data on disk | `/data/<stack>` on this VM |

The three registries in `docs/` cover **infra VM** services, where the
implementation is clickwork with no other home — an Authentik application exists
only in Authentik's database, a Kuma monitor only in Kuma's SQLite, so a file in
this repo is the only durable record. These four have a git repository each
instead, which is where a reader already goes to change them. A second copy here would
drift, and a drifted registry is worse than none because it reads as
authoritative.

`docs/sso-applications.md` scopes itself to the infra VM for exactly this
reason and names this catalog as where the apps-VM applications live — the two
files point at each other on purpose.

See also [apps/README.md](README.md) and the main [README](../README.md).
