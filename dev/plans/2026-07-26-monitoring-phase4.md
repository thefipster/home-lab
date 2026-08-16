# Monitoring Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the lab an OpenTelemetry ingest endpoint — Alloy receives OTLP over gRPC and HTTP through Traefik at `otlp.thefipster.de`, and fans metrics into the existing Prometheus, logs into the existing Loki, and traces into a new Tempo.

**Architecture:** A new `tempo` service (single-binary, filesystem, 7-day retention) provisioned as a third Grafana datasource. Alloy gains an OTLP receiver → batch processor → three exporters, two of which bridge into the phase 1/2 write paths. Traefik routes both OTLP protocols to Alloy over the `proxy` network it already shares (added in phase 3), distinguished by path — no published host ports.

**Tech Stack:** Grafana Alloy v1.18.0 (`otelcol.*` components), Grafana Tempo 2.9.4, Traefik v3, Prometheus v3, Loki 3, Docker Compose.

**Spec:** [`docs/superpowers/specs/2026-07-26-monitoring-phase4-design.md`](../specs/2026-07-26-monitoring-phase4-design.md)

## Testing model (read first — this repo has no unit-test harness)

Same as phases 1–3: correctness is verified by **config validation + review**, not a test runner (see `CLAUDE.md`).

```bash
docker compose -f <file> config -q     # exits 0 on valid YAML + resolved ${VAR} interpolation
```

Works with **no Docker daemon running**. The monitoring stack needs a populated `.env` (blank values trip the `${VAR:?}` guards); each gate step supplies throwaway values. YAML files are parsed with the scratchpad PyYAML venv created in phase 1 (`$SP/venv/Scripts/python.exe`), or any Python with PyYAML.

**Alloy config has no daemonless validator.** `alloy fmt` runs on the VM if the local Docker daemon is down (it has been for phases 2–3); record the deferral in the commit body rather than skipping it silently.

Runtime verification — actually POSTing OTLP and finding it in Grafana — happens **on the infra VM** and is the checklist added to `docs/monitoring-setup.md` in Task 4.

## Verified facts (checked against upstream, do not re-litigate)

- **Tempo image:** `grafana/tempo:2.9.4`. Tempo publishes **no bare-major and no major.minor tag** (`:2`, `:2.9` do not exist) — only full `X.Y.Z`. This is a **third** exception to the major-only pin policy, alongside `grafana/alloy` (same reason) and the two Grafana ones.
- **Tempo runtime UID:** `10001:10001` (read from the image config — same as Loki).
- **`otelcol.receiver.otlp`** defaults: gRPC `0.0.0.0:4317`, HTTP `0.0.0.0:4318`. Bare `grpc {}` / `http {}` blocks listen on those. Its `output` block has `metrics`, `logs`, `traces` lists.
- **`otelcol.exporter.prometheus`** — required arg `forward_to` (`list(MetricsReceiver)`); consumes via its `.input` (an `otelcol.Consumer`). Bridges OTLP metrics into a `prometheus.remote_write` receiver.
- **`otelcol.exporter.loki`** — required arg `forward_to` (`list(LogsReceiver)`); consumes via `.input`. Bridges OTLP logs into a `loki.write` receiver.
- **`otelcol.exporter.otlp`** — `client { endpoint = "tempo:4317"  tls { insecure = true } }`; consumes via `.input`. (Verbatim from the reference example, which literally uses `"tempo"` as the label.)
- **Existing Alloy write components** (from phases 1–2, in `config.alloy`): `prometheus.remote_write "default"` and `loki.write "default"`. Their receivers are `prometheus.remote_write.default.receiver` and `loki.write.default.receiver`.
- **Alloy already shares the `proxy` network** with Traefik (phase 3), so Traefik can reach it with no published port. Traefik's docker provider network is `proxy`.

## Global Constraints

Copied from `CLAUDE.md` and the spec; every task's requirements implicitly include these.

