# apps VM storage layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Point Docker's data-root at `/data/docker` on the apps VM before any
Engine starts, and drop that VM's root disk from 80 GB to 64 GB as a result.

**Architecture:** Two changes. `scripts/init-coolify.sh` gains a step that writes
`/etc/docker/daemon.json` between the swapfile and the vendor installer, plus a
post-installer check that the setting survived. Then four docs are synced to the
new number and the new reality.

**Spec:** [2026-08-08-apps-vm-storage-layout-design.md](../specs/2026-08-08-apps-vm-storage-layout-design.md)

**Tech Stack:** bash (`set -euo pipefail`), python3 (Ubuntu Server base install)
for the JSON merge, Markdown.

## Global Constraints

- **There is no build, lint or test system in this repo.** Correctness is verified
  by reading, plus `bash -n` for syntax. Runtime verification happens on the apps
  VM and is **out of scope for these tasks** — each task's verification steps are
  what can actually be checked from the editing machine.
- **`*.sh` must stay LF.** `.gitattributes` forces LF repo-wide; CRLF breaks
  shebangs. Do not let an editor rewrite line endings.
- **`scripts/init-coolify.sh` already exists at mode `100755`.** Do not change its
  mode. Verify with `git ls-files -s scripts/init-coolify.sh` after committing.
- **From-scratch only.** No migration paths, no "if you already have an install"
  branches in the guides. The one exception is the script's *guard* against an
  existing Engine, which exists to refuse rather than to migrate.
- **Never write a host IP address** in any file touched here.
- **Do not retro-edit** anything under `docs/review/` or `docs/superpowers/specs/`.
  They are historical records. Finding 1a of
  `docs/review/2026-08-02-fresh-playthrough-review.md` stays as written even
  though this work resolves it.
- **Exact literals**, used identically in script and docs:
  - data mount: `/data`
  - data-root: `/data/docker`
  - daemon config: `/etc/docker/daemon.json`
  - apps VM root disk: `64 GB`
  - apps VM second disk: `300 GB`
  - swapfile: `4 GB` at `/swapfile`
  - free-space floor: `30 GB` on `/`, checked twice

## File Structure

| File | Responsibility after this plan |
|---|---|
| `scripts/init-coolify.sh` | owns the data-root: writes it before the installer, verifies it after |
| `README.md` | topology block — the apps VM's advertised disk sizes |
| `docs/proxmox-setup.md` | the VM spec table, and the sizing rationale behind 64 GB |
| `docs/apps-vm-setup.md` | mounts `/data`; states why the mount must precede the installer |
| `docs/coolify-setup.md` | what `init-coolify.sh` does, and the layout of `/data` including backup fate |

---

### Task 1: `init-coolify.sh` writes and verifies Docker's data-root

**Files:**
- Modify: `scripts/init-coolify.sh` — header comment block (lines 8–13), new
  variables near line 31, new section between lines 133 and 135, verification
  after line 157, and renumbering of the two sections that follow

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: three shell variables other steps in the same script read —
  `DATA_MOUNT="/data"`, `DOCKER_DATA_ROOT="/data/docker"`,
  `DAEMON_JSON="/etc/docker/daemon.json"`. Task 2 quotes the literals
  `/data/docker` and `64 GB` in prose; nothing imports from this file.

- [ ] **Step 1: Add the three path variables**

In `scripts/init-coolify.sh`, replace:

```bash
INSTALLER_URL="https://cdn.coollabs.io/coolify/install.sh"
SWAPFILE="/swapfile"
SWAP_SIZE_MB=4096
```

with:

```bash
INSTALLER_URL="https://cdn.coollabs.io/coolify/install.sh"
SWAPFILE="/swapfile"
SWAP_SIZE_MB=4096
DATA_MOUNT="/data"
DOCKER_DATA_ROOT="/data/docker"
DAEMON_JSON="/etc/docker/daemon.json"
```

- [ ] **Step 2: Update the header comment's step list**

Replace lines 8–13, which currently read:

```bash
# below brings its own Engine. Steps:
#   1. Preflight: OS family, Docker Engine version IF one is present, disk, RAM.
#   2. Create a swapfile if none is active.
#   3. Fetch Coolify's official installer to a temp file, show where it came
#      from and its sha256, then run it.
#   4. Seed apps/.env from apps/.env.example if missing.
```

with:

