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
3. Compose file: `docker-compose.yml`.
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

Bump the image tag in `docker-compose.yml` and redeploy.
