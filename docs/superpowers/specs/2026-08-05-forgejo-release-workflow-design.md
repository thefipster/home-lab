# Forgejo release workflow — tag-driven builds for verdure

**Date:** 2026-08-05
**Status:** design, approved
**Supersedes:** `docs/roadmap/ci-triggers.md` (the cron reconciler it proposes is
rejected — see [Rejected: the scheduled reconciler](#rejected-the-scheduled-reconciler))

## Problem

The verdure repo is one repository holding three toolchains and five
independently released components:

| Component | Toolchain | Ships as |
|---|---|---|
| `blazor` | .NET / Blazor Server | container image |
| `showcase` | Astro | container image **and** static archive |
| `atmos` `terra` `flux` | PlatformIO | firmware `.bin` (+ filesystem image) |

Releases are cut by hand as git tags of the form `<component>-v<semver>`, e.g.
`blazor-v1.2.3`. The existing `infra/forgejo/build-and-push.yml` builds from
whatever the mirror last synced and tags images by commit SHA, which says
nothing about which release an image is. Nothing in the lab turns a release tag
into a versioned artifact.

Two constraints shape every possible answer:

- **Mirror syncs fire no Actions events.** Forgejo pull-mirrors emit neither
  push nor tag events, so `on: push` and `on: create` never fire.
- **GitHub cannot call in.** The lab is LAN-only behind split-horizon DNS;
  `git.thefipster.de` does not resolve publicly, so no GitHub-side workflow or
  webhook can nudge Forgejo.

## Solution

**One manually dispatched workflow that refreshes the mirror itself, then builds
exactly the tags it was given.**

The key realisation: a `workflow_dispatch` run may check out a ref that did not
exist when the run started. The dispatch pins only *which workflow file* runs
(from `main`); everything the job fetches afterwards is up to the job. So the
run can sync the mirror as its first step and build tags that arrive during its
own execution.

Because releases are already a deliberate manual act, triggering the build is
one more click in a decision the operator is already making. That removes the
lag of any polling design and — more importantly — removes the need to
reconcile drift at all.

### The release procedure

1. Tag and write release notes on GitHub.
2. Dispatch **Release** in Forgejo's Actions tab, typing the tags:
   `blazor-v1.2.3 atmos-v0.4.1`.
3. Everything else is automatic: mirror sync, build, publish. Coolify can pull
   the new image immediately.

## Architecture

New template file **`infra/forgejo/release.yml`**, which lives in the *app*
repo at `.forgejo/workflows/release.yml` — the same arrangement as the existing
`build-and-push.yml`, which is a real file that lives elsewhere.

```
workflow_dispatch (tags: "blazor-v1.2.3 atmos-v0.4.1")
        |
    [ plan ]  validate -> mirror-sync -> wait for tags -> emit matrices
        |
        +-- [ blazor   ]  matrix over blazor tags
        +-- [ showcase ]  matrix over showcase tags
        +-- [ firmware ]  matrix over atmos/terra/flux tags
```

### Trigger and input

`workflow_dispatch` only. One required string input:

```yaml
inputs:
  tags:
    description: "Release tags, space-separated (e.g. blazor-v1.2.3 atmos-v0.4.1)"
    required: true
    type: string
```

Typing the tags rather than ticking per-component boxes buys one concrete
thing: the workflow knows *exactly* what it is waiting for, so the mirror wait
polls for those refs instead of sleeping on a guess. It also makes the run
history a release log. The cost is retyping a version that was just tagged; a
typo fails the run in `plan`, before any toolchain container starts.

### The `plan` job

Runs in the runner's default job image. Four steps:

1. **Validate.** Every token in `tags` must match
   `^(atmos|terra|flux|blazor|showcase)-v[0-9]+\.[0-9]+\.[0-9]+$`. An unknown
   prefix or malformed semver fails the run here.
2. **Sync.** `POST /api/v1/repos/{owner}/{repo}/mirror-sync`, authenticated with
   `FORGEJO_API_TOKEN`. The endpoint is asynchronous — it queues the sync and
   returns.
3. **Wait.** Poll `git ls-remote --tags origin` until every named tag is
   present. On timeout, fail naming the tag that never arrived. Because the
   workflow knows the exact refs it needs, this is a deterministic wait rather
   than a race.
4. **Emit.** Three JSON matrices as job outputs — `blazor`, `showcase`,
   `firmware` — each accompanied by an `any` boolean so a toolchain with no
   tags in this release skips its job rather than running an empty matrix.

**The component table is a JSON literal inside `plan`** and is the single place
per-component facts live: source directory for all five, plus `pio_env` and
filesystem type for the PlatformIO three. Adding a fourth board is one row
there and no other change to the file. It ships with clearly marked
placeholders (see [Placeholders](#placeholders)).

### The build jobs

Each is `needs: plan`, gated on that toolchain's `any` output, and runs a
matrix with `fail-fast: false` — a board that will not compile must not cancel
its siblings. Each checks out `ref: <tag>`.

**`blazor`** — `ghcr.io/catthehacker/ubuntu:act-22.04` (Node actions *and* the
docker CLI, as today) plus buildx. Pushes
`git.thefipster.de/<owner>/<repo>/blazor` on four tags.

**`showcase`** — `code.forgejo.org/oci/node:24-bookworm`. Runs `npm ci && npm
run build` **once**, then publishes both outputs from that single `dist/`:

- `dist.tar.gz` to the generic registry under `verdure-showcase/1.2.3/` and
  `verdure-showcase/latest/` — the classic "upload and decompress" web hosting
  path;
- an nginx container image on the same four tags as blazor, for local
  deployment via Coolify.

Its Dockerfile is a `COPY dist/ /usr/share/nginx/html` two-liner consuming the
job's build output, **not** a multi-stage build. A multi-stage Dockerfile would
compile the site a second time, and the runner is `capacity: 1`. The trade-off
is that the Dockerfile is not standalone-buildable — it requires a populated
`dist/` in its context.

**`firmware`** — `python:3.12-bookworm` + `pip install platformio`, upstream's
own documented CI recipe (PlatformIO publishes no official image; the Docker
Hub ones are community builds). Toolchain cached on `~/.platformio` and
`~/.cache/pip`, keyed on component + `platformio.ini` hash. Publishes to
`verdure-<component>/1.2.3/<component>-firmware.bin` plus the filesystem image
where configured, and the same files again under `verdure-<component>/latest/`.

### Version tagging

For a tag `<component>-v1.2.3`, container images get exactly four tags:

- `latest`
- `1.2.3`
- `1.2`
- `1`

No SHA tags. Traceability travels as image labels instead —
`org.opencontainers.image.version` (the semver) and
`org.opencontainers.image.revision` (the commit) — which keeps the tag list
readable and the registry small.

**No highest-version guard is needed.** The rolling tags assume the version
being built is the newest, and a manually dispatched release always is: you
build the tag you just cut. Deliberately re-releasing an old patch would move
`latest` backwards — don't do that. (An earlier design carried a per-scope
guard; it existed only to make *automatic backfill* safe, and there is no
backfill any more.)

Generic packages have no rolling-tag concept, so "latest" is a second version
name whose files are re-uploaded each release. Uploads are **delete-then-PUT**
because a PUT over an existing filename returns 409 — which also makes
re-dispatching the same tag idempotent rather than an error.

The `verdure-` prefix on generic package names stays: generic packages are
**owner-scoped**, not repo-scoped, so an unprefixed `showcase` would collide
with any other repo of the same owner.

### Secrets

| Secret | Scope | Used for |
|---|---|---|
| `REGISTRY_TOKEN` | `write:package` | container + generic registry pushes (unchanged) |
| `FORGEJO_API_TOKEN` | `write:repository` | `mirror-sync` only (new) |

Kept as two tokens so the one handed to third-party actions
(`docker/login-action`) stays minimal. `FORGEJO_API_TOKEN` needs no package
scope — nothing reads the registry.

### Placeholders

The file ships with the same clearly marked placeholders as the existing
template, being the only things that need changing to run against the real
repo:

- `blazor` — source directory and Dockerfile path
- `showcase` — Astro project directory and its nginx Dockerfile path
- `atmos` / `terra` / `flux` — directory, `[env:...]` name, and filesystem type
  (`littlefs`, `spiffs`, or empty to skip the `buildfs` step) per component

## Other repo changes

- **`infra/forgejo/build-and-push.yml`** keeps its role as the SHA-tagged dev
  builder with browsable run artifacts, but its component names are stale:
  `web` → `blazor`, `site` → `showcase`, and its firmware matrix lists
  `atmos`/`sensor` rather than `atmos`/`terra`/`flux`. Corrected for internal
  consistency.

  **Accepted cost:** each build recipe now exists in two files and they must
  move together — the same "written down twice" discipline the repo already
  applies to the runner's default Node image.

- **`docs/forgejo-setup.md`** — a new part covering the release workflow, the
  `FORGEJO_API_TOKEN` secret, and the cut-a-release procedure.

- **`docs/roadmap/ci-triggers.md`** — shrinks to what remains genuinely ahead:
  nightly rebuilds, which `ci-supply-chain.md` depends on for its CVE re-scan
  gap. Its reconciler, ledger and backfill sections are rejected, not pending.

- **`CLAUDE.md`** — "CI is manual-only" stays accurate, but the CI bullets need
  the two-workflow split, the five components, the four image tags, and
  showcase's second output.

## Out of scope

Staying in roadmap, unchanged by this work: nightly builds, the test gate
(`ci-testing.md`), SBOM and image scanning (`ci-supply-chain.md`), static
analysis (`ci-code-analysis.md`), and any automation of release notes.

## Rejected: the scheduled reconciler

`docs/roadmap/ci-triggers.md` proposed an hourly cron that listed git tags,
queried the package registry to learn which versions already existed, and built
the difference — with a per-scope highest-version guard so a backfilled old
patch could not clobber `latest`.

It was designed and then rejected during this session. The reasoning:

- Every part of it — the ledger queries, the backfill ordering, the rolling-tag
  guard, the `read:package` scope — exists to reconcile **drift** between git
  and the registry.
- Tagging is already a deliberate manual act. Dispatching the build in the same
  sitting means drift never accumulates: at most one unbuilt version per
  component exists, and the operator knows which.
- The manual trigger is also *lower* latency than any cron, and its mirror wait
  is deterministic rather than a fixed timeout.

So the reconciler paid a large complexity cost to solve a problem the workflow
does not have. Recorded here rather than left in the roadmap so the question
does not get re-opened from scratch.

## First-run verification

Three assumptions cannot be checked from the authoring machine and must be
confirmed on the first real dispatch:

1. **`mirror-sync` on a pull-mirror repo** is accepted with a
   `write:repository` token. If it is not, the fallback is to drop the sync
   step and rely on the mirror's own interval, with the tag-polling wait
   absorbing the delay — the workflow still works, just slower.
2. **`fromJSON` dynamic matrices** are supported by Forgejo Actions. If not,
   the fallback is a fixed matrix over all five components with per-leg
   step-level skips.
3. **Registry push from a mirrored repo's Actions** — near-certain, since
   `build-and-push.yml` already does exactly this today.
4. **`code.forgejo.org/actions/setup-node@v4` exists.** The `showcase` job runs
   on the `act` image (it needs the docker CLI) and so cannot inherit the
   runner's default Node image; it pins Node 24 through `setup-node` instead.
   If Forgejo does not mirror that action, the fallback is to drop the step and
   accept whatever Node the `act` image ships — check the version it lands on,
   because an EOL major is the reason the pin is there.
