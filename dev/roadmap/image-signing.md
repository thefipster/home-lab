# Task: Image signing (parked)

Formerly phase 5 of the supply-chain roadmap
([done/ci-supply-chain.md](done/ci-supply-chain.md)). `cosign` with a
self-managed key in Forgejo secrets, signing each image the release build
pushes; verification on the deploy side.

**Why it is parked, not queued.** A signature has value only when something
*verifies* it, and nothing does: the third-party stacks on the apps VM pull
**upstream** images, not ones this lab builds, so there is no deploy step
anywhere that would check a signature this lab produces. Signing without a
verifier is a checkbox, and the lab does not collect those.

## The trigger

The first image **built here** deployed on the apps VM. That is the moment a
verify step has somewhere to live (the Coolify side of the deploy), and the
task un-parks itself — key generation, the signing step in the release
workflow (app repo, not this one), and the verification wiring all belong to
that day.

## Recommendation

Leave it parked and resist doing it early for completeness' sake. When the
trigger fires, keep the scope honest: a self-managed key in Forgejo secrets is
the right size for a one-person lab — keyless/OIDC signing infrastructure is
not, for the same reason the lab rejected a second vulnerability scanner.
