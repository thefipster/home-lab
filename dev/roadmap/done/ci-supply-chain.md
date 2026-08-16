# Roadmap: CI — container scanning, SBOM & supply chain

Goal: know what's inside every image the lab builds, and don't push images
with known-critical holes. **That goal is met** — the build produces an SBOM
and fails on a critical finding today. What was left here — keeping the
registry from filling up, and signing — moved to its own tasks:
[registry-hygiene.md](../registry-hygiene.md) and
[image-signing.md](../image-signing.md).

**The landed phases live in the app repo**, in `.forgejo/workflows/`, because
that is where they run. This side records the consequences only —
[forgejo-setup.md](../../../docs/guides/forgejo-setup.md) states what the build now leaves in the
registry and what can fail a run. Phase numbers are kept as they were so the
references to "phase 3" elsewhere still land.

## Phases

1. **✅ Landed.** **SBOM at build time.** Two complementary outputs, both cheap:
   - `--sbom=true` on the buildx step — BuildKit generates an SBOM
     attestation and stores it **in the registry next to the image**.
   - `syft <image> -o cyclonedx-json` uploaded as a run artifact for a
     human-readable copy.

2. **✅ Landed, enforcing.** **Image scan after build, before push.** Trivy
   against the freshly built image. It went in report-only, and now runs
   `--exit-code 1 --severity CRITICAL` — a critical finding fails the run and
   nothing is pushed. HIGH is still advisory; raise it if the noise level turns
   out to be livable. One scanner, deliberately (Grype exists; two scanners is
   a hobby, not a control).

3. **⬜ Open — extracted to [registry-hygiene.md](../registry-hygiene.md).**
   Forgejo's built-in cleanup rules for the package registry, so SHA tags stop
   living forever. More pressing than when first written: phase 1 stores an
   attestation beside every image, so each build leaves more behind.

4. **✅ Landed.** **Dependency updates — runs against GitHub, not Forgejo.** The
   Forgejo copies are read-only mirrors, so updates are raised on the GitHub
   originals. Merged there → mirror in → manual dispatch builds them. No
   Forgejo-side work, exactly as planned.

5. **⬜ Parked — extracted to [image-signing.md](../image-signing.md).**
   `cosign` with a self-managed key in Forgejo secrets, verification on the
   Coolify side. Real value only arrives when something *verifies* signatures;
   parked until an image built here is deployed there.

## The re-scan gap, and why nothing is coming for it

Scanning at build time misses CVEs published *after* the build. A release that
is still current can rot without anything noticing.

An earlier version of this file parked that on a **nightly rebuild** — rescan
the published `latest` images every night, surface findings in the step summary
or as an alert. That nightly is **dropped**, not deferred: the lab runs no CI
schedule at all, because GitHub is primary and Forgejo pull-mirrors it, so
nothing event-driven or timed reaches these workflows from either direction
([timetable.md](../../../docs/reference/timetable.md#deliberate-absences) records the absence).

So the re-scan gap has **no automated answer and is not waiting for one.**
Re-dispatching the build by hand rebuilds and rescans in one go, and that is
the whole procedure. If the gap ever starts to bite, the honest fix is a
scanner that runs somewhere a schedule *can* reach — a timer on the infra VM
pointed at the registry, not a workflow — and that would be a new roadmap
entry rather than a revival of this one.
