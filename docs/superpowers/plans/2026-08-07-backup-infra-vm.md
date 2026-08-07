# Infra VM file-level backup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A nightly restic job on the infra VM that produces one tagged snapshot per stack, driven by a per-stack backup definition living beside each stack's compose file — delivered end to end for Authentik.

**Architecture:** A shared recipe library (`infra/backup/lib.sh`) is sourced by per-stack `backup.sh` scripts, which stage database dumps and declare paths. A runner (`infra/backup/run.sh`) discovers those scripts by glob, executes each, and takes a `--tag <stack>` restic snapshot. A systemd timer drives it nightly; a Kuma push monitor is the deadman. `infra/authentik/restore.sh` is the inverse.

**Tech Stack:** bash, restic (SFTP backend), systemd timers, Docker Compose, Postgres 18, Uptime Kuma push monitors.

**Spec:** [2026-08-07-backup-infra-vm-design.md](../specs/2026-08-07-backup-infra-vm-design.md)

## Global Constraints

- **This repo has no build, lint or test system.** Correctness is verified by reading, plus `bash -n` for syntax. Real verification happens on the VM and is **not** claimed by the implementer — Task 10 lists it as an operator checklist.
- **`*.sh` must be committed LF and mode `100755`.** `.gitattributes` forces LF; a file created on Windows lands `100644`. Use `git update-index --chmod=+x` and verify with `git ls-files -s`.
- **Executable shell scripts use `set -euo pipefail`** and resolve paths from `$BASH_SOURCE`. Two deliberate exceptions, each documented in its own task: `run.sh` uses `set -uo pipefail` (Task 4), and `lib.sh` sets nothing at all because it is sourced and inherits the caller's settings (Task 2).
- **Never write a host IP address.** Machines are addressed by name: `pve.thefipster.de`.
- **Image pins and paths are already fixed** — do not change any compose file. The four Postgres stacks are uniform: service `db`, `POSTGRES_USER == POSTGRES_DB == <stack>`.
- **Guides describe a from-scratch bring-up.** No migration paths, no upgrade procedures, no phase history in guides.
- **Restic retention:** `--group-by host,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
- **Schedule:** backup `01:00` daily; check weekly. 01:00 is one hour before the 02:00 vzdump job and clear of the 04:30 unattended-upgrades reboot window.
- **Repository:** `sftp:backup@pve.thefipster.de:/restic`.

## File Structure

| File | Responsibility |
|---|---|
| `infra/backup/lib.sh` | The recipes: `include`, `include_env`, `dump_postgres`. Sourced only. |
| `infra/backup/run.sh` | Discovery, staging, per-stack snapshot, retention, Kuma push, exit code. |
| `infra/backup/.env.example` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `KUMA_PUSH_URL`. |
| `infra/backup/restic-backup.service` / `.timer` | Nightly run. |
| `infra/backup/restic-check.service` / `.timer` | Weekly `restic check`. |
| `infra/authentik/backup.sh` | What Authentik's backup consists of. First caller of `lib.sh`. |
| `infra/authentik/restore.sh` | The inverse, with guardrails. |
| `scripts/init-backup.sh` | Install on the infra VM. |
| `docs/backup-setup.md` | The guide: host prerequisites, install, restore, troubleshooting. |
| `docs/roadmap/backup.md` | Corrected to match reality and this design. |

---

### Task 1: Correct the backup roadmap

The roadmap predates Vaultwarden and the current repo shape. Six corrections plus a phase-2 rewrite. Doing this first means every later task has an accurate reference.

**Files:**
- Modify: `docs/roadmap/backup.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the corrected tier tables and phase-2 description that Tasks 8 and 9 link to.

- [ ] **Step 1: Add `/opt/monitoring/grafana` to Tier 3**

In the "Tier 3 — deliberately **not** backed up" list, add a bullet after the Alloy one:

```markdown
- **Grafana's file state** `/opt/monitoring/grafana` — with
  `GF_DATABASE_TYPE: postgres` this directory holds only the plugin dir (nothing
  installs plugins here) and the renderer/CSV cache. There is no `grafana.db`,
  because the backend is not SQLite. The Grafana *database* is Tier 2 above and
  is a different path.
```

- [ ] **Step 2: Drop Dockge's `.env` from the Tier 1 secrets row**

In the Tier 1 table, the "All `.env` files" row's Path cell currently reads:

```
`infra/{traefik,vaultwarden,authentik,forgejo,monitoring}/.env`, `/opt/stacks/dockge/.env`
```

Replace with:

```
`infra/{traefik,vaultwarden,authentik,forgejo,monitoring}/.env`
```

Then add this paragraph immediately after the Tier 1 table's three coupling bullets:

```markdown
**Dockge's `.env` is deliberately not in that row.** It holds exactly
`REPO_DIR=…`, rewritten by `scripts/init-dockge.sh` on every run. There is no
secret in it and nothing to lose.
```

- [ ] **Step 3: Write down why the `.env` files are backed up from the checkout**

Add a fourth coupling bullet after the three existing ones under the Tier 1 table:

```markdown
- **The `.env` files are reachable only through the checkout, not through
  `/opt/stacks`.** `/opt/stacks/<stack>` are *symlinks* into
  `~/home-lab/infra/<stack>`, and restic stores a symlink as a symlink rather
  than descending into it. Backing up `/opt/stacks` therefore captures the
  links and none of the secrets. The paths in the diagram below name
  `infra/*/.env` separately for exactly this reason — it is not redundancy.
```

- [ ] **Step 4: Give the Home Assistant VM its row**

In "Not on the infra VM, but part of the same story", add after the apps VM bullet:

```markdown
- **The home-assistant VM** — HAOS is an appliance and ships its own backup
  mechanism (*Settings → System → Backups*), which is what it uses. Layer 1
  covers its disk; nothing in this repo drives its file-level backups, the same
  way nothing here drives its configuration.
```

- [ ] **Step 5: Record that no MariaDB recipe exists**

In "Why dumps, not raw directory copies, for the databases", after the first paragraph, add:

```markdown
There is **no MariaDB on the infra VM** — all four databases are
`postgres:18-alpine` — so there is no MariaDB recipe. That belongs to the apps
VM, which this roadmap scopes out.
```

- [ ] **Step 6: Rewrite phase 2 to the per-stack shape**

Replace the `infra/backup/` block in "Architecture" with:

```
infra/backup/
  lib.sh             the recipes: include, include_env, dump_postgres
  run.sh             glob infra/*/backup.sh → stage → snapshot --tag <stack> → forget --prune → ping Kuma
  restic-backup.service / .timer   nightly 01:00
  restic-check.service / .timer    weekly restic check
  .env.example       RESTIC_REPOSITORY, RESTIC_PASSWORD, KUMA_PUSH_URL
infra/<stack>/
  backup.sh          what THIS stack's backup consists of — one file per stack
  restore.sh         the inverse, with guardrails
