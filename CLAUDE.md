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

One hypervisor and three VMs on a single flat `/24` LAN behind a UniFi Dream
Router. **The repo root is the machine map** — one directory per VM — while
`docs/` and `scripts/` stay flat, because their filenames already carry the
service name and nesting them would add a `../` to every cross-guide link:

- **Proxmox host** — hypervisor only, no Docker. A bad container can't
  take the box down.
- **infra VM** — Traefik + Authentik + Forgejo + Dockge + monitoring
  (the stacks in `infra/`). The only machine whose services this repo declares.
- **apps VM** — Coolify (self-hosted PaaS). Coolify owns its own Docker
  and manages apps through its UI, so `apps/` holds **no compose file** — a
  README, a `.env.example` naming the `NETCUP_*` variables Coolify's own proxy
  needs, and `services.md`, a **catalog** of the third-party software this VM
  runs. Coolify never reads that `.env` and has **no credentials form**: the
  values are typed into the proxy's own compose in its UI (*Servers → Proxy →
  Configuration*), beside the flags that switch it off its default HTTP-01
  challenge — which cannot issue a wildcard at all. The file is the **recovery
  copy** for when Coolify regenerates that compose from its own store, not
  merely a record of what is required. App definitions live in Coolify's
  database, not this repo; the
  third-party compose files live in a Forgejo repo, so the catalog records what
  runs and why, never how. It deliberately adds no rows to the three `docs/`
  registries — those cover infra VM services, whose implementation is clickwork
  with no other home.
- **home-assistant VM** — Home Assistant OS, Supervisor included, so
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

**Never write a host IP address in this repo.** Addresses drift — they already
have; the running lab does not match the addresses the build plan assumed — and a
recorded address that has drifted reads as authoritative while being wrong.
Machines are addressed by **name** everywhere: Traefik's backends, Alloy's scrape
targets, every command in every guide. `dns-records.md` names hosts and refers to
them as `infra ip` / `apps ip` / `ha ip` / `pve ip`; the router is the source of
truth for addresses, that registry for names.

A literal address is therefore a **flag** — something that could not be expressed
as a name. There is one legitimate case: `trusted_proxies` in
`home-assistant/configuration.yaml`, which HA validates as an address or CIDR and
will not accept as a hostname. It ships as the placeholder `<infra-vm-ip>` and is
filled in on the machine, derived from
`getent hosts ha.thefipster.de` rather than read off the router. Install-time
addresses in `proxmox-setup.md` (the Proxmox installer wants a static IP typed in)
and HA's pre-DNS onboarding URL are the remaining irreducible ones. Anything else
should be a name.

Three DNS facts are counter-intuitive and all are deliberate:

- **`ha.` points at the infra VM**, not the HA VM, because Traefik
  terminates TLS there.
- **Home Assistant therefore has a second name**,
  `homeassistant.thefipster.de` → the HA VM, which is what Traefik dials. `ha.` is the
  **service**, `homeassistant.` is the **machine**; they are not interchangeable,
  and a backend of `http://ha.thefipster.de:8123` would have Traefik dialling its
  own `:8123` and 502-ing every request. Same service/machine split as
  `pve.` and `apps.`, which name boxes for internal access.
- **`coolify.` and `apps.` have no exact record at all**, because the wildcard
  already reaches the apps VM — the machine both names want.

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

The first three are **host** scripts, not stack scripts, and the split between
them is deliberate: only the middle one is about Docker, so only it is
infra-VM-only. The apps VM runs the other two (it gets its Docker from
Coolify's installer). Those two runs have a guide each —
`docs/infra-vm-setup.md` and `docs/apps-vm-setup.md` — rather than one shared
section, for the reasons under [Docs layout](#docs-layout).

1. `scripts/init-host.sh` — machine-level basics with no Docker in them: the
   time-sync daemon's step policy (chrony `makestep 1 -1`, or a tighter
   `PollIntervalMaxSec` for systemd-timesyncd), then `qemu-guest-agent`. A
   Proxmox snapshot rollback resumes the guest with a stale clock, and chrony's
   default `makestep 1 3` would only ever slew it back — every TLS client then
   fails with "certificate has expired or is not yet valid"; the clock comes
   first inside the script too, because installing the agent already means apt.
   The guest agent is the guest half of the wizard's "Qemu Agent" tick (IP on
   the summary page, clean shutdown) and lives here rather than as a manual
   step in the guide, which is where it used to be. **First on both VMs**,
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
   stack. The only stack with **no `.env` and no `.env.example`**: Kuma has no
   database and creates its admin through its own first-run web form, so there
   is nothing to seed. No `chown`
   either — the default image runs as root, like Alloy. Last on purpose; it
   watches everything above it.

