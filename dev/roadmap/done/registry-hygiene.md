# Roadmap: Forgejo registry cleanup rules

Goal: the container registry stops growing monotonically. **Done** — two
owner-scoped cleanup rules bound it by count, recorded in
[package-cleanup-rules.md](../../../docs/reference/package-cleanup-rules.md) and
added during [forgejo-setup.md step 9](../../../docs/guides/forgejo-setup.md#9-set-the-registry-cleanup-rules).
Formerly phase 3 of the supply-chain roadmap
([ci-supply-chain.md](ci-supply-chain.md)).

## What the task assumed, and what was actually there

Three of this task's premises were false by the time it was picked up. They are
kept here because each one changed the answer, and because the same assumptions
are the ones a future reader would make again.

- **"Every SHA tag lives forever."** Nothing tags by commit SHA any more. The
  app repo's dev builder — a second workflow that rebuilt the mirrored HEAD on
  demand — was deleted on 2026-08-08, leaving `release.yml` as the only thing
  that publishes. Every version in the registry now comes from a named release
  tag, which is what made a count-based rule sufficient: the growth is one set
  of layers per release, not one per commit.
- **"Every build leaves an SBOM attestation beside its image, so each tag costs
  more disk than it used to."** It does not. The build loads the image into the
  local daemon so Trivy can scan it *before* anything is pushed, and that path
  cannot carry attestations; the SBOM is a CycloneDX **run artifact** with a
  30-day retention. A cleanup rule cannot see it and does not need to.
- **"Registry blobs dominate the restic repository."** Not yet — the registry
  held one container version and one generic package when the rules went in.
  That makes this a **policy set ahead of the growth**, not a cleanup that
  shrank anything on the day. The lever on
  [backup-offsite.md](../backup-offsite.md)'s first upload is real, but it is
  the growth that never happens rather than a reclaim that already did.

## What landed

- **Two rules**, container and generic, on the `felix` account. Exact values in
  the registry; the shape is *keep the newest ten versions per package, keep the
  rolling tags, delete the rest*.
- **A row in [timetable.md](../../../docs/reference/timetable.md)** for the
  midnight cleanup — the schedule is Forgejo's `cron.cleanup_packages` default,
  not this repo's, and it lands an hour before restic reads the same directory.
- **The guide's description of CI**, corrected to the pipeline that exists: one
  workflow, no SHA tags, the SBOM's real home, and a Trivy gate that blocks
  `CRITICAL` *and* `HIGH` but only with a fix available.

## Why the rules have no age term

The obvious rule — "expire anything older than 90 days" — was designed and then
dropped, because the field does not mean what its name suggests. Forgejo walks
each package's versions newest-first and keeps a version at the **first** of
these that matches (verified against v15.0.6's `GetCleanupTargets`):

1. container only: named `latest`, or named by a digest — skipped outright,
   before the keep counter is even incremented
2. within *Keep the most recent*
3. matches *Keep versions matching*
4. created **after** `now - RemoveDays`
5. does **not** match *Remove versions matching*

Two consequences, both counter-intuitive:

- **A registry cannot expire itself empty.** The count check precedes the age
  check and ignores dates entirely, so the newest ten versions of every package
  survive any gap between releases. The worry that motivated dropping the age
  term — no release for 90 days, empty registry — was never possible.
- **Blanking the age field is the strict choice, not the lax one.** The cutoff
  is computed as `now - RemoveDays`; blank makes it *now*, nothing was created
  after that, and no version is spared at step 4. So a version falling out of
  the newest ten is deleted at the next midnight instead of lingering for a
  fixed number of days first.

What is left is a rule with no clock in it: size bounded by how many packages
exist, not by how often releases are cut. In a lab where the gap between
releases is measured in weeks, that is the property worth having.

## The caution this task carried, answered

*Can a rule expire a tag the release workflow still references, out from under a
future `docker pull` on the apps VM?* No, and it is belt-and-braces on the side
that matters. `latest` on a container package is hard-skipped by Forgejo before
any rule is consulted, and the keep pattern names it again along with `X` and
`X.Y`. The generic registry has no such behaviour, which is why its keep pattern
carries `latest` explicitly — a device updater fetches
`verdure-<component>/latest/<file>.bin` from a stable URL, and that version is
rewritten each release rather than rolling.

Nothing built here is deployed on the apps VM yet, so no consumer is exposed
today either — the same fact that keeps [image-signing.md](../image-signing.md)
parked.

## What actually returns disk

Deleting a version deletes a manifest, not the layers under it. The same
midnight task then collects untagged child manifests and drops unreferenced
blobs older than `OLDER_THAN` (24 h) from the database and the content store.
Everything a rule can reach is older than a day by construction, so the space
comes back that night — before restic reads the directory at 01:00, which is why
the cleanup sits where it does in the timetable.