scripts/init-backup.sh   installs the units, creates /opt/backup, seeds .env, restic init
docs/backup-setup.md     the guide
```

Then replace the paragraph beginning "Layer 2 is a **systemd timer**" through the end of that section with:

```markdown
Layer 2 is a **systemd timer**, not a compose stack — deliberately. A backup
that runs inside Docker is a backup that stops when Docker does, and the
alternative (a container that can stop other containers) means a sixth socket
mount. Precedent exists: the Proxmox node exporter is a systemd unit too.

**A stack's backup is defined beside the stack, not in the runner.** Each
`infra/<stack>/backup.sh` sources `lib.sh` and declares what that stack
consists of; the runner finds them by globbing `infra/*/backup.sh`, so adding a
stack is one file and no list to keep in sync. This is the shape the couplings
argue for: Authentik's DB↔`AUTHENTIK_SECRET_KEY` and Vaultwarden's
DB↔`rsa_key.pem` are *per-stack facts*, and they belong where someone changing
that stack will read them.

**Each stack gets its own tagged snapshot**, so restoring one is
`restic restore latest --tag authentik` rather than an include-list assembled
under pressure — and the coupling comes back as one unit by construction.
```

- [ ] **Step 7: Move the Kuma ping from phase 4 into phase 2**

In the Phases list, phase 2's text gains a sentence before "**Vaultwarden is the reason…**":

```markdown
   The Kuma push (phase 4) lands here rather than later: a backup nobody knows
   has stopped is decorative, and it is three lines given Kuma already exists.
```

And phase 4's text changes its first sentence to:

```markdown
4. **Notice when it stops.** ✅ folded into phase 2 — `run.sh` pings an Uptime
   Kuma push monitor, and only a fully clean run does. What remains here is the
   optional `backup_last_success_timestamp` metric for Alloy's textfile
   collector, for the "why" half; it needs a `textfile` block on
   `prometheus.exporter.unix` and has not been built.
```

- [ ] **Step 8: Verify no stale references remain**

```bash
grep -n "dockge/.env\|monolithic\|backup.sh          dump" docs/roadmap/backup.md
```

Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add docs/roadmap/backup.md
git commit -m "docs: correct the backup roadmap against the current repo"
```

---

### Task 2: The recipe library

**Files:**
- Create: `infra/backup/lib.sh`

**Interfaces:**
- Consumes: environment `BACKUP_STAGE` (per-stack staging dir, created and emptied by the caller) and `REPO_ROOT` (repo checkout root).
- Produces, for Tasks 3 and 4:
  - `include <path>` — appends `<path>` to `$BACKUP_STAGE/paths.txt`; returns 1 if the path does not exist.
  - `include_env` — no args; `include`s `$REPO_ROOT/infra/$STACK/.env`.
  - `dump_postgres <stack> [service] [user] [db]` — writes `$BACKUP_STAGE/<stack>.sql` and `include`s it. Defaults: service `db`, user and db both `<stack>`.
  - `$STACK` — the calling script's directory name.
  - `$BACKUP_STAGE/paths.txt` — one absolute path per line; the runner's only input.

- [ ] **Step 1: Write `infra/backup/lib.sh`**

```bash
#!/usr/bin/env bash
#
# lib.sh — the backup recipes, sourced by every infra/<stack>/backup.sh.
#
# Contract with infra/backup/run.sh:
#   in   BACKUP_STAGE  this stack's staging dir — the runner creates and empties it
#        REPO_ROOT     the repo checkout root
#   out  dump files in $BACKUP_STAGE, and one absolute path per line in
#        $BACKUP_STAGE/paths.txt, which is the ONLY thing restic is given.
#
# Stack scripts are EXECUTED, not sourced, so one can be run on its own:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/authentik/backup.sh
# produces a directory you can look at — no repository, no password, no network.
#
# No `set -euo pipefail` here: the calling script sets it and a sourced file
# inherits it. Setting it again would be a second place to keep in sync.

: "${BACKUP_STAGE:?BACKUP_STAGE is not set — run this through infra/backup/run.sh}"
: "${REPO_ROOT:?REPO_ROOT is not set — run this through infra/backup/run.sh}"

# BASH_SOURCE[1] is the script that sourced us; its directory name is the stack.
# readlink -f first, because /opt/stacks/<stack> is a symlink into the checkout.
STACK="$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[1]}")")")"

mkdir -p "$BACKUP_STAGE"
: > "$BACKUP_STAGE/paths.txt"

# include <path> — declare a path for restic to snapshot.
#
# Copies nothing. restic reads the live tree, which is both faster and better
# for deduplication than staging a copy would be. A missing path is an error,
# not a warning: under the caller's `set -e` it aborts the stack, and the runner
# records that stack as failed. A backup quietly missing a directory is worse
# than a backup that says it failed.
include() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo "  ! include: $path does not exist" >&2
    return 1
  fi
  printf '%s\n' "$path" >> "$BACKUP_STAGE/paths.txt"
}

# include_env — sugar for this stack's gitignored .env.
#
# It comes from the CHECKOUT, never from /opt/stacks/<stack>, which is a symlink
# restic would store as a symlink rather than descend into.
include_env() {
  include "${REPO_ROOT}/infra/${STACK}/.env"
}

# dump_postgres <stack> [service] [user] [db]
#
# Dumps through the stack's own db container, so the client version always
# matches the server. The single-argument form works because all four Postgres
# stacks are uniform: service `db`, POSTGRES_USER == POSTGRES_DB == <stack>.
dump_postgres() {
  local stack="$1"
  local service="${2:-db}"
  local user="${3:-$stack}"
  local db="${4:-$stack}"
  local out="${BACKUP_STAGE}/${stack}.sql"

  # --format=plain, NOT -Fc. A compressed dump changes in its entirety when a
  # single row changes, which defeats restic's content-defined chunking. Plain
  # SQL deduplicates across nightly runs, and restic compresses it at rest
  # anyway (--compression auto, default since 0.14) — so plain text costs
  # nothing in stored size and buys most of the dedup.
  #
  # --clean --if-exists so the dump loads into a live database rather than
  # requiring a hand-dropped one.
  ( cd "${REPO_ROOT}/infra/${stack}" \
    && docker compose exec -T "$service" \
         pg_dump --username="$user" --format=plain --clean --if-exists "$db" ) \
    > "${out}.part"

  # Rename only after pg_dump exited 0, so a truncated dump is never mistaken
  # for a good one by the next run — or by a restore.
  mv -f "${out}.part" "$out"

  include "$out"
}
```

- [ ] **Step 2: Syntax check**

```bash
bash -n infra/backup/lib.sh
```

Expected: no output.

- [ ] **Step 3: Prove the contract guards fire**

```bash
bash -c 'set -euo pipefail; source infra/backup/lib.sh' ; echo "exit=$?"
```

Expected: `BACKUP_STAGE is not set — run this through infra/backup/run.sh` on stderr and `exit=1`.

- [ ] **Step 4: Prove `include` records paths and rejects missing ones**

