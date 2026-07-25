# Monitoring phase 1 — the Grafana stack skeleton

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan
**Roadmap:** [docs/roadmap/monitoring.md](../../roadmap/monitoring.md) — this
spec covers **phase 1 only**; phases 2–5 stay on the roadmap.

## Goal

Stand up the monitoring stack skeleton on the infra VM: **Grafana + Postgres +
Prometheus + Loki + Alloy** as one compose stack, routed at
`grafana.thefipster.de` under the existing wildcard cert, with Grafana
authenticating against Authentik by OIDC. Alloy ships a small but real config
so the metrics path is proven end to end on day one.

Container-log collection, the existing services' Prometheus endpoints, OTLP
intake and dashboards/alerts are **phases 2–5** and are deliberately not here.

## Constraints & decisions made

- **Scope is phase 1.** The stack exists, is reachable, is authenticated, and
  moves real data through the collector. Nothing else.
- **All five containers ship now, with Alloy doing real work.** The
  alternative — shipping the backends idle and configuring the collector next
  cycle — leaves nothing verifiable until phase 2. Alloy scraping the stack's
  own `/metrics` endpoints proves collector → storage → dashboard immediately,
  without touching Docker service discovery.
- **Alloy is the only collector; Prometheus is storage + query.** Alloy
  `remote_write`s into Prometheus (`--web.enable-remote-write-receiver`);
  Prometheus has no `scrape_configs`. This is the roadmap's own architecture
  and the reason the Grafana stack beat Seq: one agent for logs, metrics and
  later OTLP. Letting Prometheus scrape for itself would be more conventional
  per-half, but phase 4's OTLP metrics must enter through Alloy regardless —
  splitting now buys convenience today and a two-path metrics pipeline later.
  Cost accepted: Prometheus's targets page stays empty and collector debugging
  happens in Alloy's own UI on `:12345`.
- **Grafana uses a dedicated Postgres, not SQLite.** One backup tool and one
  restore procedure across every stack, and `pg_dump` runs against a live
  database — a consistent SQLite backup needs Grafana stopped or the `.backup`
  API. The instance is dedicated to this stack rather than shared with
  Authentik or Forgejo, matching the reasoning already recorded in
  `infra/authentik/compose.yaml`: independent backups and version pins per
  stack.
- **Alloy gets no `docker.sock` mount in phase 1.** Container-log discovery is
  what needs it, and that is phase 2. Holding it back keeps a
  root-equivalent grant tied to an actual capability rather than to an
  anticipated one.
- **Grafana joins SSO by OIDC, never forward-auth.** Grafana has native OIDC,
  so per the repo's SSO convention it gets no `authentik@docker` middleware and
  no per-host outpost router. `infra/authentik/compose.yaml` is untouched by
  this work.
- **Break-glass: Grafana's local admin stays enabled.** `GRAFANA_ADMIN_PASSWORD`
  is generated into `.env`; the login form is not disabled. An Authentik outage
  must not lock the owner out of the thing that would show why.
- **Single user, no role mapping.** `role_attribute_path` is the JMESPath
  literal `'Admin'` — every OIDC user is a Grafana admin. Same decision, and
  same deferral, as the Forgejo OIDC spec.
- **Only Grafana is routed.** Loki and Prometheus stay on the internal network;
  Grafana is the single pane, so nothing else needs a hostname or a cert.
- **Retention:** Loki 14 d, Prometheus 15 d, per the roadmap.
- **RAM prerequisite is already satisfied.** The roadmap flagged the 4 GB infra
  VM as a phase-1 decision; the VM has since been raised to **10 GB**, so the
  stack needs no memory limits and no further Proxmox change.

## Architecture

```
UniFi Dream Router — local DNS (split horizon)
  grafana.thefipster.de  → .41 (infra VM)   exact host record (NEW)
  *.thefipster.de        → .42 (apps VM)    wildcard (existing)
        │
  infra VM (.41)
  ┌────────────────────────────────────────────────────────────────┐
  │ Traefik  :80 :443   (one wildcard cert, *.thefipster.de)        │
  │   └─ grafana.thefipster.de → grafana:3000   [OIDC in Grafana]   │
  │                                                                 │
  │ monitoring stack (monitoring-net, internal)                     │
  │                                                                 │
  │   alloy ──scrape /metrics──► prometheus, loki, grafana, self    │
  │     └────remote_write───────► prometheus:9090 /api/v1/write     │
  │                                                                 │
  │   grafana ──datasource──► prometheus:9090   (default)           │
  │           └─datasource──► loki:3100                             │
  │           └─database────► db:5432 (postgres)                    │
  └────────────────────────────────────────────────────────────────┘
                    │ OIDC (via https://auth.thefipster.de)
                    ▼
              Authentik (existing stack)
```

Grafana reaches Authentik over its public hostname, resolved by the UDR's
split-horizon DNS back to Traefik on the same VM — the same server-to-server
path Forgejo's OIDC source already uses.

