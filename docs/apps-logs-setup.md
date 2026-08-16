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
