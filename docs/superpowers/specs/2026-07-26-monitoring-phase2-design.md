# Monitoring phase 2 — container log ingestion

**Date:** 2026-07-26
**Status:** Approved design, pending implementation plan
**Roadmap:** [docs/roadmap/monitoring.md](../../roadmap/monitoring.md) — this
spec covers **phase 2 only**; phases 3–5 stay on the roadmap.
**Builds on:** [phase 1](2026-07-26-monitoring-phase1-design.md), deployed and
verified on the infra VM.

## Goal

Fill Loki. Alloy discovers every container on the infra VM over the Docker API,
tails its stdout, labels it by compose project/service, and writes it to Loki.
Traefik's access log is switched on so HTTP traffic is queryable. Grafana then
shows logs and metrics from one place.

Also: split the monitoring documentation in two, so the guide that stands up the
platform is separate from the guide that configures what the platform watches.

## Constraints & decisions made

- **Collection via the Docker API** (`discovery.docker` + `loki.source.docker`),
  not log-file tailing and not the Docker Loki logging driver. The API is the
  only route that carries the compose metadata the roadmap's labelling goal
  needs — a log file path yields nothing but a 64-hex container ID. The logging
  driver would need a daemon plugin, a `logging:` block in all five stacks, and
  can block container start-up when Loki is down; it would also re-create the
  split-path problem phase 1 rejected, with metrics through Alloy and logs
  around it.
- **Alloy gets the Docker socket, and this is a real privilege grant.**
  Mounted `:ro` to match how Traefik declares it, but **`:ro` is not a security
  boundary for a socket** — it marks the mount read-only while the API behind it
  stays fully writable, so anything holding it can start a privileged container.
  Phase 2 is where Alloy joins Dockge, Traefik and the Forgejo runner as a
  root-equivalent holder of this VM's Docker. Accepted on the same basis as
  those three: single-tenant box running its owner's own code. Recorded here
  because phase 1 deliberately withheld it, and that decision is now reversed.
- **Four Loki labels, and no more:** `job`, `compose_project`,
  `compose_service`, `container`. Roughly 15 streams on this VM, all bounded.
  Labels are Loki's index; an unbounded label value is how a Loki install gets
  destroyed. Everything else — level, status code, path, duration — stays in the
  line.
- **JSON is parsed at query time, not at ingest.** No `loki.process` stages.
  Grafana's `| json` handles Authentik and the Traefik access log when a query
  actually needs fields. This keeps the pipeline to four components, costs
  nothing at ingest, and removes any chance of a parse rule exploding
  cardinality. The roadmap's "verify JSON logs land parsed" becomes a
  verification step, not a pipeline feature.
- **Traefik's access log is JSON; its application log stays human-readable.**
  Both go to stdout, so one container stream carries two shapes and a bare
  `| json` tags the plain lines with `__error__`. Accepted deliberately: the
  application log is what you read during ACME trouble, and readable beats
  uniform there. The guide documents the `| json | __error__=""` idiom.
- **No retention change.** Loki stays at 14 days, as shipped in phase 1.
- **Alloy tails its own container too.** Useful when debugging collection, and
  it is not a feedback loop — Alloy does not log per shipped line.
- **Documentation splits in two** (see below). The phase 1 guide is about
  standing up a platform; phase 2 onwards is about configuring what that
  platform observes. Keeping both in one file would mix a one-time install with
  a document that grows through phases 3–5.

## Architecture

```
  infra VM (.41)
  ┌────────────────────────────────────────────────────────────────┐
  │  /var/run/docker.sock ──(:ro mount)──► alloy                    │
  │                                                                 │
  │   discovery.docker "containers"      lists containers, 15s      │
  │            │ targets (raw, with __meta_*)                       │
  │            ▼                                                    │
  │   loki.source.docker "containers"    tails each container       │
  │            │   ▲                                                │
  │            │   └── relabel_rules ◄── discovery.relabel          │
  │            │        (compose_project, compose_service,          │
  │            │         container)                                 │
  │            ▼                                                    │
  │   loki.write "default" ──► http://loki:3100/loki/api/v1/push    │
  │                                                                 │
  │   traefik --accesslog=true --accesslog.format=json ──► stdout   │
  │            └─ picked up like any other container                │
  └────────────────────────────────────────────────────────────────┘
```

Metrics keep flowing exactly as phase 1 built them; nothing in that path
changes.

## Components

### `infra/monitoring/alloy/config.alloy` — the log pipeline

Four new components appended to the existing metrics config:

- **`discovery.docker "containers"`** — `host = "unix:///var/run/docker.sock"`,
  `refresh_interval = "15s"`. New containers are picked up automatically.
- **`discovery.relabel "containers"`** — maps Docker metadata to labels:
  `__meta_docker_container_label_com_docker_compose_project` → `compose_project`,
  `__meta_docker_container_label_com_docker_compose_service` → `compose_service`,
  and `__meta_docker_container_name` → `container`, stripping the leading slash
  Docker prepends.
- **`loki.source.docker "containers"`** — takes the **raw**
  `discovery.docker.containers.targets` plus
  `relabel_rules = discovery.relabel.containers.rules`, and a static
  `labels = {"job" = "docker"}`.

  > **The trap:** passing pre-relabelled targets instead is the intuitive
  > version and it is wrong — `loki.source.docker` needs
  > `__meta_docker_container_id` on the target to know what to tail, and a
  > relabel step that keeps only the four output labels strips it. The exact
  > argument names and this idiom are verified against the Alloy reference docs
  > during implementation.
