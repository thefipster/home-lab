# Habitica

Habit tracker and to-do list built as a role-playing game: habits, dailies and to-dos deal damage
or hand out gold, and the party mechanics turn chores into a co-op raid.

| | |
|---|---|
| Image | `docker.io/awinterstein/habitica-server:5.48.8` |
| Internal port | `3000` |
| Database | **MongoDB** `8.0.28`, as a single-member replica set |
| Domain | `https://habitica.thefipster.de` |
| Data | `/data/habitica/` on the apps VM |
| Docs | <https://habitica.fandom.com/wiki/Habitica_Wiki> · <https://github.com/awinterstein/habitica> |

## The image is a third-party fork, and that is the first thing to decide

Habitica's own repository (`HabitRPG/habitica`) publishes **no production image** — its
`docker-compose.yml` builds a development environment and nothing else. Self-hosting is not a
supported use case upstream, so every self-hosted instance runs somebody's adaptation.

This stack uses `awinterstein/habitica`, which rebases a fixed set of patches onto each upstream
release and publishes server and client images per version. Its changes are what make a private
instance behave sensibly:

- every account gets a subscription on registration that never expires
- the **first registered user becomes admin**
- gem purchases become gold purchases; group plans need no payment
- mail goes to a configured SMTP server instead of Mailchimp/Mandrill
- registration can be closed with `INVITE_ONLY`
- analytics and payment scripts are not loaded

**What that costs:** the images are built by a third party from a rebase of somebody else's
application, and this lab runs them with `docker.sock`-adjacent neighbours on a single-tenant box.
The fork is public and reproducible — its Dockerfile and workflow are in the repository above — so
the alternative, if that trade is not acceptable, is building the image yourself from the
`self-host` branch and pushing it to the lab's own registry on the infra VM. Nothing else in this
stack changes if you do; only the `image:` line does.

The fork also states one limitation plainly: third-party access and scripts are not thoroughly
disabled, so an instance still loads more than it strictly needs.

## Deploy on Coolify

Runs on the **apps VM**, deployed by Coolify from this repository in Forgejo.

1. Create the host directories, on the apps VM. Both are MongoDB's, and its entrypoint chowns what
   it needs:

   ```bash
   sudo mkdir -p /data/habitica/db /data/habitica/dbconf
   ```

2. New Resource → **Docker Compose** → point it at this repository
   (`https://git.thefipster.de/<owner>/habitica`).
3. Compose file: `compose.yaml`.
4. Set the domain under **Domains** to `https://habitica.thefipster.de`. It needs no DNS record —
   `*.thefipster.de` already resolves to this VM.
5. Set `ADMIN_EMAIL` before the first deploy. Leave `INVITE_ONLY` at `false` for now.
6. Deploy. Coolify generates the three session secrets and writes them into the resource's
   environment editor.
7. Open the domain and register. **The first account to register becomes the admin** — do this
   before telling anyone else the URL.
8. Register the other accounts you want, then set `INVITE_ONLY=true` in Coolify and redeploy.

`PUBLIC_URL` already defaults to the domain above and feeds `BASE_URL`. If it is wrong the app
still runs, but invite and password-reset links point at the wrong host.

MongoDB takes a few seconds longer than usual on the very first start: the replica set does not
exist yet, and the health check is what creates it (see below). The server waits for that.

**If a session secret comes out as a literal `${SERVICE_HEX_64_SESSIONKEY}` in the container's
environment**, this Coolify predates the `HEX` generator. Generate the values by hand —
`openssl rand -hex 32` for the key, `openssl rand -hex 16` for the IV, anything long for
`SESSION_SECRET` — and paste them into the environment editor. Do not deploy with the placeholders
the image ships.

## MongoDB, and why it is a replica set

Habitica uses multi-document transactions, which MongoDB only offers on a replica set — so even a
single node has to be one. The compose starts `mongod --replSet rs`, and the **health check is what
initiates the set**: `rs.status()` throws until the set exists, and the catch block calls
`rs.initiate()`. There is no init container and no manual step. It also means "healthy" genuinely
means "the replica set is up", which is what `depends_on: service_healthy` on the server waits for.

`hostname: mongo` is load-bearing for the same reason: `rs.initiate()` records the member under
whatever hostname the container has, and every client afterwards dials exactly that name.

**The database has no credentials**, and that is a deliberate deviation from the rest of the lab.
Enabling authentication on a replica set also requires a shared keyfile for member-to-member
authentication — real setup for a single-member set whose only client is the container beside it,
on a network with no host port published. If this instance ever grows a second consumer, that is
the point to revisit it, and the keyfile is the work.

