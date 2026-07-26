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

One hypervisor and three VMs on one LAN (`192.168.1.0/24`) behind a UniFi Dream
Router. **The repo root is the machine map** — one directory per VM — while
`docs/` and `scripts/` stay flat, because their filenames already carry the
service name and nesting them would add a `../` to every cross-guide link:

- **Proxmox host** (`.40`) — hypervisor only, no Docker. A bad container can't
  take the box down.
- **infra VM** (`.41`) — Traefik + Authentik + Forgejo + Dockge + monitoring
  (the stacks in `infra/`). The only machine whose services this repo declares.
- **apps VM** (`.42`) — Coolify (self-hosted PaaS). Coolify owns its own Docker
  and manages apps through its UI, so `apps/` holds **no compose file** — only a
  README and a `.env.example` naming the `NETCUP_*` variables Coolify's own proxy
  needs. App definitions live in Coolify's database, not this repo.
- **home-assistant VM** (`.43`) — Home Assistant OS, Supervisor included, so
  add-ons (ESPHome, Mosquitto) come from HA's store. An **appliance**: no compose,
  no init script, no `/opt/<stack>` data dir, and no shell of ours inside it. The
  repo cannot be its source of truth, so `home-assistant/` holds a README and a
  `configuration.yaml` **fragment you append by hand** (the
  `infra/forgejo/build-and-push.yml` precedent — a real file that lives elsewhere).

Only the infra VM is driven from this repo. For the other two the repo holds
guides and one config fragment each; treat their machine state as authoritative
over anything written here.

DNS is split-horizon: real subdomains of `thefipster.de` resolved locally by the
router; the public zone holds no A records. `git.` / `dockge.` → infra VM,
`*.thefipster.de` → apps VM. TLS everywhere is a genuine Let's Encrypt **wildcard**
issued via DNS-01 against the netcup API — nothing is exposed to the internet.

Two DNS entries are counter-intuitive and both are deliberate: **`ha.` points at
the infra VM** (`.41`), not the HA VM, because Traefik terminates TLS there and
proxies to `.43:8123`; and **`coolify.` has no exact record at all**, because the
wildcard already reaches the apps VM whose proxy routes by `Host` header.

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

**Traefik runs a second provider, and it has exactly one user.** Labels only
exist where there is a container to put them on, and Home Assistant runs on
another VM — so Traefik also watches a **file provider** over
`infra/traefik/dynamic/` (`--providers.file.directory` +
`--providers.file.watch`, bind-mounted read-only; the repo stays the source of
truth, same arrangement as Forgejo's `config.yml`). `dynamic/ha.yaml` is its only
file. Routers declared there are ordinary `websecure` routers, so the
no-per-router-TLS rule applies to them identically — the entrypoint wildcard
covers them too. **The label path remains the default:** reach for a file only
when the backend is not a container on the infra VM. Nothing in
`scripts/init-traefik.sh` changes for this — the directory lives inside the
checkout and is mounted, not copied.

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

**Two services join neither, deliberately.** Both have no OIDC, so the
convention would point at forward-auth for each; treat both as stated exceptions,
not gaps to close. The reasoning lives in `sso-applications.md`, and each absence
is commented in place so someone about to "fix" it reads why first.

- **Uptime Kuma.** Gating the outage dashboard behind the identity provider makes
  an Authentik outage the one failure you cannot see, and break-glass would need
  SSH mid-incident. `infra/uptime-kuma/compose.yaml` carries no `middlewares`
  label.
- **Home Assistant.** Forward-auth gates a browser login flow, but most traffic
  to HA is not a browser: the companion mobile app, webhooks and every local API
  caller authenticate with long-lived tokens against the same endpoints the
  frontend uses, and there is no clean split that admits them. Gating it breaks
  notifications, presence and inbound automations. Break-glass would mean editing
  Traefik config over SSH while the lights do not respond.
  `infra/traefik/dynamic/ha.yaml` carries no `middlewares` key.

`infra/authentik/compose.yaml` carries **no** `/outpost.goauthentik.io/` router
for either host, with a comment naming both and why.

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

1. `scripts/init-host.sh` — installs Docker Engine + compose plugin (Ubuntu),
   and **first** relaxes the time-sync daemon's step policy (chrony
   `makestep 1 -1`, or a tighter `PollIntervalMaxSec` for systemd-timesyncd).
   A Proxmox snapshot rollback resumes the guest with a stale clock, and
   chrony's default `makestep 1 3` would only ever slew it back — every TLS
   client then fails with "certificate has expired or is not yet valid". It
   runs before the Docker install because apt and curl need a sane clock too.
