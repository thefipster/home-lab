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
Authentik is the **first routed stack** — the first thing Traefik actually
serves. The wildcard certificate was already *requested* when Traefik started
(first issuance takes 10–15 minutes); if that's still running, or you began on
the staging CA, finish the
[staging→production flow](traefik-setup.md#staging--production) before
expecting a trusted cert here.

```bash
cd ~/home-lab
scripts/init-authentik.sh     # data tree, generates secrets in .env, symlinks for Dockge
```

`init-authentik.sh` auto-generates `AUTHENTIK_SECRET_KEY`, `PG_PASS` and
`AUTHENTIK_BOOTSTRAP_PASSWORD` into `infra/authentik/.env`. The bootstrap
password is the initial `akadmin` login — it is applied **only when akadmin is
first created**, so read it out of `.env` before first boot. Then:

```bash
cd ~/home-lab/infra/authentik
docker compose up -d
docker compose logs -f server    # wait for migrations; first boot takes a minute
```

> **First bring-up on the staging CA?** The portal serves an **untrusted
> staging cert** until you complete the
> [staging→production switch](traefik-setup.md#staging--production) in the
> Traefik guide. Do that now, then come back and log in below.

Open `https://auth.thefipster.de`, log in as **`akadmin`** with the bootstrap
password. If the portal loads with a trusted cert, the stack and routing are
good.

> **"Invalid password" for akadmin on a first boot?** The bootstrap variables
> must reach the **worker** — blueprints, including the one that creates
> akadmin, are applied there, not on the server (the repo compose sets them on
> both). Diagnose with
> `docker compose exec worker printenv AUTHENTIK_BOOTSTRAP_PASSWORD` (must
> print the value) and
> `docker compose exec server ak shell -c "from authentik.core.models import User; print(User.objects.get(username='akadmin').has_usable_password())"`
> — `False` means akadmin was created with **no** password. Recover without
> reinstalling: set one at `https://auth.thefipster.de/if/flow/initial-setup/`,
> or use the recovery key from the break-glass section. Fixing the env alone
> does *not* help an existing install — bootstrap applies only at creation.

> Deploy Authentik **before** the stacks that reference `authentik@docker`
> (Dockge, Traefik dashboard) — that's why it sits between Traefik and Dockge
> in the build order. If those routers load while Authentik is down, Traefik
> logs `middleware "authentik@docker" does not exist` and the route 404s.

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
     user; [Part C](#part-c--add-users-and-control-who-reaches-what) adds
     group bindings.)
3. **Attach both to the embedded outpost.** **Admin → Applications → Outposts →
   `authentik Embedded Outpost` → Edit → Applications**: add both `Dockge` and
   `Traefik`. Save. The outpost updates within a few seconds.

The Traefik side is already wired (repo stacks): the `authentik@docker`
middleware and the per-host `/outpost.goauthentik.io/` routers live on the
Authentik `server` container; Dockge and the dashboard carry the middleware
label.

**Verify:** the dashboard half works right away — open
`https://traefik.thefipster.de` in a private window → you are redirected to
Authentik, and after login the dashboard loads, gated. The Dockge half needs
the Dockge stack running first (`scripts/init-dockge.sh` — next in the build
order, documented in [forgejo-setup.md, Part 0](forgejo-setup.md)); then
`https://dockge.thefipster.de` behaves the same way. Each shows up as an
independent app in **Admin → Events → Logs**.

## Part B — Forgejo via OIDC

Needs the Forgejo stack up and its admin account created
([forgejo-setup.md](forgejo-setup.md), Parts 0–A) — come back here afterwards.

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

## Part C — Add users and control who reaches what

`akadmin` is break-glass, not a daily driver. Create a normal account for
yourself (and anyone else), put it in a group, and bind the applications to
that group.

### Create a group and a user

1. **Group:** **Admin → Directory → Groups → Create** — e.g. `lab-users`.
   Groups are what you bind to applications. One shared group is fine to
   start; per-app groups (`dockge-users`, …) only pay off once more people
   than you use the lab.
2. **User:** **Admin → Directory → Users → Create**.
   - Username / Name as you like. **Email matters for Forgejo:** the OIDC
     account linking from Part B matches by email, so give your own user the
     same address as your Forgejo admin account.
   - Save, open the user, and click **Set password** — the lab sends no
     recovery mails, so set it directly.
3. **Membership:** on the user's page → **Groups** tab → **Add to existing
   group** → `lab-users`. (Equivalently from the group's **Users** tab.)

Keep regular users **out** of the built-in `authentik Admins` group — it
grants superuser over Authentik itself. `akadmin` stays your only admin.

### Grant (and restrict) application access

Parts A and B left every application without bindings, which means **any
authenticated user** is allowed through. To restrict an application to a
group:

1. **Admin → Applications → Applications** → open the app (`Dockge`,
   `Traefik` or `Forgejo`) → **Policy / Group / User Bindings** tab.
2. **Bind existing Group / User** → select `lab-users` → Save.

The moment an application has at least one binding, everyone *not* matched by
a binding is denied — so bind group(s) per application, and remember that
applications with no bindings stay open to any authenticated login. What
"denied" means differs by pattern:

- **Forward-auth (Dockge, Traefik dashboard):** enforced at the proxy — a
  denied user authenticates but gets Authentik's access-denied page instead
  of the service.
- **Forgejo (OIDC):** the binding gates only the "Sign in with authentik"
  path. Forgejo-local accounts (break-glass) are unaffected.

**Verify:** in a private window, log in at `https://dockge.thefipster.de` as
the new user → you land in Dockge. Remove the user from `lab-users` and retry
→ Authentik shows access denied.

## Verification checklist (runtime)

- [ ] `https://auth.thefipster.de` serves the Authentik portal on the wildcard cert.
- [ ] Unauthenticated `https://dockge.thefipster.de` redirects to Authentik, returns after login.
- [ ] Unauthenticated `https://traefik.thefipster.de` redirects to Authentik, then shows the dashboard.
- [ ] Forgejo shows "Sign in with authentik"; using it logs into the existing admin; local login still works.
- [ ] A non-admin user (Part C) reaches the bound apps; removing it from the group denies access.
- [ ] `docker login git.thefipster.de` and an Actions build/push still succeed (OIDC didn't disturb git/registry auth).

## Break-glass procedures

- **Forgejo** — local admin password still works if Authentik is down.
- **Dockge / Traefik dashboard** — comment the `traefik.http.routers.*.middlewares: authentik@docker` label and `docker compose up -d` to bypass; drive Docker over SSH meanwhile. Dockge's own login remains underneath.
- **Authentik itself** — `akadmin` is the recovery account. `AUTHENTIK_BOOTSTRAP_PASSWORD` is applied **only when akadmin is first created**; editing it later does nothing. To get back in: `docker compose exec server ak create_recovery_key 10 akadmin` prints a one-time login link — open it, then set a new password under the akadmin user settings.

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