- **Metrics and logs reuse the existing write paths** — `otelcol.exporter.prometheus` forwards to `prometheus.remote_write.default.receiver`, `otelcol.exporter.loki` to `loki.write.default.receiver`. Do **not** create a second Prometheus or Loki write.
- **Routing convention:** proxied via the external `proxy` network + `traefik.*` labels, `entrypoints: websecure`, **no per-router TLS labels** (the one wildcard cert covers every websecure router).
- **One hostname, path-based:** `otlp.thefipster.de`, HTTP on `PathPrefix(/v1/)`, gRPC on `PathPrefix(/opentelemetry.proto.collector.)`. One DNS record, one cert, two routers, two named services (one per Alloy port).
- **The phase 3 "Alloy deliberately has no traefik labels" comment is now false** and must be rewritten where the labels are added — Alloy is intentionally exposed here.
- **No authentication** on the endpoint — deliberate, documented; the routers must be structured so a basic-auth middleware is a one-line add later.
- **Image pins:** `grafana/tempo:2.9.4` is a full-patch pin; note the exception in the compose comment, as done for Alloy.
- **Container UID:** Tempo runs as `10001`; `init-monitoring.sh` must chown `/opt/monitoring/tempo` to it, or Tempo crash-loops on first boot.
- **Tempo retention 7 days** (`block_retention: 168h`); logs (14d) and metrics (15d) unchanged.
- **`metrics_generator` stays off** — phase 5 territory, needs its own remote-write.
- **`.env` is gitignored**; preserve `${VAR:?}` guards. **Line endings:** LF; `*.sh` stays LF.

---

### Task 1: Tempo — trace storage and datasource

**Files:**
- Create: `infra/monitoring/tempo/tempo.yaml`
- Modify: `infra/monitoring/compose.yaml` (new `tempo` service)
- Modify: `infra/monitoring/grafana/provisioning/datasources/datasources.yaml` (Tempo datasource)
- Modify: `scripts/init-monitoring.sh` (data dir + chown)

**Interfaces:**
- Produces (consumed by Task 2): a Tempo OTLP gRPC receiver at `tempo:4317`.
- Produces (consumed by Task 4): a Tempo query API at `tempo:3200`, wired as Grafana datasource uid `tempo`.

- [ ] **Step 1: Create `infra/monitoring/tempo/tempo.yaml`**

```yaml
# Tempo — single-binary trace storage, filesystem-backed, 7-day retention.
#
# Sized for a one-person lab: no clustering, no object storage. Receives traces
# from Alloy over OTLP gRPC on 4317; Grafana queries the API on 3200. Nothing
# external talks to it — only Alloy writes, only Grafana reads.
#
# metrics_generator (service graphs / span metrics) is deliberately OFF: it
# needs its own remote_write and belongs with phase 5's dashboards.

server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317

storage:
  trace:
    backend: local
    local:
      path: /tempo/blocks
    wal:
      path: /tempo/wal

compactor:
  compaction:
    # 7 days — shorter than logs (14d) and metrics (15d): traces are far
    # bulkier per unit of insight.
    block_retention: 168h

# Don't phone home from a private lab (matches Loki's setting).
usage_report:
  reporting_enabled: false
```

- [ ] **Step 2: Add the `tempo` service to `infra/monitoring/compose.yaml`**

Insert after the `loki` service block and before the `alloy` service block:

```yaml
  # ---------------------------------------------------------------------------
  # Tempo — trace storage (phase 4). Alloy writes OTLP traces here; Grafana
  # reads them. Not routed and not published: monitoring-net only.
  # ---------------------------------------------------------------------------
  tempo:
    # FULL PATCH pin, like grafana/alloy: Tempo publishes only vX.Y.Z tags —
    # there is no `2` and no `2.9`.
    image: grafana/tempo:2.9.4
    restart: unless-stopped
    command: -config.file=/etc/tempo/tempo.yaml
    volumes:
      - ./tempo/tempo.yaml:/etc/tempo/tempo.yaml:ro
      # Image runs as UID 10001 — init-monitoring.sh chowns it.
      - /opt/monitoring/tempo:/tempo
    networks:
      - monitoring-net
```

- [ ] **Step 3: Add the Tempo datasource**

Append to `infra/monitoring/grafana/provisioning/datasources/datasources.yaml`:

