# Monitoring phase 5 — dashboards and alerts

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan
**Roadmap:** [docs/roadmap/monitoring.md](../../roadmap/monitoring.md) — this
spec covers **phase 5**, the final phase; it completes the monitoring roadmap.
**Builds on:** phases 1–4 (platform, logs, metrics, OTLP), all deployed and
verified on the infra VM.

## Goal

Make the collected data visible and make failure states shout. Two pinned
community dashboards — a host dashboard and a Traefik dashboard — plus three
alerts that matter for a one-person lab: disk almost full, a service down, the
wildcard cert failing to renew.

A prerequisite correction comes first: the metric label convention.

## Constraints & decisions made

- **Scope is the roadmap's phase 5, held tight:** two dashboards, three alerts.
  The roadmap says "more than that is noise in a one-person lab", and that is
  the governing constraint — no extra panels, no extra rules.
- **The `service` label was a phase 1 mistake; rename it to `job`.** Phase 1
  invented a `service` label to tag each scrape target. It works for
  hand-written `up{service=...}` queries but is **not** the Prometheus
  convention — the ecosystem uses `job` (what kind of target) and `instance`
  (which specific one), and community dashboards assume exactly those. Rather
  than adapt each vendored dashboard to a non-standard label, correct the data
  at the source: rename `service` → `job` across the Alloy config, and add an
  explicit `instance` to host metrics. This is the idiomatic shape and makes the
  dashboards work with no per-dashboard editing. No rollback needed — it is a
  config change plus an Alloy restart; old `service`-labelled series age out
  within the 15-day retention.
- **The host exporter's job is `node`, not `host`.** Every node-exporter
  dashboard in existence expects `job="node"`; matching the convention is worth
  breaking the superficial uniformity with the other job names (which are named
  after their service). `instance="infra"` matches the VM's actual hostname.
- **Dashboards are vendored and pinned, not fetched at runtime.** The JSON lives
  in the repo, provisioned from disk. Accepted cost: these are large files no
  one reviews line by line — the trade for battle-tested, immediately-flashy
  panels. Every datasource reference is rewritten from the interactive-import
  placeholder (`${DS_PROMETHEUS}`) to the real datasource UID `prometheus`,
  because provisioned-from-disk dashboards do not resolve `__inputs`.
- **Alerts are UI-only.** Rules fire to Grafana's default contact point with no
  external delivery configured; they are visible in the Alerting UI and on
  panels. The rules are the substance; wiring a real channel (SMTP, a chat
  webhook) later is a one-file change. No new secrets, nothing to break.
- **Cert-expiry threshold is 21 days.** Traefik renews the 90-day Let's Encrypt
  wildcard at 30 days remaining, so a healthy cert never drops below ~30d.
  Alerting under 21d means renewal has been failing for over a week, with three
  weeks left to react — no false positives during the normal renewal window,
  real runway to fix.
- **No compose change.** `provisioning/` is already bind-mounted into Grafana;
  phase 5 only adds `dashboards/` and `alerting/` subfolders beside the existing
  `datasources/`.

## Architecture

```
  Grafana (provisioning/, read-only from disk)
  ├── datasources/  (phases 1, 4)  prometheus · loki · tempo
  ├── dashboards/   (phase 5)
  │     dashboards.yaml ── provider: load *.json from this folder
  │     node-exporter-full.json   queries prometheus, job="node"
  │     traefik.json              queries prometheus, Traefik labels
  └── alerting/     (phase 5)
        rules.yaml ── 3 rules, evaluate against the prometheus datasource,
                      notify the default contact point (UI-only)

  Alloy config.alloy
  └── every scrape/relabel block: label `service` → `job`
        host exporter: job="node", instance="infra"
```

## Components

### `infra/monitoring/alloy/config.alloy` — the label rename

Four blocks change, all mechanically (`target_label`/`replacement` and the
static target maps):

- `discovery.relabel "alloy_self"` — `service` → `job` (value `alloy`).
- `prometheus.scrape "monitoring_stack"` — the static target maps'
  `"service" = ...` keys become `"job" = ...` (`prometheus`, `loki`, `grafana`).
- `prometheus.scrape "infra_services"` — same, values `traefik`, `authentik`,
  `forgejo`.
- `discovery.relabel "host"` — `service=host` becomes **`job=node`**, plus a
  second rule setting `instance="infra"`.

The OTLP pipeline (phase 4) is untouched — those signals carry their own
resource attributes, not this scrape label.

### `infra/monitoring/grafana/provisioning/dashboards/dashboards.yaml`

A provider block pointing Grafana at the folder, `foldersFromFilesStructure`
off, updates allowed so a `git pull` + restart re-provisions. Standard shape.

### The two dashboard JSON files

- **`node-exporter-full.json`** — grafana.com dashboard **1860** (Node Exporter
  Full), vendored at a pinned revision. Datasource references rewired to uid
  `prometheus`. Works because host metrics now carry `job="node"` + `instance`.
