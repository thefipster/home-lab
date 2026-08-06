# BookStack

Self-hosted wiki / documentation platform, backed by MariaDB.

| | |
|---|---|
| Image | `lscr.io/linuxserver/bookstack:26.05.3` |
| Internal port | `80` |
| Database | `mariadb:11.8` (BookStack requires MariaDB ≥ 10.6 or MySQL ≥ 8.0) |
| Domain | `https://wiki.thefipster.de` |
| Data | `/data/bookstack/` on the apps VM |
| Docs | <https://www.bookstackapp.com/docs/> · <https://docs.linuxserver.io/images/docker-bookstack/> |

BookStack does not publish an official image. Its own installation docs point at the
LinuxServer.io image, which is what this stack uses. It is also the one service in the lab on
MariaDB rather than Postgres — it supports no PostgreSQL at all, and the reasoning for keeping it
anyway is in the `home-lab` repo's `apps/services.md`.

## Deploy on Coolify

Runs on the **apps VM**, deployed by Coolify from this repository in Forgejo.

1. Create the host directories, on the apps VM:

   ```bash
   sudo mkdir -p /data/bookstack/config /data/bookstack/mariadb
   ```

2. New Resource → **Docker Compose** → point it at this repository
   (`https://git.thefipster.de/<owner>/bookstack`).
3. Compose file: `docker-compose.yml`.
4. Set the domain under **Domains** to `https://wiki.thefipster.de`. It needs no DNS record —
   `*.thefipster.de` already resolves to this VM.
5. Deploy. Coolify generates `APP_KEY` and both MariaDB passwords, and writes them into the
   resource's environment editor.

`PUBLIC_URL` already defaults to the domain above and feeds BookStack's `APP_URL`, which has to
match the external URL exactly, scheme included. A mismatch shows up as broken CSS, failed logins,
or redirect loops rather than an obvious error — so change it only together with the domain.

## Default login

`admin@admin.com` / `password`. Change both on first login.

## APP_KEY

Generated once as `base64:${SERVICE_REALBASE64_32_BOOKSTACK}`. **Do not rotate it** — BookStack
encrypts stored data (e.g. third-party auth secrets) with it, and a new key makes that data
unrecoverable. If you ever move this instance, copy the value out of Coolify's environment editor
along with the volumes.

To generate one by hand:

```bash
docker run -it --rm --entrypoint /bin/bash lscr.io/linuxserver/bookstack:26.05.3 appkey
```

## Optional: async queue and SMTP

For background email and audit processing, add `- QUEUE_CONNECTION=database` to the `bookstack`
service. SMTP is configured with the `MAIL_*` variables documented at
<https://www.bookstackapp.com/docs/admin/email-webhooks/>; add the ones you need to the
`environment:` block so they reach the container.

## Backup

| Path | Holds |
|---|---|
| `/data/bookstack/mariadb` | pages, users, permissions |
| `/data/bookstack/config` | uploaded images and attachments, plus the generated `.env` |

Both are needed for a restore. A `mysqldump` of the `bookstack` database is the safer form for the
database half — a live copy of the data directory is torn. Tier 2 in the `home-lab` repo's backup
roadmap: authored, but small. `/data` on this VM is excluded from whole-VM `vzdump` and is not
covered by anything else yet.

## Upgrades

Bump the image tag and redeploy; migrations run on start. BookStack does not support skipping
major versions backwards, so take a backup before a large jump.
