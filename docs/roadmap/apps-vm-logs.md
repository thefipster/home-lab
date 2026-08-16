# Roadmap: Container logs from the apps VM

Goal: get container stdout from the **apps VM** into Loki, so the single pane in
Grafana covers both Docker machines instead of one.

This is a gap for the whole machine, not for any one application. Coolify's own
containers, the applications it builds from your source, and the third-party
services in [apps/services.md](../../apps/services.md) are all equally invisible
today. It is the last piece of the ambition
[roadmap/monitoring.md](monitoring.md) opened with — "every stack on the infra VM
and, later, the apps the apps VM runs".

## What already works, and why logs are the exception

Metrics from this VM are **not** affected and need nothing:
`scripts/init-node-exporter.sh` runs there, Alloy on the infra VM scrapes it
over the LAN by name, and it carries `job="node"` with `instance="apps"` like the
other two hosts.

Logs are different because Alloy discovers containers and tails their stdout
through a **Docker socket**, and it is mounted from the machine Alloy runs on.
`infra/monitoring/compose.yaml` bind-mounts the infra VM's socket; there is no
socket for the apps VM in that container and there should not be one.

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
