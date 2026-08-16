# Apps VM logs → Loki, and Home Assistant host metrics — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get container stdout from the apps VM into the infra VM's Loki, and
make Home Assistant's own host metrics reach Prometheus — closing the last two
open rows in [docs/status.md](../../status.md).

**Architecture:** A logs-only Alloy in `apps/alloy/`, started by its own init
script on the apps VM, pushing over the LAN to a new push-path-only Traefik
router on the existing Loki. Both machines' `loki.source.docker` gain an
`instance` label so one query still covers both. The Home Assistant half is
documentation only — promoting the System Monitor integration from an aside to a
build step.

**Tech Stack:** Grafana Alloy `v1.18.1`, Loki 3, Traefik v3, Docker Compose,
bash. No build system, no test runner — see *Verification model* below.

**Spec:** [dev/specs/2026-08-16-apps-vm-logs-design.md](../specs/2026-08-16-apps-vm-logs-design.md)

> **Written before the docs restructure landed**, and executed against the tree
> as it was. Every path in the tasks below names the pre-restructure layout —
> `docs/status.md` rather than `STATUS.md`, `docs/grafana-setup.md` rather than
> `docs/guides/grafana-setup.md`, `docs/roadmap/` rather than `dev/roadmap/`.
> It is left that way on purpose: it is the record of what was actually done,
> and rewriting it would make it claim edits that were never made at those
> paths. The merge commit is where the two layouts meet.

## Global Constraints

- **Alloy image tag is `grafana/alloy:v1.18.1`, everywhere.** Full-patch pin
  because Alloy publishes only `vX.Y.Z` tags. It now appears in
  `infra/monitoring/compose.yaml`, `apps/alloy/compose.yaml`,
  `scripts/init-monitoring.sh`, `docs/grafana-setup.md` and `CLAUDE.md` — they
  move together.
- **No host IP addresses anywhere.** Every machine is addressed by name. A
  literal address in a diff is a defect.
- **No migration paths, no upgrade notes, no compatibility shims.** Every file
  describes a from-scratch bring-up of the current checkout.
- **`.sh` files are LF and mode `100755`.** A file created on Windows lands
  `100644`; fix with `git update-index --chmod=+x`.
- **New shell scripts use `set -euo pipefail`**, resolve paths from
  `${BASH_SOURCE[0]}`, and carry the `run_root()` helper.
- **No per-router TLS labels.** The entrypoint wildcard covers every `websecure`
  router.
- **Durable wording.** Do not write "the four labels", "three absences", "the
  only script that…" where the count or exclusivity can change. State the fact
  instead. Several existing sentences violate this *after* these changes and are
  fixed by named tasks below.
- **Loki label set stays bounded.** No unbounded-cardinality label (request id,
  path, user) is added by any task here.

## Verification model — read this before Task 1

**This repo has no build, lint or test system, and none of these changes can be
executed on the machine the repo is edited from (Windows, no Docker, no Alloy
binary, no Loki).** "Run the tests" does not exist here. What replaces it, and
what every task's verification steps actually do:

1. **Mechanical checks that do run locally** — `bash -n` for shell syntax,
   `git ls-files --eol` for line endings, `git ls-files -s` for file mode, and
   `grep` for cross-file consistency. These are written as exact commands with
   exact expected output.
2. **Reading against the source of truth** — when a compose file and a guide
   disagree, the compose file wins and the guide is corrected.
3. **On-VM verification is a deliverable, not a step.** The checks that need
   real machines live in `docs/apps-logs-setup.md` (Task 3), which is itself
   reviewed as content. Do not attempt to run them.

Commands below are written for **Git Bash** (the `Bash` tool), not PowerShell.

---

### Task 1: Accept pushes at `loki.thefipster.de`

The infra VM half. It ships before anything pushes to it and simply waits — the
same arrangement as `infra/traefik/dynamic/ha.yaml`, which was live from the
first bring-up while its backend did not yet exist.

**Files:**
- Modify: `infra/monitoring/compose.yaml` (the `loki` service, ~lines 140-153)
- Modify: `infra/monitoring/alloy/config.alloy` (`loki.source.docker`, ~line 252)
- Modify: `docs/dns-records.md` (records table + both verify sweeps)

**Interfaces:**
- Produces: the push URL `https://loki.thefipster.de/loki/api/v1/push`, consumed
  by Task 2's `loki.write`. The Traefik router is named `loki-push` and the
  Traefik service `loki-push`.
- Produces: the label `instance="infra"` on infra-VM container logs, which
  Task 2 mirrors as `instance="apps"` and Task 4 documents.

- [ ] **Step 1: Replace the `loki` service block in `infra/monitoring/compose.yaml`**

Replace the existing comment header and service (from the
`# ---` line above `loki:` through its `networks:` list) with:

```yaml
  # ---------------------------------------------------------------------------
  # Loki — log storage. Fed by Alloy: every container's stdout plus OTLP logs
  # from the apps.
  #
  # ROUTED, which reverses what this service used to say about itself ("not
  # routed; Grafana is the only reader"). The apps VM runs its own logs-only
  # Alloy (apps/alloy/) and pushes here over the LAN, so Loki needs an ingest
  # path that leaves this box. Same reversal Alloy went through when it became
  # the OTLP endpoint.
  #
  # The router is scoped to the PUSH PATH, deliberately. Routing the whole host
  # would put Loki's QUERY api on the LAN unauthenticated — and its DELETE api
  # with it, which is live because loki.yaml runs the compactor with
  # retention_enabled: true. Grafana still reads over monitoring-net, so the
  # write path is the only thing exposed.
  #
  # No auth, matching otlp.thefipster.de — the lab's other ingest endpoint. To
  # require it later, add ONE basic-auth middleware label here and one there.
  # ---------------------------------------------------------------------------
  loki:
    image: grafana/loki:3            # major pin
    restart: unless-stopped
    command: -config.file=/etc/loki/loki.yaml
    volumes:
      - ./loki/loki.yaml:/etc/loki/loki.yaml:ro
      # Image runs as UID 10001 — init-monitoring.sh chowns it.
      - /opt/monitoring/loki:/loki
    labels:
      traefik.enable: "true"
      # Push only. PathPrefix is anchored at the start of the path, so this
      # cannot be widened by a query that merely contains the string.
      traefik.http.routers.loki-push.rule: Host(`loki.thefipster.de`) && PathPrefix(`/loki/api/v1/push`)
      traefik.http.routers.loki-push.entrypoints: websecure
      traefik.http.services.loki-push.loadbalancer.server.port: "3100"
      # No middlewares label: this is machine-to-machine ingest with no browser
      # flow, so forward-auth would break the push outright. See
      # docs/sso-applications.md.
    networks:
      - monitoring-net
      # Joined so Traefik can reach :3100 without a published port — exactly how
      # Alloy's OTLP listeners are reached. The consequence worth knowing: every
      # container on `proxy` can now dial loki:3100 directly. Same single-tenant
      # trust domain that already accepts the docker.sock mounts, but it is a
      # widening.
      - proxy
```

- [ ] **Step 2: Add the `instance` label in `infra/monitoring/alloy/config.alloy`**

