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
- **infra VM** (`.41`) — Traefik + Authentik + Forgejo + Dockge + monitoring
  (the stacks in `infra/`).
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

- **OIDC** — for services that authenticate non-browser traffic (Forgejo: git
  push, `docker login`/registry, CI) **or that simply have real SSO support**
  (Grafana). Configured *in the app* as an OpenID Connect source pointing at
  Authentik. Local login stays enabled (break-glass). Anything with native
  OIDC uses it — forward-auth is only for UIs that have no SSO at all.
- **Forward-auth** — for plain web UIs with no SSO support (Dockge, the Traefik
  dashboard). Per application: the shared `authentik@docker` `forwardauth`
  middleware plus a per-host `/outpost.goauthentik.io/` router — both declared as
  labels on the Authentik `server` container — and a `...middlewares:
  authentik@docker` label on the protected router. Authentik must be running or
  Traefik reports the middleware undefined; comment the label to break-glass.

**One service joins neither, deliberately: Uptime Kuma.** It has no OIDC, so
the convention would point at forward-auth — but gating the outage dashboard
behind the identity provider makes an Authentik outage the one failure you
cannot see, and break-glass would need SSH mid-incident. It keeps its own local
login instead. Treat this as a stated exception, not a gap to close:
`infra/uptime-kuma/compose.yaml` carries no `middlewares` label and
`infra/authentik/compose.yaml` no outpost router for it, both commented in
place, with the reasoning in `sso-applications.md`.

Not every SSO knob is clickwork: Forgejo's auto-registration and account
linking are **instance settings** in the compose
(`FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION`, `...__ACCOUNT_LINKING`),
not fields on its "Add Authentication Source" form — that form has neither.
Linking matches on **email**, so the Authentik user and the Forgejo admin must
share an address or SSO silently creates a second account. `sso-applications.md`
records which side each value lives on; keep that column honest.

## Deploy model & ordering

Bring-up order matters and is enforced by the guides — Traefik must exist
before anything is reachable, and Authentik before anything it gates. On a VM,
the sequence is:

The first three are **host** scripts, not stack scripts, and the split between
them is deliberate: only the middle one is about Docker, so only it is
infra-VM-only. The apps VM runs the other two (it gets its Docker from
Coolify's installer).

1. `scripts/init-host.sh` — machine-level basics with no Docker in them; today
   that is relaxing the time-sync daemon's step policy (chrony `makestep 1 -1`,
   or a tighter `PollIntervalMaxSec` for systemd-timesyncd). A Proxmox snapshot
   rollback resumes the guest with a stale clock, and chrony's default
   `makestep 1 3` would only ever slew it back — every TLS client then fails
   with "certificate has expired or is not yet valid". **First on both VMs**,
   because everything after it (apt, curl, ACME) does TLS. New host setup that
   isn't tied to a stack or to Docker belongs here.
2. `scripts/init-docker.sh` — installs Docker Engine + compose plugin from
   Docker's apt repo (Ubuntu) and adds the invoking user to the `docker` group.
   Docker and nothing else — the clock fix that used to live at the top of it
   is step 1, which is what lets that fix reach the apps VM too. Infra VM only.
3. `scripts/init-unattended-upgrades.sh` — the second script meant for **both**
   VMs. Writes `/etc/apt/apt.conf.d/20auto-upgrades` plus a `52homelab-…`
   drop-in numbered above the distro's `50unattended-upgrades` so it wins, and
   enables `apt-daily{,-upgrade}.timer`. Two deliberate choices: the origins are
   **security-only** — the `#clear` directives in the drop-in are apt-config
   syntax, not comments, and without them a second `Origins-Pattern` block
   would *append* to the distro default instead of replacing it, silently
   voiding that promise — and Docker's repo (`origin=Docker`) is excluded, so
   no unattended `docker-ce` upgrade ever restarts the daemon under the lab.
   Reboots at 04:30 when needed, `WithUsers` included (a forgotten SSH session
   must not defer kernel patches); `AUTO_REBOOT=false` / `AUTO_REBOOT_TIME=`
   override per run. Order relative to `init-docker.sh` is free (it touches
   nothing Docker owns); order relative to `init-host.sh` is not — apt does
   TLS, so it wants the clock fix first.