```bash
mkdir -p /tmp/bkstage && bash -c 'set -euo pipefail
BACKUP_STAGE=/tmp/bkstage REPO_ROOT="$PWD" source infra/backup/lib.sh
include "$PWD/README.md"
include /nope/does/not/exist' ; echo "exit=$?" ; cat /tmp/bkstage/paths.txt
```

Expected: `! include: /nope/does/not/exist does not exist` on stderr, `exit=1`, and `paths.txt` containing exactly the README path.

- [ ] **Step 5: Fix the file mode and commit**

```bash
git add infra/backup/lib.sh
git update-index --chmod=+x infra/backup/lib.sh
git ls-files -s infra/backup/lib.sh
```

Expected: mode `100755`.

```bash
git commit -m "feat(backup): add the shared backup recipe library"
```

---

### Task 3: Authentik's backup definition

**Files:**
- Create: `infra/authentik/backup.sh`

**Interfaces:**
- Consumes: `include`, `include_env`, `dump_postgres` from Task 2; `BACKUP_STAGE` and `REPO_ROOT` from the runner.
- Produces, for Task 4: an executable at `infra/authentik/backup.sh` that writes `$BACKUP_STAGE/authentik.sql` and `$BACKUP_STAGE/paths.txt`.

- [ ] **Step 1: Write `infra/authentik/backup.sh`**

```bash
#!/usr/bin/env bash
#
# backup.sh — what Authentik's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/authentik/backup.sh

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/authentik is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

dump_postgres authentik

include /opt/authentik/data       # uploads, branding, flow backgrounds
include /opt/authentik/templates
include /opt/authentik/certs      # signing keypairs created in the UI

# The raw PGDATA, as a LAST RESORT only. A live-copied data directory is torn by
# construction, so the restore path is always authentik.sql above — this is for
# the case where no dump exists. Kept because it costs little for a database
# this size; it is the first thing to reconsider if snapshots get expensive.
include /opt/authentik/postgres

# AUTHENTIK_SECRET_KEY decrypts secrets held in the database dumped above. That
# database restored WITHOUT this file is a database full of undecryptable
# values — the two are one unit, and this line is what keeps them in one
# snapshot. Same shape as Vaultwarden's rsa_key.pem, one directory apart.
include_env
```

- [ ] **Step 2: Syntax check**

```bash
bash -n infra/authentik/backup.sh
```

Expected: no output.

- [ ] **Step 3: Confirm every declared path matches the compose file**

```bash
grep -n "/opt/authentik" infra/authentik/compose.yaml infra/authentik/backup.sh
```

Expected: the four paths `data`, `templates`, `certs`, `postgres` appear in both. There must be no path in `backup.sh` that the compose file does not mount.

- [ ] **Step 4: Fix the file mode and commit**

```bash
git add infra/authentik/backup.sh
git update-index --chmod=+x infra/authentik/backup.sh
git ls-files -s infra/authentik/backup.sh
```

Expected: mode `100755`.

```bash
git commit -m "feat(backup): declare Authentik's backup set"
```

---

### Task 4: The runner and its configuration

**Files:**
- Create: `infra/backup/run.sh`
- Create: `infra/backup/.env.example`

**Interfaces:**
- Consumes: `infra/<stack>/backup.sh` scripts (Task 3), `infra/backup/.env`.
- Produces, for Tasks 5, 6 and 8: an executable at `infra/backup/run.sh` taking optional stack names as arguments; exits 0 only on a fully clean run; pings `KUMA_PUSH_URL` only then.

- [ ] **Step 1: Write `infra/backup/.env.example`**

```bash
# infra/backup/.env — layer 2 (restic) configuration. Gitignored.
#
# This file is read TWO ways: sourced by infra/backup/run.sh, and parsed by
# systemd as an EnvironmentFile for restic-check.service. Keep every line plain
# KEY=value — no `export`, no shell expansion, no command substitution. systemd
# does not run a shell over it and will not tell you it skipped a line.

# The restic repository: SFTP against the Proxmox host's existing sshd. /restic
# is inside the `backup` user's chroot, on the usbbackup pool. Setting it up is
# Part 1 of docs/backup-setup.md and happens on the host.
RESTIC_REPOSITORY=sftp:backup@pve.thefipster.de:/restic

# THE ONE SECRET THAT CANNOT BE IN THE BACKUP. Lose it and the repository is
# cryptographically gone — there is no recovery, no support, no reset.
#
# The authoritative copy belongs OUTSIDE the lab: on paper, or in an account
# that survives the building. Keep a copy in Vaultwarden by all means, but that
# is the convenient one, not the authoritative one — the vault is inside this
# backup, so storing the key only there closes a circle where losing the infra
# VM loses both at once.
RESTIC_PASSWORD=

# Uptime Kuma push monitor. Pinged ONLY by a fully clean run, so silence is the
# signal. Its row is in docs/uptime-kuma-monitors.md. Leave empty to disable the
# heartbeat — the backup still runs, you just stop being told when it doesn't.
KUMA_PUSH_URL=
```

- [ ] **Step 2: Write `infra/backup/run.sh`**

