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

## The shape of the answer

Two candidate designs, both keeping Loki on the infra VM:

- **A second Alloy, on the apps VM**, in `logs-only` configuration, pushing to
  Loki over the LAN. Symmetric with the collector already running, reuses its
  config idiom, and needs no change to what Loki accepts beyond an ingest path.
  Costs a container and a socket mount on a machine this repo does not declare
  stacks for — which is the interesting question, since Coolify owns that VM's
  Docker.
- **Coolify's own logging driver**, pointed at Loki. No extra container. Costs a
  Docker daemon-level change on a machine Coolify expects to own outright, and
  the labels would not match what Alloy produces on the infra VM, so the two
  halves of the pane would not query alike.

The first looks right. Decide before building.

## Open questions

- **Where does the second Alloy's config live?** `apps/` holds no compose by
  design. A logs-only collector is infrastructure, not an application, so it may
  belong in `infra/` despite running elsewhere — or in the Forgejo repo with
  everything else Coolify deploys.
- **Does Loki need authentication?** It is currently reachable only inside the
  infra VM's `monitoring-net`. Accepting pushes from another machine changes
  that, and the LAN is not a trust boundary this repo has leaned on before.
- **What labels make the two machines queryable together?** The infra VM's
  container logs carry labels Alloy derives from Docker. The apps VM's must
  match, or `{job="..."}` splits in two and every dashboard needs an edit.
