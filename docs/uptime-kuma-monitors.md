# Uptime Kuma monitors (registry)

**Runs on:** Uptime Kuma on the infra VM — registry, not a build step

Every monitor the lab watches, grouped by the stack it belongs to. All of this is
**manual setup in the Kuma web UI** — Kuma keeps its own SQLite database and
nothing here is provisioned from a file — so this registry is the record of what
must exist. How to create them, register the Docker host and wire notifications:
[uptime-kuma-setup.md](uptime-kuma-setup.md).

**When a new service arrives, add its rows here first**, the same convention as
[dns-records.md](dns-records.md) and [sso-applications.md](sso-applications.md).
A service with a DNS record, an SSO entry and no monitor is a service whose
outages you find out about from someone complaining.

## The two monitor types, and when each applies

| Type | Watches | Use it when |
|------|---------|-------------|
| **HTTP(s)** | DNS → Traefik → certificate → application, end to end | the service answers **200** on `/` without authentication |
| **Docker** | container state, read from this VM's `docker.sock` | the route is gated, has no root path, or the container is on this VM and you want to tell "container down" from "route down" |

Docker monitors need the Docker host registered once
([uptime-kuma-setup.md, step 5](uptime-kuma-setup.md#5-add-the-monitors)).
They only work for containers on the **infra VM** — that is the only socket Kuma
can read.

**Container names are derived, not configured.** No compose file in this repo sets
`container_name`, so every container is `<project>-<service>-1`. When in doubt,
ask the daemon rather than trusting this table:

```bash
docker ps --format '{{.Names}}'
```

---

## traefik

| Monitor | Type | Target |
|---|---|---|
| Traefik | Docker | `traefik-traefik-1` |

**No HTTP monitor,** deliberately. `traefik.thefipster.de` is forward-auth gated
and answers **302**, not 200. Kuma's accepted-status-codes field would take
`200-399`, but that reports "up" for an Authentik redirect page — which is a
statement about Authentik, not about Traefik. The container check is the more
truthful signal.

Traefik is nonetheless covered end-to-end many times over: **every** HTTP monitor
below traverses it, so a Traefik failure turns most of this registry red at once.

## authentik

| Monitor | Type | Target |
|---|---|---|
| Authentik | HTTP(s) | `https://auth.thefipster.de` |
| Authentik server | Docker | `authentik-server-1` |
| Authentik worker | Docker | `authentik-worker-1` |
| Authentik DB | Docker | `authentik-db-1` |
| Authentik Redis | Docker | `authentik-redis-1` |

All four containers are listed because Authentik is the one stack whose partial
failures are silent: the `server` can serve a login page while the `worker` is
dead and nothing sends email or runs a flow, and Redis dying breaks sessions
without touching the front page.

## forgejo

| Monitor | Type | Target |
|---|---|---|
| Forgejo | HTTP(s) | `https://git.thefipster.de` |
| Forgejo | Docker | `forgejo-forgejo-1` |
| Forgejo DB | Docker | `forgejo-db-1` |
| Forgejo runner | Docker | `forgejo-runner-1` |

Both an HTTP and a container monitor on the same service, on purpose — that pair
is what distinguishes "Forgejo is down" from "the route to Forgejo is down".

The **runner** is the one container here whose failure is otherwise invisible:
nothing serves a page, nothing 500s, CI just silently stops picking up jobs.

## dockge

| Monitor | Type | Target |
|---|---|---|
| Dockge | Docker | `dockge-dockge-1` |

**No HTTP monitor** — forward-auth gated, same 302 reasoning as Traefik.

`dockge-dockge-1` is the one container name you cannot derive from the repo:
`infra/dockge/compose.yaml` is the only stack with no `name:` key, so its project
name comes from the directory `init-dockge.sh` copies it into.

## monitoring

| Monitor | Type | Target |
|---|---|---|
| Grafana | HTTP(s) | `https://grafana.thefipster.de` |
| Grafana | Docker | `monitoring-grafana-1` |
| Grafana DB | Docker | `monitoring-db-1` |
| Prometheus | Docker | `monitoring-prometheus-1` |
| Loki | Docker | `monitoring-loki-1` |
| Tempo | Docker | `monitoring-tempo-1` |
| Alloy | Docker | `monitoring-alloy-1` |

Six containers, and this is the stack where Kuma earns its keep: it is the only
watcher that does not depend on the thing being watched. Grafana's own
`ServiceDown` alert cannot fire when **Alloy** is the component that died — `up`
goes stale, the rule evaluates NoData → OK, and nothing happens. `monitoring-alloy-1`
is that blind spot's only cover.

**No HTTP monitor for `otlp.thefipster.de`.** It has no root route: its routers
match `PathPrefix(/v1/)` and the gRPC proto prefix only, so a bare `GET /` gets a
Traefik 404. `monitoring-alloy-1` covers the same process.

## apps VM — Coolify

| Monitor | Type | Target |
|---|---|---|
| Coolify | HTTP(s) | `https://coolify.thefipster.de` |

HTTP-only, necessarily: Coolify runs on **another VM**, so there is no container
here for a Docker check to read. Add a row per deployed app as you deploy them —
each gets its own hostname under the wildcard, and none of them needs a DNS
record.

"Down" is genuinely ambiguous for this monitor in a way it is not for the infra
stacks: it could be the app, Coolify's proxy, or that VM being off.

## home-assistant VM

| Monitor | Type | Target |
|---|---|---|
| Home Assistant | HTTP(s) | `https://ha.thefipster.de` |

HTTP-only for the same reason — another VM, no local container. This one has a
third failure mode on top of Coolify's, because it is proxied by Traefik *on the
infra VM* to the HA VM: see
[home-assistant-setup.md](home-assistant-setup.md#troubleshooting) for telling a
502 (backend unreachable) from a 404 (route missing).

---

## Deliberately not monitored

Three absences that are decisions, not gaps. Listed so this registry stays an
honest account of coverage.

**Uptime Kuma itself.** A monitor for `uptime-kuma-uptime-kuma-1` would be
pointless: a dead Kuma cannot report that it is dead, and a live one telling you
it is alive carries no information. This is the lab's one genuine monitoring blind
spot and it is structural — closing it needs something *outside* the lab, either a
push/heartbeat monitor to an external service or a second watcher on another
machine. Neither exists yet.

**The Proxmox host.** Tempting, and useless from here: Kuma runs on the infra VM,
which is a **guest of the hypervisor**. Any failure severe enough to take the
Proxmox host down takes Kuma with it, so the monitor could never fire for the case
you would want it for. The hypervisor is instead watched from the metrics side —
Alloy scrapes its node exporter as `instance="pve"`, and Grafana's `DiskAlmostFull`
and `ServiceDown` rules cover it
([grafana-setup.md](grafana-setup.md#6-add-the-proxmox-host)).

**A DNS monitor for the wildcard-versus-exact-record trap.** The repo's
most-warned-about failure is an infra name losing its exact record and falling
through `*.thefipster.de` to the apps VM. That needs no monitor of its own: the
existing HTTP monitors already catch it, because Coolify answers such a request
with a 404 and every HTTP monitor here expects 200. A dedicated DNS monitor would
also have to assert an expected address, which is exactly what
[dns-records.md](dns-records.md#why-this-registry-holds-no-addresses) refuses to
write down.

## What every HTTP monitor also gets, for free

Kuma tracks **certificate expiry per HTTPS monitor**. That is a second,
independent read on wildcard renewal — independent of Alloy, of Prometheus, and of
Grafana's `CertExpiringSoon` rule, all of which share a failure domain with each
other and none of which share one with Kuma.
