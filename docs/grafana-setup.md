# Monitoring — Grafana, Prometheus, Loki, Tempo, Alloy (infra VM)

**Prerequisite:** [forgejo-setup.md](forgejo-setup.md) complete — the stack
scrapes Traefik, Authentik and Forgejo, so they should exist before you verify
collection.

One place to see the lab's metrics, logs and traces, at
**`https://grafana.thefipster.de`**, behind Traefik under the same wildcard
certificate, with login through Authentik by **OIDC**.

| Piece | Role |
|-------|------|
| **Grafana** | the single pane — dashboards, Explore, and the only routed UI here |
| **Prometheus** | metrics **storage + query only**; it never scrapes anything |
| **Loki** | log storage |
| **Tempo** | trace storage |
| **Alloy** | the **only** collector; everything flows in through it |
| **Postgres** | Grafana's database (dedicated to this stack) |

Everything ships in final form: your first start already tails every
container's logs, scrapes every service and the host, receives OTLP, and loads
the dashboards and alerts. The steps below bring it up, wire SSO, and then
verify each capability in turn.

> **Break-glass first.** Grafana's local **`admin`** login stays enabled on
> purpose — an Authentik outage must not lock you out of the very thing that
> would show you why. The password is `GRAFANA_ADMIN_PASSWORD` in
> `infra/monitoring/.env`. Never set `GF_AUTH_DISABLE_LOGIN_FORM`.

> **RAM:** this adds six containers to a VM already running Traefik, Authentik,
> Forgejo and Dockge. [proxmox-setup.md](proxmox-setup.md) provisions 10 GB for
> exactly this reason; at 4 GB an OOM kill would most likely take Authentik
> with it.

## Steps

### 1. Verify DNS

Two exact host records must point at the infra VM: `grafana.thefipster.de` and
`otlp.thefipster.de`. Both are in the registry
([dns-records.md](dns-records.md)) and already exist if you added the full set
during the DNS step.

```bash
nslookup grafana.thefipster.de
```

```bash
nslookup otlp.thefipster.de
```

Expect `192.168.1.41` for both.

> **Don't skip this.** `*.thefipster.de` resolves to the **apps VM**. Without
> an exact record the name silently points at the wrong box and you get
> Coolify's 404 — behind a perfectly valid certificate, which makes it look
> like a Traefik problem when it isn't.

### 2. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-monitoring.sh
```

It creates `/opt/monitoring/{postgres,grafana,prometheus,loki,tempo,alloy}` and
`chown`s each directory to the UID its image runs as, generates
`GRAFANA_DB_PASSWORD` and `GRAFANA_ADMIN_PASSWORD` into
`infra/monitoring/.env`, and symlinks the stack into `/opt/stacks`.

The Authentik values stay blank and `GRAFANA_OIDC_ENABLED=false` — deliberate,
so you can prove the stack works *before* SSO is in the picture.

### 3. Start the stack

```bash
cd ~/home-lab/infra/monitoring
```

```bash
docker compose up -d
```

```bash
docker compose ps
```

First start pulls roughly 1 GB of images. Expect six services, `db` healthy,
none restarting.

> **A container restart-looping on first boot is almost always ownership.**
> Each image runs as a different user — Grafana `472`, Prometheus `65534`, Loki
> and Tempo `10001`, Alloy root — and each must own its directory under
> `/opt/monitoring`. Re-running `scripts/init-monitoring.sh` sets all of them.

### 4. Verify the platform

**Grafana is served over the wildcard certificate:**

```bash
curl -sI https://grafana.thefipster.de | head -1
```

Expect `HTTP/2 302` (Grafana redirecting to `/login`). A certificate warning
here is Traefik's problem, not Grafana's — see
[traefik-setup.md](traefik-setup.md).

**Loki is alive:**

```bash
docker compose exec grafana wget -qO- http://loki:3100/ready
```

Expect `ready`. (Run this from the **grafana** container, not Loki's own — the
Loki image ships no shell utilities at all, so `docker compose exec loki wget`
fails with `executable file not found`. Loki publishes no port either, so the
check has to come from a neighbour on `monitoring-net`.)

**Alloy's components are healthy.** Its UI is bound to the VM's loopback only —
no hostname, no certificate, no route. Tunnel to it:

```bash
ssh -L 12345:127.0.0.1:12345 <infra-vm>
```

Open `http://127.0.0.1:12345` and confirm every component reports **Healthy**.
This is where you debug collection.

**In the browser**, at `https://grafana.thefipster.de`, log in as **`admin`**
with `GRAFANA_ADMIN_PASSWORD` from `.env`, then:

