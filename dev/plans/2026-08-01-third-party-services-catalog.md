# Third-Party Services Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the repo a catalog, `apps/services.md`, describing the five third-party applications the apps VM runs as Coolify resources — what runs, why that one, and where its implementation lives.

**Architecture:** Documentation only. Three files change and two are new. The catalog is the single place the list of applications is allowed to live; the compose files live in a Forgejo repo, the secrets in Coolify, and the three `docs/` registries are deliberately untouched. A fourth file records the container-log gap this exposes on the apps VM.

**Tech Stack:** Markdown. No build, no lint, no tests — per `CLAUDE.md`, correctness here is verified by reading, not by executing.

**Spec:** [docs/superpowers/specs/2026-07-31-third-party-services-design.md](../specs/2026-07-31-third-party-services-design.md)

## Global Constraints

Every task's requirements implicitly include this section.

- **Never write a host IP address.** Machines are addressed by name everywhere. A literal address is a flag.
- **No compose, no environment values, no image tags in this repo** for these five applications. Those live in the Forgejo repo `self-hosted-services`, one directory per app.
- **Do not modify `docs/dns-records.md`, `docs/sso-applications.md` or `docs/uptime-kuma-monitors.md`.** Their exclusion is a decision recorded in the spec, not an oversight.
- **Do not create a guide in `docs/`.** `coolify-setup.md` already owns the platform.
- **Do not name individual applications in `README.md`.** It links the catalog and stays vague, so there is no list to keep in sync.
- **Hostnames are subdomains of `thefipster.de`**: `paperless.`, `vault.`, `mealie.`, `lube.`, `wiki.`.
- **Line endings are LF** (`.gitattributes` forces this repo-wide). Do not let an editor rewrite them.
- **Guides and registries link with relative paths.** From `apps/`, `docs/` is `../docs/`. From `docs/roadmap/`, the repo root is `../../`.
- **Work on branch `feature/third-party-services`**, which already exists and holds the spec.

---

### Task 1: The catalog

**Files:**
- Create: `apps/services.md`
- Modify: `apps/README.md` (the table under "Why there is no compose file here", and a new link)

**Interfaces:**
- Consumes: nothing.
- Produces: the path `apps/services.md`, linked from `apps/README.md` in Task 1 and from `README.md` in Task 3. The roadmap file created in Task 2 links back to it as `../../apps/services.md`.

- [ ] **Step 1: Create the catalog**

Create `apps/services.md` with exactly this content:

```markdown
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
```

- [ ] **Step 2: Verify the catalog against the constraints**

Run this and confirm it returns **no output** — no host IP addresses, no image tags, no environment assignments:

```bash
grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|image:|:v?[0-9]+\.[0-9]+\.[0-9]+' apps/services.md
```

Then read the file and confirm each of these by eye:

1. Both "decisions that look like mistakes" state their reasoning where a reader would try to change them.
2. Every row's Implementation column is a bare directory name.
3. The relative links resolve: `../docs/dns-records.md`, `../docs/sso-applications.md`, `../docs/roadmap/backup.md`, `../docs/roadmap/apps-vm-logs.md` (created in Task 2 — the link is written now and points forward), `README.md`, `../README.md`.

- [ ] **Step 3: Link the catalog from `apps/README.md`**

In `apps/README.md`, the table under "Why there is no compose file here" currently has one row, for `.env.example`. Add a second row **above** it so the table reads:

```markdown
| File | Purpose |
|------|---------|
| `services.md` | the catalog of **third-party** applications this VM runs as Coolify resources — what runs and why that one. Their compose files live in the Forgejo repo `self-hosted-services`, so this stays a pointer, not a second source of truth. |
| `.env.example` | the three `NETCUP_*` names Coolify's bundled proxy needs for its own DNS-01 wildcard. Copied to `.env` by the init script. The **values** are entered in Coolify's UI — the file exists so the requirement is visible in the repo instead of only inside Coolify. |
```