```bash
# below brings its own Engine. Steps:
#   1. Preflight: OS family, Docker Engine version IF one is present, disk, RAM.
#   2. Create a swapfile if none is active.
#   3. Point Docker's data-root at /data/docker, BEFORE any Engine exists.
#   4. Fetch Coolify's official installer to a temp file, show where it came
#      from and its sha256, then run it — then re-check the data-root survived.
#   5. Seed apps/.env from apps/.env.example if missing.
```

- [ ] **Step 3: Insert the data-root section**

Insert this **between** the end of the swap section (the `fi` on line 133) and
the `# --- 3. install ---` marker on line 135:

```bash
# --- 3. Docker's data-root --------------------------------------------------

# Left alone, Coolify's installer brings up the Engine with the default
# /var/lib/docker — on the 64 GB root disk. Images, layers, containers and
# build cache are the part of this machine that actually grows, and this repo
# assigns that growth to the 300 GB `data` mirror, so the data-root is pointed
# there BEFORE any Engine exists. Afterwards means moving a live data
# directory, the same trap docs/apps-vm-setup.md names for /data/coolify.
#
# /data/docker is the one directory on that disk which is DELIBERATELY
# disposable: every byte in it is pullable or rebuildable. That is also why the
# disk carries backup=0 on the hypervisor, and why the file-level backup job
# that eventually covers this VM must walk /data/coolify and /data/<stack>
# rather than /data.
echo "==> Pointing Docker's data-root at ${DOCKER_DATA_ROOT}"

# Not cosmetic. If /data is an ordinary directory on the root filesystem, then
# writing the data-root here recreates the exact problem this step exists to
# fix — and it would look like it worked.
if ! mountpoint -q "$DATA_MOUNT"; then
  echo "${DATA_MOUNT} is not a mountpoint — mount the 300 GB data disk first" >&2
  echo "(docs/apps-vm-setup.md, step 4)." >&2
  exit 1
fi

# The preflight's Docker check above is deliberately soft, so an Engine that is
# already running is REACHABLE here. Switching the data-root under one orphans
# every image, volume and container it holds, so change nothing and say why.
if [ -d /var/lib/docker ] \
   && [ -n "$(run_root find /var/lib/docker -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "    WARNING: /var/lib/docker exists and is not empty."
  echo "             Leaving ${DAEMON_JSON} alone — changing the data-root under"
  echo "             a live Engine orphans everything it holds. To move it on"
  echo "             purpose: stop docker, move the tree, then set \"data-root\""
  echo "             in ${DAEMON_JSON} by hand."
elif ! command -v python3 >/dev/null 2>&1; then
  echo "    WARNING: python3 not found, so ${DAEMON_JSON} cannot be edited"
  echo "             without risking whatever else is in it. Set"
  echo "             \"data-root\": \"${DOCKER_DATA_ROOT}\" by hand, then re-run."
else
  run_root mkdir -p "$DOCKER_DATA_ROOT" /etc/docker

  # MERGE, never overwrite. On a re-run this file already holds whatever
  # Coolify's installer put in it, and clobbering that would be a silent
  # regression somewhere else. python3 is in Ubuntu Server's base install;
  # the branch above covers its absence rather than assuming.
  run_root python3 - "$DAEMON_JSON" "$DOCKER_DATA_ROOT" <<'PY'
import json, os, sys

path, root = sys.argv[1], sys.argv[2]

try:
    with open(path) as fh:
        cfg = json.load(fh)
except FileNotFoundError:
    cfg = {}
except json.JSONDecodeError as exc:
    sys.exit(f"{path} is not valid JSON ({exc}); fix it by hand and re-run.")

if cfg.get("data-root") == root:
    print(f"    {path} already sets data-root to {root} — nothing to do")
    sys.exit(0)

cfg["data-root"] = root

# Write beside the target and rename, so an interrupted run cannot leave the
# Engine with a half-written config it refuses to start on.
tmp = path + ".new"
with open(tmp, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print(f"    wrote data-root={root} to {path}")
PY
fi

```

- [ ] **Step 4: Renumber the two following sections**

Change `# --- 3. install ---...` to `# --- 4. install ---...` and
`# --- 4. .env ---...` to `# --- 5. .env ---...`. Keep the trailing dashes so
each marker still reaches column 79, matching every other marker in the file.

- [ ] **Step 5: Add the post-installer verification**

Immediately after the line `run_root bash "$TMP_INSTALLER"`, insert:

```bash

# Coolify's installer writes /etc/docker/daemon.json for its own reasons, and
# whether it merges or replaces is not documented — so verify rather than
# assume. A clobbered data-root sends every future image layer back to the
# 64 GB root disk, and nothing else would look wrong for weeks.
ACTUAL_ROOT="$(run_root docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
if [ "$ACTUAL_ROOT" = "$DOCKER_DATA_ROOT" ]; then
  echo "    data-root confirmed: ${ACTUAL_ROOT}"
else
  echo "    WARNING: Docker reports data-root '${ACTUAL_ROOT:-unknown}', not"
  echo "             ${DOCKER_DATA_ROOT}. The installer probably rewrote"
  echo "             ${DAEMON_JSON}. Put the key back, then:"
  echo "             sudo systemctl restart docker"
fi
```

- [ ] **Step 6: Check the syntax**

Run:

```bash
bash -n scripts/init-coolify.sh
```

Expected: no output, exit 0. A non-zero exit here almost certainly means the
`PY` heredoc terminator picked up leading whitespace — it must sit at column 0.

- [ ] **Step 7: Check shellcheck, if it is installed**

Run:

```bash
command -v shellcheck >/dev/null && shellcheck scripts/init-coolify.sh || echo "shellcheck not installed — skipped"
```

Expected: either clean output, or the skip message. If shellcheck runs and
reports anything, fix it — but do **not** add a `# shellcheck disable` without
saying why in the comment, matching the existing one at line 55.

- [ ] **Step 8: Confirm the line endings and mode did not change**

Run:

```bash
git diff --stat && git ls-files -s scripts/init-coolify.sh
```

Expected: `scripts/init-coolify.sh` is the only changed file, mode is `100755`,
and the diff shows no whole-file rewrite (which is what a CRLF conversion looks
like).

- [ ] **Step 9: Read the section back in place**

Run:

```bash
sed -n '130,200p' scripts/init-coolify.sh
```

Confirm by reading: the section order is swap → data-root → install → .env, the
section markers read 3, 4, 5, and the `mountpoint` guard sits **before** the
Engine guard (a populated `/var/lib/docker` on an unmounted `/data` must fail on
the mount, which is the more actionable message).

- [ ] **Step 10: Commit**

```bash
git add scripts/init-coolify.sh
git commit -m "Apps VM: point Docker's data-root at /data/docker

Coolify's installer would otherwise bring up the Engine with the default
/var/lib/docker, on the root disk — which is what made the repo's claim
that image layers land on the data mirror untrue.

Written before any Engine exists, so there is no live data-root to move,
and re-checked after the installer runs because the installer writes that
same file and whether it merges is undocumented. Guards: refuse if /data
is not a mountpoint, skip if an Engine is already populated, merge rather
than overwrite.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Sync the docs to 64 GB and to the data-root

**Files:**
- Modify: `README.md:43`
- Modify: `docs/proxmox-setup.md:285`, `docs/proxmox-setup.md:739-748`
- Modify: `docs/apps-vm-setup.md:88-93`, `:127`, `:140`
- Modify: `docs/coolify-setup.md:32-34`, `:226`, `:234-235`

**Interfaces:**
- Consumes: the literals Task 1 established — `/data/docker`,
  `/etc/docker/daemon.json`, and the behaviour that the script refuses when
  `/data` is not a mountpoint.
- Produces: nothing other tasks consume. This is the last task.

- [ ] **Step 1: `README.md` topology block**

Replace line 43:

```
    ├─ apps VM · 12 vCPU · 32 GB · 80 GB + 300 GB on data · Ubuntu Server 26.04
```

with:

```
    ├─ apps VM · 12 vCPU · 32 GB · 64 GB + 300 GB on data · Ubuntu Server 26.04
