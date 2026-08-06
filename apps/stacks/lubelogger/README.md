# LubeLogger

Vehicle maintenance, fuel and service-record tracker, backed by PostgreSQL.

| | |
|---|---|
| Image | `ghcr.io/hargata/lubelogger:v1.7.0` |
| Internal port | `8080` |
| Database | `postgres:18` |
| Domain | `https://lube.thefipster.de` |
| Data | `/data/lubelogger/` on the apps VM |
| Docs | <https://docs.lubelogger.com/> |

## Deploy on Coolify

Runs on the **apps VM**, deployed by Coolify from this repository in Forgejo.

1. Create the host directories, on the apps VM:

   ```bash
   sudo mkdir -p /data/lubelogger/data /data/lubelogger/keys /data/lubelogger/postgres
   ```

2. New Resource → **Docker Compose** → point it at this repository
   (`https://git.thefipster.de/<owner>/lubelogger`).
3. Compose file: `compose.yaml`.
4. Set the domain under **Domains** to `https://lube.thefipster.de`. It needs no DNS record —
   `*.thefipster.de` already resolves to this VM.
5. Deploy. Coolify generates `SERVICE_PASSWORD_POSTGRES` and writes it into the resource's
   environment editor.

Unlike the other stacks in this library, LubeLogger has no public-URL setting of its own, so the
domain is set in Coolify and nowhere else — there is no `PUBLIC_URL` here.

## Enable authentication — do this first

**LubeLogger ships with authentication disabled.** A fresh instance behind a public domain is
wide open. Immediately after the first deploy:

1. Open the app → **Settings** tab → tick **Enable Authentication**.
2. Enter the username and password for the Root/Super User in the dialog, then click **Setup**.
3. You are redirected to a login screen — log in with those credentials.

New users are invite-only from there. Configuring SMTP (Settings → Mail) makes the invite flow
usable; without it you have to hand out registration tokens manually.

Until step 2 is done the instance is open to anyone on the LAN. The lab is LAN-only and nothing
here is exposed to the internet, but do this before you put anything real in it.

## SSO (OIDC via Authentik)

LubeLogger has real OIDC support, so it joins Authentik by **OIDC** rather than proxy forward-auth —
the lab convention for anything that can. Local login **stays enabled**
(`OpenIDConfig__DisableRegularLogin=false`), the break-glass path when Authentik is down.

**Enable authentication first** (the section above). OIDC does nothing while LubeLogger is
unauthenticated — there is no login flow for it to plug into.

LubeLogger has **no enable flag**: the login page grows an SSO button the moment
`OpenIDConfig__ClientId` and `OpenIDConfig__ClientSecret` carry values, and blank keeps it off.
That is what stages this the same way the other stacks stage their `OIDC_ENABLED`.

### Authentik side

Admin UI → **Applications → Providers → Create**, type **OAuth2/OpenID Provider**:

| Field | Value |
|---|---|
| Provider name | `lubelogger` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | **Confidential** |
| Redirect URI (**Strict**) | `https://lube.thefipster.de/Login/RemoteAuth` |
| Signing key | `authentik Self-signed Certificate` (default) |
| Scopes | `openid`, `profile`, `email` — the defaults |

Then **Applications → Create**:

| Field | Value |
|---|---|
| Name / slug | `LubeLogger` / `lubelogger` |
| Provider | `lubelogger` |

**The slug must be exactly `lubelogger`** — it appears in `OpenIDConfig__LogOutURL` in the compose
file. Note that only the issuer and end-session endpoints carry the slug; Authentik's
authorize/token/userinfo endpoints are instance-global, which is why the other three URLs in the
compose have no slug in them and look wrong at first glance.

Bind the application to the **`lab-users`** group.

### LubeLogger side

Set these in Coolify's environment editor, then redeploy:

| Variable | Value |
|---|---|
| `OIDC_CLIENT_ID` | from the Authentik provider |
| `OIDC_CLIENT_SECRET` | from the Authentik provider |

Everything else is already in `compose.yaml`. Three things it does differently from the rest of
the lab:

- **No discovery.** LubeLogger reads no `.well-known` document, so every endpoint is spelled out
  by hand. An Authentik URL change is a compose edit here, not a re-fetch.
- **PKCE is on** (`OpenIDConfig__UsePKCE=true`) along with state validation. Both default to
  `false` upstream; there is no reason to run without them against a provider that supports both.
- **The redirect URL must be HTTPS** and match Authentik exactly. For diagnosing a failing login,
  upstream offers `https://lube.thefipster.de/Login/RemoteAuthDebug`, which dumps the claims it
  received — point `OpenIDConfig__RedirectURL` *and* the Authentik redirect URI at it temporarily,
  then put both back.

Users are matched to a local LubeLogger account by **email**, so the Authentik user must carry the
same address as the account it should link to.

## Uptime Kuma monitors

Created by hand in Kuma on the infra VM, following the lab's `<Function> <Role>` naming:

| Name | Type | Target |
|---|---|---|
| Vehicles Web | HTTP(s) | `https://lube.thefipster.de` |

**No Docker monitor**, and that is a deliberate non-row rather than a gap: Kuma reads the *infra*
VM's `docker.sock` and cannot see this machine's daemon at all. An HTTP check through Coolify's
proxy is the only signal available for anything on the apps VM.

**No Ping monitor either.** `Apps Host` in the lab's shared registry already pings this VM, below
every app on it.

**No separate database monitor.** LubeLogger waits on a healthy Postgres before it starts, so
`Vehicles Web` going red covers both.

## Postgres vs. the embedded database

`POSTGRES_CONNECTION` switches LubeLogger from its embedded file database to Postgres; the app
creates its own tables on first connect. Remove that variable and the `postgres` service to run
on the embedded database instead — but migrate the data first (Settings has an import/export
tool); the two backends do not share storage.

`/data/lubelogger/data` is still required either way: uploaded receipts, documents and vehicle
images are stored on disk, not in the database.

## Backup

| Path | Holds |
|---|---|
| `/data/lubelogger/postgres` | all records (PGDATA directly) |
| `/data/lubelogger/data` | uploaded receipts, documents, vehicle images |
| `/data/lubelogger/keys` | ASP.NET data-protection keys — losing these logs everyone out, nothing worse |

Tier 2 in the `home-lab` repo's backup roadmap: hand-entered service history, with no upstream to
re-fetch it from. `/data` on this VM is excluded from whole-VM `vzdump` and is not covered by
anything else yet.

## Upgrades

Bump the image tag in `compose.yaml` and redeploy.
