# Container logs from the apps VM — design

**Date:** 2026-08-16
**Status:** design, approved — implementation follows
**Supersedes the open questions in:** [roadmap/apps-vm-logs.md](../roadmap/apps-vm-logs.md)

> **Written before the docs restructure landed.** This spec was authored at
> `docs/superpowers/specs/`, the location the convention named at the time, and
> the file paths in the *Files* table below name the pre-restructure tree —
> `docs/dns-records.md` rather than `docs/reference/dns-records.md`, and so on.
> Its links have been repaired; the table is left as the record of what was
> decided, when. Same treatment the restructure's own spec gave itself.

## The problem

Alloy discovers containers and tails their stdout through a **Docker socket**,
and that socket is the one on the machine Alloy runs on. `infra/monitoring/`
mounts the infra VM's. So every container on the **apps VM** — Coolify's own,
the third-party catalog in [apps/services.md](../../apps/services.md), and
anything Coolify builds from your source — logs where Loki cannot see it.

Metrics from that machine are unaffected and need nothing:
`scripts/init-node-exporter.sh` runs there and Alloy scrapes it by name as
`job="node"`, `instance="apps"`. Logs are the only gap, and this closes it.

## Shape of the answer

A **second Alloy on the apps VM**, logs-only, pushing to the existing Loki over
the LAN through Traefik. Loki, Prometheus, Tempo and Grafana all stay exactly
where they are; the infra VM's Alloy config changes by one line.

The rejected alternative was Coolify's own Docker logging driver pointed at
Loki. It needs no extra container, but it is a daemon-level change on a machine
Coolify expects to own outright, and the labels it produces would not match what
`loki.source.docker` produces on the infra VM — so the two halves of the single
pane would not query alike, which is the whole point of having one.

## Decisions

### 1. The collector lives in `apps/`, and starts itself

`apps/alloy/` — a compose stack in this repo, run with plain `docker compose` on
the apps VM. Not a Coolify resource: the thing that collects the logs must not
depend on the platform it exists to observe.

**The repo root is the machine map**, so a collector that runs on the apps VM
belongs in `apps/`. That directory's standing rule — it declares no running
service — is a rule about **applications**, and its reason is that Coolify owns
app definitions and mirroring them here would create a second source of truth
that drifts. A log collector is infrastructure this repo owns outright: nothing
in Coolify's store describes it, so there is nothing for it to drift from. The
rule keeps its force and gains one stated exception.

Two alternatives were weighed and dropped:

- **Alloy from Grafana's apt repo as a systemd unit**, symmetric with
  `init-node-exporter.sh`. It would have left `apps/` untouched, but it adds a
  third-party apt repo that `init-unattended-upgrades.sh` would then have to
  exclude by hand, and apt tracks latest — so the repo's image-pin policy would
  stop applying to one collector, on the machine where label parity with the
  other collector is the entire requirement.
- **A Coolify resource from its own Forgejo repo**, like every third-party app
  on that VM. Rejected on the dependency direction above, and because this repo
  would stop owning the config.

`scripts/init-apps-alloy.sh` **starts the stack itself**, which until now only
`init-dockge.sh` did. The reasoning is the same one, in a stronger form: Dockge
starts itself because Dockge is what you would otherwise start stacks with and
it is not up yet. The apps VM has **no Dockge at all, ever** — no
`/opt/stacks` symlink, nothing to drive start/stop/logs from — so a script that
prepared the stack and left it stopped would be handing you a `docker compose up`
with no home. `CLAUDE.md` currently calls Dockge's the *only* init script that
starts its own stack; that claim stops being true and has to name both.

The script name carries the machine because the stack name alone would not: there
is already an Alloy in `infra/monitoring/`, and `init-alloy.sh` would read as
that one.

### 2. Ingest: `loki.thefipster.de`, push path only, no auth

A new **exact** DNS record `loki.thefipster.de` → `infra ip`, and an ordinary
`websecure` router on the Loki container. Alloy on the apps VM does a direct
`loki.write` to `https://loki.thefipster.de/loki/api/v1/push`.

The record must be **exact**. This is the `pve.` case, not the `apps.` case: the
`*.thefipster.de` wildcard answers with the apps VM, and a missing record here
would have the collector pushing its logs at Coolify's proxy — which answers on
443 with a valid certificate, so it fails as a 404 rather than as a name that
does not resolve.

**The router is scoped to `PathPrefix('/loki/api/v1/push')`.** Routing the whole
host would put Loki's query API on the LAN unauthenticated, and its **delete**
API with it — which is live, because `loki.yaml` runs the compactor with
`retention_enabled: true` and a `delete_request_store`. Grafana keeps reading
over `monitoring-net` exactly as it does today, so the write path is the only
thing that leaves the box.

