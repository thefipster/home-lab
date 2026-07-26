# Monitoring configuration (infra VM)

The [Grafana platform](grafana-setup.md) is up and both datasources are green.
This guide points it at something.

It **grows**: phase 2 (container logs) is here now; the service metrics
endpoints, OTLP intake and dashboards/alerts append as phases 3–5 land. See
[roadmap/monitoring.md](roadmap/monitoring.md) for what's coming.

## Prerequisites

[grafana-setup.md](grafana-setup.md) complete and verified — Grafana reachable
at `https://grafana.thefipster.de`, both datasources passing **Test**, and the
`up` query in Explore returning series for `alloy`, `prometheus`, `loki` and
`grafana`.

## Part 1 — Container logs

Alloy gains the Docker socket and four new components: `discovery.docker` lists
every container on the VM, `discovery.relabel` maps Docker metadata onto Loki
labels, `loki.source.docker` tails each container, and `loki.write` ships to
Loki. New containers are picked up within 15 seconds of starting.

> **This grants Alloy root-equivalent control of the VM's Docker.** The socket
> is mounted `:ro`, which matches how Traefik declares it, but that is **not**
> a security boundary — the *mount* is read-only, the *API behind it* is not.
> Anything holding that socket can start a privileged container. Dockge,
> Traefik and the Forgejo runner already hold it; phase 1 deliberately withheld
> it from Alloy until there was a capability that actually needed it. That
> capability is this one.

Apply:

```bash
cd ~/home-lab && git pull
```

```bash
cd ~/home-lab/infra/monitoring && docker compose up -d alloy
```

```bash
docker compose logs --tail=20 alloy
```

Expect no errors about the socket or the config. Then, in Grafana
**Explore → Loki**:

```logql
{job="docker"}
```

Lines should appear within seconds. Next, prove the labelling works across
stacks and not just for the monitoring one:

```logql
{compose_project="authentik"}
```

Then check nothing is silently missing:

```logql
sum by (compose_service) (count_over_time({job="docker"}[5m]))
```

One row per running service. If a service you expect is absent, it is not being
collected — see Troubleshooting.

## Part 2 — Traefik access logs

Traefik gains `--accesslog=true --accesslog.format=json`. The access log goes to
stdout, so Alloy already collects it — no change to the monitoring stack is
needed.

> **This restarts Traefik**, which briefly interrupts *every* routed service —
> Grafana, Forgejo, Dockge, Authentik. Do it in the same maintenance window as
> Part 1. Nothing is lost; connections just drop for a few seconds.

```bash
cd ~/home-lab/infra/traefik && docker compose up -d
```

Verify, after generating some traffic by loading any lab URL:

```logql
{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400
```

**Why `| __error__=""` is not optional here.** Traefik's *application* log stays
human-readable on purpose — it is what you read when ACME issuance misbehaves —
while its *access* log is JSON. Both go to the same stdout, so this one stream
carries two shapes. A bare `| json` tags every plain line with a parse error;
`| __error__=""` drops those and leaves the access-log entries.

Useful fields on those lines: `DownstreamStatus`, `RequestHost`, `RequestPath`,
`Duration`, `ServiceName`.

## Part 3 — Querying

### The four labels

Everything is labeled by exactly four things:

| Label | Example | Source |
|-------|---------|--------|
| `job` | `docker` | static, set by Alloy |
| `compose_project` | `monitoring`, `authentik`, `traefik` | the compose project name |
| `compose_service` | `grafana`, `server`, `db` | the service name inside that project |
| `container` | `monitoring-grafana-1` | the Docker container name |

**There are only four on purpose.** Labels are Loki's index, and every distinct
combination creates a stream. A label with unbounded values — a request ID, a
path, a user — multiplies streams without limit and is the standard way people
destroy a Loki install. Everything else you might want to filter on stays in
the log line and is parsed at query time, which costs nothing at ingest.

### Starters

Authentik's structured logs, parsed on read:

```logql
{compose_service="server"} | json | event != ""
```

Plain substring search across everything:

```logql
{job="docker"} |= "error"
```

Which service is loudest right now:

```logql
sum by (compose_service) (rate({job="docker"}[5m]))
```

Everything from one stack:

```logql
{compose_project="forgejo-lab"}
```

## Part 4 — Service and host metrics

Phase 3 turns on the Prometheus endpoints the services already ship, and adds
host-level metrics. Authentik needed **no change at all** — its metrics
listener defaults to `:9300` on every component and was simply unreachable
until now.

