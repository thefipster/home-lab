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
registry: [sso-applications.md](../reference/sso-applications.md#forgejo-oidc).

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
3. **Check "This repository will be a mirror"** and set an interval — `8h` is
   what the lab uses.
4. Create. Forgejo clones it and re-pulls on that interval.

> **A long interval costs nothing here, and that is a consequence of the build
> being manual.** A release run POSTs the mirror sync itself and waits for the
> tags it was given ([step 8](#8-cut-a-release-and-verify-the-image)), so it
> never depends on the schedule having caught up. A short interval would only
> pay off if something built each tag as it arrived, and nothing does — a pull
> mirror updates Git data without firing `push` events.

### 7. Add the pipeline to your repo

The workflows and Dockerfile live in the repo being built — **this repo ships no
copies of them**, deliberately: a second copy of a live workflow drifts from the
one actually running, and there is nothing here that could keep the two honest.
What this guide owns is the runner, the registry and the tokens the workflows
authenticate with.

The Forgejo copy of your app repo is a read-only mirror, so the workflow file is
committed to **GitHub** and mirrors in, at `.forgejo/workflows/`:

| Workflow | Builds | Publishes |
|---|---|---|
| the **release** builder | the `<component>-v<semver>` git tags you name | images tagged `1.2.3`, `1.2`, `1` and `latest`; firmware and archives to the generic registry |

It is `workflow_dispatch`-only — see [CI is manual-only](#how-it-works) — and it
carries one job per toolchain, because `container:` is a per-job setting and
.NET, PlatformIO and Node cannot share one.

Then create **two access tokens** under the Forgejo account at **Settings →
Applications → Manage Access Tokens → Generate Token**, and add each to the app
repo's **Settings → Actions → Secrets**:

| Secret | Scope | Used by |
|---|---|---|
| `REGISTRY_TOKEN` | `write:package` | every build job, for the container **and** generic registries |
| `REPOSITORY_TOKEN` | `write:repository` | the first job only, to trigger the mirror sync |

One scope covers both registries, so the non-Docker jobs need no token of their
own. Keep the two separate: `REGISTRY_TOKEN` is handed to third-party actions
(`docker/login-action`), so it stays minimal.

> **A secret's name may not begin with `FORGEJO`.** That prefix is reserved for
> the variables Forgejo injects into a run itself, and the Secrets form rejects
> the name outright — which is why the mirror-sync token is `REPOSITORY_TOKEN`
> and not the `FORGEJO_API_TOKEN` its job would suggest. Same rule for any third
> secret added later.

Push, then wait for the mirror interval (or **Settings → Mirror Settings →
Synchronize Now** in Forgejo).

### 8. Cut a release and verify the image

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

- `<repo>/web` carries four tags — `latest`, `1.2.3`, `1.2` and `1`. The
  `blazor-` prefix builds an image named `web`; that is the name the deployment
  pulls, and the prefix is not the image name.
- `verdure-atmos` has two versions — `0.4.1` and `latest`, each holding the
  `.bin` files

Then pull it from any LAN machine, with **zero** Docker daemon configuration —
no `insecure-registries`, no CA to distribute, because Traefik serves the
registry under the real wildcard certificate:

```bash
docker login git.thefipster.de
```

```bash
docker pull git.thefipster.de/<owner>/<repo>/web:1.2
```

> The rolling tags assume you are releasing the newest version. Re-dispatching
> an **older** tag republishes it and moves `latest`, `1.2` and `1` backwards —
> there is no guard against it, because a hand-cut release is always the newest
> one.

> **A prerelease moves nothing.** `blazor-v1.2.3-rc1` publishes `1.2.3-rc1` and
> leaves `latest`, `1.2` and `1` where they were — handing a release candidate
> to everything tracking a rolling tag is exactly what the `-rc` suffix exists
> to prevent.

### 9. Set the registry cleanup rules

**Nothing in the registry expires on its own.** Every version stays until a rule
removes it, and the blobs sit in the same bind mount the nightly backup
snapshots — so an unbounded registry is an unbounded restic repository, not just
a full disk. Two rules keep it bounded, one per registry in use. They are
**owner-scoped**: set once on the account, covering every repository under it.

Go to **Settings → Packages → Cleanup Rules → Add cleanup rule** and add both.
The exact field values, and why each one is what it is, are in the registry:
[package-cleanup-rules.md](../reference/package-cleanup-rules.md).

Before saving either rule, use its **preview**. It lists exactly the versions
that rule would delete right now — the one way to find out whether a pattern
reaches something still being pulled *before* the next midnight rather than
after it.

**Verify:** both rules appear in the list marked enabled, and each preview shows
nothing you did not intend to lose. On a lab whose registry holds less than ten
versions per package, both previews are empty, and that is the expected result:
these are a policy set ahead of the growth, not a cleanup of it.

### Checklist

- [ ] `https://git.thefipster.de` serves the UI on the wildcard certificate
- [ ] The runner shows **Idle / online** with the `docker` label
- [ ] **Sign in with authentik** lands in the existing admin account
- [ ] Local password login still works (break-glass)
- [ ] A release dispatch publishes an image tagged `latest`, `X.Y.Z`, `X.Y` and `X`
- [ ] The release run's mirror sync succeeds (a `write:repository` token, not
      the registry one)
- [ ] `docker login git.thefipster.de` succeeds from a machine with **zero**
      Docker daemon configuration
- [ ] Both cleanup rules exist and are enabled, and neither preview lists a
      version you meant to keep

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
buildx. A plain `node` image fails; the app repo's Docker-building jobs use
`ghcr.io/catthehacker/ubuntu:act-24.04`, which has both. The first run pulls it
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
`REPOSITORY_TOKEN` lacks `write:repository`.

**A generic package upload returns 409.** A PUT over an existing filename
conflicts. The publish steps delete before uploading, so a 409 means the
*delete* failed — almost always a `REGISTRY_TOKEN` without `write:package`.

**A version you expected is missing from the Packages tab.** Check the cleanup
rules before the workflow: they run at midnight and delete without asking, and
a pattern reaches every package of its type. Each rule's **preview** shows what
it would remove right now — [package-cleanup-rules.md](../reference/package-cleanup-rules.md)
records what the two rules are meant to protect.

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

The nightly file-level layer covers this stack once
[backup-setup.md](backup-setup.md) is built — `infra/forgejo/backup.sh` dumps
the database and snapshots `/opt/forgejo` every night, and
`infra/forgejo/restore.sh` is the way back. What follows is the **ad-hoc**
procedure, for a cold copy right before a risky change.

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
The release builder is therefore `workflow_dispatch`-only. It takes the release
tags as its input, POSTs `mirror-sync` itself, and waits for exactly those refs
before building. A dispatched run can therefore check out a tag that did not
exist when it started: the dispatch pins only *which workflow file* runs, not
what it fetches — which is also why the mirror's own interval can be long
without slowing a release down.

**A second workflow used to build the mirrored HEAD on demand and tag by commit
SHA; it is gone.** Every image in the registry now comes from a named release
tag, which is what lets the cleanup rules in
[package-cleanup-rules.md](../reference/package-cleanup-rules.md) be written
against `X.Y.Z` and the rolling tags alone. Nothing here produces a
SHA-tagged image, so nothing accumulates one per commit.

Two scheduled jobs were designed for this and both were **rejected**. A
*reconciler* — cron, list the tags, ask the registry what is already built,
build the difference — existed entirely to reconcile drift between git and the
registry, and tagging is already a deliberate manual act: dispatching the build
in the same sitting means drift never accumulates
([design spec](../../dev/specs/2026-08-05-forgejo-release-workflow-design.md)).
A *nightly rebuild* went the same way; its last remaining purpose was
re-scanning published images for CVEs disclosed after the build, and that gap is
stated without an automated answer in
[roadmap/ci-supply-chain.md](../../dev/roadmap/done/ci-supply-chain.md). The lab therefore runs
**no CI schedule at all**, which
[timetable.md](../reference/timetable.md#deliberate-absences) records as a decision rather
than an omission.

**The workflow files are not in this repository.** They live in the app repo,
where they run. This repo used to carry annotated example copies under
`infra/forgejo/`; they were removed once the real ones existed, because two
copies of a live workflow drift and nothing here can tell you which one is
current. What stays on this side is the runner (`infra/forgejo/config.yml`), the
registry, and the tokens above.

**What that build does leave on this side.** Supply-chain work landed in those
workflows ([roadmap/ci-supply-chain.md](../../dev/roadmap/done/ci-supply-chain.md)),
and its effects are visible from this machine rather than from the YAML. A
**Trivy scan runs after the build and before the push**, failing the run on a
`CRITICAL` or `HIGH` finding **that has a fix available** — unfixable ones are
reported, not blocking, because a release that cannot be unblocked only teaches
people to bypass the gate. A run that goes red having built nothing new is the
expected shape of that, not a broken runner.

The scan also writes an **SBOM**, and where it lands matters for the disk on
this machine: it is a **run artifact** with a 30-day retention, not an
attestation in the registry. The build loads the image into the local daemon so
it can be scanned before anything is pushed, and that path cannot carry
attestations — so a pushed tag costs exactly its own layers, and the SBOM
expires on its own without a cleanup rule ever seeing it. What does need
bounding is the tags themselves: [step 9](#9-set-the-registry-cleanup-rules).
None of this needs a token, a runner label or a change to this stack.

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
far. The full sequence is in the [README build order](../../README.md#build-order).