2. `scripts/init-traefik.sh` — creates the `proxy` network + ACME dir, seeds
   `.env` from `.env.example`. The entrypoint-level `tls.domains` makes
   Traefik request the wildcard cert at startup — no router needed.
3. `scripts/init-authentik.sh` — creates `/opt/authentik`, generates secrets
   into `.env`. Authentik is the first *routed* stack and must run before the
   forward-auth-gated routers (Dockge, Traefik dashboard) can load.
4. `scripts/init-dockge.sh` — copies the compose to `/opt/stacks/dockge`,
   records `REPO_DIR` in `.env` (the compose bind-mounts the repo checkout at
   an identical path so stack symlinks resolve inside the container), and — the
   **only** init script that does — **starts the stack itself**, so its guide
   has no `docker compose` step. Sits right after Authentik on purpose:
   publishing a port for an earlier bootstrap view was considered and rejected
   (it would leave an un-gated LAN path), so Dockge is unreachable until both
   Traefik and Authentik run. From here on the remaining stacks can be driven
   from the web UI.
5. `scripts/init-forgejo.sh` — creates `/opt/forgejo` data tree, seeds `.env`
   (generates `FORGEJO_DB_PASSWORD`, records `DOCKER_GID`), symlinks the stack
   into `/opt/stacks`.
6. `scripts/init-monitoring.sh` — creates `/opt/monitoring`, chowns each data
   dir to the UID its image runs as (grafana 472, prometheus 65534, loki and
   tempo 10001; alloy is root), generates `GRAFANA_DB_PASSWORD` +
   `GRAFANA_ADMIN_PASSWORD`, symlinks the stack. Comes after Authentik because
   Grafana's OIDC needs a provider — but the stack starts fine before SSO is
   wired (`GRAFANA_OIDC_ENABLED=false`), which is how it's meant to be
   verified first.
7. `scripts/init-uptime-kuma.sh` — creates `/opt/uptime-kuma`, symlinks the
   stack. The **shortest** init script in the repo and the only stack with **no
   `.env` and no `.env.example`**: Kuma has no database and creates its admin
   through its own first-run web form, so there is nothing to seed. No `chown`
   either — the default image runs as root, like Alloy. Last on purpose; it
   watches everything above it.

That sequence is the **infra VM**. The other two machines follow it, and the
build order in the README is grouped by machine for exactly this reason:

8. `scripts/init-coolify.sh` on the **apps VM** — preflight (Debian family,
   Docker Engine ≥ 24, 30 GB free), a swapfile if none is active, then Coolify's
   official installer **fetched to a temp file with its source URL and sha256
   printed** before running as root — deliberately not `curl | sudo bash`, which
   is the documented upstream method. Seeds `apps/.env`. The only init script that
   installs a whole platform instead of preparing a compose stack, and the only
   one whose result this repo does not describe.
9. `scripts/init-node-exporter.sh` — machine-agnostic, but the **apps VM is its
   only caller**. Explicitly **not** folded into `init-host.sh`: that runs on the
   infra VM too, where Alloy's embedded `prometheus.exporter.unix` already
   collects host metrics, so a second exporter there would be a duplicate target.
   The Proxmox host wants one as well but has no checkout, so it stays a
   documented `apt install`.
10. The **home-assistant VM has no init script at all** — HAOS is an appliance.
    Its VM is created by hand (`qm importdisk`, OVMF, resize before first boot)
    per `docs/home-assistant-setup.md`.

`scripts/init-host.sh` now runs on **both** Ubuntu VMs, not just infra. That is
what removed the manual chrony drop-in `proxmox-setup.md` used to hand you for
the apps VM — Coolify accepts a pre-existing Docker Engine, so there is no reason
to skip it there.

