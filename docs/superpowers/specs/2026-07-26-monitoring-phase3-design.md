# Monitoring phase 3 — service and host metrics

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan
**Roadmap:** [docs/roadmap/monitoring.md](../../roadmap/monitoring.md) — this
spec covers **phase 3 only**; phases 4–5 stay on the roadmap.
**Builds on:** [phase 1](2026-07-26-monitoring-phase1-design.md) (platform) and
[phase 2](2026-07-26-monitoring-phase2-design.md) (logs), both deployed and
verified on the infra VM.

## Goal

Scrape the Prometheus endpoints that the lab's services already ship — Traefik,
Authentik, Forgejo — and add host-level metrics (CPU, memory, disk,
filesystem) via Alloy's embedded unix exporter. This is what makes phase 5's
VM dashboard and the "disk >80 %" alert possible.

## Constraints & decisions made

- **Scope: the three service endpoints plus host metrics.** Per-container
  metrics (cadvisor) and Authentik's `worker` are explicitly **out**. Cadvisor
  costs continuous CPU and several more host mounts for a question — "which
  container is eating RAM" — that a one-person lab can answer with
  `docker stats` when it actually arises. The worker sits on `authentik-net`
  alone and exposes mostly task-queue depth; reaching it would mean a second
  network on Alloy for little return.
- **Alloy joins the `proxy` network.** This is the enabling change, and the
  roadmap did not anticipate it: Alloy currently sits on `monitoring-net` only,
  while Traefik, Authentik's `server` and Forgejo all sit on `proxy`. Phase 1's
  targets were all inside Alloy's own stack, so the gap never surfaced. Joining
  each stack's private network instead would mean three networks and still
  wouldn't reach Traefik; scraping through the public hostnames would drag TLS
  and forward-auth into the scrape path. Nothing becomes newly exposed by this:
  Traefik only routes containers carrying `traefik.enable` labels, and Alloy has
  none.
- **Authentik requires no change whatsoever.** `AUTHENTIK_LISTEN__METRICS`
  already defaults to `[::]:9300` on every component, so the endpoint is live
  today and merely unreachable. The roadmap's phrasing implies setting the
  variable; verified against the upstream configuration reference, and against
  the running instance, that would be redundant. `infra/authentik/compose.yaml`
  is untouched.
- **Static scrape targets, not Docker discovery.** `discovery.docker` exists
  from phase 2 and could auto-discover by container label, but three targets
  that change roughly never do not justify a discovery convention every stack
  must opt into. Explicit beats clever at this size.
- **Traefik gets a dedicated `metrics` entrypoint on `:8082`** rather than
  relying on the implicit `traefik` entrypoint. Self-documenting, and it cannot
  collide with the dashboard. Reachable only on Docker networks — nothing is
  published to the host.
- **Forgejo's `/metrics` is enabled and left open on the LAN.** A deliberate,
  informed choice — see the dedicated section below.
- **Host metrics need the host root filesystem mounted read-only.** See the
  dedicated section below.
- **No change to the metrics storage path.** Both new scrapes feed the existing
  `prometheus.remote_write`; Prometheus still has no `scrape_configs` and still
  runs with 15-day retention.
- **Label convention carries forward from phase 1:** each target gets a
  `service` label (`traefik`, `authentik`, `forgejo`, `host`), matching the
  existing `alloy` / `prometheus` / `loki` / `grafana` series.

## Architecture

```
  infra VM (.41)
  ┌────────────────────────────────────────────────────────────────┐
  │  alloy  (now on monitoring-net AND proxy)                       │
  │                                                                 │
  │   prometheus.scrape "monitoring_stack"   (phase 1, unchanged)   │
  │   prometheus.scrape "infra_services"  ──► traefik:8082          │
  │                                       ──► authentik-server:9300 │
  │                                       ──► forgejo:3000          │
  │   prometheus.scrape "host" ◄── prometheus.exporter.unix         │
  │                                  │                              │
  │                                  └─ /host/proc, /host/sys,      │
  │                                     /host/root  (all :ro)       │
  │            │                                                    │
  │            ▼                                                    │
  │   prometheus.remote_write "default" ──► prometheus:9090         │
  └────────────────────────────────────────────────────────────────┘
```

The log pipeline from phase 2 is untouched and keeps running alongside.

## Components

### `infra/monitoring/compose.yaml`

Alloy gains the `proxy` network and three read-only host mounts:

```yaml
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro,rslave
```

`rslave` propagation ensures mounts made on the host after Alloy starts remain
visible, so a newly attached disk still reports usage.

### `infra/monitoring/alloy/config.alloy`

Three additions, appended after the existing metrics section:

- **`prometheus.exporter.unix "host"`** with `procfs_path = "/host/proc"`,
  `sysfs_path = "/host/sys"`, `rootfs_path = "/host/root"`. No privileged mode
  and no host PID namespace — verified against the component reference. Alloy
  already runs as root in-container, which is sufficient for the default
  collector set.
- **`prometheus.scrape "host"`** — the exporter's targets, relabelled to
  `service="host"`, forwarded to the existing remote-write receiver.
- **`prometheus.scrape "infra_services"`** — three static targets with
  `service` labels, same shape as phase 1's `monitoring_stack` block. Metrics
  paths are the default `/metrics` for all three.

### `infra/traefik/compose.yaml`

