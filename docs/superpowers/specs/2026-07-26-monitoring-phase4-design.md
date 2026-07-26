# Monitoring phase 4 — OTLP intake and traces

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan
**Roadmap:** [docs/roadmap/monitoring.md](../../roadmap/monitoring.md) — this
spec covers **phase 4 only**; phase 5 (dashboards + alerts) stays on the
roadmap.
**Builds on:** [phase 1](2026-07-26-monitoring-phase1-design.md) (platform),
[phase 2](2026-07-26-monitoring-phase2-design.md) (logs) and
[phase 3](2026-07-26-monitoring-phase3-design.md) (metrics), all deployed and
verified on the infra VM.

## Goal

Give the lab an OpenTelemetry ingest endpoint. Alloy receives OTLP over gRPC
and HTTP, routed through Traefik at `otlp.thefipster.de`, and fans the three
signals out: metrics into the existing Prometheus, logs into the existing Loki,
and traces into a new Tempo. A future app on the apps VM points its OTel SDK at
one URL and its telemetry lands beside the infrastructure's.

## Deviation from the roadmap (recorded on purpose)

The roadmap says: *"add Tempo when the first app actually emits traces, not
before."* This phase **includes Tempo now**, by explicit decision. The
consequence is a larger phase than the roadmap sketched — a fifth service, a
new datasource, three pipelines instead of two, and trace storage that nothing
writes to until an app exists. Accepted because a synthetic OTLP payload
verifies the whole path end to end (see Verification), so "nothing emits traces
yet" does not mean "untestable."

A second, smaller deviation: the roadmap implies plain OTLP ports. This phase
routes OTLP **through Traefik with TLS** instead (see Exposure). Phase 3 already
put Alloy on the `proxy` network, so Traefik can reach it with no published
host port.

## Constraints & decisions made

- **All three OTLP signals are accepted**, each to real storage. No signal is
  silently dropped.
- **Exposure is via Traefik at `otlp.thefipster.de`, TLS-terminated by the
  wildcard cert**, not published host ports. This reverses a phase 3 decision
  and its comment: `infra/monitoring/compose.yaml` currently states Alloy
  "deliberately has none" of the `traefik.enable` labels, which was the reason
  joining `proxy` exposed nothing. Phase 4 adds those labels deliberately; that
  comment is rewritten rather than left to mislead.
- **One hostname, path-based routing** rather than two hostnames. OTLP/HTTP and
  OTLP/gRPC share `otlp.thefipster.de` and are told apart by path (see
  Routing). One DNS record, one cert, two routers.
- **gRPC is a first-class target, not an afterthought.** The lab's future apps
  are .NET, whose OTLP exporter defaults to gRPC on 4317. An HTTP-only endpoint
  would force every app to override the protocol.
- **Tempo stores traces on the filesystem with 7-day retention** — shorter than
  logs (14d) and metrics (15d) because traces are far bulkier per unit of
  insight. Same single-binary, filesystem-backed shape as Loki.
- **Metrics and logs reuse the existing write paths.** OTLP metrics bridge into
  the phase 1 `prometheus.remote_write.default`; OTLP logs bridge into the
  phase 2 `loki.write.default`. An app's metrics land in the same Prometheus as
  Traefik's, queryable side by side — no parallel storage.
- **No authentication on the endpoint** — see the dedicated section. Consistent
  with the phase 3 decision to leave Forgejo's `/metrics` open on the LAN, but a
  larger surface, and recorded as such.
- **A batch processor sits between receiver and exporters** — standard OTel
  collector practice; it bounds per-export overhead and is where future
  sampling or attribute processing would attach.
- **Retention for logs and metrics is unchanged** (14d / 15d). Only Tempo adds
  a new retention window.

## Architecture

```
  apps VM (.42)  ── OTLP/gRPC or /HTTP ──►  otlp.thefipster.de
                                                  │  (Traefik, wildcard TLS)
  infra VM (.41)                                  ▼
  ┌────────────────────────────────────────────────────────────────┐
  │  traefik ──PathPrefix(/v1/)──────────────► alloy :4318 (HTTP)   │
  │          ──PathPrefix(/opentelemetry...)─► alloy :4317 (h2c)    │
  │                                                                 │
  │  alloy:                                                         │
  │    otelcol.receiver.otlp (4317 grpc + 4318 http)               │
  │        │                                                        │
  │        ▼  otelcol.processor.batch                              │
  │        ├─ metrics ─► prometheus.remote_write.default (phase 1) │
  │        ├─ logs ────► loki.write.default            (phase 2)   │
  │        └─ traces ──► otelcol.exporter.otlp ─► tempo:4317       │
  │                                                                 │
  │  tempo ──► /opt/monitoring/tempo   (filesystem, 7d)            │
  │  grafana ──datasource──► tempo:3200                            │
  └────────────────────────────────────────────────────────────────┘
```