4. `scripts/init-traefik.sh` — creates the `proxy` network + ACME dir, seeds
   `.env` from `.env.example`. The entrypoint-level `tls.domains` makes
   Traefik request the wildcard cert at startup — no router needed.
5. `scripts/init-authentik.sh` — creates `/opt/authentik`, generates secrets
   into `.env`. Authentik is the first *routed* stack and must run before the
   forward-auth-gated routers (Dockge, Traefik dashboard) can load.
6. `scripts/init-dockge.sh` — copies the compose to `/opt/stacks/dockge`,
   records `REPO_DIR` in `.env` (the compose bind-mounts the repo checkout at
   an identical path so stack symlinks resolve inside the container), and — the
   **only** init script that does — **starts the stack itself**, so its guide
   has no `docker compose` step. Sits right after Authentik on purpose:
   publishing a port for an earlier bootstrap view was considered and rejected
   (it would leave an un-gated LAN path), so Dockge is unreachable until both
   Traefik and Authentik run. From here on the remaining stacks can be driven
   from the web UI.
7. `scripts/init-forgejo.sh` — creates `/opt/forgejo` data tree, seeds `.env`
   (generates `FORGEJO_DB_PASSWORD`, records `DOCKER_GID`), symlinks the stack
   into `/opt/stacks`.
8. `scripts/init-monitoring.sh` — creates `/opt/monitoring`, chowns each data
   dir to the UID its image runs as (grafana 472, prometheus 65534, loki and
   tempo 10001; alloy is root), generates `GRAFANA_DB_PASSWORD` +
   `GRAFANA_ADMIN_PASSWORD`, symlinks the stack. Comes after Authentik because
   Grafana's OIDC needs a provider — but the stack starts fine before SSO is
   wired (`GRAFANA_OIDC_ENABLED=false`), which is how it's meant to be
   verified first.
9. `scripts/init-uptime-kuma.sh` — creates `/opt/uptime-kuma`, symlinks the
   stack. The **shortest** init script in the repo and the only stack with **no
   `.env` and no `.env.example`**: Kuma has no database and creates its admin
   through its own first-run web form, so there is nothing to seed. No `chown`
   either — the default image runs as root, like Alloy. Last on purpose; it
   watches everything above it.

All init scripts are **idempotent-ish and re-runnable**, use `set -euo pipefail`,
resolve paths from `$BASH_SOURCE` (run from anywhere), and share a `run_root()`
helper (direct if already root, else `sudo`). Match that style in new scripts.

Persistent state convention: each stack bind-mounts its data under `/opt/<stack>`
(e.g. `/opt/forgejo`, `/opt/traefik/letsencrypt`), and stacks are exposed to
Dockge by symlinking `infra/<stack>` into `/opt/stacks/<stack>` — the repo stays
the single source of truth; Dockge only drives start/stop/logs.

## Conventions & gotchas that aren't obvious from a single file

- **Image pins are major-only** (`traefik:v3`, `dockge:1`, `postgres:16-alpine`,
  `forgejo:11`) — a deliberate policy; keep it when bumping. Four exceptions,
  each for a different reason: Authentik is pinned **major.minor** (`2025.6`)
  because its minor releases ship breaking DB migrations; `grafana/grafana` is
  pinned **major.minor** (`13.1`) because no bare-major tag is published;
  `grafana/alloy` (`v1.18.0`) and `grafana/tempo` (`2.9.4`) are pinned to a
  **full patch** because each publishes only `vX.Y.Z` / `X.Y.Z` tags. Verify
  against the registry before assuming a coarser tag exists.
- **`.env` is gitignored**; every stack ships a `.env.example`. Secrets
  (netcup creds, `DOCKER_GID`) live only in the VM's `.env`. Compose uses
  `${VAR:?message}` to fail fast when one is missing — preserve those guards.
- **netcup DNS-01 is finicky.** Propagation is slow (~10 min), so
  `NETCUP_PROPAGATION_TIMEOUT` is 900s and propagation is checked against
  netcup's **authoritative** nameservers (not 1.1.1.1/8.8.8.8, which
  negative-cache the empty answer). The wildcard has **no apex SAN** on purpose
  (two TXT records at the same `_acme-challenge` FQDN race on netcup's
  non-atomic zone updates). Don't "simplify" these away.
