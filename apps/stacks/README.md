# apps/stacks — staging ground for the apps VM's third-party stacks

Each subdirectory is a self-contained Docker Compose stack for the **apps VM**, written to be
deployed by [Coolify](https://coolify.io/) as a **Docker Compose** resource pointed at its own git
repository in Forgejo.

**This directory is a staging ground, not the source of truth.** Each stack becomes its own repo
at `git.thefipster.de/<owner>/<stack>`, and from that moment the Forgejo repo is what Coolify
deploys and what a change is made in. What stays behind in `home-lab` is the catalog —
[apps/services.md](../services.md), which records *what* runs and *why that one*, never the
compose. See [apps/README.md](../README.md) for why this VM's definitions deliberately do not live
in this repo.

| Stack | Repo | Domain | Internal port | Backing services |
|---|---|---|---|---|
| [mealie](mealie/) | `mealie` | `mealie.thefipster.de` | 9000 | PostgreSQL 18 |
| [lubelogger](lubelogger/) | `lubelogger` | `lube.thefipster.de` | 8080 | PostgreSQL 18 |
| [bookstack](bookstack/) | `bookstack` | `wiki.thefipster.de` | 80 | MariaDB 11.8 |
| [paperless](paperless/) | `paperless` | `paperless.thefipster.de` | 8000 | PostgreSQL 18, Valkey 9, Gotenberg, Tika |

Domains match [apps/services.md](../services.md), which is the registry for them.

## Conventions

Every stack follows the same rules, so they behave identically once deployed.

**Real domains, not placeholders.** Every host is a subdomain of `thefipster.de`, and **none of
them needs a DNS record**: `*.thefipster.de` already resolves to the apps VM, and Coolify's proxy
routes by `Host` header. Coolify terminates TLS with its own Let's Encrypt wildcard — Traefik on
the infra VM never sees this traffic. See
[docs/dns-records.md](../../docs/dns-records.md#names-the-wildcard-covers-on-purpose) for why
riding the wildcard is deliberate rather than an omission.

**Bind mounts under `/data/<stack>`, never named volumes.** `/data` on the apps VM is the 300 GB
second disk, the same one Coolify keeps its own store on (`/data/coolify`) —
[docs/apps-vm-setup.md, step 4](../../docs/apps-vm-setup.md). Named volumes were dropped on
purpose: a backup job needs a path it can walk, and `docker volume inspect` is not that. This is
the apps-VM analogue of the infra VM's `/opt/<stack>` convention, on the disk that machine
actually has for it.

Each stack's README opens with the `mkdir -p` that creates its directories. Docker creates a
missing bind-mount source as root-owned, which is fine for the databases (their entrypoints chown
what they need) and wrong for the app data dirs that run as `PUID`/`PGID` — hence the `chown` in
the same step.

**`/data` is not backed up yet.** It is excluded from whole-VM `vzdump`
(`backup=0`), and the file-level layer is still roadmap. Anything deployed here is unbacked until
that lands; Paperless is tier 1 and should be exported by hand in the meantime.

**No published host ports.** Services use `expose:` and Coolify's proxy handles ingress. Nothing
competes for host ports on a single node.

**Coolify magic variables for anything generated.** Declaring a bare
`SERVICE_URL_<SERVICE>_<PORT>` in an `environment:` list makes Coolify generate a domain and route
the proxy to that port. Passwords and keys use `${SERVICE_PASSWORD_*}` and
`${SERVICE_REALBASE64_*}`. All of these are generated on first deploy and then live in the
resource's environment editor — nothing secret is committed.

**`PUBLIC_URL` is set by hand, not derived.** Mealie, BookStack and Paperless each need their
public URL *with the scheme* (`BASE_URL`, `APP_URL`, `PAPERLESS_URL`). It is tempting to feed them
`${SERVICE_FQDN_X}` or `${SERVICE_URL_X}`, but whether those expand with or without `https://` has
flipped between Coolify versions and is still inconsistent
([#2702](https://github.com/coollabsio/coolify/issues/2702),
[#7656](https://github.com/coollabsio/coolify/issues/7656)). A scheme-less value here is a subtle
breakage — dead invite links, CSRF failures on login, broken assets — so all three stacks read one
explicit `PUBLIC_URL` variable instead, defaulting to the real domain above. Changing it means
changing the Coolify domain in the same breath.

**Postgres services set `PGDATA` explicitly.** Postgres 18's image made its default PGDATA
version-specific (`/var/lib/postgresql/18/docker`); left alone, a bind mount at
`/var/lib/postgresql/data` would no longer be where the server writes. Pinning it keeps
`/data/<stack>/postgres` holding PGDATA directly — one flat path across every stack here and on
the infra VM — and makes a future major bump fail loudly instead of silently initialising an empty
`19/` beside the old data.

**Everything else is a plain variable with a sane default**, e.g. `${TZ:-Europe/Berlin}`, so a
stack deploys unattended and is still tunable from Coolify's UI without editing the repo.
Variables written as `${FOO:-default}` show up pre-filled in Coolify's environment editor, which
is how they are meant to be discovered and changed.

**Pinned image tags, down to the patch.** No `:latest`. These are upstream applications with
schema migrations on start, not lab infrastructure — the infra VM's major-only pin policy does not
apply here. Upgrades are a deliberate commit, which also gives you a revert path.

**No `container_name:`.** Coolify names containers itself; a hardcoded name collides across
deployments and preview environments.

**Healthchecks and `depends_on: condition: service_healthy`** on every database, so apps do not
start against a database that is still initialising.

**No relative links out of the stack directory.** Each README ends up in a standalone repo where
`../../docs/…` resolves to nothing. Name the `home-lab` file in prose instead. That rule applies
inside the stack directories only — this file stays here and may link freely.

## Defaults worth checking before the first deploy

`TZ` defaults to `Europe/Berlin` and Paperless OCR defaults to `deu+eng` across these stacks.
Both are one variable each in the respective `.env.example`.

## Splitting into separate repositories

Each directory is already repo-shaped — a `docker-compose.yml`, a `README.md`, an `.env.example`
and a `.gitignore`. To break one out, create the repo in Forgejo first, then:

```bash
cd mealie && git init -b main && git add . && git commit -m "Initial commit: Mealie stack for Coolify"
```

```bash
git remote add origin git@git.thefipster.de:<owner>/mealie.git && git push -u origin main
```

Then in Coolify: New Resource → Docker Compose → select the repository → compose file
`docker-compose.yml` → set the domain → deploy. Each stack's README carries the full sequence
including its host directories.

**Once a stack is pushed, delete its directory here.** Two copies of a compose file is exactly the
drift [apps/README.md](../README.md) argues against; the row in
[apps/services.md](../services.md) is what keeps it findable.

## Backups

Coolify can back up Postgres/MariaDB on a schedule, but the data directories (uploads,
attachments, scanned documents) are not covered by that. Where an app ships its own exporter —
Mealie's Settings → Backups, Paperless' `document_exporter` — prefer it: those archives survive
version upgrades, raw directory copies do not always. Per-service tiers are in
[apps/services.md](../services.md#backup).