Loki therefore joins the `proxy` network, a deliberate reversal of the
"Not routed; Grafana is the only reader" comment it currently carries. That is
the same reversal Alloy underwent between monitoring phases 3 and 4, and it is
commented in place the same way. The consequence worth stating: every container
on `proxy` can now reach `loki:3100` directly. That is the lab's existing
single-tenant trust domain — the same one that already accepts `docker.sock`
mounts across the infra VM's stacks — but it is a widening and should read as a
decision.

**No authentication**, matching `otlp.thefipster.de`, which is the lab's other
unauthenticated ingest endpoint and carries a comment saying how to add a
middleware later. Adding one here and not there would be the inconsistency, and
it would put a secret in front of the collector before it can start.

Two paths were considered and rejected:

- **Converting to OTLP and reusing `otlp.thefipster.de`.** No new record, no new
  router, no change to Loki. But OTLP has no concept of a Loki label — the round
  trip through `otelcol.receiver.loki` and `otelcol.exporter.loki` carries labels
  as attributes, promotes them back only via hint attributes upstream has been
  deprecating, and derives `job` from OTel service semantics rather than from the
  `job = "docker"` set at the source. The apps VM's containers would not answer
  to `{job="docker"}`, which is precisely the split pane this design exists to
  avoid. It also merges machine-level container stdout into the pipeline the
  applications emit to, so any later change to one silently applies to the other.
- **Publishing Loki's `:3100` on the LAN.** One line, no record, no certificate.
  It would be the lab's first cross-machine hop in plaintext and its first
  published port that Traefik does not front — contradicting the reasoning that
  put OTLP behind Traefik rather than on open ports.

### 3. Labels: one new dimension, `instance`

`loki.source.docker` on **both** machines gains an `instance` label — `infra`
and `apps` — beside the existing `job="docker"`.

This is the roadmap's third open question. Without it the two machines' logs are
indistinguishable, and a stack name that exists on both collides into one
stream. With it, `{job="docker"}` still covers everything (so nothing that
queries Loki today changes) and `{job="docker", instance="apps"}` narrows to one
machine. The value set matches what `job="node"` already uses — `infra`, `apps`,
`pve` — so one word means the same machine in both metrics and logs.

The three existing relabel rules are copied verbatim: `compose_project`,
`compose_service`, `container`. **They will be partly empty on this machine, and
that is expected.** Coolify deploys its compose-based resources through Docker
Compose, so those carry the `com.docker.compose.*` labels; anything deployed
straight from a Dockerfile does not, and for those `container` is the only label
that identifies the log.

So the apps VM gets **one rule the infra VM does not have**, mapping Coolify's
own container label to `coolify_resource`. Loki treats an unset label as absent
rather than as empty, so a label present on one machine and not the other does
not split `{job="docker"}` — the parity that matters is preserved. This is what
makes a Dockerfile-deployed resource identifiable by something other than a
container ID.

**The exact source label name must be verified on the machine.** Coolify's label
set is not pinned by this repo and has changed across versions. The guide carries
a `docker inspect` step for reading it, and the config carries a comment saying
this is the one line to change if it differs. Getting it wrong is silent: the
label is simply absent, and everything else still works.

### 4. Liveness: a stated blind spot, not a monitor

**Uptime Kuma gets no monitor for this collector**, recorded as a deliberate
non-row.

Kuma cannot see it. Kuma's container-state monitors work by reading a
`docker.sock`, and the one it holds is the **infra VM's** — that is exactly what
lets it report on stacks it shares no network with, and exactly why it cannot
report on a container on another machine. The collector's own component UI is
loopback-bound like the infra VM's, so there is no HTTP endpoint to probe either.

The signal that it has died is **logs from `instance="apps"` stopping**, noticed
by eye in Grafana. That is a real blind spot and belongs in the same list as the
weekly `restic check` having no heartbeat — stated rather than papered over.

Two ways to close it were weighed and dropped:

- **Binding the collector's `:12345` to all interfaces and scraping its
  self-metrics** as `job="alloy"`, `instance="apps"`. The existing `ServiceDown`
  alert (`up == 0`) would then cover it with no new rule, and `apps.thefipster.de`
  needs no DNS row. Rejected because it puts Alloy's component graph on the LAN
  where the infra VM's equivalent is deliberately loopback-only — buying an alert
  by making the two collectors disagree about their own exposure.
