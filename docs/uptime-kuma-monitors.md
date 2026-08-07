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

## Naming: function, not product

Monitor names describe **what breaks for a user**, not which piece of software is
involved. `SSO Web` down means nobody can log in anywhere; `authentik-server-1`
down means you first have to remember what Authentik is for. The dashboard is read
at the worst possible moment, so it should not require a mental lookup table.

The pattern is `<Function> <Role>`, with a shared function prefix per stack:

| Role | Means |
|------|-------|
| **Web** | the routed HTTPS entry point — what a browser talks to |
| **Backend** | the main application container behind it |
| **Database** / **Caching** | that stack's datastore |
| **Worker** / **Runner** / **Collector** | background processing, no user-facing page |
| **Storage** | a datastore that *is* the product (metrics, logs, traces) |
| **Host** | ICMP to the machine, below any service on it |

The product name still appears — in the **Target** column, where it belongs, since
that is what you paste into Kuma and what `docker ps` will show you.

## Monitor types, and when each applies

| Type | Watches | Use it when |
|------|---------|-------------|
| **HTTP(s)** | DNS → Traefik → certificate → application, end to end | the service answers **200** on `/` without authentication |
| **Docker** | container state, read from this VM's `docker.sock` | the route is gated, has no root path, or the container is on this VM and you want to tell "container down" from "route down" |
| **Ping** | ICMP to the host | the machine can fail *independently of Kuma* — see [Reachability](#reachability-and-why-only-two-machines-get-it) |
| **Push** | nothing — it waits to be told | the thing to check is a **condition Kuma cannot reach**: a shell command, a job's outcome, a machine with no listening port worth polling |

**Push inverts the direction**, which is what makes it the answer for anything
off-box that has no HTTP surface. Kuma hands you a URL, something out there calls
it on a schedule, and silence past the interval is a failure. Two failure modes
for the price of one: the caller can report a problem *actively* by pushing
`status=down&msg=...`, and if the caller dies instead, the absence is caught
anyway. There is no monitor type that runs a command — that is precisely the gap
Push fills.

Docker monitors need the Docker host registered once
([uptime-kuma-setup.md, step 5](uptime-kuma-setup.md#5-add-the-monitors)) and only
work for containers on the **infra VM** — that is the only socket Kuma can read.

**Container names are derived, not configured.** No compose file in this repo sets
`container_name`, so every container is `<project>-<service>-1`. When in doubt,
ask the daemon rather than trusting this table:

```bash
docker ps --format '{{.Names}}'
```

---

## Gateway — traefik

| Name | Type | Target |
|---|---|---|
| Gateway | Docker | `traefik-traefik-1` |

**No `Gateway Web` monitor,** deliberately. `traefik.thefipster.de` is
forward-auth gated and answers **302**, not 200. Kuma's accepted-status-codes
field would take `200-399`, but that reports "up" for an Authentik redirect page —
which is a statement about Authentik, not about Traefik. The container check is the
more truthful signal.

Traefik is nonetheless covered end-to-end many times over: **every** HTTP monitor
below traverses it, so a Traefik failure turns most of this registry red at once.

## Vault — vaultwarden

| Name | Type | Target |
|---|---|---|
| Vault Web | HTTP(s) | `https://vault.thefipster.de` |
| Vault Backend | Docker | `vaultwarden-vaultwarden-1` |
| Vault Storage | Docker | `vaultwarden-db-1` |

The one stack where **`Vault Web` alone would be misleading**. Vaultwarden
serves its web vault from cached assets and answers `/` with 200 even when
Postgres is unreachable — the failure only shows up at login, which is a page
Kuma never reaches. `Vault Storage` is what turns "the vault is fine" into a
claim about the database too.

Set `Vault Web` to expect **200**; there is no gate in front of it to redirect,
because [Vaultwarden joins no SSO
pattern](sso-applications.md#vaultwarden-deliberately-not-joined). That makes it
the only Web monitor here whose green state does not also depend on Authentik —
which is the same property the service itself was placed in the build order for.

## Identity — authentik

| Name         | Type | Target |
|--------------|---|---|
| Auth Web     | HTTP(s) | `https://auth.thefipster.de` |
| Auth Backend | Docker | `authentik-server-1` |
| Auth Worker  | Docker | `authentik-worker-1` |
| Auth Storage | Docker | `authentik-db-1` |

All three containers are listed because Authentik is the one stack whose partial
failures are silent: `Auth Backend` can serve a login page while `Auth Worker` is
dead and nothing sends email or runs a flow.

There is **no cache monitor**, and that is a deliberate non-row rather than a
gap: Authentik has run without Redis since its 2025.10 release — caching,
background tasks and the embedded outpost's sessions all live in Postgres — so
`Auth Storage` already covers what a `authentik-redis-1` monitor used to.

## Git — forgejo

| Name        | Type | Target |
|-------------|---|---|
| Git Web     | HTTP(s) | `https://git.thefipster.de` |
| Git Backend | Docker | `forgejo-forgejo-1` |
| Git Runner  | Docker | `forgejo-runner-1` |
| Git Storage | Docker | `forgejo-db-1` |

`Git Web` and `Git Backend` are the same service checked two ways, on purpose —
that pair is what distinguishes "Forgejo is down" from "the route to Forgejo is
down".

`Git Runner` is the one container here whose failure is otherwise invisible:
nothing serves a page, nothing 500s, CI just silently stops picking up jobs.

Note that `Git Web` also covers the **container registry** — same hostname, same
Forgejo process — so a red `Git Web` means image pulls are failing too, not only
the web UI.

## Stack management — dockge

| Name | Type | Target |
|---|---|---|
| Stack Manager | Docker | `dockge-dockge-1` |

**No Web monitor** — forward-auth gated, same 302 reasoning as the Gateway.

`dockge-dockge-1` is the one container name you cannot derive from the repo:
`infra/dockge/compose.yaml` is the only stack with no `name:` key, so its project
name comes from the directory `init-dockge.sh` copies it into.

## Observability — monitoring

| Name | Type | Target |
|---|---|---|
| Dashboards Web | HTTP(s) | `https://grafana.thefipster.de` |
| Dashboards Backend | Docker | `monitoring-grafana-1` |
| Dashboards Database | Docker | `monitoring-db-1` |
| Metrics Storage | Docker | `monitoring-prometheus-1` |
| Logs Storage | Docker | `monitoring-loki-1` |
| Traces Storage | Docker | `monitoring-tempo-1` |
| Telemetry Collector | Docker | `monitoring-alloy-1` |

The one stack that does not take a single function prefix, because it genuinely
performs four: dashboards, metrics, logs and traces. Naming them by signal is more
useful than `Monitoring 1..7` would be — when `Logs Storage` goes red you know
immediately that metrics and traces are unaffected.

This is also where Kuma earns its keep, being the only watcher that does not depend
on the thing it watches. Grafana's own `ServiceDown` alert cannot fire when
**`Telemetry Collector`** is what died — `up` goes stale, the rule evaluates
NoData → OK, and nothing happens. That monitor is the blind spot's only cover.

**No Web monitor for `otlp.thefipster.de`.** It has no root route: its routers
match `PathPrefix(/v1/)` and the gRPC proto prefix only, so a bare `GET /` gets a
Traefik 404. `Telemetry Collector` covers the same process.

## App platform — apps VM (Coolify)

| Name          | Type | Target |
|---------------|---|---|
| Apps Platform | HTTP(s) | `https://coolify.thefipster.de` |
| Apps Host     | Ping | `apps.thefipster.de` |

No Docker monitors: Coolify runs on **another VM**, so there is no container here
for a Docker check to read. Per-app monitors are **not** recorded here either:
each deployed app's monitors are listed beside the app itself, in its README's
**Uptime Kuma monitors** section ([apps/services.md](../apps/services.md) is the
catalog). Each app gets its own hostname under the wildcard, and none of them
needs a DNS record.

Every one of them is a **single HTTP(s) monitor** for the same reason this stack
has no Docker rows, so their lists look thin next to any infra stack above. Each
app's README states that absence in place rather than leaving it to be inferred.

The ping monitor is what makes a red `Apps Platform` interpretable. On its own it
could mean the app, Coolify's proxy, or the VM being off; with `Apps Host`
beside it the answer is immediate.

## Home automation — home-assistant VM

| Name | Type | Target |
|---|---|---|
| Home Automation | HTTP(s) | `https://ha.thefipster.de` |
| HA Host | Ping | `homeassistant.thefipster.de` |

Same shape, one extra failure mode: `Home Automation` traverses Traefik **on the
infra VM**, which proxies to the HA VM. So a red HTTP monitor with a green ping
narrows it to Traefik's route or Home Assistant itself — see
[home-assistant-setup.md](home-assistant-setup.md#troubleshooting) for telling a
502 (backend unreachable) from a 404 (route missing).

Note the two different names deliberately: the HTTP monitor uses `ha.` (the
service, which resolves to the infra VM) and the ping uses `homeassistant.` (the
machine). Pinging `ha.` would pointlessly ping the infra VM —
[dns-records.md](dns-records.md#home-assistant-has-two-names-on-purpose).

## Hypervisor storage — Proxmox host

| Name | Type | Target |
|---|---|---|
| Hypervisor Storage | Push | *(push URL — the host calls Kuma)* |

The one monitor here that watches a **condition** rather than a service, and the
only one whose target is not something Kuma dials. Set the heartbeat interval to
**300 s** with 2 retries; a timer on the Proxmox host calls the push URL on that
cadence. Create the monitor first, then paste its URL into
[proxmox-setup.md Part 9](proxmox-setup.md#part-9--notice-when-a-mirror-degrades),
which is where the script and its systemd timer live — on the hypervisor, because
that is the machine with the pools.

**Why this exists at all:** the lab's six internal drives are paired into three
ZFS mirrors, and **a degraded mirror is the failure that takes nothing down.**
The host keeps running, every VM keeps running, redundancy is silently gone, and
the second drive of the pair fails weeks later with no audience. Nothing else in
this registry would go red.

The push carries the pool name, so a `down` here names the drive to look at
rather than sending you to the shell to find out. It covers all four pools —
including `usbbackup`, the external backup drive, whose *absence* is otherwise
invisible: a pool whose device vanished does not appear in `zpool list` at all,
which is why the script checks an expected list rather than trusting that output.

Pool *health* is deliberately **not** alerted from Grafana, even though Alloy
already scrapes the hypervisor. This is a notification, and notifications are
Kuma's half of the split ([uptime-kuma-setup.md](uptime-kuma-setup.md)) — putting
it here means it inherits the configured ntfy notification with no new alert rule
and no new contact point.

Pool *capacity* goes the other way, and the same timer does both jobs from one
`zpool list`: it pushes here, and writes `zfs_pool_*` metrics for Prometheus, so
`ZfsPoolAlmostFull` in Grafana covers a filling pool
([grafana-setup.md](grafana-setup.md#what-diskalmostfull-sees-under-zfs)). A
degrading mirror is something to be told about; a pool at 74% is something to
look at on a graph. The coupling is also what makes a staleness alert
unnecessary — a script that stops writing metrics stops pushing heartbeats, and
this monitor says so.

---

## Reachability, and why only two machines get it

A ping monitor is worth having exactly when **the target can fail independently of
Kuma**. That single rule decides all four machines:

| Machine | Ping monitor | Why |
|---|---|---|
| apps VM | **yes** | separate machine; can die while Kuma keeps running and reporting |
| home-assistant VM | **yes** | same |
| infra VM | **no** | Kuma *runs on it*. If it is down, so is Kuma. |
| Proxmox host | **no** | Kuma is a **guest** of it. Same failure domain, one level down. |

Ping is not a deeper check than HTTP — it is a **shallower** one, and that is the
point. HTTP tests DNS, TCP, TLS, routing and the application at once, so it fails
for many reasons; ICMP fails for exactly one. Running both against the same host
turns "something is wrong" into "the machine is fine, the service is not".

Addressed by **name**, not by address, like everything else in the lab — Kuma's
ping monitor accepts hostnames, so there is no reason to hardcode anything here
([dns-records.md](dns-records.md#why-this-registry-holds-no-addresses)).

> **If a ping monitor never turns green, it is capabilities, not the network.**
> ICMP needs `NET_RAW`, which is in Docker's default capability set — so this
> works out of the box only because `infra/uptime-kuma/compose.yaml` drops no
> capabilities. Verify from the container rather than the host:
>
> ```bash
> docker compose exec uptime-kuma ping -c1 apps.thefipster.de
> ```

## Deliberately not monitored

Three absences that are decisions, not gaps. Listed so this registry stays an
honest account of coverage.

**Uptime Kuma itself.** A monitor for `uptime-kuma-uptime-kuma-1` would be
pointless: a dead Kuma cannot report that it is dead, and a live one telling you it
is alive carries no information. This is the lab's one genuine monitoring blind
spot and it is structural — closing it needs something *outside* the lab, either a
push/heartbeat monitor to an external service or a second watcher on another
machine. Neither exists yet.

**The Proxmox host's *availability*.** Tempting, and useless from here, for the
reason in the table above: Kuma is a guest of the hypervisor, so any failure
severe enough to take Proxmox down takes Kuma with it. Uptime is watched from the
metrics side instead — Alloy scrapes its node exporter as `instance="pve"`, and
Grafana's `DiskAlmostFull`, `ZfsPoolAlmostFull` and `ServiceDown` rules cover it
([grafana-setup.md](grafana-setup.md#6-add-the-proxmox-host)).

> **Note the word *availability*.** That argument is about the host being up, and
> it does not extend to the host's **condition**. A degraded ZFS mirror leaves
> Proxmox running perfectly, so the shared-failure-domain reasoning simply does
> not apply — which is why
> [Hypervisor Storage](#hypervisor-storage--proxmox-host) exists above and is not
> a contradiction of this absence. The distinction is worth keeping straight:
> "same failure domain" rules out watching whether the box answers, not whether
> the box is healthy.

**A DNS monitor for the wildcard-versus-exact-record trap.** The repo's
most-warned-about failure is an infra name losing its exact record and falling
through `*.thefipster.de` to the apps VM. That needs no monitor of its own: the
existing HTTP monitors already catch it, because Coolify answers such a request
with a 404 and every HTTP monitor here expects 200. A dedicated DNS monitor would
also have to assert an expected address, which is exactly what
[dns-records.md](dns-records.md#why-this-registry-holds-no-addresses) refuses to
write down.

## Optional: group them on the dashboard

Kuma 2.x supports a **Group** monitor type — a parent with no check of its own
that nests the monitors under it. Creating one group per section heading above
(`Gateway`, `Vault`, `Identity`, `Git`, `Stack management`, `Observability`,
`App platform`, `Home automation`, `Hypervisor storage`) makes the status page
collapse to nine rows that expand on demand, instead of twenty-five flat
entries.

Worth doing once the list is long; skip it while it still fits on a screen. Groups
are cosmetic — they do not affect checks or notifications — so this registry
records the grouping as *optional* rather than as rows to create.

## What every HTTP monitor also gets, for free

Kuma tracks **certificate expiry per HTTPS monitor**. That is a second,
independent read on wildcard renewal — independent of Alloy, of Prometheus, and of
Grafana's `CertExpiringSoon` rule, all of which share a failure domain with each
other and none of which share one with Kuma.
