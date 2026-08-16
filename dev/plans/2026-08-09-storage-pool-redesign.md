# Storage Pool Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring every doc in the repo into line with the all-flash four-mirror
storage layout specified in
[2026-08-09-storage-pool-redesign-design.md](../specs/2026-08-09-storage-pool-redesign-design.md).

**Architecture:** Documentation only. No script, compose, or provisioning file
changes anywhere in the repo. Two pools are renamed (`backup` → `vmbackup`,
`usbbackup` → `filebackup`), one pool moves bus (`data`: SATA → NVMe), one pool
gains capacity (`rpool`: 2 × 500 GB → 2 × 1 TB), and one pool stops being a
single disk (`filebackup` is a mirror). Several claims that were true of the old
hardware are now false and need rewriting, not renaming — those are called out
per task and are the parts that need judgement.

**Tech Stack:** Markdown. Verification is `grep` plus reading; this repo has no
build, lint, or test system, and correctness is verified by reading
(`CLAUDE.md`).

## Global Constraints

- **Canonical pool names:** `rpool`, `data`, `vmbackup`, `filebackup`. No other
  spelling appears anywhere outside historical records.
- **Canonical device assignment:** `rpool` = 2 × 1 TB NVMe mirror; `data` =
  2 × 512 GB NVMe mirror; `vmbackup` = 2 × 1 TB SATA SSD mirror; `filebackup` =
  2 × 1 TB SATA SSD mirror.
- **Canonical capacity figures:** `rpool` ~930 GB usable, `data` ~465 GB usable,
  `vmbackup` ~930 GB usable, `filebackup` ~930 GB usable. VM roots total
  **278 GB** (150 infra + 64 apps + 64 home-assistant). Anywhere the current text
  says 294 GB, that is a stale figure from before the apps VM went 80 → 64 GB;
  correct it to 278 in passing.
- **Canonical mountpoints:** `/vmbackup` (Directory storage), `/filebackup`
  (chroot parent). `/opt/backup` on the **infra VM** is unrelated staging and
  must NOT be touched. `infra/backup/` as a repo path must NOT be touched.
  `backup-setup.md` and `roadmap/backup.md` as filenames must NOT be touched.
- **Eight drives installed, two SATA ports deliberately empty.** Ten fit. The
  2 × 512 GB SATA SSDs are out of the machine.
- **`RESTIC_REPOSITORY` does not change.** It stays
  `sftp:resticbackup@pve.thefipster.de:/restic` — the path is inside a chroot, so
  the pool beneath it is invisible to clients. Any edit that changes this value
  is wrong.
- **ARC stays at 16 GB** (`zfs_arc_max=17179869184`). It is already correct in
  `proxmox-setup.md`; do not touch it.