```yaml

  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo:3200
```

- [ ] **Step 4: Add the Tempo data dir and chown to `scripts/init-monitoring.sh`**

In the `mkdir -p` line, add `/opt/monitoring/tempo`:

```bash
run_root mkdir -p /opt/monitoring/postgres /opt/monitoring/grafana \
  /opt/monitoring/prometheus /opt/monitoring/loki /opt/monitoring/alloy \
  /opt/monitoring/tempo
```

In the chown block, after the loki chown, add (and extend the UID comment list to include tempo):

```bash
run_root chown -R 10001:10001 /opt/monitoring/tempo
```

- [ ] **Step 5: Gate the compose file**

```bash
cd infra/monitoring
printf 'GRAFANA_DB_PASSWORD=dummy\nGRAFANA_ADMIN_PASSWORD=dummy\nGRAFANA_OIDC_ENABLED=false\nGRAFANA_OIDC_CLIENT_ID=\nGRAFANA_OIDC_CLIENT_SECRET=\n' > .env
docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 6: Parse the two YAML files**

```bash
cd infra/monitoring
SP="/c/Users/felix/AppData/Local/Temp/claude/C--Users-felix-Source-home-lab/254319f7-c997-4fb2-a9c3-66e0b3fae488/scratchpad"
for f in tempo/tempo.yaml grafana/provisioning/datasources/datasources.yaml; do
  "$SP/venv/Scripts/python.exe" -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1]))); print('yaml ok:', sys.argv[1])" "$f"
done
```

Expected: two `yaml ok:` lines. (If the venv is gone, recreate per phase 1: `python -m venv "$SP/venv" && "$SP/venv/Scripts/python.exe" -m pip install -q pyyaml`.)

- [ ] **Step 7: Confirm the datasource file now has three datasources**

```bash
grep -c '^  - name:' infra/monitoring/grafana/provisioning/datasources/datasources.yaml
```

Expected: **3**.

- [ ] **Step 8: Verify the shell script still parses and the chown UID is present**

```bash
bash -n scripts/init-monitoring.sh && grep -c '10001:10001 /opt/monitoring/tempo' scripts/init-monitoring.sh
```

Expected: exit 0, count **1**.

- [ ] **Step 9: Commit**

```bash
git add infra/monitoring/tempo infra/monitoring/compose.yaml \
  infra/monitoring/grafana/provisioning/datasources/datasources.yaml \
  scripts/init-monitoring.sh
git commit -m "feat(monitoring): add Tempo for trace storage"
```

---

### Task 2: The Alloy OTLP pipeline

**Files:**
- Modify: `infra/monitoring/alloy/config.alloy` (append the OTLP section)

**Interfaces:**
- Consumes (from Task 1): the Tempo OTLP endpoint `tempo:4317`.
- Consumes (from phases 1–2): `prometheus.remote_write.default.receiver`, `loki.write.default.receiver`.
- Produces (consumed by Task 3): OTLP listeners on Alloy `:4317` (gRPC) and `:4318` (HTTP).

- [ ] **Step 1: Append the OTLP section to `infra/monitoring/alloy/config.alloy`**

Add at the end of the file (after the logs section):

```river

// --- OTLP intake ------------------------------------------------------------
//
// Phase 4: the lab's OpenTelemetry ingest endpoint. Apps on the apps VM send
// OTLP here (through Traefik at otlp.thefipster.de — see compose.yaml). The
// three signals fan out: metrics and logs REUSE the existing write paths built
// in phases 1-2, so an app's metrics land in the same Prometheus as Traefik's
// and its logs in the same Loki as the containers'. Traces go to Tempo.

