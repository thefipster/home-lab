# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-notes for a personal homelab on **Proxmox VE**. It is not an
application — there is no build, lint, or test system. It holds Docker Compose
stacks, bash setup scripts, and Markdown guides that reproduce the lab. Most
"running" happens **on the VMs**, not on the machine you edit from (which is
Windows). Treat changes here as documentation + declarative config: correctness
is verified by reading, not by executing locally.

## Topology (why things are split the way they are)

Three tiers on one LAN (`192.168.1.0/24`) behind a UniFi Dream Router:

- **Proxmox host** (`.40`) — hypervisor only, no Docker. A bad container can't
  take the box down.
- **infra VM** (`.41`) — Traefik + Authentik + Forgejo + Dockge (the stacks in `infra/`).
- **apps VM** (`.42`) — Coolify (self-hosted PaaS). Coolify owns its own Docker
  and manages apps through its UI, so `apps/` is intentionally near-empty — app
  definitions live in Coolify, not this repo.

DNS is split-horizon: real subdomains of `thefipster.de` resolved locally by the
router; the public zone holds no A records. `git.` / `dockge.` → infra VM,
`*.thefipster.de` → apps VM. TLS everywhere is a genuine Let's Encrypt **wildcard**
issued via DNS-01 against the netcup API — nothing is exposed to the internet.

## The routing convention (most important cross-file pattern)

Traefik is the only thing that terminates TLS and does routing on the infra VM.
A stack becomes reachable by **two things**, not by any central config:

1. Joining the external `proxy` Docker network (declared `external: true`; created
   once by the init scripts).
2. Adding `traefik.*` labels: `traefik.enable`, a `Host(...)` router rule,
   `entrypoints: websecure`, and the service `loadbalancer.server.port`.

There are **no per-router TLS labels** — every `websecure` router is covered by
the single wildcard cert configured in `infra/traefik/compose.yaml`. When adding a
new proxied service, copy the label block from `infra/forgejo` or `infra/dockge`
and change the host + port. Do not add a TLS resolver or domain per router.

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

## Deploy model & ordering

Bring-up order matters and is enforced by the guides — Traefik must exist
before anything is reachable, and Authentik before anything it gates. On a VM,
the sequence is:

1. `scripts/init-host.sh` — installs Docker Engine + compose plugin (Ubuntu).
2. `scripts/init-traefik.sh` — creates the `proxy` network + ACME dir, seeds
   `.env` from `.env.example`. The entrypoint-level `tls.domains` makes
   Traefik request the wildcard cert at startup — no router needed.
3. `scripts/init-authentik.sh` — creates `/opt/authentik`, generates secrets
   into `.env`. Authentik is the first *routed* stack and must run before the
   forward-auth-gated routers (Dockge, Traefik dashboard) can load.
4. `scripts/init-dockge.sh` — copies the compose to `/opt/stacks/dockge`,
   records `REPO_DIR` in `.env` (the compose bind-mounts the repo checkout at
   an identical path so stack symlinks resolve inside the container), starts
   Dockge; afterwards it drives the other stacks from a web UI.
5. `scripts/init-forgejo.sh` — creates `/opt/forgejo` data tree, seeds `.env`
   (generates `FORGEJO_DB_PASSWORD`, records `DOCKER_GID`), symlinks the stack
   into `/opt/stacks`.

All init scripts are **idempotent-ish and re-runnable**, use `set -euo pipefail`,
resolve paths from `$BASH_SOURCE` (run from anywhere), and share a `run_root()`
helper (direct if already root, else `sudo`). Match that style in new scripts.

Persistent state convention: each stack bind-mounts its data under `/opt/<stack>`
(e.g. `/opt/forgejo`, `/opt/traefik/letsencrypt`), and stacks are exposed to
Dockge by symlinking `infra/<stack>` into `/opt/stacks/<stack>` — the repo stays
the single source of truth; Dockge only drives start/stop/logs.

## Conventions & gotchas that aren't obvious from a single file

- **Image pins are major-only** (`traefik:v3`, `dockge:1`, `postgres:16-alpine`,
  `forgejo:11`) — a deliberate policy; keep it when bumping. One deliberate
  exception: Authentik is pinned **major.minor** (`2025.6`) because its minor
  releases ship breaking DB migrations.
- **`.env` is gitignored**; every stack ships a `.env.example`. Secrets
  (netcup creds, `DOCKER_GID`) live only in the VM's `.env`. Compose uses
  `${VAR:?message}` to fail fast when one is missing — preserve those guards.
- **netcup DNS-01 is finicky.** Propagation is slow (~10 min), so
  `NETCUP_PROPAGATION_TIMEOUT` is 900s and propagation is checked against
  netcup's **authoritative** nameservers (not 1.1.1.1/8.8.8.8, which
  negative-cache the empty answer). The wildcard has **no apex SAN** on purpose
  (two TXT records at the same `_acme-challenge` FQDN race on netcup's
  non-atomic zone updates). Don't "simplify" these away.
- **First TLS bring-up uses the Let's Encrypt staging CA** (commented in
  `infra/traefik/compose.yaml`) to prove creds under loose rate limits, then
  switches to production by deleting `acme.json` and force-recreating.
- **Mounted `docker.sock` is root-equivalent** and used deliberately by Dockge,
  the Forgejo runner, and Traefik (read-only there). Acceptable only because
  this is a single-tenant box building the owner's own code — never extend this
  to untrusted/fork code.
- **CI is manual-only.** GitHub is primary and Forgejo pull-mirrors it, so
  `on: push` does not fire — the workflow's only trigger is
  `workflow_dispatch`, and every manual run builds and pushes (see
  `infra/forgejo/build-and-push.yml`, which is a template that lives in the
  *app* repo at `.forgejo/workflows/`, not on the infra VM).
- **Line endings:** `.gitattributes` forces LF repo-wide, and `*.sh` **must**
  stay LF even on Windows (CRLF breaks shebangs). Don't let an editor rewrite
  them to CRLF.

## Docs layout

`docs/` holds the reproduction guides (`proxmox-setup.md`, `wildcard-dns-udr.md`,
`traefik-setup.md`, `authentik-setup.md`, `forgejo-setup.md`) — the README's
"Build order" links them in sequence. `docs/superpowers/{specs,plans}/` holds dated design specs and
implementation plans (`YYYY-MM-DD-*.md`) produced by the superpowers workflow.
When the config and a guide disagree, the compose/script files are the source of
truth — update the guide to match.
