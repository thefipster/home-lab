# Status

**Runs on:** nothing — status record, not a build step

What is actually running versus what is only written down. The
[build order](../README.md#build-order) says what to do; this says how far it has
got.

| Piece | State |
|-------|-------|
| Proxmox host + the infra and apps VMs | ✅ deployed |
| DNS (UDR split-horizon + wildcard) | ✅ deployed |
| Traefik + Let's Encrypt (netcup DNS-01) | ✅ deployed |
| Vaultwarden password manager | ✅ deployed — pinned `1.37.1`, restore drilled from an already-paired client, [guide](vaultwarden-setup.md) |
| Authentik SSO (OIDC + forward-auth) | ✅ deployed — pinned `2026.5`, [guide](authentik-setup.md) |
| Dockge management UI | ✅ deployed — [guide](dockge-setup.md) |
| Forgejo CI + registry | ✅ deployed — [guide](forgejo-setup.md) |
| Monitoring: Grafana + Prometheus + Loki + Alloy + Tempo | ✅ complete — [guide](grafana-setup.md), [roadmap](roadmap/monitoring.md) |
| Uptime Kuma (status monitoring + notifications) | ✅ complete — [guide](uptime-kuma-setup.md) |
| Homepage start page | ✅ deployed — [guide](homepage-setup.md) |
| Backup layer 1: `vzdump` whole-VM to the `backup` mirror | ✅ deployed — scheduled and verified, [Part 8](proxmox-setup.md#part-8--schedule-whole-vm-backups) |
| Backup layer 2: `restic` file-level to the USB drive | ✅ deployed — [guide](backup-setup.md). All seven stateful infra stacks wired and restore-drilled, one tagged snapshot each ([drill guide](backup-restore-drill.md), [findings](review/2026-08-07-backup-bring-up.md)). Not yet done: a VM-rollback drill, and the apps VM has not joined ([roadmap](roadmap/backup.md)) |
| ZFS pool health → Uptime Kuma; pool capacity → Prometheus | ✅ deployed — timer pushing, Kuma monitor green, [Part 9](proxmox-setup.md#part-9--notice-when-a-mirror-degrades) |
| CI: release builds from git tags | ✅ deployed — dispatched by hand after tagging, [step 9](forgejo-setup.md#9-cut-a-release). The nightly rebuild was this item's last open piece and is **dropped**, not deferred |
| CI: tests + coverage | ✅ deployed — a failing test fails the run, coverage in the run summary |
| CI: code analysis | ✅ deployed — analyzers enforced in the build. One decision still open: whether a SonarQube stack earns its place ([roadmap](roadmap/ci-code-analysis.md)) |
| CI: container scanning + SBOM | ⬜ planned — [roadmap](roadmap/ci-supply-chain.md) |
| Coolify install (apps VM) | ✅ deployed — running and **empty**, [guide](coolify-setup.md) |
| Third-party apps on the apps VM | 📄 catalog written, nothing deployed — [catalog](../apps/services.md) |
| Container logs from the apps VM | ⬜ planned — [roadmap](roadmap/apps-vm-logs.md) |
| home-assistant VM (HAOS + Supervisor) | 📄 guide ready, not yet built — [guide](home-assistant-setup.md) |
| Monitoring the apps + HA VMs | ◐ apps VM scraped (`instance="apps"`, node exporter installed); the HA target stays red until that VM exists |
| Sizing for the hardware (12 threads / 96 GB / 4 pools) | ✅ deployed — the box is built and running these allocations, [Why these sizes](proxmox-setup.md#why-these-sizes) |

`✅` runs today · `◐` one half runs, the other waits on a machine · `📄` written
and reviewed, waiting on hardware or a build step · `⬜` not started. The one
machine-shaped `📄` row left is the HA VM, and it is why a guide can describe a
machine you cannot yet log into: the repo documents the lab it is being built
into, and that guide is verified by reading until the box exists to run it on.

**The infra VM is done, and the apps VM is up but empty.** Every infra stack in
the build order runs today, both backup layers included, Homepage last. The
apps VM now runs Coolify and is scraped for host metrics — what it does not yet
run is any application, its own or third-party. What is left overall: deploy
something onto Coolify, build the home-assistant VM, and two CI items —
container scanning ([roadmap](roadmap/ci-supply-chain.md)) and container logs
from the apps VM ([roadmap](roadmap/apps-vm-logs.md)).

**Where the CI rows actually live.** Tests, coverage, analysis and the release
build all run in the *app* repository's own `.forgejo/workflows/`, against the
runner this repo declares. This repo used to carry example copies of those
workflows under `infra/forgejo/`; they are gone, because a second copy of a
live file drifts. What stays here is the runner, the registry and the procedure
for driving them — [forgejo-setup.md](forgejo-setup.md).