## Components

### `infra/monitoring/compose.yaml` — `name: monitoring`

| Service | Image | Networks | Purpose |
|---|---|---|---|
| `db` | `postgres:16-alpine` | `monitoring-net` | Grafana's database |
| `grafana` | `grafana/grafana` (major pin) | `monitoring-net`, `proxy` | the single pane; only routed service |
| `prometheus` | `prom/prometheus` (major pin) | `monitoring-net` | metrics storage + query |
| `loki` | `grafana/loki` (major pin) | `monitoring-net` | log storage (empty until phase 2) |
| `alloy` | `grafana/alloy` (major pin) | `monitoring-net` | the collector |

Image pins follow the repo's major-only policy; the exact current major for each
image is verified when the compose file is written.

- **`db`** — `POSTGRES_USER`/`POSTGRES_DB` = `grafana`, password from
  `${GRAFANA_DB_PASSWORD:?…}`, data at `/opt/monitoring/postgres`,
  `pg_isready -U grafana` healthcheck. Same shape as the Authentik and Forgejo
  databases.
- **`grafana`** — `depends_on: db: condition: service_healthy`.
  `GF_DATABASE_TYPE=postgres`, `GF_DATABASE_HOST=db:5432`,
  `GF_DATABASE_SSL_MODE=disable`, `GF_SERVER_ROOT_URL=https://grafana.thefipster.de`,
  plus the `GF_AUTH_GENERIC_OAUTH_*` block below. Mounts
  `/opt/monitoring/grafana:/var/lib/grafana` (plugins and file state persist
  there even with a Postgres backend; UID 472) and
  `./grafana/provisioning:/etc/grafana/provisioning:ro`. Traefik labels:
  `traefik.enable`, `Host(\`grafana.thefipster.de\`)`, `entrypoints: websecure`,
  `loadbalancer.server.port: "3000"` — **no TLS labels, no middleware label**.
- **`prometheus`** — `--config.file=/etc/prometheus/prometheus.yml`,
  `--storage.tsdb.path=/prometheus`,
  `--storage.tsdb.retention.time=15d`, `--web.enable-remote-write-receiver`.
  Data at `/opt/monitoring/prometheus` (UID 65534).
- **`loki`** — `-config.file=/etc/loki/loki.yaml`, data at `/opt/monitoring/loki`
  (UID 10001).
- **`alloy`** — `run --server.http.listen-addr=0.0.0.0:12345
  --storage.path=/var/lib/alloy/data /etc/alloy/config.alloy`, WAL at
  `/opt/monitoring/alloy`. No Docker socket.

### Config files (in the repo, bind-mounted read-only)

Mounted with **relative paths** so the repo stays the single source of truth —
edit, `git pull` on the VM, restart the stack. Data paths stay absolute under
`/opt/monitoring`, matching every other stack. Relative mounts resolve against
the compose file's directory, which reaches these files by either route: the
repo path directly, or `/opt/stacks/monitoring` when Dockge drives the stack,
since that symlink points at `infra/monitoring`.

- **`alloy/config.alloy`** — `prometheus.exporter.self`, a `prometheus.scrape`
  over `prometheus:9090`, `loki:3100`, `grafana:3000` and self, all forwarded to
  `prometheus.remote_write` at `http://prometheus:9090/api/v1/write`. Every one
  of those endpoints exists by default; none require changes to another stack.
- **`prometheus/prometheus.yml`** — a `global:` block only. No `scrape_configs`:
  metrics arrive by remote write.
- **`loki/loki.yaml`** — single-binary filesystem config, `retention_period:
  336h` with the compactor enabled.
- **`grafana/provisioning/datasources/datasources.yaml`** — Prometheus
  (`http://prometheus:9090`, default) and Loki (`http://loki:3100`), provisioned
  as code so a rebuilt Grafana comes back wired.

### `.env.example` / secrets

`GRAFANA_DB_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_OIDC_CLIENT_ID`,
`GRAFANA_OIDC_CLIENT_SECRET`. Compose guards each with `${VAR:?message}`. The
two OIDC values are copied by hand from Authentik in Part B; the two passwords
are generated by the init script.

### `scripts/init-monitoring.sh`

Same shape and style as the existing init scripts — `set -euo pipefail`, paths
resolved from `$BASH_SOURCE`, the shared `run_root()` helper, re-runnable:

1. Verify Docker is present.
2. `mkdir -p /opt/monitoring/{postgres,grafana,loki,prometheus,alloy}` and chown
   per-container UIDs (grafana 472, loki 10001, prometheus 65534). Postgres
   manages its own directory's ownership; Alloy's image runs as root, so its
   WAL directory needs no chown. Each image's actual runtime UID is confirmed
   against the pinned tag during implementation — a wrong UID here is the
   classic cause of a crash-looping container on first boot.