otelcol.receiver.otlp "default" {
  // Bare blocks listen on the OTLP defaults: gRPC 0.0.0.0:4317, HTTP
  // 0.0.0.0:4318. Traefik routes to these two ports (compose.yaml labels).
  grpc {}
  http {}

  output {
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

// Standard collector practice: bound per-export overhead. Also the natural
// place to attach sampling or attribute processing later.
otelcol.processor.batch "default" {
  output {
    metrics = [otelcol.exporter.prometheus.default.input]
    logs    = [otelcol.exporter.loki.default.input]
    traces  = [otelcol.exporter.otlp.tempo.input]
  }
}

// OTLP metrics -> the SAME Prometheus as every scrape (phase 1).
otelcol.exporter.prometheus "default" {
  forward_to = [prometheus.remote_write.default.receiver]
}

// OTLP logs -> the SAME Loki as the container logs (phase 2).
otelcol.exporter.loki "default" {
  forward_to = [loki.write.default.receiver]
}

// OTLP traces -> Tempo. In-network plaintext, same trust domain as every other
// monitoring-net hop.
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo:4317"
    tls {
      insecure = true
    }
  }
}
```

- [ ] **Step 2: Gate the compose file (unchanged config must still resolve the mount)**

```bash
cd infra/monitoring && docker compose config -q; echo "exit=$?"
```

Expected: **exit=0** (the `.env` from Task 1 is still present; recreate if needed).

- [ ] **Step 3: Structural check of the Alloy config**

```bash
cd infra/monitoring
python - <<'PY'
import re
src = open('alloy/config.alloy', encoding='utf-8').read()
noc = re.sub('//.*', '', src)
noc = re.sub('"[^"]*"', '""', noc)
depth = 0; bad = False
for ch in noc:
    if ch == '{': depth += 1
    elif ch == '}':
        depth -= 1
        if depth < 0: bad = True
print("brace balance  :", "OK" if depth == 0 and not bad else "BROKEN depth=%d" % depth)
print("bracket balance:", "OK" if noc.count('[') == noc.count(']') else "BROKEN")
comps = re.findall(r'^([a-z_.]+) +"([a-z_]+)" *{', src, re.M)
print("components (%d):" % len(comps))
for kind, label in comps: print("   %-28s %r" % (kind, label))
PY
```

Expected: two `OK` lines and **17** components — the twelve from phases 1–3 plus `otelcol.receiver.otlp "default"`, `otelcol.processor.batch "default"`, `otelcol.exporter.prometheus "default"`, `otelcol.exporter.loki "default"`, `otelcol.exporter.otlp "tempo"`. Confirm the five new names are present rather than trusting the count.

- [ ] **Step 4: Confirm the two bridge exporters point at the EXISTING receivers**

```bash
grep -E 'prometheus.remote_write.default.receiver|loki.write.default.receiver' infra/monitoring/alloy/config.alloy | wc -l
```

Expected: **at least 2** new references (one each), proving no second write path was created. Re-read to confirm there is still exactly one `prometheus.remote_write "default"` and one `loki.write "default"` declaration.

- [ ] **Step 5: Run `alloy fmt` if a Docker daemon is available**

```bash
cd infra/monitoring
if docker info >/dev/null 2>&1; then
  docker run --rm -v "$(pwd)/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.18.0 fmt /c.alloy >/dev/null; echo "fmt exit=$?"
else
  echo "daemon DOWN — defer alloy fmt to the VM and say so in the commit body"
fi
```

Do **not** treat a daemon-down result as a pass.

- [ ] **Step 6: Commit**

```bash
git add infra/monitoring/alloy/config.alloy
git commit -m "feat(monitoring): add the OTLP receiver and three export pipelines"
```

---

### Task 3: Traefik routing to Alloy

**Files:**
- Modify: `infra/monitoring/compose.yaml` (the `alloy` service — labels; rewrite the phase 3 networks comment)

**Interfaces:**
- Consumes (from Task 2): Alloy's OTLP listeners on `:4317` and `:4318`.
- Produces (consumed by Task 4): `https://otlp.thefipster.de/v1/*` (HTTP) and `.../opentelemetry.proto.collector.*` (gRPC).

- [ ] **Step 1: Add the Traefik labels to the `alloy` service**

The `alloy` service currently has no `labels:` block. Add one (place it alongside the existing `ports:`/`volumes:`/`networks:` keys). Two routers, two named services on the one container:

