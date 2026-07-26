# Uptime Kuma — independent black-box monitoring

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan
**Builds on:** the monitoring stack (Grafana + Prometheus + Loki + Tempo +
Alloy), deployed and verified on the infra VM —
[docs/grafana-setup.md](../../grafana-setup.md).

## Goal

Add [Uptime Kuma](https://github.com/louislam/uptime-kuma) to the infra VM as a
**standalone stack**, `infra/uptime-kuma/`, routed at
`uptime.thefipster.de`. It becomes the lab's **notification layer**: the thing
that pokes you when something is down. Grafana stays the thing that explains
why.

It watches two classes of target — the routed services end-to-end through
Traefik, and every container's state through the Docker API — so nothing needs
to be exposed and no existing stack changes.

## Why standalone, not part of the monitoring stack

The two arguments, in order of weight:

1. **Fate-sharing defeats the purpose.** The monitoring stack is *white-box*
   and lives inside everything it watches: same VM, same Docker daemon,
   scraping internal `/metrics`. Kuma is *black-box*, and its value comes from
   being outside. In the same compose project, one `docker compose down` on
   monitoring takes out the pipeline **and** the thing that would have told you
   the pipeline went down.
2. **It fills a blind spot that stack documents about itself.**
   `infra/monitoring/grafana/provisioning/alerting/rules.yaml` records it: if
   Alloy dies, `up` goes stale, `ServiceDown` evaluates NoData → OK, and the
   most total failure never fires. An independent watcher is exactly the fix,
   and it is only independent if it is a separate stack.

The cohesion argument agrees. The monitoring stack is not a category ("things
that monitor") but a **pipeline** — Alloy collects, Prometheus/Loki/Tempo
store, Grafana displays — with one shared network, one datasource config, one
provisioning tree. Kuma is collector + store + UI + notifier in a single
container with its own SQLite, sharing none of that.

## Constraints & decisions made

- **Division of labor is explicit: Kuma notifies, Grafana diagnoses.** Grafana's
  three alert rules stay UI-only and unchanged — no contact point is wired
  there. Outbound notification is Kuma's job alone, so there is exactly one
  place to tune and no duplicate alerts. This is written into both the Kuma
  compose header and the guide, because the overlap is the obvious future
  mistake.
- **No SSO. Kuma keeps its own local login.** This is a **deliberate deviation**
  from the repo's "OIDC or forward-auth, never both" convention, and the first
  service to sit outside it. Kuma has no OIDC support, so the convention points
  at forward-auth — but gating the outage dashboard behind the identity
  provider makes an Authentik outage the one you cannot see, and the
  break-glass path (comment the middleware label, recreate) requires SSH at the
  exact moment you are already firefighting. Kuma ships real local auth (bcrypt,
  optional 2FA) and the lab is LAN-only, so the exposure is bounded. Recorded
  as an intentional non-integration in `sso-applications.md`, not omitted
  silently.
- **`infra/authentik/compose.yaml` is untouched.** No forward-auth means no
  `authentik@docker` middleware label and no per-host
  `/outpost.goauthentik.io/` router.
- **No network changes to any existing stack.** Kuma joins `proxy` only.
  `monitoring-net` and `authentik-net` stay internal. Reaching unexposed
  containers is solved by the Docker API, not by network topology (below).
- **Image pinned `louislam/uptime-kuma:2`** — major-only, conforming to repo
  policy. Verified against Docker Hub: a bare `2` tag is published (currently
  2.4.0), so no major.minor or full-patch exception is needed here.
- **The default image, not `2-rootless`.** Rootless would need `group_add` by
  `DOCKER_GID` to reach the socket, the way the Forgejo runner does — a second
  GID to keep in sync for no gain. Root-in-container matches how Alloy already
  holds the same socket.
- **No `.env` and no generated secrets.** Kuma's admin account is created
  through its own first-run web form; the ntfy topic lives in Kuma's SQLite.
  There is nothing for the init script to seed, which makes this the only stack
  in the repo without a `.env.example`.
- **Notifications go to hosted ntfy.sh** on a long random topic. No new
  infrastructure, works off-LAN, and survives the infra VM dying — which
  self-hosted ntfy on the same VM would not. Accepted trade: alert text
  (hostnames) transits a third party. Moving to a self-hosted ntfy later
  changes only the server URL in Kuma's notification config.
- **No IP addresses in the guide or the init script.** Everything addresses
  services by DNS name; the split-horizon records are the mechanism and
  `dns-records.md` remains the only place IPs are written down. This also rules
  out ping/host-level monitors, which were considered and dropped.
- **Fate-sharing is stated, not hidden.** Kuma runs on the infra VM and dies
  with it. It catches a stack failing — the common case — and not the VM
  failing. Named plainly in the guide rather than left for a reader to
  discover.

## Architecture

```
  uptime.thefipster.de ──> Traefik ──> uptime-kuma:3001   (no middleware)
                                            │
   ┌────────────────────────────────────────┼──────────────────────────┐
   │ HTTP(s) monitors                       │ Docker monitors          │
   │   via Traefik, the real user path      │   via /var/run/docker.sock
   │   grafana. · auth. · git.              │   every container on the VM,
   │   (+ TLS expiry per monitor)           │   regardless of network
   └────────────────────────────────────────┴──────────────────────────┘
                                            │
                                       ntfy.sh topic ──> phone

  networks: proxy (external) only
  volumes:  /opt/uptime-kuma:/app/data
            /var/run/docker.sock:/var/run/docker.sock:ro
```

## Components

### `infra/uptime-kuma/compose.yaml`

One service, `uptime-kuma`, project name `uptime-kuma`. Header comment carries
the two things a reader will look for and not find elsewhere: why this is not
in the monitoring stack, and why there is no `middlewares: authentik@docker`
label.

| Element | Value |
|---|---|
| Image | `louislam/uptime-kuma:2` |
| Restart | `unless-stopped` |
| Volumes | `/opt/uptime-kuma:/app/data`, `/var/run/docker.sock:/var/run/docker.sock:ro` |
| Networks | `proxy` (external) |
| Ports | none published |

Traefik labels, copied from `infra/forgejo` with host and port changed — no
per-router TLS labels, the wildcard covers it:

```
traefik.enable: "true"
traefik.http.routers.uptime.rule: Host(`uptime.thefipster.de`)
traefik.http.routers.uptime.entrypoints: websecure
traefik.http.services.uptime.loadbalancer.server.port: "3001"
```

The socket mount is the fourth in the lab (after Dockge, Traefik and Alloy) and
carries the same caveat already stated in `CLAUDE.md`: `:ro` makes the *mount*
read-only, not the API behind it, so this is root-equivalent control of the
VM's Docker. The compose comment says so rather than implying `:ro` is a
boundary.

### `scripts/init-uptime-kuma.sh`

House style — `set -euo pipefail`, paths resolved from `$BASH_SOURCE`, the
shared `run_root()` helper, re-runnable. Four steps, no secrets:

1. Check `docker` exists (same guard and message as the other init scripts).
2. `mkdir -p /opt/uptime-kuma`. No `chown`: the image runs as root, like Alloy.
3. Ensure the `proxy` network exists.
4. Symlink `infra/uptime-kuma` into `/opt/stacks/uptime-kuma` for Dockge.

Closing `echo` block points at the guide and the DNS registry, naming
`uptime.thefipster.de` — **no IP literal**, unlike `init-monitoring.sh`, which
prints one.

### Monitor inventory (clickwork, documented as a table in the guide)

Monitors live in Kuma's SQLite, not in the repo. The guide carries the
authoritative list so a rebuild is reproducible:

No compose file in the repo sets `container_name`, so every container is named
`<project>-<service>-1` and Kuma's Docker monitors must use those exact
strings:

| Monitor | Type | Target |
|---|---|---|
| Grafana | HTTP(s) | `https://grafana.thefipster.de` |
| Authentik | HTTP(s) | `https://auth.thefipster.de` |
| Forgejo | HTTP(s) | `https://git.thefipster.de` |
| Traefik | Docker | `traefik-traefik-1` |
| Dockge | Docker | `dockge-dockge-1` |
| Alloy | Docker | `monitoring-alloy-1` |
| Prometheus / Loki / Tempo | Docker | `monitoring-prometheus-1`, `monitoring-loki-1`, `monitoring-tempo-1` |
| Grafana DB | Docker | `monitoring-db-1` |
| Authentik server / worker / db / redis | Docker | `authentik-server-1`, `authentik-worker-1`, `authentik-db-1`, `authentik-redis-1` |
| Forgejo + db + runner | Docker | `forgejo-forgejo-1`, `forgejo-db-1`, `forgejo-runner-1` |

One caveat the guide must state: `infra/dockge/compose.yaml` is the only stack
with **no `name:` key**, so its project name comes from the directory it runs
from — `/opt/stacks/dockge`, per `init-dockge.sh`. That is where
`dockge-dockge-1` comes from, and it is the one name a reader cannot derive
from the repo alone.

The HTTP monitors are the honest end-to-end check — DNS, Traefik, wildcard
cert, app — and Kuma tracks certificate expiry per monitor, giving a second
read on wildcard renewal that does not depend on Alloy being alive.

Three targets are deliberately **Docker rather than HTTP**, each for a stated
reason:

- `dockge.` and `traefik.` are forward-auth gated and answer 302, not 200.
  (Kuma's accepted-status-codes field could take `200-399`, but that would
  report "up" for an Authentik redirect page — the container check is the more
  truthful signal.)
- `otlp.` has no root route: its Traefik routers match `PathPrefix(/v1/)` and
  the gRPC proto prefix only, so a bare `GET /` returns a Traefik 404. Alloy's
  container monitor covers it.

### Notifications

One ntfy notification in Kuma, `https://ntfy.sh` with a long random topic,
attached as the default for every monitor. The guide documents generating a
topic (`openssl rand -hex 16`) and that the topic string is a bearer secret —
anyone who knows it can read the alerts — so it is **never** committed. Kuma's
"Test" button is the verification.

## Verification

Runtime, on the VM, captured as the guide's checklist:

- `docker compose up -d` brings one container up; `docker compose ps` shows it
  healthy with no published ports.
- `https://uptime.thefipster.de` loads the Kuma setup form directly — **no
  Authentik redirect**, which is the visible proof the SSO deviation is in
  effect and intentional.
- The browser padlock shows the Let's Encrypt wildcard, same as every other lab
  host — confirms the router picked up the shared cert with no TLS labels.
- Adding one Docker monitor requires selecting a Docker host; creating it with
  connection type **Socket** and path `/var/run/docker.sock` and hitting "Test"
  returns success — proves the socket mount, and is the single step most likely
  to fail.
- A Docker monitor for an **unexposed** container (`monitoring-loki-1`, which
  lives only on `monitoring-net`) goes green — the direct answer to "can it see
  into stacks it shares no network with".
- Stop one container (`docker stop monitoring-loki-1`), watch the monitor go
  red and an ntfy push arrive; start it again and confirm recovery. End-to-end
  proof of the notification layer.
- No regressions: Grafana, Authentik and Forgejo still load, and Grafana's
  alert rules still show `Normal`.

Local (no daemon): `docker compose config -q` passes, and
`bash -n scripts/init-uptime-kuma.sh` parses.

## Error handling

- **Kuma unreachable, Traefik logs nothing.** Missing DNS record —
  `uptime.thefipster.de` falls through the `*.thefipster.de` wildcard to the
  apps VM and returns Coolify's 404 behind a valid certificate. The classic lab
  failure; the guide names it because it does not look like a DNS problem.
- **Docker monitors all fail with a connection error.** The socket mount is
  missing or the path in Kuma's Docker Host entry is wrong. `docker compose
  exec uptime-kuma ls -l /var/run/docker.sock` is the one-line check.
- **A Docker monitor is red but the container is running.** Kuma matches on
  container **name**, which compose builds as `<project>-<service>-<n>`.
  `docker ps --format '{{.Names}}'` gives the exact strings to paste.
- **HTTP monitor red with a TLS error.** Almost always the guest clock after a
  snapshot rollback, which `init-host.sh` addresses at the chrony level — the
  same failure mode already documented for every other TLS client in the lab.
- **No ntfy push although the monitor went red.** Topic mismatch between Kuma
  and the subscribed client, or the notification was not attached to that
  monitor (Kuma does not apply a notification retroactively unless "Default
  enabled" was set).

## Documentation changes (part of this work)

- **`docs/uptime-kuma-setup.md`** — new guide, standard structure: headline;
  one-line prerequisite linking `grafana-setup.md`; what the stack is; numbered
  steps with verification, each command in its own fenced block; jump-off;
  troubleshooting; server layout; design notes; jump-off repeated. Last in
  build order.
- **`docs/grafana-setup.md`** — its jump-off now points here instead of ending
  the chain.
- **`docs/dns-records.md`** — new row, `uptime.thefipster.de` → infra VM.
- **`docs/sso-applications.md`** — new row recording Kuma as a **deliberate
  non-integration**, with the reason, so the registry stays an honest account
  of every service's relationship to Authentik rather than only the ones that
  joined.
- **`README.md`** — repository-layout tree (`infra/uptime-kuma/`,
  `scripts/init-uptime-kuma.sh`), build order step 8 (Coolify moves to 9),
  status table row, and the infra-VM description in the architecture table.
- **`CLAUDE.md`** — the docs-layout section lists the guide chain and must name
  the new guide; the socket-mount note gains Kuma as a fourth user. The SSO
  convention section needs the deviation recorded — it currently reads as
  absolute ("one of two patterns, never both"), and Kuma is a third case.

## Out of scope

- **Joining `monitoring-net`** to health-check Loki/Prometheus/Tempo over HTTP
  (`/ready`, `/-/healthy`). Considered and dropped: Alloy already scrapes those
  three with a `ServiceDown` alert, and the Docker monitors already answer "is
  it running". It would mean promoting an internal network to external for no
  new signal.
- **Ping / host-level monitors** for the Proxmox host and apps VM. Dropped: they
  would require IP literals in the guide, and the lab addresses everything by
  DNS name.
- **Kuma's public status page.** A separate feature with its own curation and
  routing questions; nothing here depends on it.
- **A Grafana contact point.** Deliberately still absent — Kuma owns
  notification, and wiring both would produce duplicate alerts for overlapping
  conditions.
- **Push (heartbeat) monitors** for cron-style jobs. Nothing in the lab emits
  them yet.
- **Monitoring the apps VM's Coolify apps.** Coolify is not installed yet; those
  monitors arrive with it.