MongoDB is also the second database engine on this VM after BookStack's MariaDB, and the third in
the lab. Habitica offers no choice; the `home-lab` repo's `apps/services.md` records that.

## No SSO, and it cannot be fixed here

**Habitica has no OIDC support at all.** It authenticates against its own user collection, plus
Google and Apple social login — neither of which is an identity provider this lab runs. So this is
the first application on the apps VM that joins neither of the lab's two SSO patterns.

The other pattern, forward-auth, is not available on this machine. The lab's forward-auth wiring is
a set of labels on the Authentik container behind the **infra VM's** Traefik: a shared
`authentik@docker` middleware plus a per-host outpost router. Coolify runs its own separate Traefik
on this VM, which knows nothing about either. Bringing forward-auth here would mean declaring the
middleware and an outpost route inside Coolify's own proxy configuration — a second, hand-edited
copy of the lab's auth wiring living in a UI, for one application. No service on this VM does that
today.

What guards the instance instead:

- **`INVITE_ONLY=true`** after the accounts exist. It is the whole access control, so set it.
- **Nothing here is exposed to the internet.** The domain resolves only on the LAN.
- **A local password**, kept in Vaultwarden like every other credential.

Two consequences worth knowing: an account here does not disappear when the Authentik user does,
and an Authentik outage does not lock anyone out of their dailies.

## Uptime Kuma monitors

Created by hand in Kuma on the infra VM, following the lab's `<Function> <Role>` naming:

| Name | Type | Target |
|---|---|---|
| Habits Web | HTTP(s) | `https://habitica.thefipster.de/api/v3/status` |

The API's status endpoint rather than the front page, because it answers `{"status":"up"}` only
once the server is actually serving — the static client would render from a process that has lost
its database.

**No Docker monitor**, and that is a deliberate non-row rather than a gap: Kuma reads the *infra*
VM's `docker.sock` and cannot see this machine's daemon at all. An HTTP check through Coolify's
proxy is the only signal available for anything on the apps VM.

**No Ping monitor either.** `Apps Host` in the lab's shared registry already pings this VM, below
every app on it.

**No separate MongoDB monitor.** The server's own health check gates on the replica set being up,
so `Habits Web` going red covers both.

## Optional: SMTP

Password resets, invitations and the daily reminder mails need an SMTP server. Add these to the
`habitica` service's `environment:` block and set the values in Coolify:

```yaml
      - EMAIL_SERVER_URL=${EMAIL_SERVER_URL}
      - EMAIL_SERVER_PORT=${EMAIL_SERVER_PORT:-587}
      - EMAIL_SERVER_AUTH_USER=${EMAIL_SERVER_AUTH_USER}
      - EMAIL_SERVER_AUTH_PASSWORD=${EMAIL_SERVER_AUTH_PASSWORD}
```

Without them Habitica sends nothing, which is the current state of this lab. Everything else works;
a forgotten password becomes an admin's problem rather than a self-service link.

## Backup

Tier 2 in the `home-lab` repo's backup roadmap: hand-entered, with no upstream to re-fetch it from
— the same shape as LubeLogger's service history. Losing it costs a habit streak, not a document.

| Path | Holds |
|---|---|
| `/data/habitica/db` | everything: users, habits, dailies, history, parties, challenges |
| `/data/habitica/dbconf` | MongoDB's own configuration state, including the replica set config |

**A copy of `/data/habitica/db` taken from a running server is torn**, the same rule the infra VM's
restic layer follows for Postgres. The supported form is a dump:

```bash
docker compose exec -T mongo mongodump --db=habitica --archive --gzip > habitica-$(date +%F).archive.gz
```

**Back the session secrets up with it.** `SESSION_SECRET_KEY` is the AES-256 key the server
encrypts stored values with; a restored database beside a regenerated key is the same failure mode
as Vaultwarden's `rsa_key.pem` on the infra VM — a server that starts, a database that is intact,
and data it cannot read. They live in Coolify's environment editor, which is not in this backup.

`/data` on this VM is excluded from whole-VM `vzdump` and is not covered by anything else yet — the
file-level layer runs on the infra VM, and this machine has not joined its restic repository.

## Upgrades

Bump the image tag and redeploy; the tag is the upstream Habitica version the fork was rebased
onto, and the fork publishes one per upstream release. Migrations run on start.

Two things to check before a jump: the fork's commit log, since a rebase can drop or change an
adaptation, and whether the release notes mention a MongoDB feature-compatibility bump — that is
the one change that would need the database touched rather than the image.
