# Design: storage pools — all-flash, four mirrors, no external drive

**Date:** 2026-08-09
**Status:** approved

Re-cuts the hypervisor's storage for an inventory that changed underneath it:
ten drives available instead of seven, all of them flash, and no external drive
at all. Four pools remain — the same four jobs — but every one of them is now a
mirror, the two pools that carry random-access work move to NVMe, and the two
backup pools get names that say which layer they hold.

Supersedes the **storage** section of
[2026-07-31-hardware-specs-design.md](2026-07-31-hardware-specs-design.md).
That document is a historical record and is **not** retro-edited; this one states
what changed and why.

> That spec is stale on more than storage. It records `i5-12500HL` / 64 GB, while
> `README.md` records **`i5-10600K` · 12 threads · 96 GB** and the apps VM at
> 32 GB. The README is treated as current here, because the ARC decision below
> depends on the RAM figure. Correcting the CPU and RAM lines wherever they are
> still wrong is not this spec's job, and it is not in the change surface.

## What changed on the shelf

| | Before | Now |
|---|---|---|
| NVMe | 2 × 512 GB | **2 × 1 TB + 2 × 512 GB** |
| SATA SSD | 2 × 512 GB + 2 × 1 TB | **4 × 1 TB** |
| External | 1 × 1 TB USB 3.1 NVMe | **none** |
| Installed | 6 internal + 1 external | **8 internal** |

The board carries 4 × M.2 and 6 × SATA, all usable simultaneously — so ten
drives fit. Eight are installed. **The two 512 GB SATA SSDs are deliberately
left out of the machine**; see decision 4.

Every installed drive is flash. There is no spinning disk in the box and no
device on a removable bus.

## The pools

| Pool | Devices | Usable | Proxmox storage | Holds |
|---|---|---|---|---|
| `rpool` | 2 × 1 TB NVMe, mirror | ~930 GB | installer-created (boot pool) | Proxmox itself + all three VM **root** disks |
| `data` | 2 × 512 GB NVMe, mirror | ~465 GB | `zfspool`, content `images,rootdir` | the apps VM's second disk (`/data`, 300 GB) |
| `vmbackup` | 2 × 1 TB SATA SSD, mirror | ~930 GB | *Directory* on `/vmbackup`, `--is_mountpoint 1` | `vzdump` whole-VM archives — layer 1 |
| `filebackup` | 2 × 1 TB SATA SSD, mirror | ~930 GB | **none** — reached over SFTP | the restic repository — layer 2 |