```yaml
    labels:
      # Phase 4: Alloy is now the lab's OTLP ingest endpoint, reached through
      # Traefik at otlp.thefipster.de. This is a DELIBERATE reversal of phase
      # 3, where Alloy carried no traefik labels — that was why joining `proxy`
      # then exposed nothing. It IS exposed now, on purpose.
      # One hostname, two protocols told apart by path. No per-router TLS
      # labels: the one wildcard cert covers every websecure router.
      traefik.enable: "true"
      # OTLP/HTTP -> Alloy :4318. Covers /v1/traces, /v1/metrics, /v1/logs.
      traefik.http.routers.otlp-http.rule: Host(`otlp.thefipster.de`) && PathPrefix(`/v1/`)
      traefik.http.routers.otlp-http.entrypoints: websecure
      traefik.http.routers.otlp-http.service: alloy-http
      traefik.http.services.alloy-http.loadbalancer.server.port: "4318"
      # OTLP/gRPC -> Alloy :4317. All gRPC methods live under this proto
      # package prefix. h2c: Traefik must speak cleartext HTTP/2 to Alloy's
      # gRPC listener.
      traefik.http.routers.otlp-grpc.rule: Host(`otlp.thefipster.de`) && PathPrefix(`/opentelemetry.proto.collector.`)
      traefik.http.routers.otlp-grpc.entrypoints: websecure
      traefik.http.routers.otlp-grpc.service: alloy-grpc
      traefik.http.services.alloy-grpc.loadbalancer.server.port: "4317"
      traefik.http.services.alloy-grpc.loadbalancer.server.scheme: h2c
      # No auth (LAN-only lab). To require it later, add ONE middleware label
      # (a basic-auth middleware) to each router above — see the phase 4 spec.
```

- [ ] **Step 2: Rewrite the stale phase 3 networks comment**

In the `alloy` service's `networks:` block, the phase 3 comment ends with "Alloy deliberately has none [of the traefik.enable labels]." That is now false. Replace that sentence so the comment reads:

```yaml
    networks:
      - monitoring-net
      # Traefik, Authentik's server and Forgejo all live on `proxy` — joining
      # it is how Alloy reaches their metrics endpoints (phase 3), and (phase
      # 4) how Traefik reaches Alloy's OTLP listeners without any published
      # port. See the traefik.* labels above.
      - proxy
```

- [ ] **Step 3: Gate the compose file**

