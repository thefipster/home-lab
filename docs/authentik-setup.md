# Authentik — single sign-on (infra VM)

**Runs on:** infra VM

**Prerequisite:** [vaultwarden-setup.md](vaultwarden-setup.md) complete — the
vault is where this guide's generated secrets belong, and it is the last stack
that does not depend on what you are about to build.

[Authentik](https://goauthentik.io) is the lab's identity provider, at
**`https://auth.thefipster.de`**. It must run before the services it gates: the
Traefik dashboard and Dockge reference a forward-auth middleware that Authentik
provides, so their routers do not load without it.

Services join SSO by **one of two patterns, never both**:

- **OIDC** — for services with real SSO support, or that authenticate
  non-browser traffic (`git push`, `docker login`, CI). Forgejo and Grafana.
- **Forward-auth** — at the proxy, for plain web UIs with no SSO support at
  all. The Traefik dashboard and Dockge.

Three services join **neither**, deliberately — Vaultwarden, Uptime Kuma and
Home Assistant. The first of those is already running by the time you get here,
and its absence is the reason it was built first
([sso-applications.md](sso-applications.md#vaultwarden-deliberately-not-joined)).

The full list of applications and the exact values each is created with is the
registry: **[sso-applications.md](sso-applications.md)**. This guide sets up
Authentik itself and gates the Traefik dashboard; the other services join from
their own guides.

> **Break-glass first.** This is a single-node lab, so plan for Authentik being
> down. `akadmin` is Authentik's own recovery account. Forgejo and Grafana keep
> **local login enabled**. Forward-auth guards only the browser route: comment
> one label to bypass it. See [Break-glass](#break-glass).

## Steps

### 1. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-authentik.sh
```

It creates `/opt/authentik/{postgres,data,certs,templates}`, generates
`AUTHENTIK_SECRET_KEY`, `PG_PASS` and `AUTHENTIK_BOOTSTRAP_PASSWORD` into
`infra/authentik/.env`, and symlinks the stack into `/opt/stacks`.

Read the bootstrap password out now — it is the initial `akadmin` login, and it
is applied **only when akadmin is first created**:

```bash
grep AUTHENTIK_BOOTSTRAP_PASSWORD ~/home-lab/infra/authentik/.env
```

### 2. Start the stack and log in

```bash
cd ~/home-lab/infra/authentik
```

```bash
docker compose up -d
```

```bash
docker compose logs -f server
```

Wait for migrations to finish; first boot takes a minute. Then check that
Traefik is serving it:

```bash
curl -Is https://auth.thefipster.de | head -1
```

Expect `HTTP/2 200` (or a `302`/`303` to the login flow) with no TLS warning —
this is the first check that exercises the certificate against a real service.

Open **`https://auth.thefipster.de`** and log in as **`akadmin`** with the
bootstrap password from step 1.

### 3. Gate the Traefik dashboard (forward-auth)

This is the click-path for **every** forward-auth service; Dockge repeats it
later with its own values. All per-service values are in the registry:
[sso-applications.md](sso-applications.md#forward-auth-dockge--traefik-dashboard).

1. **Create the provider.** **Admin → Applications → Providers → Create →
   Proxy Provider**. Set the name, authorization flow, mode
   (*Forward auth (single application)*) and external host exactly as the
   registry specifies. Save.
2. **Create the application.** **Admin → Applications → Applications →
   Create**. Name and slug from the registry; provider = the one you just
   made. Save. Leave the bindings empty for now — that means *any*
   authenticated user is allowed, which [step 5](#5-control-who-reaches-what)
   tightens.
3. **Attach it to the embedded outpost.** **Admin → Applications → Outposts →
   `authentik Embedded Outpost` → Edit → Applications**: add `Traefik`. Save.
   The outpost picks it up within a few seconds.

The Traefik side needs no work — the `authentik@docker` middleware and the
per-host `/outpost.goauthentik.io/` routers are already labels on the Authentik
`server` container, and the dashboard router already carries the middleware.

**Verify:** open `https://traefik.thefipster.de` in a **private window**. You
are redirected to Authentik; after login the dashboard loads. (In a normal
window you may already hold a session and sail straight through — the private
window is what makes the redirect visible.)

### 4. Add a user and a group

`akadmin` is break-glass, not a daily driver.

1. **Group:** **Admin → Directory → Groups → Create** — e.g. `lab-users`.
   Groups are what you bind applications to. One shared group is enough until
   more people than you use the lab.
2. **User:** **Admin → Directory → Users → Create**. **Email matters:**
   Forgejo's OIDC account linking matches on email, so give this user the same
   address you will use for the Forgejo admin account
   ([forgejo-setup.md](forgejo-setup.md)). Save, open the user, and click
   **Set password** — the lab sends no recovery mail.
3. **Membership:** on the user's **Groups** tab → **Add to existing group** →
   `lab-users`.

Keep regular users **out** of the built-in `authentik Admins` group — it grants
superuser over Authentik itself. `akadmin` stays the only admin.

### 5. Control who reaches what

An application with **no** bindings admits **any** authenticated user. The
moment it has at least one binding, everyone not matched is denied. To
restrict one:

1. **Admin → Applications → Applications** → open the app → **Policy / Group /
   User Bindings**.
2. **Bind existing Group / User** → `lab-users` → Save.

Do this for every application in the [registry](sso-applications.md) as it is
created. What "denied" means depends on the pattern:

- **Forward-auth** (Traefik dashboard, Dockge): enforced at the proxy — the
  user authenticates but gets Authentik's access-denied page instead of the
  service.
- **OIDC** (Forgejo, Grafana): gates only the "Sign in with authentik" path.
  Local accounts are unaffected — that is the break-glass path.

**Verify:** in a private window, sign in at `https://traefik.thefipster.de` as
the new user → the dashboard loads. Remove the user from `lab-users` and retry
→ Authentik shows access denied.

### Checklist

- [ ] `https://auth.thefipster.de` serves the portal on the wildcard cert
- [ ] `akadmin` logs in with the bootstrap password
- [ ] Unauthenticated `https://traefik.thefipster.de` redirects to Authentik,
      then shows the dashboard
- [ ] A `lab-users` member reaches it; removing them from the group denies
      access
- [ ] The login just performed shows as an authorization event against the
      `Traefik` application under **Admin → Events → Logs**

## Next

**[dockge-setup.md](dockge-setup.md)** — the compose management UI, and the
second forward-auth application. From there on you can drive stacks from a
browser.

## Troubleshooting

**"Invalid password" for akadmin on a first boot.** The bootstrap variables
must reach the **worker** — blueprints, including the one that creates akadmin,
are applied there, not on the server (the repo compose sets them on both).
Check the worker actually has it:

```bash
docker compose exec worker printenv AUTHENTIK_BOOTSTRAP_PASSWORD
```

Then check whether akadmin got a usable password at all:

```bash
docker compose exec server ak shell -c "from authentik.core.models import User; print(User.objects.get(username='akadmin').has_usable_password())"
```

`False` means akadmin was created with **no** password. Fixing the environment
alone does not help — bootstrap applies only at creation. Recover by setting
one at `https://auth.thefipster.de/if/flow/initial-setup/`, or with the
recovery key below.

**`middleware "authentik@docker" does not exist` in Traefik's log.** Authentik
isn't running (or its `server` container isn't on the `proxy` network). Any
router referencing the middleware 404s until it is.

**The login redirect loops, or the callback 404s.** Single-application forward
auth runs its handshake on *each app's own domain*, so every protected host
needs its own `/outpost.goauthentik.io/` router. Those are labels on the
Authentik `server` container — a new protected host needs a new pair added
there.

**A new forward-auth app authenticates but always denies.** It is not attached
to the embedded outpost (step 3.3), or it has a binding that doesn't match your
user (step 5).

## Break-glass

- **Authentik itself** — `akadmin` is the recovery account.
  `AUTHENTIK_BOOTSTRAP_PASSWORD` applies **only** at creation; editing it later
  does nothing. To get back in:

  ```bash
  docker compose exec server ak create_recovery_key 10 akadmin
  ```

  That prints a one-time login link; open it and set a new password from the
  akadmin user settings.

- **Traefik dashboard / Dockge** — comment the
  `traefik.http.routers.*.middlewares: authentik@docker` label and
  `docker compose up -d` to bypass the gate. Dockge's own login remains
  underneath; drive Docker over SSH meanwhile.

- **Forgejo / Grafana** — local login stays enabled by design. Nothing to do.

## Layout on the server

| What | Where |
|------|-------|
| Compose project (this repo) | `infra/authentik/` |
| Secrets | `infra/authentik/.env` — gitignored, VM-only |
| Persistent data | `/opt/authentik/{postgres,data,certs,templates}` |

`data` is the file-storage mount (uploaded icons, branding and flow
backgrounds under `data/media`, served at the `/files` prefix). There is no
`redis` directory: Authentik uses Postgres for caching, background tasks and
the embedded outpost's sessions, so the stack runs no Redis container.

Keep `.env`: `AUTHENTIK_SECRET_KEY` is **not recoverable**, and losing it
invalidates all sessions and encrypted secrets.

## How it works

**Two patterns, one rule.** Anything with native SSO uses **OIDC** — it is
stronger (the app knows *who* the user is, not merely that someone passed a
gate) and it is the only option for non-browser traffic like `git push` or
`docker login`. Forward-auth is the fallback for UIs that have no SSO at all,
and it never applies to a service that could use OIDC. Never both on one
service: two gates on one door means two places to debug and two ways to be
locked out.

**How forward-auth is wired.** Three pieces, all already in the repo:

1. A `forwardauth` middleware named `authentik` — declared as labels on the
   Authentik `server` container, so Traefik discovers it as
   `authentik@docker`.
2. One `/outpost.goauthentik.io/` router **per protected host**, also on the
   `server` container. Single-application forward auth completes its handshake
   on the app's own domain, so each host must serve that path from the
   outpost.
3. A `middlewares: authentik@docker` label on the protected router itself.

The `server` container joins the `proxy` network under the explicit alias
`authentik-server`; the default alias (`server`) would be far too generic on a
network every stack joins.

**Per application, not per proxy.** Each protected host gets its own Authentik
Application and its own bindings, so access is authorized independently rather
than "anyone who can log in gets everything".

## Next

**[dockge-setup.md](dockge-setup.md)** — the compose management UI. The full
sequence is in the [README build order](../README.md#build-order).
