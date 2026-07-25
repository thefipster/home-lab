# Monitoring Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `monitoring` compose stack to the infra VM — Grafana + Postgres + Prometheus + Loki + Alloy — routed at `grafana.thefipster.de`, authenticated against Authentik by OIDC, with Alloy proving the metrics path end to end.

**Architecture:** One new `infra/monitoring/` stack following every existing repo convention: bind mounts under `/opt/monitoring`, symlinked into `/opt/stacks`, joined to the external `proxy` network, routed by Traefik labels under the one wildcard cert. Alloy is the **only** collector — it scrapes the stack's own `/metrics` endpoints and `remote_write`s into Prometheus, which runs as storage + query with no `scrape_configs`. Grafana joins SSO by native OIDC (no forward-auth middleware, `infra/authentik/compose.yaml` untouched) and keeps its local admin as break-glass.

**Tech Stack:** Docker Compose, Traefik v3 (label routing), Grafana 13.1 (Postgres backend), Prometheus v3, Loki 3, Grafana Alloy v1.18.0, PostgreSQL 16, Bash setup scripts.

**Spec:** [`docs/superpowers/specs/2026-07-26-monitoring-phase1-design.md`](../specs/2026-07-26-monitoring-phase1-design.md)

## Testing model (read first — this repo has no unit-test harness)

Infra-as-notes: correctness is verified by **config validation + review**, not a test runner (see `CLAUDE.md`). The objective local gate for compose work is:

```bash
docker compose -f <file> config -q     # exits 0 on valid YAML + resolved ${VAR} interpolation
```

**Verified for this plan:** `docker compose config -q` works with **no Docker daemon running** (it only parses and interpolates), so the gate runs on the Windows workstation. Pulling or running images does not — that happens on the VM.

Because every `${VAR:?…}` guard fails on a blank value, the gate needs a populated `.env`. Each compose gate step below writes a throwaway `.env` with dummy values first.

For non-compose files:

```bash
python -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1]))); print('yaml ok')" <file>   # YAML syntax
bash -n <script>                                                                                    # shell syntax
```

Runtime verification (bringing the stack up, logging in through Authentik, confirming `up` returns series) happens **on the infra VM** and is captured as the verification checklist inside `docs/monitoring-setup.md` — that guide *is* the runtime test for this feature.

## Global Constraints

Copied from `CLAUDE.md` and the spec; every task's requirements implicitly include these.

- **Routing convention:** a proxied service joins the external `proxy` network (`external: true`) and adds `traefik.*` labels (`traefik.enable`, a `Host(...)` router rule, `entrypoints: websecure`, service `loadbalancer.server.port`). **No per-router TLS labels** — the single wildcard cert in `infra/traefik/compose.yaml` covers every `websecure` router.
- **Image pins are major-only** (`postgres:16-alpine`, `prom/prometheus:v3`, `grafana/loki:3`) — with **two forced exceptions verified against the registry**, both of which MUST be explained in a compose comment:
  - `grafana/grafana:13.1` — Grafana publishes **no bare-major tag** (`grafana/grafana:13` does not exist); major.minor is the coarsest pin available.
  - `grafana/alloy:v1.18.0` — Alloy publishes **only full `vX.Y.Z` tags** (no `v1`, no `v1.18`).
- **`.env` is gitignored**; every stack ships a `.env.example`. Compose uses `${VAR:?message}` guards to fail fast on a missing var — preserve them.
- **Persistent state** bind-mounts under `/opt/<stack>`; stacks are exposed to Dockge by symlinking `infra/<stack>` into `/opt/stacks/<stack>`. The repo stays the single source of truth.
- **Config files live in the repo** and are bind-mounted **read-only with relative paths** (`./alloy/config.alloy:...:ro`). Data paths stay absolute under `/opt/monitoring`.
- **Init scripts** use `set -euo pipefail`, resolve paths from `$BASH_SOURCE` (run from anywhere), share the `run_root()` helper (direct if root, else `sudo`), and are re-runnable — `ensure_secret` only fills a **blank** value so re-runs never rotate a live secret.
- **Line endings:** `.gitattributes` forces LF; `*.sh` MUST stay LF (CRLF breaks the shebang). Do not let an editor rewrite them.
- **SSO convention:** OIDC **or** forward-auth, never both. Grafana has native OIDC → **no `authentik@docker` middleware label**, no per-host outpost router, no edit to `infra/authentik/compose.yaml`.
- **Break-glass:** Grafana's local admin login stays ENABLED. Never set `GF_AUTH_DISABLE_LOGIN_FORM`.
- **Container UIDs, read from the pinned images' own configs** — a wrong chown is the classic first-boot crash loop: grafana `472`, loki `10001`, prometheus `nobody` = `65534`, alloy `root` (no chown), postgres manages its own.
- **Scope is phase 1.** No `docker.sock` mount, no container-log discovery, no other stack's metrics endpoints, no OTLP, no dashboards, no alerts.
- **Domain scheme:** exact-host records under `thefipster.de` → infra VM `.41`; the new name is `grafana.thefipster.de`.

---

### Task 1: The monitoring compose stack

**Files:**
- Create: `infra/monitoring/compose.yaml`
- Create: `infra/monitoring/.env.example`