| Stack | Change |
|-------|--------|
| Traefik | a `metrics` entrypoint on `:8082` + Prometheus flags |
| Forgejo | `FORGEJO__metrics__ENABLED=true` |
| Authentik | nothing — already listening on `:9300` |
| Monitoring | Alloy joins `proxy`, gains three read-only host mounts |

> **Alloy joins the `proxy` network.** It sat on `monitoring-net` alone, which
> is why it could not reach any of these endpoints — phase 1's targets all
> happened to live inside its own stack. Nothing becomes exposed by this:
> Traefik routes only containers carrying `traefik.enable` labels, and Alloy
> has none.

> **Forgejo's `/metrics` is open on the LAN.** It is served on port 3000 — the
> same port Traefik publishes at `git.thefipster.de` — so
> `https://git.thefipster.de/metrics` is now readable by anyone on the LAN,
> unauthenticated. That is a deliberate choice: aggregate counters (repository,
> user and issue totals), no code and no credentials, on a LAN-only lab. To
> close it, set `FORGEJO__metrics__TOKEN` (plus `bearer_token` on Alloy's
> scrape), or add a higher-priority Traefik router for `PathPrefix(/metrics)`
> with an `ipAllowList` of `127.0.0.1/32`. Alloy scrapes the container
> directly, so either change is invisible to collection.

### Apply

The Traefik restart blips every routed service, so use one window.

```bash
cd ~/home-lab && git pull
```

```bash
cd ~/home-lab/infra/traefik && docker compose up -d
```

```bash
cd ~/home-lab/infra/forgejo && docker compose up -d forgejo
```

```bash
cd ~/home-lab/infra/monitoring && docker compose up -d alloy
```

### Verify

In **Explore → Prometheus**:

```promql
up
```

Expect `job` values `traefik`, `authentik`, `forgejo` and `node` (the host
exporter) **on top of** phase 1's `alloy`, `prometheus`, `loki` and `grafana`.
Any target sitting at 0 is unreachable — see Troubleshooting.

```promql
traefik_service_requests_total
```

Non-zero after loading any lab URL.

```promql
node_memory_MemAvailable_bytes
```

Plausible for a 10 GB VM.

Then the check that actually matters:

```promql
node_filesystem_avail_bytes
```

**Compare this against `df -h` on the VM — don't just confirm it returns.** If
the mounts or the path arguments are wrong, the exporter reports the
*container's* filesystem: a plausible-looking number that simply isn't the
VM's. An empty result would be obvious; a wrong one is not.

## Part 5 — OTLP ingest and traces

Phase 4 gives the lab an OpenTelemetry endpoint at `otlp.thefipster.de`. Apps
point their OTel SDK at it, and the three signals fan out: **metrics** into the
same Prometheus as the scrapes, **logs** into the same Loki as the container
logs, **traces** into a new Tempo. Two things to be clear about up front:

- **No app emits telemetry yet.** This builds and verifies the *receiving*
  end — the checks below use `curl`, not an app.
- **The endpoint takes no authentication.** Anything on the LAN can write to
  the lab's storage. That is acceptable on a LAN-only lab with no untrusted
  users, and the same reasoning as Forgejo's open `/metrics` — but it is a
  larger surface (it *writes*), so it is called out here. To close it later,
  add a Traefik basic-auth middleware to the two OTLP routers plus an
  `Authorization` header in each app's exporter config.

### Prerequisite: DNS

An exact host record `otlp.thefipster.de` → `192.168.1.41`, like `grafana.`
(the wildcard otherwise sends it to the apps VM). Verify:

```bash
nslookup otlp.thefipster.de
```

Expect `192.168.1.41`.

### Apply

```bash
cd ~/home-lab && git pull
```

```bash
scripts/init-monitoring.sh
```

```bash
cd ~/home-lab/infra/monitoring && docker compose up -d
```

`docker compose up -d` with no service argument starts the new `tempo` service
and recreates `alloy` with the OTLP config and the Traefik labels.

### Verify — synthetic payloads over HTTPS

The point of routing through Traefik is that the whole path is testable before
any app exists. Each `curl` exercises receiver → batch → exporter → storage.

**Logs:**

```bash
curl -si -X POST https://otlp.thefipster.de/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"phase4 hello"},"severityText":"INFO"}]}]}]}' | head -1
```

Expect `HTTP/2 200`. Then in Grafana → Loki, query `{service_name="otlp-smoketest"}`
(the exact label key derived from `service.name` may be `service_name` — list
labels in Explore rather than assuming).

**Traces:**