That sequence is the **infra VM**. The other two machines follow it, and the
build order in the README is grouped by machine for exactly this reason:

10. `scripts/init-coolify.sh` on the **apps VM** — preflight (Debian family,
   30 GB free, and Docker Engine ≥ 24 **only if an Engine is already there**),
   a swapfile if none is active, then Coolify's
   official installer **fetched to a temp file with its source URL and sha256
   printed** before running as root — deliberately not `curl | sudo bash`, which
   is the documented upstream method. Seeds `apps/.env`. The only init script that
   installs a whole platform instead of preparing a compose stack, and the only
   one whose result this repo does not describe. Its Docker check is a
   **soft** one on purpose, unlike every other script's hard `command -v docker`
   gate: the apps VM skips `init-docker.sh`, so on a first run there is no
   Engine yet and the installer is what provides it. Making that gate hard
   deadlocks the only machine that needs the script.
11. `scripts/init-node-exporter.sh` — machine-agnostic, but the **apps VM is its
   only caller**. Explicitly **not** folded into `init-host.sh`: that runs on the
   infra VM too, where Alloy's embedded `prometheus.exporter.unix` already
   collects host metrics, so a second exporter there would be a duplicate target.
   The Proxmox host wants one as well but has no checkout, so it stays a
   documented `apt install`.
12. The **home-assistant VM has no init script at all** — HAOS is an appliance.
    Its VM is created by hand (`qm importdisk`, OVMF, resize before first boot)
    per `docs/home-assistant-setup.md`.

`scripts/init-host.sh` and `scripts/init-unattended-upgrades.sh` run on **both**
Ubuntu VMs, not just infra — neither one touches Docker, which is the whole
point of the split. That is what removed the manual chrony drop-in
`proxmox-setup.md` used to hand you for the apps VM. `init-docker.sh` is the
only one of the three that stays infra-only.

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
  `forgejo:15`) — a deliberate policy; keep it when bumping. Four exceptions,
  each for a different reason: Authentik is pinned **major.minor** (`2026.5`)
  because its minor releases ship breaking DB migrations — upstream requires
  upgrades to step through **every** intermediate release, so a bump here is
  never routine and the pin is what keeps that decision explicit;
  `grafana/grafana` is
  pinned **major.minor** (`13.1`) because no bare-major tag is published;
  `grafana/alloy` (`v1.18.0`) and `grafana/tempo` (`2.9.4`) are pinned to a
  **full patch** because each publishes only `vX.Y.Z` / `X.Y.Z` tags. Verify
  against the registry before assuming a coarser tag exists.
- **Which major is a separate question from how coarse the pin is, and Forgejo
  answers it differently.** `forgejo:15` tracks the **LTS** major, not the
  latest stable one — Forgejo's non-LTS majors carry a ~3-month support window,
  the LTS a year, and this lab is bumped when someone sits down to bump it
  rather than on a release cadence. So the pinned number normally **lags** the
  newest release and is not stale; check https://forgejo.org/releases/ for which
  major is LTS before raising it. The Forgejo **runner** has no LTS track, so it
  follows the newest major (`runner:12`) — and it moves **with** the server:
  Forgejo 13 and runner 8 both began rejecting Actions workflows that fail a
  YAML schema check, so a pair straddling those versions disagrees about what a
  valid workflow is.
