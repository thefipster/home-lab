# Third-party services on the apps VM — a catalog

**Date:** 2026-07-31
**Status:** Approved design, pending implementation plan
**Builds on:** the apps VM and Coolify —
[docs/coolify-setup.md](../../coolify-setup.md), guide written, machine not yet
built.

## Goal

Run five third-party self-hosted applications — **Paperless-ngx**,
**Vaultwarden**, **Mealie**, **LubeLogger**, **BookStack** — on the apps VM as
Coolify resources, and give this repo the one thing it is missing to describe
them: a **catalog**, `apps/services.md`.

The catalog records *what* runs, *why* that particular piece of software, and
every cross-cutting decision (hostname, database, SSO, monitoring, backup
criticality). It records no compose, no environment values and no image tags.

## The category problem this solves

The repo has two slots and these five fit neither. `infra/` is *services the lab
itself needs* — declared here, started by Dockge, the repo is the source of
truth. `apps/` is *software you wrote*, deployed by Coolify, where app
definitions deliberately live in Coolify's database and **not** in this repo.

Paperless and friends are a third thing: third-party software you *use*. Not lab
plumbing, not your code. Left undocumented they would exist only as clickwork in
Coolify's UI, which is precisely the failure mode the three existing registries
were created to prevent.

## Decisions made

### Where they run: the apps VM, via Coolify

Considered and rejected:

- **The infra VM as new `infra/` stacks.** Would inherit Traefik labels, the
  wildcard cert, Authentik, Dockge, Alloy and `/opt/<stack>` backups for free —
  the cheapest path in pure mechanics. Rejected because it puts a recipe manager
  on the one box that must survive an experiment on either of the others, and
  because Paperless's document store wants the 300 GB `data` mirror, which is
  the apps VM's second disk.
- **A fourth VM for third-party services.** Cleanest blast radius. Rejected on
  memory: 16 + 24 + 8 = 48 GB of 64 is already allocated and the ARC wants the
  rest.
- **Split by role** — Vaultwarden on infra, the rest on apps. Rejected as two
  homes and two conventions for five small applications.

Running them on the apps VM makes each an ordinary Coolify resource: the
wildcard already resolves there, Coolify's proxy already terminates TLS with its
own certificate, and storage lands on the disk sized for growth.

**A side effect resolves the Vaultwarden worry.** Coolify's proxy carries no
forward-auth middleware, so nothing deployed there is gated behind Authentik by
default. Every app authenticates locally, plus per-app OIDC where it is wanted.

### The three-way split of truth

The boundary is the point of the whole design:

| Holds | What |
|---|---|
| **This repo** (`apps/services.md`) | What runs, why that one, hostname, database, SSO decision, monitoring, backup criticality |
| **Forgejo `self-hosted-services`** | One directory per app: `compose.yaml` + `.env.example` |
| **Coolify's database** | Secrets and runtime state, as today |

One Forgejo repo with a directory per app, not five repos — one clone, one place
to look, and shared conventions stay visibly shared rather than drifting apart.
Coolify creates five Compose resources against the same repository, each with a
different Base Directory.

The catalog's Implementation column is therefore just a directory name. That is
deliberate: it keeps the catalog from rotting every time an image is bumped.

This preserves the existing rule rather than bending it — app definitions still
do not live in this repo.

### Where the catalog file lives: `apps/`, not `docs/`

The three existing registries ([dns-records.md](../../dns-records.md),
[sso-applications.md](../../sso-applications.md),
[uptime-kuma-monitors.md](../../uptime-kuma-monitors.md)) sit in `docs/` and each
carries `**Runs on:** … — registry, not a build step`, because each **spans
machines**. This catalog describes exactly one VM, so it belongs to that VM's
directory in the machine map. `apps/README.md` links it; the root README shows it
in the layout tree.

### The software itself — verified 2026-07-31

The original shortlist came from a 2024 recommendation and was re-checked against
current releases. **All five stand.** Two findings changed the design:

**Vaultwarden gained OIDC.** SSO with OpenID Connect landed upstream and shipped
(1.36.0 as of mid-2026), with Authentik named as a supported provider. In 2024
this would have been a forced SSO exception like Uptime Kuma. It is now a
*choice* — see the next decision.

