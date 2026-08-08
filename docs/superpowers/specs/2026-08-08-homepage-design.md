# Homepage — the lab's start page

**Date:** 2026-08-08
**Status:** Approved design, pending implementation plan
**Builds on:** Uptime Kuma, deployed and verified on the infra VM —
[docs/uptime-kuma-setup.md](../../uptime-kuma-setup.md).

## Goal

Add [gethomepage/homepage](https://github.com/gethomepage/homepage) to the
**infra VM** as an ordinary stack, `infra/homepage/`, routed at
`home.thefipster.de` and gated by Authentik forward-auth.

It is the lab's single start page: every service in one place, with live
container state for the infra VM's stacks and plain links for everything on the
other machines. One instance serves both audiences — daily use and operator
console — because the lab has one user.

## Why the infra VM and not the apps VM

The apps VM is the other plausible home: it runs third-party software already
([apps/services.md](../../../apps/services.md)), and a service there rides the
`*.thefipster.de` wildcard so it needs no DNS record at all. Four things decide
against it.

1. **The Docker socket it needs is on the infra VM.** Homepage's container
   integration reads a socket, and the daemon with the lab's stacks on it is the
   infra VM's. The apps VM's daemon belongs to Coolify — generated container
   names, and no view of the infra VM whatsoever. This is the same asymmetry the
   repo records twice already: Alloy tails the infra VM's socket, so nothing on
   the apps VM reaches Loki; and Kuma's container monitors "cannot see this
   machine's daemon at all".
2. **Homepage ships no authentication of any kind.** That is exactly the profile
   the forward-auth convention exists for — a plain web UI with no SSO, like
   Dockge and the Traefik dashboard. The `authentik@docker` middleware and its
   per-host outpost routers are labels on the Authentik `server` container, on
   the infra VM's Traefik. Behind Coolify's proxy there is no gate to reach for,
   and building one would mean re-implementing the pattern on a second proxy.
3. **Its entire configuration is YAML files.** That is the `infra/` model
   exactly — the repo is the source of truth and the stack bind-mounts it, the
   same arrangement as Traefik's `dynamic/` and Forgejo's `config.yml`. The apps
   VM's rule is deliberately the opposite: one Forgejo repo per application, and
   Coolify owns the running configuration. That rule fits an application with a
   database and OIDC, not a config-file dashboard.
4. **Category.** `apps/services.md` catalogs applications you *use*. Homepage is
   a navigation surface over the lab itself, which puts it in Dockge's and
   Kuma's neighbourhood.

The cost is one exact DNS record where the apps VM would have given the wildcard
for free. That is the same cost `git.` and `dockge.` already pay.

What it gives up by living on the infra VM is a container-level view of the apps
VM. Covered anyway: everything there is reachable as an HTTP link by name, and
nothing on this page depends on seeing Coolify's containers.

## Constraints & decisions made

- **Forward-auth, not a fourth stated exception.** Homepage has no login of its
  own, so the convention points at the `authentik@docker` middleware, exactly as
  for Dockge and the Traefik dashboard. The three existing exceptions
  (Vaultwarden, Uptime Kuma, Home Assistant) are each recovery-critical —
  something about repairing the lab depends on them being reachable when
  Authentik is not. Homepage is not: it is a page of links whose targets can be
  typed by hand, and Kuma remains the un-gated outage dashboard. Break-glass is
  commenting one label, the same as Dockge.
- **Every widget is token-free.** Container state comes from the Docker socket,
  service health from Uptime Kuma's status page, host figures from the built-in
  resource widget. No API tokens for Forgejo, Grafana, Authentik, Traefik,
  Prometheus, Coolify or Home Assistant. This is what removes the `.env` from
  this stack entirely; those widgets can be added later, and doing so is what
  would introduce one.
- **The Kuma widget reads a status page, not an API.** Uptime Kuma has no full
  API, so Homepage's widget takes a `slug` and reads a **public status page**.
  `homelab` already exists at `https://uptime.thefipster.de/status/homelab`.
  That page is not currently recorded in
  [docs/uptime-kuma-monitors.md](../../uptime-kuma-monitors.md); this design adds
  the row, because a Kuma status page lives only in Kuma's SQLite and that
  registry is its only durable record — and it is now a dependency of this stack
  rather than a loose end.
- **`LOG_TARGETS: stdout` is load-bearing.** By default Homepage writes a
  logfile into `/app/config/logs`, which makes a read-only config mount fail.
  `:ro` is what keeps the checkout the source of truth, so logging moves to
  stdout. The side effect is desirable: Alloy already tails this VM's socket, so
  the logs land in Loki like every other infra container.
- **`HOMEPAGE_ALLOWED_HOSTS` is mandatory in v1.x.** It is not a secret and not
  machine-specific, so it lives inline in the compose as
  `home.thefipster.de` rather than becoming this stack's only `.env` value.
- **The image pin stays major-only.** `ghcr.io/gethomepage/homepage:v1` — a bare
  `v1` tag is published (verified against the registry; latest at time of
  writing is `v1.4.5`), so this needs none of the finer-grained exceptions Alloy,
  Tempo, Vaultwarden, Grafana and Authentik carry.
- **Groups are by purpose, not by machine.** Infrastructure & Identity /
  Monitoring / Development / Applications / Home. Daily use is "what am I
  reaching for", and Docker status attaches per service entry regardless of
  which group holds it, so nothing operational is lost by not grouping by box.

## Shape

### Two absences, both firsts

- **No `.env` and no `.env.example`.** The second stack in the repo with none,
  after Uptime Kuma. Consequence of every widget being token-free.
- **No `/opt/homepage`.** The **first** stack in the repo with no persistent data
  directory at all. Homepage's entire state is git-tracked YAML, so there is
  nothing for a bind mount to hold. This makes `scripts/init-homepage.sh` the
  thinnest init script here: ensure the `proxy` network exists, symlink the
  stack into `/opt/stacks`, stop.

### Compose

```yaml
name: homepage

services:
  homepage:
    image: ghcr.io/gethomepage/homepage:v1
    restart: unless-stopped
    environment:
      HOMEPAGE_ALLOWED_HOSTS: home.thefipster.de
      LOG_TARGETS: stdout
    volumes:
      - ./config:/app/config:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      traefik.enable: "true"
      traefik.http.routers.homepage.rule: Host(`home.thefipster.de`)
      traefik.http.routers.homepage.entrypoints: websecure
      traefik.http.services.homepage.loadbalancer.server.port: "3000"
      traefik.http.routers.homepage.middlewares: authentik@docker
    networks:
      - proxy

networks:
  proxy:
    external: true
```

`proxy` only. The Kuma widget reaches
`http://uptime-kuma:3001` container-to-container on that network — no TLS hop,
no round trip through Traefik. Everything else on the page is a link.

The socket mount makes Homepage the **sixth** socket consumer in the lab, after
Dockge, the Forgejo runner, Traefik, Alloy and Uptime Kuma. Its compose header
carries the same caveat the others do: `:ro` makes the mount read-only, not the
API behind it, and this is root-equivalent control of the VM's Docker —
acceptable only because the box is single-tenant.

### Config

Nine files in `infra/homepage/config/`, all git-tracked, all bind-mounted
read-only — upstream's full skeleton set, because a missing file under a
read-only mount makes Homepage exit rather than warn:

| File | Holds |
|---|---|
| `settings.yaml` | title, theme, group layout |
| `docker.yaml` | the socket declaration the service entries reference |
| `services.yaml` | the five purpose groups, each entry with its href and (for infra VM stacks) its container |
| `widgets.yaml` | deliberately empty — the Kuma widget is a *service* widget and lives in `services.yaml`; the `resources` widget would report the container's figures, not the VM's |
| `bookmarks.yaml` | links with no service behind them |
| `kubernetes.yaml`, `proxmox.yaml`, `custom.css`, `custom.js` | unused stubs. A missing file under the read-only mount makes Homepage `process.exit(1)`, so all nine of upstream's skeleton files must be present |

## Build order

Homepage lands **after Uptime Kuma and before backup**, becoming step 11 and
pushing backup and the apps VM steps down by one.

This requires one wording change elsewhere. Uptime Kuma is currently documented
as the "**last stack** on purpose; it watches everything above it". That becomes
*last monitored stack*: Homepage comes after it precisely because it references
every stack above it, and nothing references Homepage.

## Backup

**No `backup.sh`, deliberately** — recorded as a stated absence in
[docs/roadmap/backup.md](../../roadmap/backup.md) rather than left to be noticed.

Every byte this stack owns is in git: the compose, the five config files, and no
`.env`. A restic snapshot of it would be a snapshot of a checkout. It is the
first stack in the repo where that is true, which means CLAUDE.md's "Every stack
is wired" sentence needs the exception named in place.

## The three registries

| Registry | Row |
|---|---|
| [dns-records.md](../../dns-records.md) | `home.thefipster.de` → `infra ip`. An exact record, like `git.` and `dockge.` — the name wants the infra VM, which the wildcard would not deliver. |
| [sso-applications.md](../../sso-applications.md) | A third member of the forward-auth section, beside Dockge and the Traefik dashboard. `infra/authentik/compose.yaml` gains a pair of `ak-outpost-homepage` router labels matching the Homepage host plus the `/outpost.goauthentik.io/` path prefix, exactly as it already does for `dockge` and `traefik`. |
| [uptime-kuma-monitors.md](../../uptime-kuma-monitors.md) | **One** monitor: Docker → `homepage-homepage-1`. **No Web monitor** — forward-auth gated, the same 302 reasoning the registry already applies to Dockge and the Gateway. Plus a row recording the existing `homelab` status page. |

## Files touched

**New**

- `infra/homepage/compose.yaml`
- `infra/homepage/config/{settings,docker,services,widgets,bookmarks}.yaml`
- `scripts/init-homepage.sh` — committed mode `100755`
- `docs/homepage-setup.md`

**Edited**

- `infra/authentik/compose.yaml` — `ak-outpost-homepage` routers
- `scripts/init-uptime-kuma.sh` — it claims Kuma is "the only stack with no `.env`"
- `README.md` — build order
- `CLAUDE.md` — build order, the socket-consumer list, the no-`.env` note, the
  "every stack is wired" exception
- `docs/dns-records.md`, `docs/sso-applications.md`,
  `docs/uptime-kuma-monitors.md`, `docs/roadmap/backup.md`
- `docs/uptime-kuma-setup.md` — jump-off to the new guide
- `docs/backup-setup.md` — prerequisite link now points at Homepage

## Out of scope

- **Token-backed widgets** for Forgejo, Grafana, Authentik, Traefik, Prometheus,
  Coolify and Home Assistant. Each needs a token minted by hand, and together
  they would give this stack an `.env`, an `.env.example` and a backup
  obligation it currently does not have. The token-free page is the one to live
  with first; adding a widget later is an additive change.
- **The weather / search / greeting widgets.** Weather wants an API key and a
  location; search wants a decision about which engine. Neither earns its place
  on a single-user start page yet.
- **A second instance for a household audience.** One user, one page.
- **Anything on the apps VM.** Coolify's applications appear here as links.
  Giving them live state would mean either exposing that daemon's socket across
  machines or minting a Coolify API token — both are the out-of-scope item
  above, and neither is worth it for four applications.
- **Replacing Dockge or Kuma.** Homepage links to them and shows container
  state; it starts nothing, notifies no one, and is not a fallback for either.