- [ ] **Step 4: Extend the surrounding paragraph in `apps/README.md`**

The section "Why there is no compose file here" ends with "What that leaves in this directory:" just above that table. Immediately before that line, add this paragraph so the catalog does not read as a contradiction of the section's own title:

```markdown
That holds for third-party software too — Paperless, Vaultwarden and the rest
are Coolify resources deployed from their own Forgejo repo, not stacks declared
here. What this directory adds for them is a **catalog**:
[services.md](services.md) records what runs and why that one, and points at the
repo holding the compose.
```

- [ ] **Step 5: Verify `apps/README.md` still reads correctly**

Read `apps/README.md` end to end and confirm:

1. The "Why there is no compose file here" section no longer contradicts itself — it explains that the catalog is a pointer, not a definition.
2. The `services.md` link resolves (same directory).
3. Nothing else in the file changed — the Scripts, TLS and DNS sections are untouched.

Confirm the diff touches only the intended region:

```bash
git diff --stat apps/README.md
```

- [ ] **Step 6: Commit**

```bash
git add apps/services.md apps/README.md
git commit -m "docs: add a catalog of third-party services on the apps VM

Paperless-ngx, Vaultwarden, Mealie, LubeLogger and BookStack run as Coolify
resources deployed from a Forgejo repo. The catalog records what runs and why
that one -- no compose, no env values, no image tags, so it does not rot when
an image is bumped.

Two decisions are documented where a reader would try to reverse them:
BookStack supports no Postgres at all and is kept anyway, and Vaultwarden
keeps local login despite now supporting OIDC.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The apps VM log gap as a roadmap item

**Files:**
- Create: `docs/roadmap/apps-vm-logs.md`

**Interfaces:**
- Consumes: the link written in Task 1 at `apps/services.md` → `../docs/roadmap/apps-vm-logs.md`. This task is what makes that link resolve.
- Produces: the path `docs/roadmap/apps-vm-logs.md`, referenced from `apps/services.md` and from the `README.md` status table in Task 3.

- [ ] **Step 1: Create the roadmap entry**

Create `docs/roadmap/apps-vm-logs.md` with exactly this content:

```markdown
# Roadmap: Container logs from the apps VM

Goal: get container stdout from the **apps VM** into Loki, so the single pane in
Grafana covers both Docker machines instead of one.

This is a gap for the whole machine, not for any one application. Coolify's own
containers, the applications it builds from your source, and the third-party
services in [apps/services.md](../../apps/services.md) are all equally invisible
today. It is the last piece of the ambition
[roadmap/monitoring.md](monitoring.md) opened with — "every stack on the infra VM
and, later, the apps the apps VM runs".

## What already works, and why logs are the exception

Metrics from this VM are **not** affected and need nothing:
`scripts/init-node-exporter.sh` runs there, Alloy on the infra VM scrapes it
over the LAN by name, and it carries `job="node"` with `instance="apps"` like the
other two hosts.

Logs are different because Alloy discovers containers and tails their stdout
through a **Docker socket**, and it is mounted from the machine Alloy runs on.
`infra/monitoring/compose.yaml` bind-mounts the infra VM's socket; there is no
socket for the apps VM in that container and there should not be one.

## The shape of the answer

Two candidate designs, both keeping Loki on the infra VM:

- **A second Alloy, on the apps VM**, in `logs-only` configuration, pushing to
  Loki over the LAN. Symmetric with the collector already running, reuses its
  config idiom, and needs no change to what Loki accepts beyond an ingest path.
  Costs a container and a socket mount on a machine this repo does not declare
  stacks for — which is the interesting question, since Coolify owns that VM's
  Docker.
- **Coolify's own logging driver**, pointed at Loki. No extra container. Costs a
  Docker daemon-level change on a machine Coolify expects to own outright, and
  the labels would not match what Alloy produces on the infra VM, so the two
  halves of the pane would not query alike.

The first looks right. Decide before building.

## Open questions

