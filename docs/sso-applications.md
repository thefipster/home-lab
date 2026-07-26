# SSO applications (registry)

Every service behind [Authentik](authentik-setup.md), with the exact values
its provider and application are created with. All of this is **manual
clickwork in the Authentik admin UI** — none of it lives in a compose file —
so this registry is the record of what must exist. The click-path procedures
live in the linked guides; **when a new service joins SSO, add its section
here first.**

Services join by one of two patterns, never both on one service (the repo
convention):

- **OIDC** — for services with real SSO support, or that authenticate
  non-browser traffic (git push, `docker login`/registry, CI).
- **Forward-auth** — at the proxy, for plain web UIs with no SSO support.

| Service | Method | Where configured | Procedure |
|---------|--------|------------------|-----------|
| Dockge | forward-auth | Authentik only | [authentik-setup.md, Part A](authentik-setup.md#part-a--forward-auth-for-dockge-and-the-traefik-dashboard) |
| Traefik dashboard | forward-auth | Authentik only | [authentik-setup.md, Part A](authentik-setup.md#part-a--forward-auth-for-dockge-and-the-traefik-dashboard) |
| Forgejo | OIDC | Authentik + Forgejo admin UI | [authentik-setup.md, Part B](authentik-setup.md#part-b--forgejo-via-oidc) |
| Grafana | OIDC | Authentik + `infra/monitoring/.env` | [grafana-setup.md, Part 3](grafana-setup.md#part-3--authentik-oidc) |

## Forward-auth: Dockge & Traefik dashboard

Provider type **Proxy Provider**, mode **Forward auth (single application)**,
authorization flow `default-provider-authorization-implicit-consent`. Both
providers must be attached to the **authentik Embedded Outpost**.

| | Dockge | Traefik dashboard |
|-|--------|-------------------|
| Provider name | `dockge-forwardauth` | `traefik-forwardauth` |
| External host | `https://dockge.thefipster.de` | `https://traefik.thefipster.de` |
| Application name / slug | `Dockge` / `dockge` | `Traefik` / `traefik` |

The Traefik side ships in the repo: the shared `authentik@docker` middleware
and the per-host `/outpost.goauthentik.io/` routers are labels on the
Authentik `server` container (`infra/authentik/compose.yaml`), and the
protected routers carry the `middlewares: authentik@docker` label
(`infra/dockge/compose.yaml`, `infra/traefik/compose.yaml`).

## Forgejo (OIDC)

Authentik side — provider type **OAuth2/OpenID Provider**:

| Field | Value |
|-------|-------|
| Provider name | `forgejo` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | **Confidential** |
| Redirect URI (exact) | `https://git.thefipster.de/user/oauth2/authentik/callback` |
| Signing key | `authentik Self-signed Certificate` (default) |
| Application name / slug | `Forgejo` / `forgejo` |

Forgejo side — **Site Administration → Identity & Access → Authentication
Sources → Add Authentication Source**, type **OAuth2**, provider **OpenID
Connect**:

| Field | Value |
|-------|-------|
| Authentication Name | `authentik` — **must** be exactly this: Forgejo builds the callback as `/user/oauth2/<name>/callback`, which has to match the redirect URI above |
| Auto Discovery URL | `https://auth.thefipster.de/application/o/forgejo/.well-known/openid-configuration` |
| Auto Registration | enabled; account linking **automatic** (link by email) |

Local login stays **enabled** — it is the break-glass path when Authentik is
down.

## Grafana (OIDC)

Authentik side — provider type **OAuth2/OpenID Provider**:

| Field | Value |
|-------|-------|
| Provider name | `grafana` |
| Authorization flow | the default explicit- or implicit-consent flow |
| Client type | **Confidential** |
| Redirect URI (**Strict**) | `https://grafana.thefipster.de/login/generic_oauth` |
| Signing key | the default self-signed certificate |
| Application name / slug | `Grafana` / `grafana` |

Grafana side — no admin-UI work: the Client ID / Client Secret go into
`infra/monitoring/.env` (`GRAFANA_OIDC_CLIENT_ID` /
`GRAFANA_OIDC_CLIENT_SECRET`) together with `GRAFANA_OIDC_ENABLED=true`, then
`docker compose up -d grafana` —
[grafana-setup.md, Part 3](grafana-setup.md#part-3--authentik-oidc).

Local `admin` login stays **enabled** (break-glass;
`GRAFANA_ADMIN_PASSWORD` in the same `.env`).

## Access bindings

An application with **no** bindings admits **any authenticated user**; the
moment it has at least one, everyone not matched is denied. The lab binds
each application above to the `lab-users` group —
[authentik-setup.md, Part C](authentik-setup.md#part-c--add-users-and-control-who-reaches-what)
covers creating the group and users, and what "denied" means per pattern.
