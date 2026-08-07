# BookStack

Self-hosted wiki / documentation platform, backed by MariaDB.

| | |
|---|---|
| Image | `lscr.io/linuxserver/bookstack:26.05.3` |
| Internal port | `80` |
| Database | `mariadb:12.3` (the current LTS line; BookStack requires MariaDB ≥ 10.6 or MySQL ≥ 8.0) |
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
3. Compose file: `compose.yaml`.
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

## SSO (OIDC via Authentik)

BookStack has real OIDC support, so it joins Authentik by **OIDC** rather than proxy forward-auth —
the lab convention for anything that can.

**BookStack is the exception to the lab's "local login stays enabled" rule, and it is not
fixable.** `AUTH_METHOD` takes exactly one value: setting it to `oidc` **replaces** the
email/password form rather than sitting beside it. There is no configuration in which both work.
So the break-glass path is not a login page — it is setting `AUTH_METHOD` back to `standard` in
Coolify and redeploying, which restores the `admin@admin.com` account untouched. Know that before
you need it.

Ships as `standard`. The stack deploys and runs fine before SSO exists, which is how it is meant to
be verified first.

### Authentik side

Admin UI → **Applications → Providers → Create**, type **OAuth2/OpenID Provider**:

| Field | Value |
|---|---|
| Provider name | `bookstack` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | **Confidential** |
| Redirect URI (**Strict**) | `https://wiki.thefipster.de/oidc/callback` |
| Signing key | `authentik Self-signed Certificate` (default) |
| Scopes | `openid`, `profile`, `email` — the defaults |

Then **Applications → Create**:

| Field | Value |
|---|---|
| Name / slug | `BookStack` / `bookstack` |
| Provider | `bookstack` |

**The slug must be exactly `bookstack`.** It is baked into `OIDC_ISSUER` in the compose file, and
with `OIDC_ISSUER_DISCOVER=true` that URL is where BookStack reads every endpoint from — a
different slug fails discovery at login rather than at deploy.

Bind the application to the **`lab-users`** group.

### BookStack side

Set these in Coolify's environment editor, then redeploy:

| Variable | Value |
|---|---|
| `AUTH_METHOD` | `oidc` |
| `OIDC_CLIENT_ID` | from the Authentik provider |
| `OIDC_CLIENT_SECRET` | from the Authentik provider |

Everything else is already in `compose.yaml`. Two defaults worth knowing:

- **`OIDC_USER_TO_GROUPS=false`.** BookStack's own roles decide permissions. Turning group sync on
  makes Authentik authoritative and silently demotes anyone who is not in a matching group — a
  surprising way to lose your own admin rights on the next login.
- **`AUTH_AUTO_INITIATE` is not set.** It skips BookStack's login page and bounces straight to
  Authentik, which removes the one page you can still reach when Authentik is what broke.

New users are created on first SSO login and matched thereafter by the `sub` claim, not by email.

## Uptime Kuma monitors

Created by hand in Kuma on the infra VM, following the lab's `<Function> <Role>` naming:

| Name | Type | Target |
|---|---|---|
| Wiki Web | HTTP(s) | `https://wiki.thefipster.de` |

**No Docker monitor**, and that is a deliberate non-row rather than a gap: Kuma reads the *infra*
VM's `docker.sock` and cannot see this machine's daemon at all. An HTTP check through Coolify's
proxy is the only signal available for anything on the apps VM.

**No Ping monitor either.** `Apps Host` in the lab's shared registry already pings this VM, below
every app on it.

**No separate MariaDB monitor.** BookStack's healthcheck already gates on the database being
healthy, so `Wiki Web` going red covers both.

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
