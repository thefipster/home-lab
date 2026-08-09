# Homepage widgets (registry)

**Runs on:** the services being read, not Homepage — registry, not a build step

Every Homepage tile that shows **figures** rather than only a status dot needs a
credential, and every one of those credentials is minted by hand in the service
it belongs to. Homepage itself is provisioned entirely from the checkout — the
compose and the YAML under `infra/homepage/config` — so this file is the record
of the part that is not: which button to press, in which admin UI, with which
scopes. The bring-up is [homepage-setup.md](homepage-setup.md).

**When a new service arrives, decide about its widget here first**, the same
convention as [dns-records.md](dns-records.md),
[sso-applications.md](sso-applications.md) and
[uptime-kuma-monitors.md](uptime-kuma-monitors.md). A service can legitimately
have no widget — several do, and they are listed under
[Deliberate absences](#deliberate-absences) with the reason. What should never
happen is a tile that quietly shows less than it could because nobody wrote down
what it needed.

Container **state** — the dot, and the start/stop counts — needs no credential at
all. It comes from the Docker socket and covers every stack on the infra VM.
This file is only about the widgets layered on top of that.

## How a credential reaches a widget

Homepage substitutes environment variables into its config at runtime: the value
of `HOMEPAGE_VAR_XXX` replaces `{{HOMEPAGE_VAR_XXX}}` in any config file. So the
credential lives in `infra/homepage/.env`, which is gitignored, and
`config/services.yaml` stays tracked in git with nothing secret in it. That is
what makes the read-only config mount workable — Homepage never writes, and the
checkout never holds a token.

Three properties of that arrangement are worth knowing before editing anything:

- **The placeholder must be quoted.** `key: {{HOMEPAGE_VAR_AUTHENTIK_KEY}}` is a
  YAML parse error, because a bare `{` opens a flow mapping. Write
  `key: "{{HOMEPAGE_VAR_AUTHENTIK_KEY}}"`. The symptom of getting this wrong is
  a container that exits on boot, not a broken tile.
- **Every widget dials its backend container directly over the `proxy`
  network**, never through Traefik. Going through the proxy would be a TLS hop
  back into the same VM, and for a forward-auth gated host the widget would end
  up authenticating against Authentik rather than reading the service. This is
  the same shape as the Uptime Kuma widget's `http://uptime-kuma:3001`.
- **Every value carries a `${VAR:?}` guard** in `compose.yaml`. A missing or
  empty value stops the whole stack, deliberately — a half-configured start page
  should not load. A guard fires on *empty*, though, and an **expired** token is
  still a non-empty string, so an expired credential degrades exactly one tile
  and leaves the rest of the page alone.

## Authentik

| | |
|---|---|
| Widget type | `authentik` |
| URL | `http://authentik-server:9000` |
| `.env` variable | `HOMEPAGE_VAR_AUTHENTIK_KEY` |
| Where to mint | Admin Portal → **Directory** → **Tokens & App passwords** → Create, with **Intent: API Token** |
| Permissions the owning user needs | authentik Core → *Can view User* (model: User); authentik Events → *Can view Event* (model: Event) |
| Shows | users, logins last 24h, failed logins last 24h |

`version: 2` is set in `services.yaml` and is **required** from Authentik
2025.8.0 onward, which split the API this widget reads. The lab pins `2026.5`.
On version 1 against a current Authentik the tile renders blank rather than
erroring, which is the confusing failure to watch for.

`authentik-server` is an explicit network alias on `proxy`, declared in
`infra/authentik/compose.yaml` — the widget does not go via `auth.thefipster.de`.

**This adds no row to [sso-applications.md](sso-applications.md).** An API token
is not an Authentik *application*; Homepage's entry in that registry stays the
forward-auth one it already has.

## Forgejo

| | |
|---|---|
| Widget type | `gitea` — upstream ships no Forgejo widget |
| URL | `http://forgejo:3000` |
| `.env` variable | `HOMEPAGE_VAR_FORGEJO_KEY` |
| Where to mint | User Settings → **Applications** → **Generate New Token** |
| Scopes | `repository`, `issue` and `notification`, **read** access |
| Shows | repositories, notifications, issues, pulls |

**The widget type is `gitea` and that is not a typo.** Upstream documents this
widget for Gitea and does not mention Forgejo anywhere; the Forgejo API is
Gitea-compatible, which is why it works. That makes this the one widget here
whose compatibility rests on an upstream relationship neither project promises
to keep — a future Forgejo major could break it in a way no other widget on this
page can break. If it does, drop the widget and move Forgejo to
[Deliberate absences](#deliberate-absences); do not work around it.

Alloy already scrapes `forgejo:3000` over the same network, so the address
itself is proven.

## Grafana

| | |
|---|---|
| Widget type | `grafana` |
| URL | `http://grafana:3000` |
| `.env` variables | `HOMEPAGE_VAR_GRAFANA_USER`, `HOMEPAGE_VAR_GRAFANA_PASSWORD` |
| Where to mint | Grafana → **Administration** → **Users and access** → **Users** → New user |
| Role | **Viewer** |
| Shows | dashboards, datasources, total alerts, alerts triggered |

**This widget has no token form.** It offers `username` and `password` and
nothing else, so what goes in `.env` is a real login rather than a revocable
key. That is why the account is a **dedicated** Grafana user rather than the
monitoring stack's admin: reusing `GRAFANA_ADMIN_PASSWORD` would put one
credential in two `.env` files and two restic snapshots, and rotating it in one
place would silently break the other.

Local logins stay enabled beside OIDC as break-glass, so this account costs
nothing that is not already there.

`version: 2` is required above Grafana v10.4; the lab pins `13.1`.

> **Unverified until the first bring-up:** the `datasources` figure reads
> `/api/datasources`, which Grafana restricts to admins. If a Viewer account
> blanks the whole tile rather than just that one number, the fix is to scope the
> widget with `fields: [dashboards, alertstriggered]` — **not** to raise the
> role. Delete this note once the tile has been seen working, and record which
> of the two it needed.

## Deliberate absences

A registry that only records what exists cannot tell you whether a gap was a
decision. These are decisions.

**Proxmox** — a widget exists and is deliberately unused. The Proxmox API is
HTTPS-only on `:8006` behind a self-signed certificate, and Homepage is Node, so
it refuses the connection outright. Both fixes cost more than the widget is
worth: `NODE_EXTRA_CA_CERTS` means copying `/etc/pve/pve-root-ca.pem` off the
hypervisor and mounting it, which reintroduces the `/opt/homepage` directory
this stack is defined by not having; and `NODE_TLS_REJECT_UNAUTHORIZED=0`
disables certificate verification for *every* outbound request Homepage makes,
which is a trap set for whoever adds the next widget. What is lost is the VM and
LXC counts — host CPU and memory are already on Grafana's Node Exporter Full
dashboard.

**The Traefik dashboard** — a widget exists and is deliberately unused. Its
router is forward-auth gated, so a widget pointed at it would report on
Authentik rather than on Traefik. This is the same reasoning that gives Traefik
no `Gateway Web` monitor in
[uptime-kuma-monitors.md](uptime-kuma-monitors.md#gateway--traefik).

**Vaultwarden, Dockge and Coolify** — upstream ships **no widget** for any of
them. This is a fact about Homepage, not a decision about the lab, and no amount
of configuration changes it. They stay plain links.

**Home Assistant, and the applications on the apps VM** (Paperless-ngx, Mealie,
BookStack, LubeLogger) — widgets exist, and those machines are not built yet
([status.md](status.md)). **This is the one absence here that expires**: when
those machines exist, the question is worth reopening, and a widget pointed at a
machine that does not exist cannot be verified. The absences above do not expire.

**Uptime Kuma** — has a widget already and needs **no credential**. It reads the
public `homelab` status page rather than an API, which is recorded in
[uptime-kuma-monitors.md](uptime-kuma-monitors.md#the-homelab-status-page)
because the slug has to exist for the tile to fill in.

## Next

**[homepage-setup.md](homepage-setup.md)** — the bring-up, which is where these
credentials get typed into `infra/homepage/.env`. The full sequence is the
[README build order](../README.md#build-order).