**Interfaces:**
- Produces (consumed by Tasks 2, 3): service names `db`, `grafana`, `prometheus`, `loki`, `alloy` on the `monitoring-net` network; the in-network URLs `http://prometheus:9090`, `http://loki:3100`, `http://grafana:3000`; the config mount paths `/etc/prometheus/prometheus.yml`, `/etc/loki/loki.yaml`, `/etc/alloy/config.alloy`, `/etc/grafana/provisioning`.
- Produces (consumed by Task 4): data paths `/opt/monitoring/{postgres,grafana,prometheus,loki,alloy}` and env var names `GRAFANA_DB_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_OIDC_ENABLED`, `GRAFANA_OIDC_CLIENT_ID`, `GRAFANA_OIDC_CLIENT_SECRET`.
- Produces (consumed by Task 5): Traefik router name `grafana`, hostname `grafana.thefipster.de`, Alloy UI on VM loopback `127.0.0.1:12345`.

- [ ] **Step 1: Create `infra/monitoring/compose.yaml`**

```yaml
# Monitoring — Grafana + Prometheus + Loki + Alloy for the INFRA VM.
#
# Phase 1 of docs/roadmap/monitoring.md: the stack skeleton. Alloy is the ONLY
# collector — it scrapes this stack's own /metrics endpoints and remote-writes
# into Prometheus, which runs as STORAGE + QUERY only (no scrape_configs).
# Container-log collection, the other stacks' metrics endpoints, OTLP intake
# and dashboards/alerts are phases 2-5 and are deliberately absent.
#
# Routed by Traefik at grafana.thefipster.de under the one wildcard cert (no
# per-router TLS labels). Grafana authenticates against Authentik by OIDC —
# NOT forward-auth: it has native SSO, and the repo convention is one pattern
# or the other, never both. So there is no authentik@docker middleware label
# here, and infra/authentik/compose.yaml is untouched by this stack.
#
# Deploy (on the infra VM): scripts/init-monitoring.sh, then bring it up and
# wire Authentik afterwards — see docs/monitoring-setup.md.

name: monitoring

services:
  # ---------------------------------------------------------------------------
  # Grafana's database. Dedicated to this stack (not shared with Authentik or
  # Forgejo) so it backs up and version-pins independently — same reasoning as
  # infra/authentik/compose.yaml. Postgres over SQLite so the whole lab has ONE
  # backup story, and because pg_dump runs against a LIVE database: a consistent
  # SQLite backup would need Grafana stopped.
  # ---------------------------------------------------------------------------
  db:
    image: postgres:16-alpine        # major pin, same policy as the other DBs
    restart: unless-stopped
    environment:
      POSTGRES_USER: grafana
      POSTGRES_DB: grafana
      # NOTE: Postgres keeps the password its data dir was FIRST initialized
      # with — on an existing deployment .env must hold that value (or rotate
      # it via ALTER USER). Generated by scripts/init-monitoring.sh.
      POSTGRES_PASSWORD: ${GRAFANA_DB_PASSWORD:?set GRAFANA_DB_PASSWORD in .env — run scripts/init-monitoring.sh}
    volumes:
      - /opt/monitoring/postgres:/var/lib/postgresql/data
    networks:
      - monitoring-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U grafana"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ---------------------------------------------------------------------------
  # Grafana — the single pane, and the only routed service in this stack.
  # ---------------------------------------------------------------------------
  grafana:
    # MAJOR.MINOR pin, deviating from the repo's major-only policy because
    # Grafana publishes NO bare-major tag — there is no `grafana/grafana:13`,
    # only 13.1 / 13.1.1 / latest. Major.minor is the coarsest pin available.
    image: grafana/grafana:13.1
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      # --- database ---------------------------------------------------------
      GF_DATABASE_TYPE: postgres
      GF_DATABASE_HOST: db:5432
      GF_DATABASE_NAME: grafana
      GF_DATABASE_USER: grafana
      GF_DATABASE_PASSWORD: ${GRAFANA_DB_PASSWORD:?set GRAFANA_DB_PASSWORD in .env — run scripts/init-monitoring.sh}
      GF_DATABASE_SSL_MODE: disable    # private compose network, never leaves the host
      # --- server -----------------------------------------------------------
      # Must match the public URL: it's what OIDC redirects are built from.
      GF_SERVER_ROOT_URL: https://grafana.thefipster.de
      # --- local admin (BREAK-GLASS) ----------------------------------------
      # Kept enabled ON PURPOSE: an Authentik outage must not lock you out of
      # the very thing that would show you why. Do NOT set
      # GF_AUTH_DISABLE_LOGIN_FORM. Applied only when the Grafana database is
      # FIRST initialized; generated into .env by scripts/init-monitoring.sh.
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env — run scripts/init-monitoring.sh}
      # --- Authentik OIDC ---------------------------------------------------
      # Starts DISABLED so the stack can come up and be verified BEFORE
      # Authentik is wired (docs/monitoring-setup.md Part B) — that separates
      # "does the stack work" from "does SSO work" when debugging. Flip
      # GRAFANA_OIDC_ENABLED to true in .env once the client id/secret are in.
      GF_AUTH_GENERIC_OAUTH_ENABLED: ${GRAFANA_OIDC_ENABLED:-false}
      GF_AUTH_GENERIC_OAUTH_NAME: Authentik
      GF_AUTH_GENERIC_OAUTH_CLIENT_ID: ${GRAFANA_OIDC_CLIENT_ID:-}
      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: ${GRAFANA_OIDC_CLIENT_SECRET:-}
      GF_AUTH_GENERIC_OAUTH_SCOPES: "openid email profile"
      GF_AUTH_GENERIC_OAUTH_AUTH_URL: https://auth.thefipster.de/application/o/authorize/
      GF_AUTH_GENERIC_OAUTH_TOKEN_URL: https://auth.thefipster.de/application/o/token/
      GF_AUTH_GENERIC_OAUTH_API_URL: https://auth.thefipster.de/application/o/userinfo/
      GF_AUTH_GENERIC_OAUTH_USE_PKCE: "true"
      # JMESPath — and the INNER QUOTES ARE PART OF THE VALUE. A bare Admin is
      # a field reference that evaluates to nothing, which presents as a
      # SUCCESSFUL SSO login into a Grafana with no permissions at all.
      # Single-user lab: every OIDC user is an admin (see the design spec).
      GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: "'Admin'"
    volumes:
      # Grafana keeps file state here (plugins, renderer cache) even with the
      # Postgres backend. Image runs as UID 472 — init-monitoring.sh chowns it.
      - /opt/monitoring/grafana:/var/lib/grafana
      # Datasources as code: a rebuilt Grafana comes back already wired.
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    labels:
      traefik.enable: "true"
      traefik.http.routers.grafana.rule: Host(`grafana.thefipster.de`)
      traefik.http.routers.grafana.entrypoints: websecure
      traefik.http.services.grafana.loadbalancer.server.port: "3000"
      # Deliberately NO middlewares label — Grafana does OIDC itself.
    networks:
      - monitoring-net
      - proxy

  # ---------------------------------------------------------------------------
  # Prometheus — storage + query ONLY. Alloy pushes; this never scrapes.
  # ---------------------------------------------------------------------------
  prometheus:
    image: prom/prometheus:v3        # major pin
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      # Alloy PUSHES via remote write. Without this flag that endpoint 404s
      # and metrics silently never arrive.
      - --web.enable-remote-write-receiver
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      # Image runs as `nobody` (65534) — init-monitoring.sh chowns it.
      - /opt/monitoring/prometheus:/prometheus
    networks:
      - monitoring-net

  # ---------------------------------------------------------------------------
  # Loki — log storage. EMPTY until phase 2 adds collection; phase 1 only
  # proves it is reachable, healthy and wired as a Grafana datasource.
  # ---------------------------------------------------------------------------
  loki:
    image: grafana/loki:3            # major pin
    restart: unless-stopped
    command: -config.file=/etc/loki/loki.yaml
    volumes:
      - ./loki/loki.yaml:/etc/loki/loki.yaml:ro
      # Image runs as UID 10001 — init-monitoring.sh chowns it.
      - /opt/monitoring/loki:/loki
    networks:
      - monitoring-net

  # ---------------------------------------------------------------------------
  # Alloy — the single collector for the whole lab.
  # ---------------------------------------------------------------------------
  alloy:
    # FULL PATCH pin, deviating from the repo's major-only policy because Alloy
    # publishes ONLY vX.Y.Z tags — there is no v1 and no v1.18.
    image: grafana/alloy:v1.18.0
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    ports:
      # Alloy's own component-health UI. Bound to the VM's LOOPBACK only — it
      # gets no hostname, no cert and no Traefik router. Reach it when
      # debugging with:  ssh -L 12345:127.0.0.1:12345 <infra-vm>
      - "127.0.0.1:12345:12345"
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      # WAL / component state. Image runs as root, so no chown is needed.
      - /opt/monitoring/alloy:/var/lib/alloy/data
      # NOTE: deliberately NO /var/run/docker.sock here. Container-log
      # discovery (phase 2) is what needs it, and a root-equivalent grant
      # should follow an actual capability, not an anticipated one.
    networks:
      - monitoring-net

networks:
  monitoring-net:
    driver: bridge
  proxy:
    external: true
```