- **A Kuma HTTP monitor on the push URL** accepting `405`, which a `GET` to a
  push endpoint returns. It would prove DNS, Traefik, the certificate and Loki
  being up — the *receiving* half — while saying nothing about whether anything
  is pushing. A green tick that does not mean what it reads as is worse than a
  stated gap.

### 5. Registries and docs

`loki.thefipster.de` gets its row in `dns-records.md` **and goes into both
verify sweeps**. Those `for n in git dockge home …` loops are enumerated by hand,
so a name that is not added there is invisible to the check that exists to catch
exactly this class of mistake — including the IPv6 sweep, where a stray public
AAAA would send the lab's logs off the LAN without failing.

`sso-applications.md` gains a non-row in the shape of its existing
"The backup job (not an application at all)" section: the ingest endpoint has no
browser UI to gate and speaks no OIDC, so it was never eligible for either
pattern, and forward-auth would break the push outright.

`uptime-kuma-monitors.md` gains the non-row from decision 4.

A new guide, `docs/apps-logs-setup.md` (**Runs on:** apps VM), slots into the
build order after `coolify-setup.md` and before `home-assistant-setup.md`.
One guide per build-order step, with its own verification and its own
troubleshooting.

**The infra half ships before its consumer exists and simply waits.** The Loki
router is in `infra/monitoring/compose.yaml` from the first bring-up, routing a
name nothing pushes to yet — the same arrangement as
`infra/traefik/dynamic/ha.yaml`, which was live from the start and failing to
reach a backend that did not exist. Nothing in `grafana-setup.md` becomes
conditional on the apps VM.

### 6. What deliberately does not change

- **Backup.** `apps/alloy`'s only state is Alloy's read positions under
  `/opt/alloy`, which are regenerable by construction — losing them re-reads
  logs, it does not lose them. The apps VM has not joined the restic repository
  anyway. No `backup.sh`, and none wanted.
- **`infra/monitoring`'s backup and restore.** Loki is Tier 3 and not in the
  snapshot; `restore.sh` stays narrow on `postgres/` for the reason it already
  documents.
- **Retention and sizing.** Loki keeps 14 days. A second machine's container
  stdout roughly doubles what that holds; retention is the lever if it ever
  matters, and nothing here pre-empts it.
- **Homepage.** Loki has no UI, so there is no tile to add.
- **Out-of-order writes.** Two collectors write to one Loki, but the `instance`
  label puts them in different streams, so neither can arrive out of order
  relative to the other.

## Files

| File | Change |
|------|--------|
| `apps/alloy/compose.yaml` | new — logs-only Alloy, `v1.18.1`, no networks block, no `.env` |
| `apps/alloy/config.alloy` | new — docker discovery → relabel → `loki.source.docker` → remote `loki.write` |
| `scripts/init-apps-alloy.sh` | new — creates `/opt/alloy`, starts the stack, mode `100755` |
| `infra/monitoring/compose.yaml` | Loki gains the push router + `proxy` |
| `infra/monitoring/alloy/config.alloy` | `instance = "infra"` on `loki.source.docker` |
| `docs/apps-logs-setup.md` | new guide |
| `docs/dns-records.md` | `loki.` row + both verify sweeps |
| `docs/sso-applications.md` | non-row |
| `docs/uptime-kuma-monitors.md` | non-row |
| `docs/grafana-setup.md` | log verification covers two machines |
| `docs/roadmap/apps-vm-logs.md` | marked landed; the three open questions answered |
| `docs/status.md` | the apps-logs row and the summary bullets |
| `apps/README.md` | the one-service exception, the file table, the scripts table |
| `README.md` | build order |
| `CLAUDE.md` | apps VM topology, the Alloy pin count, two self-starting init scripts, the docs list, Loki being routed |

## Verification

None of this can be verified from the machine the repo is edited on — it is
config and prose, and it proves itself on the VMs. The guide's checks, in order,
are what stand in for a test suite:

1. `getent hosts loki.thefipster.de` answers with the **infra** VM, not the apps
   VM. This is the check that catches the wildcard trap, and it must be run
   before anything is started.
2. `curl -sI https://loki.thefipster.de/loki/api/v1/push` returns `405` with no
   certificate warning — the router, the wildcard and Loki, without pushing
   anything.
3. `docker inspect` on a Coolify-managed container, reading its label set, before
   trusting the `coolify_resource` rule.
4. In Grafana: `{job="docker", instance="apps"}` returns lines, and
   `{job="docker"}` returns both machines.
5. `compose_service` is populated for a Coolify compose resource and empty for a
   Dockerfile one — confirming the expected asymmetry rather than being surprised
   by it later.
