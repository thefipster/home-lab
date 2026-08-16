# Task: Forgejo registry cleanup rules

Goal: the container registry stops growing monotonically. Formerly phase 3 of
the supply-chain roadmap ([done/ci-supply-chain.md](done/ci-supply-chain.md)),
and the only piece of it that got *more* urgent after landing the rest: every
build now leaves an SBOM attestation beside its image, so each tag costs more
disk than it used to, and every SHA tag lives forever.

**Why it matters beyond the 40 GB.** The registry blobs live under Forgejo's
`APP_DATA_PATH`, inside the tier-1 backup set — so they dominate the restic
repository too. The backup design named this item as *the* lever on whether the
`filebackup` pool stays big enough
([done/backup.md](done/backup.md#constraints--notes)), and it is now also what
decides the size of [backup-offsite.md](backup-offsite.md)'s first full upload.
restic's dedup absorbs repeated layers well, but it cannot delete what the
registry never expires.

## The work

- **Forgejo's built-in cleanup rules** for the package registry — keep last N
  versions / max age. They are owner-scoped clickwork in the Forgejo UI, which
  means a registry-row-style record of the exact values, the same way every
  other piece of clickwork is recorded.
- **Decide what "current" means.** Release tags stay; SHA-tagged builds expire.
  The generic package registry (binaries, archives) needs its own answer —
  publishes there already delete-before-PUT, so old *versions* are the question,
  not old files.
- **Verify the attestations go with their images**, and that expiring a package
  version actually returns disk rather than orphaning blobs.
- **A row in [timetable.md](../../docs/reference/timetable.md)** — the cleanup
  runs on Forgejo's own schedule, and that registry records everything that
  runs on a clock.

## Recommendation

Do it before [backup-offsite.md](backup-offsite.md)'s first upload — it is an
afternoon of clickwork plus a verification pull, and it permanently shrinks
every nightly snapshot after it. The one caution: confirm a tag the release
workflow still references cannot be expired out from under a future
`docker pull` on the apps VM — "keep last N" is measured against what CI
produces, not against what Coolify has deployed.
