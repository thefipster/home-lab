# Roadmap: Monitoring (infra VM)

Goal: one place to see **logs, metrics and (later) traces** for every stack on
the infra VM and, later, the apps the apps VM runs — collected via
OpenTelemetry-compatible plumbing wherever possible.

## Decision: Grafana + Alloy + Loki (not Seq)

**Seq** is a strong contender for one reason: it has the best structured-log
UX in the .NET world, ingests OTLP, and is a single low-maintenance container.
If the only goal were "read my Blazor app's Serilog output", Seq would win.

It loses on the actual first requirement: **the logs that exist today are not
.NET logs.** Traefik, Authentik, Forgejo, Dockge, Postgres and Redis are
heterogeneous container stdout — and the same services all expose
**Prometheus metrics endpoints** that Seq can't do anything with. The Grafana
stack covers logs *and* metrics *and* dashboards/alerts with one agent:

- **Alloy** (the collector) natively discovers Docker containers and tails
  their stdout, has embedded `node_exporter`/`cadvisor` equivalents, scrapes
  Prometheus endpoints, and is a full **OTLP receiver** — the future Blazor
  apps just point their OTel SDK at it.
- **Loki** stores logs cheaply (label-indexed, no full-text index to feed).
- **Grafana** is the single pane, with native **OIDC** — so it joins Authentik
  by the OIDC pattern (it has real SSO support; forward-auth is for UIs that
  don't), matching the repo's SSO convention.
- **Tempo** (traces) can be added later without changing anything else —
  Alloy already speaks OTLP on both ends.

Seq can still appear later as a dev-side luxury for app logs, but it would be
a second system, not the foundation.

## Architecture

```
containers stdout ─┐
Prometheus /metrics ─┼─► Alloy (infra VM) ─► Loki (logs) ─┐
OTLP from apps ─────┘                     ─► Prometheus ──┼─► Grafana (OIDC via Authentik)
                                          ─► Tempo (later)┘
```

One `infra/monitoring` compose stack, same conventions as everything else:
`proxy` network + labels for `grafana.thefipster.de`, data under
`/opt/monitoring/{grafana,loki,prometheus}`, `.env.example` + init script,
symlink into `/opt/stacks`. Later the apps VM gets its own Alloy shipping to
this Loki/Prometheus over the LAN.

## Phases

1. **✅ Landed** — see [docs/grafana-setup.md](../grafana-setup.md).
   **Stack skeleton** — Grafana + Loki + Prometheus + Alloy compose;
   `grafana.thefipster.de` routed; Grafana wired to Authentik as an
   OAuth2/OIDC app (guide part, like Forgejo's). Retention short: Loki 14d,
   Prometheus 15d.
   Shipped with a dedicated Postgres for Grafana (one `pg_dump`-shaped backup
   story across the lab, and no downtime to take one) and **without** the
   `docker.sock` mount on Alloy — phase 2 adds the socket together with
   `discovery.docker`, so the root-equivalent grant follows the capability
   that needs it. Loki is intentionally empty until then.
2. **✅ Landed** — see [docs/monitoring-setup.md](../monitoring-setup.md).
   **Logs** — Alloy `discovery.docker` + `loki.source.docker`: every container
   on the VM, labeled by compose project/service. Verify Authentik's JSON
   logs land parsed and Traefik access logs are on (`--accesslog=true`).
   Shipped with four labels only (`job`, `compose_project`, `compose_service`,
   `container`) and **no ingest-time parsing** — JSON is parsed at query time
   with `| json`. Alloy took the `docker.sock` mount here, as phase 1 said it
   would.
3. **✅ Landed** — see [docs/monitoring-setup.md](../monitoring-setup.md).
   **Metrics** — enable the endpoints that already exist: Traefik
   (`--metrics.prometheus`), Authentik (`AUTHENTIK_LISTEN__METRICS`, :9300),
   Forgejo (`FORGEJO__metrics__ENABLED`); host + per-container via Alloy's
   embedded unix/cadvisor exporters.
   Shipped with the unix exporter only — **cadvisor was descoped**: continuous
   CPU cost and several more host mounts to answer a question `docker stats`
   already answers on demand. Authentik needed **no change at all** (`:9300` is
   the default). The enabling change the roadmap didn't foresee: Alloy had to
   join the `proxy` network, since it sat on `monitoring-net` alone and could
   not reach a single one of the three targets.
4. **OTLP intake** — Alloy listens on 4317/4318 for the future apps; add
   Tempo when the first app actually emits traces, not before.
5. **Dashboards + alerts** — a VM dashboard (CPU/RAM/disk), a Traefik
   dashboard (status codes, cert expiry), and 2–3 alerts that matter
   (disk >80 %, service down, cert not renewed). More than that is noise in
   a one-person lab.

## Constraints & notes

- **RAM: resolved.** The infra VM was raised from 4 GB to **10 GB** before
  phase 1, so the stack needs no memory limits and retention isn't constrained
  by memory. Revisit only if phase 3's per-container metrics change the
  picture.
- Non-goals: HA, long-term storage, Mimir/Thanos — this is a lab, snapshots
  and short retention are the durability story.