- [ ] **Step 2: Create `infra/monitoring/.env.example`**

```bash
# Monitoring stack — copy to .env (gitignored), or let
# scripts/init-monitoring.sh seed it and generate the two passwords.
#
# The two OIDC values are copied BY HAND from Authentik — see
# docs/monitoring-setup.md Part B.

# Grafana's Postgres password. Generated by the init script when blank.
# NOTE: Postgres keeps the password its data dir was FIRST initialized with;
# on an existing deployment this must match that value.
GRAFANA_DB_PASSWORD=

# Local Grafana admin password — the BREAK-GLASS login for when Authentik is
# down. Generated by the init script when blank. Applied only when the Grafana
# database is first initialized. Log in as user `admin`.
GRAFANA_ADMIN_PASSWORD=

# --- Authentik OIDC (docs/monitoring-setup.md Part B) -----------------------
# Left off until the provider exists, so the stack can be brought up and
# verified first. Set to true once the client id/secret below are filled in.
GRAFANA_OIDC_ENABLED=false
GRAFANA_OIDC_CLIENT_ID=
GRAFANA_OIDC_CLIENT_SECRET=
```

- [ ] **Step 3: Run the gate to verify it FAILS on the guards (red)**

The `${VAR:?…}` guards must reject a blank `.env`. From `infra/monitoring/`:

