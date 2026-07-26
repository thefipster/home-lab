# Grafana platform setup — Grafana, Prometheus, Loki, Alloy (infra VM)

One place to see the lab's metrics and (from phase 2) its logs, at
**`https://grafana.thefipster.de`**, behind the [Traefik stack](traefik-setup.md)
under the same wildcard cert, with login through
[Authentik](authentik-setup.md) by **OIDC**.

| Piece | Role |
|-------|------|
| **Grafana** | the single pane — dashboards, Explore, and the only routed service here |
| **Prometheus** | metrics **storage + query only**; it never scrapes anything |
| **Loki** | log storage — **empty until phase 2**, see below |
| **Alloy** | the **only** collector; scrapes and pushes into Prometheus |
| **Postgres** | Grafana's database (dedicated to this stack) |

> **This guide stands up the platform.** Configuring what it actually watches —
> container logs, service metrics, dashboards — is
> [monitoring-setup.md](monitoring-setup.md). Do this one first: it's the
> prerequisite for that one.

> **This is phase 1 — the stack skeleton.** Container-log collection, the other
> stacks' metrics endpoints, host metrics, OTLP intake, dashboards and alerts
> are phases 2–5, tracked in [roadmap/monitoring.md](roadmap/monitoring.md).
> **Loki being empty at the end of this guide is expected, not a fault:**
> nothing collects logs yet. What phase 1 proves is that the *metrics* path
> works end to end and that Loki is up and wired.

> **Break-glass first.** Grafana's **local `admin` login stays enabled** on
> purpose — an Authentik outage must not lock you out of the very thing that
> would show you why. The password is `GRAFANA_ADMIN_PASSWORD` in
> `infra/monitoring/.env`. Never set `GF_AUTH_DISABLE_LOGIN_FORM`.

## Layout on the server

Same two-location convention as the other stacks:

| What | Where |
|------|-------|
| Compose project (this repo) | `infra/monitoring/` |
| Persistent data | `/opt/monitoring/{postgres,grafana,prometheus,loki,alloy}` |

Config files (`alloy/config.alloy`, `loki/loki.yaml`, `prometheus/prometheus.yml`,
`grafana/provisioning/`) live **in the repo** and are bind-mounted read-only, so
the repo stays the source of truth: edit, `git pull` on the VM, restart.

## Prerequisites

- [Traefik](traefik-setup.md) up, with the wildcard cert issued.
- [Authentik](authentik-setup.md) up — needed for Part 3, not for Parts 0–2.
- Docker installed ([`scripts/init-host.sh`](../scripts/init-host.sh)).
- **Infra VM RAM ≥ 8 GB.** This adds five containers to a box already running
  Authentik and Forgejo. The lab VM was raised to 10 GB before phase 1; at the
  original 4 GB an OOM kill would most likely take Authentik with it.

## Part 0 — DNS

`grafana.thefipster.de` needs an **exact Host (A) record** pointing at the infra
VM, added exactly like the rows in [wildcard-dns-udr.md](wildcard-dns-udr.md):

| Name | Address |
|------|---------|
| `grafana.thefipster.de` | `192.168.1.41` |

> **Don't skip this.** `*.thefipster.de` resolves to the **apps VM** (`.42`).
> Without the exact record the name silently points at the wrong box, and you
> get Coolify's 404 instead of Grafana — with a perfectly valid certificate,
> which makes it look like a Traefik problem when it isn't.

Verify from a LAN client:

```bash
nslookup grafana.thefipster.de
```

Expect `192.168.1.41`.

## Part 1 — Bring up the stack

```bash
cd ~/home-lab
scripts/init-monitoring.sh    # data tree + ownership, .env secrets, symlink for Dockge
```

The script generates `GRAFANA_DB_PASSWORD` and `GRAFANA_ADMIN_PASSWORD` into
`infra/monitoring/.env`. The Authentik values stay blank and
`GRAFANA_OIDC_ENABLED=false` — deliberate, so you can verify the stack works
*before* SSO is in the picture. Then:

```bash
cd ~/home-lab/infra/monitoring
docker compose up -d
docker compose ps
```

First start pulls roughly 1 GB of images. Expect five services, `db` healthy,
none restarting.

> **A container restart-looping on first boot is almost always ownership.**
> Each image runs as a different user — Grafana `472`, Prometheus `65534`, Loki
> `10001`, Alloy root — and each must own its dir under `/opt/monitoring`.
> Re-running `scripts/init-monitoring.sh` sets all of them; check with
> `docker compose logs <service>` and `ls -ln /opt/monitoring`.

## Part 2 — Verify the stack (before touching SSO)

**Grafana is served over the wildcard cert:**

```bash
curl -sI https://grafana.thefipster.de | head -1
```

Expect a `HTTP/2 302` (Grafana redirecting to `/login`). A cert warning here
means Traefik, not Grafana — see [traefik-setup.md](traefik-setup.md).

**Loki is alive (empty, but ready):**

```bash
docker compose exec loki wget -qO- localhost:3100/ready
```

Expect `ready`.

**Alloy's components are healthy.** Its UI is bound to the VM's loopback only —
no hostname, no cert, no route. Tunnel to it:

```bash
ssh -L 12345:127.0.0.1:12345 <infra-vm>
```