- **`loki.write "default"`** — endpoint `http://loki:3100/loki/api/v1/push`.

Alloy's existing `--storage.path=/var/lib/alloy/data` (bind-mounted to
`/opt/monitoring/alloy`) persists read positions, so a restart resumes rather
than re-ingesting.

### `infra/monitoring/compose.yaml`

Add to the `alloy` service:

```yaml
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

replacing the phase 1 comment that explained why it was absent with one that
explains what it now grants. Alloy runs as root in-container, so no `group_add`
is needed (unlike the Forgejo runner, which runs non-root and joins by GID).

### `infra/traefik/compose.yaml`

Add two flags to the existing `command:` list, in a commented block matching the
file's style:

```yaml
      - --accesslog=true
      - --accesslog.format=json
```

Applying this **restarts Traefik**, so every routed service blips for a few
seconds. The guide says to do it in the same window as the Alloy change.

## Documentation restructure

### `docs/monitoring-setup.md` → `docs/grafana-setup.md` (git mv)

Content is kept as-is apart from the title and a reworded intro pointing onward
to the new guide. It owns **the platform**: the DNS record, `init-monitoring.sh`,
bring-up, stack verification, Authentik OIDC, break-glass, and the phase 1
troubleshooting.

Ten live references must follow the rename:

| File | Count | Where |
|---|---|---|
| `README.md` | 3 | layout tree, build order, status row |
| `infra/monitoring/.env.example` | 2 | header comment, OIDC section comment |
| `infra/monitoring/compose.yaml` | 2 | file header, the OIDC env comment |
| `scripts/init-monitoring.sh` | 2 | usage header, printed next-steps |
| `docs/roadmap/monitoring.md` | 1 | the phase 1 "Landed" link |

The dated phase 1 spec and plan keep their original references — they are
archival records of that cycle — but each gains a one-line note at the top
saying the guide it produced is now `grafana-setup.md`, so the links don't
mislead a reader.

### `docs/monitoring-setup.md` (new)

Starts where the platform guide ends: Grafana is up, now make it show you
something. Structured to **grow** as phases 3–5 land.

1. **Prerequisites** — `grafana-setup.md` complete and verified.
2. **Part 1 — Container logs.** What changes and why the socket matters
   (stated as the privilege grant it is), apply, verify.
3. **Part 2 — Traefik access logs.** The two flags, the restart warning, verify.
4. **Querying logs** — the four labels and why there are only four; LogQL
   starters; the `| json | __error__=""` idiom for Traefik's mixed stream.
5. **Troubleshooting.**
6. **Verification checklist.**
7. **What's next** — pointing at roadmap phases 3–5.

### Other docs

- **`docs/roadmap/monitoring.md`** — phase 2 marked landed, linking the new
  guide; phase 1's link retargeted to `grafana-setup.md`.
- **`README.md`** — build order gains a step (Grafana platform → monitoring
  configuration → Coolify, renumbering Coolify to 8); layout tree lists both
  guides; status row reflects phase 2.
- **`CLAUDE.md`** — the `docker.sock` gotcha adds Alloy to the list of
  deliberate socket holders; the docs-layout paragraph describes the two-guide
  split.

## Verification

Runtime, on the VM, captured as the new guide's checklist:

- `{job="docker"}` in Explore returns lines within seconds of the change.
- `{compose_project="monitoring"}` and `{compose_project="authentik"}` both
  return — discovery and labelling work across stacks, not just locally.
- `{compose_service="server"} | json | event != ""` — Authentik's JSON parses at
  query time. This is the roadmap's "verify JSON logs land parsed".
- `{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400`
  — access logs are on and structured, and the mixed-stream idiom works.
- `sum by (compose_service) (count_over_time({job="docker"}[5m]))` returns a row
  per service — a quick way to see nothing is silently missing.
- Restart Alloy; confirm no duplicate flood — positions persisted.
- Metrics still work: the phase 1 `up` query is unchanged.

Local (no daemon): `docker compose config -q` on both edited stacks, and the
Alloy config syntax-checked with `alloy fmt` on the VM.

## Error handling

- **Loki unreachable:** Alloy's `loki.write` buffers to its WAL and retries;
  container logging is unaffected because nothing sits in the containers' log
  path. This is a property of the API approach that the logging driver lacks.
- **Alloy restart:** read positions live in `/opt/monitoring/alloy`, so logs
  resume rather than duplicating.
- **A container produces a flood:** retention is 14 days and the label set is
  bounded, so the blast radius is disk, not cardinality. `df -h` and the
  per-service `count_over_time` query above identify the source.
- **Traefik restart fails after the flag change:** the two flags are additive
  and independently revertible; comment them and `docker compose up -d`.
- **Socket unavailable / permission denied:** Alloy's components report
  unhealthy in its UI on `127.0.0.1:12345` — the same debugging surface phase 1
  established.

## Out of scope

- **Phases 3–5** — the other stacks' Prometheus endpoints, host/cadvisor
  metrics, OTLP intake, Tempo, dashboards and alerts.
- **Ingest-time parsing, structured metadata, and multiline stitching** —
  query-time parsing first; revisit only if a real query proves it insufficient.
- **Log-based alerting** — belongs with phase 5's alerts.
- **The apps VM** — its own Alloy shipping to this Loki comes later.
- **Retention or storage changes** — Loki stays filesystem-backed at 14 days.