- **Never edit historical records:** everything under `docs/superpowers/` (except
  this plan's own checkboxes) and `docs/review/`. They record what was decided
  when.
- **Three claims are now FALSE and must be rewritten, not renamed:**
  1. *"`backup` is deliberately double the root pool"* — `vmbackup` and `rpool`
     are both ~930 GB. The ratio that matters is target vs. **source**
     (930 GB against 278 GB of roots), not target vs. pool.
  2. *"the only copy that can physically leave the building"* — nothing leaves
     the building now. Offsite is roadmap phase 3.
  3. *"the USB drive falling off the bus"* — there is no removable bus. The
     failure the expected-list check still catches is a pool that fails to
     import at all.
- **Line endings stay LF.** `.gitattributes` enforces it; do not let an editor
  rewrite them.

---

### Task 1: `docs/proxmox-setup.md` — the source of truth

This guide builds the pools, so every other file's wording follows from it. Do it
first.

**Files:**
- Modify: `docs/proxmox-setup.md` (Part 2 :41-50, Part 3 :138-219, Part 8
  :407-449, Part 9 :457-485, layout section :766-788)

**Interfaces:**
- Produces: the canonical `zpool create` invocations, the `pvesm` storage IDs
  (`vmbackup` as `dir` on `/vmbackup`; `data` unchanged as `zfspool`), the
  `EXPECTED` pool list, and the target-vs-source sizing argument that Tasks 3
  and 4 restate in shorter form.

- [ ] **Step 1: Part 2 — the installer targets the 1 TB NVMe pair**

Replace at `:41-50`:

```markdown
2. **Target disks** — select **both 1 TB NVMe drives**, then *Options* →
   Filesystem **`zfs (RAID1)`**. That mirrored pair becomes `rpool`: the
   hypervisor itself and every VM root disk. Leave `ashift` on its default (`12`,
   right for any modern drive).

   **Leave the other six drives untouched here** — the 512 GB NVMe pair and all
   four SATA SSDs. The installer only ever builds the boot pool; the other three
   mirrors are created by hand in
   [Part 3](#part-3--post-install-housekeeping), once there is a shell to do it
   from. Selecting them now would fold all eight drives into one pool and throw
   away the whole point of the split.
```

- [ ] **Step 2: Part 3 — the three hand-built pools**

Replace at `:138-156`:

```markdown
The first 1 TB SATA pair becomes `vmbackup`, the whole-VM archive target:

```bash
zpool create -o ashift=12 -O compression=lz4 vmbackup mirror /dev/disk/by-id/<sata-1tb-a> /dev/disk/by-id/<sata-1tb-b>
```

The second 1 TB SATA pair becomes `filebackup`, which holds the restic
repository — see [roadmap/backup.md](roadmap/backup.md):

```bash
zpool create -o ashift=12 -O compression=lz4 filebackup mirror /dev/disk/by-id/<sata-1tb-c> /dev/disk/by-id/<sata-1tb-d>
```

The 512 GB NVMe pair becomes `data`, which carries the apps VM's second disk:

```bash
zpool create -o ashift=12 -O compression=lz4 data mirror /dev/disk/by-id/<nvme-512g-a> /dev/disk/by-id/<nvme-512g-b>
```
```

- [ ] **Step 3: Part 3 — the wipefs note loses its USB drive**

At `:161-162`, replace `so expect it on the SATA pairs\nand the USB drive.` with:

```markdown
so expect it on all three
hand-built pairs.
```

- [ ] **Step 4: Part 3 — register the storages**

Replace at `:203`:

```bash
pvesm add dir vmbackup --path /vmbackup --content backup --is_mountpoint 1 --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=3
```

At `:212` replace `refuse the storage when `/backup` is` with
``refuse the storage when `/vmbackup` is``.

At `:217` replace ``` `usbbackup` gets **no `pvesm` entry at all**. ``` with
``` `filebackup` gets **no `pvesm` entry at all**. ```

Leave the `pvesm add zfspool data` line at `:199` exactly as it is — the pool
changed bus, not name or type.

- [ ] **Step 5: Part 8 — the sizing claim that is now false**

Replace at `:407-410`:

```markdown
The target is the `vmbackup` mirror from [Part 3](#part-3--post-install-housekeeping)
— **~930 GB against the 278 GB of VM roots it archives**, and on different
physical drives, which is the entire point. A backup on the disk it protects is
not a backup.

Roughly three times the source is what makes a retention policy possible instead
of a single copy. Note the ratio is target against **source**, not against
`rpool`: the two pools are now the same size, and what `vmbackup` has to hold is
the roots, not the pool they sit in.
```

- [ ] **Step 6: Part 8 — the storage row and the verification commands**

At `:416` replace `| Storage | `backup` |` with `| Storage | `vmbackup` |`.

At `:437` replace `ls -lh /backup/dump` with `ls -lh /vmbackup/dump`.

At `:441` replace `zfs list backup` with `zfs list vmbackup`.

At `:444` replace ``If `/backup/dump` is empty`` with
``If `/vmbackup/dump` is empty``.

At `:448` replace `That is what keeps a 1 TB target able` with
`That is what keeps a ~930 GB target able`.

- [ ] **Step 7: Part 9 — drive count and the expected-list reasoning**

At `:457` replace `Six drives in mirrors buy nothing` with
`Eight drives in four mirrors buy nothing`.

Replace at `:473-477`:

```markdown
Note that the health check walks an **expected list** of pools rather than
whatever `zpool list` happens to return, because a pool that failed to import
does not appear in that output at all. A mirror that loses one member degrades
and is still listed; a pool that loses both members, or whose controller drops,
is simply **absent** — and absence is exactly what a check that trusts
`zpool list` cannot see:
```

- [ ] **Step 8: Part 9 — the script's expected pool list**

At `:485` replace:

```bash
EXPECTED="rpool backup data usbbackup"
```

with:

```bash
EXPECTED="rpool vmbackup data filebackup"
```

This is the one functional line in the whole task. Everything else on this page
is prose.

- [ ] **Step 9: the layout section**

Replace the heading at `:766` and the table and prose at `:768-788`:

```markdown
### Why the drives are split four ways

| Pool | Devices | Holds |
|---|---|---|
| `rpool` | 2 × 1 TB NVMe, mirror | Proxmox + all three VM **root** disks |
| `data` | 2 × 512 GB NVMe, mirror | the apps VM's second disk |
| `vmbackup` | 2 × 1 TB SATA SSD, mirror | `vzdump` archives — [Part 8](#part-8--schedule-whole-vm-backups) |
| `filebackup` | 2 × 1 TB SATA SSD, mirror | restic repository — [roadmap/backup.md](roadmap/backup.md) |

**Every mirror answers a different question, and the bus follows the access
pattern.** `rpool` and `data` are NVMe because they carry live VM I/O — three
root filesystems, plus the apps VM's Docker data-root and Coolify's store, which
is the most seek-heavy work in the lab and the only work anyone waits on
interactively. `vmbackup` and `filebackup` are written once a night and read
during a restore, so SATA SSD costs them nothing.

`vmbackup` holds only the **278 GB** of VM roots, because the apps VM's data
disk is excluded with `backup=0`. ~930 GB against 278 GB of source is several
compressed generations with room to spare, which is what retention needs;
include that disk and it collapses to one archive with nowhere to keep
yesterday's.

`filebackup` is the same size as the single drive it replaced, and that is worth
stating plainly rather than glossing: it gained a mirror, not runway. Forgejo's
registry blobs grow monotonically and restic cannot expire what the registry
never expires, so registry hygiene remains the only lever on that number.

278 GB of roots on ~930 GB usable leaves real headroom, and it needs to: zvols
are sparse so actual consumption is far lower, but **ZFS snapshots live in the
same pool as the disk they snapshot**. Every `clean-install` snapshot you keep is
charged to `rpool`, not to a backup mirror.

**Two SATA ports are deliberately empty.** The board fits ten drives; eight are
installed. Whatever fills those ports should be a **1 TB** pair, which is the
size that can stand in for a member of three of the four pools — a smaller pair
could only ever replace into `data`.

Treat all of it as a starting point. The reasoning above is the part meant to
survive.
```

- [ ] **Step 10: Verify no stale pool references remain in this file**

Run:

```bash
grep -nE 'usbbackup|500 GB|`backup`|/backup/|zfs list backup|Six drives' docs/proxmox-setup.md
```

Expected: **no output**. Any hit is a site this task missed.

- [ ] **Step 11: Verify the untouchables survived**

Run:

```bash
grep -nE 'zfs_arc_max=17179869184|pvesm add zfspool data|roadmap/backup.md|backup-setup.md' docs/proxmox-setup.md | head -20
```

Expected: the ARC line, the unchanged `data` registration, and the intact
filename links are all still present.

- [ ] **Step 12: Commit**

```bash
git add docs/proxmox-setup.md
git commit -m "docs(proxmox): four all-flash mirrors, vmbackup and filebackup"
```

---

### Task 2: `docs/backup-setup.md` + `infra/backup/.env.example` — where layer 2 lives

These change together: both describe the pool the restic repository sits on, and
one of them is the only non-Markdown file in the change surface.

**Files:**
- Modify: `docs/backup-setup.md` (:18, :52, :65, :69, :75, :79, :100, :152,
  :208, :775-779, :804)
- Modify: `infra/backup/.env.example` (:23)

**Interfaces:**
- Consumes: the pool name `filebackup` established in Task 1.
- Produces: the host-side chroot path `/filebackup/chroot`, which nothing else
  references.

- [ ] **Step 1: The prose naming the pool**

At `:18-19` replace ``the repository is the **`usbbackup`\npool** on the hypervisor`` with
``the repository is the **`filebackup`\npool** on the hypervisor``.

At `:52` replace ``one thing — SFTP into a directory on the `usbbackup` pool —`` with
``one thing — SFTP into a directory on the `filebackup` pool —``.

- [ ] **Step 2: The chroot commands**

At `:65` replace `zfs create usbbackup/chroot` with `zfs create filebackup/chroot`.

At `:69` replace:

```bash
chown root:root /usbbackup/chroot && chmod 755 /usbbackup/chroot
```

with:

```bash
chown root:root /filebackup/chroot && chmod 755 /filebackup/chroot
```

At `:75` replace:

```bash
useradd --system --home-dir /filebackup/chroot --shell /usr/sbin/nologin resticbackup
```

At `:79` replace:

```bash
mkdir -p /filebackup/chroot/restic && chown resticbackup:resticbackup /filebackup/chroot/restic && chmod 700 /filebackup/chroot/restic
```

- [ ] **Step 3: The chroot explanation and the sshd block**

At `:99-100` replace ``the repository path is `/restic` and not\n`/usbbackup/chroot/restic``` with
``the repository path is `/restic` and not\n`/filebackup/chroot/restic```.

At `:152` replace `    ChrootDirectory /usbbackup/chroot` with
`    ChrootDirectory /filebackup/chroot`.

At `:208` replace ``Expected: `chrootdirectory /usbbackup/chroot```` with
``Expected: `chrootdirectory /filebackup/chroot````.

At `:804` replace `| The repository itself | `/usbbackup/chroot/restic` on the Proxmox host |`
with `| The repository itself | `/filebackup/chroot/restic` on the Proxmox host |`.

- [ ] **Step 4: The troubleshooting paragraph that assumed a USB bus**

Replace at `:775-779`:

```markdown
When it does fail, suspect the drive before the job. Check pool health on the
hypervisor first (`zpool status filebackup`); the **Hypervisor Storage** monitor
covers `filebackup` by name precisely because a pool that failed to import does
not appear in `zpool list` at all — so that monitor, not this one, is what
catches the storage-side cause. A mirror losing one member degrades and keeps
serving, which is the case you want to hear about *before* it becomes the case
where restic has nowhere to write.
```

- [ ] **Step 5: The `.env.example` comment**

In `infra/backup/.env.example` at `:22-23` replace ``/restic\n# is inside the `resticbackup` user's chroot, on the usbbackup pool.`` with:

```
# The restic repository: SFTP against the Proxmox host's existing sshd. /restic
# is inside the `resticbackup` user's chroot, on the filebackup pool. Setting it
```

**Do not touch the `RESTIC_REPOSITORY=` line below it.** Its value is unchanged.

- [ ] **Step 6: Verify**

Run:

```bash
grep -n 'usbbackup' docs/backup-setup.md infra/backup/.env.example
```

Expected: **no output**.

Run:

```bash
grep -n 'RESTIC_REPOSITORY=' infra/backup/.env.example
```

Expected: `RESTIC_REPOSITORY=sftp:resticbackup@pve.thefipster.de:/restic` —
unchanged. If this line differs, revert it.

Run:

```bash
grep -c '/opt/backup' docs/backup-setup.md
```

Expected: a non-zero count, unchanged from before this task. `/opt/backup` is
infra VM staging and must survive.

- [ ] **Step 7: Commit**

```bash
git add docs/backup-setup.md infra/backup/.env.example
git commit -m "docs(backup): layer 2 lives on the filebackup mirror"
```

---

### Task 3: `README.md` + `CLAUDE.md` — the top-level summaries

**Files:**
- Modify: `README.md` (:29-32, :74, :76-81, :83-87, :89-94, :96-101)
- Modify: `CLAUDE.md` (:315)

**Interfaces:**
- Consumes: pool names, device assignment and the target-vs-source argument from
  Task 1.

- [ ] **Step 1: The topology block**

Replace at `:29-32`:

```
    │  rpool      2×1 TB   NVMe mirror  → Proxmox + VM root disks
    │  data       2×512 GB NVMe mirror  → the apps VM's second disk
    │  vmbackup   2×1 TB   SATA mirror  → vzdump whole-VM archives
    │  filebackup 2×1 TB   SATA mirror  → restic file-level backups
```

- [ ] **Step 2: The Storage section headline**

Replace at `:74`:

```markdown
Eight internal drives paired into **four ZFS mirrors**. All flash, nothing
external, and two SATA ports left deliberately empty.
```

- [ ] **Step 3: The Storage table**

Replace at `:76-81`:

```markdown
| Pool | Devices                 | Proxmox storage | Holds |
|------|-------------------------|-----------------|-------|
| `rpool` | 2 × 1 TB NVMe, mirror | installer-created (boot pool) | Proxmox itself + all three VM **root** disks |
| `vmbackup` | 2 × 1 TB SATA SSD, mirror | *Directory* on `/vmbackup`, `--is_mountpoint 1` | `vzdump` whole-VM archives — layer 1 |
| `data` | 2 × 512 GB NVMe, mirror | `zfspool`, content `images,rootdir` | the apps VM's second disk (`/data`, 300 GB) |
| `filebackup` | 2 × 1 TB SATA SSD, mirror | **none** — reached over SFTP, not by Proxmox | the `restic` repository — layer 2 |
```

- [ ] **Step 4: The storage-types paragraph**

At `:85-86` replace ``mirror is a *Directory* on the pool's mountpoint instead. `usbbackup` gets no\nProxmox entry at all`` with:

```markdown
mirror is a *Directory* on the pool's mountpoint instead. `filebackup` gets no
Proxmox entry at all
```

- [ ] **Step 5: The "every mirror answers a different question" paragraph**

Replace at `:89-94`:

```markdown
Every mirror answers a different question, which is why they are not one big pool,
and the bus follows the access pattern: `rpool` and `data` are NVMe because they
carry live VM I/O — root filesystems, Coolify's store, Docker's data-root — while
`vmbackup` and `filebackup` are written once a night and read during a restore, so
SATA SSD costs them nothing. `vmbackup` is ~930 GB against the 278 GB of VM roots
it archives, and that target-to-source ratio is what makes a retention policy
possible instead of a single copy.
```

- [ ] **Step 6: The paragraph about the drive that no longer exists**

Replace at `:96-101`:

```markdown
`filebackup` holds the file-level `restic` repository, reached over SFTP so both
VMs can write to it. The infra VM's half is built in
[docs/backup-setup.md](docs/backup-setup.md); the apps VM has **not** joined the
repository yet, which is why its 300 GB data disk is still covered by nothing
([docs/roadmap/backup.md](docs/roadmap/backup.md)).

**Nothing here is offsite.** Both backup layers live in the same box as the thing
they protect, so a fire or a theft takes all three copies. Offsite is phase 3 of
[docs/roadmap/backup.md](docs/roadmap/backup.md) and is not built.
```

- [ ] **Step 7: `CLAUDE.md`**

At `:315` replace ``hypervisor's own `sshd`, into a chroot on the `usbbackup` pool.`` with
``hypervisor's own `sshd`, into a chroot on the `filebackup` pool.``

Leave `:323` (`VM's 300 GB data disk is covered by nothing…`) exactly as it is —
that gap is unchanged by this work and the sentence is still true.

- [ ] **Step 8: Verify**

Run:

```bash
grep -nE 'usbbackup|500 GB|Six internal|three ZFS mirrors|external' README.md CLAUDE.md
```

Expected: **no output**. `external: true` in `CLAUDE.md` refers to the Docker
`proxy` network — if that is the only hit, it is correct and should stay; confirm
by reading the matched line before dismissing it.

- [ ] **Step 9: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: README and CLAUDE.md describe the four all-flash mirrors"
```

---

### Task 4: the three downstream references

`roadmap/backup.md` carries the most rewriting here, because two of its load-
bearing claims were about the external drive specifically.

**Files:**
- Modify: `docs/roadmap/backup.md` (:140-151, :173-181, :206-210, :212-218, :258,
  :382-390)
- Modify: `docs/uptime-kuma-monitors.md` (:257-261)
- Modify: `docs/grafana-setup.md` (:338-339, :466-467, :523, :586-587)

**Interfaces:**
- Consumes: pool names and the target-vs-source argument from Task 1; the
  `filebackup` framing from Task 2.

- [ ] **Step 1: `roadmap/backup.md` — layer 1's target**

At `:141-145` replace ``a nightly job onto the `backup` mirror, which is dedicated 1 TB on different\nphysical drives, deliberately double the 500 GB root pool so retention is\npossible rather than a single copy.`` with:

```markdown
a nightly job onto the `vmbackup` mirror — ~930 GB on different physical drives,
against the 278 GB of VM roots it archives, so retention is possible rather than
a single copy.
```

- [ ] **Step 2: `roadmap/backup.md` — layer 2's target**

At `:150-151` replace ``Its target is the **external 500 GB USB\nNVMe** — see [Where layer 2 writes](#where-layer-2-writes).`` with:

```markdown
Its target is the **`filebackup` mirror** — see
[Where layer 2 writes](#where-layer-2-writes).
```

- [ ] **Step 3: `roadmap/backup.md` — the "Where layer 2 writes" opening**

Replace at `:175-181`:

```markdown
The target is the **`filebackup` pool** — 2 × 1 TB SATA SSD, mirrored — created
on the Proxmox host in
[proxmox-setup.md Part 3](../proxmox-setup.md#part-3--post-install-housekeeping).
It replaces the external USB drive the earlier hardware had, and it is a strict
improvement in every respect but one: mirrored rather than single-disk, so it can
repair corruption instead of merely detecting it, and internal rather than on a
bus a device can drop off.

**The exception is the one that matters for this phase.** The USB drive could be
unplugged and carried somewhere; `filebackup` cannot. Phase 3 is therefore not
merely still open, it is the *only* remaining path to a copy that survives the
building — see [phase 3](#phases) below.
```

- [ ] **Step 4: `roadmap/backup.md` — sizing**

Replace at `:206-210`:

```markdown
**Sizing.** ~930 GB against a set dominated by Forgejo's registry blobs, which
grow monotonically. That is the same space the drive it replaced had, so this
change bought redundancy and **not** runway. restic's dedup absorbs repeated
image layers well but cannot delete what the registry never expires — so the
registry-hygiene item in [ci-supply-chain.md](ci-supply-chain.md) phase 3 is
still the only real lever on whether this pool stays big enough.
```

- [ ] **Step 5: `roadmap/backup.md` — the obligation paragraph is a NO-OP, confirm it**

The paragraph at `:212-218` names no pool — it refers only to the Proxmox flag
`backup=0`, which is an option name and must NOT be renamed. **Make no edit
here.** This step exists because the paragraph looks like a rename site and is
not.

Run:

```bash
sed -n '212,218p' docs/roadmap/backup.md | grep -n 'backup'
```

Expected: hits on `backup=0` and on `restic job` prose only — no bare pool name.
If a previous step renamed `backup=0` to `vmbackup=0`, revert it: that flag is
Proxmox's, not ours.

- [ ] **Step 6: `roadmap/backup.md` — the architecture diagram**

This is box-drawing ASCII art; keep the leading `        │     ` padding exactly
as it is or the diagram shears. Replace the three lines at `:255`, `:256` and
`:258` in place:

```
        │     infra + apps + HA roots ──► `vmbackup` pool ──► "the VM is gone" restore
        │        (2×1 TB SATA SSD mirror, ~3× the archived roots, retention on the storage)
```

```
        └─ `filebackup` pool (2×1 TB SATA SSD mirror), served over SFTP by the host's sshd
```

Line `:257` (`Proxmox │`) sits between them and is unchanged.

- [ ] **Step 7: `roadmap/backup.md` — phase 3**

Replace at `:386-390`:

```markdown
   true rather than aspirational. **Nothing on the box closes this phase:** both
   layers now live in the same machine as the thing they protect, so a fire or a
   theft takes every copy at once. The external drive that used to offer a
   manual third copy is gone, and it was never a reliable one — it counted only
   for as long as someone actually carried it somewhere, and nothing could alert
   on a human step that didn't happen. An S3 target has no such failure mode.
```

- [ ] **Step 8: `uptime-kuma-monitors.md`**

Replace at `:257-261`:

```markdown
The push carries the pool name, so a `down` here names the pool to look at
rather than sending you to the shell to find out. It covers all four pools, and
it checks an **expected list** rather than trusting `zpool list`: a pool that
failed to import does not appear in that output at all, so its absence is
invisible to anything that reads the output alone.
```

- [ ] **Step 9: `grafana-setup.md`**

At `:338-339` replace ``the three pools mounted at `/backup`,\n`/data` and `/usbbackup``` with:

```markdown
> the three pools mounted at `/vmbackup`,
> `/data` and `/filebackup`
```

At `:466-467` replace the two table rows with:

```markdown
| `/vmbackup` on the host | holds `vzdump` **files**, so used grows and avail shrinks together |
| `/filebackup` on the host | same — restic writes files |
```

At `:523` replace `Expect four series each — `rpool`, `backup`, `data`, `usbbackup`. The number that`
with `Expect four series each — `rpool`, `vmbackup`, `data`, `filebackup`. The number that`.

At `:586-587` replace ``returns four series (`rpool`, `backup`, `data`,\n      `usbbackup`)`` with:

```markdown
- [ ] `zfs_pool_allocated_bytes` returns four series (`rpool`, `vmbackup`, `data`,
      `filebackup`)
```

- [ ] **Step 10: Verify**

Run:

```bash
grep -nE 'usbbackup|500 GB USB|external 500|`backup` pool|/usbbackup' docs/roadmap/backup.md docs/uptime-kuma-monitors.md docs/grafana-setup.md
```

Expected: **no output**.

Run:

```bash
grep -n 'backup=0' docs/roadmap/backup.md
```

Expected: still present. The Proxmox flag is not renamed.

- [ ] **Step 11: Commit**

```bash
git add docs/roadmap/backup.md docs/uptime-kuma-monitors.md docs/grafana-setup.md
git commit -m "docs: roadmap, monitors and Grafana follow the pool rename"
```

---

### Task 5: repo-wide consistency gate

Nothing here edits by default. This task exists because a cross-file sweep cannot
run until every file is done, and because the two exclusion rules (historical
records, `/opt/backup`) are easy to violate with a careless `sed`.

**Files:**
- Modify: only whatever the sweep turns up.

- [ ] **Step 1: No live document still says `usbbackup`**

Run:

```bash
grep -rn 'usbbackup' --include='*.md' --include='*.example' --include='*.sh' --include='*.yaml' . | grep -v 'docs/superpowers/' | grep -v 'docs/review/'
```

Expected: **no output**. Hits under `docs/superpowers/` and `docs/review/` are
historical records and must be left alone — that is what the two filters are for.

- [ ] **Step 2: No live document still calls a pool `backup`**

The word "backup" is everywhere in this repo legitimately, so search for the
shapes that can only be the old pool name:

```bash
grep -rnE 'zfs list backup|zpool (status|list) backup\b|/backup/dump|--path /backup\b|pool `backup`|`backup` (pool|mirror)' --include='*.md' --include='*.sh' . | grep -v 'docs/superpowers/' | grep -v 'docs/review/'
```

Expected: **no output**. Every one of those patterns is unambiguous — none of
them can match `/opt/backup`, `infra/backup/`, `backup-setup.md`, or the
`backup=0` flag.

- [ ] **Step 3: The infra VM's staging directory is untouched**

`/opt/backup` is the infra VM's dump staging area and has nothing to do with any
pool. Compare this branch against `main`:

```bash
git diff main -- docs/ infra/ | grep -E '^[+-].*(/opt/backup|infra/backup/)' | sort | uniq -c
```

Expected: any `-` line has a matching `+` line with the same path — i.e. the path
survived whatever else changed on that line. A `-` with no `+` counterpart means
a rename went too wide; restore it.

- [ ] **Step 4: The restic repository value never moved**

Run:

```bash
git diff main -- infra/backup/.env.example | grep '^[+-]RESTIC_REPOSITORY'
```

Expected: **no output**. If this line appears in the diff at all, the value was
changed and must be reverted to
`sftp:resticbackup@pve.thefipster.de:/restic`.

- [ ] **Step 5: No script, compose or provisioning file changed**

Run:

```bash
git diff --name-only main | grep -vE '\.md$|\.env\.example$'
```

Expected: **no output**. This change surface is documentation plus one comment.
Anything else means the edit went somewhere it should not have.

- [ ] **Step 6: The capacity figures agree across files**

Run:

```bash
grep -rn '294 GB' --include='*.md' . | grep -v 'docs/superpowers/' | grep -v 'docs/review/'
```

Expected: **no output** — 294 GB is the pre-apps-VM-resize figure and every live
mention should now read 278 GB.

- [ ] **Step 7: Read the two guides end to end**

Read `docs/proxmox-setup.md` Parts 2, 3, 8 and 9 straight through, then
`docs/backup-setup.md` Part 1. You are looking for sentences that are
individually correct but no longer follow from each other — a paragraph that
still argues from six drives, a ratio that no longer holds, a "the external
drive" that survived a targeted grep because it never said `usbbackup`. This is
the check that greps cannot do, and it is the one that matters most in a repo
whose correctness is verified by reading.

- [ ] **Step 8: Commit anything the sweep turned up**

```bash
git add -A
git commit -m "docs: consistency sweep after the pool rename"
```

If the sweep found nothing, skip the commit and say so.

---

## Verification

The whole change is verified by three properties:

1. `grep -rn 'usbbackup'` returns hits only under `docs/superpowers/` and
   `docs/review/`.
2. `git diff --name-only main` lists only `.md` files plus
   `infra/backup/.env.example`.
3. `docs/proxmox-setup.md` reads as a coherent from-scratch bring-up of an
   eight-drive all-flash machine, with no sentence that only made sense when one
   pool was a single USB disk.

There is nothing to execute. The pools themselves are built by following the
guide on the hypervisor, which is out of scope for this plan — the plan makes
the guide correct, not the machine.