```bash
#!/usr/bin/env bash
#
# run.sh — the nightly file-level backup. Layer 2 of docs/roadmap/backup.md.
#
# For every infra/<stack>/backup.sh: stage that stack's dumps, then take one
# restic snapshot tagged with the stack name. Per-stack tags are what make
# "restore Authentik, all of it, in one command" possible.
#
# Runs as ROOT. The /opt trees are owned by the UIDs their images run as
# (postgres 999, forgejo 1000, grafana 472), so nothing else can read all of
# them, and pg_dump needs the Docker socket regardless.
#
# Usage:  infra/backup/run.sh [stack ...]      (no arguments = every stack)

# NOT `set -e`. One stack failing must not cost the other six their snapshots —
# failures are collected and reported at the end instead. `-u` and `-o pipefail`
# still apply.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export REPO_ROOT

STAGE_ROOT="/opt/backup/dumps"

if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  echo "no ${SCRIPT_DIR}/.env — run scripts/init-backup.sh first." >&2
  exit 1
fi

# restic reads RESTIC_REPOSITORY and RESTIC_PASSWORD from the environment.
set -a
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/.env"
set +a

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY in infra/backup/.env}"
: "${RESTIC_PASSWORD:?set RESTIC_PASSWORD in infra/backup/.env}"

# Which stacks? Anything with a backup.sh — there is no list to keep in sync,
# so adding a stack is one file.
stacks=()
if [ "$#" -gt 0 ]; then
  stacks=("$@")
else
  for f in "${REPO_ROOT}"/infra/*/backup.sh; do
    [ -e "$f" ] || continue
    stacks+=("$(basename "$(dirname "$f")")")
  done
fi

if [ "${#stacks[@]}" -eq 0 ]; then
  echo "no infra/*/backup.sh found — nothing to do." >&2
  exit 1
fi

failed=()

for stack in "${stacks[@]}"; do
  script="${REPO_ROOT}/infra/${stack}/backup.sh"

  if [ ! -x "$script" ]; then
    echo "  ! ${stack}: ${script} is missing or not executable" >&2
    failed+=("$stack")
    continue
  fi

  stage="${STAGE_ROOT}/${stack}"
  echo "==> ${stack}: staging"

  # Overwritten every run. History lives in restic, not in a pile of timestamped
  # local files that grows until the disk is full.
  rm -rf "$stage"
  mkdir -p "$stage"

  if ! BACKUP_STAGE="$stage" "$script"; then
    echo "  ! ${stack}: backup.sh failed" >&2
    failed+=("$stack")
    continue
  fi

  echo "==> ${stack}: snapshot"
  if ! restic backup --tag "$stack" --files-from "${stage}/paths.txt"; then
    echo "  ! ${stack}: restic backup failed" >&2
    failed+=("$stack")
    continue
  fi
done

# Retention runs once, over the whole repository.
#
# --group-by host,tags is NOT optional. restic applies the policy per group, and
# its default grouping is host,paths — so --keep-daily 7 across several stacks
# in one repository would be decided by a grouping that silently re-partitions
# the moment a stack's backup.sh gains or loses an include. Grouping by tag
# makes the policy mean "seven dailies of Authentik", which is how it reads.
# `host` is in there because the apps VM joins this same repository later.
echo "==> forget + prune"
if ! restic forget --group-by host,tags \
       --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; then
  echo "  ! forget/prune failed" >&2
  failed+=("forget")
fi

if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi

# Only a fully clean run reports success, and the deadman does the rest: Kuma
# goes red when the heartbeat does not arrive. A partial success must therefore
# look like a failure rather than a green tick. Same shape as the hypervisor's
# zfs-health-push.sh — see proxmox-setup.md Part 9.
if [ -n "${KUMA_PUSH_URL:-}" ]; then
  curl -fsS --max-time 10 --get "$KUMA_PUSH_URL" \
    --data-urlencode "status=up" \
    --data-urlencode "msg=${#stacks[@]} stacks: ${stacks[*]}" >/dev/null \
    || echo "  ! Kuma push failed (the backup itself succeeded)" >&2
fi

echo "OK: ${stacks[*]}"
```

- [ ] **Step 3: Syntax check**

```bash
bash -n infra/backup/run.sh
```

Expected: no output.

- [ ] **Step 4: Verify the repo-root calculation is right**

`SCRIPT_DIR` is `<repo>/infra/backup`, so the repo root is two levels up, not one. Confirm the script says `../..`:

```bash
grep -n 'REPO_ROOT=' infra/backup/run.sh
```

Expected: `REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"`.

- [ ] **Step 5: Verify glob discovery finds Authentik and nothing else yet**

```bash
for f in infra/*/backup.sh; do [ -e "$f" ] && basename "$(dirname "$f")"; done
```

Expected: exactly `authentik`.

- [ ] **Step 6: Confirm `.env` is gitignored**

```bash
git check-ignore -v infra/backup/.env
```

Expected: a match against the existing `.env` rule in `.gitignore`. If there is no match, add `infra/backup/.env` coverage to `.gitignore` before continuing.

- [ ] **Step 7: Fix the file mode and commit**

```bash
git add infra/backup/run.sh infra/backup/.env.example
git update-index --chmod=+x infra/backup/run.sh
git ls-files -s infra/backup/run.sh infra/backup/.env.example
```

Expected: `run.sh` mode `100755`, `.env.example` mode `100644`.

```bash
git commit -m "feat(backup): add the runner and its configuration"
```

---

### Task 5: The systemd units

**Files:**
- Create: `infra/backup/restic-backup.service`
- Create: `infra/backup/restic-backup.timer`
- Create: `infra/backup/restic-check.service`
- Create: `infra/backup/restic-check.timer`

**Interfaces:**
- Consumes: `infra/backup/run.sh` (Task 4), `infra/backup/.env`.
- Produces, for Task 6: four unit files containing the literal token `@REPO_ROOT@`, which `scripts/init-backup.sh` substitutes at install time.

- [ ] **Step 1: Write `infra/backup/restic-backup.service`**

```ini
[Unit]
Description=File-level backup of the infra VM (restic)
Documentation=file://@REPO_ROOT@/docs/backup-setup.md
# Wants, not Requires: if Docker is down the run fails loudly and Kuma goes red,
# which is the behaviour we want. Requires would cancel the unit silently.
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=@REPO_ROOT@/infra/backup/run.sh
# Root: the /opt trees are owned by the UIDs their images run as.
User=root
# The backup is never the most important thing running. Yield to the lab.
Nice=10
IOSchedulingClass=idle
```

- [ ] **Step 2: Write `infra/backup/restic-backup.timer`**

```ini
[Unit]
Description=Nightly file-level backup (restic)

[Timer]
# 01:00 — one hour BEFORE the 02:00 vzdump job on the Proxmox host
# (proxmox-setup.md Part 8), so layer 1's whole-VM archive contains the current
# night's dumps. Also clear of the 04:30 unattended-upgrades reboot window.
OnCalendar=*-*-* 01:00:00
RandomizedDelaySec=300
# A VM that was down at 01:00 catches up on boot rather than skipping a night.
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write `infra/backup/restic-check.service`**

```ini
[Unit]
Description=Verify the restic repository is readable
Documentation=file://@REPO_ROOT@/docs/backup-setup.md
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
# systemd parses this itself — which is why .env.example insists on plain
# KEY=value lines with no shell syntax in them.
EnvironmentFile=@REPO_ROOT@/infra/backup/.env
# A rotating tenth per week verifies the whole repository over ~10 weeks
# without reading all of it every night.
ExecStart=/usr/bin/restic check --read-data-subset=10%%
User=root
Nice=15
IOSchedulingClass=idle
```

Note the doubled `%%`: systemd treats `%` as a specifier prefix, so a literal percent sign must be escaped. `--read-data-subset=10%` written singly would fail to start with an unknown-specifier error.

- [ ] **Step 4: Write `infra/backup/restic-check.timer`**

```ini
[Unit]
Description=Weekly restic repository check

[Timer]
# Sunday 03:00 — after that night's backup and after vzdump, so the three jobs
# never contend for the same USB drive.
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 5: Verify every unit's placeholder token is consistent**

```bash
grep -c "@REPO_ROOT@" infra/backup/restic-backup.service infra/backup/restic-backup.timer infra/backup/restic-check.service infra/backup/restic-check.timer
```

Expected: `2`, `0`, `2`, `0` respectively. The timers carry no paths, so they need no substitution.

- [ ] **Step 6: Verify the escaped percent**

```bash
grep -n "read-data-subset" infra/backup/restic-check.service
```

Expected: `--read-data-subset=10%%` — two percent signs.

- [ ] **Step 7: Commit**

```bash
git add infra/backup/restic-backup.service infra/backup/restic-backup.timer infra/backup/restic-check.service infra/backup/restic-check.timer
git commit -m "feat(backup): add the nightly and weekly systemd units"
```

---

### Task 6: The install script