All init scripts are **idempotent-ish and re-runnable**, use `set -euo pipefail`,
resolve paths from `$BASH_SOURCE` (run from anywhere), and share a `run_root()`
helper (direct if already root, else `sudo`). Match that style in new scripts, and
**commit them mode `100755`** — a file created on Windows defaults to `100644` and
lands non-executable on the VM (`git update-index --chmod=+x`).

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
  **One deliberate exception:** `HA_PROMETHEUS_TOKEN` in
  `infra/monitoring/compose.yaml` uses `${VAR:-}`. It cannot be generated locally
  (it is minted in Home Assistant's UI) and is legitimately empty until the HA VM
  exists, so a fail-fast guard would stop the entire monitoring stack from
  starting during bring-up. Empty means that one scrape target 401s; nothing else
  changes.
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
- **Three scrape targets aren't containers.** The infra VM is covered by Alloy's
  embedded `prometheus.exporter.unix`; the **Proxmox host** and the **apps VM**
  each run Debian's `prometheus-node-exporter` as a systemd unit — the hypervisor
  by hand (`apt install`, `grafana-setup.md` step 6, **no init script** because it
  has no checkout of this repo), the apps VM via
  `scripts/init-node-exporter.sh`. All three carry `job="node"` and are told apart
  by `instance` (`infra`, `pve`, `apps`); that shared job label is what puts all
  of them on the vendored Node Exporter Full dashboard with no edit to its JSON.
  It is also why `dns-records.md` no longer marks the `pve` record optional:
  without the exact record the `*.thefipster.de` wildcard answers with the apps VM
  and Alloy silently scrapes the wrong box, which looks exactly like a dead
  exporter.
- **The apps VM is the one target addressed by IP** (`192.168.1.42:9100`), against
  the lab's name-not-address habit, and on purpose:
  `apps.thefipster.de` is **not a record**, so it would resolve only because the
  wildcard happens to point at that very VM. Relying on that would be adopting
  the exact accident the `pve` note above warns about.
- **Home Assistant is scraped differently from everything else** — over HTTPS
  through Traefik (`ha.thefipster.de:443`, `metrics_path = /api/prometheus`)
  rather than reached directly, so a broken route surfaces in monitoring instead
  of being bypassed; and with a credential, via an `authorization` block reading
  `sys.env("HA_PROMETHEUS_TOKEN")`. Its `job="homeassistant"` carries **entity**
  metrics (sensor states), *not* machine counters, so it does not and cannot
  appear on Node Exporter Full. HAOS can't run a node exporter as a systemd unit;
  HA's **System Monitor** integration is the closest equivalent and feeds the same
  endpoint.
- **`ServiceDown` is expected red for `apps` and `homeassistant`** on a fresh
  build: monitoring comes up on the infra VM before either machine exists. Left
  live rather than commented out, because `rules.yaml` provisions no contact point
  or notification policy — alerts are UI-only and send nothing outward.
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
`grafana-setup.md` → `uptime-kuma-setup.md` → `coolify-setup.md` →
`home-assistant-setup.md`. The README's "Build order" links them in sequence,
**grouped by machine** (lab foundation → infra VM → apps VM → home-assistant VM),
and each guide ends by linking the next. The last two guides leave the infra VM:
their `**Runs on:**` line is the quickest way to tell. `grafana-setup.md` owns **all** of monitoring —
the platform *and* what it observes; an earlier split into a second
`monitoring-setup.md` was merged away because, on a fresh checkout, the second
guide was pure verification.

Two **registries** centralize the manual operations that live outside the repo:
`dns-records.md` (every UDR DNS record) and `sso-applications.md` (every
Authentik application and its exact config values). Guides link the registries
instead of duplicating the lists — a new hostname or SSO app gets its registry
row first, and per-service values should never be repeated inline in a guide.

**Every guide follows the same structure**, in this order: headline; a
`**Runs on:** <machine>` line naming the machine whose shell you are in (the two
registries say `— registry, not a build step` instead, because they describe
manual operations that span machines);
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