**BookStack cannot use Postgres.** Its requirements are `MySQL >= 8.0 or
MariaDB >= 10.6`; Postgres is not supported at all. It is therefore the one
service that drags a MariaDB into a lab where Authentik, Forgejo and Grafana all
sit on Postgres. **BookStack is kept anyway** — the Postgres-native alternatives
each cost more than one extra database:

| Alternative | Stack | Why rejected |
|---|---|---|
| Docmost | Postgres + Redis | OIDC is an **Enterprise** feature, billed per seat. A wiki that cannot join Authentik without a subscription is a downgrade for this lab specifically. |
| Outline | Postgres + Redis | Has **no local login** — it requires an external OIDC provider. By the lab's own Kuma reasoning, that makes an Authentik outage take the break-glass documentation with it. |
| Wiki.js | Postgres | Appears stale — last commit months old as of June 2026, while BookStack commits weekly. |

BookStack is light (~256 MB), has free built-in OIDC, and is actively
maintained. The exception is recorded **in place** in the catalog so nobody
"corrects" it later.

Also considered: **Tandoor** in place of Mealie — Postgres-required, with
nutrition data and meal-cost tracking Mealie cannot match, at the price of more
complexity. A taste call, not a correctness one. **Mealie stands.**

### SSO: four join by OIDC, one deliberately does not

Paperless-ngx, Mealie, BookStack and LubeLogger all support OIDC and all join
Authentik, per the repo rule that anything with native OIDC uses it. The catalog
records **the decision**; the client IDs, callback URLs and environment variables
that implement it live in each app's Forgejo directory.

**Vaultwarden keeps local login only**, though it now supports OIDC. It is the
third stated exception to that rule, joining Uptime Kuma and Home Assistant for a
reason of the same shape: a password manager that dies with the identity provider
is the one outage from which you cannot recover, because the credentials needed
to fix Authentik are inside it.

Two gotchas the catalog carries because they cause silent, hard-to-diagnose
damage rather than a visible failure:

- **LubeLogger links accounts on email address.** The Authentik user's address
  must match the LubeLogger user's, or SSO quietly creates a second account —
  the same trap `sso-applications.md` already documents for Forgejo.
- **LubeLogger's OIDC is configured in its Server Settings UI**, not by
  environment variable, so it is the one integration a `git clone` of the
  Forgejo repo cannot reproduce.

## The five entries

| App | Hostname | Database | Also needs | SSO | Backup tier |
|---|---|---|---|---|---|
| Paperless-ngx | `paperless.thefipster.de` | Postgres | Redis; optionally Gotenberg + Tika | OIDC | **1** — scanned documents; the originals are paper or gone |
| Vaultwarden | `vault.thefipster.de` | Postgres | — | none, deliberate | **1** — vault data, attachments, `rsa_key` |
| Mealie | `mealie.thefipster.de` | Postgres | — | OIDC | 2 — re-scrapable, tediously |
| LubeLogger | `lube.thefipster.de` | Postgres | — | OIDC | 2 — hand-entered service history |
| BookStack | `wiki.thefipster.de` | **MariaDB** | — | OIDC | 2 — authored, but small and diffable |

Tiers use the language of [docs/roadmap/backup.md](../../roadmap/backup.md):
**tier 1 is irreplaceable**. Paperless is the only entry here whose loss can
destroy something that exists nowhere else, and Vaultwarden's loss locks you out
of everything else — including the lab.

Every app is put on Postgres where it offers the choice, even though three of
them (Vaultwarden, Mealie, LubeLogger) default to SQLite — matching the database
the lab already runs everywhere else. Paperless already ships Postgres in its
official compose, and BookStack has no choice to make.

Vaultwarden additionally needs `SIGNUPS_ALLOWED=false` once the first account
exists, and an argon2-hashed `ADMIN_TOKEN`.

## The three registries stay untouched — deliberately

