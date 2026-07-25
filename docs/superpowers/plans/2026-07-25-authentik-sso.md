# Authentik SSO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Authentik SSO stack to the infra VM and bring Forgejo (OIDC), Dockge and the Traefik dashboard (per-app forward-auth) under it, keeping a local-admin break-glass path.

**Architecture:** A new `infra/authentik/` compose stack (server + worker + dedicated `postgres:16` + `redis:7`) follows the repo's conventions — bind mounts under `/opt/authentik`, symlinked into `/opt/stacks`, joined to the external `proxy` network, routed by Traefik labels under the one wildcard cert. Forgejo integrates via a native OpenID Connect authentication source. Dockge and the Traefik dashboard are gated by Authentik's embedded outpost using per-application forward-auth: a single shared Traefik `forwardauth` middleware plus one `/outpost.goauthentik.io/` router per protected host, both declared as labels on the Authentik `server` container.

**Tech Stack:** Docker Compose, Traefik v3 (label-based routing + forwardauth middleware), Authentik (`ghcr.io/goauthentik/server`), PostgreSQL 16, Redis 7, Bash setup scripts.

## Testing model (read first — this repo has no unit-test harness)

This is infra-as-notes: correctness is verified by **config validation + review**, not a test runner (see `CLAUDE.md`). The objective gate for each compose task is:

```bash
docker compose -f <file> config -q     # exits 0 on valid YAML + resolved ${VAR} interpolation
```

`config` fails when a file is missing, YAML is malformed, or a `${VAR:?...}` guard is unset — that is our red→green signal. It needs the Docker CLI and a populated `.env`. If the workstation has no Docker, fall back to a pure-syntax check:

```bash
python -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1]))); print('yaml ok')" <file>
```

Runtime verification (actually logging in through Authentik) happens **on the infra VM** and is captured as the verification checklist inside `docs/authentik-setup.md` (Task 5) — that guide *is* the runtime test for this feature.

## Global Constraints

Copied verbatim from `CLAUDE.md` and the spec; every task's requirements implicitly include these.

- **Routing convention:** a proxied service joins the external `proxy` network (`external: true`) and adds `traefik.*` labels (`traefik.enable`, a `Host(...)` router rule, `entrypoints: websecure`, service `loadbalancer.server.port`). **No per-router TLS labels** — the single wildcard cert in `infra/traefik/compose.yaml` covers every `websecure` router.
- **Image pins are major-only** (`postgres:16-alpine`, `redis:7-alpine`, `traefik:v3`) — EXCEPT Authentik, pinned **major.minor** (`ghcr.io/goauthentik/server:2025.6`) because its `YYYY.M` releases carry breaking DB migrations between minors. Note this deviation in the compose comments.
- **`.env` is gitignored**; every stack ships a `.env.example`. Compose uses `${VAR:?message}` guards to fail fast on a missing var — preserve them.
- **Persistent state** bind-mounts under `/opt/<stack>`; stacks are exposed to Dockge by symlinking `infra/<stack>` into `/opt/stacks/<stack>`. The repo stays the single source of truth.
- **Init scripts** use `set -euo pipefail`, resolve paths from `$BASH_SOURCE` (run from anywhere), share the `run_root()` helper (direct if root, else `sudo`), and are re-runnable.
- **Line endings:** `.gitattributes` forces LF; `*.sh` MUST stay LF (CRLF breaks the shebang). Do not let an editor rewrite them.
- **Break-glass:** Forgejo local login stays ENABLED; forward-auth guards only the browser route and is removable by editing one label; `akadmin` is Authentik's recovery account.
- **Domain scheme:** exact-host records under `thefipster.de` → infra VM `.41`; new names `auth.thefipster.de` and `traefik.thefipster.de`.

---

### Task 1: Authentik stack (`infra/authentik/`)

**Files:**
- Create: `infra/authentik/compose.yaml`
- Create: `infra/authentik/.env.example`

**Interfaces:**
- Produces (consumed by Tasks 3, 4):
  - Traefik middleware named **`authentik@docker`** (a `forwardauth` middleware).
  - Traefik service named **`authentik`** (the server container, port 9000).
  - Per-host outpost routers **`ak-outpost-dockge`** and **`ak-outpost-traefik`** matching `Host(...) && PathPrefix(\`/outpost.goauthentik.io/\`)` → the `authentik` service.
