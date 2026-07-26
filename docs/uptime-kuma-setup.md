# Uptime Kuma — independent status monitoring (infra VM)

**Runs on:** infra VM

**Prerequisite:** [grafana-setup.md](grafana-setup.md) complete — Kuma watches
that stack, so it is the last thing built.

[Uptime Kuma](https://github.com/louislam/uptime-kuma) is a self-contained
status monitor at **`https://uptime.thefipster.de`**. It checks the routed
services end-to-end over HTTPS and reads every container's state from the
Docker API, then pushes a notification when something breaks.

It is the lab's **notification layer**, and the split with Grafana is
deliberate: **Kuma notices and pokes you; Grafana explains why.** Grafana's
alert rules stay UI-only — see [How it works](#how-it-works).

Kuma also closes a blind spot the monitoring stack documents about itself: if
Alloy dies, `up` goes stale, the `ServiceDown` rule evaluates NoData → OK, and
nothing fires for the most total failure there is. A watcher that shares no
process, no network and no compose project with that pipeline is the only thing
that catches it.

## Steps

### 1. Verify DNS

`uptime.thefipster.de` needs an exact host record pointing at the infra VM. The
registry is [dns-records.md](dns-records.md); the router how-to is
[wildcard-dns-udr.md](wildcard-dns-udr.md).

```bash
getent hosts uptime.thefipster.de
```

It must return the **infra** VM. Without an exact record the name falls through
the `*.thefipster.de` wildcard to the apps VM and you get Coolify's 404 behind a
perfectly valid certificate — which looks like a Traefik problem and is not.

### 2. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-uptime-kuma.sh
```

It creates `/opt/uptime-kuma`, ensures the `proxy` network exists, and symlinks
the stack into `/opt/stacks`. There is **no `.env`** and nothing to fill in —
Kuma has no database and creates its admin account through its own first-run
form, which makes this the only stack in the repo without one.

### 3. Start the stack

```bash
cd /opt/stacks/uptime-kuma && docker compose up -d
```

```bash
docker compose ps
```

One container, `running`, and **no published ports** — everything arrives
through Traefik.

### 4. Create the admin account

Open **`https://uptime.thefipster.de`**. Kuma's setup form appears **directly,
with no Authentik redirect**. Create the admin account there.

> **That missing redirect is the point, not a bug.** Kuma is the one service in
> the lab that deliberately joins neither SSO pattern. Gating the outage
> dashboard behind the identity provider would make an Authentik outage the one
> failure you cannot see, and the break-glass path would need `ssh` at exactly
> the moment you are already firefighting. Kuma's own login (bcrypt, optional
> 2FA) protects it instead. The reasoning is recorded in
> [sso-applications.md](sso-applications.md#uptime-kuma-deliberately-not-joined).

Check the padlock: the trusted Let's Encrypt **wildcard** is served, same as
every other lab host. That confirms the router picked up the shared certificate
with no TLS labels of its own.

### 5. Add the monitors

First register the Docker host, once: **Settings → Docker Hosts → Add**,
connection type **Socket**, path `/var/run/docker.sock`, then **Test**.

> This is the single step most likely to fail, and its **Test** button is the
> whole verification. If it errors, the socket is not mounted — see
> [Troubleshooting](#troubleshooting).

Then create the monitors. **The full list is the registry:
[uptime-kuma-monitors.md](uptime-kuma-monitors.md)** — grouped by stack, with the
monitor type for each and the reasoning behind every absence. It lives outside
this guide because it grows with every service you add, most of which this guide
will never mention.

For each row there: **Add New Monitor**, pick the type, paste the target, save.

Two things to know before you start, both explained in the registry:

- Docker monitors only see containers on **this** VM — that is the only socket
  Kuma can read. Services on the apps and home-assistant VMs get HTTP monitors.
- Container names are **derived, not configured** (`<project>-<service>-1`), so
  if a Docker monitor will not come up, check the real name:

```bash
docker ps --format '{{.Names}}'
```

The Coolify and Home Assistant monitors will be **red** until those machines are
built — they are the last two steps of the
[build order](../README.md#build-order).

### 6. Wire notifications (ntfy)

Generate a topic:

```bash
openssl rand -hex 16
```

In Kuma: **Settings → Notifications → Setup Notification**, type **ntfy**,
server `https://ntfy.sh`, topic = the string you just generated. Tick **Default
enabled** *and* **Apply on all existing monitors**.

> **Both ticks matter.** Kuma does not attach a notification to existing
> monitors retroactively, and it does not add it to new ones unless it is the
> default. Miss them and you get monitors that watch faithfully and never tell
> you anything.

> **The topic is a bearer secret, in both directions.** Anyone who knows it can
> read every alert about the lab *and* push fake ones to your phone. It lives
> only in Kuma's database — it is in no file in this repo, and it must never be
> committed.

Subscribe on your phone with the ntfy app, or in a browser at
`https://ntfy.sh/<your-topic>`. Verify with Kuma's **Test** button.

### Checklist

The runtime proof, in order. `monitoring-loki-1` is the deliberate choice here:
it sits on `monitoring-net` only, so Kuma can reach it by **no network path at
all** — a working monitor proves the Docker socket is doing the work.

- [ ] Every monitor in [uptime-kuma-monitors.md](uptime-kuma-monitors.md) exists
      and is green (except Coolify and Home Assistant, if those VMs are not built yet)
- [ ] Stop Loki and watch its monitor go red, with an ntfy push arriving:

```bash
docker stop monitoring-loki-1
```

- [ ] Start it again and confirm recovery, with a second push:

```bash
docker start monitoring-loki-1
```

- [ ] No regressions: Grafana, Authentik and Forgejo still load, and Grafana's
      alert rules still show `Normal`

## Next

The infra VM is complete. **[coolify-setup.md](coolify-setup.md)** is next — the
apps VM — followed by [home-assistant-setup.md](home-assistant-setup.md). The full
sequence is the [README build order](../README.md#build-order).

## Troubleshooting

**`uptime.thefipster.de` returns a 404 and Traefik logs nothing about it.** The
DNS record is missing, so the name fell through the wildcard to the apps VM and
you are looking at Coolify's 404 — behind a valid certificate, which is what
makes it convincing:

```bash
getent hosts uptime.thefipster.de
```

**Every Docker monitor fails with a connection error.** The socket is not
mounted, or the path in the Docker Host entry is wrong:

```bash
docker compose exec uptime-kuma ls -l /var/run/docker.sock
```

**A Docker monitor is red but the container is running.** Kuma matches on
container **name**, and Compose builds it as `<project>-<service>-1`. Paste the
exact strings from:

```bash
docker ps --format '{{.Names}}'
```

**An HTTP monitor is red with a TLS error.** Almost always the guest clock after
a snapshot rollback — the same failure mode as every other TLS client in the
lab, which is why `scripts/init-host.sh` relaxes the time-sync step policy
before it installs anything:

```bash
timedatectl status
```

**A monitor went red but no ntfy push arrived.** Either the subscribed topic
does not match the one in Kuma, or the notification was never attached to that
monitor — check **Default enabled** and **Apply on all existing monitors** in
the notification's settings, then re-test.

## Layout on the server

| What | Where |
|------|-------|
| Compose project (source of truth) | `infra/uptime-kuma/compose.yaml` in this repo |
| Stack as Dockge sees it | `/opt/stacks/uptime-kuma` → symlink into the repo |
| Kuma's data (SQLite, uploads) | `/opt/uptime-kuma/` |

**Monitors and notifications live in that SQLite, not in the repo.** Nothing
about them is provisioned from a file, which is exactly why the inventory table
in [step 5](#5-add-the-monitors) exists — it is what makes a rebuild
reproducible. Back up `/opt/uptime-kuma` and you keep the monitors and their
history; lose it and the table above is how you get them back.

## How it works

**Why this is a separate stack.** `infra/monitoring` is a white-box *pipeline* —
Alloy collects, Prometheus/Loki/Tempo store, Grafana displays — and it lives
inside everything it watches: same VM, same Docker daemon, scraping internal
`/metrics`. Kuma is black-box and only works from *outside*. In the same compose
project, one `docker compose down` on monitoring would take out the pipeline
**and** the thing that tells you the pipeline is down. Its independence is
functional, not tidiness.

**Why no SSO, and what that costs.** Every other UI in the lab joins Authentik
by OIDC or forward-auth. Kuma has no OIDC, so the convention would point at
forward-auth — and forward-auth would hide the exact outage the dashboard
exists to report. Local login is the trade. The cost is real and worth naming:
anyone on the LAN reaches the login page, where every other infra UI would have
shown them Authentik first. Kuma's own authentication is what stands there
instead.

**Why the Docker socket instead of joining more networks.** The unexposed
containers — Authentik's database, Redis and worker, plus Loki, Prometheus and
Tempo — sit on private compose networks Kuma is not on. Asking the Docker API
sidesteps that entirely, so **no existing stack changed** to make this work:
`monitoring-net` and `authentik-net` are still internal and
`infra/authentik/compose.yaml` was not touched.

The socket is the usual trade. `:ro` makes the *mount* read-only, not the API
behind it, so this is root-equivalent control of the VM's Docker — the fourth
such mount in the lab, after Dockge, Traefik and Alloy. Acceptable only because
this is a single-tenant box.

**Why hosted ntfy.sh rather than self-hosting it.** A self-hosted ntfy on this
VM would share fate with everything it reports on: the VM goes, and so does the
notification about it. The trade accepted instead is that alert text — mostly
hostnames — transits a third party. Moving to a self-hosted server later changes
one URL in Kuma's notification settings and nothing else.

**Why Grafana's alerts stay UI-only.** Kuma owns outbound notification. Adding a
Grafana contact point would produce duplicate alerts for overlapping conditions
and two places to tune them. The rules there remain visible in the Alerting UI
and on panels — which is what you want when you have already been paged and are
looking for the reason.

**Kuma runs on the infra VM and dies with it.** It catches a stack failing —
the common case, and the one that used to go unnoticed. It does not catch the
VM failing. That is the honest boundary of a single-host watcher, and closing it
would mean putting Kuma somewhere else entirely.

## Next

The infra VM is complete. **[coolify-setup.md](coolify-setup.md)** is next — the
apps VM — followed by [home-assistant-setup.md](home-assistant-setup.md). The full
sequence is the [README build order](../README.md#build-order).
