# SSO applications (registry)

**Runs on:** Authentik on the infra VM — registry, not a build step

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

**Two** services join **neither**, deliberately — see
[Uptime Kuma](#uptime-kuma-deliberately-not-joined) and
[Home Assistant](#home-assistant-deliberately-not-joined). They are listed here
so this registry stays an honest account of every service's relationship to
Authentik, not only the ones that joined. Both are decisions, not gaps: in each
case the break-glass path for an Authentik outage would need `ssh` at precisely
the moment you are least able to use it.

| Service | Method | Where configured | Procedure |
|---------|--------|------------------|-----------|
| Traefik dashboard | forward-auth | Authentik only | [authentik-setup.md, step 3](authentik-setup.md#3-gate-the-traefik-dashboard-forward-auth) |
| Dockge | forward-auth | Authentik only | [dockge-setup.md, step 1](dockge-setup.md#1-create-the-dockge-application-in-authentik) |
| Forgejo | OIDC | Authentik + Forgejo admin UI + `infra/forgejo/compose.yaml` | [forgejo-setup.md, step 5](forgejo-setup.md#5-join-sso-oidc-via-authentik) |
| Grafana | OIDC | Authentik + `infra/monitoring/.env` | [grafana-setup.md, step 5](grafana-setup.md#5-join-sso-oidc-via-authentik) |
| Uptime Kuma | **none** (deliberate) | Kuma's own local login | [uptime-kuma-setup.md, step 4](uptime-kuma-setup.md#4-create-the-admin-account) |
| Home Assistant | **none** (deliberate) | HA's own local login | [home-assistant-setup.md, step 6](home-assistant-setup.md#6-make-it-reachable-through-traefik) |

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
Connect**. Only three fields matter; the Client ID / Secret come from the
provider above:

| Field | Value |
|-------|-------|
| Authentication Name | `authentik` — **must** be exactly this: Forgejo builds the callback as `/user/oauth2/<name>/callback`, which has to match the redirect URI above |
| Auto Discovery URL | `https://auth.thefipster.de/application/o/forgejo/.well-known/openid-configuration` |
| Client ID / Client Secret | from the Authentik provider |

**Auto-registration and account linking are not on this form.** They are
instance-level settings, already shipped in
[`infra/forgejo/compose.yaml`](../infra/forgejo/compose.yaml) — nothing to
click:

| Setting | Value | Why |
|---------|-------|-----|
| `FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION` | `true` | create the Forgejo user on first SSO login (the default, `false`, rejects it) |
| `FORGEJO__oauth2_client__ACCOUNT_LINKING` | `auto` | link to the existing local account with the **same email** instead of creating a duplicate (the default, `login`, stops at a manual prompt) |

Account linking matches on **email**, so the Authentik user must carry the
same address as the Forgejo admin account created at first run — see
[authentik-setup.md, step 4](authentik-setup.md#4-add-a-user-and-a-group).

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
[grafana-setup.md, step 5](grafana-setup.md#5-join-sso-oidc-via-authentik).

Local `admin` login stays **enabled** (break-glass;
`GRAFANA_ADMIN_PASSWORD` in the same `.env`).

## Uptime Kuma (deliberately not joined)

Kuma has no OIDC support, so the convention would point at forward-auth. It is
**not** applied. Kuma's entire job is telling you what is down — gating it
behind the identity provider makes an Authentik outage the one failure you
cannot see, and the break-glass path (comment the middleware label, recreate
the container) needs `ssh` at exactly the moment you are already firefighting.

Kuma ships real local authentication (bcrypt, optional 2FA) and the lab is
LAN-only, so the exposure is bounded. The cost is worth naming: anyone on the
LAN reaches Kuma's login page, where every other infra UI would have shown them
Authentik first.

Nothing to click in Authentik, and nothing to undo:
`infra/authentik/compose.yaml` carries **no** outpost router for this host, and
`infra/uptime-kuma/compose.yaml` carries **no** `middlewares` label. Both
absences are deliberate and commented in place.

## Home Assistant (deliberately not joined)

HA has no OIDC support either, so the convention again points at forward-auth,
and again it is **not** applied — for a different reason than Kuma's.

Forward-auth gates *everything* behind a browser login flow, and most traffic to
Home Assistant is not a browser. The **companion mobile app**, webhooks, and
every local API caller authenticate with long-lived tokens against the same
endpoints the frontend uses; there is no clean path that admits them while
challenging a browser. Gating HA would break notifications, presence detection
and automations that call in from elsewhere on the LAN — the parts you notice
least until they stop.

And the failure mode is the household's, not just yours: the break-glass is
editing `infra/traefik/dynamic/ha.yaml` over `ssh` while the lights do not
respond.

HA ships real local authentication (per-user accounts, optional MFA, trusted
networks) and the lab is LAN-only, so the exposure is bounded. Same cost as
Kuma, named the same way: anyone on the LAN reaches HA's login page, where
another infra UI would have shown them Authentik first.

Nothing to click in Authentik, and nothing to undo:
`infra/authentik/compose.yaml` carries **no** outpost router for this host, and
`infra/traefik/dynamic/ha.yaml` carries **no** `middlewares` key. Both absences
are deliberate and commented in place.

## Access bindings

An application with **no** bindings admits **any authenticated user**; the
moment it has at least one, everyone not matched is denied. The lab binds
each Authentik application above to the `lab-users` group (Uptime Kuma and Home
Assistant have no application, so they have no binding) —
[authentik-setup.md, step 5](authentik-setup.md#5-control-who-reaches-what)
covers creating the group and users, and what "denied" means per pattern.
