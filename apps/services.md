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
| Immich | `immich.` | Photo and video library — phone backup, face and object search | Postgres **+ VectorChord** | Valkey, machine-learning container | OIDC | `immich` | `/data/immich` |
| Habitica | `habitica.` | Habit tracker and to-do list as a role-playing game | **MongoDB** | — | **none** | `habitica` | `/data/habitica` |

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
Paperless already ships Postgres; BookStack and Habitica have no choice to make.
Immich is on Postgres but not on the *stock* image — it needs a vector extension
the official one does not carry, which is the row below rather than a third
engine.

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

Unlike the six above, it therefore **does** get rows in the three `docs/`
registries — a DNS record, an SSO non-entry and three Kuma monitors — because
that is what living on the infra VM means.

## Three decisions that look like mistakes

All three are recorded here because they are exactly what a later reader would
try to "fix": two are databases that do not match the lab's standard, and one is
an absence where the rest of the repo has a stated exception.

### BookStack uses MariaDB, and that is not fixable

BookStack supports **MySQL >= 8.0 or MariaDB >= 10.6** and no PostgreSQL at all.
It is the service that dragged a second database engine into the lab, and
Habitica later added a third. The Postgres-native alternatives were checked and
each costs more than one extra container:

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

### Habitica runs MongoDB, and not by choice

Habitica stores everything in **MongoDB** and supports nothing else — it needs
multi-document transactions, which is also why even a single node has to run as
a replica set. It is the third engine in the lab after Postgres and BookStack's
MariaDB, and unlike BookStack there was no alternative to weigh: no comparable
application exists, because the thing being self-hosted *is* Habitica.

The consequences are all in its repo's README: no credentials on the database
(authentication on a replica set also wants a member keyfile), the health check
doubling as the replica-set initiator, and a dump rather than a directory copy
as the backup form.

### Every application here joins SSO except one, and the exception is not a choice

Five of the six use OIDC against Authentik. The lab's stated exceptions to the
"anything with native OIDC uses it" rule — Vaultwarden, Uptime Kuma, Home
Assistant — are all **infra VM** services, and each is an exception because
something about recovering the lab depends on it staying reachable when
Authentik is not ([sso-applications.md](../docs/sso-applications.md)).

Nothing on this machine has that property. A recipe manager behind a dead
identity provider is an inconvenience, not a trap, so no application here
*declines* the pattern.

**Habitica cannot join it.** It has no OIDC support at all — its own accounts
plus Google and Apple social login, neither of which this lab runs. The other
pattern is out of reach for a different reason, and it is a property of this
machine rather than of Habitica: the lab's forward-auth wiring is labels on the
Authentik container behind the **infra VM's** Traefik, and Coolify runs its own
separate Traefik here that knows nothing about that middleware or its outpost
routes. Putting forward-auth in front of an app on this VM would mean a second,
hand-maintained copy of that wiring inside Coolify's proxy configuration.

So **OIDC is the only SSO pattern available on the apps VM**, and an application
without it gets none. Habitica's guard is `INVITE_ONLY` once the accounts exist,
plus the fact that nothing here is reachable from outside the LAN. The detail
lives in its repo's README, as it does for every other per-service decision —
this table carries only the fact that the row says `none`.

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
  six is an exporter.

## What it does not give them

- **No container logs.** Alloy tails the *infra* VM's Docker socket, so nothing
  running here reaches Loki — these six, and Coolify's own containers alike.
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
| Immich | **1** | Phone photos. It is the copy meant to outlive the phone — that is the point of running it. |
| Mealie | 2 | Re-scrapable, tediously. |
| LubeLogger | 2 | Hand-entered service history — no upstream to re-fetch it from. |
| BookStack | 2 | Authored, but small. |
| Habitica | 2 | Hand-entered habits and history. Losing it costs a streak, not a record. |

Every one of those lives under `/data/<stack>` on the second disk — which is
**excluded from whole-VM `vzdump`** (`backup=0`,
[proxmox-setup.md Part 5](../docs/proxmox-setup.md#part-5--create-the-vms)) and
covered by nothing else. The file-level `restic` layer now exists
([docs/backup-setup.md](../docs/backup-setup.md)), but it runs on the **infra
VM** and this machine has not joined the repository
([roadmap/backup.md](../docs/roadmap/backup.md) names that gap and scopes it out).
So the honest state today is: the apps VM's *root* disk is backed up and its
**application data is not**. Both tier 1 services ship their own exporter, and
until this VM joins that repository running them by hand is the whole backup:
Paperless' `document_exporter` writes to `/data/paperless/export`, and Immich
dumps its database into `/data/immich/library/backups` on a schedule of its own.
Copy both off the box.

Immich makes that gap sharper rather than merely wider. Its **library is the
larger half and no exporter covers it** — the dumps hold metadata only, so a
restore needs the files too, and those are hundreds of gigabytes that no
hand-run command turns into an archive. Until this machine joins the restic
repository, treat the instance as a second copy of what is still on the phone,
not as where the phone's photos are kept.

That the gap exists at all is why Vaultwarden, the third tier 1 service this
machine used to hold, was moved to the infra VM
([above](#vaultwarden-is-not-on-this-list-and-used-to-be)).

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
this repo is the only durable record. These six have a git repository each
instead, which is where a reader already goes to change them. A second copy here would
drift, and a drifted registry is worse than none because it reads as
authoritative.

`docs/sso-applications.md` scopes itself to the infra VM for exactly this
reason and names this catalog as where the apps-VM applications live — the two
files point at each other on purpose.

See also [apps/README.md](README.md) and the main [README](../README.md).