- **Where does the second Alloy's config live?** `apps/` holds no compose by
  design. A logs-only collector is infrastructure, not an application, so it may
  belong in `infra/` despite running elsewhere — or in the Forgejo repo with
  everything else Coolify deploys.
- **Does Loki need authentication?** It is currently reachable only inside the
  infra VM's `monitoring-net`. Accepting pushes from another machine changes
  that, and the LAN is not a trust boundary this repo has leaned on before.
- **What labels make the two machines queryable together?** The infra VM's
  container logs carry labels Alloy derives from Docker. The apps VM's must
  match, or `{job="..."}` splits in two and every dashboard needs an edit.
```

- [ ] **Step 2: Verify the roadmap entry**

Confirm the relative links resolve from `docs/roadmap/`:

- `../../apps/services.md` → the catalog created in Task 1
- `monitoring.md` → the existing roadmap in the same directory

Run and confirm both paths exist:

```bash
ls docs/roadmap/monitoring.md apps/services.md
```

Then confirm the forward link written in Task 1 now resolves — this should print the file's first line:

```bash
head -1 docs/roadmap/apps-vm-logs.md
```

- [ ] **Step 3: Commit**

```bash
git add docs/roadmap/apps-vm-logs.md
git commit -m "docs: roadmap for shipping apps VM container logs to Loki

Alloy tails the infra VM's Docker socket, so nothing on the apps VM reaches
Loki -- Coolify's containers, your apps and the third-party services alike.
Metrics are unaffected; node_exporter already covers that host.

Names the two candidate designs and the three questions that decide between
them, rather than leaving the gap as an assumed capability.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Repo-level mentions

**Files:**
- Modify: `README.md` (architecture diagram, the layer table, the repository layout tree, the status table)
- Modify: `CLAUDE.md` (the apps VM paragraph under "Topology")

**Interfaces:**
- Consumes: `apps/services.md` from Task 1 and `docs/roadmap/apps-vm-logs.md` from Task 2. Both links must already resolve.
- Produces: nothing later tasks depend on. This is the final task.

**Constraint specific to this task:** the README must not name any of the five applications. It says *third-party apps* and links the catalog. A README that enumerated them would be a fourth copy competing with the catalog and the Forgejo repos.

- [ ] **Step 1: Add a line to the architecture diagram**

In `README.md`, the apps VM block of the fenced architecture diagram currently reads:

```
    ├─ apps VM · 12 vCPU · 24 GB · 80 GB + 300 GB on data · Ubuntu Server 26.04
    │    Coolify       self-hosted PaaS — owns its own Docker and its own cert
    │    your apps     *.thefipster.de, routed by Host header — no new DNS record
    │    node_exporter scraped by Alloy over the LAN
```

Insert one line after `your apps`, keeping the existing column alignment:

```
    ├─ apps VM · 12 vCPU · 24 GB · 80 GB + 300 GB on data · Ubuntu Server 26.04
    │    Coolify       self-hosted PaaS — owns its own Docker and its own cert
    │    your apps     *.thefipster.de, routed by Host header — no new DNS record
    │    third-party   self-hosted software you use — catalog in apps/services.md
    │    node_exporter scraped by Alloy over the LAN
```

- [ ] **Step 2: Extend the apps VM row of the layer table**

In the layer table, the apps VM row currently ends with "Owns its own Docker, and issues its own wildcard certificate." Append one sentence so the cell reads:

```markdown
| **apps VM** | Coolify | A self-hosted PaaS that deploys and runs *your* applications with domains + HTTPS. Owns its own Docker, and issues its own wildcard certificate. Also runs the third-party software you use, deployed the same way — the catalog is [apps/services.md](apps/services.md). |
```

- [ ] **Step 3: Update the repository layout tree**

In the fenced layout tree, the `apps/` block currently reads:

```
├── apps/                        Apps VM (Coolify) — no compose, by design
│   ├── README.md                 What lives here and what deliberately doesn't
│   └── .env.example              netcup names Coolify's own proxy needs
```

