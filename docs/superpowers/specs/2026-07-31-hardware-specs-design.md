# Design: hardware specs for the target machine

**Date:** 2026-07-31
**Status:** approved, implemented in the same pass

Re-sizes the whole lab for the hardware that was actually bought, replaces the
placeholder storage story with four real ZFS pools, and turns the backup
roadmap's two abstract layers into two named targets.

Supersedes the sizing in
[2026-07-26-three-machine-lab-design.md](2026-07-26-three-machine-lab-design.md),
which assumed 32 threads, 64 GB and an undifferentiated 2 TB. That document is a
historical record and is **not** retro-edited; this one states what changed and
why.

## What changed on the spec sheet

| | Assumed (2026-07-26) | Actual |
|---|---|---|
| CPU | 32 threads | **12 threads**, Intel `i5-12500HL` (Alder Lake) |
| RAM | 64 GB | 64 GB — unchanged |
| Storage | "2 TB dedicated to VM disks" | **6 internal drives + 1 external**, see below |

The CPU is documented as **12 threads** without asserting a P/E split. Twelve is
the number that drives every vCPU decision below, and it holds whichever way the
cores are arranged.

## Storage — four pools

Six internal drives, paired into three mirrors, plus one external drive.
Mirroring on Proxmox means **ZFS**: it is the only mirrored layout the installer
will boot from, and it is what makes the other two mirrors uniform to manage and
to monitor.

| Pool | Devices | Proxmox storage | Holds |
|---|---|---|---|
| `rpool` | 2 × 500 GB NVMe, mirror | `local-zfs` (`zfspool`) | Proxmox root + all three VM **root** disks |
| `backup` | 2 × 1 TB SATA, mirror | `backup` (**`dir`**) | `vzdump` whole-VM archives — layer 1 |
| `data` | 2 × 500 GB SATA, mirror | `data` (`zfspool`) | the apps VM's **second** disk |
| `usbbackup` | 1 × 500 GB USB 3.1 NVMe | *(none)* | restic repository — layer 2 |

Only `rpool` is created by the installer. The other three are `zpool create`
after first boot.

### The one non-obvious storage type

A ZFS pool registered with Proxmox as type **`zfspool`** supports content
`images,rootdir` **only** — it cannot hold `vzdump` output. So the backup mirror
is registered as a **Directory** storage on the pool's mountpoint
(`pvesm add dir backup --path /backup --content backup`), while `data` is an
ordinary `zfspool`. Getting this backwards produces a backup target that does
not appear in the *Datacenter → Backup* storage dropdown, with no error to
explain why.

`usbbackup` gets **no Proxmox storage entry at all**. Proxmox never writes to
it; it is a plain filesystem that a restic client reaches over SFTP.

### Why ZFS on the USB drive too

A single-disk pool cannot repair corruption, but it still **detects** it, and it
makes all four pools answer the same health query — which is what lets one
monitor cover the lot. It also sidesteps the `/etc/fstab` trap: a USB device
that is absent at boot with a hard fstab entry blocks the boot, whereas an
unimportable ZFS pool is simply absent and the host comes up regardless.

## VM sizing

| | infra | apps | home-assistant |
|---|---|---|---|
| vCPU | 12 | 12 | 12 |
| `cpuunits` | 100 (default) | 50 | 200 |
| RAM | 16 GB | 24 GB | 8 GB |
| Ballooning | off | off | off |
| Root disk | 150 GB on `rpool` | 80 GB on `rpool` | 64 GB on `rpool` |
| Second disk | — | **300 GB on `data`**, `backup=0` | — |

### CPU — the ratio survives, the numbers move

36 vCPU over 12 threads is 3:1 overcommit — the same ratio as 96-over-32, so the
original reasoning carries over unedited: three workloads that each spike hard
and briefly (CI compiles, ESPHome firmware builds, user load) and rarely spike
together. The configuration that actually degrades performance is a *single* VM
defined wider than the host, and 12 = 12 stays on the right side of that line.

`cpuunits` still arbitrates collisions and is unchanged, because it is a
**relative** weight — the ratios 100 / 50 / 200 mean exactly what they meant on
a 32-thread box.