Find the `loki.source.docker "containers"` block and change its `labels` line,
putting the explanation inline inside the block. The `NOTE the wiring:` comment
that sits *above* the block is about `relabel_rules` and is untouched:

```river
loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  // `instance` names the MACHINE, and the apps VM's collector sets it to
  // "apps". Without it the two machines' logs are indistinguishable and a
  // stack name present on both collides into one stream. The value set matches
  // job="node" above — infra / apps / pve — so one word means one machine in
  // both metrics and logs. {job="docker"} still covers everything.
  labels        = {"job" = "docker", "instance" = "infra"}
  relabel_rules = discovery.relabel.containers.rules
  forward_to    = [loki.write.default.receiver]
}
```

Leave the `NOTE the wiring:` comment above the block exactly as it is.

- [ ] **Step 3: Add the DNS row in `docs/dns-records.md`**

In the records table, insert between the `grafana.thefipster.de` and
`otlp.thefipster.de` rows:

```markdown
| `loki.thefipster.de` | `infra ip` | Loki log ingest — the apps VM's collector pushes here (via Traefik, **push path only**) |
```

- [ ] **Step 4: Add `loki` to BOTH verify sweeps in `docs/dns-records.md`**

The sweeps are enumerated by hand, so a name missing from them is invisible to
the check that exists to catch exactly this mistake. Both loops become:

```bash
for n in git dockge home auth vault traefik grafana loki otlp uptime ha homeassistant pve nonsense; do printf '%-16s %s\n' "$n" "$(getent hosts $n.thefipster.de | awk '{print $1}')"; done
```

```bash
for n in git dockge home auth vault traefik grafana loki otlp uptime ha homeassistant pve nonsense; do printf '%-16s %s\n' "$n" "$(getent ahostsv6 $n.thefipster.de | awk 'NR==1{print $1}')"; done
```

The surrounding prose ("Everything through `ha` should share one address") stays
correct — `loki` is inserted before `ha`, and it points at the infra VM.

- [ ] **Step 5: Verify the router name is used consistently and no address leaked**

Run:

```bash
cd "C:/Users/felix/Source/home-lab" && grep -n "loki-push\|loki.thefipster.de" infra/monitoring/compose.yaml docs/dns-records.md
```

Expected: three `loki-push` hits in `compose.yaml` (router rule, router
entrypoints, service loadbalancer), one `loki.thefipster.de` in `compose.yaml`,
and three in `dns-records.md` (the table row plus both sweeps).

Run:

```bash
cd "C:/Users/felix/Source/home-lab" && git diff -U0 | grep -nE '^\+.*[0-9]{1,3}(\.[0-9]{1,3}){3}' || echo "no literal addresses added"
```

Expected: `no literal addresses added`.

- [ ] **Step 6: Verify the label change landed and nothing else in Alloy moved**

Run:

```bash
cd "C:/Users/felix/Source/home-lab" && grep -n 'instance" = "infra"\|"job" = "docker"' infra/monitoring/alloy/config.alloy
```

Expected: one line containing both `"job" = "docker"` and `"instance" = "infra"`.

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/felix/Source/home-lab" && git add infra/monitoring/compose.yaml infra/monitoring/alloy/config.alloy docs/dns-records.md && git commit -m "monitoring: route Loki's push path and label logs by machine

Loki gains a push-path-only websecure router at loki.thefipster.de and
joins proxy, so the apps VM's collector can reach it. Scoped to
/loki/api/v1/push deliberately: the query and delete APIs stay on
monitoring-net. Both machines' container logs now carry an instance
label, matching the job=node convention.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The apps VM's collector

**Files:**
- Create: `apps/alloy/compose.yaml`
- Create: `apps/alloy/config.alloy`
- Create: `scripts/init-apps-alloy.sh`

**Interfaces:**
- Consumes: `https://loki.thefipster.de/loki/api/v1/push` from Task 1.
- Produces: `instance="apps"` container logs carrying `job`, `compose_project`,
  `compose_service`, `container` and `coolify_resource`; the stack directory
  `apps/alloy`; the data directory `/opt/alloy`; the script name
  `scripts/init-apps-alloy.sh`, referenced by Tasks 3, 4 and 6.

- [ ] **Step 1: Create `apps/alloy/compose.yaml`**

```yaml
# Alloy — container logs from the APPS VM, and nothing else.
#
# This is the ONE running service this repo declares for this machine, and the
# exception is deliberate. apps/ holds no compose because COOLIFY owns app
# definitions, and mirroring them here would create a second source of truth
# that drifts. Nothing in Coolify's store describes a log collector, so there is
# nothing for this to drift from — the rule keeps its force and gains this one
# stated exception. See apps/README.md.
#
# NOT a Coolify resource, on purpose: the thing that collects the logs must not
# depend on the platform it exists to observe.
#
# What it is not: it does NOT scrape metrics (scripts/init-node-exporter.sh
# covers this host, scraped from the infra VM as job="node", instance="apps")
# and it does NOT receive OTLP (the apps emit straight to otlp.thefipster.de).
# Logs are the only gap on this machine; this closes it and nothing else.
#
# Deploy: scripts/init-apps-alloy.sh — see docs/apps-logs-setup.md.

name: alloy

services:
  alloy:
    # Same FULL PATCH pin as infra/monitoring/compose.yaml, and it must STAY the
    # same: the two collectors have to produce identical labels, so they run
    # identical versions. Alloy publishes only vX.Y.Z tags.
    image: grafana/alloy:v1.18.1
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    ports:
      # Component-health UI, bound to this VM's LOOPBACK only — no hostname, no
      # cert, no router, exactly like the infra VM's. Reach it when debugging:
      #   ssh -L 12345:127.0.0.1:12345 <apps-vm>
      # This is also why Uptime Kuma has no monitor for this collector: there is
      # nothing to probe and Kuma's docker.sock is the infra VM's. Recorded in
      # docs/uptime-kuma-monitors.md.
      - "127.0.0.1:12345:12345"
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
      # Read positions. Losing them re-reads logs rather than losing them, which
      # is why this directory is in no backup.
      - /opt/alloy:/var/lib/alloy/data
      # Docker API — container discovery + log tailing. `:ro` is NOT a security
      # boundary for a socket: the mount is read-only, the API behind it is not,
      # so this is root-equivalent control of this VM's Docker. Same trade the
      # infra VM already makes for Alloy, Dockge, Traefik and the Forgejo runner.
      - /var/run/docker.sock:/var/run/docker.sock:ro

# No `networks:` block, and that is not an omission. This container needs only
# OUTBOUND LAN access to reach loki.thefipster.de, which compose's default
# project network gives it — the same way Alloy on the infra VM reaches pve and
# apps to scrape them. It joins no Coolify network and publishes nothing.
#
# No `hostname:` either. The infra VM's Alloy pins one because its embedded unix
# exporter reads the container's UTS hostname and the node dashboard chains off
# it; there is no unix exporter here, so nothing would read it.
```

- [ ] **Step 2: Create `apps/alloy/config.alloy`**

