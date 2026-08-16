# Task: A heartbeat for the weekly restic check

Goal: a repository that has quietly become unreadable stops being quiet. The
nightly backup pings a Kuma push monitor; the weekly `restic check` pings
nothing, so today its failure is found with
`systemctl status restic-check.service` — which requires already suspecting it.
The gap is stated in [done/backup.md](done/backup.md#phases) phase 4, in
[backup-setup.md](../../docs/guides/backup-setup.md) and in
[timetable.md](../../docs/reference/timetable.md#deliberate-absences); this task
is what closes it.

## The work

- **A second Kuma push monitor**, weekly period with a generous grace window,
  pinged by the check unit **only on a clean exit** — the same discipline
  `run.sh` applies to the nightly: a partial success must read as red, never as
  a green tick over a broken repository.
- **A registry row** in
  [uptime-kuma-monitors.md](../../docs/reference/uptime-kuma-monitors.md), and
  the timetable's stated absence comes out.
- **Reuse the query-string guard.** Kuma displays push URLs with `&` in the
  query string, `.env` is sourced as shell, and that trap already bit once —
  `run.sh` detects the signature and fails loudly; the check path must go
  through the same validation, not a fresh copy of the mistake.
- **Optional second half:** the `backup_last_success_timestamp` textfile metric
  for Alloy's `prometheus.exporter.unix`, giving Grafana the "why" half when
  the monitor goes red. Optional then, optional now — the monitor alone closes
  the stated gap.

## Recommendation

Small, and it matches an existing pattern exactly — this is an evening, not a
project. Do it beside [backup-proofs.md](backup-proofs.md) so the new monitor's
red path gets drilled in the same pass as the nightly's, and it starts life
proven rather than assumed.
