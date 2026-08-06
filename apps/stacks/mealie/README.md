# Mealie

Recipe manager and meal planner, backed by PostgreSQL.

| | |
|---|---|
| Image | `ghcr.io/mealie-recipes/mealie:v3.22.0` |
| Internal port | `9000` |
| Database | `postgres:18` |
| Domain | `https://mealie.thefipster.de` |
| Data | `/data/mealie/` on the apps VM |
| Docs | <https://docs.mealie.io/> |

## Deploy on Coolify

Runs on the **apps VM**, deployed by Coolify from this repository in Forgejo.

1. Create the host directories, on the apps VM. Docker would create them as `root`, which the
   app data dir cannot use:

   ```bash
   sudo mkdir -p /data/mealie/data /data/mealie/postgres && sudo chown -R 1000:1000 /data/mealie/data
   ```

2. New Resource → **Docker Compose** → point it at this repository
   (`https://git.thefipster.de/<owner>/mealie`).
3. Compose file: `compose.yaml`.
4. Set the domain under **Domains** to `https://mealie.thefipster.de`. It needs no DNS record —
   `*.thefipster.de` already resolves to this VM.
5. Adjust `TZ`, `DEFAULT_EMAIL`, `DEFAULT_GROUP`, `DEFAULT_HOUSEHOLD` **before** the first deploy —
   the admin account is only seeded against an empty database.
6. Deploy. Coolify generates `SERVICE_PASSWORD_POSTGRES` and writes it into the resource's
   environment editor.

`PUBLIC_URL` already defaults to the domain above, so there is nothing to set unless you move the
service. It feeds Mealie's `BASE_URL`; if it is wrong the app still runs but invite and
password-reset links point at the wrong host.

## After first boot

- Log in with `DEFAULT_EMAIL` / `MyPassword` (Mealie's built-in default) and change the password
  right away.
- `ALLOW_SIGNUP=false` is the default here. Add users through invite links instead.

## SSO (OIDC via Authentik)

Mealie has real OIDC support, so it joins Authentik by **OIDC** rather than proxy forward-auth —
the lab convention for anything that can. Local login **stays enabled**
(`ALLOW_PASSWORD_LOGIN=true`), which is the break-glass path when Authentik is down.

Ships **off** (`OIDC_ENABLED=false`). The stack deploys and runs fine before SSO exists, which is
how it is meant to be verified first — the same staging as Grafana on the infra VM.

### Authentik side

Admin UI → **Applications → Providers → Create**, type **OAuth2/OpenID Provider**:

| Field | Value |
|---|---|
| Provider name | `mealie` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | **Confidential** |
| Redirect URI (**Strict**) | `https://mealie.thefipster.de/login` |
| Signing key | `authentik Self-signed Certificate` (default) |
| Scopes | `openid`, `profile`, `email` — the defaults; no extra mapping needed |

Then **Applications → Create**:

| Field | Value |
|---|---|
| Name / slug | `Mealie` / `mealie` |
| Provider | `mealie` |

**The slug must be exactly `mealie`.** It is baked into `OIDC_CONFIGURATION_URL` in the compose
file — Authentik's discovery document lives at `/application/o/<slug>/.well-known/…`, so a
different slug 404s at login with nothing in Mealie's logs to explain it.

Bind the application to the **`lab-users`** group. An application with no bindings admits every
authenticated user; the moment it has one, everyone unmatched is denied.

### Mealie side

Set these in Coolify's environment editor, then redeploy:

| Variable | Value |
|---|---|
| `OIDC_ENABLED` | `true` |
| `OIDC_CLIENT_ID` | from the Authentik provider |
| `OIDC_CLIENT_SECRET` | from the Authentik provider |

Everything else is already in `compose.yaml`. Two defaults worth knowing:

- **`OIDC_USER_GROUP=lab-users`** — Mealie checks the `groups` claim itself, on top of Authentik's
  binding. Authentik's default `profile` scope emits that claim; a trimmed-down custom mapping
  would not, and every login would then be rejected as "not in group".
- **`OIDC_ADMIN_GROUP` is deliberately blank.** No Authentik group grants Mealie admin — promote
  the first account inside Mealie, where its own UI shows who has it.

`OIDC_REQUIRES_EMAIL_VERIFICATION` is `true` (Mealie's own default since 3.21). Authentik's
default email mapping emits `email_verified: true`, so this works out of the box; if you ever
replace that mapping, logins fail here first.

Users are matched by **email** (`OIDC_USER_CLAIM=email`), so an Authentik user must carry the same
address as the Mealie account it should link to — the same trap as Forgejo's account linking.

## Uptime Kuma monitors

Created by hand in Kuma on the infra VM, following the lab's `<Function> <Role>` naming:

| Name | Type | Target |
|---|---|---|
| Recipes Web | HTTP(s) | `https://mealie.thefipster.de` |

**No Docker monitor**, and that is a deliberate non-row rather than a gap: Kuma reads the *infra*
VM's `docker.sock` and cannot see this machine's daemon at all. An HTTP check through Coolify's
proxy is the only signal available for anything on the apps VM.

**No Ping monitor either.** `Apps Host` in the lab's shared registry already pings this VM, below
every app on it — a second one per stack would say the same thing four times.

**No separate database monitor.** Mealie's healthcheck already gates on Postgres being healthy, so
`Recipes Web` going red covers both.

## Optional: SMTP

Password resets and invite emails need SMTP. Add these to the `mealie` service's `environment:`
block and set the values in Coolify:

```yaml
      - SMTP_HOST=${SMTP_HOST}
      - SMTP_PORT=${SMTP_PORT:-587}
      - SMTP_FROM_NAME=${SMTP_FROM_NAME:-Mealie}
      - SMTP_FROM_EMAIL=${SMTP_FROM_EMAIL}
      - SMTP_USER=${SMTP_USER}
      - SMTP_PASSWORD=${SMTP_PASSWORD}
      - SMTP_AUTH_STRATEGY=${SMTP_AUTH_STRATEGY:-TLS}
```

## Backup

Everything lives in two bind mounts, both walkable from the host:

| Path | Holds |
|---|---|
| `/data/mealie/data` | recipe images, uploads, and Mealie's own backup archives |
| `/data/mealie/postgres` | the database (PGDATA directly — see the `PGDATA` comment in the compose) |

Mealie also has a built-in backup under Settings → Backups that writes a restorable archive into
`/data/mealie/data/backups` — the more reliable option for restores across versions than a raw
copy of `postgres/`. Tier 2 in the `home-lab` repo's backup roadmap: re-scrapable, tediously. Note
that `/data` on this VM is excluded from whole-VM `vzdump` and is not covered by anything else yet.

## Upgrades

Bump the image tag in `compose.yaml` and redeploy. Read the release notes first: Mealie
occasionally ships migrations that are not reversible, so take a backup before a major bump.