```river
// Alloy on the APPS VM — logs only. The infra VM's config.alloy is the fuller
// one (metrics, logs, OTLP); this is its logs section, pointed at a remote Loki.
//
// The two files must keep producing the SAME LABELS. That parity is the entire
// reason this machine runs its own Alloy rather than a Docker logging driver
// pointed at Loki — a driver's labels would not match, and the single pane in
// Grafana would split in two.
//
// Component health: http://127.0.0.1:12345 on the apps VM (loopback-bound).
//   ssh -L 12345:127.0.0.1:12345 <apps-vm>

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
  // Default is 1m; 15s means a newly deployed Coolify resource shows up almost
  // at once.
  refresh_interval = "15s"
}

// Docker metadata -> the labels we keep. Docker SANITIZES label names, so
// `com.docker.compose.project` arrives as `com_docker_compose_project`.
//
// `targets = []` is deliberate: only the `rules` export is consumed below, so
// evaluating a target list here as well would be pure waste.
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

  // THE ONE RULE THE INFRA VM DOES NOT HAVE.
  //
  // The three rules above are partly empty on this machine and that is
  // expected: Coolify deploys its compose-based resources through Docker
  // Compose, so those carry com.docker.compose.*, but anything deployed
  // straight from a Dockerfile does not — for those, `container` would
  // otherwise be the only thing identifying the log.
  //
  // Loki treats an unset label as ABSENT rather than as empty, so a label that
  // exists on one machine and not the other does NOT split {job="docker"}.
  //
  // VERIFY THE SOURCE NAME ON THE MACHINE. Coolify's label set is not pinned by
  // this repo and has changed across versions. docs/apps-logs-setup.md has the
  // `docker inspect` step; if the label is not `coolify.name`, THIS is the line
  // to change. Getting it wrong is silent — the label is simply absent.
  rule {
    source_labels = ["__meta_docker_container_label_coolify_name"]
    target_label  = "coolify_resource"
  }
}

// NOTE the wiring: `targets` gets the RAW discovery output and the rules are
// passed SEPARATELY as `relabel_rules`. These are not interchangeable. The
// component keys its tailers on `__meta_docker_container_id`, and handing it
// `discovery.relabel.containers.output` would strip that ID along with every
// other `__meta_*` label.
loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  // `instance` names the MACHINE — "infra" on the other collector. {job="docker"}
  // covers both; {job="docker", instance="apps"} narrows to this one.
  labels        = {"job" = "docker", "instance" = "apps"}
  relabel_rules = discovery.relabel.containers.rules
  forward_to    = [loki.write.default.receiver]
}

// Across the LAN to the infra VM, through Traefik under the lab's wildcard
// certificate. No tls_config: the certificate is a genuine Let's Encrypt one and
// this image trusts public CAs, the same reason the infra VM's Home Assistant
// scrape needs none.
//
// No credential — matching otlp.thefipster.de, the lab's other ingest endpoint.
//
// The name MUST have an exact DNS record pointing at the infra VM. The
// *.thefipster.de wildcard answers with THIS machine, so a missing record sends
// these logs to Coolify's own proxy, which answers on 443 with a valid
// certificate and 404s them. See docs/dns-records.md.
loki.write "default" {
  endpoint {
    url = "https://loki.thefipster.de/loki/api/v1/push"
  }
}
```

- [ ] **Step 3: Create `scripts/init-apps-alloy.sh`**

```bash
#!/usr/bin/env bash
#
# init-apps-alloy.sh — bring up the APPS VM's log collector.
#
# WHICH MACHINE RUNS THIS: the apps VM, and only the apps VM. The infra VM's
# Alloy is part of infra/monitoring and is started with that stack; running this
# there would tail the same containers twice.
#
# Named for the machine rather than the stack because `init-alloy.sh` would read
# as the OTHER Alloy — the one inside infra/monitoring.
#
# It STARTS THE STACK ITSELF, which only init-dockge.sh otherwise does, and for a
# stronger version of the same reason. Dockge starts itself because Dockge is
# what you would otherwise start stacks with and it is not up yet. This machine
# has no Dockge AT ALL — no /opt/stacks, nothing to drive start/stop/logs from —
# so a script that prepared the stack and left it stopped would hand you a
# `docker compose up` with no home. Hence also no symlink step.
#
# Assumes Docker exists, which on this machine means scripts/init-coolify.sh has
# run (Coolify's installer brings the Engine — init-docker.sh is deliberately
# skipped here).
#
# Re-runnable: mkdir -p and `compose up -d` are both idempotent.
# Usage (from anywhere):
#   scripts/init-apps-alloy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/apps/alloy"

# Alloy's read positions. Not backed up anywhere on purpose: losing them
# re-reads logs rather than losing them.
DATA_DIR="/opt/alloy"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-coolify.sh first; its installer" >&2
  echo "brings the Engine on this machine." >&2
  exit 1
fi

echo "==> Creating ${DATA_DIR}"
# No chown: this image runs as root in-container, like the infra VM's Alloy.
run_root mkdir -p "${DATA_DIR}"

echo "==> Starting the collector"
( cd "${STACK_DIR}" && docker compose up -d )

cat <<EOF

Done. Nothing else runs on this machine.

Verify from here:
  docker compose -f ${STACK_DIR}/compose.yaml logs alloy

Then in Grafana (Explore -> Loki), from any browser:
  {job="docker", instance="apps"}

If that stays empty, check the DNS record FIRST — the wildcard answers with
this VM, so a missing loki.thefipster.de record 404s the push against
Coolify's own proxy:
  getent hosts loki.thefipster.de

Guide: docs/apps-logs-setup.md
EOF
```

- [ ] **Step 4: Make the script executable and verify its mode**

```bash
cd "C:/Users/felix/Source/home-lab" && git add scripts/init-apps-alloy.sh && git update-index --chmod=+x scripts/init-apps-alloy.sh && git ls-files -s scripts/init-apps-alloy.sh
```

Expected: the line begins `100755`.

- [ ] **Step 5: Verify shell syntax and line endings**

```bash
cd "C:/Users/felix/Source/home-lab" && bash -n scripts/init-apps-alloy.sh && echo "syntax ok"
```

Expected: `syntax ok`.

```bash
cd "C:/Users/felix/Source/home-lab" && git add apps/alloy && git ls-files --eol scripts/init-apps-alloy.sh apps/alloy/compose.yaml apps/alloy/config.alloy
```

Expected: every line shows `w/lf` (working-tree LF). If any shows `w/crlf`, the
`.gitattributes` rule did not apply — re-check out the file rather than editing
it by hand.

- [ ] **Step 6: Verify label parity between the two collectors**

The two configs must agree on the shared labels. Run:

```bash
cd "C:/Users/felix/Source/home-lab" && grep -n 'target_label' infra/monitoring/alloy/config.alloy apps/alloy/config.alloy
```

Expected: `compose_project`, `compose_service` and `container` appear in **both**
files; `coolify_resource` appears in `apps/alloy/config.alloy` **only**.

```bash
cd "C:/Users/felix/Source/home-lab" && grep -n '"job" = "docker"' infra/monitoring/alloy/config.alloy apps/alloy/config.alloy
```

Expected: one hit per file, `instance` `"infra"` and `"apps"` respectively.

