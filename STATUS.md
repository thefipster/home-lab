# Status

**Runs on:** nothing — status record, not a build step

What is actually running versus what is only written down. The
[build order](README.md#build-order) says what to do; this says how far it has
got; [ROADMAP.md](ROADMAP.md) says what is still worth building, ranked. It
sits at the repo root rather than in `docs/` because it is neither an
instruction, a value to look up, nor a procedure — it answers "is this real?"
about the whole lab.

| Piece | State |
|-------|-------|
| Proxmox host + the infra and apps VMs | ✅ deployed |
| DNS (router split-horizon + wildcard) | ✅ deployed |
| Traefik + Let's Encrypt (netcup DNS-01) | ✅ deployed |
| Vaultwarden password manager | ✅ deployed — pinned `1.37.1`, restore drilled from an already-paired client, [guide](docs/guides/vaultwarden-setup.md) |
| Authentik SSO (OIDC + forward-auth) | ✅ deployed — pinned `2026.5`, [guide](docs/guides/authentik-setup.md) |
| Dockge management UI | ✅ deployed — [guide](docs/guides/dockge-setup.md) |
| Forgejo CI + registry | ✅ deployed — [guide](docs/guides/forgejo-setup.md) |
| Monitoring: Grafana + Prometheus + Loki + Alloy + Tempo | ✅ complete — [guide](docs/guides/grafana-setup.md), [roadmap](dev/roadmap/done/monitoring.md) |
| Uptime Kuma (status monitoring + notifications) | ✅ complete — [guide](docs/guides/uptime-kuma-setup.md) |
| Homepage start page | ✅ deployed — [guide](docs/guides/homepage-setup.md) |
| Backup layer 1: `vzdump` whole-VM to the `vmbackup` mirror | ✅ deployed — scheduled and verified, [Part 8](docs/guides/proxmox-setup.md#part-8--schedule-whole-vm-backups) |
| Backup layer 2: `restic` file-level to the `filebackup` mirror | ✅ deployed — [guide](docs/guides/backup-setup.md). Every stateful infra stack wired and restore-drilled, one tagged snapshot each ([drill guide](docs/drills/backup-restore-drill.md), [findings](dev/reviews/2026-08-07-backup-bring-up.md)). Not yet done: a VM-rollback drill ([task](dev/roadmap/backup-proofs.md)), and the apps VM has not joined ([task](dev/roadmap/apps-vm-backup.md)) — which now costs real data, see the apps row below |
| ZFS pool health → Uptime Kuma; pool capacity → Prometheus | ✅ deployed — timer pushing, Kuma monitor green, [Part 9](docs/guides/proxmox-setup.md#part-9--notice-when-a-mirror-degrades) |
| Proxmox web UI on 443 with its own certificate | ✅ deployed — [Part 3](docs/guides/proxmox-setup.md#give-the-host-a-real-certificate). Its own Let's Encrypt certificate from Proxmox's ACME client, not Traefik's wildcard, so the one UI you repair the lab with does not depend on one of the lab's own guests. Renewal is Proxmox's `pve-daily-update.timer` and has not had to run yet. The home-assistant VM does the same, for the same reason |
| UPS: orderly shutdown, and coming back | ✅ deployed — [Part 10](docs/guides/proxmox-setup.md#part-10--survive-a-power-cut). NUT on the hypervisor, no client in any guest. **Drilled end to end** ([drill](docs/drills/ups-power-cut-drill.md)): on-battery notification, backstop, guests down together, killpower, and the lab booting itself when mains returned. Only the server is on the UPS so far — adding the router, switch and WAN termination raises the load and is what lets the alert leave the house ([task](dev/roadmap/ups-reach.md)) |
| CI: release builds from git tags | ✅ deployed — dispatched by hand after tagging, [step 8](docs/guides/forgejo-setup.md#8-cut-a-release-and-verify-the-image). The only workflow left: the on-demand dev builder that tagged by commit SHA was deleted from the app repo, so every image here comes from a named release tag. The nightly rebuild was this item's last open piece and is **dropped**, not deferred |
| CI: tests + coverage | ✅ deployed — a failing test fails the run, coverage in the run summary |
| CI: code analysis | ✅ deployed — analyzers enforced in the build. One decision still open: whether a SonarQube stack earns its place ([task](dev/roadmap/sonarqube.md)) |
| CI: container scanning + SBOM | ✅ deployed — Trivy failing the run on a `CRITICAL` or `HIGH` finding **that has a fix**, a CycloneDX SBOM as a 30-day run artifact, and dependency updates raised against the GitHub originals. The SBOM is deliberately **not** an attestation in the registry: the image is loaded locally so it can be scanned before the push, and that path cannot carry one. The registry is now bounded by two cleanup rules ([values](docs/reference/package-cleanup-rules.md), [design](dev/roadmap/done/registry-hygiene.md)); image signing is still parked ([task](dev/roadmap/image-signing.md)) |
| Coolify install (apps VM) | ✅ deployed — [guide](docs/guides/coolify-setup.md) |
| Third-party apps on the apps VM | ✅ deployed — Paperless-ngx, Mealie, BookStack and LubeLogger all running as Coolify resources, each from its own Forgejo repo and each joined to Authentik by OIDC — [catalog](apps/services.md). Their data under `/data` is backed up by nothing yet, and Paperless is tier 1 |
| Container logs from the apps VM | ✅ deployed — a logs-only Alloy in `apps/alloy` pushing to the infra VM's Loki through a push-path-only router, [guide](docs/guides/apps-logs-setup.md). One query covers both Docker machines; `instance` tells them apart. Its own liveness is the one thing nothing watches — Kuma's socket is the infra VM's ([why](docs/reference/uptime-kuma-monitors.md#deliberately-not-monitored)) |
| home-assistant VM (HAOS + Supervisor) | ✅ deployed — onboarded at `ha.thefipster.de` on **its own** Let's Encrypt certificate from the add-on, so the HA UI and the companion app survive an infra-VM outage ([step 7](docs/guides/home-assistant-setup.md#7-give-it-its-own-certificate)); add-ons in from HA's store; metrics wired with the long-lived token in the monitoring `.env` plus System Monitor for host counters ([step 9](docs/guides/home-assistant-setup.md#9-wire-up-metrics), [step 10](docs/guides/home-assistant-setup.md#10-add-the-hosts-own-metrics)). Bare beyond that: no devices and no automations of its own yet, the weekly renewal one aside — [guide](docs/guides/home-assistant-setup.md) |
| Monitoring the apps + HA VMs | ✅ deployed — apps VM scraped (`instance="apps"`) and now shipping logs too; HA scraped as `job="homeassistant"`, entities and host counters both. HA's are entity metrics by nature, so they do not appear on Node Exporter Full and no dashboard for them exists yet |
| Sizing for the hardware (12 threads / 96 GB / 4 pools) | ✅ deployed — the box is built and running these allocations, [Why these sizes](docs/guides/proxmox-setup.md#why-these-sizes) |

`✅` runs today · `◐` one half runs, the other is still waiting · `📄` written
and reviewed, waiting on hardware or a build step · `⬜` not started. **Every row
above is `✅`** — the other three markers are kept because the next piece of work
will need them, not because anything is wearing one. And none are verified by
reading alone: every guide in the build order has been run on the machine it
describes, the hypervisor's two newest Parts included.

**Every machine in the build order is built.** All infra stacks run, both backup
layers included; the apps VM runs Coolify with the whole third-party catalog on
it; the HA VM is up, routed and onboarded. What remains is reach rather than
existence:

- **The rest of the load on the UPS.** The shutdown chain is drilled and works,
  but only the server is plugged in
  ([task](dev/roadmap/ups-reach.md)). The router, the switch
  and the WAN termination are what let the on-battery alert actually leave the
  house — until they are on it, a real outage shuts the lab down correctly and
  silently.
- **Backup for the apps VM.** `/data` holds Paperless' scanned documents and is
  covered by neither layer ([task](dev/roadmap/apps-vm-backup.md)) — layer 1
  excludes the disk and the machine has not joined the restic repository.
  Paperless' own `document_exporter`, run by hand, is the whole answer today.
  Its container logs, by contrast, are now collected
  ([guide](docs/guides/apps-logs-setup.md)).
- **Image signing, the one CI supply-chain phase that did not land**
  ([task](dev/roadmap/image-signing.md)) — parked rather than ranked, because
  nothing would verify a signature until a lab-built image is deployed on the
  apps VM. The registry cleanup rules that used to sit beside it here are
  [done](dev/roadmap/done/registry-hygiene.md).

The full ranked list, including the cheaper proofs and heartbeats those three
imply, is [ROADMAP.md](ROADMAP.md).

**Where the CI rows actually live.** Tests, coverage, analysis and the release
build all run in the *app* repository's own `.forgejo/workflows/`, against the
runner this repo declares. This repo used to carry example copies of those
workflows under `infra/forgejo/`; they are gone, because a second copy of a
live file drifts. What stays here is the runner, the registry and the procedure
for driving them — [forgejo-setup.md](docs/guides/forgejo-setup.md).