**Files:**
- Create: `scripts/init-backup.sh`

**Interfaces:**
- Consumes: `infra/backup/.env.example` and the four unit files (Tasks 4, 5).
- Produces, for Task 8: an idempotent installer. Reads `PVE_HOST` from the environment, defaulting to `pve.thefipster.de`.

- [ ] **Step 1: Write `scripts/init-backup.sh`**

```bash
#!/usr/bin/env bash
#
# init-backup.sh — install layer 2, the file-level restic backup.
#
# Installs restic, creates /opt/backup, seeds infra/backup/.env, generates the
# SSH key the repository is reached with, initialises the restic repository and
# enables the two timers.
#
# Build order: LAST on the infra VM. Needs Uptime Kuma for the push monitor URL,
# and needs the HOST-side prerequisites (the `backup` user and its chroot) to
# already exist — that is Part 1 of docs/backup-setup.md and runs on the
# Proxmox host, not here.
#
# Usage (from the repo root):
#   scripts/init-backup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/backup"
BACKUP_ROOT="/opt/backup"

# The host serving the repository over SFTP. By NAME, never an address — the
# router is the source of truth for addresses (docs/dns-records.md).
PVE_HOST="${PVE_HOST:-pve.thefipster.de}"

UNITS="restic-backup.service restic-backup.timer restic-check.service restic-check.timer"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-docker.sh first." >&2
  exit 1
fi

echo "==> Installing restic"
if ! command -v restic >/dev/null 2>&1; then
  run_root apt-get update
  run_root apt-get install -y restic
fi

echo "==> Creating ${BACKUP_ROOT}"
run_root mkdir -p "${BACKUP_ROOT}/dumps" "${BACKUP_ROOT}/restore"
# The dumps contain every credential the lab has, in plain SQL. Root only.
run_root chmod 700 "${BACKUP_ROOT}"

echo "==> Seeding ${STACK_DIR}/.env"
if [ ! -f "${STACK_DIR}/.env" ]; then
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
  chmod 600 "${STACK_DIR}/.env"
fi

echo "==> Ensuring root has an SSH key for the backup repository"
run_root mkdir -p /root/.ssh
run_root chmod 700 /root/.ssh
if ! run_root test -f /root/.ssh/id_ed25519; then
  run_root ssh-keygen -t ed25519 -N '' -C "restic-backup@infra" -f /root/.ssh/id_ed25519
fi

echo
echo "Public key — install this in the backup user's authorized_keys on ${PVE_HOST}:"
run_root cat /root/.ssh/id_ed25519.pub
echo

# A systemd timer cannot answer a trust-on-first-use prompt, so the host key has
# to be accepted now, by a human looking at the fingerprint.
echo "==> Recording the ${PVE_HOST} host key"
if ! run_root grep -q "${PVE_HOST}" /root/.ssh/known_hosts 2>/dev/null; then
  scan="$(ssh-keyscan -t ed25519 "${PVE_HOST}" 2>/dev/null)"
  if [ -z "$scan" ]; then
    echo "ssh-keyscan got nothing from ${PVE_HOST}. Is the name resolving?" >&2
    exit 1
  fi
  echo "Verify this fingerprint against the host (run 'ssh-keygen -lf"
  echo "/etc/ssh/ssh_host_ed25519_key.pub' there):"
  printf '%s\n' "$scan" | ssh-keygen -lf -
  printf '%s\n' "$scan" | run_root tee -a /root/.ssh/known_hosts >/dev/null
fi

# ---- Everything past here needs a filled-in .env ---------------------------

set -a
# shellcheck source=/dev/null
. "${STACK_DIR}/.env"
set +a

if [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo
  echo "RESTIC_PASSWORD is empty in ${STACK_DIR}/.env."
  echo
  echo "Generate one, WRITE IT DOWN SOMEWHERE OUTSIDE THIS LAB, put it in the"
  echo "file, then re-run this script. Losing it means losing the repository:"
  echo
  echo "  openssl rand -base64 32"
  echo
  exit 1
fi

echo "==> Initialising the restic repository (if it isn't already)"
if run_root env RESTIC_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_PASSWORD="$RESTIC_PASSWORD" \
     restic cat config >/dev/null 2>&1; then
  echo "    already initialised"
else
  run_root env RESTIC_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_PASSWORD="$RESTIC_PASSWORD" \
    restic init
fi

echo "==> Installing the systemd units"
for unit in ${UNITS}; do
  sed "s#@REPO_ROOT@#${REPO_ROOT}#g" "${STACK_DIR}/${unit}" \
    | run_root tee "/etc/systemd/system/${unit}" >/dev/null
done
run_root systemctl daemon-reload
run_root systemctl enable --now restic-backup.timer restic-check.timer

echo
echo "Done. Timers:"
run_root systemctl list-timers 'restic-*' --no-pager
echo
echo "Run the first backup by hand rather than waiting for 01:00 — the first"
echo "one uploads everything and may take a while:"
echo
echo "  sudo ${STACK_DIR}/run.sh"
```

- [ ] **Step 2: Syntax check**

```bash
bash -n scripts/init-backup.sh
```

Expected: no output.

- [ ] **Step 3: Verify it matches the house style of the other init scripts**

```bash
grep -c "set -euo pipefail" scripts/init-backup.sh
grep -c "run_root()" scripts/init-backup.sh
grep -n "BASH_SOURCE" scripts/init-backup.sh
```

Expected: `1`, `1`, and a `SCRIPT_DIR` line resolving from `$BASH_SOURCE`.

- [ ] **Step 4: Verify no literal IP address was introduced**

```bash
grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' scripts/init-backup.sh infra/backup/*.sh infra/backup/.env.example
```

Expected: no output.

- [ ] **Step 5: Fix the file mode and commit**

```bash
git add scripts/init-backup.sh
git update-index --chmod=+x scripts/init-backup.sh
git ls-files -s scripts/init-backup.sh
```

Expected: mode `100755`.

```bash
git commit -m "feat(backup): add scripts/init-backup.sh"
```

---

### Task 7: Authentik's restore script

**Files:**
- Create: `infra/authentik/restore.sh`

**Interfaces:**
- Consumes: `infra/backup/.env` for restic credentials; snapshots tagged `authentik` produced by Task 4.
- Produces: an executable taking an optional snapshot id (default `latest`).

- [ ] **Step 1: Write `infra/authentik/restore.sh`**

