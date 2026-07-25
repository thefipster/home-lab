# apps VM — Coolify

This directory is a placeholder for the **apps VM**, which runs
[Coolify](https://coolify.io) — a self-hosted PaaS that deploys and runs your own
applications with domains and HTTPS.

Unlike the infra stacks, Coolify is **not** a compose file checked in here: it's
installed by its own script and then manages apps through its web UI, owning the
VM's Docker itself. So this folder stays mostly empty by design — app definitions
live in Coolify, not in this repo.

## Planned

- Install guide: Coolify on the apps VM (Ubuntu 26.04), reachable at
  `coolify.thefipster.de`.
- Wildcard HTTPS for `*.thefipster.de` — decided and already working on the
  infra VM: genuine Let's Encrypt wildcard via the DNS-01 challenge against
  netcup. Coolify's bundled proxy gets the same `NETCUP_*` credentials and
  issues its own cert — see [docs/traefik-setup.md](../docs/traefik-setup.md),
  "Apps VM later". The DNS side (`*.thefipster.de` → this VM) is already in
  place.

See the main [README](../README.md) and [docs/wildcard-dns-udr.md](../docs/wildcard-dns-udr.md).
