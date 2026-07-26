# Monitoring Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scrape the Prometheus endpoints Traefik, Authentik and Forgejo already ship, and add host CPU/memory/disk metrics via Alloy's embedded unix exporter.

**Architecture:** Traefik and Forgejo each get their metrics endpoint switched on (Authentik's is already on by default). Alloy joins the `proxy` network so it can reach all three, gains three read-only host mounts for the unix exporter, and gets two new `prometheus.scrape` blocks feeding the existing `prometheus.remote_write`. Nothing about storage, retention or the phase 2 log pipeline changes.

**Tech Stack:** Grafana Alloy v1.18.0 (`prometheus.exporter.unix`), Traefik v3 (Prometheus metrics), Forgejo 11, Prometheus v3, Docker Compose.

**Spec:** [`docs/superpowers/specs/2026-07-26-monitoring-phase3-design.md`](../specs/2026-07-26-monitoring-phase3-design.md)

## Testing model (read first — this repo has no unit-test harness)

Same as phases 1–2: correctness is verified by **config validation + review**, not a test runner (see `CLAUDE.md`).

```bash
docker compose -f <file> config -q     # exits 0 on valid YAML + resolved ${VAR} interpolation
```

Works with **no Docker daemon running**. Each stack needs its guarded vars supplied; every gate step below does so with throwaway values.

**Alloy config has no daemonless validator.** If a Docker daemon is available, `alloy fmt` is a real gate; if not (it was down for phases 1–2), it runs **on the VM** and the deferral must be recorded in the commit body rather than silently skipped.

Runtime verification happens **on the infra VM** and is the checklist added to `docs/monitoring-setup.md` in Task 5.

## Verified facts (checked against upstream, do not re-litigate)

- **Traefik v3:** `--metrics.prometheus=true`; options `--metrics.prometheus.addEntryPointsLabels`, `--metrics.prometheus.addRoutersLabels`, `--metrics.prometheus.addServicesLabels`; the entryPoint option defaults to **`traefik`**. Our compose does **not** define a `traefik` entrypoint, which is why an explicit `metrics` entrypoint is created rather than relying on the default.
- **Authentik:** `AUTHENTIK_LISTEN__METRICS` defaults to `[::]:9300` and applies to **all** components, so the `server` container already serves metrics on 9300. Confirmed with the user that this deployment has no overrides. **`infra/authentik/compose.yaml` is not touched by this plan.**
- **Forgejo:** the `/metrics` endpoint is **disabled by default** and is served on the web port (3000) at `/metrics`. Enabled with the `[metrics]` `ENABLED` setting, i.e. env var `FORGEJO__metrics__ENABLED`. A `TOKEN` option exists for protecting it.
- **`prometheus.exporter.unix`:** arguments `procfs_path` (default `/proc`), `sysfs_path` (default `/sys`), `rootfs_path` (default `/`), plus `enable_collectors` / `disable_collectors`. In a container the host's filesystem, procfs and sysfs must be bind-mounted and the corresponding arguments set. **No privileged mode and no host PID namespace are required** for the default collector set.
- **Network topology (read from the compose files):** `traefik` → `proxy`; authentik `server` → `authentik-net` + `proxy` (alias `authentik-server`); `forgejo` → `forgejo-net` + `proxy`; `alloy` → `monitoring-net` **only**. This is why Alloy currently cannot reach any target.

## Global Constraints

Copied from `CLAUDE.md` and the spec; every task's requirements implicitly include these.

- **Alloy joins `proxy`; it does not join `authentik-net` or `forgejo-net`.** One shared network, not three, and `proxy` is the only one Traefik is on.
- **Nothing becomes newly exposed by joining `proxy`.** Traefik routes only containers carrying `traefik.enable` labels; Alloy has none and must not gain any.
- **`infra/authentik/compose.yaml` is untouched.** If a task seems to need an Authentik change, the assumption is wrong — re-read the verified facts.
- **Static scrape targets, not Docker discovery.** Three targets that change roughly never.
- **The `service` label convention carries forward from phase 1:** `traefik`, `authentik`, `forgejo`, `host`, alongside the existing `alloy` / `prometheus` / `loki` / `grafana`.
- **Both new scrapes feed the existing `prometheus.remote_write.default`.** Prometheus keeps no `scrape_configs` and stays at 15-day retention.
- **Host mounts are read-only**, and the host-root mount must be commented as widening what Alloy can *see* without moving the trust boundary `docker.sock` already crossed in phase 2.
- **Forgejo's `/metrics` is deliberately left open on the LAN** — the comment must say so and name both ways to close it, so a future reader knows it was a decision rather than an oversight.
- **Image pins unchanged.** This phase bumps nothing.
- **Line endings:** `.gitattributes` forces LF; `*.sh` must stay LF.

---

### Task 1: Traefik's Prometheus endpoint

**Files:**
- Modify: `infra/traefik/compose.yaml` (the `command:` list, after the access-log block)

**Interfaces:**
- Produces (consumed by Task 3): a metrics endpoint at `traefik:8082/metrics`, reachable on the `proxy` network.

- [ ] **Step 1: Add the metrics entrypoint and flags**

In `infra/traefik/compose.yaml`, immediately after the `- --accesslog.format=json` line, insert:

```yaml
      # --- metrics ---------------------------------------------------------
      # Prometheus metrics on a DEDICATED entrypoint. Traefik's default metrics
      # entryPoint is `traefik` (its internal one), which this compose never
      # defines — naming our own keeps the port explicit and unable to collide
      # with the dashboard. :8082 is reachable only on Docker networks: it is
      # not published to the host and has no router, so it is not routed
      # publicly. Alloy scrapes it over the `proxy` network.
      # The three label options are what make per-router and per-service
      # dashboards possible in phase 5.
      - --entrypoints.metrics.address=:8082
      - --metrics.prometheus=true
      - --metrics.prometheus.entryPoint=metrics
      - --metrics.prometheus.addEntryPointsLabels=true
      - --metrics.prometheus.addRoutersLabels=true
      - --metrics.prometheus.addServicesLabels=true
```

- [ ] **Step 2: Verify the compose gate is green**

```bash
cd infra/traefik
env ACME_EMAIL=a@b.c NETCUP_CUSTOMER_NUMBER=1 NETCUP_API_KEY=k NETCUP_API_PASSWORD=p \
  docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 3: Confirm all six flags survived interpolation**

```bash
cd infra/traefik
env ACME_EMAIL=a@b.c NETCUP_CUSTOMER_NUMBER=1 NETCUP_API_KEY=k NETCUP_API_PASSWORD=p \
  docker compose config | grep -E 'metrics'
```

Expected: exactly six lines — the `entrypoints.metrics.address` flag plus the five `metrics.prometheus*` flags.

- [ ] **Step 4: Confirm no port was published to the host**

```bash
grep -A6 '^    ports:' infra/traefik/compose.yaml
```

Expected: only `"80:80"` and `"443:443"`. **8082 must not appear** — it is an internal entrypoint, and publishing it would expose metrics on the LAN.

- [ ] **Step 5: Commit**

```bash
git add infra/traefik/compose.yaml
git commit -m "feat(traefik): expose Prometheus metrics on a dedicated entrypoint"
```

---

### Task 2: Forgejo's Prometheus endpoint

**Files:**
- Modify: `infra/forgejo/compose.yaml` (the `forgejo` service's `environment:`)

**Interfaces:**
- Produces (consumed by Task 3): a metrics endpoint at `forgejo:3000/metrics`, reachable on the `proxy` network.

- [ ] **Step 1: Enable metrics**

In `infra/forgejo/compose.yaml`, in the `forgejo` service's `environment:` block, after the `FORGEJO__server__DOMAIN` line, add:

```yaml
      # Prometheus metrics at /metrics, on the SAME port as the web UI (3000).
      # NOTE: that port is what Traefik publishes at git.thefipster.de, so this
      # also makes https://git.thefipster.de/metrics readable by anyone on the
      # LAN, unauthenticated. That is DELIBERATE: the endpoint serves aggregate
      # counters (repository/user/issue totals), not code or credentials, and
      # the lab is LAN-only with no untrusted users.
      # To close it later, either set FORGEJO__metrics__TOKEN (and add a
      # bearer_token to Alloy's scrape), or add a higher-priority Traefik
      # router for PathPrefix(`/metrics`) with an ipAllowList of 127.0.0.1/32.
      # Alloy scrapes forgejo:3000 DIRECTLY over the proxy network, never
      # through Traefik, so neither change affects collection.
      FORGEJO__metrics__ENABLED: "true"
```

- [ ] **Step 2: Verify the compose gate is green**

```bash
cd infra/forgejo
env FORGEJO_DB_PASSWORD=dummy DOCKER_GID=999 docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 3: Confirm the variable resolved onto the forgejo service**

```bash
cd infra/forgejo
env FORGEJO_DB_PASSWORD=dummy DOCKER_GID=999 docker compose config | grep -i 'metrics'
```

Expected: one line — `FORGEJO__metrics__ENABLED: "true"`.

- [ ] **Step 4: Commit**

```bash
git add infra/forgejo/compose.yaml
git commit -m "feat(forgejo): enable the Prometheus metrics endpoint"
```

---

### Task 3: Alloy reaches and scrapes the three services

**Files:**
- Modify: `infra/monitoring/compose.yaml` (the `alloy` service's `networks:`)
- Modify: `infra/monitoring/alloy/config.alloy` (one new scrape block)

**Interfaces:**
- Consumes (from Tasks 1–2): `traefik:8082/metrics` and `forgejo:3000/metrics`; plus `authentik-server:9300/metrics`, which needed no change.
- Produces (consumed by Task 5): `up` series labelled `service="traefik"`, `service="authentik"`, `service="forgejo"`.

- [ ] **Step 1: Put Alloy on the `proxy` network**

In `infra/monitoring/compose.yaml`, replace the `alloy` service's networks block:

```yaml
    networks:
      - monitoring-net
```

with:

```yaml
    networks:
      - monitoring-net
      # Traefik, Authentik's server and Forgejo all live on `proxy` — joining
      # it is how Alloy reaches their metrics endpoints (phase 3). Alloy's
      # phase 1 targets were all inside this stack, so this wasn't needed then.
      # Nothing becomes exposed: Traefik routes only containers carrying
      # traefik.enable labels, and Alloy deliberately has none.
      - proxy
```

- [ ] **Step 2: Add the service scrape to `infra/monitoring/alloy/config.alloy`**

Insert after the `prometheus.scrape "monitoring_stack"` block and **before** the `// --- logs ---` section:

```river

// The lab's own services. All three endpoints ship with the products: Traefik
// and Forgejo each needed one flag flipped (see their compose files), and
// Authentik's has been live all along — AUTHENTIK_LISTEN__METRICS defaults to
// :9300 on every component, so that stack needed no change at all.
// These are reachable only because Alloy joined the `proxy` network; see
// compose.yaml. Static targets on purpose: three entries that change roughly
// never don't justify a discovery convention every stack has to opt into.
prometheus.scrape "infra_services" {
  targets = [
    {"__address__" = "traefik:8082", "service" = "traefik"},
    {"__address__" = "authentik-server:9300", "service" = "authentik"},
    {"__address__" = "forgejo:3000", "service" = "forgejo"},
  ]

  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

- [ ] **Step 3: Verify the compose gate is green**

```bash
cd infra/monitoring
printf 'GRAFANA_DB_PASSWORD=dummy\nGRAFANA_ADMIN_PASSWORD=dummy\nGRAFANA_OIDC_ENABLED=false\nGRAFANA_OIDC_CLIENT_ID=\nGRAFANA_OIDC_CLIENT_SECRET=\n' > .env
docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 4: Confirm Alloy is on both networks**

```bash
cd infra/monitoring
docker compose config | python -c "
import sys,yaml
d=yaml.safe_load(sys.stdin)
print(sorted((d['services']['alloy'].get('networks') or {}).keys()))
"
```

Expected: `['monitoring-net', 'proxy']`.

If PyYAML is unavailable, use the scratchpad venv created in phase 1, or fall back to:

```bash
cd infra/monitoring && docker compose config | grep -A8 '^  alloy:' | grep -A4 'networks:'
```

- [ ] **Step 5: Confirm Alloy still has no Traefik labels**

```bash
grep -c 'traefik' infra/monitoring/alloy/config.alloy infra/monitoring/compose.yaml
```

Expected: a non-zero count in `config.alloy` (the scrape target and comments) and — checking by eye — **no `traefik.enable` label on the `alloy` service** in `compose.yaml`. Joining `proxy` must not make Alloy routable.

- [ ] **Step 6: Commit**

```bash
git add infra/monitoring/compose.yaml infra/monitoring/alloy/config.alloy
git commit -m "feat(monitoring): scrape Traefik, Authentik and Forgejo metrics"
```

---

### Task 4: Host metrics

**Files:**
- Modify: `infra/monitoring/compose.yaml` (the `alloy` service's `volumes:`)
- Modify: `infra/monitoring/alloy/config.alloy` (exporter + relabel + scrape)

**Interfaces:**
- Consumes (from Task 3): the `prometheus.remote_write.default.receiver` and the `service` label convention.
- Produces (consumed by Task 5): `node_*` series labelled `service="host"`.

- [ ] **Step 1: Add the three read-only host mounts**

In `infra/monitoring/compose.yaml`, in the `alloy` service's `volumes:` list, after the `docker.sock` line, add:

```yaml
      # Host metrics (phase 3). The unix exporter reads the HOST's procfs,
      # sysfs and root filesystem; without these it silently reports the
      # CONTAINER's view, which looks plausible and is wrong. All read-only.
      # `rslave` keeps mounts made on the host after Alloy starts visible, so a
      # newly attached disk still reports usage.
      # Scope, stated plainly: this exposes the whole host filesystem read-only
      # to Alloy. It does NOT widen the trust boundary — Alloy already holds
      # docker.sock above, which is root-equivalent and strictly more powerful
      # — but both being true at once is worth knowing.
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro,rslave
```

- [ ] **Step 2: Add the exporter, relabel and scrape to `infra/monitoring/alloy/config.alloy`**

Insert immediately after the `prometheus.scrape "infra_services"` block:

```river

// Host CPU / memory / disk / filesystem — Alloy's embedded node_exporter.
// The paths point at the read-only host mounts declared in compose.yaml. Get
// these wrong and the exporter reports the CONTAINER's view: plausible-looking
// numbers that are simply not the VM's, which is why the guide verifies disk
// figures against `df -h` rather than just checking the series exist.
// No privileged mode and no host PID namespace are needed for this collector
// set; Alloy already runs as root in-container.
prometheus.exporter.unix "host" {
  procfs_path = "/host/proc"
  sysfs_path  = "/host/sys"
  rootfs_path = "/host/root"
}

// Same `service` label convention as every other target in this file.
discovery.relabel "host" {
  targets = prometheus.exporter.unix.host.targets

  rule {
    target_label = "service"
    replacement  = "host"
  }
}

prometheus.scrape "host" {
  targets         = discovery.relabel.host.output
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.default.receiver]
}
```

- [ ] **Step 3: Verify the compose gate is green**

```bash
cd infra/monitoring && docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

If it rejects the `ro,rslave` short syntax, replace that one entry with the long form, which is equivalent:

```yaml
      - type: bind
        source: /
        target: /host/root
        read_only: true
        bind:
          propagation: rslave
```

- [ ] **Step 4: Confirm all three mounts resolved read-only**

```bash
cd infra/monitoring && docker compose config | grep -A3 '/host/'
```

Expected: three bind mounts — `/host/proc`, `/host/sys`, `/host/root` — each showing `read_only: true`.

- [ ] **Step 5: Structural check of the Alloy config**

There is no daemonless Alloy validator, so confirm delimiters balance and every component is declared:

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
print("brace balance :", "OK" if depth == 0 and not bad else "BROKEN depth=%d" % depth)
print("bracket balance:", "OK" if noc.count('[') == noc.count(']') else "BROKEN")
print("paren balance :", "OK" if noc.count('(') == noc.count(')') else "BROKEN")
for kind, label in re.findall('^([a-z_.]+) +"([a-z_]+)" *{', src, re.M):
    print("   %s %r" % (kind, label))
PY
```

Expected: three `OK` lines and **twelve** components — the eight from phases 1–2 (`prometheus.remote_write "default"`, `prometheus.exporter.self "alloy"`, `discovery.relabel "alloy_self"`, `prometheus.scrape "monitoring_stack"`, `discovery.docker "containers"`, `discovery.relabel "containers"`, `loki.source.docker "containers"`, `loki.write "default"`) plus the four added in Tasks 3–4 (`prometheus.scrape "infra_services"`, `prometheus.exporter.unix "host"`, `discovery.relabel "host"`, `prometheus.scrape "host"`). Check the printed list against those names rather than trusting the count.

- [ ] **Step 6: Run `alloy fmt` if a Docker daemon is available**

```bash
cd infra/monitoring
if docker info >/dev/null 2>&1; then
  docker run --rm -v "$(pwd)/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.18.0 fmt /c.alloy >/dev/null; echo "fmt exit=$?"
else
  echo "daemon DOWN — defer alloy fmt to the VM and say so in the commit body"
fi
```

Do **not** treat a daemon-down result as a pass.

- [ ] **Step 7: Commit**

```bash
git add infra/monitoring/compose.yaml infra/monitoring/alloy/config.alloy
git commit -m "feat(monitoring): add host metrics via the unix exporter"
```

---

### Task 5: Document phase 3

**Files:**
- Modify: `docs/monitoring-setup.md` (new Part 4 + checklist entries)
- Modify: `docs/roadmap/monitoring.md` (phase 3 marked landed)
- Modify: `README.md` (status row)
- Modify: `CLAUDE.md` (the docker.sock gotcha gains the host mounts)

**Interfaces:**
- Consumes (from Tasks 1–4): the four new `service` label values, the endpoint addresses, and the host mount paths.

- [ ] **Step 1: Add "Part 4 — Service and host metrics" to `docs/monitoring-setup.md`**

Insert after Part 3 (Querying) and before Troubleshooting, matching the guide's existing voice. Content:

**Intro.** Phase 3 turns on the Prometheus endpoints the services already ship and adds host metrics. Note that Authentik needed no change — its metrics listener defaults to `:9300` and was simply unreachable until now.

**What changes.** A table:

| Stack | Change |
|---|---|
| Traefik | a `metrics` entrypoint on `:8082` + Prometheus flags |
| Forgejo | `FORGEJO__metrics__ENABLED=true` |
| Authentik | nothing — already listening on `:9300` |
| Monitoring | Alloy joins `proxy`, gains three read-only host mounts |

**The two things worth knowing**, as blockquotes:

> **Alloy joins the `proxy` network.** It sat on `monitoring-net` alone, which
> is why it could not reach any of these endpoints. Nothing becomes exposed:
> Traefik routes only containers carrying `traefik.enable` labels, and Alloy
> has none.

> **Forgejo's `/metrics` is open on the LAN.** It is served on port 3000 — the
> same port Traefik publishes at `git.thefipster.de` — so
> `https://git.thefipster.de/metrics` is now readable by anyone on the LAN.
> That is a deliberate choice: aggregate counters only, no code or credentials,
> LAN-only lab. To close it, set `FORGEJO__metrics__TOKEN` (plus `bearer_token`
> on Alloy's scrape) or block the path with a higher-priority Traefik router.
> Alloy scrapes the container directly, so either change is invisible to it.

**Apply.** Traefik and Forgejo restart; the Traefik restart blips every routed service, so use one window:

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

**Verify** in Explore → Prometheus:

```promql
up
```

Expect `service` values `traefik`, `authentik`, `forgejo` and `host` **on top of** phase 1's `alloy`, `prometheus`, `loki`, `grafana`. Any target at 0 is unreachable — see Troubleshooting.

```promql
traefik_service_requests_total
```

Non-zero after loading any lab URL.

```promql
node_memory_MemAvailable_bytes
```

Plausible for a 10 GB VM.

Then the check that actually matters, with an explicit warning that it must be **compared**, not merely observed:

```promql
node_filesystem_avail_bytes
```

Compare against `df -h` on the VM. If the mounts or path arguments are wrong the exporter reports the *container's* filesystem — a plausible-looking number that is simply not the VM's. An empty result is easy to notice; a wrong one is not.

- [ ] **Step 2: Extend the guide's verification checklist**

Add to the existing `- [ ]` list in `docs/monitoring-setup.md`:

```markdown
- [ ] `up` returns `traefik`, `authentik`, `forgejo` and `host` alongside the phase 1 four
- [ ] `traefik_service_requests_total` is non-zero after loading a lab URL
- [ ] `node_filesystem_avail_bytes` matches `df -h` on the VM (not the container's view)
- [ ] An Authentik metric returns — proves cross-network scraping over `proxy`
- [ ] Phase 2 logs still flow (`{job="docker"}`) and phase 1's `up` series are unchanged
```

- [ ] **Step 3: Add phase 3 entries to the guide's Troubleshooting section**

```markdown
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
`docker compose exec forgejo printenv | grep -i metrics`.
```

- [ ] **Step 4: Mark phase 3 landed in `docs/roadmap/monitoring.md`**

Prefix phase 3 as phases 1 and 2 were, keeping its original text:

```markdown
3. **✅ Landed** — see [docs/monitoring-setup.md](../monitoring-setup.md).
   **Metrics** — enable the endpoints that already exist: Traefik
   (`--metrics.prometheus`), Authentik (`AUTHENTIK_LISTEN__METRICS`, :9300),
   Forgejo (`FORGEJO__metrics__ENABLED`); host + per-container via Alloy's
   embedded unix/cadvisor exporters.
   Shipped with the unix exporter only — **cadvisor was descoped**: continuous
   CPU cost and several more host mounts to answer a question `docker stats`
   already answers on demand. Authentik needed **no change at all** (`:9300` is
   the default). The enabling change the roadmap didn't foresee: Alloy had to
   join the `proxy` network, since it sat on `monitoring-net` alone.
```

- [ ] **Step 5: Update the README status row**

```markdown
| Monitoring: Grafana + Prometheus + Loki + Alloy | ✅ phases 1–3 deployed — [platform](docs/grafana-setup.md), [configuration](docs/monitoring-setup.md); dashboards + alerts next — [roadmap](docs/roadmap/monitoring.md) |
```

- [ ] **Step 6: Extend the `docker.sock` gotcha in `CLAUDE.md`**

Replace the mounted-socket bullet so the socket and the host mounts sit together:

```markdown
- **Mounted `docker.sock` is root-equivalent** and used deliberately by Dockge,
  the Forgejo runner, Traefik (read-only there) and Alloy (container discovery
  + log tailing). `:ro` is **not** a security boundary for a socket — the mount
  is read-only, the API behind it is not. Alloy additionally bind-mounts the
  host's `/proc`, `/sys` and `/` read-only for host metrics; that widens what
  it can *see* but does not move the trust boundary the socket already crossed.
  Acceptable only because this is a single-tenant box building the owner's own
  code — never extend this to untrusted/fork code.
```

- [ ] **Step 7: Verify every link in the touched docs resolves**

```bash
python - <<'PY'
import re, os
bad = 0
for f in ["README.md","CLAUDE.md","docs/monitoring-setup.md","docs/grafana-setup.md","docs/roadmap/monitoring.md"]:
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
git add docs/monitoring-setup.md docs/roadmap/monitoring.md README.md CLAUDE.md
git commit -m "docs: document monitoring phase 3"
```

---

## Self-review

**Spec coverage** — every spec section maps to a task: Traefik's endpoint → Task 1; Forgejo's endpoint and its exposure decision → Tasks 2, 5; Authentik needing nothing → recorded as a constraint and documented in Tasks 3, 5; the `proxy` network → Task 3; static targets → Task 3; the unix exporter and the host-root mount → Task 4; the label convention → Tasks 3, 4; verification → Task 5's checklist; error handling → Task 5's troubleshooting; roadmap/README/CLAUDE.md → Task 5.

**Placeholder scan** — no TBD/TODO. Every code step carries literal content. Task 4 Step 3 includes the exact long-form fallback rather than saying "fix it if it breaks". Task 5 specifies the guide addition section-by-section with the actual queries, matching how phases 1–2 were written and executed.

**Naming consistency checked across tasks:** component labels (`prometheus.scrape "infra_services"`, `prometheus.exporter.unix "host"`, `discovery.relabel "host"`, `prometheus.scrape "host"`), the `service` label values (`traefik`, `authentik`, `forgejo`, `host`), the target addresses (`traefik:8082`, `authentik-server:9300`, `forgejo:3000`), and the mount paths (`/host/proc`, `/host/sys`, `/host/root`) are identical everywhere they appear in Tasks 1–5. `discovery.relabel "host"` and `prometheus.scrape "host"` share a label across *different component types*, which is legal — the same pattern as `prometheus.remote_write "default"` and `loki.write "default"` already in the file.
