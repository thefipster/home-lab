# Vaultwarden — password manager (infra VM)

**Runs on:** infra VM

**Prerequisite:** [traefik-setup.md](traefik-setup.md) complete — the wildcard
certificate issued and Traefik serving.

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) is a Bitwarden-
compatible server written in Rust, at **`https://vault.thefipster.de`**. Every
official Bitwarden client — browser extension, desktop app, mobile app, CLI —
talks to it unchanged; you point them at that URL instead of `bitwarden.com`.

It is the **first** stack Traefik actually serves, ahead of Authentik, and the
order is the point: from the next guide onward every step in this build
generates a secret worth keeping — bootstrap passwords, database passwords,
OIDC client secrets, API tokens — and this is where they go. It also has **no
SSO**, deliberately, so nothing about it depends on the identity provider that
comes next
([sso-applications.md](sso-applications.md#vaultwarden-deliberately-not-joined)).

## Steps

### 1. Check the DNS record

`vault.thefipster.de` must resolve to the **infra VM**. It is in the registry
([dns-records.md](dns-records.md)) and should already exist from the DNS step:

```bash
getent hosts vault.thefipster.de
```

Compare the answer against the infra VM's address on the router. If the record
is missing, the `*.thefipster.de` wildcard answers with the **apps VM** and you
get Coolify's 404 behind a perfectly valid certificate — which looks like a
Traefik problem and isn't.

### 2. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-vaultwarden.sh
```

It creates `/opt/vaultwarden/{postgres,data}`, seeds
`infra/vaultwarden/.env` from `.env.example` with a generated
`VAULTWARDEN_DB_PASSWORD`, ensures the `proxy` network exists, and symlinks the
stack into `/opt/stacks` for Dockge later.

### 3. Mint the admin token

The `/admin` page is how the first account gets created, and it is protected by
one value: an **Argon2id hash** of a password you choose. Generate it with the
image's own hasher — it prompts twice and prints the finished PHC string:

```bash
docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash
```

Put the printed value into `infra/vaultwarden/.env`, **single-quoted**:

```bash
nano ~/home-lab/infra/vaultwarden/.env
```

```
VAULTWARDEN_ADMIN_TOKEN='$argon2id$v=19$m=65540,t=3,p=4$…$…'
```

> **The single quotes are load-bearing.** Compose interpolates unquoted and
> double-quoted `.env` values, so `$argon2id`, `$v`, `$m` and the rest would be
> expanded as (undefined, therefore empty) variables. The container would start
> happily with a mangled hash and reject the password you just typed. Single
> quotes make Compose take the value literally.

> **Keep the password, not the hash.** The hash cannot get you back in — it is
> what the page checks against. Once the vault exists, the password belongs in
> it; until then, wherever you keep the netcup credentials.

### 4. Start the stack

```bash
cd ~/home-lab/infra/vaultwarden
```

```bash
docker compose up -d
```

```bash
docker compose logs -f vaultwarden
```

Expect the migrations to run against the fresh Postgres, then
`Rocket has launched from http://0.0.0.0:80`. `Ctrl-C` out of the log.

### 5. Create your account

Signups are closed from the first boot, so the only way in is an invite from
the admin page. Open **`https://vault.thefipster.de/admin`**, enter the
password from step 3, and invite your own email address under **Users →
Invite User**.

> **No mail is sent, and that is expected.** The lab has no SMTP server, so the
> invite creates the account in an *invited* state and there is no email to
> click. That is all it needs to do.

Now register that address directly — the signup form is reachable by URL even
though the link is hidden:

```
https://vault.thefipster.de/#/signup
```

Use the invited email, set a master password, and store it the way you would
any master password: this one is not recoverable, and nothing in this repo
holds a copy.

### 6. Verify

**The route, the certificate and the app, end to end:**

```bash
curl -Is https://vault.thefipster.de | head -1
```

Expect `HTTP/2 200`. curl verifies the certificate by default, so a 200 also
proves the wildcard covers this host.

**The app's own liveness endpoint:**

```bash
curl -s https://vault.thefipster.de/alive
```

Expect a JSON timestamp. Note what this does *not* tell you: `/alive` returns
the current time and touches no database, so it stays green while Postgres is
gone. Logging in is the only check that covers both, which is why the Kuma
registry pairs the HTTP monitor with a container monitor on the database
([uptime-kuma-monitors.md](uptime-kuma-monitors.md#vault--vaultwarden)).

**The container got the settings the compose file declares** — in particular
that the admin token survived `.env` quoting and signups are closed:

```bash
docker compose exec vaultwarden printenv DOMAIN SIGNUPS_ALLOWED INVITATIONS_ALLOWED ADMIN_TOKEN
```

`ADMIN_TOKEN` must still start with `$argon2id$v=19$`. Confirm the closure in a
browser too: `https://vault.thefipster.de/#/signup` with an **uninvited**
address fails with *Registration not allowed or user already exists*. The same
form succeeded for your own address in step 5 — the invite is what made the
difference, and neither of those two flags gates the `/admin` invite that
created it.

**Both containers are healthy** — the image ships its own healthcheck, which
curls `/alive`, so `healthy` here is a second read on the same signal:

```bash
docker compose ps
```

### Checklist

- [ ] `https://vault.thefipster.de` → `HTTP/2 200`, no TLS warning
- [ ] `/alive` returns a timestamp
- [ ] `/admin` accepts the password from step 3
- [ ] Your account logs in at `https://vault.thefipster.de`
- [ ] A registration attempt for an **uninvited** address is refused
- [ ] The netcup API credentials and the Vaultwarden admin password are now
      *in* the vault — this is the first guide where that is possible

## Next

**[authentik-setup.md](authentik-setup.md)** — SSO. It is the first stack that
generates secrets worth putting in the vault you just built, and the first one
this guide's service deliberately does **not** join.

## Troubleshooting

**`vaultwarden` exits at startup with a database error.** Check the URL it was
handed — the password is substituted into `DATABASE_URL`:

```bash
docker compose config | grep -A2 DATABASE_URL
```

If `VAULTWARDEN_DB_PASSWORD` was ever replaced by hand with a base64 value, its
`+ / =` characters are not URI-safe and libpq will parse the URL wrongly. Use
hex (`openssl rand -hex 32`), which is what the init script generates. Note
that Postgres keeps the password its data dir was **first** initialized with,
so changing it now means `ALTER USER` inside the running database, not an edit
to `.env`.

**`/admin` rejects the password you just generated.** The `.env` value is not
single-quoted, so Compose ate the `$`-segments of the hash. Confirm what the
container actually received:

```bash
docker compose exec vaultwarden printenv ADMIN_TOKEN
```

It must start with `$argon2id$v=19$`. If it doesn't, quote the line and:

```bash
docker compose up -d --force-recreate vaultwarden
```

**`/admin` says the page is disabled.** `ADMIN_TOKEN` is empty — but the
compose file guards it, so the stack would not have started at all. This means
someone set `DISABLE_ADMIN_TOKEN` or cleared the token through the admin page's
own settings form, which writes `/opt/vaultwarden/data/config.json`. See
[The admin page can overwrite this repo](#the-admin-page-can-overwrite-this-repo).

**A 404 behind a valid certificate.** Either the DNS record is missing (step 1
— the wildcard answered with the apps VM), or the container is not on the
`proxy` network:

```bash
docker network inspect proxy
```

Traefik and `vaultwarden-vaultwarden-1` should both be listed.

**Second factors stop working after a rename.** `DOMAIN` is the WebAuthn
relying-party ID. Changing the hostname invalidates every registered passkey
and hardware key — they must be re-enrolled. Nothing else in the lab is
sensitive to its own hostname this way.

**Clients say the vault is out of date, or edits don't appear on another
device.** Websockets ride the main HTTP port and Traefik forwards the upgrade
without configuration, so this is normally the client. Mobile **push** is a
separate thing and is deliberately off ([Design notes](#design-notes)); apps
sync on open and on a timer instead.

## Layout on the server

| What | Where |
|------|-------|
| Compose project (source of truth) | `infra/vaultwarden/` in this repo |
| Secrets | `infra/vaultwarden/.env` — gitignored, VM-only |
| Vault database | `/opt/vaultwarden/postgres` |
| Attachments, Sends, icon cache, `rsa_key.pem` | `/opt/vaultwarden/data` |
| Dockge entry | `/opt/stacks/vaultwarden` → symlink into this repo |

**Both `/opt` paths are tier 1 in [roadmap/backup.md](roadmap/backup.md), and
they must be captured together.** The database holds the vault; `rsa_key.pem`
beside it signs every access token the server issues. Restore one without the
other and every client is logged out of a database it can no longer prove
anything against — the same coupling Authentik has between its database and
`AUTHENTIK_SECRET_KEY`, one directory apart instead of one file.

## Design notes

**No SSO — the one service with OIDC support that doesn't use it.** Vaultwarden
gained OIDC in 1.35.0, so the repo's "anything with native OIDC uses it" rule
points straight at it. It is still kept on local login, for the reason the whole
build order was rearranged around: this is where the credentials for repairing
Authentik live. A vault that dies with the identity provider is the one outage
with no way out, and the break-glass would be SSH into a box whose key
passphrase is inside the thing that is down. The absence is recorded in
[sso-applications.md](sso-applications.md#vaultwarden-deliberately-not-joined),
and `infra/authentik/compose.yaml` carries no outpost router for this host.

That extends to `/admin`, deliberately. Gating only the admin page behind
forward-auth was considered — it is the one page a browser-only user reaches —
and rejected: it is also the page you would need in order to repair anything,
and adding it back would reintroduce exactly the dependency this decision
removes. The admin token is a strong independent secret, and upstream rate-
limits that page (roughly one attempt per 300 s after a burst of 3).

**Postgres, not SQLite.** Vaultwarden defaults to SQLite; the lab's standard is
Postgres, matching Authentik, Forgejo and Grafana. It also makes the backup
story uniform — `pg_dump` against a live database, rather than the WAL-aware
copy that Uptime Kuma's SQLite still needs
([roadmap/backup.md](roadmap/backup.md#why-dumps-not-raw-directory-copies-for-the-databases)).
Its own database, not a shared one, for the same reason every other stack has
its own: independent version pinning and independent restores.

**The version pin is a full patch, against repo policy.** `vaultwarden/server`
publishes `latest`, `alpine` and `X.Y.Z`, and no bare `1` or `1.37` tag exists
to pin to — the same situation as `grafana/alloy` and `grafana/tempo`. Read the
[release notes](https://github.com/dani-garcia/vaultwarden/releases) when
bumping; that is where breaking configuration changes are announced.

**No Prometheus target.** Vaultwarden exposes no metrics endpoint, so Alloy
scrapes nothing here. Coverage is Uptime Kuma's three monitors
([uptime-kuma-monitors.md](uptime-kuma-monitors.md#vault--vaultwarden)) plus the
container logs Alloy already tails from this VM's Docker socket.

**No mobile push, no SMTP.** Push relays through Bitwarden's own cloud service
and needs an installation id and key from `bitwarden.com/host`; nothing else in
this lab phones out, so it stays off and clients sync on open and on a timer.
No SMTP means no invite emails, no email-based second factor and no password
hints — for a single-person vault whose only invite happens in step 5, that
buys nothing worth a mail server.

### The admin page can overwrite this repo

This is the one way this stack breaks the repo's usual guarantee. Vaultwarden's
**Settings** tab under `/admin` writes changed values to
`/opt/vaultwarden/data/config.json`, and **that file wins over the environment**
— so a setting changed there silently overrides `compose.yaml` and keeps
overriding it across restarts.

Treat the compose file as the source of truth and change configuration there,
not in the admin UI. If something behaves in a way the compose file does not
explain, that JSON is the first place to look:

```bash
sudo cat /opt/vaultwarden/data/config.json
```

Deleting a key from it restores the compose value; deleting the file restores
all of them.

## Next

**[authentik-setup.md](authentik-setup.md)** — SSO, and the first source of
secrets for the vault you just built. The full sequence is in the
[README build order](../README.md#build-order).