The repo rule is that a new service decides about
[dns-records.md](../../dns-records.md),
[sso-applications.md](../../sso-applications.md) and
[uptime-kuma-monitors.md](../../uptime-kuma-monitors.md), and says so in each.
**These five decide to stay out of all three**, and each app's DNS, SSO and
monitor facts live in its own Forgejo directory instead.

The reason is that duplication here would be pure cost. The registries earn their
keep for infra VM services because the *implementation* is clickwork with no
other home — an Authentik application exists only in Authentik's database, a Kuma
monitor only in Kuma's SQLite, so a file in this repo is the only durable record.
These five have another home: a git repository per app directory, which is
exactly where a reader already goes to change them. A second copy here would
drift, and a drifted registry is worse than none, because it reads as
authoritative.

Two facts are worth stating once, in the catalog, because they are properties of
the *machine* rather than of any one app:

- **No app needs a DNS record.** All five ride the `*.thefipster.de` wildcard to
  the apps VM, exactly like `coolify.` and `apps.`. Pinning exact records would
  break the auto-correcting property the wildcard provides — an apps-VM address
  change currently fixes itself everywhere at once.
- **Uptime Kuma can only check these over HTTP.** Its container-state monitors
  read the *infra* VM's Docker socket; these run on a different daemon on a
  different machine, so container-level monitoring is not available to them at
  all. Anyone adding monitors in the Forgejo repos needs to know that before
  wondering why the option does nothing.

**Cost accepted:** `sso-applications.md` describes itself as covering every
Authentik application, and after this it no longer does. The catalog closes that
by naming, per entry, where the app's SSO configuration lives — so the pointer
exists even though the values are not copied.

## Known gap: container logs

Alloy tails the **infra** VM's Docker socket, so container logs from these five
will not reach Loki. Host metrics are unaffected — `init-node-exporter.sh`
already covers the apps VM, and none of these five is an exporter.

This is named as a limitation in the catalog and becomes a **roadmap item**,
`docs/roadmap/apps-vm-logs.md`, rather than being quietly left as an assumed
capability. It is a gap for the whole apps VM, not for these services
specifically: Coolify's own containers are equally invisible today.

## Scope

**In scope — files this touches:**

| File | Change |
|---|---|
| `apps/services.md` | **New.** The catalog. |
| `apps/README.md` | Link it; extend "what deliberately does not live here" to cover third-party compose. |
| `docs/roadmap/apps-vm-logs.md` | **New.** Shipping apps VM container logs to Loki. |
| `README.md` | **Vague on purpose** — the apps VM runs third-party apps too, with a link to the catalog where one fits naturally. No per-app names, no list to keep in sync. |
| `CLAUDE.md` | One clause: `apps/` now holds a catalog alongside the README and `.env.example`. |

The README stays deliberately thin because the catalog is the single place the
list is allowed to live. A README that enumerated five app names would be a
fourth copy competing with the catalog and the Forgejo repos.

**Out of scope:**

- **All three registries** — `dns-records.md`, `sso-applications.md` and
  `uptime-kuma-monitors.md` are untouched. See the section above for why, and
  for the cost that accepts.

- The Forgejo `self-hosted-services` repo and the compose files themselves.
- Creating the Coolify resources.
- A new guide in `docs/`. `coolify-setup.md` already owns the platform, and a
  from-scratch bring-up of the current checkout does not include these
  applications.
- Any change to `infra/traefik`. Coolify's proxy terminates TLS on the apps VM
  with its own certificate; the infra Traefik never sees this traffic.
- Any init script, `/opt/<stack>` data directory, or Dockge symlink. Those are
  infra VM conventions.

## Verification

There is nothing to execute — the deliverable is documentation. Correctness is
established by reading, per the repo's standing rule:

1. `git diff` touches no file under `docs/` except the new roadmap entry — the
   three registries are provably unchanged.
2. The catalog names no image tag, no environment value and no compose fragment.
3. Every entry names where its implementation lives, so nothing is merely
   omitted — a reader who wants the DNS, SSO or monitor detail is told which
   Forgejo directory holds it.
4. The BookStack MariaDB exception and the Vaultwarden SSO absence each carry
   their reasoning at the point a reader would try to change them.
5. The README names no individual application.