- **`.env` is gitignored**; every stack whose `.env` holds hand-filled values
  ships a `.env.example` (Dockge's `.env` is machine-generated by its init
  script, so it ships none; Uptime Kuma has no `.env` at all). Secrets
  (netcup creds, `DOCKER_GID`) live only in the VM's `.env`. Compose uses
  `${VAR:?message}` to fail fast when one is missing — preserve those guards.
  **Five values are deliberately `${VAR:-}` instead**, each with a comment in
  place: `HA_PROMETHEUS_TOKEN` in `infra/monitoring/compose.yaml` cannot be
  generated locally (it is minted in Home Assistant's UI) and is legitimately
  empty until the HA VM exists, so a fail-fast guard would stop the entire
  monitoring stack from starting during bring-up — empty means that one scrape
  target 401s; nothing else changes. The other four are optional by design:
  `AUTHENTIK_BOOTSTRAP_TOKEN` and the three `GRAFANA_OIDC_*` values, blank
  until their features are wired.
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
- **Whether the wildcard is a safety net or a trap depends only on which machine
  the name wants.** `pve.thefipster.de` needs an exact record because the wildcard
  would answer with the apps VM — the wrong box, presenting as a dead exporter.
  `apps.thefipster.de` needs **no record at all**, because the wildcard's answer
  *is* the apps VM; Alloy scrapes it at `:9100` by name and the registry lists it
  as a deliberate non-row. Same for `coolify.thefipster.de`. Don't "fix" either by
  adding an exact record: letting them follow the wildcard is what makes an
  apps-VM IP change correct itself everywhere at once.
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
  `workflow_dispatch` (see `infra/forgejo/build-and-push.yml`, which is a
  template that lives in the *app* repo at `.forgejo/workflows/`, not on the
  infra VM). It has **three jobs, one per toolchain** — `container:` is
  per-job, so Blazor, PlatformIO and Astro cannot share one — each gated by a
  default-on boolean dispatch input, because the runner is `capacity: 1` and
  an unticked job is wall-clock saved. Those `if:` guards compare against
  `true` **and** `'true'` on purpose: a `type: boolean` input can arrive as
  the string `"false"`, which is truthy, so a bare `if: inputs.x` would run
  the job anyway.
- **Two kinds of build output, two registries.** Images go to the container
  registry; the PlatformIO `.bin`s and the Astro `dist.tar.gz` go to **both**
  a run artifact (`forgejo/upload-artifact@v4` — the upstream v4 only speaks
  to GitHub's backend; expires, browsable from the run page) and the
  **generic package registry** (`PUT /api/packages/{owner}/generic/…` —
  permanent, same Packages tab as the images). One `REGISTRY_TOKEN` covers
  both registries; `write:package` is the only scope. Two gotchas the
  workflow already handles: generic packages are **owner-scoped**, hence the
  `verdure-` name prefix, and a PUT over an existing filename **409s**, so
  every publish deletes first — re-dispatching one commit is normal when
  dispatch is the only trigger. Nothing on the infra VM stores these
  specially: artifacts live under Forgejo's `APP_DATA_PATH`, already inside
  the `/opt/forgejo/forgejo` bind mount.
- **Line endings:** `.gitattributes` forces LF repo-wide, and `*.sh` **must**
  stay LF even on Windows (CRLF breaks shebangs). Don't let an editor rewrite
  them to CRLF.

## Docs layout

`docs/` holds the reproduction guides, one per build-order step:
`proxmox-setup.md` → `wildcard-dns-udr.md` → **`infra-vm-setup.md`** →
`traefik-setup.md` → `authentik-setup.md` → `dockge-setup.md` →
`forgejo-setup.md` → `grafana-setup.md` → `uptime-kuma-setup.md` →
**`apps-vm-setup.md`** → `coolify-setup.md` → `home-assistant-setup.md`.

**The two `*-vm-setup.md` guides are one section split in two, and the split is
load-bearing.** Both were a single `Part 7` inside `proxmox-setup.md`, which
made that guide the only one whose steps ran in a shell its `**Runs on:**` line
did not name — it says *the bare server, then the Proxmox host shell*, and Part 7
ran in two guests. It also provisioned the apps VM seven guides before anything
used it, which is what grew the duplicated Part 0 back into `coolify-setup.md`.
Each machine's section of the build order now opens with the guide that prepares
that machine. Do not fold them back in, and do not add a third: the Proxmox host
has no checkout, and the HA VM is an appliance. The README's "Build order" links them in sequence,
**grouped by machine** (lab foundation → infra VM → apps VM → home-assistant VM),
and each guide ends by linking the next. The last two guides leave the infra VM:
their `**Runs on:**` line is the quickest way to tell. `grafana-setup.md` owns **all** of monitoring —
the platform *and* what it observes; an earlier split into a second
`monitoring-setup.md` was merged away because, on a fresh checkout, the second
guide was pure verification.

Three **registries** centralize the manual operations that live outside the repo:
`dns-records.md` (every UDR DNS record), `sso-applications.md` (every Authentik
application and its exact config values) and `uptime-kuma-monitors.md` (every
Kuma monitor, grouped by stack). Guides link the registries instead of duplicating
the lists — a new hostname, SSO app or monitor gets its registry row first, and
per-service values should never be repeated inline in a guide.

All three carry `**Runs on:** … — registry, not a build step`, and all three list
their **deliberate absences** alongside their entries, because a registry that
only records what exists cannot tell you whether a gap was a decision. The
absences are load-bearing: `coolify.`/`apps.` have no DNS row, Kuma and Home
Assistant have no SSO entry, and Kuma does not monitor itself or the hypervisor.
When adding a service, decide about all three and say so in each.

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
