# Monitoring configuration (infra VM)

The [Grafana platform](grafana-setup.md) is up and both datasources are green.
This guide points it at something.

It **grows**: phase 2 (container logs) is here now; the service metrics
endpoints, OTLP intake and dashboards/alerts append as phases 3–5 land. See
[roadmap/monitoring.md](roadmap/monitoring.md) for what's coming.

## Prerequisites

[grafana-setup.md](grafana-setup.md) complete and verified — Grafana reachable
at `https://grafana.thefipster.de`, both datasources passing **Test**, and the
`up` query in Explore returning series for `alloy`, `prometheus`, `loki` and
`grafana`.

## Part 1 — Container logs

Alloy gains the Docker socket and four new components: `discovery.docker` lists
every container on the VM, `discovery.relabel` maps Docker metadata onto Loki
labels, `loki.source.docker` tails each container, and `loki.write` ships to
Loki. New containers are picked up within 15 seconds of starting.

> **This grants Alloy root-equivalent control of the VM's Docker.** The socket
> is mounted `:ro`, which matches how Traefik declares it, but that is **not**
> a security boundary — the *mount* is read-only, the *API behind it* is not.
> Anything holding that socket can start a privileged container. Dockge,
> Traefik and the Forgejo runner already hold it; phase 1 deliberately withheld
> it from Alloy until there was a capability that actually needed it. That
> capability is this one.

Apply:

```bash
cd ~/home-lab && git pull
```

```bash
cd ~/home-lab/infra/monitoring && docker compose up -d alloy
```

```bash
docker compose logs --tail=20 alloy
```

Expect no errors about the socket or the config. Then, in Grafana
**Explore → Loki**:

```logql
{job="docker"}
```

Lines should appear within seconds. Next, prove the labelling works across
stacks and not just for the monitoring one:

```logql
{compose_project="authentik"}
```

Then check nothing is silently missing:

```logql
sum by (compose_service) (count_over_time({job="docker"}[5m]))
```

One row per running service. If a service you expect is absent, it is not being
collected — see Troubleshooting.

## Part 2 — Traefik access logs

Traefik gains `--accesslog=true --accesslog.format=json`. The access log goes to
stdout, so Alloy already collects it — no change to the monitoring stack is
needed.

> **This restarts Traefik**, which briefly interrupts *every* routed service —
> Grafana, Forgejo, Dockge, Authentik. Do it in the same maintenance window as
> Part 1. Nothing is lost; connections just drop for a few seconds.

```bash
cd ~/home-lab/infra/traefik && docker compose up -d
```

Verify, after generating some traffic by loading any lab URL:

```logql
{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400
```

**Why `| __error__=""` is not optional here.** Traefik's *application* log stays
human-readable on purpose — it is what you read when ACME issuance misbehaves —
while its *access* log is JSON. Both go to the same stdout, so this one stream
carries two shapes. A bare `| json` tags every plain line with a parse error;
`| __error__=""` drops those and leaves the access-log entries.

Useful fields on those lines: `DownstreamStatus`, `RequestHost`, `RequestPath`,
`Duration`, `ServiceName`.

## Part 3 — Querying

### The four labels

Everything is labeled by exactly four things:

| Label | Example | Source |
|-------|---------|--------|
| `job` | `docker` | static, set by Alloy |
| `compose_project` | `monitoring`, `authentik`, `traefik` | the compose project name |
| `compose_service` | `grafana`, `server`, `db` | the service name inside that project |
| `container` | `monitoring-grafana-1` | the Docker container name |

**There are only four on purpose.** Labels are Loki's index, and every distinct
combination creates a stream. A label with unbounded values — a request ID, a
path, a user — multiplies streams without limit and is the standard way people
destroy a Loki install. Everything else you might want to filter on stays in
the log line and is parsed at query time, which costs nothing at ingest.

### Starters

Authentik's structured logs, parsed on read:

```logql
{compose_service="server"} | json | event != ""
```

Plain substring search across everything:

```logql
{job="docker"} |= "error"
```

Which service is loudest right now:

```logql
sum by (compose_service) (rate({job="docker"}[5m]))
```

Everything from one stack:

```logql
{compose_project="forgejo-lab"}
```

## Troubleshooting

**No logs at all.** Check Alloy's component health — its UI is bound to the VM's
loopback, so tunnel in as described in [grafana-setup.md](grafana-setup.md):

```bash
ssh -L 12345:127.0.0.1:12345 <infra-vm>
```

A socket permission problem shows up as an unhealthy `discovery.docker`
component. `docker compose logs alloy` carries the detail.

**Logs arrive, but with no `compose_*` labels.** Either the container was not
started by Compose (it genuinely has no compose labels), or `relabel_rules`
isn't wired. In `alloy/config.alloy`, `loki.source.docker` must receive the
**raw** `discovery.docker.containers.targets` with the rules passed separately
as `relabel_rules` — passing `discovery.relabel.containers.output` to `targets`
strips the metadata and breaks tailing.

**Duplicate lines.** Should not happen: Alloy keys its tailers on the container
ID, so a container on two networks is still tailed once. If you genuinely see
duplicates, look for a second Alloy instance rather than a config bug.

**Alloy won't load the config.**

```bash
docker run --rm -v /opt/stacks/monitoring/alloy/config.alloy:/c.alloy:ro grafana/alloy:v1.18.0 fmt /c.alloy
```

Non-zero exit means a syntax error. Component and argument mistakes appear at
startup in `docker compose logs alloy`.

**Disk filling up.** Loki retention is 14 days and the label set is bounded, so
the blast radius is disk, not cardinality. Find the loudest service with the
`count_over_time` query in Part 1, then `df -h` and
`du -sh /opt/monitoring/loki`.

**Traefik won't start after Part 2.** The two flags are additive and
independently revertible — comment them out and `docker compose up -d`.

## Verification checklist

- [ ] `{job="docker"}` returns lines within seconds
- [ ] `{compose_project="authentik"}` returns — labelling works across stacks
- [ ] `sum by (compose_service) (count_over_time({job="docker"}[5m]))` lists every running service
- [ ] `{compose_service="server"} | json | event != ""` — Authentik's JSON parses at query time
- [ ] `{compose_service="traefik"} | json | __error__="" | DownstreamStatus >= 400` — access logs on and structured
- [ ] Restarting Alloy causes no duplicate flood (read positions persisted)
- [ ] The phase 1 `up` metrics query still works — logs did not disturb metrics

## What's next

Phases 3–5 in [roadmap/monitoring.md](roadmap/monitoring.md): the other stacks'
Prometheus endpoints and host metrics, OTLP intake for the apps VM, then
dashboards and the two or three alerts worth having.