1. **Connections → Data sources** — Prometheus (default), Loki and Tempo are
   listed and all three pass **Test**. They are read-only because they are
   provisioned from the repo; that is correct.
2. **Explore → Prometheus**, run `up`. Expect a series per scrape target. This
   is the end-to-end proof: Alloy scraped it, remote-wrote it, Prometheus
   stored it, Grafana read it back. ([Step 6](#6-verify-what-is-collected)
   checks the full target list.)
3. **State really is in Postgres** — restart and log in again:

   ```bash
   docker compose down && docker compose up -d
   ```

   Your account and settings survive. (Metrics history survives too; it lives
   in Prometheus's bind mount.)

### 5. Join SSO (OIDC via Authentik)

Grafana has native SSO, so it joins by **OIDC**, not forward-auth — there is no
`authentik@docker` middleware on its router and nothing in `infra/authentik/`
changes. All field values are in the registry:
[sso-applications.md](sso-applications.md#grafana-oidc).

1. **Create the provider.** **Admin → Applications → Providers → Create →
   OAuth2/OpenID Provider**, per the registry. Save, then copy the **Client
   ID** and **Client Secret**.
2. **Create the application.** **Admin → Applications → Applications →
   Create** — name and slug from the registry, provider `grafana`.
3. **Bind who may use it.** On the application's **Policy / Group / User
   Bindings** tab → **Bind existing Group** → `lab-users`
   ([authentik-setup.md, step 5](authentik-setup.md#5-control-who-reaches-what)).
4. **Wire Grafana.** Set these three in `infra/monitoring/.env` (file content,
   not commands to run):

   ```ini
   GRAFANA_OIDC_ENABLED=true
   GRAFANA_OIDC_CLIENT_ID=<client id from step 1>
   GRAFANA_OIDC_CLIENT_SECRET=<client secret from step 1>
   ```

   ```bash
   docker compose up -d grafana
   ```

**Verify:** the login page now shows **Sign in with Authentik**. Click it: you
are bounced through `auth.thefipster.de` and land in Grafana as an **Admin**
(check the user menu, or **Administration** appearing in the nav).

> **Landed successfully but with no permissions?** That is the signature of
> `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH` losing its inner quotes. The
> value is JMESPath and must reach the container as `'Admin'`, quotes included
> — a bare `Admin` is a *field reference* that evaluates to nothing. Confirm:
>
> ```bash
> docker compose exec grafana printenv GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH
> ```

### 6. Verify what is collected

#### Metrics

In **Explore → Prometheus**:

```promql
up
```

Expect one series per `job`: the monitoring stack itself (`alloy`,
`prometheus`, `loki`, `grafana`, `tempo`), the infra services (`traefik`,
`authentik`, `forgejo`), and the host exporter (`node`). Any target sitting at
`0` is unreachable — see [Troubleshooting](#troubleshooting).

```promql
traefik_service_requests_total
```

Non-zero after loading any lab URL.

```promql
node_filesystem_avail_bytes
```

**Compare this against `df -h` on the VM — don't just confirm it returns.** If
the mounts or path arguments were wrong, the exporter would report the
*container's* filesystem: a plausible-looking number that simply isn't the
VM's. An empty result would be obvious; a wrong one is not.

#### Logs

In **Explore → Loki**:

```logql
{job="docker"}
```

Lines appear within seconds. New containers are picked up within 15 seconds of
starting. Then prove the labelling works across stacks, not just this one:

```logql
{compose_project="authentik"}
```

Then check nothing is silently missing — one row per running service:

```logql
sum by (compose_service) (count_over_time({job="docker"}[5m]))
```

Traefik's access log is JSON on stdout, collected like any other container's:

```logql
{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400
```

**`| __error__=""` is not optional here.** Traefik's *application* log stays
human-readable on purpose — it is what you read when ACME misbehaves — while
its *access* log is JSON. Both share one stdout, so a bare `| json` tags every
plain line with a parse error; this filter drops those. Useful fields on the
access lines: `DownstreamStatus`, `RequestHost`, `RequestPath`, `Duration`,
`ServiceName`.

#### OTLP and traces

The lab exposes an OpenTelemetry endpoint at `otlp.thefipster.de`. No app emits
telemetry yet — that is fine, this is the *receiving* end and it verifies on
its own. Each `curl` exercises receiver → batch → exporter → storage.

**Logs:**

```bash
curl -si -X POST https://otlp.thefipster.de/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"otlp hello"},"severityText":"INFO"}]}]}]}' | head -1
```

Expect `HTTP/2 200`, then query `{service_name="otlp-smoketest"}` in Explore →
Loki (list the labels rather than assuming the exact key).

**Traces:**

```bash
NOW=$(date +%s)000000000; curl -si -X POST https://otlp.thefipster.de/v1/traces -H 'Content-Type: application/json' -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"smoketest-span","kind":1,"startTimeUnixNano":"'$NOW'","endTimeUnixNano":"'$NOW'"}]}]}]}' | head -1
```

Expect `HTTP/2 200`, then search Grafana → Tempo for trace ID
`5b8efff798038103d269b633813fc60c`. This is the only check that exercises
Tempo's storage.

**Metrics** — the sample must carry a *current* timestamp: Prometheus rejects
out-of-order samples, and no recent query range would show a stale one anyway.

```bash
NOW=$(date +%s)000000000; curl -si -X POST https://otlp.thefipster.de/v1/metrics -H 'Content-Type: application/json' -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeMetrics":[{"metrics":[{"name":"otlp_smoketest_total","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asInt":"1","timeUnixNano":"'$NOW'"}]}}]}]}]}' | head -1
```

Expect `HTTP/2 200`, then query `otlp_smoketest_total` over the last 5 minutes.

**gRPC routing** (no gRPC client needed):

```bash
curl -si https://otlp.thefipster.de/opentelemetry.proto.collector.trace.v1.TraceService/Export | head -3
```

Expect a gRPC/HTTP2-shaped response (a `grpc-status` header, or 415/200) —
**not a 404**. That proves the gRPC router and the h2c scheme resolve to Alloy.

#### Dashboards and alerts

In Grafana → **Dashboards**, two appear (provisioned, read-only):

- **Node Exporter Full** — the `job` and `nodename`/`instance` dropdowns
  populate (`node` / `infra`) and the panels show live CPU, RAM, disk and
  network. Empty dropdowns mean the host exporter isn't labelled as expected —
  check `up{job="node"}`.
- **Traefik Official Standalone Dashboard** — load any lab URL, then watch the
  request-rate and status-code panels move.

In **Alerting → Alert rules**, three rules, each `Normal`:

| Rule | Fires when | For |
|------|-----------|-----|
| `DiskAlmostFull` | a real filesystem over 80% used | 15m |
| `ServiceDown` | any scrape target's `up == 0` | 5m |
| `CertExpiringSoon` | a TLS certificate expires in under 21 days | 1h |

They are **UI-only** — nothing is sent anywhere yet. To prove the path without
waiting for a disk to fill, lower `DiskAlmostFull`'s threshold in
`infra/monitoring/grafana/provisioning/alerting/rules.yaml` below current
usage, `docker compose up -d grafana`, watch it flip to `Firing` within a
minute, then revert.

### Checklist

**Platform**

- [ ] `nslookup grafana.thefipster.de` and `otlp.thefipster.de` → `192.168.1.41`
- [ ] `docker compose ps` → six services, `db` healthy, none restarting
- [ ] `curl -sI https://grafana.thefipster.de` → `HTTP/2 302`, trusted cert
- [ ] Loki `/ready` → `ready` (queried from the grafana container)
- [ ] Alloy UI via tunnel → all components Healthy
- [ ] Local `admin` login works (break-glass)
- [ ] All three datasources listed and passing **Test**
- [ ] `docker compose down && up -d` → account survives (state is in Postgres)
- [ ] **Sign in with Authentik** completes and lands an **Admin** session

**Metrics**

- [ ] `up` returns one series per job — `alloy`, `prometheus`, `loki`,
      `grafana`, `tempo`, `traefik`, `authentik`, `forgejo`, `node` — none at 0
- [ ] `traefik_service_requests_total` non-zero after loading a lab URL
- [ ] `node_filesystem_avail_bytes` matches `df -h` on the VM

**Logs**

- [ ] `{job="docker"}` returns lines within seconds
- [ ] `{compose_project="authentik"}` returns — labelling works across stacks
- [ ] `sum by (compose_service) (count_over_time({job="docker"}[5m]))` lists
      every running service
- [ ] `{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400`
      — access logs on and structured
- [ ] Restarting Alloy causes no duplicate flood (read positions persisted)

**OTLP**

- [ ] `POST /v1/logs` → 200, line appears in Loki
- [ ] `POST /v1/traces` → 200, trace opens in Tempo
- [ ] `POST /v1/metrics` → 200, metric queries in Prometheus
- [ ] The gRPC path returns a gRPC-shaped response, not 404

**Dashboards and alerts**

- [ ] Node Exporter Full: dropdowns populate, panels show data
- [ ] Traefik dashboard: panels move when a lab URL is loaded
- [ ] Three alert rules listed, all `Normal`
- [ ] Temporarily lowering the disk threshold flips `DiskAlmostFull` to
      `Firing`

## Next

That completes the infra VM. What remains is **Coolify on the apps VM** —
guide TBD, see [apps/README.md](../apps/README.md). `*.thefipster.de` already
points there, so every app it deploys gets a working HTTPS hostname with no new
DNS records.

## Troubleshooting

**`up` returns nothing / Explore is empty.** Alloy isn't writing. Check
`docker compose logs alloy` for remote-write errors, and confirm
`--web.enable-remote-write-receiver` is on Prometheus's command — without it
that endpoint 404s and metrics silently never arrive.

**Prometheus's "Targets" page is empty.** Expected. Nothing scrapes *from*
Prometheus in this design; Alloy pushes. Debug collection in Alloy's UI
instead.

**A single target shows `up == 0`.** Only that target is affected. Isolate it
from a container that sits on the same networks:

```bash
docker compose exec grafana wget -qO- http://traefik:8082/metrics | head -3
```

Swap in `authentik-server:9300` or `forgejo:3000`. A connection failure means
the service isn't on `proxy`; a 404 means the metrics endpoint wasn't enabled
in that stack.

**`wget: executable file not found` when exec-ing into a container.** Several
images here (Loki, Prometheus, Tempo) ship no shell utilities. Use the
`grafana` container as your debug shell — it is Alpine-based and sits on both
`monitoring-net` and `proxy`. Failing that, run a throwaway container on the
stack's network:

```bash
docker run --rm --network monitoring_monitoring-net alpine wget -qO- http://loki:3100/ready
```

**Host metrics show container values.** The mounts and the `procfs_path` /
`sysfs_path` / `rootfs_path` arguments disagree. Compare
`node_filesystem_avail_bytes` with `df -h`.

**Forgejo `/metrics` returns 404.** The variable didn't reach the container:

```bash
docker compose exec forgejo printenv | grep -i metrics
```

**No logs at all.** Check Alloy's component health through the tunnel; a socket
permission problem shows as an unhealthy `discovery.docker` component, and
`docker compose logs alloy` carries the detail.

**Logs arrive with no `compose_*` labels.** Either the container wasn't started
by Compose (it genuinely has no compose labels), or `relabel_rules` isn't
wired: in `alloy/config.alloy`, `loki.source.docker` must receive the **raw**
`discovery.docker.containers.targets` with the rules passed separately as
`relabel_rules`. Passing `discovery.relabel.containers.output` to `targets`
strips the metadata and breaks tailing.

**Duplicate log lines.** Should not happen — Alloy keys its tailers on the
container ID, so a container on two networks is still tailed once. If you
genuinely see duplicates, look for a second Alloy instance.

**Alloy won't start / won't load its config.** Syntax-check it:

```bash
docker run --rm -v /opt/stacks/monitoring/alloy/config.alloy:/c.alloy:ro grafana/alloy:v1.18.0 fmt /c.alloy
```

`fmt` exits non-zero on a syntax error. Component and argument mistakes appear
at startup in `docker compose logs alloy`.

**Grafana can't reach Authentik.** The token exchange is server-to-server: the
Grafana *container* resolves `auth.thefipster.de` through the router, back to
Traefik on this same VM. Check directly:

```bash
docker compose exec grafana wget -qO- -S https://auth.thefipster.de/-/health/live/ 2>&1 | head
```

**SSO button missing.** `GRAFANA_OIDC_ENABLED` is still `false`, or the
container wasn't recreated — `docker compose up -d grafana`.

**Datasource edits won't save in the UI.** Correct: they are provisioned from
`infra/monitoring/grafana/provisioning/`. Edit there and restart Grafana.

**OTLP `curl` returns 404.** The DNS record is missing (so the request never
reached Traefik) or the router rule didn't match — HTTP payloads must POST to a
`/v1/...` path.

**OTLP `curl` returns 200 but nothing lands.** The receiver accepted it but an
exporter failed downstream. Look for an unhealthy `otelcol.exporter.*` in
Alloy's UI, and check `docker compose logs alloy tempo`.

**gRPC path returns 502 while HTTP works.** The classic h2c symptom — Traefik
reached Alloy but didn't speak cleartext HTTP/2. Confirm
`traefik.http.services.alloy-grpc.loadbalancer.server.scheme: h2c` is present.

**Disk filling up.** Loki retention is 14 days and the label set is bounded, so
the blast radius is disk, not cardinality. Find the loudest service with the
`count_over_time` query above, then `df -h` and `du -sh /opt/monitoring/loki`.

## Layout on the server

| What | Where |
|------|-------|
| Compose project (this repo) | `infra/monitoring/` |
| Secrets | `infra/monitoring/.env` — gitignored, VM-only |
| Persistent data | `/opt/monitoring/{postgres,grafana,prometheus,loki,tempo,alloy}` |

Config files — `alloy/config.alloy`, `loki/loki.yaml`, `tempo/tempo.yaml`,
`prometheus/prometheus.yml`, `grafana/provisioning/` — live **in the repo** and
are bind-mounted read-only, so the repo stays the source of truth: edit,
`git pull` on the VM, restart.

Retention: Prometheus 15 days, Loki 14, Tempo 7.

## How it works

**Alloy is the only collector.** Prometheus and Loki are storage and query
only; nothing scrapes from Prometheus, which is why its Targets page is empty
by design. Alloy scrapes every service's metrics endpoint, tails every
container's logs, exports host metrics through its embedded node exporter, and
receives OTLP from apps — then pushes each signal to the right store. One
component to debug when collection breaks, and one UI (`127.0.0.1:12345`) that
shows the health of every stage.

**What each stack had to enable.** Very little, and Authentik nothing at all:

| Stack | What's on |
|-------|-----------|
| Traefik | a `metrics` entrypoint on `:8082` + Prometheus flags |
| Forgejo | `FORGEJO__metrics__ENABLED=true` |
| Authentik | nothing — already listening on `:9300` |
| Monitoring | Alloy on `proxy` + three read-only host mounts |

**Alloy sits on the `proxy` network** so it can reach those endpoints at all —
they live in other stacks. The membership exposes nothing by itself: Traefik
routes only what labels tell it to, and Alloy's only labels are the deliberate
OTLP routes.

**Logs carry exactly four labels**, on purpose:

| Label | Example | Source |
|-------|---------|--------|
| `job` | `docker` | static, set by Alloy |
| `compose_project` | `monitoring`, `authentik`, `traefik` | the compose project name |
| `compose_service` | `grafana`, `server`, `db` | the service name inside that project |
| `container` | `monitoring-grafana-1` | the Docker container name |

Labels are Loki's index, and every distinct combination creates a stream. A
label with unbounded values — a request ID, a path, a user — multiplies streams
without limit and is the standard way people destroy a Loki install. Everything
else you might filter on stays in the log line and is parsed at query time,
which costs nothing at ingest. Useful starters:

```logql
{compose_service="server"} | json | event != ""
```

```logql
{job="docker"} |= "error"
```

```logql
sum by (compose_service) (rate({job="docker"}[5m]))
```

**Metric targets use the idiomatic `job` label** (the host exporter as
`job="node"` with `instance="infra"`), which is exactly what community
dashboards assume — that is why the two vendored dashboards work unmodified.
Both come from grafana.com (Node Exporter Full #1860 rev 45, Traefik #17346 rev
9) with their datasource UIDs rewired. Updating one means re-vendoring the JSON
in the repo, not editing in the browser.

**Alloy holds `docker.sock`, and that is root-equivalent.** The mount is `:ro`,
matching how Traefik declares it, but that is **not** a security boundary: the
*mount* is read-only, the *API behind it* is not, and anything holding that
socket can start a privileged container. Dockge, Traefik and the Forgejo runner
already hold it. Alloy additionally bind-mounts the host's `/proc`, `/sys` and
`/` read-only for host metrics — that widens what it can *see* but does not
move a boundary the socket already crossed. Acceptable only because this is a
single-tenant box running its owner's own code.

**The OTLP endpoint takes no authentication.** Anything on the LAN can write to
the lab's storage. Same reasoning as Forgejo's open `/metrics`, but a larger
surface because it *writes*, so it is called out explicitly. To close it, add a
Traefik basic-auth middleware to the two OTLP routers plus an `Authorization`
header in each app's exporter config.

**Grafana uses Postgres, not SQLite**, so the whole lab has one backup story
and because `pg_dump` runs against a live database — a consistent SQLite backup
would need Grafana stopped.

**Alerts are UI-only.** Nothing is delivered anywhere yet. For real
notifications, add a contact point and a notification policy (SMTP or a chat
webhook) — one provisioning file, no change to the existing rules.

The design decisions behind all of this, and the order they were built in, are
recorded in [roadmap/monitoring.md](roadmap/monitoring.md) and the dated specs
under [superpowers/specs/](superpowers/specs/).

## Next

The infra VM is complete. **Coolify on the apps VM** is what remains — see
[apps/README.md](../apps/README.md) and the
[README build order](../README.md#build-order).
