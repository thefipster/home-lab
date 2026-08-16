# Authentik SSO for the infra services

**Date:** 2026-07-25
**Status:** Approved design, pending implementation plan

## Goal

Add [Authentik](https://goauthentik.io) to the infra VM as a single sign-on
identity provider, then bring the existing infra services under it: **Forgejo**
(`git.thefipster.de`), **Dockge** (`dockge.thefipster.de`), and the Traefik
dashboard (newly exposed at `traefik.thefipster.de`). Authentik's own portal
lives at `auth.thefipster.de`. Everything stays on the LAN behind Traefik with
the existing wildcard TLS — nothing new is exposed to the internet.

## Constraints & decisions made

- **Scope: the three current infra UIs + Authentik itself.** The apps VM
  (Coolify) is out of scope — it gets its own outpost later, a separate effort.
- **Auth method is per-service, and effectively forced by each service:**
  - **Forgejo → native OIDC.** Forgejo authenticates more than a browser UI:
    `git push` over HTTPS, `docker login` / registry pulls, and the CI runner.
    None of those carry a browser session cookie, so a forward-auth proxy
    cannot cover them — only real OIDC accounts in Forgejo can. Forgejo uses
    Authentik as an OpenID Connect authentication source.
  - **Dockge + Traefik dashboard → forward-auth.** Neither has any SSO support.
    Authentik's embedded outpost exposes a forward-auth endpoint; a Traefik
    middleware (added as labels, like the existing routing labels) gates them.
- **Forward-auth is per application, not domain-level.** Each protected host
  gets its own Authentik Application and access-policy binding, so services can
  be authorized independently and the session cookie is scoped per host. The
  cost is a little more config per service (an Application plus a per-host
  outpost-path router); accepted for the granularity and to keep the door open
  to multi-user access later. Authentik still keeps one SSO session, so this
  does **not** mean re-entering credentials per app — hops stay silent.
- **Break-glass: keep a local admin fallback.** This is a single-node homelab —
  an Authentik outage must not lock the owner out. Forgejo keeps local login
  enabled; forward-auth only guards the browser route and can be bypassed by
  editing one label; `akadmin` is Authentik's own recovery account.
- **Single user, minimal authorization.** One admin identity (the owner) mapped
  onto the existing Forgejo admin account by email. No groups or role mapping
  now — extendable later.
- **Approach chosen: a dedicated Authentik stack** (its own Postgres + Redis),
  over reusing Forgejo's Postgres (couples two stacks, entangles backups and
  version pins) and over forward-auth-for-everything (breaks Forgejo
  git/registry/CI auth, forcing a second auth system on Forgejo anyway).

## Architecture

```
UniFi Dream Router — local DNS (split horizon)
  git.thefipster.de      → .41 (infra VM)   exact host record (existing)
  dockge.thefipster.de   → .41 (infra VM)   exact host record (existing)
  auth.thefipster.de     → .41 (infra VM)   exact host record (NEW)
  traefik.thefipster.de  → .41 (infra VM)   exact host record (NEW)
  *.thefipster.de        → .42 (apps VM)    wildcard (existing)
        │
  infra VM (.41)
  ┌──────────────────────────────────────────────────────────────┐
  │ Traefik  :80 :443   (one wildcard cert, *.thefipster.de)      │
  │   ├─ git.thefipster.de     → forgejo:3000   [OIDC in Forgejo] │
  │   ├─ dockge.thefipster.de  → dockge:5001    [forwardauth mw]  │
  │   ├─ traefik.thefipster.de → api@internal   [forwardauth mw]  │
  │   └─ auth.thefipster.de    → authentik server:9000           │
  │                                                              │
  │ Authentik stack: server + worker + postgres:16 + redis:7     │
  │   embedded outpost → forwardauth endpoint for the middleware  │
  └──────────────────────────────────────────────────────────────┘
```

### The two integration patterns

Every protected service uses exactly one of these; they are the cross-cutting
convention this work introduces.

1. **OIDC (Forgejo).** Authentik holds an OAuth2/OpenID Provider + Application;
   Forgejo adds an OpenID Connect authentication source pointing at it. Real
   Forgejo accounts are created/linked, so git, registry, and API auth all keep
   working through Forgejo's own tokens.
