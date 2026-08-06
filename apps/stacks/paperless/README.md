# Paperless-ngx

Document management system: scan in, OCR, full-text searchable archive.

| | |
|---|---|
| Image | `ghcr.io/paperless-ngx/paperless-ngx:3.0.5` |
| Internal port | `8000` |
| Services | app · `postgres:18` · `valkey:9` · `gotenberg:8.34` · `tika:3.3.1.0` |
| Domain | `https://paperless.thefipster.de` |
| Data | `/data/paperless/` on the apps VM |
| Docs | <https://docs.paperless-ngx.com/> |

Mirrors upstream's `docker-compose.postgres-tika.yml`, adapted for Coolify.

## Deploy on Coolify

Runs on the **apps VM**, deployed by Coolify from this repository in Forgejo.

1. Create the host directories, on the apps VM. `consume/` and `export/` need to be writable by
   whatever drops files there — that UID must match `USERMAP_UID`:

   ```bash
   sudo mkdir -p /data/paperless/{data,media,postgres,redis,consume,export} && sudo chown -R 1000:1000 /data/paperless/consume /data/paperless/export
   ```

2. New Resource → **Docker Compose** → point it at this repository
   (`https://git.thefipster.de/<owner>/paperless`).
3. Compose file: `docker-compose.yml`.
4. Set `PAPERLESS_OCR_LANGUAGE` and `TZ` **before** the first deploy if the defaults
   (`deu+eng`, `Europe/Berlin`) are wrong — OCR language is applied per document at ingest time,
   so changing it later only affects new documents.
5. Set the domain under **Domains** to `https://paperless.thefipster.de`. It needs no DNS record —
   `*.thefipster.de` already resolves to this VM.
6. Deploy. Coolify generates `PAPERLESS_SECRET_KEY`, the Postgres password and the admin password,
   and writes them into the resource's environment editor.

`PUBLIC_URL` already defaults to the domain above and feeds `PAPERLESS_URL`, which drives Django's
`ALLOWED_HOSTS` and `CSRF_TRUSTED_ORIGINS`. If it is wrong or lacks the scheme, the UI loads but
logging in fails with a CSRF error — change it only together with the domain.

First start is slow (migrations plus index build). The healthcheck allows 2 minutes before it
starts counting failures.

## Login

`PAPERLESS_ADMIN_USER` (default `admin`) with the generated `SERVICE_PASSWORD_ADMIN` — read it out
of Coolify's environment editor. These are only applied against an empty database; changing them
later does nothing. Change the password in the UI afterwards.

## consume/ and export/

`/data/paperless/consume` and `/data/paperless/export` are fixed host paths, deliberately — they
are the two directories you reach from outside the container. Anything dropped into `consume/` is
ingested and then removed.

Point your scanner or an SMB share at `/data/paperless/consume`. `USERMAP_UID`/`USERMAP_GID`
control the ownership Paperless expects there — they must match the host user writing the files,
or ingest fails on permissions.

## Trimming the stack

`gotenberg` and `tika` exist only to consume Office documents (`.docx`, `.odt`, `.xlsx`, …) and
`.eml` e-mail. If you only ever feed it PDFs and images, delete both services, their two
`depends_on` entries, and the three `PAPERLESS_TIKA_*` variables. That saves roughly 700 MB of RAM.

## Backup

**This is the one tier-1 stack on the apps VM** — the originals are paper, or gone.

The supported route is Paperless' own exporter, not a raw copy of the data directories:

```bash
docker compose exec -T paperless document_exporter ../export
```

That writes a self-contained, version-portable archive into `/data/paperless/export`. Back that
directory up.

The paths, for completeness:

| Path | Holds |
|---|---|
| `/data/paperless/media` | originals and archived PDFs — the irreplaceable half |
| `/data/paperless/postgres` | metadata: tags, correspondents, dates (PGDATA directly) |
| `/data/paperless/data` | search index, classifier — rebuildable |
| `/data/paperless/redis` | task queue — disposable |
| `/data/paperless/export` | exporter output; this is what a backup job should pick up |

`/data` on this VM is excluded from whole-VM `vzdump` and is not covered by anything else yet, so
until the file-level backup layer exists, treat this as unbacked and export by hand.

## Upgrades

Bump the image tag and redeploy. Never skip a major version — check
<https://docs.paperless-ngx.com/changelog/> for breaking changes, and export first.