Only `rpool` is created by the installer. The other three are `zpool create`
after first boot, unchanged in form from
[proxmox-setup.md Part 3](../../proxmox-setup.md#part-3--post-install-housekeeping)
— `-o ashift=12 -O compression=lz4`, devices named by `/dev/disk/by-id/`.

The storage *types* are unchanged and still not interchangeable: a pool
registered as `zfspool` accepts `images,rootdir` only and cannot hold `vzdump`
output, so `vmbackup` is a *Directory* on the pool's mountpoint while `data` is
an ordinary `zfspool`. Getting it backwards still produces a target that never
appears in the backup job's storage dropdown, with nothing to explain why.

## Decisions and why

### 1. NVMe takes the pools that seek; SATA takes the pools that stream

The assignment is by access pattern, not by size.

- **`rpool` and `data` carry every VM's live I/O** — three root filesystems, and
  on `data` the apps VM's Docker data-root, Coolify's store and whatever
  databases the third-party stacks run. That is the most random-access work in
  the lab, and it is the only work anyone waits on interactively. Both go on
  NVMe.
- **`vmbackup` and `filebackup` are written once a night, sequentially, and read
  during a restore.** SATA SSD is not the constraint there, and spending a PCIe
  slot on a nightly bulk write would be spending it in the wrong place.

`data` moving from SATA to NVMe is the one workload upgrade in this change; it
was on the slowest pool in the box while carrying the most seek-heavy job.

### 2. Every pool is a mirror

`usbbackup` was the only single-disk pool on the machine, and the
[2026-07-31 spec](2026-07-31-hardware-specs-design.md) defended it on the
grounds that a single-disk pool still *detects* corruption even though it cannot
repair it, and that an unimportable ZFS pool beats a hard `/etc/fstab` entry for
a device that might be absent at boot. Both arguments were sound and both are
now moot: the drive it defended is gone.

What replaces it is not a smaller compromise but the absence of one. The pool
holding **layer 2 — the granular, encrypted, per-stack restore path** — is now
the same shape as every other pool: two devices, self-healing, and answering the
same `zpool status` query the health monitor already runs.

### 3. `backup` → `vmbackup`, `usbbackup` → `filebackup`

`usbbackup` has to change regardless — it is neither USB nor external now, and a
name that describes a bus the pool no longer sits on is worse than no name.

The obvious replacement, `restic`, collides badly. The repository is reached
through a chroot, so the pool would mount at `/restic`, the chroot dataset would
be `/restic/chroot`, and the writable directory inside it `/restic/chroot/restic`
— while every client still addresses it as `/restic`, because inside a chroot the
chroot is the root. Two different `/restic` paths on two sides of the same
sentence is a trap in a document someone reads during an incident.

Renaming the sibling at the same time is the part that is optional, and it is
taken anyway. `backup` and `usbbackup` were never distinguishable by name — the
docs disambiguate them as "layer 1" and "layer 2" in prose every time they come
up, including in `CLAUDE.md`. `vmbackup` / `filebackup` says it in the name:
whole-VM archives against file-level snapshots. On a fresh build the rename costs
a `pvesm` storage ID and the vzdump job's target, both of which are typed once.

### 4. The 512 GB SATA pair leaves the machine

Ten drives make **five** matched mirror pairs. There are four jobs. One pair is
surplus by construction, and the smallest, slowest pair is the one to drop.

Inventing a fifth pool was considered and rejected. The capacity is not needed —
the lab's entire live footprint is 278 GB of VM roots plus a 300 GB data disk,
against ~1.4 TB of pool holding it and another ~1.9 TB of backup pool behind
that — and a pool with no workload is a pool that still has to be created,
monitored, scrubbed and reasoned about. This repo's own
argument against a `proxmox/` directory applies: a structure that exists to hold
one thing nobody needed.

**They cannot be ZFS hot spares either**, which is the other thing the pair looks
like it might be for. At 512 GB they cannot replace a member of `rpool`,
`vmbackup` or `filebackup`, so the only vdev they could ever replace into is
`data` — and only if the raw byte count is at least that of the NVMe member it
stands in for, which is a `blockdev --getsize64` check nobody will remember to
have run.

Installed-but-unpooled is the worst of the options: an unpooled drive does not
appear in `zpool status`, so it is invisible to the health monitor
([proxmox-setup.md Part 9](../../proxmox-setup.md#part-9--notice-when-a-mirror-degrades))
and can fail where nothing is watching. It would be found at replace time, which
is the one moment it is supposed to help.

So the pair comes out and is used elsewhere. **Two SATA ports are deliberately
left empty.** When they are filled, the drives should be **1 TB**, to match the
members of three of the four pools — at that size the pair is genuinely useful as
replacement stock, which is exactly what the 512s could not be.

### 5. The external drive is not replaced, and layer 3 is still layer 3

Losing the USB drive does not create urgency that did not already exist.
[roadmap/backup.md](../../roadmap/backup.md) is explicit that it never closed
phase 3: it was "the second copy, on the same premises and plugged into the
machine it protects", and carrying it elsewhere counted as a third copy only for
as long as someone actually did — a human step nothing could alert on.

`filebackup` inherits that role on better terms — mirrored rather than
single-disk, internal rather than on a removable bus — but **not on roomier
ones**. A single 1 TB disk becomes a ~930 GB mirror, so the repository has the
same space it always had. What it gains is the ability to survive the loss of a
drive; what it does not gain is runway.

That matters, because the one sizing pressure the roadmap names is unrelieved:
Forgejo's registry blobs grow monotonically, and restic's dedup absorbs repeated
image layers but cannot expire what the registry never expires. Registry hygiene
([ci-supply-chain.md](../../roadmap/ci-supply-chain.md) phase 3) is still the
only lever on it, and this change does not buy time on that clock.

> The repo currently disagrees with itself about the drive it is replacing.
> `README.md` calls it 1 TB; `proxmox-setup.md` and `roadmap/backup.md` call it
> 500 GB. The README matches the physical inventory, so 1 TB is the figure used
> here. The disagreement disappears with the pool and needs no separate fix.

**Offsite S3 is out of scope here** and stays roadmap phase 3. The choice between
`restic copy` into a second repository and `rclone sync` of this one is a real
decision with its own trade-off — an independent repo does not inherit local
corruption and can carry sparser offsite retention; a byte-level mirror is
cheaper and needs no second password — and it deserves its own spec. Nothing in
this layout constrains either.

### 6. `backup=0` on the apps data disk stays

Spinning disks were considered specifically to retire this flag: a 2 × 4 TB
IronWolf mirror would make `vmbackup` large enough to stop excluding the apps
VM's 300 GB second disk, closing the gap the roadmap names — that disk is
covered by **nothing** until the apps VM runs its own restic job.

Rejected on two grounds, and the second is the one that should survive.

- **Noise.** The machine lives in a shared space that is otherwise quiet, and
  every installed drive is currently flash. Adding the first moving part to a
  silent machine is a larger perceptual change than the datasheet suggests, and
  two mirrored drives vibrate in lockstep rather than averaging each other out.
- **The gap does not want 8 TB; it wants a `backup.sh`.** Most of that 300 GB is
  `/data/docker` — images, layers, volumes, build cache — which
  [the apps-VM storage spec](2026-08-08-apps-vm-storage-layout-design.md)
  already declares **deliberately disposable**. What actually needs protecting is
  `/data/coolify/` and `/data/<stack>/`, and that is small. The roadmap chose the
  SFTP transport precisely so the apps VM joins the repository with "a key and an
  `.env` value rather than a rethink". Solving it at layer 1 with more disk does
  loudly what layer 2 already has the machinery to do quietly.

If bulk capacity is ever wanted for a workload that actually exists, the answer
for this room is 4 TB SATA **SSDs** — several times the cost per terabyte, and
silent.

### 7. The ARC cap stays at 8 GB

It was chosen against 64 GB of RAM with 48 GB of VMs. The machine now has 96 GB
with 64 GB of VMs (24 + 32 + 8), so 32 GB is unspoken for and 16 GB would fit
comfortably.

Left at 8 GB anyway. Every pool is now flash, and ARC buys far less in front of
NVMe than it did in front of anything mechanical — this is a change to make on a
measurement, not on available headroom.

## What does not change

**Nothing functional on the infra VM.** `RESTIC_REPOSITORY` stays
`sftp:resticbackup@pve.thefipster.de:/restic`: inside the chroot the chroot is the
root, so the pool underneath is invisible to every client. Every
`infra/<stack>/backup.sh` and `restore.sh`, `infra/backup/run.sh`, the four
systemd units and the Kuma push are all untouched.

Also unchanged: VM sizing and vCPU/RAM allocation, the `zfspool` vs `dir`
distinction, `ashift=12`, `compression=lz4`, the vzdump retention policy on the
storage, and the health monitor's shape — it still watches exactly four pools,
two of which are spelled differently.

## Change surface

Docs, plus one comment. No script and no compose file changes.

| File | Change |
|---|---|
| `README.md` | topology block (drives, pool names), the Storage table, and the "every mirror answers a different question" paragraph |
| `docs/proxmox-setup.md` | Part 1 installer target is the **1 TB** NVMe pair; Part 3 three `zpool create` + two `pvesm add`; Part 8 vzdump target; Part 9 health-script `EXPECTED`; the layout and "why these sizes" sections |
| `docs/backup-setup.md` | Part 1 host-side paths — `/usbbackup/chroot` → `/filebackup/chroot`, and the prose naming the pool |
| `docs/roadmap/backup.md` | target names; the "only copy that can physically leave the building" claim, which is now false |
| `docs/uptime-kuma-monitors.md` | the ZFS-health monitor row |
| `docs/grafana-setup.md` | pool names in the capacity-metric prose |
| `infra/backup/.env.example` | the comment naming `usbbackup` |
| `CLAUDE.md` | the backup-convention paragraph naming `usbbackup`, and the storage line in Topology |

**Deliberately untouched:** every dated spec, plan and review under
`docs/superpowers/` and `docs/review/`. They are historical records, and
retro-editing them would destroy the only evidence that the inventory ever
changed.

## Non-goals

- **Offsite S3.** Roadmap phase 3, its own spec — see decision 5.
- **The apps VM joining the restic repository.** The right answer to the
  uncovered `/data`, and the reason no spinning disk is bought here. It is backup
  work, not pool work.
- **Growing the infra VM's 150 GB root.** Same deferral the apps-VM spec made:
  revisit against measured pool usage. `rpool` doubling makes it cheaper, not
  more urgent.
- **Correcting the CPU/RAM figures** wherever they still disagree with the
  README. Real, and a separate pass.
- **A fifth pool.** See decision 4.