```

Leave `README.md:91-92` alone. It claims `data` absorbs "Coolify's app volumes,
databases and image layers", which Task 1 makes true as written — that line was
aspirational and is now a description.

- [ ] **Step 2: `docs/proxmox-setup.md` spec table**

Replace line 285:

```
| Root disk | 150 GB on `local-zfs` | 80 GB on `local-zfs` | 64 GB on `local-zfs` |
```

with:

```
| Root disk | 150 GB on `local-zfs` | 64 GB on `local-zfs` | 64 GB on `local-zfs` |
```

Leave line 314 alone — same reason as `README.md:91`.

- [ ] **Step 3: `docs/proxmox-setup.md` sizing rationale**

Replace the whole `- **apps 32 GB, and 80 + 300 GB across two pools.**` bullet
(lines 739–748) with:

```markdown
- **apps 32 GB, and 64 + 300 GB across two pools.** This is where real user
  workloads live, and the largest **memory** allocation on the box for that
  reason — though it is also the least evidenced one, since the VM has run
  nothing measurable yet. It is the first line to trim back if the reserve is
  ever wanted elsewhere, and the number to decide by measurement rather than
  argument: `node_memory_MemAvailable_bytes{instance="apps"}` is already
  scraped. The **root** disk carries the OS, a 4 GB swapfile and Coolify
  itself — and nothing that grows, because `scripts/init-coolify.sh` points
  Docker's data-root at `/data/docker` before any Engine starts, so app
  volumes, databases, build cache and image layers all land on the `data`
  mirror.
- **Why the apps root disk is 64 GB and not 40.** Its floor is not the OS. The
  30 GB-free check on `/` runs **twice** — once in `scripts/init-coolify.sh` so
  the failure names its cause before anything is downloaded, and again inside
  the vendor installer, that time *after* the swapfile exists. 10 GB of Ubuntu
  plus 4 GB of swap plus 30 GB free is 44 GB, so **a 40 GB root disk fails a
  check that has nothing to do with the OS fitting** — which is the trap here,
  because 40 looks like the obvious number once the layers move off. 48 GB is
  the smallest figure that passes with margin; 64 leaves room for journald, the
  apt cache and an OS that grows, on a pool that is 40% empty.
