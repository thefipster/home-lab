# Roadmap

**Runs on:** nothing — ranked index, not a build step

What is still worth building, in the order it is worth building it.
[STATUS.md](STATUS.md) says how far the build has got; this says what comes
next. It sits at the repo root for the same reason STATUS.md does: it is
neither an instruction, a value to look up, nor a procedure.

Each open task is one document in [dev/roadmap/](dev/roadmap/), small enough
to pick up in a sitting and carrying its own recommendation. Finished roadmaps
move to [dev/roadmap/done/](dev/roadmap/done/), where they remain the design
record — the backup tiers, the couplings, the rejected alternatives all still
live there and the task documents link into them rather than repeating them.

## Open tasks, ranked

| # | Task | Why this rank |
|---|------|---------------|
| 1 | [Backup for the apps VM](dev/roadmap/apps-vm-backup.md) | The only gap that costs real data: Paperless' scanned documents sit on a disk covered by **no** backup layer. Joining the restic repository was designed to be one key and an `.env` — the work is the inventory and the Coolify restore semantics. |
| 2 | [Offsite backup](dev/roadmap/backup-offsite.md) | Every copy of everything is inside one building. Client-side encryption already did the design work; what remains is a target, a topology and a bandwidth check — the step that makes 3-2-1 true. |
| 3 | [Forgejo registry cleanup rules](dev/roadmap/registry-hygiene.md) | An afternoon of clickwork that permanently shrinks the backup set — registry blobs dominate the restic repository and would dominate the offsite upload. The natural predecessor to rank 2, without gating it. |
| 4 | [The unproven halves of the backup](dev/roadmap/backup-proofs.md) | Four proofs, three of them minutes each: the deadman going red, the weekly check firing, the nightly running unattended, and the full VM-rollback drill. Until the first one is seen, the backup's alarm is a hypothesis. |
| 5 | [A heartbeat for the weekly restic check](dev/roadmap/restic-check-heartbeat.md) | The one stated monitoring gap on the infra VM: an unreadable repository stays quiet today. An evening's work that matches the existing push-monitor pattern exactly. |
| 6 | [The rest of the load on the UPS](dev/roadmap/ups-reach.md) | Router, switch and WAN termination on the UPS are what let the drilled, working on-battery alert actually leave the house. A hardware errand; nothing blocks it, nothing depends on it. |

The ranking is by stakes, not by effort — 3, 4 and 5 are each far cheaper than
1 and 2 and can be interleaved freely; only one ordering genuinely matters,
and it is stated on rank 3.

## Parked — a trigger, not a date

- **[Image signing](dev/roadmap/image-signing.md)** — until the first
  lab-built image is deployed on the apps VM, nothing anywhere would verify a
  signature. Signing without a verifier is a checkbox.
- **[SonarQube](dev/roadmap/sonarqube.md)** — trend history for issues and
  coverage, wanted only when the per-run output starts feeling insufficient.
  It has not.

## Ideas — not yet tasks

Named so they are not re-derived from scratch, and deliberately not ranked:

- **Home Assistant build-out.** The VM is deployed, routed and scraped, but
  bare — no devices, no automations, and no dashboard for its entity metrics.
  This becomes tasks when the first devices arrive.
- **A liveness signal for the apps-VM log collector.** Kuma structurally cannot
  watch it; a Loki absence rule in Grafana (UI-only, like `ServiceDown`) could,
  without touching the no-contact-points decision.
- **Drill due-dates in [timetable.md](docs/reference/timetable.md).** "Re-run
  yearly" currently lives only in the drill guides; a registry row would make
  an overdue drill visible instead of remembered.
- **Proxmox Backup Server, when a second box exists.** Already weighed and
  parked in [done/backup.md](dev/roadmap/done/backup.md#why-restic-for-layer-2):
  running PBS as a VM on the host it protects is the classic anti-pattern.

## Done

- [backup](dev/roadmap/done/backup.md) — both layers built, every infra stack
  wired and drilled; still the design record for tiers and couplings.
- [monitoring](dev/roadmap/done/monitoring.md) — all five phases; logs, metrics,
  traces and dashboards on the infra VM.
- [apps-vm-logs](dev/roadmap/done/apps-vm-logs.md) — the second Alloy; one query
  covers both Docker machines.
- [ci-supply-chain](dev/roadmap/done/ci-supply-chain.md) — SBOM and enforcing
  scan; its two open phases live on as rank 3 and a parked task above.
- [ci-code-analysis](dev/roadmap/done/ci-code-analysis.md) — analyzers, format
  gate, tests and coverage; its open decision is parked above.

Two former roadmap items are **dropped, not deferred** — a nightly rebuild and
a tag reconciler, both rejected because the lab runs no CI schedule at all
([timetable.md](docs/reference/timetable.md#deliberate-absences)). Do not
re-propose them; the reasoning lives in
[done/ci-supply-chain.md](dev/roadmap/done/ci-supply-chain.md).