```bash
#!/usr/bin/env bash
#
# restore.sh — put Authentik back from a restic snapshot.
#
# Usage:  sudo infra/authentik/restore.sh [snapshot-id]     (default: latest)
#
# THE TRAP THIS EXISTS TO AVOID: Postgres keeps the password its data directory
# was FIRST INITIALISED with. Restoring Authentik's .env next to a
# /opt/authentik/postgres that was initialised with a different PG_PASS leaves a
# stack that cannot log into its own database — a failure that presents as a
# corrupt backup and is not one.
#
# So this script restores data/, templates/, certs/ and .env, and leaves
# postgres/ EMPTY: the container initialises a fresh cluster from the restored
# .env, and the dump then loads into it. The raw PGDATA in the snapshot is never
# restored automatically — it is the last resort for when no dump exists, and
# docs/backup-setup.md says how to use it by hand.

set -euo pipefail

STACK="authentik"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE="/opt/backup/restore/${STACK}"
SNAPSHOT="${1:-latest}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it moves /opt trees around." >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
. "${REPO_ROOT}/infra/backup/.env"
set +a

# ---- 1. Resolve the snapshot and show it -----------------------------------

echo "==> Snapshots tagged ${STACK}:"
restic snapshots --tag "$STACK" --compact

# `restic snapshots` does not accept the pseudo-id `latest` the way `restore`
# does, so resolve it here rather than passing it through. grep instead of jq:
# one less thing to install on a machine you are restoring.
if [ "$SNAPSHOT" = "latest" ]; then
  id="$(restic snapshots --tag "$STACK" --latest 1 --json \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4)"
else
  id="$SNAPSHOT"
fi

if [ -z "$id" ]; then
  echo "no snapshot '${SNAPSHOT}' tagged ${STACK} found." >&2
  exit 1
fi

echo
echo "About to restore ${STACK} from snapshot ${id}."
echo "This stops the stack, moves /opt/${STACK} aside, and REPLACES"
echo "${REPO_ROOT}/infra/${STACK}/.env."
echo
read -r -p "Type '${STACK}' to continue: " answer
if [ "$answer" != "$STACK" ]; then
  echo "aborted."
  exit 1
fi

# ---- 2. Stop the stack -----------------------------------------------------

echo "==> Stopping ${STACK}"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose down )

# ---- 3. Restore into staging, before touching anything live ----------------

echo "==> Restoring snapshot ${id} into ${STAGE}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
restic restore "$id" --target "$STAGE"

# ---- 4. Move the live tree aside — never delete it -------------------------

ts="$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/${STACK}" ]; then
  echo "==> Moving /opt/${STACK} to /opt/${STACK}.bak-${ts}"
  mv "/opt/${STACK}" "/opt/${STACK}.bak-${ts}"
fi

# ---- 5. Put the files back -------------------------------------------------

echo "==> Restoring files"
mkdir -p "/opt/${STACK}"
cp -a "${STAGE}/opt/${STACK}/data"      "/opt/${STACK}/data"
cp -a "${STAGE}/opt/${STACK}/templates" "/opt/${STACK}/templates"
cp -a "${STAGE}/opt/${STACK}/certs"     "/opt/${STACK}/certs"

# EMPTY on purpose — see the header. Postgres initialises into it using the
# password from the .env restored on the next line.
mkdir -p "/opt/${STACK}/postgres"

echo "==> Restoring ${REPO_ROOT}/infra/${STACK}/.env"
cp -a "${STAGE}${REPO_ROOT}/infra/${STACK}/.env" "${REPO_ROOT}/infra/${STACK}/.env"

# ---- 6. Bring the database up, alone ---------------------------------------

echo "==> Starting the database"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d db )

echo -n "==> Waiting for Postgres"
for _ in $(seq 1 60); do
  if ( cd "${REPO_ROOT}/infra/${STACK}" \
       && docker compose exec -T db pg_isready -U "${STACK}" >/dev/null 2>&1 ); then
    echo " ready"
    break
  fi
  echo -n "."
  sleep 2
done

# ---- 7. Load the dump ------------------------------------------------------

dump="${STAGE}/opt/backup/dumps/${STACK}/${STACK}.sql"
if [ ! -f "$dump" ]; then
  echo "no dump at ${dump} — the snapshot has no SQL. See the last-resort" >&2
  echo "PGDATA path in docs/backup-setup.md." >&2
  exit 1
fi

echo "==> Loading ${dump}"
( cd "${REPO_ROOT}/infra/${STACK}" \
  && docker compose exec -T db psql -U "${STACK}" -d "${STACK}" ) < "$dump"

# ---- 8. Bring the rest up --------------------------------------------------

echo "==> Starting the rest of the stack"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify, in this order:

  1. https://auth.thefipster.de loads and you can log in.
  2. Applications and Providers are all present (docs/sso-applications.md).
  3. https://dockge.thefipster.de redirects through Authentik and back —
     that is the forward-auth middleware working, which proves the outpost
     and its token survived.
  4. Grafana's "Sign in with Authentik" button completes a login — that is
     OIDC, the other pattern.

The previous tree is at /opt/${STACK}.bak-${ts}. Delete it once you are
satisfied, not before.
EOF
```

- [ ] **Step 2: Syntax check**

```bash
bash -n infra/authentik/restore.sh
```

Expected: no output.

- [ ] **Step 3: Verify the four guardrails are all present**

```bash
grep -n "Type '\${STACK}' to continue\|\.bak-\|--target \"\$STAGE\"\|mkdir -p \"/opt/\${STACK}/postgres\"" infra/authentik/restore.sh
```

Expected: four matches — the typed confirmation, the move-aside, the staged restore, and the deliberately empty `postgres/`.

- [ ] **Step 4: Verify the script never restores the raw PGDATA**

```bash
grep -n "cp -a.*postgres" infra/authentik/restore.sh
```

Expected: no output. `postgres/` is only ever `mkdir`'d empty.

- [ ] **Step 5: Fix the file mode and commit**

```bash
git add infra/authentik/restore.sh
git update-index --chmod=+x infra/authentik/restore.sh
git ls-files -s infra/authentik/restore.sh
```

Expected: mode `100755`.

```bash
git commit -m "feat(backup): add Authentik's restore script"
```

---

### Task 8: The setup guide

**Files:**
- Create: `docs/backup-setup.md`

**Interfaces:**
- Consumes: everything from Tasks 2–7.
- Produces, for Task 9: a guide at `docs/backup-setup.md` that `uptime-kuma-setup.md` links to and that links on to `apps-vm-setup.md`.

The guide follows the repo's standard structure exactly: headline; `**Runs on:**`; one-line prerequisite; short explanation; numbered steps with verification, **each command in its own fenced block**; jump-off; troubleshooting; layout on the server; detailed explanation / design notes; jump-off repeated.

- [ ] **Step 1: Write the header and the prerequisite line**

```markdown
# Backup — restic, file-level, per stack

**Runs on:** the Proxmox host shell, then the infra VM

Prerequisite: [uptime-kuma-setup.md](uptime-kuma-setup.md) — the backup job
reports to a Kuma push monitor, so Kuma has to exist first.
```

