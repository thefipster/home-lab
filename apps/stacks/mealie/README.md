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
3. Compose file: `docker-compose.yml`.
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

Bump the image tag in `docker-compose.yml` and redeploy. Read the release notes first: Mealie
occasionally ships migrations that are not reversible, so take a backup before a major bump.
