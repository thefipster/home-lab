# Paperless-ngx

Document management system: scan in, OCR, full-text searchable archive.

| | |
|---|---|
| Image | `ghcr.io/paperless-ngx/paperless-ngx:3.0.5` |
| Internal port | `8000` |
| Services | app · `postgres:18` · `valkey:9` |
| Accepts | **PDFs and images only** — see below |
| Domain | `https://paperless.thefipster.de` |
| Data | `/data/paperless/` on the apps VM |
| Docs | <https://docs.paperless-ngx.com/> |

Mirrors upstream's `docker-compose.postgres.yml`, adapted for Coolify.

## PDFs and images only, deliberately

Paperless parses PDFs, JPEG, PNG and TIFF itself, with OCRmyPDF and Tesseract built into the
image. **Everything else — `.docx`, `.odt`, `.xlsx`, `.pptx`, `.eml` — needs two more containers**,
and upstream's `postgres-tika` variant ships them: Apache Tika to extract text and metadata, and
Gotenberg (LibreOffice + Chromium behind an HTTP API) to render the archive PDF.

This stack has **neither**. Documents are converted to PDF before they reach the consume directory,
which makes roughly 700 MB of resident RAM and two more images to track a cost with nothing on the
other side of it. Dropping a `.docx` into `consume/` will simply not be ingested — no error in the
UI, just a file that stays put.

To change that, add both services back with `PAPERLESS_TIKA_ENABLED=1`,
`PAPERLESS_TIKA_ENDPOINT` and `PAPERLESS_TIKA_GOTENBERG_ENDPOINT`, and give Gotenberg
`--chromium-disable-javascript=true` and a `--chromium-allow-list` — rendering `.eml` means
pointing a browser at mail somebody else wrote, and it should not be able to fetch or execute
anything while doing it.

## Deploy on Coolify

Runs on the **apps VM**, deployed by Coolify from this repository in Forgejo.

1. Create the host directories, on the apps VM. `consume/` and `export/` need to be writable by
   whatever drops files there — that UID must match `USERMAP_UID`:

   ```bash
   sudo mkdir -p /data/paperless/{data,media,postgres,redis,consume,export} && sudo chown -R 1000:1000 /data/paperless/consume /data/paperless/export
   ```

2. New Resource → **Docker Compose** → point it at this repository
   (`https://git.thefipster.de/<owner>/paperless`).
3. Compose file: `compose.yaml`.
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

## SSO (OIDC via Authentik)

Paperless has real OIDC support (through django-allauth), so it joins Authentik by **OIDC** rather
than proxy forward-auth — the lab convention for anything that can. Local login **stays enabled**
(`PAPERLESS_DISABLE_REGULAR_LOGIN=false`), the break-glass path when Authentik is down.

Ships **off**: `PAPERLESS_APPS` is empty, so django-allauth never loads the OIDC provider app and
the provider block in `compose.yaml` is inert. The stack deploys and runs fine before SSO exists.

**Why the JSON is in the compose file.** Paperless takes its whole provider configuration as one
`PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON blob. Pasting that into Coolify's environment editor
would put the only copy of a structured, easy-to-typo config somewhere no diff can see it — so it
lives in the compose with `${OIDC_CLIENT_ID}` / `${OIDC_CLIENT_SECRET}` interpolated in, and only
those two values are set in Coolify. The secret never lands in git; the structure never leaves it.

### Authentik side

Admin UI → **Applications → Providers → Create**, type **OAuth2/OpenID Provider**:

| Field | Value |
|---|---|
| Provider name | `paperless` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | **Confidential** |
| Redirect URI (**Strict**) | `https://paperless.thefipster.de/accounts/oidc/authentik/login/callback/` |
| Signing key | `authentik Self-signed Certificate` (default) |
| Scopes | `openid`, `profile`, `email` — the defaults |

Then **Applications → Create**:

| Field | Value |
|---|---|
| Name / slug | `Paperless` / `paperless` |
| Provider | `paperless` |

Two strings in that redirect URI are load-bearing and easy to get wrong:

- **`authentik`** is the `provider_id` from the JSON in `compose.yaml`, not a product name.
  Changing one without the other breaks the callback.
- **The trailing slash.** django-allauth's route has one; Authentik's **Strict** matching does not
  forgive its absence.

**The application slug must be exactly `paperless`** — it is in the `server_url` discovery URL in
the compose file.

Bind the application to the **`lab-users`** group.

### Paperless side

Set these in Coolify's environment editor, then redeploy:

| Variable | Value |
|---|---|
| `OIDC_ENABLED_APP` | `allauth.socialaccount.providers.openid_connect` |
| `OIDC_CLIENT_ID` | from the Authentik provider |
| `OIDC_CLIENT_SECRET` | from the Authentik provider |

`OIDC_ENABLED_APP` feeds `PAPERLESS_APPS`, which is what puts the provider into Django's
`INSTALLED_APPS` — that variable is the on/off switch, not the credentials.

Two defaults worth knowing:

- **`PAPERLESS_SOCIAL_AUTO_SIGNUP=true`** — the Paperless user is created on first SSO login
  instead of stopping at a signup form, the same call Forgejo's auto-registration makes. New
  accounts arrive with **no document permissions**; grant them in Paperless.
- **`PAPERLESS_REDIRECT_LOGIN_TO_SSO=false`** — the login page stays reachable rather than
  bouncing to Authentik, which is what keeps the break-glass path usable.

PKCE and `fetch_userinfo` are both on in the JSON, matching Authentik's own integration guidance.

## consume/ and export/

`/data/paperless/consume` and `/data/paperless/export` are fixed host paths, deliberately — they
are the two directories you reach from outside the container. Anything dropped into `consume/` is
ingested and then removed.

Point your scanner or an SMB share at `/data/paperless/consume`. `USERMAP_UID`/`USERMAP_GID`
control the ownership Paperless expects there — they must match the host user writing the files,
or ingest fails on permissions.

**A file that stays in `consume/` has not been ingested.** With Tika and Gotenberg absent, that is
the expected outcome for anything that is not a PDF or an image — convert it and drop it again.
Permissions are the other cause; the two look identical from the outside, so check
`USERMAP_UID` against the file's owner before assuming it is the format.

## Uptime Kuma monitors

Created by hand in Kuma on the infra VM, following the lab's `<Function> <Role>` naming:

| Name | Type | Target |
|---|---|---|
| Documents Web | HTTP(s) | `https://paperless.thefipster.de` |

**No Docker monitor**, and that is a deliberate non-row rather than a gap: Kuma reads the *infra*
VM's `docker.sock` and cannot see this machine's daemon at all. An HTTP check through Coolify's
proxy is the only signal available for anything on the apps VM.

**No Ping monitor either.** `Apps Host` in the lab's shared registry already pings this VM, below
every app on it.

**No monitor for the consumer, and none is needed.** Paperless runs its consumer in the same
container as the web server, so `Documents Web` already covers it. That is a consequence of
[dropping Tika and Gotenberg](#pdfs-and-images-only-deliberately): with those two present, ingest
would depend on containers that have no route of their own, and their death would look like a
document that silently never arrives. Here every ingest failure is inside the one container the
monitor already watches.

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