Then a short explanation: this is **layer 2** of [roadmap/backup.md](roadmap/backup.md); layer 1 (whole-VM `vzdump`) is already built in [proxmox-setup.md Part 8](proxmox-setup.md#part-8--schedule-whole-vm-backups). Layer 2 answers "Authentik ate its database" where layer 1 answers "the disk died".

- [ ] **Step 2: Write Part 1 — the host side, on the Proxmox host**

Each command in its own block. Create the chroot on the `usbbackup` pool:

```bash
zfs create usbbackup/chroot
```

```bash
chown root:root /usbbackup/chroot && chmod 755 /usbbackup/chroot
```

Create the user and the writable subdirectory inside the chroot:

```bash
useradd --system --home-dir /usbbackup/chroot --shell /usr/sbin/nologin backup
```

```bash
mkdir -p /usbbackup/chroot/restic && chown backup:backup /usbbackup/chroot/restic && chmod 700 /usbbackup/chroot/restic
```

Install the infra VM's public key — the one `scripts/init-backup.sh` prints:

```bash
mkdir -p /etc/ssh/authorized_keys && chmod 755 /etc/ssh/authorized_keys
```

```bash
nano /etc/ssh/authorized_keys/backup
```

```bash
chown root:root /etc/ssh/authorized_keys/backup && chmod 644 /etc/ssh/authorized_keys/backup
```

Then the sshd configuration, as a **drop-in**:

```bash
nano /etc/ssh/sshd_config.d/backup-sftp.conf
```

```
Match User backup
    ChrootDirectory /usbbackup/chroot
    ForceCommand internal-sftp
    AuthorizedKeysFile /etc/ssh/authorized_keys/backup
    PasswordAuthentication no
    AllowTcpForwarding no
    X11Forwarding no
```

The guide must state, in the body text, the two things that fail silently:

- **The chroot directory must be root-owned and not group-writable**, with the writable `restic/` *inside* it owned by `backup`. Get it wrong and sshd disconnects with no useful error in the client output.
- **A `Match` block claims every line after it.** Using a drop-in file keeps it contained, which is why the guide does not edit `sshd_config` directly — but it is still the single step here that can lock you out of the hypervisor, so it is verified before the daemon is restarted, and from a second terminal that stays logged in.

- [ ] **Step 3: Write Part 1's verification, before restarting sshd**

```bash
sshd -t
```

Expected: no output.

```bash
sshd -T -C user=root | grep -iE 'chrootdirectory|forcecommand'
```

Expected: **no output** — the `Match` block must not apply to root. If anything prints here, do not restart sshd; the drop-in is leaking.

```bash
sshd -T -C user=backup | grep -iE 'chrootdirectory|forcecommand'
```

Expected: `chrootdirectory /usbbackup/chroot` and `forcecommand internal-sftp`.

The guide must instruct: **keep the current SSH session open** and restart from it, then prove a *new* root session still works before closing the old one.

```bash
systemctl restart ssh
```

- [ ] **Step 4: Write Part 2 — the Kuma push monitor**

Create the monitor first and copy its push URL; its row is in [uptime-kuma-monitors.md](uptime-kuma-monitors.md). Heartbeat interval **90000 s** (25 h) with 0 retries — the job runs daily, so the heartbeat window has to be longer than a day, with an hour of slack for `RandomizedDelaySec` and a slow first run.

- [ ] **Step 5: Write Part 3 — the infra VM side**

```bash
scripts/init-backup.sh
```

The script stops and tells you to fill in `RESTIC_PASSWORD`. Generate it:

```bash
openssl rand -base64 32
```

The guide must carry, in bold, that this is **the one secret that cannot be in the backup**, that the authoritative copy lives outside the lab, and that a copy in Vaultwarden alone closes a circle — the vault is inside the backup.

```bash
nano infra/backup/.env
```

Then re-run:

```bash
scripts/init-backup.sh
```

- [ ] **Step 6: Write Part 4 — the first run and its verification**

The guide drives the first run through the **runner**, never through a stack script directly — a bare `infra/authentik/backup.sh` needs `BACKUP_STAGE` and `REPO_ROOT` set by hand and would fail with a guard message. The standalone form belongs in troubleshooting, where its purpose (inspecting one stack's output without restic) is the point.

```bash
sudo infra/backup/run.sh
```

```bash
sudo restic snapshots --tag authentik
```

Expected: one snapshot. Then confirm the Kuma monitor went green, and confirm the timer is armed:

```bash
systemctl list-timers 'restic-*' --no-pager
```

- [ ] **Step 7: Write the restore section**

Covering, in order: `sudo infra/authentik/restore.sh` and what it asks; the **ordering trap** that Traefik must be up before anything is reachable and Authentik before anything it gates, exactly as in the build order; and the **last-resort raw PGDATA path** — when no dump exists, stop the stack, `restic restore --include /opt/authentik/postgres`, put it in place, and accept that it is a torn copy that may not start.

- [ ] **Step 8: Write the jump-off, troubleshooting, layout, and design notes**

Jump-off: [apps-vm-setup.md](apps-vm-setup.md).

Troubleshooting must cover at least:
- `Fatal: unable to open repository` → the host key is not in `/root/.ssh/known_hosts`, or the key is not in `authorized_keys`, or the chroot permissions are wrong. Test with `sudo ssh -i /root/.ssh/id_ed25519 backup@pve.thefipster.de` — it should refuse a shell but not refuse the connection.
- A stack shows as failed but the others succeeded → that is by design; read the unit's journal with `journalctl -u restic-backup.service -n 50`.
- The Kuma monitor is red but the run said OK → `KUMA_PUSH_URL` is empty or wrong in `infra/backup/.env`.
- Running a single stack by hand: `sudo infra/backup/run.sh authentik`.
- Inspecting one stack's staging output without restic at all: `sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/authentik/backup.sh`.

Layout on the server: `/opt/backup/dumps/<stack>/` (overwritten every run), `/opt/backup/restore/<stack>/` (staging for restores), `/etc/systemd/system/restic-*.{service,timer}`, `/root/.ssh/id_ed25519`.

Design notes: why per-stack tags, why plain-format dumps, why `--group-by host,tags`, why the runner does not use `set -e`, why 01:00, and why the raw PGDATA rides along but is never the restore path.

- [ ] **Step 9: Verify the guide's structure matches the house pattern**

```bash
grep -n "^\*\*Runs on:\*\*\|^## " docs/backup-setup.md
```

Expected: a `**Runs on:**` line near the top, and sections in the house order — numbered parts, then jump-off, troubleshooting, layout, design notes.

- [ ] **Step 10: Verify no literal IP addresses**

```bash
grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' docs/backup-setup.md
```

Expected: no output.

- [ ] **Step 11: Commit**

```bash
git add docs/backup-setup.md
git commit -m "docs: add the backup setup guide"
```

---

### Task 9: Wire it into the docs system

**Files:**
- Modify: `docs/uptime-kuma-monitors.md`
- Modify: `docs/dns-records.md`
- Modify: `docs/sso-applications.md`
- Modify: `docs/uptime-kuma-setup.md` (its jump-off)
- Modify: `README.md` (build order)
- Modify: `CLAUDE.md` (the new convention)

**Interfaces:**
- Consumes: `docs/backup-setup.md` from Task 8.
- Produces: a build order that reaches the new guide, and three registries that each record a decision.

- [ ] **Step 1: Add the Kuma monitor row**

In `docs/uptime-kuma-monitors.md`, add a new section after "Hypervisor storage — Proxmox host":

```markdown
## Backup — infra VM

| Name | Type | Target |
|---|---|---|
| Backup Job | Push | *(push URL — the infra VM calls Kuma)* |

The second **Push** monitor, and the second thing in this lab that watches a
condition rather than a service. Heartbeat interval **90000 s** (25 h), 0
retries: the job runs once a day, so the window has to be longer than a day —
with an hour of slack for the timer's `RandomizedDelaySec` and for a first run
that uploads everything.

Only a **fully clean** run pushes. A run where one stack failed exits non-zero
and stays silent, so a partial success shows up here as red rather than as a
green tick over a missing snapshot. That is the whole point: silence is the
signal.

The job and its timer live on the infra VM — [backup-setup.md](backup-setup.md).
Create this monitor first and paste its URL into `infra/backup/.env`.
```

- [ ] **Step 2: Record the DNS non-row**

In `docs/dns-records.md`, under "Names the wildcard covers on purpose" (or the nearest deliberate-absence section), add:

```markdown
**The backup repository needs no new record.** It is
`sftp:backup@pve.thefipster.de:/restic`, and `pve` already has its exact record
above — which it needs anyway, so the wildcard does not answer with the apps VM
and send Alloy to scrape the wrong machine.
```

- [ ] **Step 3: Record the SSO non-entry**

In `docs/sso-applications.md`, after the three "deliberately not joined" sections, add:

```markdown
## The backup job (not an application at all)

`infra/backup/` is a systemd timer on the infra VM
([backup-setup.md](backup-setup.md)). It has no browser UI to gate and speaks no
OIDC, so it is not a candidate for either pattern — recorded here so that the
absence reads as a decision rather than an oversight, the same as the three
above.
```

- [ ] **Step 4: Change Uptime Kuma's jump-off**

In `docs/uptime-kuma-setup.md`, find the "next guide" jump-off (it currently points at `apps-vm-setup.md`) and repoint it at `backup-setup.md`, describing it as the last step on the infra VM. Verify:

```bash
grep -n "apps-vm-setup\|backup-setup" docs/uptime-kuma-setup.md
```

Expected: `backup-setup.md` referenced, `apps-vm-setup.md` no longer referenced as the next step.

- [ ] **Step 5: Update the README build order**

Insert `backup-setup.md` as the last entry of the **infra VM** group, before the apps VM group begins. Verify:

```bash
grep -n "uptime-kuma-setup\|backup-setup\|apps-vm-setup" README.md
```

Expected: `backup-setup` appears between the other two.

- [ ] **Step 6: Document the convention in CLAUDE.md**

Add a section after "The SSO convention (Authentik)":

```markdown
## The backup convention

Backups are **per stack, defined beside the stack**. A stack is backed up by
adding one file, `infra/<stack>/backup.sh`, which sources
`infra/backup/lib.sh` and declares what that stack consists of using three
recipes: `dump_postgres <stack>`, `include <path>`, and `include_env`. There is
no central list — `infra/backup/run.sh` finds stacks by globbing
`infra/*/backup.sh`.

Each stack gets its **own restic snapshot**, tagged with the stack name, so
restoring one is `restic restore latest --tag <stack>` and the stack's couplings
come back as a unit by construction. Those couplings are why the definition
lives beside the stack rather than in a central runner: Authentik's
DB↔`AUTHENTIK_SECRET_KEY` and Vaultwarden's DB↔`rsa_key.pem` are per-stack
facts, and they are commented in the file someone changing that stack will read.

Two rules that are not obvious from one file:

- **`.env` files come from the CHECKOUT, never from `/opt/stacks/<stack>`** —
  those are symlinks, and restic stores a symlink as a symlink rather than
  descending into it. `include_env` resolves against `$REPO_ROOT`.
- **Database dumps are `--format=plain`, not `-Fc`.** A compressed dump changes
  in its entirety when one row changes, which defeats restic's content-defined
  chunking; restic compresses at rest anyway.

Restores are scripted per stack too (`infra/<stack>/restore.sh`), and every one
of them leaves `postgres/` **empty** so the container re-initialises from the
restored `.env` — Postgres keeps the password its data dir was first
initialised with, so a restored `.env` beside an old PGDATA is a stack that
cannot log into its own database. The raw PGDATA rides along in the snapshot as
a last resort and is never the restore path.

Layer 1 (whole-VM `vzdump`) is separate and needs no repo code:
[proxmox-setup.md Part 8](docs/proxmox-setup.md).
```

- [ ] **Step 7: Verify the guide chain is unbroken end to end**

```bash
grep -n "backup-setup.md" README.md docs/uptime-kuma-setup.md docs/uptime-kuma-monitors.md docs/dns-records.md docs/sso-applications.md CLAUDE.md
```

Expected: at least one reference in each of README, `uptime-kuma-setup.md`, `uptime-kuma-monitors.md`, `dns-records.md` and `sso-applications.md`.

```bash
grep -n "apps-vm-setup.md" docs/backup-setup.md
```

Expected: at least one match — the jump-off out of the new guide.

- [ ] **Step 8: Commit**

```bash
git add README.md CLAUDE.md docs/uptime-kuma-monitors.md docs/dns-records.md docs/sso-applications.md docs/uptime-kuma-setup.md
git commit -m "docs: put the backup guide in the build order and the registries"
```

---

### Task 10: Operator verification on the VM

Not implementable from the checkout — this is the checklist the operator runs on the real machines, and **no earlier task may claim any of it as done**. It exists here so the plan states what "working" means.

**Files:** none.

- [ ] **Step 1: Host side** — `sudo ssh -i /root/.ssh/id_ed25519 backup@pve.thefipster.de` from the infra VM refuses a shell but does not refuse the connection; a *new* root SSH session to the hypervisor still works after the sshd restart.
- [ ] **Step 2: One stack, no restic** — `sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/authentik/backup.sh` produces `authentik.sql` and a **six-line** `paths.txt` in `/tmp/t`: the SQL dump, `data`, `templates`, `certs`, `postgres`, and the checkout's `.env`.
- [ ] **Step 3: A full run** — `sudo infra/backup/run.sh` exits 0; `sudo restic snapshots --tag authentik` lists one snapshot.
- [ ] **Step 4: The deadman** — temporarily break `infra/authentik/backup.sh` (an `include` of a path that does not exist), run again, confirm exit is non-zero, confirm **no** Kuma push happened and the monitor goes red. Restore the file.
- [ ] **Step 5: The snapshot is complete** — `sudo restic restore latest --tag authentik --target /tmp/r` yields `data`, `templates`, `certs`, the `.env` under the checkout path, and the SQL under `/opt/backup/dumps/authentik/`.
- [ ] **Step 6: The timer fires** — `systemctl list-timers 'restic-*'` shows both armed; after the first 01:00, `journalctl -u restic-backup.service` shows a clean run and Kuma stayed green.

A full restore-into-a-live-stack drill is **roadmap phase 5** and is not part of this plan.