```bash
cd infra/monitoring && docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 4: Confirm both services and the h2c scheme resolved**

```bash
cd infra/monitoring
docker compose config | grep -E 'otlp\.thefipster\.de|alloy-(http|grpc)|scheme|4317|4318'
```

Expected: both router rules (HTTP `PathPrefix(/v1/)`, gRPC `PathPrefix(/opentelemetry.proto.collector.)`), the two service ports 4318 and 4317, and `scheme: h2c` on `alloy-grpc`.

- [ ] **Step 5: Confirm no host port was published for OTLP**

```bash
grep -A6 '^    ports:' infra/monitoring/compose.yaml
```

Expected: still only `127.0.0.1:12345:12345`. **4317/4318 must not appear under `ports:`** — Traefik reaches them over `proxy`, and publishing them would bypass TLS.

- [ ] **Step 6: Commit**

```bash
git add infra/monitoring/compose.yaml
git commit -m "feat(monitoring): route OTLP through Traefik to Alloy"
```

---

### Task 4: DNS, guide, and repo docs

**Files:**
- Modify: `docs/wildcard-dns-udr.md` (host record)
- Modify: `docs/monitoring-setup.md` (new Part 5 + checklist)
- Modify: `docs/roadmap/monitoring.md` (phase 4 marked landed)
- Modify: `README.md` (status row)
- Modify: `CLAUDE.md` (image-pin exceptions; note OTLP exposure)

**Interfaces:**
- Consumes (from Tasks 1–3): the endpoint `otlp.thefipster.de`, the three signal paths, the Tempo datasource.

- [ ] **Step 1: Add the DNS host record**

In `docs/wildcard-dns-udr.md`, after the `grafana.thefipster.de` row:

```markdown
| `otlp.thefipster.de` | `192.168.1.41` | OpenTelemetry ingest (Alloy via Traefik) |
```

- [ ] **Step 2: Add "Part 5 — OTLP ingest and traces" to `docs/monitoring-setup.md`**

Insert after Part 4 and before Troubleshooting, matching the guide's voice. Content:

**Intro.** Phase 4 gives the lab an OpenTelemetry endpoint at `otlp.thefipster.de`. Apps point their OTel SDK at it; metrics land in the same Prometheus, logs in the same Loki, traces in a new Tempo. Note two things plainly: **no app emits telemetry yet** (this builds the receiving end, verified with `curl`), and the **endpoint takes no authentication** — anything on the LAN can write to the lab's storage; acceptable on a LAN-only lab, closable later with a Traefik basic-auth middleware.

**Prerequisites.** A DNS record: `otlp.thefipster.de` → `192.168.1.41` (Part 0-style; the wildcard otherwise points at the apps VM). Verify with `nslookup otlp.thefipster.de`.

**Apply.**

```bash
cd ~/home-lab && git pull
```

```bash
scripts/init-monitoring.sh
```

```bash
cd ~/home-lab/infra/monitoring && docker compose up -d
```

Note that `docker compose up -d` (no service arg) starts the new `tempo` service and recreates `alloy` with the new config and labels.

**Verify — synthetic payloads over HTTPS.** The whole point of routing through Traefik is that the path is testable before any app exists.

Logs:

```bash
curl -sic - -X POST https://otlp.thefipster.de/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"phase4 hello"},"severityText":"INFO"}]}]}}'
```

Expect `HTTP/2 200`. Then in Grafana → Loki: `{service_name="otlp-smoketest"}` returns the line. (The exact label key Loki assigns from `service.name` may be `service_name` or `service.name` — list labels in Explore rather than assuming.)

Traces:

```bash
curl -sic - -X POST https://otlp.thefipster.de/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"phase4-span","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000100000000"}]}]}]}'
```

Expect `HTTP/2 200`. Then Grafana → Tempo → search by that trace ID. This is the only check exercising the genuinely new storage.

Metrics:

```bash
curl -sic - -X POST https://otlp.thefipster.de/v1/metrics \
  -H 'Content-Type: application/json' \
  -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-smoketest"}}]},"scopeMetrics":[{"metrics":[{"name":"phase4_smoketest_total","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asInt":"1","timeUnixNano":"1700000000000000000"}]}}]}]}]}'
```

Expect `HTTP/2 200`. Then in Prometheus query `phase4_smoketest_total`.

gRPC routing (no gRPC client needed):

```bash
curl -si https://otlp.thefipster.de/opentelemetry.proto.collector.trace.v1.TraceService/Export | head -3
```

Expect a gRPC/HTTP2-shaped response (e.g. a `grpc-status` header or 415/200), **not a 404** — which proves the gRPC router and h2c scheme resolve to Alloy.

**No regressions.** `up` (phase 1), `{job="docker"}` (phase 2), and the phase 3 `service`/`host` series all still return.

- [ ] **Step 3: Extend the guide's verification checklist**

Add to the existing `- [ ]` list in `docs/monitoring-setup.md`:

```markdown
- [ ] `POST /v1/logs` returns 200 and the line appears in Loki
- [ ] `POST /v1/traces` returns 200 and the trace opens in Tempo
- [ ] `POST /v1/metrics` returns 200 and the metric queries in Prometheus
- [ ] The gRPC path returns a gRPC-shaped response, not 404 (h2c routing works)
- [ ] Phases 1–3 series (`up`, `{job="docker"}`, host metrics) still return
```

- [ ] **Step 4: Mark phase 4 landed in `docs/roadmap/monitoring.md`**

Prefix phase 4 as the others were, keeping its original text:

```markdown
4. **✅ Landed** — see [docs/monitoring-setup.md](../monitoring-setup.md).
   **OTLP intake** — Alloy listens on 4317/4318 for the future apps; add
   Tempo when the first app actually emits traces, not before.
   Shipped **with Tempo now** (7-day trace retention) rather than deferring it —
   a synthetic OTLP payload verifies the whole path end to end, so "no app emits
   traces yet" didn't mean untestable. Routed through Traefik at
   `otlp.thefipster.de` with TLS (not plain ports), which is why Alloy gained
   the traefik labels phase 3 said it lacked.
