# Monitoring Phase 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the collected data visible and failures loud — two pinned community dashboards (host + Traefik) and three UI-only alerts (disk almost full, service down, cert failing to renew), on top of a metric-label correction that makes the dashboards work natively.

**Architecture:** Rename the phase-1 `service` metric label to the idiomatic `job` across the Alloy config (host exporter becomes `job="node"` + `instance="infra"`), then provision two vendored Grafana dashboards and one alert-rules file into the already-mounted `provisioning/` tree. No compose change.

**Tech Stack:** Grafana 13.1 (provisioned dashboards + unified alerting), Grafana Alloy v1.18.0, Prometheus v3, Node Exporter Full (#1860), Traefik Official Standalone dashboard (#17346).

**Spec:** [`docs/superpowers/specs/2026-07-26-monitoring-phase5-design.md`](../specs/2026-07-26-monitoring-phase5-design.md)

## Testing model (read first — this repo has no unit-test harness)

Config validation + review, as every prior phase. `docker compose config -q` is unchanged here (no compose edit) but still run as a regression check. YAML and JSON files are parsed with Python (`json` is stdlib; PyYAML via the scratchpad venv from phase 1). Alloy config gets the structural brace/paren check and `alloy fmt` on the VM. **The real proof is on the VM**: dashboards render with data, alert rules load and show `Normal`. That is the guide's checklist (Task 4).

## Verified facts (checked against upstream, do not re-litigate)

- **Traefik cert metric:** `traefik_tls_certs_not_after` (Gauge, Unix-seconds expiry) — Traefik v3 metrics reference.
- **Traefik request metrics** (fed by phase 3's label flags): `traefik_service_requests_total`, `traefik_entrypoint_requests_total`, `traefik_router_requests_total`.
- **Dashboard #1860 "Node Exporter Full", latest revision 45** (468 KB). References the datasource via a template variable `${ds_prometheus}` (lowercase); **no `__inputs`**. Needs host metrics to carry `job` + `instance` (its variables are `label_values(node_uname_info, job)` then `…{job="$job"}, instance`).
- **Dashboard #17346 "Traefik Official Standalone Dashboard", latest revision 9** (43 KB). References the datasource via `${DS_PROMETHEUS}` (uppercase) **and** carries an `__inputs` block. Filters by `service`/`entrypoint` labels (enabled in phase 3), not by `job`.
- **The datasource-rewrite transform is verified** to leave zero placeholders in both files: replace `${ds_prometheus}` and `${DS_PROMETHEUS}` with the literal `prometheus`, then drop `__inputs`/`__requires`.
- **Our Prometheus datasource uid is `prometheus`** and it is `isDefault: true`.
- **`service` label locations in the Alloy config** (phase 1 & 3): `discovery.relabel "alloy_self"` (target_label), `prometheus.scrape "monitoring_stack"` (3 static-target map keys), `prometheus.scrape "infra_services"` (3 static-target map keys), `discovery.relabel "host"` (target_label). Eight occurrences.
- **`compose_service` is a DIFFERENT label** — a Loki *log* stream label from phase 2. It must **not** be renamed. Only the metric `service` label changes.

## Global Constraints

Copied from `CLAUDE.md` and the spec; every task's requirements implicitly include these.

- **Rename the metric label `service` → `job`; never touch `compose_service`.** The log label stays exactly as it is.
- **Host exporter is `job="node"` + `instance="infra"`** — the node-exporter convention, matching the VM's hostname.
- **Dashboards are vendored + pinned**: #1860 rev 45, #17346 rev 9, datasource references rewritten to uid `prometheus`, provisioned read-only.
- **Alerts are UI-only**: rules only, no contact point or notification policy provisioned; they use Grafana's default policy.
- **Cert threshold is 21 days**; disk is 80%; service-down is `up == 0`.
- **No compose change** — `provisioning/` is already mounted; only new files under `dashboards/` and `alerting/`.
- **Scope ceiling:** exactly two dashboards and three alerts.
- **Line endings:** LF. JSON files may be large; that is expected for vendored dashboards.

---

### Task 1: Rename the `service` metric label to `job`

**Files:**
- Modify: `infra/monitoring/alloy/config.alloy`
- Modify: `docs/grafana-setup.md` (phase 1 metric verification query)
- Modify: `docs/monitoring-setup.md` (any metric `service=` query / "host" service value)

**Interfaces:**
- Produces (consumed by Tasks 2, 3): metric series labelled `job` (values `alloy`, `prometheus`, `loki`, `grafana`, `traefik`, `authentik`, `forgejo`, `node`) and `instance="infra"` on node metrics.

- [ ] **Step 1: Rename the four Alloy blocks**

In `infra/monitoring/alloy/config.alloy`:

In `discovery.relabel "alloy_self"`, change `target_label = "service"` to `target_label = "job"`.

In `prometheus.scrape "monitoring_stack"`, change the three static-target keys:

```river
      {"__address__" = "prometheus:9090", "job" = "prometheus"},
      {"__address__" = "loki:3100", "job" = "loki"},
      {"__address__" = "grafana:3000", "job" = "grafana"},
```

In `prometheus.scrape "infra_services"`, change the three static-target keys:

```river
    {"__address__" = "traefik:8082", "job" = "traefik"},
    {"__address__" = "authentik-server:9300", "job" = "authentik"},
    {"__address__" = "forgejo:3000", "job" = "forgejo"},
```

In `discovery.relabel "host"`, replace the single rule with two — the job becomes `node`, and an explicit instance is added:

```river
discovery.relabel "host" {
  targets = prometheus.exporter.unix.host.targets

  // node-exporter convention: dashboards expect job="node".
  rule {
    target_label = "job"
    replacement  = "node"
  }
  // Host identity for the dashboard's instance dropdown; matches the hostname.
  rule {
    target_label = "instance"
    replacement  = "infra"
  }
}
```

- [ ] **Step 2: Confirm no metric `service` label remains, and `compose_service` is untouched**

```bash
grep -n '"service"\|target_label = "service"' infra/monitoring/alloy/config.alloy
grep -c 'compose_service' infra/monitoring/alloy/config.alloy
```

Expected: first grep **no output** (no metric `service` left); second grep **0** (the Alloy metrics config never had `compose_service` — that lives in the loki source, unaffected). If the first prints anything, a rename was missed.

- [ ] **Step 3: Structural check + gate**

```bash
cd infra/monitoring
python - <<'PY'
import re
src=open('alloy/config.alloy',encoding='utf-8').read()
noc=re.sub('//.*','',src); noc=re.sub('"[^"]*"','""',noc)
d=0;bad=False
for c in noc:
    d+= c=='{'; d-= c=='}'
    bad|= d<0
print("braces:", "OK" if d==0 and not bad else "BROKEN")
print("job labels present:", sorted(set(re.findall(r'"job" = "([a-z]+)"',src))))
print("host relabels:", [m for m in re.findall(r'target_label = "(\w+)"',src)])
PY
printf 'GRAFANA_DB_PASSWORD=d\nGRAFANA_ADMIN_PASSWORD=d\nGRAFANA_OIDC_ENABLED=false\nGRAFANA_OIDC_CLIENT_ID=\nGRAFANA_OIDC_CLIENT_SECRET=\n' > .env
docker compose config -q; echo "gate exit=$?"; rm -f .env
```

Expected: `braces: OK`; job labels include `traefik authentik forgejo prometheus loki grafana`; `target_label` list includes `job`, `job`, `instance` (alloy_self + host's two); gate exit 0.

- [ ] **Step 4: Fix the metric `service=` queries in the guides**

Find every metric-label `service=` in the docs (NOT `compose_service`, which is a log label):

```bash
grep -rn 'service="' docs/grafana-setup.md docs/monitoring-setup.md | grep -v compose_service
```

`docs/grafana-setup.md` has (phase 1 verification): `Expect one series each for service="alloy", "prometheus", "loki" and …`. Change to `job="alloy", "prometheus", "loki"`.

In `docs/monitoring-setup.md` Part 4, the phase-3 metric checks refer to host as a `service` value and list `service` targets in prose. Update: the `up` result values become `job="traefik"`, `"authentik"`, `"forgejo"` and **`"node"`** (not `host`); and the checklist line "`up` returns `traefik`, `authentik`, `forgejo` and `host`" becomes "… and `node` (job label)". Leave every `compose_service` / `compose_project` line unchanged — those are log labels.

- [ ] **Step 5: Verify no metric `service=` query remains in docs**

```bash
grep -rn 'service="' docs/grafana-setup.md docs/monitoring-setup.md | grep -v compose_service
```

Expected: **no output**.

- [ ] **Step 6: Commit**

```bash
git add infra/monitoring/alloy/config.alloy docs/grafana-setup.md docs/monitoring-setup.md
git commit -m "refactor(monitoring): rename the 'service' metric label to 'job'"
```

---

### Task 2: The two dashboards

**Files:**
- Create: `infra/monitoring/grafana/provisioning/dashboards/dashboards.yaml`
- Create: `infra/monitoring/grafana/provisioning/dashboards/node-exporter-full.json`
- Create: `infra/monitoring/grafana/provisioning/dashboards/traefik.json`

**Interfaces:**
- Consumes (from Task 1): host metrics with `job="node"` + `instance`; Traefik metrics with `service`/`entrypoint` labels.
- Consumes (from phase 1): datasource uid `prometheus`.

- [ ] **Step 1: Create the provider config**

`infra/monitoring/grafana/provisioning/dashboards/dashboards.yaml`:

```yaml
# Loads every dashboard JSON in this folder. Provisioned dashboards are
# READ-ONLY in the UI — edit the JSON in the repo and restart, not the browser.
#
# The JSONs are VENDORED from grafana.com at pinned revisions and their
# datasource references rewired to our uid `prometheus`:
#   node-exporter-full.json  = dashboard 1860, revision 45
#   traefik.json             = dashboard 17346 (Traefik Official Standalone), revision 9

apiVersion: 1

providers:
  - name: monitoring
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 2: Download and rewire both dashboards**

Run from the repo root. This fetches the exact pinned revisions and applies the verified transform (replace both datasource placeholders with the literal uid, drop the import-only `__inputs`/`__requires`):

```bash
python - <<'PY'
import json, urllib.request
targets = {
    1860: (45, "infra/monitoring/grafana/provisioning/dashboards/node-exporter-full.json"),
    17346: (9, "infra/monitoring/grafana/provisioning/dashboards/traefik.json"),
}
for dash_id, (rev, path) in targets.items():
    url = f"https://grafana.com/api/dashboards/{dash_id}/revisions/{rev}/download"
    raw = urllib.request.urlopen(url, timeout=60).read().decode("utf-8")
    raw = raw.replace("${ds_prometheus}", "prometheus").replace("${DS_PROMETHEUS}", "prometheus")
    d = json.loads(raw)
    d.pop("__inputs", None)
    d.pop("__requires", None)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"wrote {path}: {d.get('title')!r} (dashboard {dash_id} rev {rev})")
PY
```

Expected: two `wrote …` lines naming "Node Exporter Full" and "Traefik Official Standalone Dashboard".

- [ ] **Step 3: Verify both parse and carry no leftover datasource placeholder**

```bash
python - <<'PY'
import json, re
for p in ["infra/monitoring/grafana/provisioning/dashboards/node-exporter-full.json",
          "infra/monitoring/grafana/provisioning/dashboards/traefik.json"]:
    raw = open(p, encoding="utf-8").read()
    json.loads(raw)  # raises if invalid
    left = re.findall(r'\$\{(?:ds_prometheus|DS_PROMETHEUS)\}', raw)
    inp = '"__inputs"' in raw
    print(f"{p}: parses, leftover placeholders={len(left)}, __inputs present={inp}")
PY
```

Expected: both parse, `leftover placeholders=0`, `__inputs present=False`.

- [ ] **Step 4: Parse the provider YAML**

```bash
SP="/c/Users/felix/AppData/Local/Temp/claude/C--Users-felix-Source-home-lab/254319f7-c997-4fb2-a9c3-66e0b3fae488/scratchpad"
"$SP/venv/Scripts/python.exe" -c "import yaml; yaml.safe_load(open('infra/monitoring/grafana/provisioning/dashboards/dashboards.yaml')); print('yaml ok')"
```

Expected: `yaml ok`.

- [ ] **Step 5: Commit**

```bash
git add infra/monitoring/grafana/provisioning/dashboards
git commit -m "feat(monitoring): provision host and Traefik dashboards"
```

---

### Task 3: The three alert rules

**Files:**
- Create: `infra/monitoring/grafana/provisioning/alerting/rules.yaml`

**Interfaces:**
- Consumes (from Task 1): `up`, `node_filesystem_*{job="node"}`, `traefik_tls_certs_not_after`; datasource uid `prometheus`.

- [ ] **Step 1: Create the alert rules**

`infra/monitoring/grafana/provisioning/alerting/rules.yaml`. Each rule is an instant PromQL query (refId A) plus a threshold expression (refId C) that is the alerting condition:

```yaml
# Grafana unified alerting, provisioned. Three rules that matter for a
# one-person lab (roadmap phase 5). UI-ONLY: no contact point or notification
# policy is provisioned, so these use Grafana's default policy — they show in
# Alerting and on panels but send nothing outward. Wiring a real channel later
# is a one-file add (a contact point + a route).

apiVersion: 1

groups:
  - orgId: 1
    name: lab
    folder: Monitoring
    interval: 1m
    rules:
      # ---- disk almost full (>80% used on a real filesystem) --------------
      - uid: disk-almost-full
        title: DiskAlmostFull
        condition: C
        for: 15m
        noDataState: OK
        execErrState: Error
        labels:
          severity: warning
        annotations:
          summary: "Root filesystem on {{ $labels.instance }} is over 80% full"
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: >-
                100 * (1 - node_filesystem_avail_bytes{job="node",fstype!~"tmpfs|overlay|squashfs|ramfs"}
                / node_filesystem_size_bytes{job="node",fstype!~"tmpfs|overlay|squashfs|ramfs"})
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator: { type: gt, params: [80] }

      # ---- a scrape target is down ----------------------------------------
      - uid: service-down
        title: ServiceDown
        condition: C
        for: 5m
        noDataState: OK
        execErrState: Error
        labels:
          severity: critical
        annotations:
          summary: "Target {{ $labels.job }} ({{ $labels.instance }}) is down"
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: up
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator: { type: lt, params: [1] }

      # ---- wildcard cert failing to renew ---------------------------------
      # Traefik renews the 90-day cert at 30 days remaining, so a healthy cert
      # never drops below ~30d. Under 21d = renewal has been failing over a
      # week, 3 weeks left to fix.
      - uid: cert-expiring
        title: CertExpiringSoon
        condition: C
        for: 1h
        noDataState: OK
        execErrState: Error
        labels:
          severity: critical
        annotations:
          summary: "A TLS certificate expires in under 21 days"
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: (traefik_tls_certs_not_after - time()) / 86400
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator: { type: lt, params: [21] }
```

- [ ] **Step 2: Parse the YAML**

```bash
SP="/c/Users/felix/AppData/Local/Temp/claude/C--Users-felix-Source-home-lab/254319f7-c997-4fb2-a9c3-66e0b3fae488/scratchpad"
"$SP/venv/Scripts/python.exe" -c "import yaml; d=yaml.safe_load(open('infra/monitoring/grafana/provisioning/alerting/rules.yaml')); print('rules:', [r['title'] for r in d['groups'][0]['rules']])"
```

Expected: `rules: ['DiskAlmostFull', 'ServiceDown', 'CertExpiringSoon']`.

- [ ] **Step 3: Sanity-check each rule has a condition refId that exists in its data**

```bash
SP="/c/Users/felix/AppData/Local/Temp/claude/C--Users-felix-Source-home-lab/254319f7-c997-4fb2-a9c3-66e0b3fae488/scratchpad"
"$SP/venv/Scripts/python.exe" - <<'PY'
import yaml
d=yaml.safe_load(open('infra/monitoring/grafana/provisioning/alerting/rules.yaml'))
for r in d['groups'][0]['rules']:
    refs={x['refId'] for x in r['data']}
    ok = r['condition'] in refs
    print(r['title'], "condition", r['condition'], "in", sorted(refs), "->", "OK" if ok else "MISSING")
PY
```

Expected: three `OK` lines.

- [ ] **Step 4: Commit**

```bash
git add infra/monitoring/grafana/provisioning/alerting/rules.yaml
git commit -m "feat(monitoring): add disk, service-down and cert-expiry alerts"
```

---

### Task 4: Document phase 5

**Files:**
- Modify: `docs/monitoring-setup.md` (new Part 6 + checklist)
- Modify: `docs/roadmap/monitoring.md` (phase 5 landed; roadmap complete)
- Modify: `README.md` (status row)

**Interfaces:**
- Consumes (from Tasks 1–3): the dashboards, the alerts, the `job` label.

- [ ] **Step 1: Add "Part 6 — Dashboards and alerts" to `docs/monitoring-setup.md`**

Insert after Part 5 and before Troubleshooting, matching the guide's voice. Content:

**Intro.** Phase 5 makes the data visible: two provisioned dashboards and three alerts. Note the label correction — the phase-1 `service` metric label was renamed to the idiomatic `job` so the community dashboards work unmodified; redeploy Alloy for it to take effect.

**Apply.**

```bash
cd ~/home-lab && git pull
```

```bash
cd ~/home-lab/infra/monitoring && docker compose up -d alloy grafana
```

(`alloy` picks up the `job` relabel; `grafana` loads the new dashboard and alert provisioning.)

**Dashboards.** In Grafana → Dashboards: **Node Exporter Full** and **Traefik Official Standalone Dashboard** appear (provisioned, read-only). Open Node Exporter Full; the `job` and `nodename`/`instance` dropdowns populate (`node` / `infra`) and panels show live CPU/RAM/disk. Open the Traefik dashboard; load any lab URL and watch request/status panels move. State plainly that these are vendored from grafana.com (#1860 rev 45, #17346 rev 9) with datasource UIDs rewired — updating them means re-vendoring, not editing in the browser.

**Alerts.** In Grafana → Alerting → Alert rules: `DiskAlmostFull`, `ServiceDown`, `CertExpiringSoon`, each `Normal`. They are **UI-only** — no notification is sent anywhere yet; they show here and on panels. To prove the path without waiting for a disk to fill, edit `DiskAlmostFull`'s threshold in `rules.yaml` from `80` to a number below current usage, `docker compose up -d grafana`, watch it flip to `Firing` in a minute, then revert. To get real notifications later, add a contact point + notification policy (SMTP or a chat webhook) — one provisioning file.

**Verify** — the checklist below.

- [ ] **Step 2: Extend the guide's verification checklist**

Add to the existing `- [ ]` list in `docs/monitoring-setup.md`:

```markdown
- [ ] After redeploying Alloy, `up{job="node"}` and `up{job="traefik"}` return
- [ ] Node Exporter Full: `job`/`instance` dropdowns populate, panels show data
- [ ] Traefik dashboard: request/status panels move when a lab URL is loaded
- [ ] Alerting lists DiskAlmostFull, ServiceDown, CertExpiringSoon — all Normal
- [ ] Temporarily lowering the disk threshold flips DiskAlmostFull to Firing
```

- [ ] **Step 3: Mark phase 5 landed and the roadmap complete in `docs/roadmap/monitoring.md`**

Prefix phase 5 as the others were, keeping its original text, and add a closing line under the phase list:

```markdown
5. **✅ Landed** — see [docs/monitoring-setup.md](../monitoring-setup.md).
   **Dashboards + alerts** — a VM dashboard (CPU/RAM/disk), a Traefik
   dashboard (status codes, cert expiry), and 2–3 alerts that matter
   (disk >80 %, service down, cert not renewed). More than that is noise in
   a one-person lab.
   Shipped as two pinned community dashboards (Node Exporter Full #1860,
   Traefik Official Standalone #17346) and three UI-only alerts. Required
   renaming the phase-1 `service` metric label to the idiomatic `job` so the
   dashboards work unmodified.

**The monitoring roadmap is complete.** All five phases are deployed; further
work (external alert delivery, app-level RED dashboards, span metrics) attaches
when a real need appears, not before.
```

- [ ] **Step 4: Update the README status row**

```markdown
| Monitoring: Grafana + Prometheus + Loki + Alloy + Tempo | ✅ complete (phases 1–5) — [platform](docs/grafana-setup.md), [configuration](docs/monitoring-setup.md), [roadmap](docs/roadmap/monitoring.md) |
```

- [ ] **Step 5: Verify every link in the touched docs resolves**

```bash
python - <<'PY'
import re, os
bad=0
for f in ["README.md","docs/monitoring-setup.md","docs/roadmap/monitoring.md","docs/grafana-setup.md"]:
    for m in re.finditer(r'\[[^\]]+\]\(([^)#]+?)(?:#[^)]*)?\)', open(f,encoding='utf-8').read()):
        t=m.group(1)
        if t.startswith(('http','mailto')): continue
        p=os.path.normpath(os.path.join(os.path.dirname(f),t))
        if not os.path.exists(p): print("BROKEN",f,"->",t); bad+=1
print("link check done,",bad,"broken")
PY
```

Expected: `0 broken`.

- [ ] **Step 6: Commit**

```bash
git add docs/monitoring-setup.md docs/roadmap/monitoring.md README.md
git commit -m "docs: document monitoring phase 5 and close the roadmap"
```

---

## Self-review

**Spec coverage** — every spec section maps to a task: the `service`→`job` rename + host `job="node"`/`instance` → Task 1; the guide `service=` query fixes → Task 1 (Steps 4–5); the two vendored+rewired dashboards + provider → Task 2; the three UI-only alerts with the 21-day cert threshold → Task 3; verification → Task 4's checklist; error handling → the guide's troubleshooting (unchanged, plus the empty-panel/empty-dropdown notes in Part 6); roadmap-complete + README → Task 4. The spec's "confirm no CLAUDE.md entry claimed `service`" was checked during planning (grep found none).

**Placeholder scan** — no TBD/TODO. The dashboards are fetched by exact pinned revision (1860/45, 17346/9) with a transform proven during planning to leave zero placeholders; the alert YAML is complete, not sketched. The one genuine runtime unknown — whether Grafana's provisioned-alerting schema on 13.1 accepts this exact rule shape — is called out as VM-verified, with the "lower the threshold to force Firing" step as the end-to-end check.

**Naming consistency checked across tasks:** the label `job` and its values (`alloy`/`prometheus`/`loki`/`grafana`/`traefik`/`authentik`/`forgejo`/`node`), `instance="infra"`, the datasource uid `prometheus`, the dashboard filenames (`node-exporter-full.json`, `traefik.json`), the rule uids (`disk-almost-full`, `service-down`, `cert-expiring`) and the metric names (`node_filesystem_avail_bytes`, `node_filesystem_size_bytes`, `up`, `traefik_tls_certs_not_after`) are identical everywhere they appear in Tasks 1–4.
