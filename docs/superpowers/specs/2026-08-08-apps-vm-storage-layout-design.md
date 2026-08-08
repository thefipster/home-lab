# Design: apps VM storage layout — Docker's data-root onto the `data` mirror

**Date:** 2026-08-08
**Resolves:** [review/2026-08-02-fresh-playthrough-review.md](../../review/2026-08-02-fresh-playthrough-review.md)
finding **1a**, and its action item at the foot of that document.
**Scope:** the apps VM's two disks — where Docker writes, and how big the root
disk has to be as a result.

Three places in this repo assign the apps VM's growth to the 300 GB `data`
mirror. Nothing made that happen: Coolify's installer brings up the Engine with
the default `/var/lib/docker`, on the root disk. `/data` received only Coolify's
own store and the bind mounts under it, while images, layers, named volumes and
build cache — most of "the part that actually grows" — landed on the disk sized
as "roomy for the OS and Coolify".

This spec makes the claim true rather than softening it, and takes the root disk
*down* as a consequence.

## What this delivers

1. `scripts/init-coolify.sh` writes `/etc/docker/daemon.json` with
   `{"data-root": "/data/docker"}` **before** it runs Coolify's installer, so no
   Engine ever starts with the default location.
2. The apps VM's root disk drops from **80 GB to 64 GB**.
3. `/data/docker` is recorded as the one directory on that disk which is
   deliberately disposable, so the roadmapped file-level backup for this VM does
   not walk into it.

Nominal allocation on `rpool` therefore falls from **294 GB to 278 GB** — about
60% of the ~460 GB usable. This change *frees* pool headroom.

## Deliberately not in scope

- **The infra VM stays at 150 GB.** It was considered at 200. Rejected for now
  on the grounds that its bounded consumers (OS, Prometheus 15 d, Loki 14 d,
  Tempo 7 d, its own Docker layers, restic's cache under `/root/.cache/restic`,
  the dump staging in `/opt/backup`) come to roughly 60–70 GB, and everything
  above that is registry runway rather than a requirement. It is also the
  cheapest disk on the box to revisit — ext4-on-zvol, growable online — so the
  decision is deferred to **measurement against real pool usage** at the time it
  bites, not settled by argument now.
- **The home-assistant VM stays at 64 GB.** Evidence from a decade-old
  installation puts real usage under 40 GB, so 64 is generous. Kept anyway: this
  is the one disk here that is genuinely awkward to grow, because HAOS expands
  its data partition on first boot and a later resize means hand-expanding a
  partition rather than the `growpart` one-liner every other VM gets
  ([home-assistant-setup.md](../../home-assistant-setup.md)). Headroom on the
  smallest VM is cheap insurance against the only resize on the box that is not
  trivial.
- **The backup set is unchanged.** Removing Forgejo's registry blobs from it was
  considered and deferred; the reasoning is recorded below because the
  conclusion should survive, not because anything is built here.
- **Registry retention** remains the [ci-supply-chain.md](../../roadmap/ci-supply-chain.md)
  phase-3 item it already is.

## Decisions and why

### 1. The data-root moves, rather than the claims being softened

Finding 1a offered both. Moving it is the option that matches arithmetic the
repo already commits to — an 80 GB root is only "roomy" if layers live
elsewhere — and it puts rebuildable data on the disk carrying `backup=0`, which
is what that flag is for. Image layers stop riding in every nightly `vzdump`,
which is the same "don't back up what CI can re-emit" argument applied at layer
1, where it costs nothing to implement.

A second benefit is accidental and worth keeping: `/data` is a real filesystem
(ext4 straight on the device, no partition table), so `node_filesystem_*` and
the `DiskAlmostFull` alert begin covering Docker's growth. Under the old layout
that growth was on the root disk and *was* visible; the risk being avoided here
is moving it somewhere invisible. It is not — `/data` is scraped.

### 2. 64 GB, and why the floor is not the OS