- Produces (consumed by Task 2): the data paths `/opt/authentik/{postgres,redis,media,certs,templates}` and the env var names `AUTHENTIK_SECRET_KEY`, `PG_PASS`, `AUTHENTIK_BOOTSTRAP_PASSWORD`, `AUTHENTIK_BOOTSTRAP_TOKEN`.

- [ ] **Step 1: Create `infra/authentik/compose.yaml`**

```yaml
# Authentik — SSO identity provider for the INFRA VM.
#
# server + worker + a DEDICATED postgres/redis (not shared with Forgejo, so the
# stack backs up and version-pins independently). Routed by Traefik at
# auth.thefipster.de under the one wildcard cert (no per-router TLS labels).
#
# This stack also declares — as labels on the `server` container — the pieces
# that let OTHER stacks use Authentik for forward-auth:
#   * the shared `authentik@docker` forwardauth middleware, and
#   * one /outpost.goauthentik.io/ router per protected host (dockge, traefik),
#     required because single-application forward auth runs its handshake on
#     each app's own domain.
# Deploy (on the infra VM): scripts/init-authentik.sh, fill .env, compose up -d.
# Authentik must be RUNNING before Dockge/Traefik reference authentik@docker,
# or Traefik logs an "undefined middleware" error and those routers won't load.

name: authentik

services:
  db:
    image: postgres:16-alpine        # major pin, same policy as the Forgejo DB
    restart: unless-stopped
    environment:
      POSTGRES_USER: authentik
      POSTGRES_PASSWORD: ${PG_PASS:?set PG_PASS in .env}
      POSTGRES_DB: authentik
    volumes:
      - /opt/authentik/postgres:/var/lib/postgresql/data
    networks:
      - authentik-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U authentik"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine            # major pin
    restart: unless-stopped
    command: --save 60 1 --loglevel warning
    volumes:
      - /opt/authentik/redis:/data
    networks:
      - authentik-net
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 5

  server:
    image: ghcr.io/goauthentik/server:2025.6   # major.minor pin — breaking DB
    restart: unless-stopped                     # migrations between minors
    command: server
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY:?set AUTHENTIK_SECRET_KEY in .env}
      AUTHENTIK_POSTGRESQL__HOST: db
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS:?set PG_PASS in .env}
      AUTHENTIK_REDIS__HOST: redis
      # akadmin is created on FIRST boot from these. Keep it as break-glass.
      AUTHENTIK_BOOTSTRAP_PASSWORD: ${AUTHENTIK_BOOTSTRAP_PASSWORD:?set AUTHENTIK_BOOTSTRAP_PASSWORD in .env}
      AUTHENTIK_BOOTSTRAP_TOKEN: ${AUTHENTIK_BOOTSTRAP_TOKEN:-}
    volumes:
      - /opt/authentik/media:/media
      - /opt/authentik/templates:/templates
      - /opt/authentik/certs:/certs
    labels:
      traefik.enable: "true"
      # --- Authentik portal (auth.thefipster.de) ---------------------------
      traefik.http.routers.authentik.rule: Host(`auth.thefipster.de`)
      traefik.http.routers.authentik.entrypoints: websecure
      traefik.http.services.authentik.loadbalancer.server.port: "9000"
      # --- Shared forward-auth middleware (referenced as authentik@docker) --
      # `server` resolves on the proxy network via the compose service alias.
      traefik.http.middlewares.authentik.forwardauth.address: http://server:9000/outpost.goauthentik.io/auth/traefik
      traefik.http.middlewares.authentik.forwardauth.trustForwardHeader: "true"
      traefik.http.middlewares.authentik.forwardauth.authResponseHeaders: X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid
      # --- Per-host outpost-path routers (single-application forward auth) --
      # Each protected host must serve /outpost.goauthentik.io/ from the outpost
      # so the post-login callback lands on the app's own domain (else it 404s).
      traefik.http.routers.ak-outpost-dockge.rule: Host(`dockge.thefipster.de`) && PathPrefix(`/outpost.goauthentik.io/`)
      traefik.http.routers.ak-outpost-dockge.entrypoints: websecure
      traefik.http.routers.ak-outpost-dockge.service: authentik
      traefik.http.routers.ak-outpost-traefik.rule: Host(`traefik.thefipster.de`) && PathPrefix(`/outpost.goauthentik.io/`)
      traefik.http.routers.ak-outpost-traefik.entrypoints: websecure
      traefik.http.routers.ak-outpost-traefik.service: authentik
    networks:
      - authentik-net
      - proxy

  worker:
    image: ghcr.io/goauthentik/server:2025.6
    restart: unless-stopped
    command: worker
    # No docker.sock mount: the embedded outpost runs in `server`, so the worker
    # manages no outpost containers — keep its privilege minimal.
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY:?set AUTHENTIK_SECRET_KEY in .env}
      AUTHENTIK_POSTGRESQL__HOST: db
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS:?set PG_PASS in .env}
      AUTHENTIK_REDIS__HOST: redis
    volumes:
      - /opt/authentik/media:/media
      - /opt/authentik/templates:/templates
      - /opt/authentik/certs:/certs
    networks:
      - authentik-net

networks:
  authentik-net:
    driver: bridge
  proxy:
    external: true
```

