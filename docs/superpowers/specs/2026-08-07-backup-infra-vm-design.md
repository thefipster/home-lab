# Design: file-level backup for the infra VM (roadmap phase 2, first slice)

**Date:** 2026-08-07
**Roadmap:** [roadmap/backup.md](../../roadmap/backup.md) phase 2
**Scope:** the shared mechanism plus **one** stack — Authentik — end to end.

Layer 1 (whole-VM `vzdump`) is built and lives in
[proxmox-setup.md Part 8](../../proxmox-setup.md#part-8--schedule-whole-vm-backups).
This spec is layer 2: file-level, encrypted, restorable one stack at a time.

## What this slice delivers

A nightly `restic` job on the infra VM that produces a **tagged snapshot per
stack**, driven by a per-stack backup definition that lives next to the stack's
compose file — and, for Authentik, a restore script that actually puts it back.
The remaining six stacks are each one new file after this lands.

Deliberately **not** in scope: the other six stacks, the `dump_sqlite` recipe,
offsite replication (roadmap phase 3), the restore drill (phase 5), and the
optional `backup_last_success_timestamp` textfile metric.

## Corrections to the roadmap

The roadmap was written before Vaultwarden landed and before the repo grew its
current shape. Six things in it no longer match, and all six are fixed as part
of this work.

1. **`/opt/monitoring/grafana` was in no tier at all**, which made the inventory
   non-exhaustive — the one property a backup inventory has to have. It is
   **Tier 3**. With `GF_DATABASE_TYPE: postgres` the directory holds only the
   plugin dir (nothing installs plugins here) and the renderer/CSV cache; there
   is no `grafana.db`, because the backend is not SQLite.
2. **`/opt/stacks/dockge/.env` was listed as a Tier-1 secret.** It holds exactly
   `REPO_DIR=…`, rewritten by `scripts/init-dockge.sh` on every run. Dropped
   from the backup set entirely.
3. **The `.env` files are reachable only through the checkout.**
   `/opt/stacks/<stack>` are *symlinks* into `~/home-lab/infra/<stack>`, and
   restic stores a symlink as a symlink rather than descending into it. The
   roadmap's diagram already listed `infra/*/.env` separately and was therefore
   correct by accident; the reason is now written down, so it does not get
   "simplified" away later.
4. **The Home Assistant VM had no row** under *Not on the infra VM, but part of
   the same story*, although the apps VM, the Proxmox host, the UDR and netcup
   each had one. HAOS uses its own built-in backup mechanism. One line, stated
   as a decision rather than a gap.
5. **No MariaDB exists on the infra VM.** All four databases are
   `postgres:18-alpine`. A `dump_mariadb` recipe would ship untested with no
   caller; MariaDB belongs to the apps VM, which this roadmap scopes out.
6. **Phase 2 described one monolithic `backup.sh`** that knew about all seven
   stacks inline. Replaced by the per-stack shape below.

One thing the roadmap got right and is worth restating, because the design leans
on it: the four Postgres stacks are **uniform**. Service `db`, and
`POSTGRES_USER == POSTGRES_DB == <stack>` in all of
[authentik](../../../infra/authentik/compose.yaml),
[vaultwarden](../../../infra/vaultwarden/compose.yaml),
[forgejo](../../../infra/forgejo/compose.yaml) and
[monitoring](../../../infra/monitoring/compose.yaml). That uniformity is what
lets `dump_postgres` take a single argument.

## Architecture

```
infra/backup/
  lib.sh                 recipe functions, sourced by every <stack>/backup.sh
  run.sh                 the runner
  restic-backup.service  + .timer   nightly 01:00
  restic-check.service   + .timer   weekly
  .env.example           RESTIC_REPOSITORY, RESTIC_PASSWORD, KUMA_PUSH_URL
infra/authentik/
  backup.sh              what Authentik's backup consists of
  restore.sh             the inverse, with guardrails
scripts/init-backup.sh
docs/backup-setup.md
```

**The runner discovers stacks by globbing `infra/*/backup.sh`.** There is no
list to keep in sync — adding a stack is one file. Order does not matter,
because each stack gets its own snapshot.

### The contract between runner and stack script

Three inputs and one output file:

- The runner exports `BACKUP_STAGE=/opt/backup/dumps/<stack>` (created and
  emptied first) and `REPO_ROOT`, then **executes** `infra/<stack>/backup.sh`.
- The stack script writes dump files into `$BACKUP_STAGE` and the paths it wants
  snapshotted into `$BACKUP_STAGE/paths.txt`.
- The runner runs `restic backup --tag <stack> --files-from
  $BACKUP_STAGE/paths.txt`, plus the stage directory itself.

**Executed, not sourced.** Sourcing would let `include` append to a shared array
and save the intermediate file, but it would also make a stack script
unrunnable on its own. Executing means `sudo infra/authentik/backup.sh` produces
a directory you can inspect, with no repository, no password and no network
involved — the difference between a thing that can be tested and a thing that
can only be run.

The stage directory is **overwritten every run**. History lives in restic, not
in a pile of timestamped local files that grow until the disk is full.

### The stack definition

`infra/authentik/backup.sh` in full:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

dump_postgres authentik

include /opt/authentik/data       # uploads, media
include /opt/authentik/templates
include /opt/authentik/certs      # signing keypairs created in the UI
include /opt/authentik/postgres   # raw PGDATA — last resort; the dump is the restore path

# AUTHENTIK_SECRET_KEY decrypts secrets held in the database above. That
# database without this file is a database full of undecryptable values.
include_env
```

**`readlink -f` in that `source` line is not decoration.** `/opt/stacks/authentik`
is a symlink into the checkout, so a script invoked by that path would resolve
`../backup/lib.sh` to `/opt/stacks/backup/lib.sh`, which does not exist.
Resolving the symlink first makes the script work by either path.

The comment is the reason for the per-stack shape. Authentik's DB↔secret-key
coupling and Vaultwarden's DB↔`rsa_key.pem` coupling are **per-stack facts**;
they belong beside the stack, where someone changing it will read them, not in
a central runner or a manifest's comment field.

### The recipes

Three exist in the design; two are built in this slice.

**`dump_postgres <stack> [service] [user] [db]`** — runs
`docker compose exec -T db pg_dump` from `$REPO_ROOT/infra/<stack>`, writing
`$BACKUP_STAGE/<stack>.sql`. Service defaults to `db`, user and database to
`<stack>`. Using the container's own client means the dump tool always matches
the server version.

Two flag choices worth recording:

- **`--format=plain`, not `-Fc`.** A compressed dump changes in its entirety
  when a single row changes, which defeats restic's content-defined chunking.
  Plain SQL deduplicates well across nightly runs, and restic compresses it at
  rest anyway (`--compression auto`, default since restic 0.14) — so plain text
  costs nothing in stored size and buys most of the dedup.
- **`--clean --if-exists`**, so the dump loads into an existing database rather
  than requiring a hand-dropped one.

**`include <path>`** — the "copy files" recipe, and the honest name is
*declare*: it appends to `paths.txt` and copies nothing. restic reads the live
tree directly, which is both faster and dedup-friendlier than staging a copy.
`include_env` is sugar for `$REPO_ROOT/infra/<stack>/.env`.

**`dump_sqlite`** — designed, not built. Its only caller is Uptime Kuma, and it
carries an open question: whether `sqlite3` exists inside
`louislam/uptime-kuma:2`, or whether it needs a small `alpine` sidecar holding
the same bind mount. It lands with the Kuma slice. Stopping Kuma for a file copy
stays the option to avoid — it is the watcher, and a blind spot in the watcher
is what its own compose file argues against.

**No `dump_mariadb`** — see correction 5.

### Consistency within a run

Databases are dumped **before** restic walks the file trees, so the dumps in
`$BACKUP_STAGE` belong to the same run as the files around them. Authentik's
`data`, `templates` and `certs` are near-static (branding uploads, certificates
created once in the UI), so live-walking them alongside a dump taken seconds
earlier is not a real inconsistency. The same holds for Vaultwarden's
`rsa_key.pem`, which never changes after creation.

## Restore

`infra/authentik/restore.sh`. Guardrails first, then the sequence.

**Guardrails.** It resolves the snapshot (`--tag authentik latest`, or an
explicit `--snapshot <id>`), **prints that snapshot's id and timestamp**, and
requires the operator to type the stack name to proceed. It restores into
`/opt/backup/restore/authentik/` before touching anything live, and moves the
existing tree to `/opt/authentik.bak-<timestamp>` rather than deleting it. A
mistyped invocation must not be a data-loss event.

**The trap this exists to avoid.** Postgres keeps the password its data
directory was **first initialized with**. Restore Authentik's `.env` next to a
`/opt/authentik/postgres` that was initialized with a different `PG_PASS`, and
the stack cannot log into its own database — a failure that presents as a
corrupt backup and is not one. This is the roadmap's third coupling, and it is
the reason restore has to be scripted rather than improvised.

So the script restores `data`, `templates`, `certs` and `.env`, and leaves
`postgres/` **empty**: the container initializes a fresh cluster from the
restored `.env`, and the dump then loads into it. The raw `PGDATA` captured in
the snapshot is never restored automatically — it is the last resort for when
no dump exists, and the guide says so in those words.

Sequence:

1. Resolve snapshot, print it, require typed confirmation.
2. `docker compose down`.
3. `restic restore` into `/opt/backup/restore/authentik/`.
4. `mv /opt/authentik /opt/authentik.bak-<ts>`.
5. Put back `data`, `templates`, `certs`, and the `.env` into the checkout.
6. `docker compose up -d db`; wait for the healthcheck.
7. `psql < authentik.sql`.
8. `docker compose up -d`.
9. Print what to verify.

Restore scripts are code that runs only in an emergency, which means it is never
exercised in between. Roadmap phase 5's drill is what keeps it honest, and the
drill is the reason a script beats prose here: the drill exercises the script,
whereas it would only ever exercise one operator's reading of a paragraph.

## The runner

`infra/backup/run.sh`, as **root**. The `/opt` trees are owned by the UIDs their
images run as (postgres 999, forgejo 1000, grafana 472), so nothing else can
read all of them, and it needs the Docker socket for `pg_dump` regardless.

Per stack: empty the stage, execute `backup.sh`, `restic backup --tag <stack>`.

**A failing stack is recorded and skipped, not fatal** — one broken stack must
not cost the other six their snapshots. It does make the run exit non-zero, and
a non-zero run **does not ping Kuma**. Silence is the signal, so a partial
success is treated as a failure rather than reported green.

After every stack: `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly
6 --prune`, then the Kuma push.

A second weekly unit runs `restic check --read-data-subset=10%`. Reading a
rotating tenth verifies the whole repository over roughly ten weeks without
reading all of it nightly.

**Schedule: 01:00, one hour before vzdump.** Deliberate, and it buys a property
for free — layer 1's 02:00 whole-VM archive then contains the *current* night's
dumps, so even a coarse VM rollback lands with fresh SQL beside it. It also
stays clear of the 04:30 unattended-upgrades reboot window.
`Persistent=true`, so a VM that was down at 01:00 catches up on boot.

The Kuma push copies the shape of
[Part 9's `zfs-health-push.sh`](../../proxmox-setup.md#part-9--notice-when-a-mirror-degrades)
exactly — same `status=up` / `msg=` form, same `--max-time 10`. This is the
second user of an existing pattern, not a new one.

The roadmap's optional `backup_last_success_timestamp` metric is out of scope:
it needs Alloy's `prometheus.exporter.unix` to grow a `textfile` block, which is
a monitoring-stack change with its own verification.

## Installation

`scripts/init-backup.sh` on the infra VM, matching the existing script style
(`set -euo pipefail`, `$BASH_SOURCE` path resolution, a `run_root()` helper,
committed mode `100755`, LF endings):

1. Install `restic` from apt.
2. Create `/opt/backup/{dumps,restore}`.
3. Seed `infra/backup/.env` from `.env.example`.
4. Generate root's SSH keypair if absent and **print the public key** to install
   on the host.
5. `ssh-keyscan` the Proxmox host into `known_hosts`, printing the fingerprint
   to verify by eye — a systemd timer cannot answer a TOFU prompt, so this has
   to happen at install time.
6. `restic init` if the repository does not already exist.
7. Install the four unit files with `REPO_ROOT` substituted, enable both timers.

### Host-side prerequisites

Run **first**, on the Proxmox host: a `backup` user, its chroot, one authorized
key per client, and `/restic` on the `usbbackup` pool. Two gotchas the guide
must carry, because both fail silently:

- **The chroot directory must be root-owned and not group-writable**, with the
  writable `/restic` *inside* it owned by `backup`. Getting this wrong
  disconnects sshd with no useful error.
- **The `Match User backup` block goes at the very end of `sshd_config`.**
  Everything after a `Match` belongs to it — placed mid-file, it silently
  rewrites the rules for root's own SSH access. This is the one step in the
  project that can lock you out of the hypervisor.

## Docs and registries

New `docs/backup-setup.md`, `**Runs on:** the Proxmox host shell, then the infra
VM` — the same two-machine form `proxmox-setup.md` already uses. It is the
**last step of the infra VM**: `uptime-kuma-setup.md` gains it as its jump-off,
it jumps off to `apps-vm-setup.md`, and the README build order is updated. That
placement is also a dependency, not just an ordering: the Kuma push monitor has
to exist before the runner can report to it.

It follows the standard guide structure, and its restore section carries the
build-order trap the roadmap names — Traefik has to be up before anything is
reachable, and Authentik before anything it gates.

All three registries get a decision, per the repo convention that a registry
which only records what exists cannot tell you whether a gap was deliberate:

- **`uptime-kuma-monitors.md`** — a new push-monitor row for the infra VM
  backup job.
- **`dns-records.md`** — **no new row**, stated as a non-row. The repository is
  `sftp:backup@pve.thefipster.de`, and `pve` already has its exact record —
  which it needs anyway, so the wildcard does not answer with the apps VM.
- **`sso-applications.md`** — a **deliberate non-entry**. A systemd timer has no
  browser UI to gate and no OIDC to speak.

## Verification

There is no test system here; correctness is verified by reading and by running
the thing on the VM. The sequence that proves this slice:

1. `sudo infra/authentik/backup.sh` alone produces `authentik.sql` and
   `paths.txt` in `/opt/backup/dumps/authentik`, with no restic involved.
2. `sudo infra/backup/run.sh` produces one snapshot; `restic snapshots --tag
   authentik` lists it.
3. The Kuma push monitor goes green, and stays green on the next timer firing.
4. Breaking one stack's `backup.sh` makes the run exit non-zero and leaves Kuma
   red — the deadman path, tested on purpose rather than assumed.
5. `restic restore` of the tag into a scratch directory shows `data`,
   `templates`, `certs`, `.env` and the SQL all present in one snapshot.

Full restore-into-a-live-stack verification belongs to roadmap phase 5's drill
and is not claimed by this slice.

## Follow-ups this creates

- Six more stacks, one file each: vaultwarden, forgejo, monitoring, traefik,
  uptime-kuma, dockge. Forgejo's `.runner` registration file is an `include`
  inside forgejo's own definition, not a stack of its own; dockge's is a single
  `include /opt/stacks/dockge/data` with no dump and no `.env`.
- `dump_sqlite`, with the `louislam/uptime-kuma:2` question answered.
- Roadmap phase 3 (offsite) and phase 5 (the drill).
- Optionally, the `backup_last_success_timestamp` textfile metric via Alloy.
