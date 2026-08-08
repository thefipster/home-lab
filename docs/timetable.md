# Timetable (registry)

**Runs on:** nothing — registry, not a build step

Every operation in the lab that runs on a clock, in one place, so a new job can
be placed without re-reading the repo to work out what it would land on top of.
All times are the machines' local time (**Europe/Berlin**).

The **Declared in** column is the source of truth for each row. Change the
schedule there, then change the row — a time in this file that disagrees with
its source is a bug in this file, not a second opinion.

## The night window

The part that matters when adding a job: four operations, deliberately
staggered, on two machines that share one set of disks.

| Time | Machine | Operation | Declared in |
|---|---|---|---|
| **01:00** (+0–5 min) | infra VM | `restic` file-level backup of all seven stacks, then `forget --prune` (`--keep-daily 7 --keep-weekly 4 --keep-monthly 6`) | [`restic-backup.timer`](../infra/backup/restic-backup.timer) |
| **02:00** | Proxmox host | `vzdump` whole-VM snapshot backup, selection **All**, retention from the storage (`keep-daily=7,keep-weekly=4,keep-monthly=3`) | [proxmox-setup.md Part 8](proxmox-setup.md#part-8--schedule-whole-vm-backups) |
| **Sun 03:00** (+0–10 min) | infra VM | `restic check --read-data-subset=10%` | [`restic-check.timer`](../infra/backup/restic-check.timer) |
| **04:30** | infra + apps VMs | reboot — **only if** an installed update requires one | [`init-unattended-upgrades.sh`](../scripts/init-unattended-upgrades.sh) |

**The order is load-bearing, not tidy.** restic runs first so that when vzdump
starts an hour later, layer 1's whole-VM archive already contains that night's
database dumps — the two layers stack rather than merely coexist. The weekly
check runs after both, so the two jobs that touch the USB drive never overlap on
it and neither competes with vzdump for host I/O. The reboot window sits last,
clear of all three.

**These are start times, and nothing here records duration.** `vzdump` over
~294 GB of VM roots is the one job that could plausibly still be running when the
Sunday check begins. If that starts happening, the check is the row to move —
it is weekly and has the most slack.

**A new I/O-heavy job wants a slot after 05:00 or before 01:00.** The
01:00–04:30 band is spoken for on both machines.

## Continuous and short-interval

Nothing below competes for the night window; it is here so the whole clock is in
one document.

| Every | Machine | Operation | Declared in |
|---|---|---|---|
| **5 min** | Proxmox host | ZFS pool health pushed to Kuma, and `zfs_pool_*` written for Prometheus (`OnBootSec=2min`, then `OnUnitActiveSec=5min`) | [proxmox-setup.md Part 9](proxmox-setup.md#part-9--notice-when-a-mirror-degrades) |
| **60 s** | infra VM | Uptime Kuma checks — Kuma's default, used by every monitor except the two push rows below | [uptime-kuma-monitors.md](uptime-kuma-monitors.md) |
| **15 s** | infra VM | Prometheus scrape **and** rule evaluation | [`prometheus.yml`](../infra/monitoring/prometheus/prometheus.yml) |
| **15 s** | infra VM | Alloy scrapes (every target but one) and its Docker discovery refresh | [`config.alloy`](../infra/monitoring/alloy/config.alloy) |
| **60 s** | infra VM | Alloy's Home Assistant scrape — slower deliberately: it is the one target reached over HTTPS through Traefik rather than directly | [`config.alloy`](../infra/monitoring/alloy/config.alloy) |
| **1 min** | infra VM | Grafana alert rule group evaluation. A rule fires only after its `for:` holds — 5 m, 15 m or 1 h depending on the rule | [`rules.yaml`](../infra/monitoring/grafana/provisioning/alerting/rules.yaml) |
| **~10 min** | infra VM | Forgejo pull-mirror sync from GitHub — **per repository**, set in Forgejo's own UI, so this is a convention rather than a declaration | [forgejo-setup.md step 6](forgejo-setup.md#6-mirror-a-repo-from-github) |
| **daily** | infra VM | Traefik's ACME renewal check; it renews the wildcard when under 30 days remain. Traefik's built-in behaviour — nothing in the compose overrides it | [`traefik/compose.yaml`](../infra/traefik/compose.yaml) |

**Kuma's two push monitors invert the rule.** They are not polls — Kuma waits to
be called, so the interval is a deadline and silence past it is the alarm. Each
one has to outlast the job that feeds it:

| Heartbeat | Monitor | Fed by |
|---|---|---|
| **300 s**, 2 retries | Hypervisor Storage | the 5-minute ZFS timer above |
| **90000 s** (25 h), 0 retries | Backup | the 01:00 restic job — longer than a day, plus an hour of slack for the timer's jitter and for a first run that uploads everything |

That arithmetic is the pattern to copy: **heartbeat > period + jitter + worst
plausible run time**, or a healthy lab goes red on its own schedule.

## Package updates

`init-unattended-upgrades.sh` writes the policy and **enables** apt's timers; it
does not schedule them. The times are the distro's, so read them off the machine
rather than trusting a number written here:

```bash
systemctl list-timers 'apt-daily*'
```

Both carry large randomized delays by design — that jitter is what keeps every
machine in the world from hitting the mirrors on the same second. `apt-daily`
refreshes and downloads; `apt-daily-upgrade` installs; autoclean runs every 7
days (`APT::Periodic::AutocleanInterval "7"`).

**The reboot is not in the same window as the install, and the gap is larger
than it looks.** unattended-upgrades installs during the morning apt window and,
if a package left `/var/run/reboot-required`, schedules the reboot for the *next*
04:30 — which is the following night, roughly 22 hours later, not the same
morning. Both Ubuntu VMs do this, `WithUsers` included, so an SSH session left
open in a terminal tab does not defer it. The Proxmox host is not in this
scheme; it has no `init-unattended-upgrades.sh` run.

## Off the lab

| When | Where | Operation | Declared in |
|---|---|---|---|
| **Saturday, before 08:00** | GitHub | Renovate checks the compose image pins and refreshes the Dependency Dashboard issue | [`renovate.json5`](../renovate.json5) |

It opens PRs against this repository and touches no machine in the lab. Its
`timezone` is set to `Europe/Berlin` in that file, so it lines up with every
other time here.

## Not declared by this repo

Each machine also runs timers that came with it. None of them are this repo's to
schedule, and none are reproduced here, but a new hypervisor job should be placed
around them rather than into them — a **ZFS scrub is the heaviest I/O event on
the box**, and Proxmox ships its own periodic update and report jobs too.
Enumerate before choosing a slot:

```bash
systemctl list-timers --all
```

```bash
ls /etc/cron.d /etc/cron.daily
```

Coolify's internal schedules on the apps VM and Home Assistant's on the HA VM
are the same story, one layer up: owned by those platforms' own databases, which
is why neither machine appears in the night window above.

## Deliberate absences

A gap that was decided reads differently from one that was overlooked, so both
kinds are listed — the same rule the other registries follow.

- **No CI schedule at all.** Both Forgejo workflows are `workflow_dispatch`-only,
  because GitHub is primary and the lab is LAN-only, so nothing event-driven is
  possible in either direction. A scheduled reconciler was designed and
  **rejected** — dispatching by hand right after tagging means drift never
  accumulates
  ([spec](superpowers/specs/2026-08-05-forgejo-release-workflow-design.md)).
  Do not re-propose it.
- **The weekly `restic check` has no heartbeat.** The nightly backup pings Kuma;
  the check pings nothing, so a repository that has become unreadable stays
  quiet. Known gap ([roadmap/backup.md](roadmap/backup.md)).
- **The apps VM has no backup job of either layer.** Its 300 GB data disk is
  excluded from `vzdump` (`backup=0`) and it has not joined the restic
  repository.
- **Nothing here runs on the home-assistant VM.** It is an appliance; the repo
  schedules nothing inside it.

## Adding a job

1. Pick a slot **outside 01:00–04:30** unless it genuinely belongs in the
   backup chain.
2. Declare it where its kind is declared: a `.timer` beside the stack for the
   infra VM, a guide step for anything on the hypervisor (which has no checkout
   of this repo).
3. Add its row here, with the link back to that source.
4. If it can fail silently, give it a Kuma push monitor and size the heartbeat
   by the arithmetic above. A job whose only evidence is a journal line on a
   machine you are not looking at is not monitored.