With the data-root on `/data`, the root disk carries the OS, a 4 GB swapfile and
Coolify's own binaries — nothing that grows. The binding constraint is the
**30 GB-free check, which runs twice**: once in
[`scripts/init-coolify.sh`](../../../scripts/init-coolify.sh) so the failure
names its cause before anything is downloaded, and again inside Coolify's own
installer — the second time *after* the swapfile exists.

10 GB of Ubuntu plus 4 GB of swap plus 30 GB free is 44 GB. **A 40 GB root disk
therefore fails a check that has nothing to do with the OS fitting**, which is
the trap in this whole exercise: 40 looks like the obvious number. 48 GB is the
smallest figure that passes with margin; **64 GB is chosen** to leave room for
journald, the apt cache and an OS that grows, at a cost of 16 GB on a pool that
is 40% empty.

### 3. `init-coolify.sh` owns the file, with three guards

The alternative was a hand step in `apps-vm-setup.md`, right where the disk is
mounted. Scripting it wins because the ordering constraint — before any Engine's
first start — is then *enforced* rather than documented, and because a rebuild
re-establishes it without anyone re-reading a guide. It is also the same category
as the swapfile that script already creates: preparing this box for Coolify.

Writing the file before Docker exists is the cleanest possible ordering. There is
no live data-root to move, which is the failure mode
[apps-vm-setup.md](../../apps-vm-setup.md) already names for `/data/coolify`.

Three guards, each for a reachable case:

- **Refuse if `/data` is not a mountpoint.** Writing the data-root onto a `/data`
  directory that lives on the root filesystem would silently reproduce the exact
  bug this change fixes.
- **If an Engine is already running with a populated `/var/lib/docker`, warn and
  skip.** The Engine check in this script is deliberately soft, because a missing
  Engine is normal on a first run — so an existing one is reachable, and
  switching the data-root under it orphans everything it holds.
- **Merge, do not overwrite,** if `daemon.json` already exists with other keys.

### 4. Forgejo's registry blobs stay in the backup

The instinct — packages are recoverable by rebuilding, so they need not be backed
up — is right about their value and aimed at the wrong pressure point. The blobs
barely threaten the infra VM's disk. They threaten the **restic repository**,
which lives on `usbbackup`: a single 500 GB USB drive, the smallest pool on the
box and the only unmirrored one.

Three things make exclusion worse than it looks, and all three should survive
this spec:

- **It is all-or-nothing.** Forgejo keeps every package type in one
  content-addressed blob store under `APP_DATA_PATH`, so the firmware `.bin`s and
  the container images cannot be separated by path — they are interleaved by hash.
- **It de-synchronises the database.** The metadata lives in Postgres, which is
  still dumped. Excluding the blobs produces a restored Forgejo whose Packages
  tab lists versions that 404 on pull — the failure
  [`infra/forgejo/backup.sh`](../../../infra/forgejo/backup.sh) already names as
  *a registry that lists images it cannot serve*. Coolify pulling from it gets
  `blob unknown` rather than a clean miss, mid-restore.
- **It costs new machinery.** `infra/backup/run.sh` passes only `--files-from`,
  so an exclusion needs an `exclude` recipe in `lib.sh` plus a restore step that
  deletes every package version through Forgejo's API before builds are
  re-dispatched. Two new moving parts in the path walked during an incident.

**Bounding the registry at the source solves the growth without any of that**,
which is why the roadmap item stays where it is.

### 5. What "rebuildable" actually buys

Recorded because it was asked directly, and because it qualifies decision 4.

A rebuild from a release tag is **already implemented**:
[`infra/forgejo/release.yml`](../../../infra/forgejo/release.yml) takes release
tags as its input, validates them, POSTs `mirror-sync`, polls `git ls-remote`
until those refs land, and builds from them. Recovery needs no new workflow.

What survives such a rebuild: the source tree, and
`org.opencontainers.image.revision` — because that label comes from
`git rev-parse HEAD` *after* checking out the tag rather than from
`github.sha`. What does not:

- **Base images are mutable tags.** `node:24-bookworm` is not today what it was
  six months ago. This follows directly from the repo's major-only pin policy and
  is the largest source of drift.
- **Image digests always differ**, even with byte-identical file contents, because
  layer mtimes and the config's `created` timestamp are baked in.
- **Dependency resolution**, wherever a lockfile is not committed or a
  `lib_deps` entry is unpinned.

So a rebuilt `blazor-v1.2.3` is *a* build of that commit — functionally
equivalent, not the artifact that was lost. Correct trade for this lab; chasing
bit-reproducibility would mean pinning base images by digest, which is a policy
this repo deliberately does not have.

**One consequence for whenever recovery-by-re-dispatch is written down:**
`release.yml` publishes `latest`, `X.Y.Z`, `X.Y` and `X` with no
highest-version guard — accepted, because a hand-cut release is always the
newest. Recovering *several* lost releases makes ordering matter: rebuild in
ascending version order, or `latest` ends up pointing at whichever ran last.

### 6. `/data` now holds two backup fates, and that must be stated

After this change the data disk holds three things:

| Path | Fate |
|---|---|
| `/data/coolify/` | back up — nothing under it is reproducible from this repo |
| `/data/<stack>/` | back up — third-party app state, bind-mounted on purpose |
| `/data/docker/` | **deliberately disposable** — images, layers, volumes, build cache |

Without the third row written down, the roadmapped file-level backup job for the
apps VM would walk `/data` and sweep in every image layer — re-creating, one
layer down, the unbounded-blob problem decision 4 declines to solve by exclusion.

## Change surface

**Script — one:**

| File | Change |
|---|---|
| `scripts/init-coolify.sh` | new step between the swapfile and the installer: write/merge `/etc/docker/daemon.json` with `data-root`, under the three guards above |

**Docs — "80 → 64" and "the layer claim is now true":**

| File | Change |
|---|---|
| `README.md:43` | `80 GB` → `64 GB` in the topology block |
| `README.md:91` | `data` absorbs the growth — keep as written; it now describes reality |
| `docs/proxmox-setup.md:285` | root disk `80 GB` → `64 GB` |
| `docs/proxmox-setup.md:314` | claim becomes true as written — keep |
| `docs/proxmox-setup.md:739` | rewrite the apps sizing paragraph: the floor is the twice-run 30 GB-free check, not the OS; state that 40 GB fails it |
| `docs/apps-vm-setup.md:88` | `80 GB root` → `64 GB` |
| `docs/apps-vm-setup.md:127` | the `df -h /data` verification, and the checklist item at :140 — "not 80" → "not 64" |
| `docs/coolify-setup.md:32` | the `init-coolify.sh` summary gains the data-root step |
| `docs/coolify-setup.md:226` | layout table gains a `/data/docker` row; the "what to back up" paragraph below it gains the disposable-directory sentence |

**Deliberately untouched:**

- [review/2026-08-02-fresh-playthrough-review.md](../../review/2026-08-02-fresh-playthrough-review.md) —
  a historical record. Finding 1a stays as written even though this resolves it.
- `apps/stacks/README.md` — its "bind mounts, never named volumes" rule rests on
  *a backup job needs a walkable path*, which the move does not affect. Named
  volumes land at `/data/docker/volumes/…` and are still not that.
- `infra/backup/` — see decision 4.

## Verification

On a fresh apps VM, after `scripts/init-coolify.sh`:

- `docker info --format '{{.DockerRootDir}}'` → `/data/docker`
- `sudo ls /var/lib/docker` → absent or empty
- `df -h /data` grows as images are pulled; `df -h /` does not
- Re-running `init-coolify.sh` reports the data-root step as already done and
  changes nothing
- Running it with `/data` unmounted fails, naming `/data` rather than Docker

On the hypervisor:

- `qm config 102 | grep scsi0` shows a 64 GB root disk
- `zfs list rpool` — 278 GB nominal across the three VM roots