Everything from phases 1–3 keeps running unchanged; this adds a parallel intake
that merges into the same storage.

## Components

### `infra/monitoring/compose.yaml`

- **New `tempo` service** — `grafana/tempo` (major pin verified against the
  registry during implementation), config-file driven, data at
  `/opt/monitoring/tempo`, on `monitoring-net` only. Not routed, not published:
  only Alloy writes to it and only Grafana reads it.
- **Alloy gains `traefik.*` labels** — `traefik.enable=true` plus two routers
  (below). No new published ports; Traefik reaches Alloy over `proxy`, which it
  already shares. The phase 3 "deliberately has none" comment is replaced with
  one explaining what is now exposed and why.

### `infra/monitoring/tempo/tempo.yaml`

Single-binary Tempo: an OTLP receiver on 4317, filesystem backend under
`/tempo`, `compactor` with `block_retention: 168h` (7 days), and
`metrics_generator` left **off** (it would need its own remote-write and is
phase-5 territory). Analytics/usage reporting disabled, matching Loki.

### `infra/monitoring/alloy/config.alloy`

Appended after the existing sections:

- **`otelcol.receiver.otlp "default"`** — `grpc` endpoint `0.0.0.0:4317`,
  `http` endpoint `0.0.0.0:4318`, output wired to the batch processor.
- **`otelcol.processor.batch "default"`** — default batching, output fanned to
  the three exporters.
- **`otelcol.exporter.prometheus "default"`** → forwards to the existing
  `prometheus.remote_write.default.receiver`. (This is the OTLP-metrics →
  Prometheus bridge.)
- **`otelcol.exporter.loki "default"`** → forwards to the existing
  `loki.write.default.receiver`. (OTLP-logs → Loki bridge.)
- **`otelcol.exporter.otlp "tempo"`** — endpoint `tempo:4317`, `tls { insecure
  = true }` (in-network plaintext, same trust domain as every other
  `monitoring-net` hop).

Exact component argument names are verified against the Alloy reference during
implementation; the bridge components (`otelcol.exporter.prometheus`,
`otelcol.exporter.loki`) are confirmed to exist and to forward into the
Prometheus/Loki write components already in the file.

### `infra/monitoring/grafana/provisioning/datasources/datasources.yaml`

A third datasource: Tempo at `http://tempo:3200`, uid `tempo`. Provisioned as
code like the other two, so a rebuilt Grafana comes back wired for traces.

### Traefik routing (labels on the Alloy service)

Two routers on one host, both `entrypoints: websecure`, both under the wildcard
cert (no per-router TLS labels — the repo convention):

- **HTTP:** ``Host(`otlp.thefipster.de`) && PathPrefix(`/v1/`)`` →
  service port `4318`. Covers `/v1/traces`, `/v1/metrics`, `/v1/logs`.