### RAM — unchanged allocation, one new competitor

16 + 24 + 8 = 48 GB of 64 GB, ballooning off, exactly as before. What is new is
that **ZFS ARC now competes for the remainder**. Historically the ZFS default is
half of RAM — 32 GB here, against 48 GB of VMs — and while recent Proxmox
installers write a 10% limit for new installs, that is a reason to *verify* the
value rather than to assume it. It is set explicitly to **8 GB**, which leaves
roughly 48 + 8 + host ≈ 60 of 64 GB.

The consequence for the docs: the old "~12 GB left over is the growth pool"
sentence is no longer true. The leftover now buys the ARC, and growing a VM's
memory means taking it from the cache.

### Disk — 294 GB of ~460 on the root pool

`rpool` holds Proxmox plus 150 + 80 + 64 = **294 GB** of provisioned VM roots.
zvols are sparse, so real consumption sits far below that; the headroom matters
because ZFS snapshots live in the same pool.

- **infra stays at 150 GB.** Its reasoning is unchanged — Prometheus 15 d, Loki
  14 d, Tempo 7 d, Docker layers, and Forgejo's container registry, which gains
  an image per CI run and expires nothing until the CI roadmap says otherwise.
- **apps splits into 80 + 300.** The root disk carries the OS and Coolify
  itself; app volumes, databases, build cache and image layers — the part that
  actually grows — move to the `data` mirror. Coolify's installer requires 30 GB
  free, so 80 GB is comfortable for its own footprint.
- **home-assistant is unchanged at 64 GB.**

## Backups — two layers, two drives

### Layer 1 — `vzdump` to the `backup` mirror

The 1 TB mirror is deliberately **double** the 500 GB root pool, and that ratio
only holds if the backup set is the root pool. `vzdump` includes every VM disk
by default, so the apps VM's 300 GB data disk is marked **`backup=0`**:

- with it included: 294 + 300 = ~594 GB of source against 930 GB usable — one
  compressed copy, perhaps two, and no room for a retention policy;
- with it excluded: ~294 GB of source, zstd-compressed, which leaves genuine
  multi-copy retention on the same drive.

Nothing is lost by excluding it, because that disk *is* the container volumes —
which is exactly what layer 2 exists to cover.

### Layer 2 — restic to the USB drive, over SFTP

The roadmap's phase 2 asks for "a NAS or second disk first, so the mechanism gets
debugged without also debugging cloud credentials." The USB drive is that target.
Phase 3 (offsite) stays on the roadmap; this does not replace it.

**Transport: SFTP against the Proxmox host's existing sshd.** restic speaks SFTP
natively, so the drive is mounted on the hypervisor and both VMs reach it as
`sftp:backup@pve.thefipster.de:/restic`.

Three alternatives were considered:

| Option | Verdict |
|---|---|
| **SFTP over existing sshd** ✅ | No new daemon on a host this repo deliberately keeps free of workloads. A dedicated unprivileged `backup` user, key-only, one key per VM — so the apps VM joins later with no redesign. `ChrootDirectory` + `ForceCommand internal-sftp` confines it; the chroot directory must be root-owned and not group-writable, which is the usual thing to get wrong. |
| USB passthrough to the infra VM | Simplest — restic writes to a local path — but it binds the drive to one VM. The apps VM will need the same target once it runs real services, and re-sharing from a guest is worse than sharing from the host. Rejected on that basis. |
| NFS/SMB share from the host | Achieves the same reach, but adds a file server to the hypervisor and a network hop with its own failure modes. SFTP gets the identical result from a daemon that is already running. |

**The apps VM is a future consumer, not part of this change.** The transport was
chosen so that adding it later is a key and a `.env` value, not a redesign. The
roadmap still scopes its implementation to the infra VM.

Sizing: 500 GB against a backup set dominated by Forgejo's registry blobs, which
grow monotonically. restic's dedup absorbs repeated image layers well but cannot
delete what the registry never expires, so registry hygiene
([ci-supply-chain.md](../../roadmap/ci-supply-chain.md) phase 3) is also the
lever on whether this drive stays big enough.

## Monitoring the pools