```bash
cp .env.example .env && docker compose config -q; echo "exit=$?"
```

Expected: **non-zero exit**, with an error naming `GRAFANA_DB_PASSWORD` (blank value trips the `:?` guard). This proves the fail-fast guards work.

- [ ] **Step 4: Run the gate with values to verify it PASSES (green)**

```bash
printf 'GRAFANA_DB_PASSWORD=dummy\nGRAFANA_ADMIN_PASSWORD=dummy\nGRAFANA_OIDC_ENABLED=false\nGRAFANA_OIDC_CLIENT_ID=\nGRAFANA_OIDC_CLIENT_SECRET=\n' > .env
docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 5: Confirm the throwaway `.env` is not tracked**

```bash
git status --porcelain infra/monitoring/
```

Expected: `compose.yaml` and `.env.example` only — **no `.env`** (it is covered by the repo's gitignore). If `.env` appears, stop and fix the ignore rule before committing.

- [ ] **Step 6: Commit**

```bash
git add infra/monitoring/compose.yaml infra/monitoring/.env.example
git commit -m "feat(monitoring): add the phase 1 compose stack"
```

---

### Task 2: Backend config files (Prometheus, Loki, Grafana datasources)

**Files:**
- Create: `infra/monitoring/prometheus/prometheus.yml`
- Create: `infra/monitoring/loki/loki.yaml`
- Create: `infra/monitoring/grafana/provisioning/datasources/datasources.yaml`

**Interfaces:**
- Consumes (from Task 1): mount targets `/etc/prometheus/prometheus.yml`, `/etc/loki/loki.yaml`, `/etc/grafana/provisioning`; in-network URLs `http://prometheus:9090` and `http://loki:3100`; Loki's data dir `/loki`; Prometheus's `--storage.tsdb.retention.time=15d`.
- Produces (consumed by Task 3): Loki listening on port `3100` and Prometheus's remote-write receiver at `http://prometheus:9090/api/v1/write`.
- Produces (consumed by Task 5): datasource UIDs `prometheus` and `loki` for the guide's verification steps.

- [ ] **Step 1: Create `infra/monitoring/prometheus/prometheus.yml`**

```yaml
# Prometheus here is STORAGE + QUERY ONLY.
#
# There are deliberately NO scrape_configs: Alloy is the single collector for
# the whole lab and pushes everything in by remote write (enabled with
# --web.enable-remote-write-receiver in compose.yaml). Adding scrape jobs here
# would create a second, parallel path into storage — see the phase 1 design
# spec. That means this server's own "Targets" page stays EMPTY BY DESIGN;
# debug collection in Alloy's UI (127.0.0.1:12345 on the VM) instead.
#
# Retention lives on the command line (--storage.tsdb.retention.time=15d),
# not in this file.

global:
  scrape_interval: 15s
  evaluation_interval: 15s
```

- [ ] **Step 2: Create `infra/monitoring/loki/loki.yaml`**

```yaml
# Loki — single-binary, filesystem-backed, 14-day retention.
#
# Sized for a one-person lab: no clustering, no object storage, in-memory ring.
# Phase 1 ships NO log collection, so this starts empty on purpose — phase 2
# (Alloy discovery.docker + loki.source.docker) is what fills it.

auth_enabled: false

server:
  http_listen_port: 3100
  # Loki is very chatty at info; warn keeps its own logs from becoming the
  # thing you have to go read logs about.
  log_level: warn

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/tsdb-index
    cache_location: /loki/tsdb-cache

limits_config:
  # 14 days, per the roadmap. Retention is only ENFORCED because the compactor
  # below has retention_enabled: true — this value alone deletes nothing.
  retention_period: 336h
  reject_old_samples: true
  reject_old_samples_max_age: 168h

compactor:
  working_directory: /loki/compactor
  # Required when retention_enabled is true on a filesystem backend.
  delete_request_store: filesystem
  retention_enabled: true
  retention_delete_delay: 2h

# Don't phone home from a private lab.
analytics:
  reporting_enabled: false
```

- [ ] **Step 3: Create `infra/monitoring/grafana/provisioning/datasources/datasources.yaml`**

```yaml
# Datasources as code. Provisioned datasources are READ-ONLY in the Grafana UI
# by design — change them here and restart, not in the browser. This is what
# makes a rebuilt Grafana come back already wired.

apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      # Match Alloy's scrape_interval so rate() windows behave sensibly.
      timeInterval: 15s

  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://loki:3100
```

- [ ] **Step 4: Verify all three parse as YAML**

```bash
cd infra/monitoring
for f in prometheus/prometheus.yml loki/loki.yaml grafana/provisioning/datasources/datasources.yaml; do
  python -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1]))); print('yaml ok:', sys.argv[1])" "$f"
done
```

Expected: three `yaml ok:` lines, exit 0.

- [ ] **Step 5: Verify the compose gate is still green**

```bash
cd infra/monitoring && docker compose config -q; echo "exit=$?"
```

Expected: **exit=0** (the `.env` from Task 1 Step 4 is still in place; recreate it if not).

- [ ] **Step 6: Commit**

```bash
git add infra/monitoring/prometheus infra/monitoring/loki infra/monitoring/grafana
git commit -m "feat(monitoring): add Prometheus, Loki and Grafana datasource config"
```

