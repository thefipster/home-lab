# apps VM — Coolify

The apps VM runs [Coolify](https://coolify.io), a self-hosted
PaaS that builds, deploys and runs your own applications with domains and HTTPS.

**Guide: [docs/coolify-setup.md](../docs/coolify-setup.md).**

## Why there is no compose file here

Every `infra/` stack is a `compose.yaml` in this repo that Dockge merely starts
and stops — the repo is the source of truth. This directory is deliberately the
opposite. Coolify owns this VM's Docker, keeps its own configuration store, and
manages applications through its web UI, so app definitions live **in Coolify**,
not here. Mirroring them into the repo would create a second source of truth that
silently drifts from the one actually deploying things.

That holds for third-party software too — Paperless, Vaultwarden and the rest
are Coolify resources deployed from their own Forgejo repo, not stacks declared
here. What this directory adds for them is a **catalog**:
[services.md](services.md) records what runs and why that one, and points at the
repo holding the compose.

What that leaves in this directory:

| File | Purpose |
|------|---------|
| `services.md` | the catalog of **third-party** applications this VM runs as Coolify resources — what runs and why that one. Their compose files live in the Forgejo repo `self-hosted-services`, so this stays a pointer, not a second source of truth. |
| `.env.example` | the three `NETCUP_*` names Coolify's bundled proxy needs for its own DNS-01 wildcard. Copied to `.env` by the init script. The **values** are entered in Coolify's UI — the file exists so the requirement is visible in the repo instead of only inside Coolify. |

## Scripts that run on this machine

| Script | What it does |
|--------|--------------|
| [`init-host.sh`](../scripts/init-host.sh) | The time-sync step fix that survives a snapshot rollback, plus the QEMU guest agent. Shared with the infra VM. |
| [`init-unattended-upgrades.sh`](../scripts/init-unattended-upgrades.sh) | Automatic security updates. Also shared with the infra VM — Coolify's installer sets up none. |
| [`init-coolify.sh`](../scripts/init-coolify.sh) | Preflight, swapfile, then Coolify's official installer — fetched to disk with its checksum printed, rather than piped into a root shell. |
| [`init-node-exporter.sh`](../scripts/init-node-exporter.sh) | Host metrics for Alloy on the infra VM to scrape. The infra VM must **not** run this — Alloy collects its own host metrics there. |

**[`init-docker.sh`](../scripts/init-docker.sh) is the one script this machine
deliberately skips.** Coolify's installer brings its own Docker Engine, so this
VM has no Docker — and no `docker` group — until `init-coolify.sh` runs. Its
preflight treats a missing Engine as the normal first-run state and only
version-checks one that is already there.

## TLS and DNS

Coolify's proxy issues its **own** Let's Encrypt wildcard for `*.thefipster.de`
via the netcup DNS-01 challenge — the same mechanism as Traefik on the infra VM,
but a separate certificate and ACME account. Nothing is exposed to the internet
either way.

`*.thefipster.de` already resolves to this VM, so **a new app needs no new DNS
record** and `coolify.thefipster.de` needs no exact record of its own. The
registry, including why that absence is deliberate:
[docs/dns-records.md](../docs/dns-records.md).

See also the main [README](../README.md).