```

- [ ] **Step 4: `docs/apps-vm-setup.md` — the disk sizes and why the mount comes first**

Replace lines 88–93:

```markdown
This VM has **two** disks: an 80 GB root on the hypervisor's NVMe mirror, and a
300 GB second disk on the `data` mirror
([proxmox-setup.md Part 5](proxmox-setup.md#part-5--create-the-vms)). Coolify
keeps everything it manages under **`/data/coolify`**, so the second disk gets
mounted at `/data` **before** the installer runs — afterwards means moving a
live data directory.
```

with:

```markdown
This VM has **two** disks: a 64 GB root on the hypervisor's NVMe mirror, and a
300 GB second disk on the `data` mirror
([proxmox-setup.md Part 5](proxmox-setup.md#part-5--create-the-vms)). Two things
live on the second one: Coolify keeps everything it manages under
**`/data/coolify`**, and [`scripts/init-coolify.sh`](../scripts/init-coolify.sh)
points Docker's own data-root at **`/data/docker`** so images, layers and build
cache land here rather than on the root disk.

Both are why the second disk gets mounted at `/data` **before** the installer
runs — afterwards means moving a live data directory. The script refuses to
write the data-root at all while `/data` is not a mountpoint, for exactly that
reason.
```

- [ ] **Step 5: `docs/apps-vm-setup.md` — the two "not 80" references**

Replace line 127:

```markdown
Verify — it must show ~300 GB, not the root disk's 80:
```

with:

```markdown
Verify — it must show ~300 GB, not the root disk's 64:
```

And in the checklist, replace:

```markdown
- [ ] `df -h /data` shows ~300 GB — **not** 80
```

with:

```markdown
- [ ] `df -h /data` shows ~300 GB — **not** 64
```

- [ ] **Step 6: `docs/coolify-setup.md` — what the script does**

Replace lines 32–34:

```markdown
It preflights the box (Debian family, Engine ≥ 24, 30 GB free, RAM), creates a
4 GB swapfile if none is active, then downloads Coolify's official installer
**to a file** and prints its source URL and sha256 before running it as root.
```

with:

```markdown
It preflights the box (Debian family, Engine ≥ 24, 30 GB free, RAM), creates a
4 GB swapfile if none is active, points Docker's data-root at `/data/docker`,
then downloads Coolify's official installer **to a file** and prints its source
URL and sha256 before running it as root.
```

- [ ] **Step 7: `docs/coolify-setup.md` — the data-root note**

Directly after the existing `> **On Ubuntu 26.04 the script warns.**` block
(which ends at line 48), add:

```markdown
> **The data-root is written before the Engine exists, and verified after.**
> Left alone, Coolify's installer would put `/var/lib/docker` on the 64 GB root
> disk. The script writes `{"data-root": "/data/docker"}` into
> `/etc/docker/daemon.json` first — merging, so it keeps whatever else is in
> there — and then re-reads `docker info` once the installer has finished,
> because the installer writes that same file for its own reasons and whether it
> merges is not documented. **If that check warns, fix the key and
> `sudo systemctl restart docker` before deploying anything:** a lost data-root
> is invisible for weeks and then fills the root disk.
```

- [ ] **Step 8: `docs/coolify-setup.md` — the layout table**

In the *Layout on the server* table, insert a row immediately after the
`| The data disk | ... |` row:

```markdown
| Docker's data-root | `/data/docker` — images, layers, containers, build cache. Set by `init-coolify.sh` |
```

- [ ] **Step 9: `docs/coolify-setup.md` — the backup fate of `/data/docker`**

After the paragraph ending "…which is the trade Coolify asks for." and
**before** the `**`/data/<stack>/` is the second thing to back up…**` paragraph,
insert:

```markdown
**`/data/docker/` is the one directory on this disk that must NOT be backed
up.** Every byte in it is pullable or rebuildable — images, layers, containers,
build cache — which is part of why the disk carries `backup=0` on the
hypervisor. It also means the file-level job that eventually covers this VM has
to walk `/data/coolify` and `/data/<stack>` by name: point it at `/data` and it
swallows every image layer on the machine. Any Docker **named** volume would
land in here too, unbacked, which is the other half of why the third-party
stacks bind-mount under `/data/<stack>` instead
([apps/stacks/README.md](../apps/stacks/README.md)).
```

- [ ] **Step 10: Verify no stale size claim survives**

Run:

```bash
grep -rnE "\b80\b" README.md docs/proxmox-setup.md docs/apps-vm-setup.md docs/coolify-setup.md
```

Expected: **no output.** Before this task there are exactly seven hits — the
five in the change list plus `proxmox-setup.md:739`'s `80 + 300 GB` heading
(covered by Step 3) and `apps-vm-setup.md:140`'s `**not** 80` (covered by
Step 5). A word-boundary match on the bare number is used deliberately rather
than `"80 GB"`: the checklist line reads `**not** 80`, which a `80 GB` pattern
silently misses.

Scope the grep to those four files, not to `docs/`. `docs/review/` and
`docs/superpowers/` are historical records and must keep saying 80.

- [ ] **Step 11: Verify the new claims are consistent everywhere**

Run:

```bash
grep -rn "64 GB\|/data/docker" README.md docs/proxmox-setup.md docs/apps-vm-setup.md docs/coolify-setup.md scripts/init-coolify.sh
```

Read the output and confirm three things: the apps VM says `64 GB` in all four
docs; the home-assistant VM's own `64 GB` rows are untouched (they were always
64 — do not mistake them for edits); and `/data/docker` is spelled identically
in the script and in every doc, with no trailing slash inside backticks.

- [ ] **Step 12: Confirm nothing historical was touched**

Run:

```bash
git status --short
```

Expected: exactly `README.md`, `docs/proxmox-setup.md`,
`docs/apps-vm-setup.md`, `docs/coolify-setup.md`. Nothing under `docs/review/`
or `docs/superpowers/specs/`.

- [ ] **Step 13: Commit**

```bash
git add README.md docs/proxmox-setup.md docs/apps-vm-setup.md docs/coolify-setup.md
git commit -m "Docs: apps VM root disk 80 -> 64 GB, and record the data-root

With Docker's data-root on the data mirror, the apps root disk carries
only the OS, a 4 GB swapfile and Coolify itself. Its floor is the 30 GB
free check rather than the OS, which is why 64 and not 40 — written down,
because 40 looks like the obvious number once the layers move off.

Also states the backup fate of /data/docker: the one directory on that
disk that must not be backed up, so the file-level job that eventually
covers this VM walks /data/coolify and /data/<stack> by name.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Verification on the apps VM (out of scope for the tasks above)

Recorded so it is not lost. Run after a fresh `scripts/init-coolify.sh`:

- `docker info --format '{{.DockerRootDir}}'` → `/data/docker`
- `sudo find /var/lib/docker -mindepth 1 -maxdepth 1` → nothing
- `df -h /data` grows as images are pulled; `df -h /` does not
- re-running `init-coolify.sh` prints `already sets data-root` and changes nothing
- running it with `/data` unmounted exits non-zero, naming `/data` and not Docker
- on the hypervisor: `qm config 102 | grep scsi0` shows a 64 GB root disk