Then open `http://127.0.0.1:12345` and confirm every component reports
**Healthy**. This is where you debug collection.

**In the browser**, at `https://grafana.thefipster.de`, log in as **`admin`**
with `GRAFANA_ADMIN_PASSWORD` from `.env`, then:

1. **Connections → Data sources** — Prometheus (default) and Loki are both
   listed, and both pass **Test**. They are marked read-only because they are
   provisioned from the repo; that is correct.
2. **Explore → Prometheus**, run:
   ```
   up
   ```
   Expect one series each for `job="alloy"`, `"prometheus"`, `"loki"` and
   `"grafana"`. **This is the end-to-end proof**: Alloy scraped it, remote-wrote
   it, Prometheus stored it, Grafana read it back.
3. **State really is in Postgres** — restart the stack and log in again:
   ```bash
   docker compose down && docker compose up -d
   ```
   Your account and settings survive. (Metrics history survives too; it's in
   Prometheus's bind mount.)

## Part 3 — Authentik OIDC

Grafana joins SSO by **native OIDC**, not forward-auth — it has real SSO
support, and the lab's convention is one pattern or the other, never both. So
there is no `authentik@docker` middleware label on its router, and nothing in
`infra/authentik/` changes.

### 1. Create the provider

**Admin → Applications → Providers → Create → OAuth2/OpenID Provider**

| Field | Value |
|-------|-------|
| Name | `grafana` |
| Authorization flow | the default explicit- or implicit-consent flow |
| Client type | **Confidential** |
| Redirect URI — **Strict** | `https://grafana.thefipster.de/login/generic_oauth` |
| Signing key | the default self-signed certificate is fine |

Save, then copy the **Client ID** and **Client Secret**.

### 2. Create the application

**Admin → Applications → Applications → Create** — name `Grafana`, slug
`grafana`, provider `grafana`. Save.

### 3. Bind who may use it

On the application's **Policy / Group / User Bindings** tab → **Bind existing
Group** → `lab-users` (created in [authentik-setup.md](authentik-setup.md)).
Authentik denies access to an application with no matching binding.

### 4. Wire Grafana

In `infra/monitoring/.env`:

```bash
GRAFANA_OIDC_ENABLED=true
GRAFANA_OIDC_CLIENT_ID=<client id from step 1>
GRAFANA_OIDC_CLIENT_SECRET=<client secret from step 1>
```

```bash
docker compose up -d grafana
```

### 5. Verify

The login page now shows **Sign in with Authentik**. Click it: you should be
bounced through `auth.thefipster.de` and land in Grafana as an **Admin** (check
the user menu, or **Administration** appearing in the nav).

> **Landed successfully but with no permissions?** That is the signature of
> `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH` losing its inner quotes. The value
> is JMESPath and must reach the container as `'Admin'`, quotes included — a
> bare `Admin` is a *field reference* that evaluates to nothing. Confirm with
> `docker compose exec grafana printenv GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH`
> — it must print `'Admin'` **with** the quotes.

## Troubleshooting

**`up` returns nothing / Explore is empty.** Alloy isn't writing. Check
`docker compose logs alloy` for remote-write errors, and confirm
`--web.enable-remote-write-receiver` is on Prometheus's command — without it
that endpoint 404s and metrics silently never arrive.

**Prometheus's "Targets" page is empty.** Expected. Nothing scrapes from
Prometheus in this design; Alloy pushes. Debug collection in Alloy's UI
(`127.0.0.1:12345`) instead.

**Alloy won't start.** Syntax-check the config:

```bash
docker run --rm -v /opt/stacks/monitoring/alloy/config.alloy:/c.alloy:ro \
  grafana/alloy:v1.18.0 fmt /c.alloy
```

`fmt` exits non-zero on a syntax error. Component and argument mistakes show up
at startup in `docker compose logs alloy`.

**Grafana can't reach Authentik.** The token exchange is server-to-server: the
Grafana *container* resolves `auth.thefipster.de` through the UDR, back to
Traefik on this same VM. Check it directly:

```bash
docker compose exec grafana wget -qO- -S https://auth.thefipster.de/-/health/live/ 2>&1 | head
```

**Grafana starts but SSO button is missing.** `GRAFANA_OIDC_ENABLED` is still
`false`, or the container wasn't recreated — `docker compose up -d grafana`.

**Datasource edits won't save in the UI.** Correct: they're provisioned from
`infra/monitoring/grafana/provisioning/`. Edit there and restart Grafana.

## Verification checklist

- [ ] `nslookup grafana.thefipster.de` → `192.168.1.41`
- [ ] `docker compose ps` → five services, `db` healthy, none restarting
- [ ] `curl -sI https://grafana.thefipster.de` → `HTTP/2 302`, trusted cert
- [ ] Loki `/ready` → `ready`
- [ ] Alloy UI (via tunnel) → all components Healthy
- [ ] Local `admin` login works (break-glass path)
- [ ] Both datasources listed and passing **Test**
- [ ] `up` in Explore → series for `alloy`, `prometheus`, `loki`, `grafana`
- [ ] `docker compose down && up -d` → account survives (state is in Postgres)
- [ ] **Sign in with Authentik** completes and lands an **Admin** session
- [ ] Loki is empty — expected in phase 1; phase 2 fills it
