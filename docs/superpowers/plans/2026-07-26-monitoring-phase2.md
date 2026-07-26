# Monitoring Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill Loki — Alloy discovers every container on the infra VM over the Docker API, tails its stdout labeled by compose project/service, and writes to Loki; Traefik's access log is switched on as JSON.

**Architecture:** Four components appended to the existing Alloy config (`discovery.docker` → `discovery.relabel` rules → `loki.source.docker` → `loki.write`), plus a `docker.sock` mount on Alloy and two flags on Traefik. JSON is parsed at query time in Grafana, not at ingest. The monitoring documentation splits: `grafana-setup.md` owns standing up the platform, a new `monitoring-setup.md` owns configuring what it observes.

**Tech Stack:** Grafana Alloy v1.18.0 (Alloy config language), Loki 3, Traefik v3, Docker Compose.

**Spec:** [`docs/superpowers/specs/2026-07-26-monitoring-phase2-design.md`](../specs/2026-07-26-monitoring-phase2-design.md)

## Testing model (read first — this repo has no unit-test harness)

Same as phase 1: correctness is verified by **config validation + review**, not a test runner (see `CLAUDE.md`).

```bash
docker compose -f <file> config -q     # exits 0 on valid YAML + resolved ${VAR} interpolation
```

**Verified in phase 1:** this works with **no Docker daemon running**. `infra/monitoring` needs a populated `.env` (blank values trip the `${VAR:?}` guards) and `infra/traefik` needs its netcup vars — each gate step below supplies throwaway values.

**Alloy config has no daemonless validator.** If the Docker daemon happens to be running, `alloy fmt` is a real gate:

```bash
docker run --rm -v "$PWD/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.18.0 fmt /c.alloy
```

If the daemon is down, this runs **on the VM** instead — the guide records it, and Task 1 says so explicitly rather than silently skipping.

Runtime verification (logs actually arriving in Grafana) happens **on the infra VM** and is the checklist inside the new `docs/monitoring-setup.md` (Task 4).

## Verified facts (checked against upstream, do not re-litigate)

- `loki.source.docker` arguments: `host` (req), `targets` (req), `labels` (req), `forward_to` (req), `relabel_rules` (opt, type `RelabelRules`), `refresh_interval` (opt).
- `discovery.docker` arguments: `host` (req), `port`, `refresh_interval` (default `1m`), `filter` block.
- Docker meta labels: `__meta_docker_container_id`, `__meta_docker_container_name`, `__meta_docker_container_label_<name>` — label names are **sanitized**, so `com.docker.compose.project` becomes `com_docker_compose_project`.
- `discovery.relabel` exports `rules` (type `RelabelRules`) and `output`.
- **`loki.source.docker` deduplicates by container ID.** Its reconcile keys tailers on `__meta_docker_container_id`. Two consequences: containers attached to more than one network (grafana, traefik, authentik server, forgejo) do **not** produce duplicate log streams; and the container ID **must** still be on the targets you hand it.

## Global Constraints

Copied from `CLAUDE.md` and the spec; every task's requirements implicitly include these.

- **Pass RAW targets to `loki.source.docker`, and the relabel rules separately via `relabel_rules`.** Handing it `discovery.relabel.*.output` is the intuitive-looking version and it is **wrong** — the relabelled output keeps only the four emitted labels, stripping `__meta_docker_container_id`, which the component needs to key its tailers.
- **Exactly four Loki labels:** `job`, `compose_project`, `compose_service`, `container`. No others. Labels are Loki's index; anything unbounded destroys the install.
- **No ingest-time parsing.** No `loki.process`, no structured metadata, no multiline stitching. JSON is parsed at query time with `| json`.
- **Image pins unchanged** — `grafana/alloy:v1.18.0`, `grafana/loki:3`, `traefik:v3`. This phase bumps nothing.
- **`.env` is gitignored**; preserve every `${VAR:?message}` guard.
- **Line endings:** `.gitattributes` forces LF; `*.sh` must stay LF.
- **Retention unchanged** — Loki stays at 14 days.
- **The socket is a real privilege grant.** `:ro` marks the mount read-only but the Docker API behind it stays writable — this is root-equivalent access to the VM's Docker. Every comment written about it must say so rather than implying `:ro` makes it safe.
- **Traefik's application log stays human-readable** (`--log.level=INFO`, no `--log.format`). Only the *access* log becomes JSON.

---

### Task 1: The Alloy log pipeline + Docker socket