- [ ] **Step 7: Verify the Alloy pin matches the infra VM**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -rn "grafana/alloy:" --include=*.yaml --include=*.sh --include=*.md .
```

Expected: every hit is `v1.18.1`. A mismatch between the two compose files is
the defect this step exists to catch.

- [ ] **Step 8: Commit**

```bash
cd "C:/Users/felix/Source/home-lab" && git add apps/alloy scripts/init-apps-alloy.sh && git commit -m "apps: add a logs-only Alloy for the apps VM

The one running service this repo declares for that machine. Tails
container stdout over the local docker.sock and pushes to the infra VM's
Loki through Traefik, with labels matching the infra collector's plus a
coolify_resource rule for Dockerfile-deployed resources that carry no
compose labels.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The guide, and its place in the build order

**Files:**
- Create: `docs/apps-logs-setup.md`
- Modify: `README.md` (build order, apps VM section ~lines 214-226)
- Modify: `docs/coolify-setup.md` (both `## Next` sections, ~lines 184-188 and
  ~lines 293-297)

**Interfaces:**
- Consumes: `scripts/init-apps-alloy.sh`, `apps/alloy/config.alloy` and the
  `coolify_resource` rule from Task 2; `loki.thefipster.de` from Task 1.
- Produces: the guide path `docs/apps-logs-setup.md`, linked by Task 5's status
  row and Task 6's CLAUDE.md docs list.

- [ ] **Step 1: Create `docs/apps-logs-setup.md`**

````markdown
# Container logs from the apps VM

**Runs on:** apps VM

**Prerequisite:** [coolify-setup.md](coolify-setup.md) complete — Coolify is
running, which means this machine has a Docker Engine and containers worth
tailing.

Everything on this VM logs where Loki cannot see it: Coolify's own containers,
the third-party catalog in [apps/services.md](../apps/services.md), and anything
Coolify builds from your source. This adds a **logs-only Alloy** here that tails
them over the local Docker socket and pushes to the Loki already running on the
infra VM.

Metrics from this machine are **not** affected and need nothing —
[`init-node-exporter.sh`](../scripts/init-node-exporter.sh) ran back in
[apps-vm-setup.md](apps-vm-setup.md) and Alloy scrapes it by name. Logs are the
only gap.

> **The infra half is already in the repo, and has been live all along.** Loki's
> push router shipped with the monitoring stack in
> [grafana-setup.md](grafana-setup.md) — it has been answering at
> `loki.thefipster.de` with nothing pushing to it, the same way Traefik's file
> provider served Home Assistant's route before that VM existed. There is
> nothing to add on the infra VM.

## Steps

### 1. Check the DNS record before anything else

This is the check that catches the failure everything else here would blame on
Traefik. `loki.thefipster.de` needs an **exact** record pointing at the **infra
VM** ([dns-records.md](dns-records.md)) — the `*.thefipster.de` wildcard answers
with *this* machine:

```bash
getent hosts loki.thefipster.de
```

Compare it against a name you know points at the infra VM:

```bash
getent hosts grafana.thefipster.de
```

The two must **match**. If `loki.` instead matches this VM's own address, the
record is missing and the push would land on Coolify's proxy — which answers on
443 with a perfectly valid certificate and 404s it. Add the record before going
on.

### 2. Prove the endpoint answers

```bash
curl -sI https://loki.thefipster.de/loki/api/v1/push | head -1
```

Expect **`HTTP/2 405`**. That is the success case: 405 is Loki rejecting a `GET`
on a push endpoint, which means DNS, Traefik, the wildcard certificate and Loki
itself are all working and only the method is wrong.

A `404` means the router did not match — check the path in the command. A
certificate warning means the name resolved somewhere other than the infra VM;
go back to step 1.

### 3. Start the collector

```bash
cd ~/home-lab && scripts/init-apps-alloy.sh
```

It creates `/opt/alloy` for Alloy's read positions and starts the stack itself —
this machine has no Dockge to start it from.

```bash
docker compose -f ~/home-lab/apps/alloy/compose.yaml logs alloy | tail -20
```

Expect no errors mentioning the Loki endpoint. A `401`, `404` or TLS error here
points back at steps 1 and 2.

### 4. Confirm the labels Coolify actually sets

**Do this rather than trusting the config.** Coolify's container labels are not
pinned by this repo and have changed across versions. Pick any container Coolify
manages:

```bash
docker ps --format '{{.Names}}'
```

```bash
docker inspect --format '{{json .Config.Labels}}' <a-coolify-container> | tr ',' '\n' | grep -i coolify
```

The config maps **`coolify.name`** to the `coolify_resource` label. If that key
is absent and a differently-named one is there, change the single
`source_labels` line in
[`apps/alloy/config.alloy`](../apps/alloy/config.alloy) and restart:

```bash
docker compose -f ~/home-lab/apps/alloy/compose.yaml up -d
```

Getting this wrong is **silent** — the label is simply absent and everything
else still works.

### 5. Verify in Grafana

From any browser, in **Explore → Loki** at `https://grafana.thefipster.de`:

```logql
{job="docker", instance="apps"}
```

Lines appear within seconds. Then confirm the pane did not split — this must
return **both** machines:

```logql
sum by (instance) (count_over_time({job="docker"}[5m]))
```

Expect two rows, `infra` and `apps`. One row means the label did not land on one
of the collectors.

Then check the expected asymmetry rather than being surprised by it later:

```logql
sum by (compose_service) (count_over_time({job="docker", instance="apps"}[5m]))
```

Coolify's compose-based resources appear by service name. Anything it deployed
straight from a Dockerfile will **not** — those carry no compose labels at all,
which is what `coolify_resource` exists for:

```logql
sum by (coolify_resource) (count_over_time({job="docker", instance="apps"}[5m]))
```

### Checklist

- [ ] `loki.thefipster.de` resolves to the **infra** VM, not this one
- [ ] `curl -sI .../loki/api/v1/push` → `405`, no certificate warning
- [ ] `scripts/init-apps-alloy.sh` completes and `/opt/alloy` exists
- [ ] the collector's own logs show no endpoint errors
- [ ] `coolify.name` confirmed by `docker inspect`, or the config corrected
- [ ] `{job="docker", instance="apps"}` returns lines
- [ ] `sum by (instance) (...)` returns **two** rows

## Next

**[home-assistant-setup.md](home-assistant-setup.md)** — the third VM, and the
last machine in the lab.

## Troubleshooting

**Nothing in Loki, and the collector's logs mention a 404.** The push reached
Coolify's proxy instead of Traefik. `loki.thefipster.de` has no exact record and
fell through the wildcard to this machine — step 1.

**Nothing in Loki, and the collector's logs mention a certificate.** Same root
cause, different symptom: the name resolved to a host presenting Coolify's
certificate rather than Traefik's wildcard. Also step 1.

**`{job="docker"}` returns only `instance="infra"`.** The collector is not
pushing. Check it is running at all, then read its own logs — it tails itself,
but only into a Loki it can reach, so its own failures are visible on this
machine and nowhere else:

```bash
docker compose -f ~/home-lab/apps/alloy/compose.yaml logs alloy
```

**`{job="docker"}` returns only `instance="apps"`.** The opposite: the infra
VM's collector lost its label or its Alloy did not restart after the config
change. Fix on that machine.