---

### Task 3: The Alloy collector config

**Files:**
- Create: `infra/monitoring/alloy/config.alloy`

**Interfaces:**
- Consumes (from Tasks 1–2): mount target `/etc/alloy/config.alloy`; the scrape targets `prometheus:9090`, `loki:3100`, `grafana:3000`; the remote-write receiver at `http://prometheus:9090/api/v1/write`.
- Produces (consumed by Task 5): the metric label `service` with values `alloy`, `prometheus`, `loki`, `grafana` — this is what the guide's `up` query checks for.

**Note on syntax:** Alloy config is not YAML — it is Alloy's own HCL-like language. Do **not** run the YAML parser against it.

- [ ] **Step 1: Create `infra/monitoring/alloy/config.alloy`**

```river
// Alloy — phase 1: prove the metrics path end to end.
//
// Alloy is the ONLY collector in this lab. Here it scrapes the monitoring
// stack's own /metrics endpoints and remote-writes them into Prometheus.
// Everything else — container logs (discovery.docker + loki.source.docker),
// the other stacks' Prometheus endpoints, host/cadvisor metrics and OTLP
// intake — is phases 2-5 of docs/roadmap/monitoring.md and is NOT here.
//
// Component health: http://127.0.0.1:12345 on the infra VM (loopback-bound,
// no route, no cert). Tunnel with:
//   ssh -L 12345:127.0.0.1:12345 <infra-vm>
// This UI is where you debug collection — Prometheus's own Targets page stays
// empty by design, because nothing scrapes from there.

// Where everything goes. Prometheus runs with
// --web.enable-remote-write-receiver, which is what makes this URL exist.
prometheus.remote_write "default" {
  endpoint {
    url = "http://prometheus:9090/api/v1/write"
  }
}

// Alloy's own internal metrics. Worth having first: it proves the collector
// is alive and the write path works even if every other target is down.
prometheus.exporter.self "alloy" {}

// Give Alloy's self-metrics the same `service` label the static targets below
// carry, so one query covers all four.
discovery.relabel "alloy_self" {
  targets = prometheus.exporter.self.alloy.targets

  rule {
    target_label = "service"
    replacement  = "alloy"
  }
}

// The rest of the stack. Every one of these endpoints is enabled by default —
// phase 1 changes NO other stack to get them.
prometheus.scrape "monitoring_stack" {
  targets = concat(
    discovery.relabel.alloy_self.output,
    [
      {"__address__" = "prometheus:9090", "service" = "prometheus"},
      {"__address__" = "loki:3100", "service" = "loki"},
      {"__address__" = "grafana:3000", "service" = "grafana"},
    ],
  )

  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

- [ ] **Step 2: Verify the compose gate is still green**

```bash
cd infra/monitoring && docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 3: Note the VM-side syntax gate in the commit body**

There is no daemonless validator for Alloy config. The real gate runs on the VM and is recorded in the guide (Task 5):

```bash
docker run --rm -v /opt/stacks/monitoring/alloy/config.alloy:/c.alloy:ro \
  grafana/alloy:v1.18.0 fmt /c.alloy
```

`fmt` exits non-zero on a syntax error. Component-name and argument errors surface at startup in `docker compose logs alloy`.

- [ ] **Step 4: Commit**

```bash
git add infra/monitoring/alloy/config.alloy
git commit -m "feat(monitoring): add the Alloy phase 1 collector config"
```

---

### Task 4: The init script

**Files:**
- Create: `scripts/init-monitoring.sh`

**Interfaces:**
- Consumes (from Task 1): the data paths `/opt/monitoring/{postgres,grafana,prometheus,loki,alloy}`, the env var names, and `infra/monitoring/.env.example`.
- Produces (consumed by Task 5): a populated `infra/monitoring/.env`, the `/opt/stacks/monitoring` symlink, and the printed next-steps that the guide mirrors.

- [ ] **Step 1: Create `scripts/init-monitoring.sh`**