- [ ] **Step 2: Create `infra/authentik/.env.example`**

```bash
# Copy to .env (gitignored) on the infra VM. scripts/init-authentik.sh
# auto-generates AUTHENTIK_SECRET_KEY and PG_PASS if you leave them blank.

# Django secret key — signs sessions & encrypts stored secrets. Losing it
# invalidates all sessions and encrypted values. Generate: openssl rand -base64 60
AUTHENTIK_SECRET_KEY=

# Password for Authentik's dedicated Postgres. Generate: openssl rand -base64 36
PG_PASS=

# Initial admin (akadmin) password — applied on FIRST boot only. Break-glass.
AUTHENTIK_BOOTSTRAP_PASSWORD=changeme

# Optional API token for akadmin (first boot only). Leave blank if unused.
AUTHENTIK_BOOTSTRAP_TOKEN=
```

- [ ] **Step 3: Validate the compose file**

Create a throwaway `.env` (gitignored) with dummy values so the `${VAR:?}` guards resolve, then validate:

```bash
cd infra/authentik
printf 'AUTHENTIK_SECRET_KEY=x\nPG_PASS=x\nAUTHENTIK_BOOTSTRAP_PASSWORD=x\nAUTHENTIK_BOOTSTRAP_TOKEN=\n' > .env
docker compose config -q && echo "config ok"
```

Expected: prints `config ok`, exit 0. (No Docker on the workstation? Use the `python -c "import yaml..."` fallback from the Testing model — expect `yaml ok`.)

- [ ] **Step 4: Confirm the produced names are present**

```bash
grep -q 'middlewares.authentik.forwardauth.address' infra/authentik/compose.yaml \
  && grep -q 'routers.ak-outpost-dockge' infra/authentik/compose.yaml \
  && grep -q 'routers.ak-outpost-traefik' infra/authentik/compose.yaml \
  && echo "interfaces ok"
```

Expected: prints `interfaces ok`.

- [ ] **Step 5: Commit**

```bash
git add infra/authentik/compose.yaml infra/authentik/.env.example
git commit -m "feat: add Authentik SSO stack (server, worker, postgres, redis)"
```

---

### Task 2: `scripts/init-authentik.sh`

**Files:**
- Create: `scripts/init-authentik.sh`