```bash
NOW=$(date +%s)000000000
curl -si -X POST https://otlp.thefipster.de/v1/traces -H 'Content-Type: application/json' -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"phase4-span","kind":1,"startTimeUnixNano":"'$NOW'","endTimeUnixNano":"'$NOW'"}]}]}]}' | head -1
```

Expect `HTTP/2 200`. Then Grafana → Tempo → search by trace ID
`5b8efff798038103d269b633813fc60c`. This is the only check that exercises the
genuinely new storage.

**Metrics:**

A metric sample carries a timestamp, and **it must be current** — Prometheus
rejects a sample dated hours in the past as out-of-order, and no recent query
range would show it anyway. Generate it live rather than hard-coding one:

```bash
NOW=$(date +%s)000000000
curl -si -X POST https://otlp.thefipster.de/v1/metrics -H 'Content-Type: application/json' -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeMetrics":[{"metrics":[{"name":"phase4_smoketest_total","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asInt":"1","timeUnixNano":"'$NOW'"}]}}]}]}]}' | head -1
```

Expect `HTTP/2 200`. Then in Prometheus, query `phase4_smoketest_total` over
the last 5 minutes.

**gRPC routing** (no gRPC client needed):

```bash
curl -si https://otlp.thefipster.de/opentelemetry.proto.collector.trace.v1.TraceService/Export | head -3
```

Expect a gRPC/HTTP2-shaped response (a `grpc-status` header, or 415/200) —
**not a 404**. That proves the gRPC router and the h2c scheme resolve to Alloy
even without a real gRPC client.

## Part 6 — Dashboards and alerts

The final piece: make the collected data visible and make failures loud. Two
provisioned dashboards and three alerts.

One correction rides along. The phase-1 `service` metric label was renamed to
the idiomatic **`job`** (and the host exporter now carries `job="node"` +
`instance="infra"`) so the community dashboards work with no editing. Redeploy
Alloy for it to take effect — old `service`-labelled series simply age out
within the 15-day retention.

### Apply

```bash
cd ~/home-lab && git pull
```

```bash
cd ~/home-lab/infra/monitoring && docker compose up -d alloy grafana
```

`alloy` picks up the `job` relabel; `grafana` loads the new dashboard and alert
provisioning.

### Dashboards

In Grafana → **Dashboards**, two appear (provisioned, read-only):

- **Node Exporter Full** — open it; the `job` and `nodename`/`instance`
  dropdowns populate (`node` / `infra`) and the panels show live CPU, RAM, disk
  and network. If the dropdowns are empty, Alloy didn't pick up the rename —
  check `up{job="node"}` in Explore.
- **Traefik Official Standalone Dashboard** — load any lab URL, then watch the
  request-rate and status-code panels move.

