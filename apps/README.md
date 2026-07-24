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
  `coolify.homelab.lan`.
- Wildcard HTTPS for `*.homelab.lan` — **TLS approach still undecided**:
  - **Internal CA** (Coolify/Traefik issues certs; install the root on your
    devices) — fully offline, no public domain needed.
  - **Real domain + DNS-01 wildcard cert** — genuine Let's Encrypt certs, no
    browser warnings, nothing exposed to the internet.

See the main [README](../README.md) and [docs/wildcard-dns-udr.md](../docs/wildcard-dns-udr.md).
