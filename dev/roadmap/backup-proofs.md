# Task: The unproven halves of the backup

Goal: prove the properties no drill has covered. Phase 5 of the backup design
drilled every wired stack in place
([findings](../reviews/2026-08-07-backup-bring-up.md)); what it left explicitly
unproven is listed in [done/backup.md](done/backup.md#phases), and this task is
that list. The standing rule applies: **treat every part as untested until a
drill has covered it.**

## The four proofs

1. **The deadman's silent half.** Nothing has yet watched the Kuma monitor go
   **red** because a heartbeat did not arrive — and that is the property the
   whole arrangement exists for. Disable `restic-backup.timer` for one night,
   watch the monitor turn red and the ntfy notification arrive, re-enable.
2. **The weekly `restic check`.** Confirm from `journalctl -u
   restic-check.service` that it has fired unattended and exited clean. Once
   [restic-check-heartbeat.md](restic-check-heartbeat.md) lands, drill its red
   path the same way as the nightly's.
3. **The nightly timer, unattended.** By now the journal and the Kuma heartbeat
   history should already prove this — the proof is reading them and recording
   it, not staging anything.
4. **The VM-rollback drill.** The expensive one: roll the infra VM back to a
   snapshot, restore every stack from restic, and verify each comes up —
   Vaultwarden accepting a login from an **already-paired** client, Authentik
   with its providers intact, Forgejo serving a `docker pull`, Kuma with its
   monitors. Expect the clock-skew failure first ("certificate has expired or
   is not yet valid") and do not misdiagnose it — `init-host.sh` exists for it.

The procedure for the in-place drills is
[backup-restore-drill.md](../../docs/drills/backup-restore-drill.md). Record
every run in `dev/reviews/` as a dated finding, and re-run yearly.

## Recommendation

Proofs 1–3 cost minutes and can happen in one week — do them immediately rather
than saving them for a gameday. Proof 4 is an afternoon and deserves scheduling
like one; its procedure is already written, so the only thing between the lab
and the claim "a dead infra VM comes back" is running it once. Until proof 1
has been seen, the backup's alarm is a hypothesis exactly the way an unrestored
backup was.