3. Seed `.env` from `.env.example`; `ensure_secret GRAFANA_DB_PASSWORD` and
   `ensure_secret GRAFANA_ADMIN_PASSWORD` — the existing helper only fills a
   blank value, so re-runs never rotate a live secret. Carries Forgejo's caveat:
   Postgres keeps the password its data dir was first initialized with.
4. Ensure the `proxy` network exists.
5. Symlink the stack into `/opt/stacks/monitoring` for Dockge.
6. Print next steps, pointing at `docs/monitoring-setup.md`.

### Authentik integration (manual, Part B of the guide)

Mirrors Forgejo's OIDC steps: an **OAuth2/OpenID provider** with redirect URI
`https://grafana.thefipster.de/login/generic_oauth` and a signing key, an
**application** bound to the existing `lab-users` group, then the generated
client ID/secret into `.env`. Grafana's side:

```
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_NAME=Authentik
GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://auth.thefipster.de/application/o/authorize/
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://auth.thefipster.de/application/o/token/
GF_AUTH_GENERIC_OAUTH_API_URL=https://auth.thefipster.de/application/o/userinfo/
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH='Admin'
GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
```

**Quoting note:** `role_attribute_path` is JMESPath, and a bare `Admin` is a
*field reference* that evaluates to nothing — the quotes are part of the value
and must survive into the container. In compose YAML that means
`GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: "'Admin'"`. Getting this wrong
yields OIDC logins with no role, which presents as a successful login into an
empty Grafana.

### Prerequisite: DNS

`grafana.thefipster.de` needs a **new exact host record on the UDR pointing at
the infra VM (.41)** — the `*.thefipster.de` wildcard otherwise sends it to the
apps VM. No Traefik or certificate change: the existing wildcard already covers
the name.

## Verification

What phase 1 can honestly prove, end to end:

- `https://grafana.thefipster.de` serves Grafana over the wildcard cert.
- Login as the local admin works (break-glass), and **Sign in with Authentik**
  completes and lands an admin session.
- Grafana survives `docker compose down && up -d` with its users and settings
  intact — i.e. state really is in Postgres.
- Both datasources report healthy from Grafana's datasource page.
- A Prometheus query for a metric Alloy scraped (e.g. `up`) returns series for
  `prometheus`, `loki`, `grafana` and `alloy` — the collector → storage →
  dashboard path works.
- Alloy's UI on `:12345` shows all components healthy.

**What it does not prove:** that logs flow. With no collection until phase 2,
Loki is empty by design; phase 1 verifies only that it is reachable, healthy
(`/ready`) and wired as a datasource. Stating this rather than adding a
throwaway log source to fill a checklist.

## Error handling

- **Authentik down or OIDC misconfigured:** the local admin login form stays
  enabled — Grafana never becomes unreachable because SSO broke.
- **Postgres unhealthy:** `depends_on: service_healthy` holds Grafana back
  rather than letting it start against a missing database.
- **Missing secret:** `${VAR:?message}` fails the stack fast with a message
  naming the variable, instead of a container booting misconfigured.
- **Alloy misconfigured:** it fails in isolation — Grafana, Loki and Prometheus
  are unaffected, and component health is visible on `:12345`.
- **Prometheus rejects remote write:** symptom is an empty `up` query; the
  receiver flag and Alloy's endpoint URL are the two things to check, both
  called out in the guide.

## Documentation changes (part of this work)

- **New `docs/monitoring-setup.md`** — Part 0 (DNS record, init script, `.env`),
  Part A (bring-up + the verification list above), Part B (Authentik OIDC
  wiring), and the break-glass note.
- **`docs/roadmap/monitoring.md`** — record phase 1 as landed with a link to the
  new guide; keep phases 2–5 and the constraints section, updating the RAM note
  to reflect the VM now having 10 GB.
- **`README.md`** — add Grafana to the infra-VM box and layer table, add
  `grafana.thefipster.de` to Networking & DNS, add `infra/monitoring/` and
  `scripts/init-monitoring.sh` to the repo layout, add a build-order step, and
  flip the monitoring status row.
- **`docs/wildcard-dns-udr.md`** — add the `grafana.` exact host record.
- **`CLAUDE.md`** — add the monitoring stack to the topology and deploy
  ordering; note that Grafana joins SSO by the OIDC pattern.

## Out of scope

- **Phases 2–5** — container-log collection, the existing services' Prometheus
  endpoints, host/cadvisor metrics, OTLP intake, Tempo, dashboards and alerts.
- **Grafana role/group mapping** — every OIDC user is an admin for now.
- **The apps VM** — its own Alloy shipping to this Loki/Prometheus comes later.
- **Any public exposure** — everything stays LAN-only behind Traefik.
- **Backup automation** — choosing Postgres makes one `pg_dump`-shaped backup
  possible across stacks, but writing that job is separate work.
