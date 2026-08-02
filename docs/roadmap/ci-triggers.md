# Roadmap: CI — triggers & release builds

Goal: demote `workflow_dispatch` to a testing tool. Real builds happen on
their own: **nightly** when the default branch moved in the last 24 h, and
**per release tag**, where the tag prefix selects the build recipe and the
semver drives the image tags.

## Why polling, not events

Two hard constraints kill every event-driven design:

- **Mirror syncs fire no Actions events** — neither branch pushes nor tags
  that arrive via sync trigger `on: push`. That's the known Forgejo mirror
  limitation this repo already documents.
- **GitHub can't call in.** The lab is LAN-only with split-horizon DNS —
  `git.thefipster.de` doesn't resolve publicly, so a GitHub-side workflow or
  webhook can never reach Forgejo to nudge it.

So: a **scheduled reconciler** (`on: schedule`, cron) inside Forgejo Actions.
It doesn't react to syncs — it periodically compares *what exists in git*
against *what exists in the registry* and builds the difference. A newly
synced tag gets built on the first tick after the mirror pulls it
(worst-case lag = mirror interval + cron interval). The workflow can also
force-freshen first via Forgejo's own API (`POST .../mirror-sync`, token in
a secret) so the schedule never races the mirror.

## The registry is the build ledger

There is no "last-built" marker to store — mirrors are read-only, so pushing
tracking tags is impossible anyway. Instead the registry answers "was this
built?":

- **Tag build:** does the package (e.g. `web`) already have version `1.2.3`?
  Skip. Missing? Build. Idempotent, backfills automatically, survives losing
  the runner.
- **Nightly:** compare the `org.opencontainers.image.revision` label of the
  current `:nightly` image against the mirrored HEAD SHA. Different → there
  were commits → test + build + push `:nightly` (never touches `latest`).

## Tag prefix → build recipe

Tags follow `<component>-v<semver>`; the prefix picks the job (each with its
own toolchain container):

| Tag | Project | Job container | Output |
|-----|---------|---------------|--------|
| `web-v1.2.3` | Blazor web app | act image + buildx | container image `web` |
| `showcase-v3.4.2` | Astro site | node → static build → nginx image | container image `showcase` |
| `atmos-v2.1.3` | PlatformIO | `python:3.12-bookworm` + `pip install platformio` | `firmware.bin` + `littlefs.bin` |

> This row used to name `platformio/platformio-core`. **That image does not
> exist** — PlatformIO publishes no official Docker image, only community
> builds, and upstream's own documented CI recipe is the pip install. The
> manual template already builds this way, over a matrix of projects.

One reconciler workflow, per-prefix jobs (`if:` on the parsed prefix) or
reusable workflows once it grows. The **atmos** outputs aren't images —
publish them to Forgejo's **generic package registry**
(`PUT /api/packages/{owner}/generic/atmos/2.1.3/firmware.bin`). Releases
would be nicer, but release creation on mirror repos is likely blocked
(read-only) — verify once; the generic registry works regardless.

## Image tagging: four tags, no SHA tags

`web-v1.2.3` publishes exactly:

- `web:latest`
- `web:1.2.3`
- `web:1.2`
- `web:1`

Derived in shell from the git tag (strip `web-v`, split the semver) — no
metadata-action needed since the reconciler builds from a checked-out tag,
not a tag event. The commit SHA still travels as the
`org.opencontainers.image.revision` **label** (see
[ci-supply-chain.md](ci-supply-chain.md)) — traceability without tag spam.

> **Rolling-tag caveat:** `latest`/`1`/`1.2` assume the tag being built is
> the highest version. A backfilled `web-v1.1.9` built *after* `web-v1.2.3`
> would clobber them. Guard: before moving rolling tags, compare against the
> versions already in the registry and only advance if this one is the
> highest. Ship the guard in phase 2 — until then, don't backfill old tags.

## Phases

1. **Spike + reconciler skeleton** — verify `on: schedule` actually fires on
   a mirrored repo's workflows (it should; confirm early). Cron workflow
   that lists tags, queries the package API, and builds missing `web-v*`
   versions. `workflow_dispatch` stays for testing.
2. **Semver fan-out + rolling-tag guard** — the four tags, highest-version
   check.
3. **Nightly job** — revision-label comparison, `:nightly` image, test gate
   from [ci-testing.md](ci-testing.md) in front.
4. **`showcase` and `atmos` recipes** — the *build* halves already exist in
   the manual template (`infra/forgejo/build-and-push.yml`): a PlatformIO
   matrix and an Astro job, both publishing to the generic package registry
   under a SHA version. What's left here is the reconciler wiring — version
   from the **tag** instead of the SHA, ledger-check the package API before
   building, and the nginx image for `showcase`.
5. **Retire "manual-only"** — once this lands, update CLAUDE.md, the
   forgejo-setup guide (Parts C/E) and the workflow template header; the
   nightly also becomes the natural vehicle for the re-scan gap in
   [ci-supply-chain.md](ci-supply-chain.md).