A metrics entrypoint and the Prometheus flags, including the label options that
make the metrics useful for a per-router/per-service dashboard in phase 5:

```yaml
      - --entrypoints.metrics.address=:8082
      - --metrics.prometheus=true
      - --metrics.prometheus.entrypoint=metrics
      - --metrics.prometheus.addentrypointslabels=true
      - --metrics.prometheus.addrouterslabels=true
      - --metrics.prometheus.addserviceslabels=true
```

Exact flag casing is verified against the Traefik reference during
implementation. This restarts Traefik, briefly blipping every routed service —
the same caveat as phase 2's access-log change.

### `infra/forgejo/compose.yaml`

One environment variable on the `forgejo` service:

```yaml
      FORGEJO__metrics__ENABLED: "true"
```

## Forgejo's `/metrics` exposure

Forgejo serves `/metrics` on port 3000 — **the same port Traefik publishes at
`git.thefipster.de`**. Enabling metrics therefore makes
`https://git.thefipster.de/metrics` readable by anyone on the LAN, without
authentication.

**Decision: leave it open.** What it exposes is aggregate counters — repository,
user, issue, PR and webhook totals — not repository contents, names, or
credentials. The lab is LAN-only with no untrusted users, and the alternatives
each carry a cost the exposure doesn't justify today.

Recorded so a future reader can reverse it cheaply. Alloy scrapes
`forgejo:3000` **directly over the `proxy` network**, never through Traefik, so
either fix below is invisible to collection:

- **Block the public path:** a higher-priority Traefik router matching
  ``Host(`git.thefipster.de`) && PathPrefix(`/metrics`)`` with an
  `ipAllowList` of `127.0.0.1/32`, which returns 403 to LAN clients.
- **Require a token:** `FORGEJO__metrics__TOKEN` plus `bearer_token` on the
  Alloy scrape. Protects the endpoint itself rather than one route to it, at
  the cost of the same secret living in two stacks' `.env` files.

## The host root mount

`/:/host/root:ro,rslave` mounts the **entire host filesystem, read-only**, into
the Alloy container. This is what the `filesystem` collector needs to report the
VM's real disk usage rather than the container's — the metric behind phase 5's
"disk >80 %" alert, so it is load-bearing rather than incidental.

Stated plainly, and in proportion: Alloy has held `/var/run/docker.sock` since
phase 2, which is **root-equivalent control** of this VM's Docker and strictly
more powerful than read-only filesystem visibility. This mount widens what Alloy
can see; it does not move the trust boundary that phase 2 already crossed. Both
belong in the same paragraph of `CLAUDE.md`, not in separate places where the
combination is easy to miss.

## Verification

Runtime, on the VM, captured as the guide's checklist:

- `up` in Explore returns series for `traefik`, `authentik`, `forgejo` and
  `host`, **in addition to** phase 1's `alloy`, `prometheus`, `loki`, `grafana`.
- `traefik_service_requests_total` is non-zero after loading any lab URL.
- `node_filesystem_avail_bytes` reports the **VM's** real free space —
  cross-checked against `df -h` on the VM. This is the check that proves the
  rootfs mount works, and it must be *compared*, not merely observed: a
  container-only view returns a plausible-looking wrong number, not an empty
  result. The `mountpoint` label's exact value is whatever the exporter reports
  after applying `rootfs_path` (it strips the prefix, so expect `/` rather than
  `/host/root`) — confirm by listing the series rather than assuming the label.
- `node_memory_MemAvailable_bytes` is non-zero and plausible for a 10 GB VM.
- An Authentik metric returns, proving cross-network scraping over `proxy`.
- Phase 2's logs still flow (`{job="docker"}`) and phase 1's `up` series are
  unchanged — this phase disturbs neither.

Local (no daemon): `docker compose config -q` on all three edited stacks, and
`alloy fmt` on the VM.

## Error handling

- **A target is down or unreachable:** `up{service="..."}` goes to 0 for that
  target only; every other series keeps flowing. This is the intended failure
  mode and is exactly what phase 5's "service down" alert will watch.
- **Alloy can't reach a target after joining `proxy`:** the network alias is
  wrong or the service isn't on `proxy`. `docker compose exec alloy wget -qO-
  http://<target>/metrics` isolates it, and Alloy's UI on `127.0.0.1:12345`
  shows the scrape component's health.
- **Host metrics show container values:** the path arguments and the three
  mounts disagree. Compare `node_filesystem_avail_bytes` against `df -h`.
- **Traefik fails to start after the flag change:** the flags are additive and
  independently revertible — comment them and `docker compose up -d`.
- **Forgejo metrics 404:** the env var didn't reach the container;
  `docker compose exec forgejo printenv | grep -i metrics` confirms.

## Out of scope

- **Phases 4–5** — OTLP intake, Tempo, dashboards and alerts. The metrics this
  phase adds are the *inputs* to phase 5; no dashboard or alert is built here.
- **Per-container metrics (cadvisor)** and **Authentik's worker** — descoped
  above, both cheap to add later.
- **Postgres and Redis metrics** — neither exposes Prometheus natively; each
  would need a sidecar exporter. Not worth it for a lab whose databases back
  three services.
- **The apps VM** — its own Alloy comes later.
- **Retention or storage changes** — Prometheus stays at 15 days.