```bash
#!/usr/bin/env bash
#
# init-monitoring.sh — project-specific setup for the monitoring stack
# (Grafana + Postgres + Prometheus + Loki + Alloy).
#
# Assumes Docker is installed (run scripts/init-host.sh first). Steps:
#   1. Create the persistent data tree under /opt/monitoring and set the
#      per-image ownership each container needs.
#   2. Seed infra/monitoring/.env from .env.example; auto-generate
#      GRAFANA_DB_PASSWORD and GRAFANA_ADMIN_PASSWORD if they are still blank.
#   3. Ensure the shared `proxy` network exists.
#   4. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# The two Authentik OIDC values stay BLANK on purpose — they are copied by hand
# from Authentik (docs/monitoring-setup.md Part B), which is also when
# GRAFANA_OIDC_ENABLED flips to true. The stack comes up fine without them.
#
# Re-runnable: it never rotates a secret that is already set. Run from anywhere.
# Usage (from the repo root):
#   scripts/init-monitoring.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/monitoring"
ENV_FILE="${STACK_DIR}/.env"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-host.sh first." >&2
  exit 1
fi

echo "==> Creating persistent data tree under /opt/monitoring"
run_root mkdir -p /opt/monitoring/postgres /opt/monitoring/grafana \
  /opt/monitoring/prometheus /opt/monitoring/loki /opt/monitoring/alloy
# Each image drops to a different user and must own its data dir, or it
# crash-loops on first boot. These UIDs were read from the PINNED images'
# own configs, not guessed:
#   grafana/grafana:13.1  -> 472
#   prom/prometheus:v3    -> nobody (65534)
#   grafana/loki:3        -> 10001
#   grafana/alloy:v1.18.0 -> root, so its dir needs no chown
# Postgres manages its own dir's ownership.
run_root chown -R 472:472 /opt/monitoring/grafana
run_root chown -R 65534:65534 /opt/monitoring/prometheus
run_root chown -R 10001:10001 /opt/monitoring/loki

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Seeding ${ENV_FILE} from .env.example"
  cp "${STACK_DIR}/.env.example" "$ENV_FILE"
fi

# Fill a blank KEY= line with a generated secret. Idempotent: only rewrites a
# line whose value is EMPTY, so re-runs never rotate an existing secret. Uses a
# temp file for a portable in-place edit (same helper as init-authentik.sh).
ensure_secret() {
  local key="$1" value="$2"
  if grep -q "^${key}=$" "$ENV_FILE"; then
    grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
    echo "${key}=${value}" >> "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
    echo "==> Generated ${key} in .env"
  fi
}

echo "==> Ensuring secrets are set in ${ENV_FILE}"
# Postgres keeps the password its data dir was FIRST initialized with, so this
# only generates for fresh installs (blank value). On an existing deployment,
# set GRAFANA_DB_PASSWORD in .env to the current password by hand.
ensure_secret GRAFANA_DB_PASSWORD "$(openssl rand -base64 36 | tr -d '\n')"
# The break-glass login. Applied only when the Grafana DB is first initialized.
ensure_secret GRAFANA_ADMIN_PASSWORD "$(openssl rand -base64 24 | tr -d '\n')"

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the monitoring stack into ${STACKS_DIR}/monitoring (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/monitoring"

echo
echo "Done. Next (see docs/monitoring-setup.md):"
echo "  1. Add a DNS host record on the UDR: grafana.thefipster.de -> the infra"
echo "     VM (192.168.1.41). The *.thefipster.de wildcard points at the APPS"
echo "     VM, so without an exact record the name resolves to the wrong box."
echo "  2. cd ${STACK_DIR} && docker compose up -d"
echo "  3. Log in at https://grafana.thefipster.de as 'admin' using"
echo "     GRAFANA_ADMIN_PASSWORD from ${ENV_FILE}; check both datasources."
echo "  4. Part B: create the Authentik provider + application, put the client"
echo "     id/secret in .env, set GRAFANA_OIDC_ENABLED=true, and restart."
```

- [ ] **Step 2: Verify shell syntax**

```bash
bash -n scripts/init-monitoring.sh; echo "exit=$?"
```

Expected: **exit=0**, no output.

- [ ] **Step 3: Verify the file has LF line endings and is executable**

```bash
file scripts/init-monitoring.sh
git add scripts/init-monitoring.sh && git update-index --chmod=+x scripts/init-monitoring.sh
git ls-files -s scripts/init-monitoring.sh
```

Expected: `file` reports no `CRLF`; `git ls-files -s` shows mode **`100755`**. CRLF breaks the shebang on the VM — if `file` says CRLF, convert before committing.

- [ ] **Step 4: Verify it matches the sibling scripts' shape**

```bash
grep -c 'set -euo pipefail\|run_root()\|BASH_SOURCE' scripts/init-monitoring.sh
```

Expected: **3** or more — confirms the three shared conventions are present.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(monitoring): add scripts/init-monitoring.sh"
```

---

### Task 5: The setup guide

**Files:**
- Create: `docs/monitoring-setup.md`

**Interfaces:**
- Consumes (from Tasks 1–4): everything above — the stack, its `.env` var names, the init script's steps, the Alloy loopback port, the datasource UIDs, and the `service` label values.
- Produces: the runtime verification checklist, which is this feature's only end-to-end test.

- [ ] **Step 1: Create `docs/monitoring-setup.md`**

Write the guide with these sections, in this order, matching the voice of `docs/authentik-setup.md` (second person, numbered steps, explain *why* on anything non-obvious):

**Title + intro.** Monitoring on the infra VM: Grafana at `grafana.thefipster.de`, backed by Prometheus (metrics) and Loki (logs), collected by Alloy. State plainly that this is **phase 1** — the stack skeleton — and link `docs/roadmap/monitoring.md` for phases 2–5. State that Loki is empty until phase 2 and that this is expected, not a fault.

**Prerequisites.** Traefik and Authentik up (build order); Docker installed; the infra VM at 10 GB RAM.

**Part 0 — DNS.** Add an exact Host (A) record `grafana.thefipster.de` → `192.168.1.41` on the UDR, exactly like the rows in `docs/wildcard-dns-udr.md`. Explain the trap: `*.thefipster.de` points at the **apps** VM, so without the exact record the name silently resolves to the wrong box and you get someone else's 404. Verify with:

```bash
nslookup grafana.thefipster.de
```

Expected: `192.168.1.41`.

**Part 1 — Prep and bring-up.**

```bash
scripts/init-monitoring.sh
cd infra/monitoring && docker compose up -d
docker compose ps
```

Note that the first start pulls ~1 GB of images. Expected: five services, `db` healthy, none restarting. If a container restart-loops, check ownership under `/opt/monitoring` first — a wrong UID is the usual cause, and the init script's chowns are what fix it.

**Part 2 — Verify the stack (before touching SSO).** This is the checklist:

```bash
# Grafana is served over the wildcard cert
curl -sI https://grafana.thefipster.de | head -1          # expect: HTTP/2 302 (redirect to /login)

