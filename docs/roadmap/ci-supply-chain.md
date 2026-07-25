# Roadmap: CI — container scanning, SBOM & supply chain

Goal: know what's inside every image the lab builds, and don't push images
with known-critical holes.

## Phases

1. **SBOM at build time.** Two complementary outputs, both cheap:
   - `--sbom=true` on the buildx step — BuildKit generates an SBOM
     attestation and stores it **in the registry next to the image**.
   - `syft <image> -o cyclonedx-json` uploaded as a run artifact for a
     human-readable copy.

2. **Image scan after build, before push.** Trivy against the freshly built
   image:
   - start **report-only** (scan results into `$GITHUB_STEP_SUMMARY`),
   - after the noise level is understood, enforce
     `--exit-code 1 --severity CRITICAL` (add HIGH later if livable).
   Trivy also scans lockfiles/dependencies in the same pass (`trivy fs`) if
   wanted — one tool, keep it that way (Grype exists; two scanners is a
   hobby, not a control).

3. **Registry hygiene.** Forgejo's built-in cleanup rules for the package
   registry (keep last N tags / max age) — otherwise every SHA tag lives
   forever on a 40 GB disk.

4. **Dependency updates — runs against GitHub, not Forgejo.** The Forgejo
   copies are read-only mirrors, so Renovate/Dependabot must operate on the
   GitHub originals (Renovate app or workflow there). Updated PRs merge on
   GitHub → mirror in → manual dispatch builds them. No Forgejo-side work.

5. **Image signing (optional, last).** `cosign` with a self-managed key in
   Forgejo secrets, verification later on the Coolify side. Real value only
   arrives when something *verifies* signatures — park it until the apps VM
   deploys from the registry.

## The re-scan gap

Scanning at build time misses CVEs published *after* the build. Once the
scheduled builds from [ci-triggers.md](ci-triggers.md) exist, the **nightly
job is the natural vehicle**: rescan the published `latest` images each
night and surface findings via the step summary (or an alert through the
monitoring stack). Until then, re-running the workflow by hand rebuilds and
rescans in one go.