- **gRPC:** ``Host(`otlp.thefipster.de`) && PathPrefix(`/opentelemetry.proto.collector.`)``
  → service port `4317`, with that service's
  `loadbalancer.server.scheme=h2c` (Traefik must speak cleartext HTTP/2 to
  Alloy's gRPC listener). All OTLP gRPC methods live under that package prefix.

Two named Traefik services on the one Alloy container (`alloy-http` port 4318,
`alloy-grpc` port 4317), since a container exposing two ports to Traefik needs
one service per port. Both point at the same Alloy container; only the target
port differs.

> **Two assumptions to verify during implementation, not assert:** that OTLP/gRPC
> methods all sit under the `/opentelemetry.proto.collector.` path prefix (true
> for the standard proto package, but confirm against the OTLP spec), and that
> Traefik's `h2c` scheme is the correct way to forward cleartext HTTP/2 to
> Alloy's gRPC listener. If either is off, the fallback is two hostnames
> (`otlp-grpc.` / `otlp-http.`) with the gRPC one routing the whole host — at
> the cost of a second DNS record.

### `scripts/init-monitoring.sh`

Add `/opt/monitoring/tempo` to the `mkdir -p`, and chown it to Tempo's runtime
UID (read from the pinned image during implementation — the other data dirs are
chowned the same way). No new secrets.

### `docs/wildcard-dns-udr.md` and DNS

A new exact host record `otlp.thefipster.de` → `192.168.1.41`, same pattern and
same reason as `grafana.` — the wildcard otherwise sends it to the apps VM.

## Authentication — none, and what that means

The endpoint takes **no authentication**. Consistent with the phase 3 choice to
leave Forgejo's `/metrics` open on the LAN, and with the same justification:
LAN-only lab, no untrusted parties, split-horizon DNS with nothing exposed to
the internet.

Recorded honestly, because this surface is larger than Forgejo's read-only
counters: **anything on the LAN can inject arbitrary metrics, logs and traces
into the lab's storage.** The blast radius is storage pollution and disk, not
code execution or data exfiltration.

Forward-auth is not an option — it would break every non-browser client, exactly
as it would for Forgejo's git/registry traffic. The realistic upgrade, if the
LAN ever stops being trusted, is a Traefik **basic-auth** middleware on the two
routers plus an `Authorization` header in each app's OTLP exporter config. The
routers are structured so adding one middleware label later is a one-line
change.

## Verification

The point of routing through Traefik is that the whole path is testable with
`curl` before any app exists — a synthetic OTLP/HTTP payload proves receiver,
processor, exporter and storage together.

- **Logs:** POST an OTLP/JSON log record to
  `https://otlp.thefipster.de/v1/logs`; find it in Grafana → Loki. A trusted
  cert on that request also proves the Traefik route and TLS.
- **Traces:** POST an OTLP/JSON span to `https://otlp.thefipster.de/v1/traces`;
  open it in Grafana's Tempo explorer by trace ID. This is the only check that
  exercises the genuinely new storage.
- **Metrics:** POST an OTLP/JSON metric to
  `https://otlp.thefipster.de/v1/metrics`; query it in Prometheus. Confirms the
  OTLP-metrics bridge reaches the same store as the phase 3 scrapes.
- **gRPC routing:** a plain `curl https://otlp.thefipster.de/opentelemetry.proto.collector.trace.v1.TraceService/Export`
  returns a gRPC-shaped error, not a 404 — which proves the gRPC router and h2c
  scheme resolve to Alloy even without a real gRPC client.
- **No regressions:** phase 1 `up`, phase 2 `{job="docker"}`, and phase 3
  service/host metrics all still return.

Local (no daemon): `docker compose config -q` on the monitoring stack, YAML
parse of `tempo.yaml` and the datasource file, and `alloy fmt` on the VM.

## Error handling

- **Tempo down:** the traces exporter retries/queues; metrics and logs are
  independent pipelines and keep flowing. Loss is bounded to traces during the
  outage.
- **A malformed OTLP payload:** rejected by the receiver with an OTLP error
  response; nothing else is affected.
- **gRPC h2c misconfigured:** the classic symptom is the HTTP route working
  while gRPC returns 502/protocol errors. The `curl` gRPC check isolates it, and
  Alloy's UI on `127.0.0.1:12345` shows receiver health.
- **Traefik down:** telemetry ingest stops, since it now depends on the proxy —
  the accepted cost of choosing the routed path over published ports. Existing
  scrapes and container-log tailing are unaffected (they don't traverse
  Traefik).
- **Wrong Tempo data-dir ownership:** Tempo crash-loops on first boot, same
  failure mode and same fix (`init-monitoring.sh` chown) as the other stores.

## Out of scope

- **Phase 5** — dashboards and alerts. The signals this phase enables are inputs
  to phase 5; none are visualised here beyond ad-hoc Explore queries.
- **Tempo's `metrics_generator`** (service graphs, span metrics) — off for now;
  it needs its own remote-write and belongs with phase 5's dashboards.
- **Trace sampling / attribute processing** — the batch processor is the only
  processing stage; tail sampling waits for real trace volume.
- **Authentication** — deliberately omitted, upgrade path documented above.
- **The apps VM's own Alloy / SDK wiring** — the app-side config lands when
  Coolify and the first app exist; this phase builds only the receiving end.
- **Retention changes for logs/metrics** — unchanged; only Tempo adds a window.
