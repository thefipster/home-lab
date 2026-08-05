# Forgejo — CI and container registry (infra VM)

**Runs on:** infra VM

**Prerequisite:** [dockge-setup.md](dockge-setup.md) complete — which means
Traefik, Authentik and Dockge are all up. This is the first stack you can bring
up from the Dockge UI instead of the CLI, though the commands below use the CLI
so they work either way.

[Forgejo](https://forgejo.org) is a self-hosted Git forge with a built-in
container registry and an Actions runner, at **`https://git.thefipster.de`**.
It runs the chain **GitHub → Forgejo (pull mirror) → build → push to the
Forgejo registry**. Because Traefik serves it under the real wildcard
certificate from its very first run, the registry is a plain trusted HTTPS
registry — any Docker daemon on the LAN can use it with **zero** configuration:
no `insecure-registries`, no CA to distribute.

## Steps

### 1. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-forgejo.sh
```

It creates `/opt/forgejo/{postgres,forgejo,runner}` and `chown`s the Forgejo
and runner directories to `1000:1000` (the UID the image runs as), seeds
`infra/forgejo/.env` and generates `FORGEJO_DB_PASSWORD`, records the host
`docker` group's numeric GID as `DOCKER_GID`, and symlinks the stack into
`/opt/stacks` so Dockge lists it.

> **Dockge does not replace this script.** Dockge runs the compose *lifecycle*
> for stacks already in `/opt/stacks`; it cannot create and `chown` data
> directories, compute `DOCKER_GID`, or register a runner. Every stack still
> starts with its init script — Dockge takes over from there.

### 2. Start Forgejo

Everything except the runner — it waits for a registration file that does not
exist yet.

```bash
cd ~/home-lab/infra/forgejo
```

```bash
docker compose up -d db forgejo
```

### 3. Complete the first-run screen

Open **`https://git.thefipster.de`**. Traefik picks the container up over the
`proxy` network and serves it with the wildcard certificate — there is no
plain-HTTP phase and no port to open.

- The database settings are already injected through the environment; leave
  them.
- Create the **admin account**. Use the **same email address** as the Authentik
  user from [authentik-setup.md, step 4](authentik-setup.md#4-add-a-user-and-a-group)
  — SSO account linking matches on email, and a mismatch creates a second,
  separate user instead of linking to this one.
- Accept the defaults for everything else.

Then confirm Actions is enabled: **Site Administration → Actions → Runners**
should load (empty for now). If the Actions menu is missing, the
`FORGEJO__actions__ENABLED` environment variable didn't take — check the
container logs.

### 4. Register the runner

The runner needs a token that only the UI can generate, which is why this one
step cannot be scripted.

In Forgejo: **Site Administration → Actions → Runners → Create new runner**.
Copy the **registration token**, then:

```bash
docker compose run --rm \
  -v "/opt/forgejo/runner:/data" \
  --entrypoint forgejo-runner \
  runner register --no-interactive \
    --instance https://git.thefipster.de \
    --token <PASTE_TOKEN_HERE> \
    --name lab-runner \
    --labels docker
```

That writes `/opt/forgejo/runner/.runner`. The runner's `config.yml` is
bind-mounted from the repo, so there is nothing to copy. Start the daemon:

```bash
docker compose up -d runner
```

**Verify:** back in **Admin → Actions → Runners**, the runner shows as
**Idle / online** with the `docker` label. That green status is the milestone —
Actions can now execute.

### 5. Join SSO (OIDC via Authentik)

Forgejo authenticates non-browser traffic — `git push`, `docker login`, CI — so
it joins SSO by **OIDC**, never forward-auth. All field values are in the
registry: [sso-applications.md](sso-applications.md#forgejo-oidc).

1. **Create the provider in Authentik.** **Admin → Applications → Providers →
   Create → OAuth2/OpenID Provider** — name, flow, client type, redirect URI
   and signing key exactly as the registry specifies. Save, then note the
   generated **Client ID** and **Client Secret**.
2. **Create the application.** **Admin → Applications → Applications →
   Create** — name and slug from the registry, provider `forgejo`. Bind it to
   `lab-users` ([authentik-setup.md, step 5](authentik-setup.md#5-control-who-reaches-what)).
3. **Add the source in Forgejo.** **Site Administration → Identity & Access →
   Authentication Sources → Add Authentication Source** — type **OAuth2**,
   provider **OpenID Connect**. The authentication name **must** be exactly
   `authentik` (Forgejo builds the callback path from it, and it has to match
   the redirect URI). Fill in the discovery URL and the Client ID / Secret from
   step 1. Save.

Auto-registration and account linking need no clicks — they are instance
settings already shipped in `infra/forgejo/compose.yaml`
(`ENABLE_AUTO_REGISTRATION=true`, `ACCOUNT_LINKING=auto`), which is what maps
your Authentik identity onto the admin account from step 3 by email.

> **Do not disable local login.** Password sign-in is the break-glass path when
> Authentik is down, and it is the only way back into a forge that holds your
> code.

**Verify:** log out, open `https://git.thefipster.de`, click **Sign in with
authentik**, authenticate → you land in the **existing** admin account (not a
new one). Local username/password login still works.

### 6. Mirror a repo from GitHub

1. **+ (top right) → New Migration → GitHub**.
2. Enter the repo URL. For a private repo, supply a GitHub personal access
   token (read-only on the repo is enough).
3. **Check "This repository will be a mirror"** and set an interval (e.g.
   10m).
4. Create. Forgejo clones it and re-pulls on that interval.

> A pull mirror updates Git data but does **not** fire `push` events. Builds
> are therefore manual — see [step 8](#8-run-a-build-and-verify-the-image).

### 7. Add the pipeline to your repo

The workflow and Dockerfile must live in the repo being built, and the Forgejo
copy is a read-only mirror, so commit them to **GitHub** and let them mirror
in. In your app repo on GitHub, add:

- a `Dockerfile` for the app, and
- both workflow templates under `.forgejo/workflows/`, from
  [`infra/forgejo/build-and-push.yml`](../infra/forgejo/build-and-push.yml) and
  [`infra/forgejo/release.yml`](../infra/forgejo/release.yml) here.

The two do different jobs:

| Template | Builds | Tags images |
|---|---|---|
| `build-and-push.yml` | whatever the mirror last synced | by commit SHA — a **dev** build |
| `release.yml` | a `<component>-v<semver>` git tag you name | `latest`, `1.2.3`, `1.2`, `1` — a **release** |

Both carry three jobs, one per toolchain, because `container:` is a per-job
setting and .NET, PlatformIO and Node cannot share one. Both include a
**matrix** of PlatformIO projects: in the dev builder that is the `project:`
list, in the release workflow the `COMPONENTS` table in its `plan` job. Adding
a board is one entry in each. Every repo path and PlatformIO environment in
both files is a marked placeholder — those are the only edits you should need.

Then create **two access tokens** under the Forgejo account at **Settings →
Applications → Manage Access Tokens → Generate Token**, and add each to the app
repo's **Settings → Actions → Secrets**:

| Secret | Scope | Used by |
|---|---|---|
| `REGISTRY_TOKEN` | `write:package` | both workflows, for the container **and** generic registries |
| `FORGEJO_API_TOKEN` | `write:repository` | `release.yml` only, to trigger the mirror sync |

One scope covers both registries, so the non-Docker jobs need no token of their
own. Keep the two separate: `REGISTRY_TOKEN` is handed to third-party actions
(`docker/login-action`), so it stays minimal.

Push, then wait for the mirror interval (or **Settings → Mirror Settings →
Synchronize Now** in Forgejo).

### 8. Run a dev build and verify the image

In the repo's **Actions** tab → **Build and Push (manual)** → **Run workflow**.
Each job has a tick-box, all on by default; every run checks out the mirrored
HEAD, logs into the registry, builds and pushes. The runner is `capacity: 1`, so
the jobs you leave ticked run one after another.

Then check the image landed: the owner's **Packages** tab should list a
container package — named `<repo>/blazor` by the shipped template — with
`latest` and a SHA tag. Or pull it from any LAN machine with no daemon
configuration at all. The path follows the `tags:` you set in step 7; as shipped
that is:

```bash
docker login git.thefipster.de
```

```bash
docker pull git.thefipster.de/<owner>/<repo>/blazor:latest
```

### 9. Cut a release

A release is a git **tag**, and the tag prefix picks the build recipe. Tag on
**GitHub** — the Forgejo copy is a read-only mirror — using
`<component>-v<semver>`, where the component is one of `blazor`, `showcase`,
`atmos`, `terra` or `flux`. Write the release notes there too.

Then, in Forgejo: **Actions → Release → Run workflow**, and type the tags you
just pushed, space-separated:

```text
blazor-v1.2.3 atmos-v0.4.1
```

There is **no need to synchronize the mirror first**, and no need to wait for
the mirror interval. The run's first job POSTs the sync itself and then polls
until those exact tags arrive, so a dispatch seconds after tagging still builds
the right commits. A tag that never shows up fails the run by name after ten
minutes rather than silently building something older.

**Verify** in the owner's **Packages** tab:

- `<repo>/blazor` carries four tags — `latest`, `1.2.3`, `1.2` and `1`
- `verdure-atmos` has two versions — `0.4.1` and `latest`, each holding the
  `.bin` files

```bash
docker pull git.thefipster.de/<owner>/<repo>/blazor:1.2
```

> The rolling tags assume you are releasing the newest version. Re-dispatching
> an **older** tag republishes it and moves `latest`, `1.2` and `1` backwards —
> there is no guard against it, because a hand-cut release is always the newest
> one.

### Checklist

- [ ] `https://git.thefipster.de` serves the UI on the wildcard certificate
- [ ] The runner shows **Idle / online** with the `docker` label
- [ ] **Sign in with authentik** lands in the existing admin account
- [ ] Local password login still works (break-glass)
- [ ] A manual workflow run completes and pushes an image
- [ ] A release dispatch publishes an image tagged `latest`, `X.Y.Z`, `X.Y` and `X`
- [ ] The release run's mirror sync succeeds (a `write:repository` token, not
      the registry one)
- [ ] `docker login git.thefipster.de` succeeds from a machine with **zero**
      Docker daemon configuration

## Next

**[grafana-setup.md](grafana-setup.md)** — the monitoring stack: metrics, logs,
traces, dashboards and alerts for everything built so far.

## Troubleshooting

**The runner logs `Cannot ping the Forgejo instance server` with `x509:
certificate has expired or is not yet valid`.** The VM clock is stale, not the
certificate — the usual cause is a Proxmox snapshot rollback, which resumes the
guest with its clock frozen at snapshot time, *before* the wildcard was issued.
The runner is normally the first thing to notice, being the first non-browser
TLS client. Check and fix:

```bash
timedatectl
```

```bash
sudo chronyc makestep
```

Background and the permanent fix are in
[proxmox-setup.md, Part 7](proxmox-setup.md#part-7--snapshot-before-you-build).

**The runner restart-loops with "Cannot connect to the Docker daemon at
unix:///var/run/docker.sock".** Either `DOCKER_GID` is missing from `.env`
(re-run `scripts/init-forgejo.sh`), or the socket volume didn't mount:

```bash
docker compose run --rm --entrypoint sh runner -c 'ls -l /var/run/docker.sock'
```

It should show a socket, not "No such file". If it's missing, your running
compose is stale:

```bash
docker compose up -d --remove-orphans
```

**`docker: not found` inside a CI job.** The job image must contain **both**
Node (for the checkout/login/build-push actions) **and** the `docker` CLI with
buildx. A plain `node` image fails; the shipped workflow uses
`ghcr.io/catthehacker/ubuntu:act-22.04`, which has both. The first run pulls it
(~1.5 GB) onto the host daemon and caches it.

**A workflow refuses to start and reports a schema error.** Forgejo and the
runner both validate workflow YAML against a schema before a job runs, so a
typo that used to fail *inside* the run (`ruins-on:` for `runs-on:`, a
misspelled context like `${{ badcontext.FORGEJO_REPOSITORY }}`) now stops it
from starting at all. The error shows in the Actions tab and on the file's page
in the repo. Check a repo's workflows without dispatching anything:

```bash
docker compose run --rm --entrypoint forgejo-runner runner \
  validate --repository https://git.thefipster.de/<owner>/<repo>
```

It clones the repo and prints one line per workflow. The clone is anonymous, so
for a private mirror put a token in the URL
(`https://<user>:<token>@git.thefipster.de/...`). Fix the file in **GitHub** —
the Forgejo copy is a read-only mirror — and re-sync.

**A release run times out waiting for a tag.** The mirror sync is queued, not
synchronous, and the run polls for ten minutes before giving up. Confirm the tag
exists on GitHub and is spelled exactly as dispatched, then check **Settings →
Mirror Settings** in Forgejo. A 403 from the sync step itself means
`FORGEJO_API_TOKEN` lacks `write:repository`.

**A generic package upload returns 409.** A PUT over an existing filename
conflicts. Both workflows delete before uploading, so a 409 means the *delete*
failed — almost always a `REGISTRY_TOKEN` without `write:package`.

**SSO signs you into a *new* account instead of the admin.** The emails don't
match. Account linking matches by email only — fix the address on either side
and delete the stray user.

**Postgres refuses the password after a redeploy.** Postgres keeps the password
its data directory was **first** initialized with. On an existing deployment,
set `FORGEJO_DB_PASSWORD` in `.env` to the current value by hand, or rotate it
with `ALTER USER`.

## Layout on the server

| What | Where | Why |
|------|-------|-----|
| Compose project (this repo) | `infra/forgejo/` | edit and redeploy as your normal user; no root needed |
| Runner config | `infra/forgejo/config.yml` | bind-mounted read-only into the runner — the repo stays the source of truth |
| Persistent data | `/opt/forgejo/{postgres,forgejo,runner}` | bind mounts, not named volumes: easy to find, `chown` and back up |

Forgejo and the runner run as UID/GID `1000` and must own their data
directories. If your login user isn't `1000:1000`, keep the compose
`USER_UID`/`USER_GID` and that ownership in agreement.

### Teardown and backup

`docker compose down` — even with `-v` — leaves everything, because all state
is in bind mounts. For a consistent backup:

```bash
docker compose down
```

```bash
sudo tar czf forgejo-backup-$(date +%F).tar.gz -C /opt forgejo
```

```bash
docker compose up -d
```

For hot backups prefer `pg_dump` over copying the Postgres directory live. For
a completely clean slate, `sudo rm -rf /opt/forgejo/{postgres,forgejo,runner}`.

## How it works

**The runner uses the host Docker daemon, not Docker-in-Docker.** Job
containers are started on the host daemon through a mounted
`/var/run/docker.sock` — simpler than DinD and it reuses the host's layer
cache. The runner image itself is non-root (uid 1000), so it joins the host
`docker` group by numeric GID; that is what `DOCKER_GID` in `.env` is for.

The tradeoff: **a job holding that socket has root-equivalent control of the
VM.** That is acceptable here only because CI builds *your own* mirrored
repositories. If you ever need to build untrusted or fork code, move to an
isolated runner (DinD or ephemeral VMs) — do not extend this pattern.

**Why the runner registers against `https://git.thefipster.de` and not
`forgejo:3000`.** The registered address is baked into the clone and registry
URLs handed to CI jobs, and the `docker push` is executed by the *host* daemon,
which resolves names through the host's DNS rather than the Compose network —
the Compose name `forgejo` would not resolve there. The public hostname works
everywhere (runner, daemon, job containers), and because the certificate is
publicly trusted, nothing needs special configuration. It must match `ROOT_URL`
in the compose file, and it does.

**CI is manual-only, on purpose.** GitHub is primary and Forgejo pull-mirrors
it. Mirrors update Git data without firing `push` events, and the lab is
LAN-only so GitHub cannot call in either — no event-driven design is possible.
Both workflows are therefore `workflow_dispatch`-only, and they split the work:

- **`build-and-push.yml`** rebuilds the mirrored HEAD and tags by commit SHA.
  There is no change detection — a run with no new commits simply rebuilds the
  same code, so trigger it when something changed.
- **`release.yml`** takes the release tags as its input, POSTs `mirror-sync`
  itself, and waits for exactly those refs before building. A dispatched run can
  therefore check out a tag that did not exist when it started: the dispatch
  pins only *which workflow file* runs, not what it fetches.

A scheduled reconciler — cron, list the tags, ask the registry what is already
built, build the difference — was designed and **rejected**. Every part of it
existed to reconcile drift between git and the registry, and tagging is already
a deliberate manual act: dispatching the build in the same sitting means drift
never accumulates. The reasoning is in
[the design spec](superpowers/specs/2026-08-05-forgejo-release-workflow-design.md).

**`/metrics` is open on the LAN.** `FORGEJO__metrics__ENABLED` serves metrics
on port 3000 — the same port Traefik publishes — so
`https://git.thefipster.de/metrics` is readable unauthenticated by anyone on
the LAN. Deliberate: aggregate counters only (repository, user and issue
totals), no code and no credentials, on a LAN-only lab. To close it, set
`FORGEJO__metrics__TOKEN` (plus a `bearer_token` on Alloy's scrape) or add a
higher-priority Traefik router for `PathPrefix(/metrics)` with an `ipAllowList`.
Alloy scrapes the container directly, so either change is invisible to
collection.

## Next

**[grafana-setup.md](grafana-setup.md)** — monitoring for everything built so
far. The full sequence is in the [README build order](../README.md#build-order).