Six drives in mirrors buy nothing if a failure is silent, and a **degraded mirror
is precisely the failure that takes nothing down** — the host stays up, the VMs
stay up, and nobody finds out.

**Mechanism: an Uptime Kuma push monitor.** Kuma has no exec monitor type, so it
cannot poll `zpool status` itself. Instead a systemd timer on the Proxmox host
evaluates pool health and calls Kuma's push URL:

- every row of `zpool list -H -o name,health` reads `ONLINE` → push `status=up`;
- anything else → push `status=down&msg=<pool> <state>`, so the pool name
  reaches the notification;
- the script or the host dies → nothing is pushed, and the monitor goes down as
  a plain deadman.

Two failure modes, one monitor. It inherits Kuma's already-configured ntfy
notification with no new alert rule and no new contact point — which is the
argument for putting the notification here rather than in Grafana, and it matches
the split the lab already runs on (Kuma notifies, Grafana explains). It is also
the same shape as the backup roadmap's phase 4 deadman.

The `usbbackup` pool is included, so the monitor also reports the backup target
falling off the bus — layer 2 silently writing nowhere is the failure the whole
roadmap exists to prevent.

### Why this does not reverse a documented decision

[uptime-kuma-monitors.md](../../uptime-kuma-monitors.md) lists the Proxmox host
under *Deliberately not monitored*, on the grounds that Kuma is a guest of the
hypervisor and any failure severe enough to take Proxmox down takes Kuma with
it. That reasoning is about **availability**, and it stays true. Pool health is a
**condition** check on a host that is still running, so the absence is scoped
rather than removed.

### Where the script lives

The Proxmox host has no checkout of this repo — the same reason its node exporter
is a documented `apt install` rather than an init script. The health script
follows that precedent: a fenced block in `proxmox-setup.md`, copied to
`/usr/local/bin` on the host. A `proxmox/` root directory was considered and
rejected as a larger structural change than one script justifies.

`zfs-zed` is the native alternative — it fires on the ZFS event rather than on a
poll, which is strictly better latency — but it needs a working outbound MTA, and
Proxmox's stock postfix only does local delivery. Kuma push is genuinely the
lower-effort path, so zed is documented as optional rather than primary. SMART
warns earlier still, before a disk is kicked from a pool; the same script can
carry it, and that is a follow-on rather than part of this change.

## Files changed

| File | Change |
|---|---|
| `README.md` | Architecture diagram, storage layout, status row |
| `docs/proxmox-setup.md` | ZFS install, pool creation, ARC cap, VM table, `vzdump` procedure, health script, "Why these sizes" rewrite, `lvs` → `zpool list` |
| `docs/roadmap/backup.md` | Named targets, SFTP transport, apps VM as future consumer, sizing |
| `docs/uptime-kuma-monitors.md` | The new row; the Proxmox absence scoped to availability |
| `docs/uptime-kuma-setup.md` | Step 7 — return to Part 10 once a push URL exists |
| `docs/grafana-setup.md` | What `DiskAlmostFull` can and cannot see under ZFS |
| `docs/home-assistant-setup.md` | `local-lvm` → `local-zfs`, 32 → 12 cores |
| `docs/coolify-setup.md` | Mount the data disk before the installer runs |

The dated specs and plans under `docs/superpowers/` keep their 32-thread
numbers. They are historical records of what was decided when, and retro-editing
them would destroy the only evidence that the assumption ever changed.

## Non-goals

- **Sizing the apps VM's backup job.** It has no services yet. The transport is
  chosen to accommodate it; the job is not written.
- **SMART monitoring.** Named as the natural follow-on, not built here.
- **A pool-capacity metric.** node_exporter's `zfs` collector exposes ARC stats
  and per-pool I/O, not capacity, so `DiskAlmostFull` cannot see a pool filling
  with zvols or snapshots. Documented as a known gap in `grafana-setup.md`, with
  a textfile-collector sketch; the alert rule itself is unchanged and correct.
- **Replacing offsite backup.** The USB drive is phase 2's local target. Phase 3
  stands.
- **A `proxmox/` directory in the repo root.** Considered, rejected; revisit if
  the hypervisor accumulates a third artifact.
