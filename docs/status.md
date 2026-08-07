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
| Vaultwarden password manager | 📄 stack + guide written, not yet built — pinned `1.37.1`, [guide](vaultwarden-setup.md) |
| Authentik SSO (OIDC + forward-auth) | ✅ deployed — pinned `2026.5`, [guide](authentik-setup.md) |
| Dockge management UI | ✅ deployed — [guide](dockge-setup.md) |
| Forgejo CI + registry | ✅ deployed — [guide](forgejo-setup.md) |
| Monitoring: Grafana + Prometheus + Loki + Alloy + Tempo | ✅ complete — [guide](grafana-setup.md), [roadmap](roadmap/monitoring.md) |
| Uptime Kuma (status monitoring + notifications) | ✅ complete — [guide](uptime-kuma-setup.md) |
| Backup layer 1: `vzdump` whole-VM to the `backup` mirror | 📄 documented — [Part 8](proxmox-setup.md#part-8--schedule-whole-vm-backups) |
| Backup layer 2: `restic` file-level to the USB drive | ✅ deployed — [guide](backup-setup.md). All seven infra stacks wired and restore-drilled, one tagged snapshot each ([drill guide](backup-restore-drill.md), [findings](review/2026-08-07-backup-bring-up.md)). Not yet done: a VM-rollback drill, and the apps VM has not joined ([roadmap](roadmap/backup.md)) |
| ZFS pool health → Uptime Kuma; pool capacity → Prometheus | 📄 documented — [Part 9](proxmox-setup.md#part-9--notice-when-a-mirror-degrades) |
| CI: triggers & release builds (nightly, tags) | ⬜ planned — [roadmap](roadmap/ci-triggers.md) |
| CI: tests + coverage | ⬜ planned — [roadmap](roadmap/ci-testing.md) |
| CI: code analysis | ⬜ planned — [roadmap](roadmap/ci-code-analysis.md) |
| CI: container scanning + SBOM | ⬜ planned — [roadmap](roadmap/ci-supply-chain.md) |
| Coolify install (apps VM) | 📄 guide ready, not yet built — [guide](coolify-setup.md) |
| Third-party apps on the apps VM | 📄 catalog written, nothing deployed — [catalog](../apps/services.md) |
| Container logs from the apps VM | ⬜ planned — [roadmap](roadmap/apps-vm-logs.md) |
| home-assistant VM (HAOS + Supervisor) | 📄 guide ready, not yet built — [guide](home-assistant-setup.md) |
| Monitoring the apps + HA VMs | 📄 config shipped; targets red until those VMs exist |
| Sizing for the target hardware (12 threads / 96 GB / 4 pools) | 📄 documented — [Why these sizes](proxmox-setup.md#why-these-sizes) |

`✅` runs today · `📄` written and reviewed, waiting on hardware or a build step ·
`⬜` not started. The three machine-shaped `📄` rows — Coolify, the third-party
apps, the HA VM — are why the guides can describe machines you cannot yet log
into: the repo documents the lab it is being built into, and each guide is
verified by reading until the box exists to run it on. Vaultwarden is the same
state on a machine that *does* exist: its stack and guide are written and the
build order now runs through them, but nothing on the infra VM has been brought
up against them yet.