**Interfaces:**
- Consumes (from Task 1): data paths `/opt/authentik/{postgres,redis,media,certs,templates}`; env var names `AUTHENTIK_SECRET_KEY`, `PG_PASS`; the `.env.example` template.
- Produces: a re-runnable setup script; no code interface for later tasks (Task 5's guide references it by name).

- [ ] **Step 1: Create `scripts/init-authentik.sh` (ensure LF line endings)**

```bash
#!/usr/bin/env bash
#
# init-authentik.sh — project-specific setup for the Authentik SSO stack.
#
# Assumes Docker is installed (run scripts/init-host.sh first). Steps:
#   1. Create the persistent data tree under /opt/authentik.
#   2. Seed infra/authentik/.env from .env.example; auto-generate the two
#      secrets (AUTHENTIK_SECRET_KEY, PG_PASS) if they are still blank.
#   3. Ensure the shared `proxy` network exists.
#   4. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# Re-runnable: it never rotates a secret that is already set. Run from anywhere.
# Usage (from the repo root):
#   scripts/init-authentik.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/authentik"
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

echo "==> Creating persistent data tree under /opt/authentik"
run_root mkdir -p /opt/authentik/postgres /opt/authentik/redis \
  /opt/authentik/media /opt/authentik/certs /opt/authentik/templates

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Seeding ${ENV_FILE} from .env.example"
  cp "${STACK_DIR}/.env.example" "$ENV_FILE"
fi

# Fill a blank KEY= line with a generated secret. Idempotent: only rewrites a
# line whose value is EMPTY, so re-runs never rotate an existing secret. Uses a
# temp file for a portable in-place edit (same approach as init-forgejo.sh).
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
ensure_secret AUTHENTIK_SECRET_KEY "$(openssl rand -base64 60 | tr -d '\n')"
ensure_secret PG_PASS "$(openssl rand -base64 36 | tr -d '\n')"

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the Authentik stack into ${STACKS_DIR}/authentik (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/authentik"

echo
echo "Done. Next (see docs/authentik-setup.md):"
echo "  1. Review ${ENV_FILE} — set AUTHENTIK_BOOTSTRAP_PASSWORD."
echo "  2. cd ${STACK_DIR} && docker compose up -d"
echo "  3. Log in at https://auth.thefipster.de as akadmin, then wire providers."
```

- [ ] **Step 2: Verify shell syntax**

```bash
bash -n scripts/init-authentik.sh && echo "syntax ok"
```

Expected: prints `syntax ok`, exit 0. If `shellcheck` is installed, also run `shellcheck scripts/init-authentik.sh` and expect no errors (SC2086 on the intended word-splitting is not present here).

- [ ] **Step 3: Verify the file is LF, not CRLF**

```bash
file scripts/init-authentik.sh    # must NOT say "with CRLF line terminators"
```

Expected: `Bourne-Again shell script, ASCII text executable` (no "CRLF"). If it shows CRLF, run `sed -i 's/\r$//' scripts/init-authentik.sh`.

- [ ] **Step 4: Commit**

```bash
git add scripts/init-authentik.sh
git commit -m "feat: add init-authentik.sh setup script"
```

---

### Task 3: Protect Dockge with forward-auth

**Files:**
- Modify: `infra/dockge/compose.yaml:19-23` (the `labels:` block)

**Interfaces:**
- Consumes (from Task 1): the `authentik@docker` middleware and the `ak-outpost-dockge` router (already declared on the Authentik server container — nothing to add here for the outpost path).

- [ ] **Step 1: Add the middleware label to Dockge's router**

In `infra/dockge/compose.yaml`, the `labels:` block currently reads:

```yaml
    labels:
      traefik.enable: "true"
      traefik.http.routers.dockge.rule: Host(`dockge.thefipster.de`)
      traefik.http.routers.dockge.entrypoints: websecure
      traefik.http.services.dockge.loadbalancer.server.port: "5001"
```

Add one line so it becomes:

```yaml
    labels:
      traefik.enable: "true"
      traefik.http.routers.dockge.rule: Host(`dockge.thefipster.de`)
      traefik.http.routers.dockge.entrypoints: websecure
      traefik.http.services.dockge.loadbalancer.server.port: "5001"
      # Gate the UI behind Authentik (per-app forward auth). The middleware and
      # the /outpost.goauthentik.io/ router for this host live on the Authentik
      # `server` container (infra/authentik). Authentik must be up first, else
      # Traefik reports an undefined middleware and this router won't load.
      # Break-glass: comment this line and `docker compose up -d` to bypass.
      traefik.http.routers.dockge.middlewares: authentik@docker
```

- [ ] **Step 2: Validate**

```bash
docker compose -f infra/dockge/compose.yaml config -q && echo "config ok"
```

Expected: `config ok`. (Dockge's compose has no `${VAR:?}` guards, so no `.env` is needed. Workstation without Docker: use the python YAML fallback.)

- [ ] **Step 3: Commit**

```bash
git add infra/dockge/compose.yaml
git commit -m "feat: gate Dockge behind Authentik forward-auth"
```

---

### Task 4: Expose and protect the Traefik dashboard

**Files:**
- Modify: `infra/traefik/compose.yaml` — add two `command` flags after line 43, and add a `labels:` block to the `traefik` service (it currently has none; insert before `environment:` at line 64).

**Interfaces:**
- Consumes (from Task 1): the `authentik@docker` middleware and the `ak-outpost-traefik` router.

- [ ] **Step 1: Enable the API/dashboard**

In `infra/traefik/compose.yaml`, immediately after the line:

```yaml
      - --entrypoints.websecure.http.tls.domains[0].main=*.thefipster.de
```

insert:

```yaml
      # --- API / dashboard -------------------------------------------------
      # Exposed at traefik.thefipster.de, but ONLY because Authentik forward
      # auth gates it (see the labels below). Never expose the dashboard raw.
      - --api=true
      - --api.dashboard=true
```

- [ ] **Step 2: Add the dashboard router labels to the `traefik` service**

The `traefik` service currently has no `labels:` key. Insert one immediately before its `environment:` block (line 64):

```yaml
    labels:
      traefik.enable: "true"
      traefik.http.routers.dashboard.rule: Host(`traefik.thefipster.de`)
      traefik.http.routers.dashboard.entrypoints: websecure
      # api@internal is Traefik's built-in dashboard service.
      traefik.http.routers.dashboard.service: api@internal
      # Gate it behind Authentik. Middleware + this host's outpost router live
      # on the Authentik `server` container. Break-glass: comment this line.
      traefik.http.routers.dashboard.middlewares: authentik@docker
```

- [ ] **Step 3: Validate**

```bash
cd infra/traefik
# reuse or create a dummy .env so the netcup ${VAR:?} guards resolve
[ -f .env ] || printf 'ACME_EMAIL=x\nNETCUP_CUSTOMER_NUMBER=x\nNETCUP_API_KEY=x\nNETCUP_API_PASSWORD=x\n' > .env
docker compose config -q && echo "config ok"
```

Expected: `config ok`. Then confirm both flags and the router landed:

```bash
grep -q -- '--api.dashboard=true' infra/traefik/compose.yaml \
  && grep -q 'routers.dashboard.service: api@internal' infra/traefik/compose.yaml \
  && echo "dashboard ok"
```

Expected: `dashboard ok`.

- [ ] **Step 4: Commit**

```bash
git add infra/traefik/compose.yaml
git commit -m "feat: expose Traefik dashboard behind Authentik forward-auth"
```

---

### Task 5: Authentik setup guide (`docs/authentik-setup.md`)

**Files:**
- Create: `docs/authentik-setup.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4 (stack, script, the two protected services). This guide is the runtime verification procedure for the whole feature.

- [ ] **Step 1: Create `docs/authentik-setup.md` with this content**

````markdown
# Authentik SSO (infra VM)

[Authentik](https://goauthentik.io) is the lab's single sign-on identity
provider, at **`https://auth.thefipster.de`**, behind the
[Traefik stack](traefik-setup.md) under the same wildcard cert. It brings three
services under SSO, each by the method that fits it:

| Service | Method | Why |
|---------|--------|-----|
| Forgejo (`git.thefipster.de`) | native **OIDC** | Forgejo also authenticates `git push`, `docker login`/registry and CI — none carry a browser cookie, so only real OIDC accounts cover them. |
| Dockge (`dockge.thefipster.de`) | **forward-auth** | No native SSO; gated at the proxy. |
| Traefik dashboard (`traefik.thefipster.de`) | **forward-auth** | Exposed *only because* forward-auth guards it. |

Forward-auth is **per application**: each protected host has its own Authentik
Application + access policy, so services are authorized independently.

> **Break-glass first.** This is a single-node lab. Forgejo keeps **local login
> enabled**, so an Authentik outage never locks you out of git. Forward-auth
> guards only the browser route: comment the one `middlewares` label on Dockge
> or Traefik and `docker compose up -d` to bypass. `akadmin` is Authentik's own
> recovery account.

## Layout on the server

Same two-location convention as the Forgejo stack:

| What | Where |
|------|-------|
| Compose project (this repo) | `infra/authentik/` |
| Persistent data | `/opt/authentik/{postgres,redis,media,certs,templates}` |

## Part 0 — Bring up Authentik

Traefik must be up first (Authentik is served at `https://auth.thefipster.de`).

```bash
cd ~/home-lab
scripts/init-authentik.sh     # data tree, generates secrets in .env, symlinks for Dockge
```

`init-authentik.sh` auto-generates `AUTHENTIK_SECRET_KEY` and `PG_PASS` into
`infra/authentik/.env`. Open that file and set `AUTHENTIK_BOOTSTRAP_PASSWORD`
(your initial `akadmin` password). Then:

```bash
cd ~/home-lab/infra/authentik
docker compose up -d
docker compose logs -f server    # wait for migrations; first boot takes a minute
```

Open `https://auth.thefipster.de`, log in as **`akadmin`** with the bootstrap
password. If the portal loads with a trusted cert, the stack and routing are
good.

> Deploy Authentik **before** Tasks that reference `authentik@docker` (Dockge,
> Traefik dashboard). If those routers load while Authentik is down, Traefik
> logs `middleware "authentik@docker" does not exist` and the route 404s.

## Part A — Forward-auth for Dockge and the Traefik dashboard

Do this **once per service**. Values for the two services:

| | Dockge | Traefik dashboard |
|-|--------|-------------------|
| Provider name | `dockge-forwardauth` | `traefik-forwardauth` |
| External host | `https://dockge.thefipster.de` | `https://traefik.thefipster.de` |
| Application name / slug | `Dockge` / `dockge` | `Traefik` / `traefik` |

1. **Create the provider.** In Authentik: **Admin → Applications → Providers →
   Create → Proxy Provider**.
   - Name: as above.
   - Authorization flow: `default-provider-authorization-implicit-consent`.
   - Mode: **Forward auth (single application)**.
   - External host: as above.
   - Save.
2. **Create the application.** **Admin → Applications → Applications → Create**.
   - Name / Slug: as above.
   - Provider: the provider you just made.
   - Save. (Leave the policy engine unset for now = allow any authenticated
     user; add a group binding later when you have more than one user.)
3. **Attach both to the embedded outpost.** **Admin → Applications → Outposts →
   `authentik Embedded Outpost` → Edit → Applications**: add both `Dockge` and
   `Traefik`. Save. The outpost updates within a few seconds.

The Traefik side is already wired (Tasks 1, 3, 4): the `authentik@docker`
middleware and the per-host `/outpost.goauthentik.io/` routers live on the
Authentik `server` container; Dockge and the dashboard carry the middleware
label.

**Verify:** open `https://dockge.thefipster.de` in a private window → you are
redirected to Authentik, and after login land on Dockge. Repeat for
`https://traefik.thefipster.de` (the dashboard should load, gated). Each is an
independent app in **Admin → Events → Logs**.

## Part B — Forgejo via OIDC

1. **Create the Forgejo provider in Authentik.** **Providers → Create →
   OAuth2/OpenID Provider**.
   - Name: `forgejo`.
   - Authorization flow: `default-provider-authorization-implicit-consent`.
   - Client type: **Confidential**.
   - Redirect URIs (exact):
     `https://git.thefipster.de/user/oauth2/authentik/callback`
   - Signing Key: the default (`authentik Self-signed Certificate`).
   - Save, then note the generated **Client ID** and **Client Secret**.
2. **Create the application:** **Applications → Create** → Name `Forgejo`, Slug
   `forgejo`, Provider `forgejo`.
   - The discovery URL is then:
     `https://auth.thefipster.de/application/o/forgejo/.well-known/openid-configuration`
3. **Add the source in Forgejo.** **Site Administration → Identity & Access →
   Authentication Sources → Add Authentication Source**.
   - Type: **OAuth2**.
   - Authentication Name: **`authentik`** — this MUST be `authentik`, because
     Forgejo builds the callback as `/user/oauth2/<name>/callback`, and that
     has to match the redirect URI in step 1.
   - OAuth2 Provider: **OpenID Connect**.
   - Client ID / Client Secret: from step 1.
   - OpenID Connect Auto Discovery URL: the discovery URL from step 2.
   - Enable **Auto Registration**; set account linking to **automatic** (link by
     email) so your Authentik identity maps onto the existing Forgejo admin
     account (same email) instead of creating a second user.
   - Save.
4. **Do NOT disable local login** — leave password sign-in on (break-glass).

**Verify:** log out of Forgejo, open `https://git.thefipster.de`, click **Sign
in with authentik**, authenticate → you land in the existing admin account.
Local username/password login still works.

## Verification checklist (runtime)

- [ ] `https://auth.thefipster.de` serves the Authentik portal on the wildcard cert.
- [ ] Unauthenticated `https://dockge.thefipster.de` redirects to Authentik, returns after login.
- [ ] Unauthenticated `https://traefik.thefipster.de` redirects to Authentik, then shows the dashboard.
- [ ] Forgejo shows "Sign in with authentik"; using it logs into the existing admin; local login still works.
- [ ] `docker login git.thefipster.de` and an Actions build/push still succeed (OIDC didn't disturb git/registry auth).

## Break-glass procedures

- **Forgejo** — local admin password still works if Authentik is down.
- **Dockge / Traefik dashboard** — comment the `traefik.http.routers.*.middlewares: authentik@docker` label and `docker compose up -d` to bypass; drive Docker over SSH meanwhile. Dockge's own login remains underneath.
- **Authentik itself** — `akadmin` is the recovery account; its password is `AUTHENTIK_BOOTSTRAP_PASSWORD` (first boot) or resettable via `docker compose run --rm server make-admin` per Authentik docs.

## Teardown / backup

State is bind-mounted under `/opt/authentik`, so `docker compose down` keeps
data. Back up the filesystem plus a Postgres dump; keep `.env` (the
`AUTHENTIK_SECRET_KEY` is not recoverable — losing it invalidates sessions and
encrypted secrets).

```bash
docker compose down
sudo tar czf authentik-backup-$(date +%F).tar.gz -C /opt authentik
docker compose up -d
```
````

- [ ] **Step 2: Verify internal links resolve**

```bash
grep -q 'traefik-setup.md' docs/authentik-setup.md && echo "links ok"
```

Expected: `links ok`. Eyeball the guide once for the two value tables (Part A/B) — every URL uses `thefipster.de` and the Forgejo auth name is `authentik`.

- [ ] **Step 3: Commit**

```bash
git add docs/authentik-setup.md
git commit -m "docs: add Authentik SSO setup guide"
```

---

### Task 6: Update README, CLAUDE.md, and existing guides

**Files:**
- Modify: `README.md` (architecture box, DNS list, repo layout, build order, status table)
- Modify: `CLAUDE.md` (topology + a two-SSO-patterns convention note)
- Modify: `docs/wildcard-dns-udr.md` (two new exact-host records)
- Modify: `docs/forgejo-setup.md` (OIDC note)
- Modify: `docs/traefik-setup.md` (dashboard-now-exposed note)

**Interfaces:**
- Consumes: names/paths from Tasks 1–5. No downstream interface.

- [ ] **Step 1: `README.md` — infra-VM box in the architecture diagram**

In the code-fenced diagram, change the infra VM block so Authentik appears:

```
  ┌─ infra VM (.41) ─┐   ┌─ apps VM (.42) ─┐
  │ Traefik: TLS +   │   │ Coolify: PaaS   │
  │   routing        │   │                 │
  │ Authentik: SSO   │   │ your apps       │
  │ Forgejo: CI +    │   │                 │
  │   registry       │   │                 │
  │ Dockge: compose  │   │                 │
  │   management UI  │   │                 │
  └──────────────────┘   └─────────────────┘
```

- [ ] **Step 2: `README.md` — layer table, DNS list, repo layout, build order, status**

- In the layer table row for the infra VM, append Authentik: change `Traefik + Forgejo + Dockge` to `Traefik + Authentik + Forgejo + Dockge`, and add to the Purpose cell: `SSO (Authentik) fronts the infra UIs.`
- In **Networking & DNS**, add two bullets after the `dockge.` bullet:

```markdown
- `auth.thefipster.de` → infra VM — Authentik SSO portal, HTTPS via Traefik.
- `traefik.thefipster.de` → infra VM — Traefik dashboard, gated by Authentik.
```

- In the **Repository layout** block, add under `infra/`:

```
│   ├── authentik/
│   │   ├── compose.yaml          Authentik SSO (server, worker, postgres, redis)
│   │   └── .env.example          secret-key / DB / bootstrap template
```

and under `scripts/`:

```
│   ├── init-authentik.sh         Authentik: data tree, generate secrets
```

and under `docs/`:

```
│   ├── authentik-setup.md        SSO with Authentik (OIDC + forward-auth)
```

- In **Build order**, insert a step after Forgejo (renumber following steps):

```markdown
5. **[Authentik](docs/authentik-setup.md)** — SSO on the infra VM; bring Forgejo
   (OIDC), Dockge and the Traefik dashboard (forward-auth) under it.
```

- In the **Status** table add a row: `| Authentik SSO (OIDC + forward-auth) | ✅ stack + guide in repo |`.

- [ ] **Step 3: `CLAUDE.md` — topology + SSO convention**

- In the **Topology** section, in the infra VM bullet, change `Traefik + Forgejo + Dockge (the stacks in \`infra/\`)` to `Traefik + Authentik + Forgejo + Dockge (the stacks in \`infra/\`)`.
- After **The routing convention** section, add a new short section:

```markdown
## The SSO convention (Authentik)

Authentik (`infra/authentik`, `auth.thefipster.de`) is the identity provider.
Services join it by **one of two patterns**, never both:

- **OIDC** — for services that also authenticate non-browser traffic (Forgejo:
  git push, `docker login`/registry, CI). Configured *in the app* as an OpenID
  Connect source pointing at Authentik. Local login stays enabled (break-glass).
- **Forward-auth** — for plain web UIs with no SSO support (Dockge, the Traefik
  dashboard). Per application: the shared `authentik@docker` `forwardauth`
  middleware plus a per-host `/outpost.goauthentik.io/` router — both declared as
  labels on the Authentik `server` container — and a `...middlewares:
  authentik@docker` label on the protected router. Authentik must be running or
  Traefik reports the middleware undefined; comment the label to break-glass.
```

- [ ] **Step 4: `docs/wildcard-dns-udr.md` — add the two exact-host records**

Find the section listing the infra exact-host overrides (the `git.` / `dockge.` → `.41` records) and add alongside them:

```markdown
- `auth.thefipster.de` → `192.168.1.41` (infra VM) — Authentik SSO portal.
- `traefik.thefipster.de` → `192.168.1.41` (infra VM) — Traefik dashboard (gated by Authentik).
```

- [ ] **Step 5: `docs/forgejo-setup.md` — OIDC note**

At the end of **Part A** (after the first-run admin account step), add:

```markdown
> **SSO (optional, recommended).** Once [Authentik](authentik-setup.md) is up,
> add it as an OpenID Connect authentication source (Authentik guide, Part B) so
> you can sign in with SSO. Keep **local login enabled** — it is the break-glass
> path if Authentik is ever down.
```

- [ ] **Step 6: `docs/traefik-setup.md` — dashboard note**

Add a short subsection near the end (before any teardown/troubleshooting):

```markdown
## Dashboard

The API/dashboard is enabled (`--api.dashboard=true`) and served at
`https://traefik.thefipster.de`, but **only** because Authentik forward-auth
gates it (`traefik.http.routers.dashboard.middlewares: authentik@docker`). Do
not expose it without that middleware. See [authentik-setup.md](authentik-setup.md).
```

- [ ] **Step 7: Verify cross-references and commit**

```bash
grep -q 'auth.thefipster.de' README.md \
  && grep -q 'SSO convention' CLAUDE.md \
  && grep -q 'auth.thefipster.de' docs/wildcard-dns-udr.md \
  && echo "docs ok"
git add README.md CLAUDE.md docs/wildcard-dns-udr.md docs/forgejo-setup.md docs/traefik-setup.md
git commit -m "docs: reflect Authentik SSO across README, CLAUDE.md and guides"
```

Expected: `docs ok`, then a clean commit.

---

## Notes for the executor

- **Runtime ordering on the VM:** deploy the Authentik stack (Task 1) and complete Authentik guide Part 0 **before** Dockge/Traefik reference `authentik@docker`, or Traefik logs an undefined-middleware error and those routes 404. In the repo the edits are independent; only the live rollout is ordered.
- **The `2025.6` Authentik tag** is a concrete placeholder for "current stable major.minor". At execution, check the latest stable release and pin its `major.minor`; keep the major.minor-pin rationale comment.
- **Do not** add per-router TLS labels anywhere — the wildcard cert covers all of these new `websecure` routers.