- **`traefik.json`** — an established Traefik-v3-on-Prometheus community
  dashboard; the specific grafana.com ID and revision are selected and pinned
  during implementation, and its label expectations (`job`, plus the
  `entrypoint`/`router`/`service` labels enabled by phase 3's
  `addRoutersLabels` / `addServicesLabels` / `addEntryPointsLabels` flags) are
  verified before vendoring. Datasource references rewired to uid `prometheus`.

Both are provisioned read-only; edits happen in the repo, not the browser.

### `infra/monitoring/grafana/provisioning/alerting/rules.yaml`

Grafana provisioned alerting (`apiVersion: 1`, one rule group), evaluated
against the `prometheus` datasource. Three rules:

| Rule | Condition | For |
|---|---|---|
| `DiskAlmostFull` | `100 * (1 - node_filesystem_avail_bytes{job="node",fstype!~"tmpfs\|overlay\|squashfs\|ramfs"} / node_filesystem_size_bytes{job="node",fstype!~"tmpfs\|overlay\|squashfs\|ramfs"}) > 80` | 15m |
| `ServiceDown` | `up == 0` (any job) | 5m |
| `CertExpiringSoon` | `(traefik_tls_certs_not_after - time()) / 86400 < 21` | 1h |

Each rule sets `no data` and `execution error` states to sensible values
(`OK`/`Alerting` respectively — a target that vanishes is a `ServiceDown`
concern, not a rule error). The exact metric names —
`node_filesystem_avail_bytes`, `node_filesystem_size_bytes`, `up`,
`traefik_tls_certs_not_after` — are verified against the live instance during
implementation (the cert metric name especially, which varies by Traefik
version). Notification routing is left at Grafana's default policy → default
contact point; no contact point or policy is provisioned.

## Verification

Runtime, on the VM, captured as the guide's checklist:

- After redeploying Alloy, `up{job="node"}` and `up{job="traefik"}` return —
  the rename landed and nothing lost its series.
- **Node Exporter Full:** the `job`/`instance` dropdowns populate and panels
  show real CPU/RAM/disk — proves the label correction reached the dashboard.
- **Traefik dashboard:** panels show the request traffic generated in phases
  2–3 (load a lab URL to freshen it).
- **Alerting → Alert rules** lists all three, state `Normal`. Temporarily lower
  the `DiskAlmostFull` threshold below the current usage, confirm it flips to
  `Firing`, then revert — proves the rule path works end to end without waiting
  for a real disk to fill.
- No regressions: logs (`{job="docker"}`), traces (Tempo search), and the OTLP
  smoke-tests from phase 4 still succeed.

Local (no daemon): `docker compose config -q` still passes (unchanged), the two
dashboard JSONs and the two provisioning YAMLs parse, and `alloy fmt` runs on
the VM.

## Error handling

- **A dashboard panel is empty.** The datasource UID rewrite missed a
  reference, or a label the panel filters on is absent. Grafana's panel
  inspector shows the exact query; compare its labels against what Prometheus
  actually has.
- **`job` dropdown empty in #1860.** The Alloy rename didn't take or Alloy
  wasn't redeployed — `up{job="node"}` in Explore is the one-line check.
- **A rule shows `Error` not `Normal`.** Usually a metric name that doesn't
  exist on this Traefik version (cert metric) — query it in Explore and adjust.
- **Provisioning rejected at startup.** Grafana logs the offending file and
  refuses just that provider; `docker compose logs grafana` names it. A bad
  alert YAML does not take the dashboards down with it.

## Documentation changes (part of this work)

- **`docs/monitoring-setup.md`** — a new "Part 6 — Dashboards and alerts"
  (import/provision flow, the three alerts, the verification above). Separately,
  the label rename means every existing `service=` query in this guide's Part 4
  (metrics) must change to `job=` — those are the phase 3 verification queries,
  and leaving them wrong would send a reader chasing empty results.
- **`docs/roadmap/monitoring.md`** — phase 5 marked landed; add a closing note
  that the monitoring roadmap is now complete.
- **`README.md`** — status row reflects phases 1–5 (monitoring done).
- The label rename is confined to Alloy config and guide *queries*; no
  `CLAUDE.md` convention entry claimed `service`, so nothing there needs
  editing — confirm with a grep during implementation rather than assuming.

## Out of scope

- **External alert delivery** (SMTP, chat webhooks) — deliberately deferred; the
  rules land now, the channel is a later one-file addition.
- **Application/RED dashboards for the apps VM** — nothing emits app telemetry
  yet; these come when Coolify apps do.
- **Span-metrics / service graphs** (Tempo `metrics_generator`) — left off in
  phase 4, still out; it needs its own remote-write and earns its place only
  once traced apps exist.
- **Alerting on logs or traces** — metric alerts only; log/trace alerting is a
  separate effort if a real need appears.
- **More than three alerts / more than two dashboards** — the roadmap's explicit
  noise ceiling.
