# Homepage — the lab's start page (infra VM)

**Runs on:** infra VM

**Prerequisite:** [uptime-kuma-setup.md](uptime-kuma-setup.md) complete —
Homepage links every stack above it and reads Kuma's status page, so it is built
after all of them.

[Homepage](https://github.com/gethomepage/homepage) is a static start page at
**`https://home.thefipster.de`**: every service in the lab in one place, with
live container state for this VM's stacks read from the Docker API, and plain
links for everything on the Proxmox host, the apps VM and the HA VM.

Its entire configuration is the git-tracked YAML in `infra/homepage/config`,
bind-mounted **read-only**. There is no database and no data directory on the
server. The one thing not in the checkout is `.env`, which holds a credential
per token-backed widget — those reach the config as `{{HOMEPAGE_VAR_*}}`
substitutions, so no secret is ever written into the repo.

It has **no login of its own**, which is why its router is gated by the
`authentik@docker` forward-auth middleware, exactly like Dockge and the Traefik
dashboard.

## Steps

### 1. Verify DNS

`home.thefipster.de` needs an exact host record pointing at the infra VM. The
registry is [dns-records.md](dns-records.md); the router how-to is
[wildcard-dns-udr.md](wildcard-dns-udr.md).

```bash
getent hosts home.thefipster.de
```

It must return the **infra** VM. Without an exact record the name falls through
the `*.thefipster.de` wildcard to the apps VM and you get Coolify's 404 behind a
perfectly valid certificate.

### 2. Create the Authentik provider and application

Homepage is gated before it is ever reachable, so this comes first. Follow the
same click-path as the Traefik dashboard
([authentik-setup.md, step 3](authentik-setup.md#3-gate-the-traefik-dashboard-forward-auth)) —
provider type **Proxy Provider**, mode **Forward auth (single application)** —
with the values from
[sso-applications.md](sso-applications.md#forward-auth-dockge-traefik-dashboard--homepage).

Attach the provider to the **authentik Embedded Outpost**. The Traefik side is
already in the repo: `infra/authentik/compose.yaml` carries the
`ak-outpost-homepage` router, and `infra/homepage/compose.yaml` carries the
`middlewares: authentik@docker` label.

### 3. Run the init script

```bash
scripts/init-homepage.sh
```

It ensures the `proxy` network exists, seeds `.env` from `.env.example`, and
symlinks the stack into `/opt/stacks/homepage`. There is no data directory to
create.

### 4. Mint the widget credentials

The init script left `.env` full of `changeme` placeholders, and the stack will
**refuse to start** until they are real — every value carries a `${VAR:?}` guard.
That is deliberate: a half-configured start page should not load.

Four values, minted in three different services. The click-path for each one,
with the exact scopes and permissions, is
[homepage-widgets.md](homepage-widgets.md) — it is not repeated here, the same
way DNS records and SSO applications are not repeated in the guides that need
them.

One thing worth knowing before you start clicking: the Grafana value is a
**login**, not a token — that widget offers basic auth only. Create a dedicated
Grafana user with the **Viewer** role rather than reusing the admin account,
which belongs to the monitoring stack.

```bash
nano ~/home-lab/infra/homepage/.env
```

### 5. Start the stack

```bash
cd ~/home-lab/infra/homepage && docker compose up -d
```

Confirm it came up rather than exiting:

```bash
docker compose ps
```

The `homepage` service must show **running**, not `Exited (1)`. A one-second
exit is almost always a missing config file — see
[Troubleshooting](#troubleshooting).

### 6. Log in and check the page

Open **https://home.thefipster.de**. Authentik intercepts, you log in, and the
page loads. Verify four things, in this order:

1. **Tiles render** for every group.
2. **Container state** shows under the infra-VM services — Traefik, Authentik,
   Vaultwarden, Dockge, Grafana, Uptime Kuma, Forgejo. A grey tile means the
   container name in `services.yaml` does not match a running container.
3. **The Uptime Kuma widget** on the Kuma tile shows up/down counts. Blank means
   the `homelab` status page is missing or renamed.
4. **The Authentik, Forgejo and Grafana tiles show figures**, not just a status
   dot — user counts, repository counts, dashboard counts. A tile with a dot but
   no numbers means that widget's credential is wrong or its account is missing
   a permission; each widget authenticates separately, so the others are
   unaffected. What each one needs is in
   [homepage-widgets.md](homepage-widgets.md).

Check the container names against the daemon rather than trusting the file:

```bash
docker ps --format '{{.Names}}' | sort
```

### 7. Add the Kuma monitor

One monitor, from [uptime-kuma-monitors.md](uptime-kuma-monitors.md#start-page--homepage):
type **Docker**, target `homepage-homepage-1`. There is deliberately no HTTP
monitor — the route is forward-auth gated and answers 302, which would report
Authentik's health rather than Homepage's.

### Checklist

- [ ] `getent hosts home.thefipster.de` returns the infra VM
- [ ] Authentik provider `homepage-forwardauth` exists and is attached to the
      embedded outpost
- [ ] `scripts/init-homepage.sh` ran clean and `/opt/stacks/homepage` is a symlink
- [ ] `infra/homepage/.env` holds four real values, no `changeme` left
- [ ] `docker compose up -d` starts the stack — a guard failure means a value is
      still empty
- [ ] `docker compose ps` shows `homepage` running, not exited
- [ ] The page loads at `https://home.thefipster.de` after an Authentik login
- [ ] Every infra-VM tile shows container state
- [ ] The Uptime Kuma widget shows counts, not a blank
- [ ] The Authentik, Forgejo and Grafana tiles show figures, not just a dot
- [ ] The `Start Page` Docker monitor is green in Kuma

## Next

**[backup-setup.md](backup-setup.md)** — the last step on the infra VM:
file-level `restic` backups, one snapshot per stack. Homepage's is the `.env`
you just filled in, and [Design notes](#design-notes) says why that is all of
it. The full sequence is the [README build order](../README.md#build-order).

## Troubleshooting

**The container exits immediately with `Failed to initialize required config`.**
A file is missing from `infra/homepage/config`. Under the read-only mount
Homepage cannot copy its skeleton in, and it calls `process.exit(1)` rather than
carrying on. Every file it looks for must be present:

```bash
ls -1 infra/homepage/config
```

Expected: `bookmarks.yaml custom.css custom.js docker.yaml kubernetes.yaml
proxmox.yaml services.yaml settings.yaml widgets.yaml`.

**The stack refuses to start and compose names a `HOMEPAGE_VAR_*` variable.**
That is the guard working: the value is missing from `.env` or is still
`changeme`. Mint it per [homepage-widgets.md](homepage-widgets.md) — the message
names which one.

**One tile shows a dot but no figures.** That widget's credential is wrong,
expired, or its account lacks a permission. Each widget authenticates
separately, so the rest of the page is unaffected — which is also why this
does not show up as a stack failure.

```bash
docker compose logs homepage | grep -i -E "widget|401|403"
```

**The container exits with a YAML parse error naming `services.yaml`.** A
`{{HOMEPAGE_VAR_...}}` placeholder lost its quotes. A bare `{` opens a flow
mapping in YAML, so the file stops being parseable — write
`key: "{{HOMEPAGE_VAR_FORGEJO_KEY}}"`, quotes included.

**Every page load returns 400.** `HOMEPAGE_ALLOWED_HOSTS` does not match the
`Host` header Traefik forwards. It is set in `compose.yaml` and must be exactly
`home.thefipster.de`, no scheme and no port.

**Traefik logs `middleware "authentik@docker" does not exist`.** Authentik is
down or was recreated after Homepage. Bring Authentik up; if you need the page
during an Authentik outage, comment the `middlewares` label and
`docker compose up -d`. Uncomment it afterwards.

**The page loads but every tile is grey.** The socket mount is missing or the
`server: infra` key in `services.yaml` does not match the key in `docker.yaml`.

```bash
docker compose exec homepage ls -l /var/run/docker.sock
```

**A single tile is grey.** That container's name changed. Compare
`services.yaml` against `docker ps --format '{{.Names}}'`, and fix
[uptime-kuma-monitors.md](uptime-kuma-monitors.md) at the same time — the two
files hold the same names on purpose.

**The Uptime Kuma widget is blank.** The `homelab` status page is gone, renamed,
or no longer public. Recreate it in Kuma with that exact slug; the registry row
is [The `homelab` status page](uptime-kuma-monitors.md#the-homelab-status-page).

## Layout on the server

```
~/home-lab/infra/homepage/
  compose.yaml
  .env.example       the widget credentials, with changeme placeholders
  .env               the real ones — gitignored, and the whole of the backup
  config/            bind-mounted read-only at /app/config
    settings.yaml    title, group order and layout
    docker.yaml      the `infra` socket entry
    services.yaml    the groups, container names and every widget
    widgets.yaml     deliberately empty
    bookmarks.yaml   links with no service behind them
    kubernetes.yaml  stub
    proxmox.yaml     stub
    custom.css       empty
    custom.js        empty

/opt/stacks/homepage -> ~/home-lab/infra/homepage    (symlink, for Dockge)
```

**There is no `/opt/homepage`.** Every other stack has one; this one has no
persistent state to put there.

## Design notes

**Why the infra VM.** The apps VM is the other plausible home, and it would have
been cheaper by one DNS record. It loses on the socket: Homepage's container
integration reads a Docker API, and the daemon with the lab's stacks on it is
this one. Coolify owns the apps VM's daemon, its container names are generated,
and it cannot see this machine at all. The second argument is the gate — Homepage
ships no authentication, and the forward-auth middleware exists only on this VM's
Traefik. The full comparison is in
[the design spec](superpowers/specs/2026-08-08-homepage-design.md).

**Why the config mount is read-only, and what it costs.** `:ro` is what keeps
the checkout the source of truth — the same arrangement as Traefik's `dynamic/`
directory and Forgejo's `config.yml`. It costs two things. Homepage's default
logfile lives inside the config directory, so `LOG_TARGETS: stdout` is required
rather than tidy — and that is what puts the logs in Loki, since Alloy tails
this VM's socket. And every file Homepage looks for must already exist, because
its fallback is to copy a skeleton in and exit when it cannot. Several of the
files are stubs for exactly that reason.

**Which services have a widget, and which do not.** Authentik, Forgejo and
Grafana carry live figures; everything else on the page is a link with container
state under it. Those three are why this stack has an `.env` at all, and
therefore why it has a backup: a credential is the only thing here that a fresh
checkout does not already provide.

The services with no widget are not an oversight, and each has its own reason:
Proxmox's API is HTTPS-only behind a self-signed certificate, the Traefik
dashboard is forward-auth gated so a widget would report on Authentik instead,
upstream ships no widget at all for Vaultwarden, Dockge or Coolify, and Home
Assistant and the apps-VM applications are on machines that are not built. The
reasoning lives in [homepage-widgets.md](homepage-widgets.md) rather than here,
beside the credentials for the ones that do work.

**Why the observability containers are not on the page.** Prometheus, Loki,
Tempo and Alloy have no routed UI, so a tile for them would be a status dot with
nowhere to click. Kuma already watches all four by container and Grafana is where
you go to read them. This is a deliberate omission, not an oversight.

**What its backup contains.** The `.env`, and nothing else. Every other byte
this stack owns is in git — the compose and the whole `config/` tree — so
snapshotting any of it would be snapshotting a checkout. That makes
`infra/homepage/backup.sh` a single `include_env` with no dump, and it is the
reason the restore has one meaningful check: whether the widget tiles show
figures again. Everything else about the page comes back from the checkout
whether the restore worked or not. See
[roadmap/backup.md](roadmap/backup.md).

**Why it is gated when Kuma is not.** Both are UIs with no OIDC, so the
convention points both at forward-auth, and Kuma is a stated exception because
gating the outage dashboard makes an Authentik outage the one failure you cannot
see. Homepage has no such claim: it is a page of links whose targets can be typed
by hand. Gating it is the default, and the exception list stays at three.

**The page can rot silently.** Container names in `services.yaml` are derived
from compose project and service names, so renaming a stack leaves a permanently
grey tile and nothing goes red. The same names live in
[uptime-kuma-monitors.md](uptime-kuma-monitors.md); change them together.

## Next

**[backup-setup.md](backup-setup.md)** — file-level `restic` backups, one
snapshot per stack, onto the hypervisor's `filebackup` pool. The full sequence is the
[README build order](../README.md#build-order).