Both are vendored from grafana.com (Node Exporter Full #1860 rev 45, Traefik
#17346 rev 9) with their datasource UIDs rewired to ours. Updating one means
re-vendoring the JSON in the repo, not editing in the browser — provisioned
dashboards are read-only there by design.

### Alerts

In Grafana → **Alerting → Alert rules**, three rules, each `Normal`:

| Rule | Fires when | For |
|------|-----------|-----|
| `DiskAlmostFull` | root filesystem over 80% used | 15m |
| `ServiceDown` | any scrape target's `up == 0` | 5m |
| `CertExpiringSoon` | a TLS cert expires in under 21 days | 1h |

They are **UI-only** — nothing is sent anywhere yet; they show here and on
panels. To prove the path without waiting for a real disk to fill, lower
`DiskAlmostFull`'s threshold in `infra/monitoring/grafana/provisioning/alerting/rules.yaml`
below current usage, `docker compose up -d grafana`, watch it flip to `Firing`
within a minute, then revert. For real notifications later, add a contact point
and a notification policy (SMTP or a chat webhook) — one provisioning file, no
change to these rules.

## Troubleshooting

**A target shows `up == 0`.** Only that target is affected; everything else
keeps flowing. Isolate it from inside Alloy:

```bash
docker compose exec alloy wget -qO- http://traefik:8082/metrics | head -3
```

Swap in `authentik-server:9300` or `forgejo:3000` as needed. A connection
failure means Alloy isn't on `proxy` or the service isn't either; a 404 means
the endpoint wasn't enabled in that stack.

**Host metrics show container values.** The mounts and the `procfs_path` /
`sysfs_path` / `rootfs_path` arguments disagree. Compare
`node_filesystem_avail_bytes` with `df -h`.

**Forgejo `/metrics` returns 404.** The variable didn't reach the container:

```bash
docker compose exec forgejo printenv | grep -i metrics
```

**No logs at all.** Check Alloy's component health — its UI is bound to the VM's
loopback, so tunnel in as described in [grafana-setup.md](grafana-setup.md):

```bash
ssh -L 12345:127.0.0.1:12345 <infra-vm>
```

A socket permission problem shows up as an unhealthy `discovery.docker`
component. `docker compose logs alloy` carries the detail.

**Logs arrive, but with no `compose_*` labels.** Either the container was not
started by Compose (it genuinely has no compose labels), or `relabel_rules`
isn't wired. In `alloy/config.alloy`, `loki.source.docker` must receive the
**raw** `discovery.docker.containers.targets` with the rules passed separately
as `relabel_rules` — passing `discovery.relabel.containers.output` to `targets`
strips the metadata and breaks tailing.

**Duplicate lines.** Should not happen: Alloy keys its tailers on the container
ID, so a container on two networks is still tailed once. If you genuinely see
duplicates, look for a second Alloy instance rather than a config bug.

**Alloy won't load the config.**

```bash
docker run --rm -v /opt/stacks/monitoring/alloy/config.alloy:/c.alloy:ro grafana/alloy:v1.18.0 fmt /c.alloy
```

Non-zero exit means a syntax error. Component and argument mistakes appear at
startup in `docker compose logs alloy`.

**Disk filling up.** Loki retention is 14 days and the label set is bounded, so
the blast radius is disk, not cardinality. Find the loudest service with the
`count_over_time` query in Part 1, then `df -h` and
`du -sh /opt/monitoring/loki`.

**Traefik won't start after Part 2.** The two flags are additive and
independently revertible — comment them out and `docker compose up -d`.

**OTLP `curl` returns 404.** The DNS record is missing (so the request never
reached Traefik) or the router rule didn't match. HTTP payloads must POST to a
`/v1/...` path; a request to `/` won't match either router.

**OTLP `curl` returns 200 but nothing lands.** The receiver accepted it but an
exporter failed downstream. Check Alloy's UI on `127.0.0.1:12345` for an
unhealthy `otelcol.exporter.*`, and `docker compose logs alloy tempo`.

**gRPC path returns 502 while HTTP works.** The classic h2c symptom — Traefik
reached Alloy but didn't speak cleartext HTTP/2. Confirm
`traefik.http.services.alloy-grpc.loadbalancer.server.scheme: h2c` is present.

## Verification checklist

- [ ] `{job="docker"}` returns lines within seconds
- [ ] `{compose_project="authentik"}` returns — labelling works across stacks
- [ ] `sum by (compose_service) (count_over_time({job="docker"}[5m]))` lists every running service
- [ ] `{compose_service="server"} | json | event != ""` — Authentik's JSON parses at query time
- [ ] `{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400` — access logs on and structured
- [ ] Restarting Alloy causes no duplicate flood (read positions persisted)
- [ ] The phase 1 `up` metrics query still works — logs did not disturb metrics
- [ ] `up` returns `traefik`, `authentik`, `forgejo` and `node` (job label) alongside the phase 1 four
- [ ] `traefik_service_requests_total` is non-zero after loading a lab URL
- [ ] `node_filesystem_avail_bytes` matches `df -h` on the VM (not the container's view)
- [ ] An Authentik metric returns — proves cross-network scraping over `proxy`
- [ ] Phase 2 logs still flow (`{job="docker"}`) after the metrics change
- [ ] `POST /v1/logs` returns 200 and the line appears in Loki
- [ ] `POST /v1/traces` returns 200 and the trace opens in Tempo
- [ ] `POST /v1/metrics` returns 200 and the metric queries in Prometheus
- [ ] The gRPC path returns a gRPC-shaped response, not 404 (h2c routing works)
- [ ] Phases 1–3 series (`up`, `{job="docker"}`, host metrics) still return
- [ ] After redeploying Alloy, `up{job="node"}` and `up{job="traefik"}` return
- [ ] Node Exporter Full: `job`/`instance` dropdowns populate, panels show data
- [ ] Traefik dashboard: request/status panels move when a lab URL is loaded
- [ ] Alerting lists DiskAlmostFull, ServiceDown, CertExpiringSoon — all Normal
- [ ] Temporarily lowering the disk threshold flips DiskAlmostFull to Firing

## Done

That completes the monitoring build — platform, logs, metrics, traces,
dashboards and alerts. The [roadmap](roadmap/monitoring.md) is closed; further
work (external alert delivery, app-level dashboards, span metrics) attaches when
a real need appears, not before.