**Files:**
- Modify: `infra/monitoring/alloy/config.alloy` (append the logs section)
- Modify: `infra/monitoring/compose.yaml` (the `alloy` service's `volumes:`)

**Interfaces:**
- Consumes (from phase 1): `loki` reachable in-network at `http://loki:3100`; Alloy's `--storage.path=/var/lib/alloy/data` bind-mounted to `/opt/monitoring/alloy`, which persists log read positions.
- Produces (consumed by Tasks 2, 4): the Loki labels `job="docker"`, `compose_project`, `compose_service`, `container` — these are the label names every query in the guide uses.

- [ ] **Step 1: Append the logs section to `infra/monitoring/alloy/config.alloy`**

Add at the end of the file, after the existing `prometheus.scrape "monitoring_stack"` block:

```river

// --- logs -------------------------------------------------------------------
//
// Phase 2: every container on this VM, discovered over the Docker API and
// labeled by its compose project/service. Metrics above are untouched.

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
  // Default is 1m; 15s means a newly started stack shows up almost at once.
  refresh_interval = "15s"
}

// Docker metadata -> the four Loki labels we keep. Docker SANITIZES label
// names, so `com.docker.compose.project` arrives as
// `com_docker_compose_project`.
//
// `targets = []` is deliberate: only the `rules` export is consumed (below),
// so evaluating the target list here as well would be pure waste. This mirrors
// the upstream example.
discovery.relabel "containers" {
  targets = []

  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    target_label  = "compose_project"
  }

  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_service"]
    target_label  = "compose_service"
  }

  // Docker prepends a slash to container names — strip it.
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/?(.*)"
    target_label  = "container"
  }
}

// NOTE the wiring: `targets` gets the RAW discovery output and the rules are
// passed SEPARATELY as `relabel_rules`. These are not interchangeable. The
// component keys its tailers on `__meta_docker_container_id` — which is also
// how it avoids double-tailing a container attached to two networks (grafana,
// traefik, authentik's server and forgejo all are) — and handing it
// `discovery.relabel.containers.output` would strip that ID along with every
// other `__meta_*` label.
loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  labels        = {"job" = "docker"}
  relabel_rules = discovery.relabel.containers.rules
  forward_to    = [loki.write.default.receiver]
}

// Read positions live under --storage.path (/opt/monitoring/alloy), so an
// Alloy restart resumes instead of re-ingesting every container's history.
loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

- [ ] **Step 2: Mount the socket on Alloy in `infra/monitoring/compose.yaml`**

In the `alloy` service's `volumes:` list, **replace** the phase 1 comment:

```yaml
      # NOTE: deliberately NO /var/run/docker.sock here. Container-log
      # discovery (phase 2) is what needs it, and a root-equivalent grant
      # should follow an actual capability, not an anticipated one.
```

with the mount and an honest explanation:

```yaml
      # Docker API — container discovery + log tailing (phase 2). Phase 1
      # deliberately left this out; the capability that needs it now exists.
      # `:ro` matches how Traefik declares it but is NOT a security boundary
      # for a socket: the MOUNT is read-only, the API behind it is not, so
      # this is root-equivalent control of this VM's Docker. Same trade as
      # Dockge, Traefik and the Forgejo runner — acceptable only because this
      # is a single-tenant box running its owner's own code.
      # Alloy runs as root in-container, so no group_add is needed (unlike the
      # Forgejo runner, which is non-root and joins the docker group by GID).
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

- [ ] **Step 3: Verify the compose gate is green**

```bash
cd infra/monitoring
printf 'GRAFANA_DB_PASSWORD=dummy\nGRAFANA_ADMIN_PASSWORD=dummy\nGRAFANA_OIDC_ENABLED=false\nGRAFANA_OIDC_CLIENT_ID=\nGRAFANA_OIDC_CLIENT_SECRET=\n' > .env
docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 4: Confirm the socket mount actually resolved**

```bash
docker compose config | grep -A2 'docker.sock'
```

Expected: a bind mount of `/var/run/docker.sock` with `read_only: true` under the `alloy` service.

- [ ] **Step 5: Syntax-check the Alloy config if a Docker daemon is available**

```bash
docker run --rm -v "$PWD/alloy/config.alloy:/c.alloy:ro" grafana/alloy:v1.18.0 fmt /c.alloy >/dev/null; echo "exit=$?"
```

Expected: **exit=0**.

If this fails with a daemon connection error (`npipe`/`docker.sock` not found), the daemon is down — **do not treat that as a pass**. Record in the commit body that the Alloy syntax gate was deferred to the VM, where the guide's troubleshooting section runs the same command.

- [ ] **Step 6: Re-read the wiring against the constraint**

Confirm by eye that `loki.source.docker` has `targets = discovery.docker.containers.targets` (raw) **and** `relabel_rules = discovery.relabel.containers.rules`. If `targets` references anything containing `.output`, it is wrong — fix before committing.

- [ ] **Step 7: Commit**

```bash
git add infra/monitoring/alloy/config.alloy infra/monitoring/compose.yaml
git commit -m "feat(monitoring): collect container logs into Loki"
```

---

### Task 2: Traefik access logs

**Files:**
- Modify: `infra/traefik/compose.yaml` (the `command:` list, after `--log.level=INFO`)

**Interfaces:**
- Consumes (from Task 1): Alloy already collects every container's stdout, so no additional collection config is needed — the access log is picked up because it goes to stdout.
- Produces (consumed by Task 4): JSON access-log lines in the `{compose_service="traefik"}` stream, with the fields the guide queries (`DownstreamStatus`, `RequestHost`, `Duration`).

- [ ] **Step 1: Add the access-log flags**

In `infra/traefik/compose.yaml`, immediately after the `- --log.level=INFO` line and its comment block, insert:

```yaml
      # --- access log ------------------------------------------------------
      # One JSON object per request, on stdout — where Alloy already collects
      # this container's logs like any other (see docs/monitoring-setup.md).
      # JSON so Grafana can parse fields at query time.
      # The APPLICATION log above stays human-readable on purpose: it's what
      # you actually read during ACME trouble. So this container's stream
      # carries TWO shapes, and a bare `| json` in LogQL will tag the plain
      # lines with __error__ — filter with `| json | __error__=""`.
      - --accesslog=true
      - --accesslog.format=json
```

- [ ] **Step 2: Verify the compose gate is green**

`infra/traefik/compose.yaml` guards its netcup credentials, so supply throwaway values:

```bash
cd infra/traefik
env ACME_EMAIL=a@b.c NETCUP_CUSTOMER_NUMBER=1 NETCUP_API_KEY=k NETCUP_API_PASSWORD=p \
  docker compose config -q; echo "exit=$?"
```

Expected: **exit=0**.

- [ ] **Step 3: Confirm both flags survived interpolation**

```bash
env ACME_EMAIL=a@b.c NETCUP_CUSTOMER_NUMBER=1 NETCUP_API_KEY=k NETCUP_API_PASSWORD=p \
  docker compose config | grep accesslog
```

Expected: exactly two lines — `--accesslog=true` and `--accesslog.format=json`.

- [ ] **Step 4: Confirm the application log was NOT changed to JSON**

```bash
grep -c '\--log.format' infra/traefik/compose.yaml
```

Expected: **0**. The application log stays human-readable — that is a deliberate decision, not an oversight.

- [ ] **Step 5: Commit**

```bash
git add infra/traefik/compose.yaml
git commit -m "feat(traefik): enable JSON access logs"
```

---

### Task 3: Rename the platform guide

**Files:**
- Rename: `docs/monitoring-setup.md` → `docs/grafana-setup.md` (via `git mv`)
- Modify: `docs/grafana-setup.md` (title + intro only)
- Modify: `README.md` (3 references), `infra/monitoring/.env.example` (2), `infra/monitoring/compose.yaml` (2), `scripts/init-monitoring.sh` (2), `docs/roadmap/monitoring.md` (1)
- Modify: `docs/superpowers/specs/2026-07-26-monitoring-phase1-design.md`, `docs/superpowers/plans/2026-07-26-monitoring-phase1.md` (one archival note each)

**Interfaces:**
- Produces (consumed by Tasks 4, 5): the path `docs/grafana-setup.md` for the platform guide, freeing `docs/monitoring-setup.md` for Task 4.

- [ ] **Step 1: Rename the file**

```bash
git mv docs/monitoring-setup.md docs/grafana-setup.md
```

- [ ] **Step 2: Retitle and re-point the intro**

Change the H1 to:

```markdown
# Grafana platform setup — Grafana, Prometheus, Loki, Alloy (infra VM)
```

and add, immediately after the existing intro table, a pointer forward:

```markdown
> **This guide stands up the platform.** Configuring what it actually watches —
> container logs, service metrics, dashboards — is
> [monitoring-setup.md](monitoring-setup.md). Do this one first: it's the
> prerequisite for that one.
```

Leave the rest of the content unchanged.

- [ ] **Step 3: Update all 10 live references**

```bash
grep -rn 'monitoring-setup' README.md infra/ scripts/ docs/roadmap/
```

Rewrite each to `grafana-setup.md`, preserving surrounding wording:

| File | What to change |
|---|---|
| `README.md` layout tree | the `monitoring-setup.md` line → `grafana-setup.md   Grafana platform: stack, routing, OIDC` |
| `README.md` build order step 6 | link target → `docs/grafana-setup.md` |
| `README.md` status row | `[guide](docs/grafana-setup.md)` |
| `infra/monitoring/.env.example` | both comments → `docs/grafana-setup.md Part 3` |
| `infra/monitoring/compose.yaml` | header comment and the OIDC comment → `docs/grafana-setup.md` |
| `scripts/init-monitoring.sh` | usage header and the printed next-steps line → `docs/grafana-setup.md` |
| `docs/roadmap/monitoring.md` | phase 1 "Landed" link → `../grafana-setup.md` |

- [ ] **Step 4: Add an archival note to the phase 1 spec and plan**

Do **not** rewrite their body references — they record what was built on that date. Add one line under the header of each.

In `docs/superpowers/specs/2026-07-26-monitoring-phase1-design.md`, after the `**Roadmap:**` line:

```markdown
> **Note (phase 2):** the guide this spec calls `docs/monitoring-setup.md` was
> later renamed to [`docs/grafana-setup.md`](../../grafana-setup.md); the name
> `monitoring-setup.md` now belongs to the guide for configuring what the
> platform observes. References below are left as written at the time.
```

In `docs/superpowers/plans/2026-07-26-monitoring-phase1.md`, after the `**Spec:**` line:

```markdown
> **Note (phase 2):** `docs/monitoring-setup.md` as created by this plan was
> later renamed to `docs/grafana-setup.md`. References below are left as
> written at the time.
```

- [ ] **Step 5: Verify no stale live references remain**

```bash
grep -rn 'monitoring-setup' README.md CLAUDE.md infra/ scripts/ docs/roadmap/ docs/grafana-setup.md
```

Expected: **no output**. (Hits inside `docs/superpowers/` are expected and correct — those are the archival ones.)

- [ ] **Step 6: Verify the rename registered as a rename, not a delete+add**

```bash
git add -A && git status --short
```

Expected: a line beginning `R` for `docs/monitoring-setup.md -> docs/grafana-setup.md`, preserving history.

- [ ] **Step 7: Commit**

```bash
git commit -m "docs: rename monitoring-setup.md to grafana-setup.md"
```

---

### Task 4: The new monitoring-setup.md guide

**Files:**
- Create: `docs/monitoring-setup.md`

**Interfaces:**
- Consumes (from Tasks 1–3): the four Loki labels, the Traefik access-log fields, and `docs/grafana-setup.md` as the named prerequisite.
- Produces (consumed by Task 5): the runtime verification checklist — this feature's only end-to-end test.

- [ ] **Step 1: Write the guide**

Match the voice of `docs/grafana-setup.md` and `docs/authentik-setup.md` — second person, numbered steps, explain *why* on anything non-obvious. Sections, in order:

**Title + intro.** "Grafana is up; now make it show you something." State that this guide grows: phase 2 (logs) is here now, phases 3–5 append. Link `roadmap/monitoring.md`.

**Prerequisites.** [grafana-setup.md](grafana-setup.md) complete and verified — Grafana reachable, both datasources green, the `up` query returning series.

**Part 1 — Container logs.**

State what changes: Alloy gains the Docker socket and four new components. Then the honest note, as its own blockquote:

> **This grants Alloy root-equivalent control of the VM's Docker.** The socket
> is mounted `:ro`, which matches Traefik's declaration but is **not** a
> security boundary — the mount is read-only, the API behind it is not.
> Anything holding that socket can start a privileged container. Dockge,
> Traefik and the Forgejo runner already hold it; phase 1 withheld it from
> Alloy precisely until there was a capability that needed it.

Apply:

```bash
cd ~/home-lab && git pull
cd infra/monitoring && docker compose up -d alloy
docker compose logs --tail=20 alloy
```

Verify, in Grafana **Explore → Loki**:

```logql
{job="docker"}
```

Lines within seconds. Then prove labelling works across stacks, not just locally:

```logql
{compose_project="authentik"}
```

```logql
sum by (compose_service) (count_over_time({job="docker"}[5m]))
```

The last one returns a row per service — the quickest way to see whether anything is silently missing.

**Part 2 — Traefik access logs.**

Note the restart blips every routed service, so do it in the same window:

```bash
cd ~/home-lab/infra/traefik && docker compose up -d
```

Verify:

```logql
{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400
```

Explain the `__error__=""` filter here, not in passing: Traefik's application log stays human-readable while the access log is JSON, so one stream carries two shapes and the filter drops the lines that aren't JSON.

**Part 3 — Querying.**

The four labels and why there are only four (labels are the index; unbounded values destroy a Loki install; everything else lives in the line and is parsed at query time). A short LogQL starter set:

- `{compose_service="server"} | json | event != ""` — Authentik's structured logs, parsed at query time.
- `{job="docker"} |= "error"` — plain substring across everything.
- `sum by (compose_service) (rate({job="docker"}[5m]))` — which service is loudest.

**Troubleshooting.** At minimum:
- *No logs at all* → check Alloy's UI on `127.0.0.1:12345` (tunnel per grafana-setup.md); a permission error on the socket shows as an unhealthy `discovery.docker`.
- *Logs but no `compose_*` labels* → the container wasn't started by Compose, or `relabel_rules` isn't wired; re-check that `targets` gets the raw discovery output.
- *Duplicate lines* → should not happen (tailers are keyed by container ID); if seen, look for a second Alloy instance rather than a config bug.
- *Alloy config won't load* → `docker run --rm -v /opt/stacks/monitoring/alloy/config.alloy:/c.alloy:ro grafana/alloy:v1.18.0 fmt /c.alloy`
- *Disk filling* → retention is 14 days; find the loudest service with the `count_over_time` query above.

**Verification checklist.** A `- [ ]` list restating: `{job="docker"}` returns; both `compose_project` values return; Authentik JSON parses; Traefik access logs parse with the `__error__` filter; per-service counts show every expected service; Alloy restart causes no duplicate flood; the phase 1 `up` metrics query still works.

**What's next.** Phases 3–5, linking `roadmap/monitoring.md`.

- [ ] **Step 2: Verify every LogQL query uses only the four defined labels**

```bash
grep -o '{[a-z_]*=' docs/monitoring-setup.md | sort -u
```

Expected: only `{job=`, `{compose_project=`, `{compose_service=`. Anything else is a label that does not exist.

- [ ] **Step 3: Verify internal links resolve**

```bash
python - <<'PY'
import re, os
f = "docs/monitoring-setup.md"
for m in re.finditer(r'\[[^\]]+\]\(([^)#]+?)(?:#[^)]*)?\)', open(f, encoding='utf-8').read()):
    t = m.group(1)
    if t.startswith(('http','mailto')): continue
    p = os.path.normpath(os.path.join(os.path.dirname(f), t))
    print(("ok   " if os.path.exists(p) else "BROKEN ") + t)
PY
```

Expected: all `ok`.

- [ ] **Step 4: Commit**

```bash
git add docs/monitoring-setup.md
git commit -m "docs: add the monitoring configuration guide"
```

---

### Task 5: Fold phase 2 into the repo docs

**Files:**
- Modify: `README.md` (layout tree, build order, status row)
- Modify: `docs/roadmap/monitoring.md` (phase 2 marked landed)
- Modify: `CLAUDE.md` (docker.sock gotcha, docs layout paragraph)

**Interfaces:**
- Consumes (from Tasks 1–4): `docs/grafana-setup.md`, `docs/monitoring-setup.md`, and the fact that Alloy now mounts the socket.

- [ ] **Step 1: `README.md` — add the new guide to the layout tree**

Under `docs/`, after the `grafana-setup.md` line added in Task 3:

```
│   ├── monitoring-setup.md       Configuring what's monitored (logs, metrics)
```

- [ ] **Step 2: `README.md` — split build-order step 6 into two**

Replace step 6 and renumber Coolify to 8:

```markdown
6. **[Grafana platform](docs/grafana-setup.md)** — Grafana + Prometheus + Loki +
   Alloy on the infra VM; Grafana joins Authentik by OIDC. Needs a new
   `grafana.thefipster.de` host record — the wildcard points at the apps VM.
7. **[Monitoring configuration](docs/monitoring-setup.md)** — point the platform
   at something: container logs into Loki, Traefik access logs on.
8. **Coolify** on the apps VM — *guide TBD* (see [apps/README.md](apps/README.md)).
```

- [ ] **Step 3: `README.md` — update the status row**

```markdown
| Monitoring: Grafana + Prometheus + Loki + Alloy | ✅ phases 1–2 deployed — [platform](docs/grafana-setup.md), [configuration](docs/monitoring-setup.md); dashboards next — [roadmap](docs/roadmap/monitoring.md) |
```

- [ ] **Step 4: `docs/roadmap/monitoring.md` — mark phase 2 landed**

Prefix phase 2 the same way phase 1 was, keeping its original text as the record of what shipped:

```markdown
2. **✅ Landed** — see [docs/monitoring-setup.md](../monitoring-setup.md).
   **Logs** — Alloy `discovery.docker` + `loki.source.docker`: every container
   on the VM, labeled by compose project/service. Verify Authentik's JSON
   logs land parsed and Traefik access logs are on (`--accesslog=true`).
   Shipped with four labels only (`job`, `compose_project`, `compose_service`,
   `container`) and **no ingest-time parsing** — JSON is parsed at query time
   with `| json`. Alloy took the `docker.sock` mount here, as phase 1 said it
   would.
```

- [ ] **Step 5: `CLAUDE.md` — add Alloy to the docker.sock gotcha**

Change the mounted-socket bullet to include Alloy, keeping the existing warning:

```markdown
- **Mounted `docker.sock` is root-equivalent** and used deliberately by Dockge,
  the Forgejo runner, Traefik (read-only there) and Alloy (container discovery
  + log tailing). `:ro` is not a security boundary for a socket — the mount is
  read-only, the API behind it is not. Acceptable only because this is a
  single-tenant box building the owner's own code — never extend this to
  untrusted/fork code.
```

- [ ] **Step 6: `CLAUDE.md` — describe the two-guide split**

In the **Docs layout** section, replace the mention of the monitoring guide so the split is explicit:

```markdown
`docs/grafana-setup.md` stands up the monitoring *platform* (stack, routing,
OIDC); `docs/monitoring-setup.md` configures what it observes (logs now,
metrics and dashboards as later phases land). Adding a new observability
capability means editing the second, not the first.
```

- [ ] **Step 7: Verify every link in the touched docs resolves**

```bash
python - <<'PY'
import re, os
for f in ["README.md","CLAUDE.md","docs/monitoring-setup.md","docs/grafana-setup.md","docs/roadmap/monitoring.md"]:
    for m in re.finditer(r'\[[^\]]+\]\(([^)#]+?)(?:#[^)]*)?\)', open(f, encoding='utf-8').read()):
        t = m.group(1)
        if t.startswith(('http','mailto')): continue
        p = os.path.normpath(os.path.join(os.path.dirname(f), t))
        if not os.path.exists(p): print(f"BROKEN {f} -> {t}")
print("link check done")
PY
```

Expected: `link check done` with no `BROKEN` lines.

- [ ] **Step 8: Commit**

```bash
git add README.md CLAUDE.md docs/roadmap/monitoring.md
git commit -m "docs: fold monitoring phase 2 into the repo docs"
```

---

## Self-review

**Spec coverage** — every spec section maps to a task: the Alloy pipeline and its four components → Task 1; the socket mount and its honest framing → Tasks 1, 4, 5; Traefik access logs → Task 2; the four-label decision → Tasks 1, 4; query-time parsing → Tasks 2, 4 (no ingest config exists anywhere, which *is* the implementation); the guide rename and all 10 references → Task 3; archival notes on the phase 1 spec/plan → Task 3; the new guide → Task 4; roadmap/README/CLAUDE.md → Task 5; verification → Task 4's checklist; error handling → Task 4's troubleshooting.

**Placeholder scan** — no TBD/TODO. Every code step carries the literal content to write. Task 4 specifies the guide by section with the exact queries rather than a full transcript, matching how phase 1's Task 5 was written and executed successfully.

**Naming consistency checked across tasks:** component labels (`discovery.docker "containers"`, `discovery.relabel "containers"`, `loki.source.docker "containers"`, `loki.write "default"`), the four Loki label names, the Loki push URL, the Alloy image pin, and the two guide paths are identical everywhere they appear in Tasks 1–5. The `loki.write "default"` name does not collide with the existing `prometheus.remote_write "default"` — different component namespaces.