# Loki is healthy (empty, but alive)
docker compose exec loki wget -qO- localhost:3100/ready   # expect: ready

# Alloy's components are healthy — tunnel first:
#   ssh -L 12345:127.0.0.1:12345 <infra-vm>
# then open http://127.0.0.1:12345 and confirm every component is Healthy
```

Then in the browser: log in at `https://grafana.thefipster.de` as `admin` with `GRAFANA_ADMIN_PASSWORD` from `.env`, and confirm

- **Connections → Data sources** lists Prometheus (default) and Loki, both passing **Test**.
- **Explore → Prometheus**, query `up` — expect series for `service="alloy"`, `"prometheus"`, `"loki"` and `"grafana"`. This is the end-to-end proof: Alloy scraped, remote-wrote, Prometheus stored, Grafana read it back.
- State-persistence check: `docker compose down && docker compose up -d`, then log in again — your session/user survives, proving state is in Postgres and not a container layer.

**Part 3 — Authentik OIDC.** Mirroring `docs/authentik-setup.md` Part B:

1. **Provider:** Admin → Applications → Providers → Create → **OAuth2/OpenID Provider**. Name `grafana`. Authorization flow: the default explicit-consent (or implicit) flow. Client type **Confidential**. Redirect URI — **Strict**: `https://grafana.thefipster.de/login/generic_oauth`. Pick a signing key (the default self-signed one is fine). Save, then copy the **Client ID** and **Client Secret**.
2. **Application:** Admin → Applications → Applications → Create. Name `Grafana`, slug `grafana`, provider `grafana`. Save.
3. **Binding:** the application's **Policy / Group / User Bindings** tab → Bind existing Group → `lab-users`. Without a binding, access is denied.
4. **Wire Grafana:** put the two values in `infra/monitoring/.env`, set `GRAFANA_OIDC_ENABLED=true`, then `docker compose up -d grafana`.
5. **Verify:** the login page now shows **Sign in with Authentik**; it completes and lands you as an **Admin**. If you land with no permissions, the cause is almost always `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH` losing its inner quotes — the value must reach the container as `'Admin'`, quotes included.

**Break-glass.** Grafana's local `admin` login stays enabled deliberately. If Authentik is down or a provider change breaks SSO, log in with `admin` + `GRAFANA_ADMIN_PASSWORD`. Never set `GF_AUTH_DISABLE_LOGIN_FORM`.

**Troubleshooting.** At minimum:
- *Empty `up` query* → Alloy isn't writing. Check `docker compose logs alloy` and confirm `--web.enable-remote-write-receiver` is on the Prometheus command.
- *Prometheus "Targets" page is empty* → expected. Nothing scrapes from Prometheus; Alloy pushes.
- *Alloy won't start* → syntax check the config:
  ```bash
  docker run --rm -v /opt/stacks/monitoring/alloy/config.alloy:/c.alloy:ro grafana/alloy:v1.18.0 fmt /c.alloy
  ```
- *Grafana can't reach Authentik* → the container resolves `auth.thefipster.de` through the UDR back to Traefik on this same VM; confirm with `docker compose exec grafana wget -qO- -S https://auth.thefipster.de/-/health/live/ 2>&1 | head`.
- *Container restart-loop on first boot* → ownership under `/opt/monitoring`; re-run `scripts/init-monitoring.sh`.

**Verification checklist.** Close with a `- [ ]` checklist restating the Part 2 and Part 3 checks in one place.

- [ ] **Step 2: Verify every command in the guide is copy-pasteable**

Re-read the guide and confirm each fenced block is a single runnable command with no placeholder other than `<infra-vm>`, and that every path, port, env var name, datasource UID and label value matches Tasks 1–4 exactly.

- [ ] **Step 3: Commit**

```bash
git add docs/monitoring-setup.md
git commit -m "docs: add the monitoring setup guide"
```

---

### Task 6: Fold monitoring into the repo's docs

**Files:**
- Modify: `README.md` (architecture box, layer table, Networking & DNS list, repo layout tree, build order, status table)
- Modify: `docs/wildcard-dns-udr.md:63-69` (exact host records table)
- Modify: `docs/roadmap/monitoring.md` (mark phase 1 landed; correct the RAM note)
- Modify: `CLAUDE.md` (topology, deploy ordering, SSO convention)

**Interfaces:**
- Consumes (from Tasks 1–5): the stack path `infra/monitoring/`, `scripts/init-monitoring.sh`, `docs/monitoring-setup.md`, and the hostname `grafana.thefipster.de`.

- [ ] **Step 1: `docs/wildcard-dns-udr.md` — add the host record row**

In the table at lines 63–69, after the `traefik.thefipster.de` row:

```markdown
| `grafana.thefipster.de` | `192.168.1.41` | Grafana monitoring UI (via Traefik) |
```

- [ ] **Step 2: `README.md` — five edits**