2. **Forward-auth (Dockge, Traefik dashboard).** One Proxy Provider +
   Application **per protected host** (forward-auth "single application" mode),
   all served by the one embedded outpost. Each Application carries its own
   access-policy binding, so services are authorized independently and the
   session cookie is scoped per host. A shared Traefik `forwardauth` middleware
   points at the outpost; per host, the service adds the middleware label **and**
   a router that sends that host's `/outpost.goauthentik.io/` path to the outpost
   (required so the auth handshake/callback runs on the app's own domain).
   Adding SSO to a new infra UI is: one Application in Authentik + the middleware
   label + the outpost-path router.

## Components

### New stack: `infra/authentik/`

Managed via Dockge like the other stacks. Follows every `infra/forgejo`
convention: bind mounts under `/opt/authentik`, symlinked into `/opt/stacks`,
joined to the external `proxy` network, `.env` gitignored with a committed
`.env.example` and `${VAR:?...}` guards.

| Service | Image | Role | Notes |
|---------|-------|------|-------|
| `server` | `ghcr.io/goauthentik/server` (`server` cmd) | Web UI + API + **embedded outpost** | Router `auth.thefipster.de`, container port `9000`, no host ports. Hosts the forward-auth endpoint. |
| `worker` | `ghcr.io/goauthentik/server` (`worker` cmd) | Background jobs, migrations, cert rotation | No ports. **No `docker.sock` mount** — embedded outpost means the worker manages no outpost containers, keeping privilege minimal. |
| `db` | `postgres:16-alpine` | Dedicated Postgres | Matches Forgejo's pin. `pg_isready` healthcheck; server/worker `depends_on` it healthy. |
| `redis` | `redis:7-alpine` | Cache / task queue | Required by Authentik. |

**Data tree** (bind mounts, backup-friendly like `/opt/forgejo`):

```
/opt/authentik/postgres    → db data
/opt/authentik/redis       → redis persistence
/opt/authentik/media       → server + worker (uploaded icons, etc.)
/opt/authentik/certs       → server + worker (SSO signing certs)
/opt/authentik/templates   → server + worker (custom flow templates; usually empty)
```

**Version-pin deviation (called out deliberately).** The repo pins images to the
**major** only (`traefik:v3`). Authentik releases on a `YYYY.M` cadence with
breaking DB migrations between minors, so "major only" is not meaningful for its
scheme. Authentik (`server`/`worker`) is pinned **major.minor** (e.g. `2025.x`);
`postgres:16-alpine` and `redis:7-alpine` keep the repo's major pin. The exact
current stable Authentik tag is chosen at implementation and noted in the compose
comments.

**Routing labels.** `auth.thefipster.de` gets the standard label block
(`traefik.enable`, `Host(...)`, `entrypoints: websecure`, service port `9000`) —
identical pattern to Forgejo/Dockge, covered by the one wildcard cert, no
per-router TLS labels.

**Forward-auth wiring.** Two pieces, both defined as Traefik labels on the
Authentik `server` container so the app stacks stay clean:

- **A shared `forwardauth` middleware** (`authentik@docker`):
  - address → `http://<server>:9000/outpost.goauthentik.io/auth/traefik`
  - `trustForwardHeader=true`
  - `authResponseHeaders=X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid`
- **One outpost-path router per protected host** — e.g.
  ``Host(`dockge.thefipster.de`) && PathPrefix(`/outpost.goauthentik.io/`)`` →
  the `server` service (port `9000`), `websecure`. Single-application forward
  auth runs its handshake on each app's own host, so every protected host needs
  this router; without it the post-login callback 404s.

A protected router opts in by adding `...middlewares=authentik@docker`. Because
Authentik selects the right Application by the forwarded host, the middleware
definition is shared while authorization stays per app.

### `.env` (gitignored) / `.env.example` (committed)

```
AUTHENTIK_SECRET_KEY=          # generate: openssl rand -base64 60
PG_PASS=                       # Authentik's Postgres password
AUTHENTIK_BOOTSTRAP_PASSWORD=  # initial akadmin password (first boot only)
AUTHENTIK_BOOTSTRAP_TOKEN=     # optional API token for akadmin
```

The Forgejo OIDC **client secret** is NOT stored here — it is generated in the
Authentik UI during setup and pasted into Forgejo (a manual one-time step, like
runner registration). `akadmin` is created automatically on first boot from the
`BOOTSTRAP_*` vars — no interactive install screen.

### `scripts/init-authentik.sh`

Mirrors `init-forgejo.sh` exactly — same `run_root()` helper, `set -euo
pipefail`, `$BASH_SOURCE` path resolution, re-runnable:

1. Create `/opt/authentik/{postgres,redis,media,certs,templates}`.
2. Seed `.env` from `.env.example` and **auto-generate** `AUTHENTIK_SECRET_KEY`
   and `PG_PASS` via `openssl rand` if not already set, rewriting idempotently
   (same approach as the existing `DOCKER_GID` line-rewrite logic) so no secret
   is left as a placeholder.
3. Ensure the `proxy` network exists; symlink the stack into
   `/opt/stacks/authentik` for Dockge.

### Changes to existing stacks

- **`infra/dockge/compose.yaml`** — add `traefik.http.routers.dockge.middlewares:
  authentik@docker` to the existing router. (The matching
  `/outpost.goauthentik.io/` router for `dockge.thefipster.de` lives on the
  Authentik `server` container, above.) Dockge's own login stays underneath.
- **`infra/traefik/compose.yaml`** — enable the API/dashboard (`--api=true`,
  `--api.dashboard=true`) and add a router `traefik.thefipster.de` →
  `api@internal` on `websecure` with the `authentik@docker` middleware. Its
  `/outpost.goauthentik.io/` router also lives on the Authentik `server`
  container. The dashboard is exposed *only because* forward-auth now guards it.
- **`infra/forgejo/compose.yaml`** — unchanged structurally. OIDC is configured
  at runtime through the Forgejo UI (authentication source), not via compose;
  local login stays enabled for break-glass.

## Setup order (on the infra VM)

Traefik must be up first, as always. Then:

1. **Deploy Authentik** — `scripts/init-authentik.sh`, fill any remaining `.env`
   values, `docker compose up -d`. Reach `https://auth.thefipster.de`, log in as
   `akadmin`.
2. **Wire forward-auth (per app)** — in Authentik, for **each** of Dockge and
   the Traefik dashboard create a Proxy Provider (forward-auth, single
   application; external host = that service's URL) + an Application with its own
   access-policy binding, and add both to the embedded outpost. Ensure each
   host's `/outpost.goauthentik.io/` router and the `authentik@docker` middleware
   label are in place; `up -d`. Verify each service independently redirects to
   Authentik and returns after login.
3. **Wire Forgejo OIDC** — in Authentik create an OAuth2/OpenID Provider +
   Application for Forgejo (redirect URI
   `https://git.thefipster.de/user/oauth2/authentik/callback`). In Forgejo:
   **Site Administration → Authentication Sources → Add OpenID Connect**, using
   the discovery URL
   `https://auth.thefipster.de/application/o/forgejo/.well-known/openid-configuration`
   and the client ID/secret from Authentik. Set **link by email + auto-register**
   so the Authentik identity maps onto the existing Forgejo admin (same email).
   Log in once via Authentik to confirm the link. **Leave local login enabled.**

### Verification

- `https://auth.thefipster.de` serves the Authentik portal on the wildcard cert.
- Visiting `https://dockge.thefipster.de` or `https://traefik.thefipster.de`
  unauthenticated redirects to Authentik and returns after login.
- Forgejo shows a "Sign in with Authentik" option; using it logs into the
  existing admin account. Local login still works.
- `docker login git.thefipster.de` and an Actions build/push still succeed
  (OIDC did not disturb Forgejo's token/registry auth).

## Break-glass (first-class, not an afterthought)

- **Forgejo** — local login stays enabled; use the local admin password if
  Authentik is down.
- **Dockge / Traefik dashboard** — forward-auth only guards the browser route.
  Recovery: comment the one `middlewares` label and `docker compose up -d` to
  bypass, or drive Docker via SSH/CLI. Dockge's own auth remains underneath.
- **Authentik** — `akadmin` is the built-in recovery account.

## Documentation changes (part of this work)

- **New `docs/authentik-setup.md`** — full walkthrough: `.env`/secrets,
  bring-up, the two manual integration steps (forward-auth provider + Forgejo
  OIDC source), verification, and the break-glass procedures.
- **`README.md`** — add Authentik to the infra-VM box in the architecture
  diagram and the layer table; add `auth.thefipster.de` and
  `traefik.thefipster.de` to Networking & DNS; add `infra/authentik/` and
  `scripts/init-authentik.sh` to the repo layout; insert Authentik into the
  build order (after Forgejo); add a status-table row.
- **`docs/forgejo-setup.md`** — add the OIDC authentication-source step; note
  local login stays enabled for break-glass.
- **`docs/traefik-setup.md`** — document the dashboard now exposed at
  `traefik.thefipster.de`, protected by Authentik forward-auth.
- **`docs/wildcard-dns-udr.md`** — add the `auth.` and `traefik.` exact-host
  records.
- **`CLAUDE.md`** — add Authentik to the topology; record the two SSO patterns
  (OIDC for git/registry-capable services, forward-auth middleware for plain
  UIs) as a cross-cutting convention.

## Error handling

- **Authentik down at login time:** break-glass paths above keep every service
  reachable; no service hard-depends on Authentik for owner access.
- **Forgejo OIDC misconfigured:** local login remains, so a bad OIDC source
  never locks Forgejo; fix and retry the source.
- **Forward-auth loop / outpost unreachable:** removing the one middleware label
  restores direct access immediately; Dockge's native auth still applies.
- **Secret loss (`AUTHENTIK_SECRET_KEY`):** documented as
  non-recoverable-in-place — sessions and encrypted values are invalidated;
  recovery is re-seeding the key and re-issuing provider secrets. `.env` is part
  of the VM backup.

## Out of scope

- Group / role mapping (single-user for now; add Authentik groups → Forgejo
  admin and future app roles later).
- The apps VM / Coolify — its bundled proxy gets its own outpost in a separate
  effort.
- Any public/internet exposure — everything stays LAN-only behind Traefik.
- MFA/enrollment flows beyond Authentik's defaults.