**Logs arrive but `compose_service` is empty for some containers.** Expected,
not a fault — those were deployed from a Dockerfile rather than a compose file.
Use `coolify_resource` or `container` for them.

**`compose_service` is empty for *everything*, and so is `coolify_resource`.**
The relabel rules are not being applied. Check that `relabel_rules` is wired to
`discovery.relabel.containers.rules` and *not* to `.output` — passing `.output`
strips the metadata the component needs.

**The component-health UI will not open.** It is bound to this VM's loopback on
purpose. Tunnel to it:

```bash
ssh -L 12345:127.0.0.1:12345 <apps-vm>
```

## Layout on the server

| What | Where |
|------|-------|
| The stack | `~/home-lab/apps/alloy` — run from the checkout, no `/opt/stacks` symlink |
| Alloy's read positions | `/opt/alloy` |
| The collector's config | `apps/alloy/config.alloy` in this repo |
| Loki, Grafana, the router | the **infra VM** — nothing to configure there |

No `.env`, because there is no credential: the push endpoint takes none, matching
`otlp.thefipster.de`. No `/opt/stacks` symlink, because this machine has no
Dockge. No `backup.sh`, because read positions are regenerable and this VM has
not joined the restic repository anyway
([roadmap/backup.md](roadmap/backup.md)).

## How it works

**Why a second Alloy rather than a logging driver.** Alloy discovers containers
and tails them through a Docker socket, and that socket belongs to the machine
Alloy runs on — so the infra VM's collector structurally cannot see this one's
containers. The alternative was pointing Coolify's own Docker logging driver at
Loki, which needs no extra container but is a daemon-level change on a machine
Coolify expects to own, and produces labels that would not match the infra VM's.
The two halves of the single pane would then not query alike, which defeats the
point of having one.

**Why it pushes through Traefik instead of a published port.** Loki's `:3100` is
not published anywhere; Traefik fronts it under the lab's wildcard certificate,
exactly as it fronts the OTLP endpoint. The router is scoped to the **push
path** only, so Loki's query API — and its delete API, which is live because
retention is enabled — never leave the infra VM. There is no credential, which
matches the OTLP endpoint; adding one would mean adding it to both.

**Why `instance` and not a new job.** `job="docker"` covers both machines, so
every existing query and dashboard keeps working, and `instance` narrows to one.
The values match what `job="node"` already uses — `infra`, `apps`, `pve` — so one
word means one machine in metrics and logs alike.