1. **Architecture box** — add a line to the infra VM box: `│ Grafana: metrics +  │` / `│   logs              │` (keep the existing box width).
2. **Layer table** — extend the **infra VM** row's "Runs" cell to `Traefik + Authentik + Forgejo + Dockge + Grafana` and mention monitoring in its Purpose cell.
3. **Networking & DNS** — add after the `traefik.thefipster.de` bullet:
   ```markdown
   - `grafana.thefipster.de` → infra VM — Grafana (metrics + logs), SSO via Authentik OIDC.
   ```
4. **Repo layout tree** — add under `docs/`: `│   ├── monitoring-setup.md       Grafana + Prometheus + Loki + Alloy`; under `scripts/`: `│   └── init-monitoring.sh        Monitoring: data tree, .env secrets`; and an `infra/monitoring/` block listing `compose.yaml`, `.env.example`, `alloy/config.alloy`, `loki/loki.yaml`, `prometheus/prometheus.yml`, `grafana/provisioning/`.
5. **Build order** — insert as a new step after Forgejo (renumbering Coolify to 7):
   ```markdown
   6. **[Monitoring](docs/monitoring-setup.md)** — Grafana + Prometheus + Loki +
      Alloy on the infra VM; Grafana joins Authentik by OIDC. Needs a new
      `grafana.thefipster.de` host record — the wildcard points at the apps VM.
   ```
6. **Status table** — change the monitoring row to:
   ```markdown
   | Monitoring: Grafana + Prometheus + Loki + Alloy | ✅ phase 1 deployed — [guide](docs/monitoring-setup.md), [next phases](docs/roadmap/monitoring.md) |
   ```

- [ ] **Step 3: `docs/roadmap/monitoring.md` — mark phase 1 landed**

1. Under `## Phases`, prefix item 1 with `**✅ Landed** — see [docs/monitoring-setup.md](../monitoring-setup.md).` and keep its text as the record of what shipped.
2. In `## Constraints & notes`, replace the RAM bullet with the resolved fact:
   ```markdown
   - **RAM: resolved.** The infra VM was raised from 4 GB to **10 GB** before
     phase 1, so the stack needs no memory limits. Revisit only if phase 3's
     per-container metrics change the picture.
   ```
3. Add a line under the phase list noting that phase 1 shipped **without** the `docker.sock` mount — phase 2 adds it along with `discovery.docker`.

- [ ] **Step 4: `CLAUDE.md` — three edits**

1. **Topology** section, infra VM bullet: add Grafana — `Traefik + Authentik + Forgejo + Dockge + monitoring (the stacks in `infra/`)`.
2. **The SSO convention** section, OIDC bullet: add Grafana alongside Forgejo as an OIDC service, with the one-line reason (native SSO support → never forward-auth).
3. **Deploy model & ordering**: add step 6 — `scripts/init-monitoring.sh` — creating `/opt/monitoring`, generating the two Grafana secrets, symlinking the stack; note it comes after Authentik because Grafana's OIDC needs a provider, and that the stack still starts fine before SSO is wired (`GRAFANA_OIDC_ENABLED=false`).
4. In **Conventions & gotchas**, extend the image-pin bullet: Authentik is not the only exception — `grafana/grafana` is pinned major.minor (no bare-major tag published) and `grafana/alloy` to a full patch (only `vX.Y.Z` tags published).

- [ ] **Step 5: Verify every new link resolves**

```bash
for f in docs/monitoring-setup.md docs/roadmap/monitoring.md infra/monitoring/compose.yaml scripts/init-monitoring.sh; do
  test -e "$f" && echo "ok   $f" || echo "MISS $f"
done
grep -n 'monitoring' README.md CLAUDE.md docs/wildcard-dns-udr.md | head -30
```

Expected: four `ok` lines, and the grep shows the new references in all three files.

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md docs/wildcard-dns-udr.md docs/roadmap/monitoring.md
git commit -m "docs: fold the monitoring stack into the repo docs"
```

---

## Self-review

**Spec coverage** — every spec section maps to a task: stack layout → 1; the five services and their pins/UIDs → 1; config files → 2, 3; Alloy's phase-1 behaviour → 3; `.env`/secrets → 1, 4; init script → 4; Authentik integration → 5 (Part 3); the DNS prerequisite → 5 (Part 0) and 6; verification → 5 (Part 2); error handling → 5 (Troubleshooting); documentation changes → 6.

**Deliberate additions beyond the spec**, both to make spec requirements actually verifiable:
- `GRAFANA_OIDC_ENABLED` — the spec's verification list wants local-admin login checked *before* the OIDC login, which is impossible if a `${VAR:?}` guard on the client id blocks start-up. Soft-defaulted OIDC vars plus an explicit enable flag let the stack come up, be verified, and gain SSO as a separate step.
- Alloy's `127.0.0.1:12345` port binding — the spec's checklist says "Alloy's UI shows all components healthy", which needs the port reachable. Loopback-bound, so it stays off the network without a route or cert.

**Naming consistency checked across tasks:** service names (`db`, `grafana`, `prometheus`, `loki`, `alloy`), env var names (all five), data paths (`/opt/monitoring/*`), mount targets, datasource UIDs (`prometheus`, `loki`), the `service` label values, and the image pins are identical everywhere they appear in Tasks 1–6.
