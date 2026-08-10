# Immich

Self-hosted photo and video library — phone backup, timeline, albums, face and object search.

| | |
|---|---|
| Image | `ghcr.io/immich-app/immich-server:v3.1.0` |
| Internal port | `2283` |
| Services | server · machine learning · `valkey:9` · Immich's own `postgres:18` build |
| Domain | `https://immich.thefipster.de` |
| Data | `/data/immich/` on the apps VM |
| Docs | <https://docs.immich.app/> |

Mirrors upstream's `docker/docker-compose.yml`, adapted for Coolify: no published host
ports, bind mounts instead of named volumes, and the machine-learning service left
under its upstream name because Immich dials it by that name.

## The database is not `postgres:18`, deliberately

Immich stores smart-search and face embeddings as vectors and **refuses to start** unless the
[VectorChord](https://github.com/tensorchord/VectorChord) extension is present — it checks the
version on startup. The stock `postgres:18` image does not carry it, so this is the second stack
on this VM whose database engine deviates from the lab standard, after BookStack's MariaDB.

The image here is Immich's own build of Postgres + pgvector + VectorChord, and two choices inside
that tag are worth knowing:

- **Postgres 18**, not the 14 upstream's default compose still pins. Immich supports `>= 14, < 20`;
  upstream ships 14 because an existing installation's data directory cannot change major version
  in place. This lab has no existing installation to carry forward, so it starts on the same major
  as every other database in it.
- **No `pgvectors`**, the legacy pgvecto.rs extension. Its only purpose is migrating installs
  created before VectorChord existed. A fresh deploy has nothing to migrate.

`PGDATA` is pinned to `/var/lib/postgresql/data` for the same reason as every other Postgres in
the lab, and it matters more here: Immich's entrypoint substitutes that path into the
`postgresql.conf` it generates at first start.

## Deploy on Coolify

Runs on the **apps VM**, deployed by Coolify from this repository in Forgejo.

1. Create the host directories, on the apps VM. All three are written by containers running as
   root, so there is no `chown` step:

   ```bash
   sudo mkdir -p /data/immich/{library,postgres,model-cache}
   ```

2. New Resource → **Docker Compose** → point it at this repository
   (`https://git.thefipster.de/<owner>/immich`).
3. Compose file: `compose.yaml`.
4. Set the domain under **Domains** to `https://immich.thefipster.de`. It needs no DNS record —
   `*.thefipster.de` already resolves to this VM.
5. Raise the proxy's response timeouts **before** uploading anything large — see
   [below](#uploads-die-after-a-minute-through-coolifys-proxy).
6. Deploy. Coolify generates `SERVICE_PASSWORD_POSTGRES` and writes it into the resource's
   environment editor.
7. Open the domain and create the admin account when prompted. The first account created owns the
   instance; everyone else is added from **Administration → Users** or arrives through SSO.

First start pulls several gigabytes of images and runs the schema migrations, so give it a few
minutes.
The machine-learning container downloads its models on first use, not at startup — the first smart
search is slow once, then cached in `/data/immich/model-cache`.

## Uploads die after a minute through Coolify's proxy

Coolify's bundled proxy is Traefik, whose `respondingTimeouts` default to 60 seconds. A video
upload that takes longer than that is cut off — the client reports a **499** and the asset never
lands. This is the single most likely thing to go wrong with Immich behind Coolify, and it is not
fixable from this repository: the proxy's configuration is edited in Coolify's UI, under
**Servers → Proxy → Configuration** — the same file that carries the `NETCUP_*` flags for the
wildcard certificate.

Add the transport block to the entrypoint Immich is served on:

```yaml
entryPoints:
  websecure:
    address: :443
    transport:
      respondingTimeouts:
        readTimeout: 600s
        idleTimeout: 600s
```

Ten minutes covers a long video on a LAN. Raise it if uploads still stop mid-file rather than
failing immediately — an immediate failure is a different problem.

## What this stack needs from the machine

- **RAM.** Immich asks for 6 GB minimum, 8 GB recommended, and that is on top of Coolify and
  everything else on this VM. The apps VM has 24 GB, so this fits — but it is the largest single
  tenant on the machine, and the machine-learning container is most of it.
- **CPU instruction set.** Since v3, the machine-learning image requires `x86-64-v2`. The apps VM
  is created with the Proxmox CPU type **`host`** (the `home-lab` repo's `docs/proxmox-setup.md`
  Part 5), so it inherits the physical CPU's feature set and this is satisfied. A VM created with
  the `kvm64` default would fail here, and the failure is a crash loop in one container while the
  rest of the stack looks healthy.
- **Local storage.** Immich's database entrypoint checks the filesystem under `PGDATA` and
  **refuses to start** on a network share. `/data` is ext4 on the VM's second disk, which passes.

## SSO (OIDC via Authentik)

Immich has real OIDC support, so it joins Authentik by **OIDC** rather than proxy forward-auth —
the lab convention for anything that can. Local login stays enabled, which is the break-glass path
when Authentik is down.

**Its OAuth settings are not in `compose.yaml`, and that is a deliberate exception to how every
other stack here stages SSO.** Immich keeps system settings in its own database and edits them in
the admin UI. The one way to declare them in a file is `IMMICH_CONFIG_FILE`, which points at a JSON
document holding the *entire* system configuration — and setting it **disables editing every other
setting in the web UI**, from job concurrency to storage templates. Trading the whole admin UI for
one reviewable block is a bad deal, so the values live below instead, in the file a reader already
opens to change this stack.

Nothing about the deploy depends on SSO existing: the stack comes up with OAuth off, which is how
it is meant to be verified first.

### Authentik side

Admin UI → **Applications → Providers → Create**, type **OAuth2/OpenID Provider**:

| Field | Value |
|---|---|
| Provider name | `immich` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | **Confidential** |
| Redirect URI 1 (**Strict**, `Authorization`) | `https://immich.thefipster.de/auth/login` |
| Redirect URI 2 (**Strict**, `Authorization`) | `https://immich.thefipster.de/user-settings` |
| Redirect URI 3 (**Strict**, `Authorization`) | `app.immich:///oauth-callback` |
| Signing key | `authentik Self-signed Certificate` (default) |
| Scopes | `openid`, `profile`, `email` — the defaults |

Then **Applications → Create**:

| Field | Value |
|---|---|
| Name / slug | `Immich` / `immich` |
| Provider | `immich` |

All three redirect URIs are required and each covers a different path:

- **`/auth/login`** — signing in from the web client.
- **`/user-settings`** — linking an existing Immich account to OAuth by hand.
- **`app.immich:///oauth-callback`** — the mobile app. It is a custom URL scheme, not a typo;
  without it the iOS and Android apps cannot complete a login.

The purpose selector (`Authorization` above) exists from Authentik 2026.5 onward, which is the
version this lab pins; older releases treat every redirect URI as `Authorization` and have no
selector.

Bind the application to the **`lab-users`** group. An application with no bindings admits every
authenticated user; the moment it has one, everyone unmatched is denied.

### Immich side

**Administration → Settings → OAuth Authentication**, then save and no redeploy is needed —
these are database settings, not environment variables:

| Setting | Value |
|---|---|
| Enabled | on |
| `issuer_url` | `https://auth.thefipster.de/application/o/immich/` |
| `client_id` | from the Authentik provider |
| `client_secret` | from the Authentik provider |
| Button text | `Sign in with Authentik` |

**The application slug must be exactly `immich`** — it is the middle of that issuer URL, and a
mismatch fails discovery at login rather than at save time. The `.well-known/openid-configuration`
suffix is optional; Immich appends it during discovery.

Three defaults worth leaving alone:

- **Auto Register stays on.** The Immich user is created on first SSO login, matching Forgejo's
  auto-registration. New accounts arrive with no albums and the default storage quota.
- **Auto Launch stays off.** It skips the login page and bounces straight to Authentik, which
  removes the one page still reachable when Authentik is what broke.
- **Password login stays enabled** (Settings → Authentication). It is the break-glass path, and the
  admin account created at setup is the one that repairs everything else.

## Uptime Kuma monitors

Created by hand in Kuma on the infra VM, following the lab's `<Function> <Role>` naming:

| Name | Type | Target |
|---|---|---|
| Photos Web | HTTP(s) | `https://immich.thefipster.de` |

**No Docker monitor**, and that is a deliberate non-row rather than a gap: Kuma reads the *infra*
VM's `docker.sock` and cannot see this machine's daemon at all. An HTTP check through Coolify's
proxy is the only signal available for anything on the apps VM.

**No Ping monitor either.** `Apps Host` in the lab's shared registry already pings this VM, below
every app on it.

**No monitor for the machine-learning container, and that one is a real blind spot rather than a
tidy non-row.** It has no HTTP route of its own, and the server stays up and serves the timeline
without it — so smart search and face detection can be dead for days with `Photos Web` green. The
symptom to watch for is new uploads never gaining faces or search results.

## Backup

**Tier 1** in the `home-lab` repo's backup roadmap, alongside Paperless: this is where a phone's
photos go to be safe, which means it is the copy that outlives the phone.

Immich takes its own database dumps — daily at 02:00, keeping the last 14, adjustable under
**Administration → Settings → Backup**. They land in `/data/immich/library/backups`, so they are
inside the library directory a file-level backup already walks. Trigger one by hand from
**Administration → Job Queues → Create job → Create Database Dump**.

| Path | Holds |
|---|---|
| `/data/immich/library` | originals, thumbnails, encoded video, profile images — **and** the database dumps |
| `/data/immich/postgres` | the live database: albums, faces, search vectors, file paths (PGDATA directly) |
| `/data/immich/model-cache` | downloaded ML models — rebuildable, just slow |

A restore needs the library **and** a database dump: Immich does not scan the library folder, so
the files are meaningless without the metadata that points at them. The dump is the supported form
of that half — `/data/immich/postgres` copied from a running server is torn by construction, the
same rule the infra VM's restic layer follows.

`/data` on this VM is excluded from whole-VM `vzdump` and is not covered by anything else yet —
the file-level layer runs on the infra VM, and this machine has not joined its restic repository.
**Until it does, treat this instance as a second copy of what is still on the phone, not as the
place the phone's photos are kept.** Copying `/data/immich/library` off the box by hand is the
stopgap, the same one Paperless has.

## Upgrades

Bump **both** immich tags in the same commit — server and machine learning are released together
and a mismatched pair is unsupported — then redeploy. Migrations run on start. Read
<https://github.com/immich-app/immich/releases> first: Immich ships fast and its major releases
have carried breaking changes, so take a database dump before a major bump.

The database image moves on its own schedule and rarely: bumping the VectorChord version in that
tag means reindexing, which Immich's own docs cover under
<https://docs.immich.app/administration/postgres-standalone>.
