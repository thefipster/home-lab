# Roadmap: CI — nightly rebuilds

Tag-driven release builds have **landed**. `release.yml` takes the release tags
as a dispatch input, syncs the mirror itself, waits for those exact refs, and
publishes versioned images and packages — design in
[`../superpowers/specs/2026-08-05-forgejo-release-workflow-design.md`](../superpowers/specs/2026-08-05-forgejo-release-workflow-design.md),
procedure in [`../forgejo-setup.md`](../forgejo-setup.md).

> An earlier version of this file proposed a **cron reconciler**: list the git
> tags, ask the package registry which versions already exist, build the
> difference, and guard the rolling tags so a backfill could not clobber
> `latest`. That was **rejected**, not deferred — every part of it reconciles
> drift between git and the registry, and dispatching the build in the same
> sitting as the tag means drift never accumulates. The reasoning is in the
> spec; don't re-propose it.

What remains is the one build that genuinely cannot be hand-triggered, because
its whole purpose is to run when nobody is looking.

## Nightly rebuild

[`ci-supply-chain.md`](ci-supply-chain.md) has a **re-scan gap**: scanning at
build time misses CVEs published after the build. A release that is still
current can rot without anything noticing. The nightly is the natural vehicle.

- **Trigger:** `on: schedule`. Confirm early that cron actually fires on a
  mirrored repo's workflows — if it does not, this whole item is dead and the
  fallback is re-dispatching by hand.
- **Change detection without a ledger:** compare the `:nightly` image's
  `org.opencontainers.image.revision` label against the mirrored HEAD SHA.
  Different → there were commits → rebuild. Same → stop, having pulled one
  manifest. The label is already published by both workflows.
- **Never touches `latest`.** The nightly publishes `:nightly` only. Release
  tags remain the sole way anything rolls forward.
- **Gated by the test job** from [`ci-testing.md`](ci-testing.md), once that
  exists — an unattended build that publishes untested code is worse than no
  build.
- **Rescan the published `latest` images** in the same run and surface findings
  through the step summary, or as an alert via the monitoring stack. That is
  the part [`ci-supply-chain.md`](ci-supply-chain.md) is waiting on.