**Why Uptime Kuma has no monitor for this.** It cannot have one. Kuma's
container-state monitors read a `docker.sock`, and the one it holds is the infra
VM's — the same property that lets it watch stacks it shares no network with is
what stops it watching a container over here. The collector's UI is
loopback-bound, so there is no endpoint to probe either. The signal that it died
is logs from `instance="apps"` stopping, and that blind spot is recorded in
[uptime-kuma-monitors.md](uptime-kuma-monitors.md#deliberately-not-monitored).

## Next

**[home-assistant-setup.md](home-assistant-setup.md)** — the last machine. The
full sequence is the [README build order](../README.md#build-order).
````

- [ ] **Step 2: Insert the build-order entry in `README.md`**

In the `### apps VM — your own applications` section, after entry 14 (Coolify)
and before the `### home-assistant VM` heading, add:

```markdown
15. **[Container logs](docs/apps-logs-setup.md)** — a logs-only Alloy on this
    machine, pushing to the infra VM's Loki so the single pane covers both
    Docker hosts. The infra half has been live since the monitoring stack came
    up; this is the collector. Check `loki.thefipster.de` resolves to the
    **infra** VM first — the wildcard answers with this one.
```

Then renumber the Home Assistant entry from **15** to **16**.

- [ ] **Step 3: Repoint both `## Next` sections in `docs/coolify-setup.md`**

Replace the first (~line 186):

```markdown
**[apps-logs-setup.md](apps-logs-setup.md)** — get this machine's container
logs into Loki, so the single pane covers both Docker hosts.
```

And the second (~line 295):

```markdown
**[apps-logs-setup.md](apps-logs-setup.md)** — this machine's container logs.

The full sequence is the [README build order](../README.md#build-order).
```

- [ ] **Step 4: Verify every relative link in the new guide resolves**

```bash
cd "C:/Users/felix/Source/home-lab/docs" && grep -o '](\.\./\?[^)#]*' apps-logs-setup.md | sed 's/](//' | sort -u | while read -r p; do [ -e "$p" ] && echo "ok   $p" || echo "MISS $p"; done
```

Expected: every line starts `ok`. Any `MISS` is a broken link — fix before
committing.

- [ ] **Step 5: Verify the build order is numbered without a gap or repeat**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -nE '^[0-9]+\. \*\*\[' README.md | sed -E 's/^([0-9]+):([0-9]+)\..*/\2/' | tr '\n' ' '
```

Expected: `1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16`.

- [ ] **Step 6: Verify no guide still sends the reader from Coolify to Home Assistant**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -n "home-assistant-setup.md" docs/coolify-setup.md || echo "coolify no longer links HA directly"
```

Expected: `coolify no longer links HA directly`.

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/felix/Source/home-lab" && git add docs/apps-logs-setup.md README.md docs/coolify-setup.md && git commit -m "docs: add the apps VM container-logs guide

Its own build-order step between Coolify and Home Assistant, leading with
the DNS check that catches the wildcard trap and the 405 that proves the
push route without pushing anything.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Registries and the monitoring guide

The three registries centralise what lives outside the repo, and each records
its **deliberate absences** — a registry that only lists what exists cannot say
whether a gap was a decision.

**Files:**
- Modify: `docs/sso-applications.md` (new section before `## Access bindings`)
- Modify: `docs/uptime-kuma-monitors.md` (`## Deliberately not monitored`, ~line 432)
- Modify: `docs/grafana-setup.md` (label table ~line 856, log verification
  ~lines 345-364, checklist ~line 594)
- Modify: `apps/README.md` (intro carve-out, file table, scripts table)

**Interfaces:**
- Consumes: the label set and script name from Task 2, the guide path from Task 3.

- [ ] **Step 1: Add the SSO non-row in `docs/sso-applications.md`**

Insert immediately before `## Access bindings`:

```markdown
## The log ingest endpoint (not an application at all)

`loki.thefipster.de` is a machine-to-machine ingest path — the apps VM's
collector pushing container logs into Loki
([apps-logs-setup.md](apps-logs-setup.md)). It has no browser UI to gate and
speaks no OIDC, so it was never a candidate for either pattern, and forward-auth
would break the push outright rather than prompting anyone.

Recorded here for the same reason as the backup job above: so the absence reads
as a decision. It is **not** counted among the deliberate non-joiners, which are
services that could have joined and did not.

It carries no credential of its own either, matching `otlp.thefipster.de` — the
lab's other unauthenticated ingest endpoint. Gating one and not the other would
be the inconsistency. Note that the Traefik router is scoped to the **push path
only**, so Loki's query and delete APIs are not reachable from the LAN at all;
that scoping, not authentication, is what bounds this surface.
```

- [ ] **Step 2: Add the Kuma non-row in `docs/uptime-kuma-monitors.md`**

First fix the opening line of `## Deliberately not monitored`, which counts:

```markdown
Absences that are decisions, not gaps. Listed so this registry stays an
honest account of coverage.
```

Then insert this entry after the **Uptime Kuma itself** paragraph and before
**The Proxmox host's *availability***:

```markdown
**The apps VM's log collector.** `apps/alloy` cannot be monitored from here, and
the reason is the same property that makes Kuma useful everywhere else: its
container-state monitors read a `docker.sock`, and the one it holds is the
**infra VM's**. That is exactly what lets it report on stacks it shares no
network with, and exactly what stops it seeing a container on another machine.
The collector's own component UI is loopback-bound on the apps VM, so there is
no endpoint to probe either.

The signal that it has died is **logs from `instance="apps"` stopping**, noticed
by eye in Grafana. That is a real blind spot, and it belongs beside the weekly
`restic check` having no heartbeat rather than being papered over.

Two closures were weighed and dropped. Binding the collector's `:12345` to the
LAN and scraping its self-metrics would let the existing `ServiceDown` alert
cover it with no new rule — rejected because it puts Alloy's component graph on
the LAN where the infra VM's equivalent is deliberately loopback-only, buying an
alert by making the two collectors disagree about their own exposure. An HTTP
monitor on the push URL accepting the `405` a `GET` returns would prove DNS,
Traefik, the certificate and Loki being up — the *receiving* half — while saying
nothing about whether anything is pushing. A green tick that does not mean what
it reads as is worse than a stated gap.
```

- [ ] **Step 3: Update the label table in `docs/grafana-setup.md`**

Replace the `**Logs carry exactly four labels**, on purpose:` line and its table
with:

```markdown
**Logs carry a deliberately small label set**, and it is the same on both Docker
machines:

| Label | Example | Source |
|-------|---------|--------|
| `job` | `docker` | static, set by Alloy |
| `instance` | `infra`, `apps` | static, set by Alloy — the machine, matching `job="node"`'s values |
| `compose_project` | `monitoring`, `authentik`, `traefik` | the compose project name |
| `compose_service` | `grafana`, `server`, `db` | the service name inside that project |
| `container` | `monitoring-grafana-1` | the Docker container name |
| `coolify_resource` | `paperless` | **apps VM only** — Coolify's own label, for resources deployed from a Dockerfile that carry no compose labels |

`coolify_resource` exists on one machine and not the other, which does not split
`{job="docker"}`: Loki treats an unset label as absent rather than as empty. See
[apps-logs-setup.md](apps-logs-setup.md).
```

- [ ] **Step 4: Extend the log verification in `docs/grafana-setup.md`**

After the `sum by (compose_service) (count_over_time({job="docker"}[5m]))` block
and its "one row per running service" line, insert:

````markdown
Both Docker machines land in the same place once the apps VM's collector exists
([apps-logs-setup.md](apps-logs-setup.md)) — until then this returns one row,
which is correct at this point in the build:

```logql
sum by (instance) (count_over_time({job="docker"}[5m]))
```
````

- [ ] **Step 5: Extend the checklist in `docs/grafana-setup.md`**

After the `- [ ] {job="docker"} returns lines within seconds` item, add:

```markdown
- [ ] `sum by (instance) (count_over_time({job="docker"}[5m]))` returns `infra`
      — and `apps` too, once that machine's collector is up
```

- [ ] **Step 6: Update `apps/README.md`**

Leave the existing `## Why there is no compose file here` prose intact and append
a new paragraph directly after the one ending "…silently drifts from the one
actually deploying things":

```markdown
**One exception, and it is stated rather than implied.** `alloy/` is a compose
stack this repo declares and this machine runs. The rule above is about
**applications**, and its reason is that Coolify owns app definitions — nothing
in Coolify's store describes a log collector, so there is nothing for this to
drift from. It is deliberately not a Coolify resource either: the thing that
collects the logs must not depend on the platform it exists to observe.
```

Add to the file table:

```markdown
| `alloy/` | a **logs-only** Alloy that tails this machine's containers and pushes them to the infra VM's Loki. The one running service this repo declares here — see the exception above and [docs/apps-logs-setup.md](../docs/apps-logs-setup.md). |
```

Add to the scripts table:

```markdown
| [`init-apps-alloy.sh`](../scripts/init-apps-alloy.sh) | Creates `/opt/alloy` and starts the log collector. Starts its own stack, because this machine has no Dockge to start it from. |
```

- [ ] **Step 7: Verify every registry records this service**

The repo's rule is that a new service gets a decision in all three registries.
Run:

```bash
cd "C:/Users/felix/Source/home-lab/docs" && grep -ln "loki.thefipster.de\|apps/alloy\|instance=\"apps\"" dns-records.md sso-applications.md uptime-kuma-monitors.md
```

Expected: all three filenames listed.

- [ ] **Step 8: Verify no stale count survived**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -rn "exactly four labels\|Three absences" docs/ || echo "no stale counts"
```

Expected: `no stale counts`.

- [ ] **Step 9: Commit**

```bash
cd "C:/Users/felix/Source/home-lab" && git add docs/sso-applications.md docs/uptime-kuma-monitors.md docs/grafana-setup.md apps/README.md && git commit -m "docs: record the apps collector in all three registries

SSO and Kuma get non-rows with their reasoning, grafana-setup gains the
instance and coolify_resource labels plus a per-machine verification
query, and apps/README states the one-running-service exception.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Home Assistant's own host metrics

Bounded, and documentation only — the repo's wiring already exists
(`HA_PROMETHEUS_TOKEN` passthrough, the `home_assistant` scrape, `prometheus:`
in the fragment). What is missing is that `/api/prometheus` exports **entities**,
so without the System Monitor integration that VM's CPU, RAM and disk are not in
the feed at all — and today that integration is a "worth doing from here" aside
after the guide has ended.

**Files:**
- Modify: `docs/home-assistant-setup.md` (new step 9 after `### 8. Wire up metrics`,
  ~line 297; the `## Next` section ~lines 299-307)
- Modify: `home-assistant/configuration.yaml` (the metrics comment, ~lines 40-46)

**Interfaces:**
- Consumes: nothing from Tasks 1-4. This task is independent and may be done in
  any order relative to them.

- [ ] **Step 1: Add step 9 to `docs/home-assistant-setup.md`**

Insert after step 8's closing paragraph and before `## Next`:

````markdown
### 9. Add the host's own metrics

Step 8 got Home Assistant's **entities** into Prometheus. This VM's CPU, RAM and
disk are not among them — `/api/prometheus` exports entity states, and nothing
on this appliance produces machine counters on its own. HAOS cannot run Debian's
node exporter as a systemd unit the way the apps VM and the hypervisor do, so
the equivalent is an integration that turns host readings into entities, which
then flow out through the endpoint you just wired.

In HA: *Settings → Devices & Services → Add Integration → **System Monitor***.
It has no configuration to fill in.

By default it creates only a few sensors. Add the ones worth graphing from
*Settings → Devices & Services → Entities*, filtering on `System Monitor` and
enabling the disabled ones — processor use, memory use, disk use, and load
average are the set that matches what Node Exporter Full shows for the other
three machines.

Confirm they reached Prometheus. In Grafana's **Explore → Prometheus**:

```promql
{job="homeassistant", __name__=~"homeassistant_sensor.*"}
```

Expect the new sensors among the results within a scrape interval — 60 seconds
here, not the 15 the other targets use.

> **These will not appear on the Node Exporter Full dashboard, and that is not a
> fault.** They carry `job="homeassistant"` and are entity metrics with entity
> names; that dashboard is built on `job="node"` and the node exporter's metric
> names. This VM is visible in monitoring, just not on that panel set. Building
> a dashboard for these is separate work and deliberately not part of this
> guide.
````

- [ ] **Step 2: Trim the now-redundant sentence from `## Next`**

The `## Next` section currently opens its "Worth doing from here" paragraph with
the System Monitor suggestion, which step 9 now covers. Replace that paragraph
with:

```markdown
Worth doing from here: add this machine's two Kuma monitors from the registry
([uptime-kuma-monitors.md](uptime-kuma-monitors.md#home-automation--home-assistant-vm)).
```

- [ ] **Step 3: Update the metrics comment in `home-assistant/configuration.yaml`**

Replace the sentence beginning `Add the System Monitor integration if you want`
with:

```yaml
# System Monitor integration turns this VM's CPU/RAM/disk into entities, which
# then leave through this same endpoint — HAOS cannot run a node exporter as a
# systemd unit, so that is the equivalent. It is step 9 of
# docs/home-assistant-setup.md, not an optional extra: without it this machine
# contributes no host metrics at all.
```

- [ ] **Step 4: Verify the guide's steps are numbered without a gap**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -nE '^### [0-9]+\.' docs/home-assistant-setup.md | sed -E 's/^[0-9]+:### ([0-9]+)\..*/\1/' | tr '\n' ' '
```

Expected: `1 2 3 4 5 6 7 8 9`.

- [ ] **Step 5: Verify the fragment and the guide agree**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -n "System Monitor" home-assistant/configuration.yaml docs/home-assistant-setup.md CLAUDE.md
```

Expected: the fragment points at **step 9**, the guide has step 9 plus its
"How it works" mention, and CLAUDE.md's existing sentence still reads correctly
(it describes System Monitor as the closest equivalent to a node exporter, which
stays true).

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/felix/Source/home-lab" && git add docs/home-assistant-setup.md home-assistant/configuration.yaml && git commit -m "docs: make System Monitor a build step, not an aside

/api/prometheus exports entities, so without this integration the HA VM
contributes no host metrics at all. It was a suggestion after the guide
ended; it is now step 9, with the entity-vs-node-metrics distinction
stated where someone would otherwise go looking for it on Node Exporter
Full.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The consistency sweep

The repo's one hard rule: a fact appears in a compose file, a comment, a script
and a guide, and **all of them move together**. This task is where that is paid.

**Files:**
- Modify: `docs/roadmap/apps-vm-logs.md` (rewritten as landed)
- Modify: `docs/status.md` (the apps-logs row, the HA rows, the summary bullets)
- Modify: `CLAUDE.md` (topology, deploy order, docs layout, the two self-starting
  scripts, the Alloy pin note)
- Modify: `infra/monitoring/compose.yaml` (the Alloy pin comment's count)

**Interfaces:**
- Consumes: every path, name and decision produced by Tasks 1-5.

- [ ] **Step 1: Mark the roadmap landed in `docs/roadmap/apps-vm-logs.md`**

Replace the `## The shape of the answer` and `## Open questions` sections
(everything from `## The shape of the answer` to end of file) with:

```markdown
## ✅ Landed

See [docs/apps-logs-setup.md](../apps-logs-setup.md). A **second Alloy on the
apps VM**, logs-only, in `apps/alloy/` and started by
`scripts/init-apps-alloy.sh`. The rejected alternative was Coolify's own logging
driver pointed at Loki: no extra container, but a daemon-level change on a
machine Coolify expects to own, producing labels that would not match the infra
VM's — so the single pane would have split in two.

The design is recorded in
[specs/2026-08-16-apps-vm-logs-design.md](../superpowers/specs/2026-08-16-apps-vm-logs-design.md).
The three open questions this roadmap left were answered as follows.

**Where the config lives.** In `apps/`, because the repo root is the machine map
and the collector runs on that machine. `apps/` declaring no running service is
a rule about *applications* — Coolify owns those, and mirroring them here would
create a second source of truth. Nothing in Coolify's store describes a log
collector, so the rule keeps its force and gains one stated exception. Alloy as
a systemd unit from Grafana's apt repo was rejected: it adds a third-party apt
repo `init-unattended-upgrades.sh` would then have to exclude, and apt tracks
latest — so the image-pin policy would stop applying to the one collector whose
version parity with the other is the whole requirement.

**Whether Loki needs authentication.** No, matching `otlp.thefipster.de` — the
lab's other ingest endpoint, which carries none and documents how to add one.
What bounds the surface instead is **scope**: the Traefik router matches
`PathPrefix('/loki/api/v1/push')` only, so Loki's query API and its delete API
(live, because the compactor runs with `retention_enabled: true`) never leave the
infra VM. Grafana still reads over `monitoring-net`. Publishing `:3100` on the
LAN was rejected as the lab's first plaintext cross-machine hop.

**What labels make the two machines queryable together.** An `instance` label on
both collectors — `infra` and `apps` — beside the existing `job="docker"`, so
every query that exists keeps working and `{job="docker", instance="apps"}`
narrows. The values match `job="node"`'s, so one word means one machine in
metrics and logs alike. The apps VM additionally maps Coolify's own container
label to `coolify_resource`, because Coolify's Dockerfile-deployed resources
carry no `com.docker.compose.*` labels at all; Loki treats an unset label as
absent, so a label on one machine and not the other does not split the job.

**The known gap, stated rather than closed.** Uptime Kuma cannot monitor this
collector — its `docker.sock` is the infra VM's — and the collector's UI is
loopback-bound, so nothing probes it. A dead collector shows up as logs from
`instance="apps"` stopping. Recorded in
[uptime-kuma-monitors.md](../uptime-kuma-monitors.md#deliberately-not-monitored).
```

- [ ] **Step 2: Update the two affected rows in `docs/status.md`**

Replace the `Container logs from the apps VM` row with:

```markdown
| Container logs from the apps VM | ✅ deployed — a logs-only Alloy in `apps/alloy` pushing to the infra VM's Loki through a push-path-only router, [guide](apps-logs-setup.md). One query covers both Docker machines; `instance` tells them apart. Its own liveness is the one thing nothing watches — Kuma's socket is the infra VM's ([why](uptime-kuma-monitors.md#deliberately-not-monitored)) |
```

Replace the `home-assistant VM` row with:

```markdown
| home-assistant VM (HAOS + Supervisor) | ✅ deployed — onboarded, routed through Traefik at `ha.thefipster.de`, add-ons in from HA's store, and metrics wired: the long-lived token in the monitoring `.env` plus the System Monitor integration for host counters ([step 8](home-assistant-setup.md#8-wire-up-metrics), [step 9](home-assistant-setup.md#9-add-the-hosts-own-metrics)). Bare beyond that: no devices and no automations yet — [guide](home-assistant-setup.md) |
```

Replace the `Monitoring the apps + HA VMs` row with:

```markdown
| Monitoring the apps + HA VMs | ✅ deployed — apps VM scraped (`instance="apps"`) and now shipping logs too; HA scraped as `job="homeassistant"`, entities and host counters both. HA's are entity metrics by nature, so they do not appear on Node Exporter Full and no dashboard for them exists yet |
```

- [ ] **Step 3: Update the summary bullets in `docs/status.md`**

Delete the **Home Assistant's metrics token** bullet entirely. Replace the
**Container logs from the apps VM** bullet with one that keeps only what is
still outstanding on that machine:

```markdown
- **Backup for the apps VM.** `/data` holds Paperless' scanned documents and is
  covered by neither layer ([roadmap](roadmap/backup.md)) — layer 1 excludes the
  disk and the machine has not joined the restic repository. Paperless' own
  `document_exporter`, run by hand, is the whole answer today. Its container
  logs, by contrast, are now collected ([guide](apps-logs-setup.md)).
```

Leave the UPS bullet and the CI supply-chain bullet as they are.

- [ ] **Step 4: Update `CLAUDE.md` — the apps VM's topology paragraph**

The bullet beginning `- **apps VM** — Coolify (self-hosted PaaS).` states that
`apps/` declares **no running service**. Amend that clause to:

```markdown
so `apps/` declares exactly **one** running service and it is not an application
— `alloy/`, a logs-only collector pushing this machine's container stdout to the
infra VM's Loki (`docs/apps-logs-setup.md`). The no-compose rule is about
*applications*, which Coolify owns; nothing in Coolify's store describes a
collector, so there is nothing for it to drift from. Beside it:
```

...followed by the existing list (README, `.env.example`, `services.md`,
`stacks/`), left intact.

- [ ] **Step 5: Update `CLAUDE.md` — the deploy order**

This is `CLAUDE.md`'s own numbered deploy list, **not** the README's build order
— they are separate lists that happen to be numbered alike. Here
`init-coolify.sh` is 13 and `init-node-exporter.sh` is 14, so the new entry is
**15** and the "the home-assistant VM has no init script at all" entry
renumbers from 15 to **16**.

After the `scripts/init-node-exporter.sh` entry, add:

```markdown
15. `scripts/init-apps-alloy.sh` — the apps VM's log collector, and the second
   init script that **starts its own stack**. Same reason as Dockge's in a
   stronger form: that machine has no Dockge at all, so there is no UI a
   prepared-but-stopped stack could be started from, and no `/opt/stacks`
   symlink either. Creates `/opt/alloy` for read positions and nothing else —
   no `.env`, because the push endpoint takes no credential.
```

Then amend the `init-dockge.sh` entry, which currently calls itself *the only*
init script that starts its own stack, to say **one of two** and name
`init-apps-alloy.sh` as the other.

- [ ] **Step 6: Update `CLAUDE.md` — the docs list and the SSO/backup conventions**

In the `## Docs layout` guide sequence, insert `apps-logs-setup.md` between
`coolify-setup.md` and `home-assistant-setup.md`.

In the routing-convention section, note that Loki is now routed and that its
router is **path-scoped**, which no other router in the lab is:

```markdown
**One router in the lab is path-scoped rather than host-scoped**, and it is not
an inconsistency. `loki.thefipster.de` matches
`PathPrefix('/loki/api/v1/push')` only, so the apps VM can push logs in while
Loki's query API — and its delete API, live because retention is enabled —
stay on `monitoring-net`. Every other router matches a whole host because every
other backend is a UI or an API meant to be reached in full.
```

- [ ] **Step 7: Fix the Alloy pin count in both places**

`infra/monitoring/compose.yaml`'s Alloy comment says the tag is "Written down
FOUR times" and then lists three. It is now written in more places again.
Replace that sentence with an enumeration that cannot go stale by counting:

```yaml
    # The same tag appears in apps/alloy/compose.yaml (the apps VM's collector,
    # which MUST match — the two produce the labels of one pane),
    # docs/grafana-setup.md's troubleshooting `fmt` command, CLAUDE.md's
    # pin-exceptions list and init-monitoring.sh's UID table. Bump them together.
```

Then check `CLAUDE.md`'s pin-exceptions entry for `grafana/alloy`. It names the
tag and the reason for the full-patch pin but carries **no** count, so it needs
no edit — confirm that by reading it rather than assuming, since the sentence
above is being corrected precisely because a count went stale.

- [ ] **Step 8: Verify every claim of exclusivity that this work broke**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -rn "only init script\|declares \*\*no running service\*\*\|no running service\|FOUR times" CLAUDE.md apps/README.md infra/ scripts/ || echo "no stale exclusivity claims"
```

Expected: any remaining hit is a sentence that reads correctly **after** these
changes — for example a "one of two" phrasing. A surviving "the only init script
that" or "declares no running service" is a defect.

- [ ] **Step 9: Verify status.md has no unfinished rows left for this work**

```bash
cd "C:/Users/felix/Source/home-lab" && grep -n "⬜\|◐" docs/status.md || echo "no planned or half-done rows remain"
```

Expected: `no planned or half-done rows remain`. If a row still shows `◐` or
`⬜`, either it is genuinely outstanding (say so in the review) or Step 2 missed
it.

- [ ] **Step 10: Verify the whole tree's internal links still resolve**

```bash
cd "C:/Users/felix/Source/home-lab/docs" && grep -rho '](\.\{0,2\}/\?[A-Za-z0-9._/-]*\.md' *.md roadmap/*.md | sed 's/](//' | sort -u | while read -r p; do [ -e "$p" ] && : || echo "MISS $p"; done; echo "link check done"
```

Expected: `link check done` with no `MISS` lines above it.

- [ ] **Step 11: Commit**

```bash
cd "C:/Users/felix/Source/home-lab" && git add docs/roadmap/apps-vm-logs.md docs/status.md CLAUDE.md infra/monitoring/compose.yaml && git commit -m "docs: mark apps-VM logs and HA metrics done, and move what they invalidated

The roadmap's three open questions get their answers recorded, status
loses its last two unfinished rows, and the claims this work made false
— apps/ declaring no running service, Dockge being the only self-starting
init script, the Alloy tag's place count — are corrected together.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Final review — run after Task 6

Not a task; a gate before opening the PR.

- [ ] **Read the diff whole.** `git diff main...HEAD --stat`, then read each
      file's diff. This repo is verified by reading; this is the verification.
- [ ] **The two configs still agree.** `apps/alloy/config.alloy` and
      `infra/monitoring/alloy/config.alloy` must share the three relabel rules
      verbatim and differ only by `instance`, the `coolify_resource` rule, and
      the absence of metrics/OTLP on the apps side.
- [ ] **No literal IP address entered the repo:**
      `git diff main...HEAD -U0 | grep -nE '^\+.*[0-9]{1,3}(\.[0-9]{1,3}){3}'`
      must return nothing.
- [ ] **Shell script is LF and 755:**
      `git ls-files -s scripts/init-apps-alloy.sh` begins `100755`, and
      `git ls-files --eol scripts/init-apps-alloy.sh` shows `w/lf`.
- [ ] **Open the PR** against `main`. Do not merge — Felix integrates.