Replace it with:

```
├── apps/                        Apps VM (Coolify) — no compose, by design
│   ├── README.md                 What lives here and what deliberately doesn't
│   ├── services.md               Catalog: third-party apps this VM runs
│   └── .env.example              netcup names Coolify's own proxy needs
```

Also update the `docs/roadmap/` line in the same tree. It currently reads:

```
│   └── roadmap/                  What's next (backup, CI hardening; monitoring is done)
```

Replace it with:

```
│   └── roadmap/                  What's next (backup, CI hardening, apps VM logs)
```

- [ ] **Step 4: Add two rows to the status table**

In the Status table, add these rows immediately after the `Coolify install (apps VM)` row:

```markdown
| Third-party apps on the apps VM | 📄 catalog written, nothing deployed — [catalog](apps/services.md) |
| Container logs from the apps VM | ⬜ planned — [roadmap](docs/roadmap/apps-vm-logs.md) |
```

- [ ] **Step 5: Update the apps VM paragraph in `CLAUDE.md`**

Under "Topology (why things are split the way they are)", the apps VM bullet currently reads:

```markdown
- **apps VM** — Coolify (self-hosted PaaS). Coolify owns its own Docker and
  manages apps through its UI, so `apps/` holds **no compose file** — only a
  README and a `.env.example` naming the `NETCUP_*` variables Coolify's own proxy
  needs. App definitions live in Coolify's database, not this repo.
```

Replace it with:

```markdown
- **apps VM** — Coolify (self-hosted PaaS). Coolify owns its own Docker and
  manages apps through its UI, so `apps/` holds **no compose file** — a README, a
  `.env.example` naming the `NETCUP_*` variables Coolify's own proxy needs, and
  `services.md`, a **catalog** of the third-party software this VM runs. App
  definitions live in Coolify's database, not this repo; the third-party compose
  files live in a Forgejo repo, so the catalog records what runs and why, never
  how. It deliberately adds no rows to the three `docs/` registries — those cover
  infra VM services, whose implementation is clickwork with no other home.
```

- [ ] **Step 6: Verify no application is named in `README.md`**

Run this and confirm it returns **no output**:

```bash
grep -niE 'paperless|vaultwarden|mealie|lubelogger|bookstack' README.md
```

- [ ] **Step 7: Verify the three registries are untouched**

Run this and confirm the output lists **only** `README.md`, `CLAUDE.md`, `apps/README.md`, `apps/services.md`, `docs/roadmap/apps-vm-logs.md` and the two spec/plan files — and no file matching `docs/dns-records.md`, `docs/sso-applications.md` or `docs/uptime-kuma-monitors.md`:

```bash
git diff --name-only main...HEAD
```

- [ ] **Step 8: Verify every new link resolves**

Confirm each path exists:

```bash
ls apps/services.md docs/roadmap/apps-vm-logs.md
```

Then read the rendered README section by eye and confirm the architecture diagram's column alignment survived the insertion — the descriptions after each service name should still line up.

- [ ] **Step 9: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: point the repo at the third-party catalog

README stays deliberately vague -- it says third-party apps and links the
catalog, naming none of them, so there is no list to keep in sync with the
catalog and the Forgejo repos.

CLAUDE.md records the apps VM change: apps/ now holds a catalog alongside the
README and .env.example, and why that catalog adds no registry rows.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Done when

- `apps/services.md` exists and describes all five applications, their databases, their SSO decisions and their backup tiers.
- The BookStack MariaDB exception and the Vaultwarden SSO absence each carry their reasoning at the point a reader would try to change them.
- `docs/roadmap/apps-vm-logs.md` exists and names two candidate designs and three open questions.
- `README.md` links the catalog and names no application.
- `git diff --name-only main...HEAD` shows no change to `docs/dns-records.md`, `docs/sso-applications.md` or `docs/uptime-kuma-monitors.md`.
- Nothing under `infra/` or `scripts/` changed.