- **First TLS bring-up goes straight to the production CA** — one challenge
  total. The staging CA stays available as a commented `caserver` line in
  `infra/traefik/compose.yaml` purely for debugging failed issuance under
  loose rate limits; switching CAs either way means deleting `acme.json` and
  force-recreating.
- **Mounted `docker.sock` is root-equivalent** and used deliberately by Dockge,
  the Forgejo runner, Traefik (read-only there), Alloy (container discovery
  + log tailing) and Uptime Kuma (container-state monitors — it is what lets
  Kuma report on stacks it shares no network with, which is why adding it
  changed no other stack's networks). `:ro` is **not** a security boundary for
  a socket — the mount
  is read-only, the API behind it is not. Alloy additionally bind-mounts the
  host's `/proc`, `/sys` and `/` read-only for host metrics; that widens what
  it can *see* but does not move the trust boundary the socket already crossed.
  Acceptable only because this is a single-tenant box building the owner's own
  code — never extend this to untrusted/fork code.
- **The Proxmox host is a scrape target — the only one that isn't a
  container.** It runs Debian's `prometheus-node-exporter` as a systemd unit
  (`apt install`, documented in `grafana-setup.md` step 6; **no init script**,
  because the hypervisor has no checkout of this repo), and Alloy scrapes it at
  `pve.thefipster.de:9100`. Both hosts carry `job="node"` and are told apart by
  `instance` (`infra`, `pve`) — that shared job label is what puts them both on
  the vendored Node Exporter Full dashboard with no edit to its JSON. It is
  also why `dns-records.md` no longer marks that record optional: without the
  exact record the `*.thefipster.de` wildcard answers with the apps VM and
  Alloy silently scrapes the wrong box, which looks exactly like a dead
  exporter.
- **CI is manual-only.** GitHub is primary and Forgejo pull-mirrors it, so
  `on: push` does not fire — the workflow's only trigger is
  `workflow_dispatch`, and every manual run builds and pushes (see
  `infra/forgejo/build-and-push.yml`, which is a template that lives in the
  *app* repo at `.forgejo/workflows/`, not on the infra VM).
- **Line endings:** `.gitattributes` forces LF repo-wide, and `*.sh` **must**
  stay LF even on Windows (CRLF breaks shebangs). Don't let an editor rewrite
  them to CRLF.

## Docs layout

`docs/` holds the reproduction guides, one per build-order step:
`proxmox-setup.md` → `wildcard-dns-udr.md` → `traefik-setup.md` →
`authentik-setup.md` → `dockge-setup.md` → `forgejo-setup.md` →
`grafana-setup.md` → `uptime-kuma-setup.md`. The README's "Build order" links
them in sequence and each
guide ends by linking the next. `grafana-setup.md` owns **all** of monitoring —
the platform *and* what it observes; an earlier split into a second
`monitoring-setup.md` was merged away because, on a fresh checkout, the second
guide was pure verification.

Two **registries** centralize the manual operations that live outside the repo:
`dns-records.md` (every UDR DNS record) and `sso-applications.md` (every
Authentik application and its exact config values). Guides link the registries
instead of duplicating the lists — a new hostname or SSO app gets its registry
row first, and per-service values should never be repeated inline in a guide.

**Every guide follows the same structure**, in this order: headline;
one-line prerequisite linking the previous guide (never a restatement of it);
short explanation of the stack; numbered steps with verification, **each
command in its own fenced block**; jump-off to the next guide;
troubleshooting; layout on the server; detailed explanation / design notes;
jump-off repeated. Doing-path first and short, all rationale below the fold.

**Guides describe a from-scratch bring-up of the current checkout — always.**
No migration paths, no upgrade branches, no phase history (the roadmap and the
dated specs keep that). A `git pull` anywhere but the initial clone is a red
flag. `docs/roadmap/` holds forward-looking plans (CI hardening) — decisions
for work not built yet; a piece graduates from roadmap to guide when it lands.
`docs/superpowers/{specs,plans}/` holds dated design specs and implementation
plans (`YYYY-MM-DD-*.md`), and `docs/review/` holds dated findings from
replaying the guides end to end. Those three are **historical records** — do
not retro-edit them when the guides change.

When the config and a guide disagree, the compose/script files are the source
of truth — update the guide to match.
