# Authentik SSO (infra VM)

[Authentik](https://goauthentik.io) is the lab's single sign-on identity
provider, at **`https://auth.thefipster.de`**, behind the
[Traefik stack](traefik-setup.md) under the same wildcard cert. It brings three
services under SSO, each by the method that fits it:

| Service | Method | Why |
|---------|--------|-----|
| Forgejo (`git.thefipster.de`) | native **OIDC** | Forgejo also authenticates `git push`, `docker login`/registry and CI — none carry a browser cookie, so only real OIDC accounts cover them. |
| Dockge (`dockge.thefipster.de`) | **forward-auth** | No native SSO; gated at the proxy. |
| Traefik dashboard (`traefik.thefipster.de`) | **forward-auth** | Exposed *only because* forward-auth guards it. |

Forward-auth is **per application**: each protected host has its own Authentik
Application + access policy, so services are authorized independently.

> **Break-glass first.** This is a single-node lab. Forgejo keeps **local login
> enabled**, so an Authentik outage never locks you out of git. Forward-auth
> guards only the browser route: comment the one `middlewares` label on Dockge
> or Traefik and `docker compose up -d` to bypass. `akadmin` is Authentik's own
> recovery account.

## Layout on the server

Same two-location convention as the Forgejo stack:

| What | Where |
|------|-------|
| Compose project (this repo) | `infra/authentik/` |
| Persistent data | `/opt/authentik/{postgres,redis,media,certs,templates}` |

## Part 0 — Bring up Authentik

Traefik must be up first (Authentik is served at `https://auth.thefipster.de`).

```bash
cd ~/home-lab
scripts/init-authentik.sh     # data tree, generates secrets in .env, symlinks for Dockge
```

`init-authentik.sh` auto-generates `AUTHENTIK_SECRET_KEY` and `PG_PASS` into
`infra/authentik/.env`. Open that file and set `AUTHENTIK_BOOTSTRAP_PASSWORD`
(your initial `akadmin` password). Then:

```bash
cd ~/home-lab/infra/authentik
docker compose up -d
docker compose logs -f server    # wait for migrations; first boot takes a minute
```

Open `https://auth.thefipster.de`, log in as **`akadmin`** with the bootstrap
password. If the portal loads with a trusted cert, the stack and routing are
good.

> Deploy Authentik **before** the stacks that reference `authentik@docker`
> (Dockge, Traefik dashboard). If those routers load while Authentik is down,
> Traefik logs `middleware "authentik@docker" does not exist` and the route
> 404s.

## Part A — Forward-auth for Dockge and the Traefik dashboard

Do this **once per service**. Values for the two services:

| | Dockge | Traefik dashboard |
|-|--------|-------------------|
| Provider name | `dockge-forwardauth` | `traefik-forwardauth` |
| External host | `https://dockge.thefipster.de` | `https://traefik.thefipster.de` |
| Application name / slug | `Dockge` / `dockge` | `Traefik` / `traefik` |

1. **Create the provider.** In Authentik: **Admin → Applications → Providers →
   Create → Proxy Provider**.
   - Name: as above.
   - Authorization flow: `default-provider-authorization-implicit-consent`.
   - Mode: **Forward auth (single application)**.
   - External host: as above.
   - Save.
2. **Create the application.** **Admin → Applications → Applications → Create**.
   - Name / Slug: as above.
   - Provider: the provider you just made.
   - Save. (Leave the policy engine unset for now = allow any authenticated
     user; add a group binding later when you have more than one user.)
3. **Attach both to the embedded outpost.** **Admin → Applications → Outposts →
   `authentik Embedded Outpost` → Edit → Applications**: add both `Dockge` and
   `Traefik`. Save. The outpost updates within a few seconds.

The Traefik side is already wired (repo stacks): the `authentik@docker`
middleware and the per-host `/outpost.goauthentik.io/` routers live on the
Authentik `server` container; Dockge and the dashboard carry the middleware
label.

**Verify:** open `https://dockge.thefipster.de` in a private window → you are
redirected to Authentik, and after login land on Dockge. Repeat for
`https://traefik.thefipster.de` (the dashboard should load, gated). Each is an
independent app in **Admin → Events → Logs**.

## Part B — Forgejo via OIDC

1. **Create the Forgejo provider in Authentik.** **Providers → Create →
   OAuth2/OpenID Provider**.
   - Name: `forgejo`.
   - Authorization flow: `default-provider-authorization-implicit-consent`.
   - Client type: **Confidential**.
   - Redirect URIs (exact):
     `https://git.thefipster.de/user/oauth2/authentik/callback`
   - Signing Key: the default (`authentik Self-signed Certificate`).
   - Save, then note the generated **Client ID** and **Client Secret**.
2. **Create the application:** **Applications → Create** → Name `Forgejo`, Slug
   `forgejo`, Provider `forgejo`.
   - The discovery URL is then:
     `https://auth.thefipster.de/application/o/forgejo/.well-known/openid-configuration`
3. **Add the source in Forgejo.** **Site Administration → Identity & Access →
   Authentication Sources → Add Authentication Source**.
   - Type: **OAuth2**.
   - Authentication Name: **`authentik`** — this MUST be `authentik`, because
     Forgejo builds the callback as `/user/oauth2/<name>/callback`, and that
     has to match the redirect URI in step 1.
   - OAuth2 Provider: **OpenID Connect**.
   - Client ID / Client Secret: from step 1.
   - OpenID Connect Auto Discovery URL: the discovery URL from step 2.
   - Enable **Auto Registration**; set account linking to **automatic** (link by
     email) so your Authentik identity maps onto the existing Forgejo admin
     account (same email) instead of creating a second user.
   - Save.
4. **Do NOT disable local login** — leave password sign-in on (break-glass).

**Verify:** log out of Forgejo, open `https://git.thefipster.de`, click **Sign
in with authentik**, authenticate → you land in the existing admin account.
Local username/password login still works.

## Verification checklist (runtime)

- [ ] `https://auth.thefipster.de` serves the Authentik portal on the wildcard cert.
- [ ] Unauthenticated `https://dockge.thefipster.de` redirects to Authentik, returns after login.
- [ ] Unauthenticated `https://traefik.thefipster.de` redirects to Authentik, then shows the dashboard.
- [ ] Forgejo shows "Sign in with authentik"; using it logs into the existing admin; local login still works.
- [ ] `docker login git.thefipster.de` and an Actions build/push still succeed (OIDC didn't disturb git/registry auth).

## Break-glass procedures

- **Forgejo** — local admin password still works if Authentik is down.
- **Dockge / Traefik dashboard** — comment the `traefik.http.routers.*.middlewares: authentik@docker` label and `docker compose up -d` to bypass; drive Docker over SSH meanwhile. Dockge's own login remains underneath.
- **Authentik itself** — `akadmin` is the recovery account; its password is `AUTHENTIK_BOOTSTRAP_PASSWORD` (first boot) or resettable via `docker compose run --rm server make-admin` per Authentik docs.

## Teardown / backup

State is bind-mounted under `/opt/authentik`, so `docker compose down` keeps
data. Back up the filesystem plus a Postgres dump; keep `.env` (the
`AUTHENTIK_SECRET_KEY` is not recoverable — losing it invalidates sessions and
encrypted secrets).

```bash
docker compose down
sudo tar czf authentik-backup-$(date +%F).tar.gz -C /opt authentik
docker compose up -d
```