```

- [ ] **Step 5: Update the README status row**

```markdown
| Monitoring: Grafana + Prometheus + Loki + Alloy + Tempo | ✅ phases 1–4 deployed — [platform](docs/grafana-setup.md), [configuration](docs/monitoring-setup.md); dashboards + alerts next — [roadmap](docs/roadmap/monitoring.md) |
```

- [ ] **Step 6: Update `CLAUDE.md` — the image-pin exceptions**

The pin-policy bullet currently lists Authentik, `grafana/grafana` and `grafana/alloy` as exceptions. Add Tempo to the full-patch group:

```markdown
  `grafana/alloy` is pinned to a **full patch** (`v1.18.0`) and `grafana/tempo`
  to a **full patch** (`2.9.4`) because each publishes only `vX.Y.Z` / `X.Y.Z`
  tags. Verify against the registry before assuming a coarser tag exists.
```

(Adjust the surrounding sentence so it reads as four exceptions, not three.)

- [ ] **Step 7: Verify every link in the touched docs resolves**

```bash
python - <<'PY'
import re, os
bad = 0
for f in ["README.md","CLAUDE.md","docs/monitoring-setup.md","docs/roadmap/monitoring.md","docs/wildcard-dns-udr.md"]:
    for m in re.finditer(r'\[[^\]]+\]\(([^)#]+?)(?:#[^)]*)?\)', open(f, encoding='utf-8').read()):
        t = m.group(1)
        if t.startswith(('http','mailto')): continue
        p = os.path.normpath(os.path.join(os.path.dirname(f), t))
        if not os.path.exists(p):
            print("BROKEN %s -> %s" % (f, t)); bad += 1
print("link check done, %d broken" % bad)
PY
```

Expected: `0 broken`.

- [ ] **Step 8: Commit**

```bash
git add docs/wildcard-dns-udr.md docs/monitoring-setup.md docs/roadmap/monitoring.md README.md CLAUDE.md
git commit -m "docs: document monitoring phase 4"
```

---

## Self-review

**Spec coverage** — every spec section maps to a task: Tempo service + config + retention → Task 1; Tempo datasource → Task 1; the OTLP receiver/batch/three-exporter pipeline → Task 2; metrics/logs reusing existing write paths → Task 2 (Steps 1, 4); traces to Tempo → Task 2; Traefik routing (one host, path-based, two services, h2c) → Task 3; the phase 3 comment reversal → Task 3 (Steps 1, 2); no published ports → Task 3 (Step 5); DNS record → Task 4; no-auth documented with upgrade path → Tasks 3 (label comment) and 4 (guide); verification via synthetic payloads → Task 4; roadmap/README/CLAUDE.md and the pin exception → Task 4.

**Placeholder scan** — no TBD/TODO. Every code step carries literal content, including the three synthetic OTLP payloads in full. The one genuine unknown — the exact Loki label key derived from `service.name` — is called out inline with the resolution ("list labels in Explore rather than assuming") rather than left as a guess.

**Naming consistency checked across tasks:** component labels (`otelcol.receiver.otlp "default"`, `otelcol.processor.batch "default"`, `otelcol.exporter.prometheus "default"`, `otelcol.exporter.loki "default"`, `otelcol.exporter.otlp "tempo"`), the existing receivers they target (`prometheus.remote_write.default.receiver`, `loki.write.default.receiver`), the Traefik service names (`alloy-http`:4318, `alloy-grpc`:4317), the hostname `otlp.thefipster.de`, the Tempo target `tempo:4317` / datasource `tempo:3200`, and the image pin `grafana/tempo:2.9.4` are identical everywhere they appear in Tasks 1–4. The `otelcol.exporter.otlp` label `"tempo"` matches the verified reference example verbatim and does not collide with the `tempo` compose service name (different namespaces).
