# Roadmap: Backup & restore (infra VM)

Goal: make every piece of **irreplaceable state on the infra VM** survive a
lost disk, a lost VM, and a bad `rm -rf` — with a restore procedure that has
actually been run, not just written down.

Half the problem is already solved and worth naming: **the configuration is
not at risk.** Compose files, init scripts, provisioning, guides and the three
registries ([dns-records.md](../dns-records.md),
[sso-applications.md](../sso-applications.md),
[uptime-kuma-monitors.md](../uptime-kuma-monitors.md)) live in git, on GitHub, mirrored
into Forgejo. What is *not* in git is exactly what this roadmap is about: the
bind-mounted data under `/opt/<stack>`, and the gitignored `.env` files.

> **Vaultwarden changed the stakes of phase 2, and nothing else about this
> plan.** Every other tier-1 entry below is painful to lose; the vault
> ([vaultwarden-setup.md](../vaultwarden-setup.md)) is the one whose loss is
> *unrecoverable by any other means*, because it is where the credentials for
> rebuilding everything else are kept. Layer 1 already covers it — a whole-VM
> `vzdump` of the infra VM includes `/opt/vaultwarden` like any other
> directory, and that is real coverage, not a placeholder. What it does not
> give is a granular restore, an off-premises copy, or the ability to recover
> the vault without rolling the entire VM back.
>
> **The vault has now joined phase 2.** `infra/vaultwarden/backup.sh` and its
> `restore.sh` exist, so the vault has a granular restore, an encrypted
> off-machine copy, and a recovery path that does not roll the whole VM back —
> the three things layer 1 could not give it. That closes the gap this note was
> written about.
>
> Two things it does **not** change. `RESTIC_PASSWORD` still cannot live only
> in the vault, because the vault is inside the backup — keep the
> authoritative copy outside the lab, on paper or in an account that survives
> the building. The same goes for the Vaultwarden master password, for the same
> reason.

## What needs a backup

Every stack keeps its state in bind mounts under `/opt/<stack>` (the repo
convention), so the inventory is a walk of that tree plus the `.env` files
that make it openable.

### Tier 1 — irreplaceable; this is the backup set

| What | Path | Why it can't be rebuilt |
|---|---|---|
| **Vaultwarden DB** | `/opt/vaultwarden/postgres` | **The vault itself** — every credential the lab has, including the ones needed to repair the rest of this table. Nothing regenerates it and nothing else holds a copy. |
| **Vaultwarden data** | `/opt/vaultwarden/data` | Attachments, Sends, and `rsa_key.pem` — the key that signs every access token. See the coupling below: this is not optional beside the row above. |
| Forgejo data | `/opt/forgejo/forgejo` | Git repos, LFS, attachments, **container-registry blobs**, `app.ini`, SSH host keys, the instance's internal/JWT secrets. The repos are pull-mirrors of GitHub, so those come back — the **registry does not**, and it is what the apps VM pulls from. |
| Forgejo DB | `/opt/forgejo/postgres` | Users, the Authentik OIDC source, issues/PRs, Actions history, and **package metadata** — registry blobs without it are unaddressable garbage. |
| Authentik DB | `/opt/authentik/postgres` | Every application, provider, flow, policy, group and user. This is the entire body of clickwork that `sso-applications.md` describes; the registry records the *values*, not the objects. |
| Authentik data/templates/certs | `/opt/authentik/data`, `/templates`, `/certs` | Branding uploads and any signing keypairs created in the UI. Small, and nothing regenerates them. |
| Uptime Kuma | `/opt/uptime-kuma` | SQLite: monitors, the ntfy notification config, status pages, heartbeat history, the admin bcrypt hash. The monitor registry ([uptime-kuma-monitors.md](../uptime-kuma-monitors.md)) makes it *re-creatable*, by hand, one form at a time. |
| Traefik ACME store | `/opt/traefik/letsencrypt/acme.json` | The Let's Encrypt account key **and** the wildcard cert. Reissuable — at ~10–15 min of netcup propagation, and against the duplicate-certificate rate limit (5/week) if the reissue loop goes wrong. Contains a private key: encrypt it. |
| All `.env` files | `infra/{traefik,vaultwarden,authentik,forgejo,monitoring}/.env` | netcup API credentials, four Postgres passwords, `AUTHENTIK_SECRET_KEY`, the Vaultwarden `ADMIN_TOKEN` hash, the Grafana OIDC client secret, break-glass admin passwords. Gitignored on purpose, generated once, **never printed again**. |

Three couplings in that table decide the shape of the whole thing:

- **`rsa_key.pem` and the Vaultwarden database are one unit.** The key under
  `/opt/vaultwarden/data` signs every access token the server issues, and the
  database holds what those tokens address. Restore either without the other
  and every client is logged out of a vault it can no longer prove anything
  against. Same failure as the Authentik pairing below, one directory apart
  instead of one file.
- **`AUTHENTIK_SECRET_KEY` encrypts secrets stored in the Authentik DB.** A
  restored `/opt/authentik/postgres` without the matching key is a database
  full of undecryptable values. The DB and the `.env` must be captured
  together, or the backup is decorative.
- **Postgres keeps the password its data dir was first initialized with** —
  the `.env.example` files already say so. Restore a `postgres` directory
  next to a regenerated `.env` and the stack cannot log into its own database.
- **The `.env` files are reachable only through the checkout, not through
  `/opt/stacks`.** `/opt/stacks/<stack>` are *symlinks* into
  `~/home-lab/infra/<stack>`, and restic stores a symlink as a symlink rather
  than descending into it. Backing up `/opt/stacks` therefore captures the
  links and none of the secrets. The paths in the diagram below name
  `infra/*/.env` separately for exactly this reason — it is not redundancy.

**Dockge's `.env` is deliberately not in that row.** It holds exactly
`REPO_DIR=…`, rewritten by `scripts/init-dockge.sh` on every run. There is no
secret in it and nothing to lose.

### Tier 2 — cheap to include, mildly annoying to lose

| What | Path | Note |
|---|---|---|
| Grafana DB | `/opt/monitoring/postgres` | Datasources, dashboards and alert rules are **provisioned from the repo**, so only hand-made UI objects, users and API keys are unique here. Include it — it's small — but it is not why this project exists. |
| Forgejo runner registration | `/opt/forgejo/runner/.runner` | One small file. Re-registering needs a fresh token from the Forgejo UI; backing it up skips a manual step. |
| Dockge data | `/opt/stacks/dockge/data` | Dockge's own accounts. Kilobytes. |

### Tier 3 — deliberately **not** backed up

Stating these is half the design; a backup that hauls the TSDB around nightly
is a backup nobody keeps running.

- **Prometheus (15 d), Loki (14 d), Tempo (7 d)** — `/opt/monitoring/{prometheus,loki,tempo}`.
  Observability data with short retention *by design*
  ([roadmap/monitoring.md](monitoring.md) already calls snapshots + short
  retention the durability story). Restoring three-week-old metrics has no
  value that justifies the bytes.
- **Alloy** `/opt/monitoring/alloy` — WAL and log positions. Self-healing; a
  restore would only replay stale offsets.
- **Grafana's file state** `/opt/monitoring/grafana` — with
  `GF_DATABASE_TYPE: postgres` this directory holds only the plugin dir (nothing
  installs plugins here) and the renderer/CSV cache. There is no `grafana.db`,
  because the backend is not SQLite. The Grafana *database* is Tier 2 above and
  is a different path.
- **Docker images and layers** — pullable, and CI rebuilds what it built.
- **The repo checkout at `~/home-lab`** — it's a clone; `git clone` restores
  it. Only its untracked `.env` files matter, and those are Tier 1 above.
- **The Homepage stack** — `infra/homepage/` and nothing else. It has no `/opt`
  directory and no `.env`; its compose and all nine config files are tracked in
  this repo. It is the only stack with no `backup.sh` and no `restore.sh`, and
  the reason is the bullet above: backing it up would be backing up a clone.

### Not on the infra VM, but part of the same story

- **UDR DNS records** — router-side, no export worth automating.
  [dns-records.md](../dns-records.md) *is* the backup.
- **The netcup public zone + API credentials** — netcup's problem, plus the
  `.env` above.
- **The Proxmox host** — `/etc/pve`, and the `prometheus-node-exporter` unit
  that `grafana-setup.md` installs by hand. Out of scope here; folded into
  phase 1 because the host's backup job is where whole-VM backups live anyway.
- **The apps VM (Coolify)** — its own state, its own story. Not this roadmap.
- **The home-assistant VM** — HAOS is an appliance and ships its own backup
  mechanism (*Settings → System → Backups*), which is what it uses. Layer 1
  covers its disk; nothing in this repo drives its file-level backups, the same
  way nothing here drives its configuration.

## Decision: two layers, not one

Neither available mechanism covers both failure modes, and they fail in
opposite directions — so run both, at different frequencies.

**Layer 1 — Proxmox `vzdump`, whole-VM, for disaster recovery.** ✅ **built**
Answers "the SSD died" / "I broke the VM beyond repair" with a single restore
that brings back the OS, Docker, the checkout and every `/opt` tree at once.
Requires no code in this repo. All three things this roadmap said were missing —
a **schedule**, the **qemu-guest-agent** for fs-freeze, and a **target that is
not the boot pool** — now exist as
[proxmox-setup.md Part 8](../proxmox-setup.md#part-8--schedule-whole-vm-backups):
a nightly job onto the `backup` mirror, which is dedicated 1 TB on different
physical drives, deliberately double the 500 GB root pool so retention is
possible rather than a single copy.

**Layer 2 — `restic`, file-level, encrypted, offsite, for data recovery.**
Answers "Authentik ate its database", "which version of that repo was it
yesterday", and "the house burned down". Granular, deduplicated, and small
enough to send off-premises daily. Its target is the **external 500 GB USB
NVMe** — see [Where layer 2 writes](#where-layer-2-writes).

Why not just one:

- vzdump alone is coarse (no "restore this one directory"), lives on the same
  premises unless a second box exists, and every restore is an all-or-nothing
  rollback of the entire VM — including the thing you *didn't* want to lose.
- restic alone doesn't rebuild a VM. After a disk failure you'd be
  re-running the whole build order from `proxmox-setup.md` before there was
  anywhere to restore *into*.

### Why restic for layer 2

| Candidate | Verdict |
|---|---|
| **restic** ✅ | Single static binary, no daemon, nothing to install on the remote. **Client-side encryption**, so a cheap untrusted target (B2, netcup Storage Space, a NAS share) is fine for `acme.json` and `.env` files. Content-addressed dedup — nightly Forgejo registry blobs cost almost nothing after the first run. Backends: local, SFTP, S3/B2, rclone. `forget --prune` for retention, `check --read-data-subset` to prove the repo is readable. |
| Borg | Better compression/dedup ratios, but wants `borg` installed on the remote for efficient SSH transport, which rules out plain object storage without an extra layer. |
| duplicity | Full+incremental chains make a restore only as good as the whole chain. A corrupt increment poisons everything after it. |
| rsnapshot / rsync+hardlinks | No encryption at all — disqualifying for `.env` and ACME private keys on an off-site target. |
| `offen/docker-volume-backup` | Genuinely tempting: a compose container, which matches how everything else here is shaped. But it wants the **docker socket** for its stop/start hooks — a seventh root-equivalent socket mount for scheduling that a systemd timer already does — and its Postgres story still bottoms out at "run your own dump". |
| Proxmox Backup Server | The right answer *if a second machine exists* — dedup, incremental, verify jobs, and it makes layer 1 genuinely offsite. Running PBS as a VM on the host it protects is the classic anti-pattern. Revisit when there is a NAS or a mini-PC to put it on. |

### Where layer 2 writes

The target is the **external 500 GB USB 3.1 NVMe**, a single-disk ZFS pool
(`usbbackup`) created on the Proxmox host in
[proxmox-setup.md Part 3](../proxmox-setup.md#part-3--post-install-housekeeping).
It is phase 2's "local target first" — **not** a replacement for phase 3. Offsite
still stands; this is the drive that gets the mechanism debugged without also
debugging cloud credentials, and it is the only copy that can physically leave
the building.

**Transport: SFTP against the Proxmox host's existing `sshd`.** restic speaks
SFTP natively, so the drive stays mounted on the hypervisor and the repository
is `sftp:resticbackup@pve.thefipster.de:/restic`. A dedicated unprivileged
`resticbackup` user, key-only, one key per client, confined with
`ChrootDirectory` + `ForceCommand internal-sftp` — the chroot directory must be
root-owned and not group-writable, which is the usual thing to get wrong.

**Not `backup`, and not a per-machine name.** Debian ships a stock `backup`
system account (uid 34, `/var/backups`, used by `cron.daily`) and Proxmox VE is
Debian, so that name is taken. The replacement is not named after a machine
either, because the account is shared by every *client* of the repository — the
apps VM joins it later with its own key, which is the whole point of choosing
this transport.

Three options were weighed, and the deciding factor is **who else will need this
drive**:

| Option | Verdict |
|---|---|
| **SFTP over the existing sshd** ✅ | No new daemon on a host this repo deliberately keeps free of workloads. Both VMs reach the same repository, so the apps VM joins later with a key and an `.env` value rather than a redesign. |
| USB passthrough to the infra VM | Simplest — restic writes to a local path — but it binds the drive to one guest. Re-sharing it from there to the apps VM is strictly worse than sharing it from the host that owns it. |
| NFS/SMB share from the host | Same reach, but it adds a file server to the hypervisor and a network hop with its own failure modes, to achieve what a daemon already running achieves. |

**Sizing.** 500 GB against a set dominated by Forgejo's registry blobs, which
grow monotonically. restic's dedup absorbs repeated image layers well but cannot
delete what the registry never expires — so the registry-hygiene item in
[ci-supply-chain.md](ci-supply-chain.md) phase 3 is also the lever on whether
this drive stays big enough.

**One obligation this creates.** Layer 1 excludes the apps VM's 300 GB data disk
(`backup=0`, [proxmox-setup.md Part 5](../proxmox-setup.md#part-5--create-the-vms)),
so that disk is covered by *nothing* until the apps VM runs its own restic job —
which this roadmap scopes out. That is deliberate and currently harmless: the
apps VM has no services on it yet. It stops being harmless the day it does, and
the transport above is chosen so that day is a key and a config value rather than
a rethink.

### Why dumps, not raw directory copies, for the databases

Four Postgres instances (`vaultwarden`, `authentik`, `forgejo`, `grafana` — all
`postgres:18-alpine`) and one SQLite (Kuma). Copying a live `PGDATA` yields a
torn snapshot; stopping four stacks nightly is downtime this lab has no
reason to take. `pg_dump` runs against a **live** database — the same argument
[monitoring's phase-1 spec](../superpowers/specs/2026-07-26-monitoring-phase1-design.md)
used to pick Postgres over SQLite for Grafana in the first place. Running it as
`docker compose exec -T db pg_dump` uses the container's own client, so the
dump tool always matches the server version.

There is **no MariaDB on the infra VM** — all four databases are
`postgres:18-alpine` — so there is no MariaDB recipe. That belongs to the apps
VM, which this roadmap scopes out.

The raw `PGDATA` directories still ride *inside* the restic snapshot — the
diagram's whole-`/opt/<stack>` paths include them, and `monitoring/postgres`
is listed by name precisely so Grafana's database comes along while the
re-collectable stores beside it (Prometheus, Loki, Tempo) stay out. That is
belt and braces, not a second restore path: a live-copied `PGDATA` is torn by
construction, so a restore starts from the dumps, and the raw copy is the
last resort for when no dump exists.

Kuma is the exception and needs deciding at implementation time: its SQLite is
open with WAL, so a live file copy is torn too. Preferred fix is
`sqlite3 ... ".backup"` — pending a check that the binary exists in
`louislam/uptime-kuma:2`; fallback is a tiny `alpine` sidecar holding the same
bind mount. Stopping Kuma for the copy is the option to *avoid*: it is the
watcher, and a blind spot in the watcher is exactly what its own compose file
argues against.

## Architecture

```
        ┌─ Layer 1: vzdump nightly, snapshot mode + guest agent   ✅ built
        │     infra + apps + HA roots ──► `backup` pool ──► "the VM is gone" restore
Proxmox │        (2×1 TB SATA mirror, 2× the root pool, retention on the storage)
 host   │
        └─ `usbbackup` pool (500 GB USB NVMe), served over SFTP by the host's sshd
                                    ▲
infra VM                            │
  pg_dump ×4 ─┐                     │
  sqlite .backup ─┼─► /opt/backup/dumps ─┐
  /opt/{vaultwarden,forgejo,authentik,uptime-kuma,traefik,monitoring/postgres} ─┼─► restic ─┘  (encrypted)
  infra/*/.env ──────────────────────────┘                          │
                                                                    └─► Kuma push URL (deadman)

apps VM (later) ─── same repository, its own key ───────────────────────┘
```

Layer 2 is a **systemd timer**, not a compose stack — deliberately. A backup
that runs inside Docker is a backup that stops when Docker does, and the
alternative (a container that can stop other containers) means a seventh socket
mount. Precedent exists: the Proxmox node exporter is a systemd unit too.

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

**The one secret that cannot be in the backup: `RESTIC_PASSWORD`.** Lose it and
the repository is cryptographically gone. It belongs in a password manager and
on paper, before the first `restic init` — not in `/opt/backup/.env` alone.

**And "a password manager" cannot mean *this* password manager, alone.** The
lab now runs its own ([vaultwarden-setup.md](../vaultwarden-setup.md)), and
storing `RESTIC_PASSWORD` only there closes a circle: the vault is in the
backup, the backup key is in the vault, and losing the infra VM loses both at
once. Keep it in the vault by all means — that is the convenient copy — but the
authoritative one is outside the lab entirely. On paper, or in an account that
survives the building. Same for the Vaultwarden master password, for the same
reason.

## Phases

1. ~~**Layer 1 — whole-VM backups, no repo code.**~~ ✅ **done** —
   [proxmox-setup.md Part 8](../proxmox-setup.md#part-8--schedule-whole-vm-backups).
   Nightly *Datacenter → Backup* job in snapshot mode onto the `backup` mirror,
   with `qemu-guest-agent` in every guest for the fs-freeze and retention set on
   the storage. Was the biggest coverage-per-effort item in the roadmap, and it
   is the one piece of this design that needed no repo code at all.
2. ~~**Layer 2 — the dump + restic job, USB target.**~~ ✅ **built and
   running** — [backup-setup.md](../backup-setup.md). `infra/backup/`,
   `scripts/init-backup.sh`, the four systemd units, and the per-stack shape
   described above. The repository is the `usbbackup` pool over SFTP
   ([Where layer 2 writes](#where-layer-2-writes)) — local first, so the
   mechanism got debugged without also debugging cloud credentials. Retention
   `--group-by host,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6`; a
   weekly `restic check`. Host-side prerequisites — the `resticbackup` user,
   its chroot, one authorized key per client — are Part 1 of the guide and run
   on the hypervisor. The Kuma push (phase 4) landed here rather than later: a
   backup nobody knows has stopped is decorative.

   **The recipe set is complete and every exception is spent.** Four stacks
   are wired. The first three were chosen in that order deliberately — each
   was the last remaining unknown of its kind — and the fourth is the one the
   whole phase was prioritised for:

   - **Authentik** — the Postgres shape, and the DB↔secret-key coupling the
     per-stack design exists for.
   - **Uptime Kuma** — settled `dump_sqlite`'s open question. The image ships
     `/usr/bin/sqlite3`, so no `alpine` sidecar, and the recipe dumps through
     the stack's own client exactly as `dump_postgres` does.
   - **monitoring** — the only stack whose directory and database names differ
     (`monitoring` vs `grafana`), so the only caller of `dump_postgres`'s
     override arguments: `dump_postgres monitoring db grafana grafana`. Also
     the only **narrow** restore: it touches `postgres/` alone and leaves the
     five Tier-3 directories beside it untouched, because they are not in the
     snapshot and destroying them would throw away live data the backup never
     promised to return.

   - **Vaultwarden** — the plainest mechanics of the four (single-argument
     `dump_postgres`, two includes, `include_env`) and the highest stakes.
     `rsa_key.pem` under `data/` signs every access token; the database holds
     what those tokens address. Restore one without the other and you get a
     working server, an intact vault, and every client logged out with no way
     to prove anything — so `restore.sh` checks for `rsa_key.pem` by name
     rather than trusting that `data/` exists.

   - **Forgejo** — single-argument `dump_postgres`, three includes,
     `include_env`, and the largest snapshot of the set. It carries three quiet
     couplings with its database: the container-registry **blobs** live in the
     files while their **package metadata** lives in the database; `app.ini`
     holds the instance's `SECRET_KEY`/`INTERNAL_TOKEN`; and the SSH host keys
     are in there too. Its `.env` also holds `DOCKER_GID`, the one
     machine-specific value in the repo — `restore.sh` compares the restored
     value against the live docker group and warns, because a stale gid breaks
     only the runner and nothing else looks wrong.

   - **Traefik** and **Dockge** — the include-only form, no database, and
     between them one more lesson. Dockge turned out to need a **narrow
     restore** as well, for a different reason than monitoring's: it is the
     one stack *copied* into `/opt/stacks` rather than symlinked, so its
     directory also holds a `compose.yaml` and a `.env` that
     `scripts/init-dockge.sh` writes and the backup does not carry. The rule
     that caught it — *where a stack's `/opt` directory holds anything not in
     its snapshot, do not move the whole tree* — had been written down one
     stack earlier, and found its second case immediately.

   **Every tier-1 and tier-2 row above now has a `backup.sh` and a
   `restore.sh`.** Phase 2 is complete.
3. **Offsite.** Point (or replicate) the repository at B2 / netcup Storage
   Space / rclone. Client-side encryption means the target is untrusted by
   construction — no additional design needed, only credentials and a
   bandwidth check against the first full upload. This is what makes 3-2-1
   true rather than aspirational. **The USB drive does not close this phase:**
   it is the second copy, on the same premises and plugged into the machine it
   protects. Unplugging it and carrying it elsewhere is a valid third copy only
   for as long as someone actually does — and nothing here can alert on a human
   step that didn't happen.
4. **Notice when it stops.** ✅ folded into phase 2 — `run.sh` pings an Uptime
   Kuma push monitor, and only a fully clean run does.

   Two things remain. The **weekly `restic check` has no heartbeat of its
   own**: it is a separate unit and nothing pushes on its behalf, so a
   repository that has quietly become unreadable stays quiet. Today that is
   found with `systemctl status restic-check.service`, which means finding it
   requires already suspecting it — the gap is stated rather than fixed, and
   the guide says so too. Second, the optional
   `backup_last_success_timestamp` metric for Alloy's textfile collector, for
   the "why" half; it needs a `textfile` block on `prometheus.exporter.unix`
   and has not been built.

   One thing this phase learned the hard way: the push URL is the part that
   breaks. Kuma displays it with a query string attached, `.env` is sourced as
   shell, and `&` there is a command separator — so pasting it verbatim leaves
   `KUMA_PUSH_URL` empty and the heartbeat silently unarmed. A warning in the
   guide did not prevent it on the first real bring-up; `run.sh` now detects
   that exact signature and fails loudly instead.
5. **Prove it.** ⚠️ **Partly done — all seven stacks drilled**, recorded in
   [review/2026-08-07-backup-bring-up.md](../review/2026-08-07-backup-bring-up.md).
   Each drill used the same method: change something *after* the backup, run
   `restore.sh`, confirm the change is gone and everything else survived.

   **Authentik** — a user created after the backup was correctly absent
   afterwards. That is the coupling this design exists to protect,
   demonstrated rather than asserted: the restored database is the backup's
   database, and `AUTHENTIK_SECRET_KEY` still decrypts what is inside it, so
   the `.env` and the dump came back as one unit.

   **Uptime Kuma** — a throwaway monitor created after the backup was gone
   afterwards, with monitors, groups, notification bindings and heartbeat
   history all intact. It also verified the ownership mechanism: rebuilding
   through the stack's own image means the new `kuma.db` lands owned by
   whatever UID that image runs as, with no `chown` to get wrong.

   **monitoring** — the Grafana theme was switched from dark to light after
   the backup and came back dark. A per-user preference row makes a good
   marker: unambiguous at a glance, and nothing to clean up afterwards. It
   also proved the **narrow restore** — Prometheus, Loki and Tempo still
   returned data from before it, which is what shows the script left the five
   Tier-3 directories alone rather than moving the whole tree.

   **Vaultwarden** — a new item and an attachment added after the backup were
   both gone afterwards, and **a client that was already paired logged in
   without re-authenticating**. That last one is the result this whole roadmap
   was written around: `rsa_key.pem` and the database came back as a unit, so
   the vault has a granular restore that has actually been performed rather
   than described. A fresh browser login would have proved none of it.

   **Forgejo** — packages deleted from the registry after the backup were back
   afterwards. That is a better marker than the guide first suggested: creating
   a repository proves the database rolled back and leaves the registry to be
   inferred, while deleting a package exercises the thing this stack's shape
   exists to protect. It is also the only marker in the drill guide that risks
   anything, since a failed restore leaves the package deleted.

   The **Kuma push is confirmed** too: found misconfigured during the same
   bring-up (the query string trap in phase 4), corrected, and a run then
   delivered its heartbeat and turned the monitor green.

   Still unproven, and not to be claimed until it is:
   a **VM-rollback** drill rather than an in-place restore,
   the nightly timer firing unattended, the weekly `restic check`, and the
   deadman's *silent* half — nothing has yet watched the monitor go **red**
   because a heartbeat did not arrive, which is the property the arrangement
   exists for. The full drill still reads: roll the infra VM
   back to a snapshot, restore from restic, verify each stack comes up —
   Vaultwarden accepting a login from a client that was already paired (which
   is what proves `rsa_key.pem` and the database came back together), Authentik
   with its providers intact, Forgejo serving a `docker pull`, Kuma with its
   monitors.

   The procedure is [backup-restore-drill.md](../backup-restore-drill.md) —
   what to mark before each restore, and what each stack's result actually
   proves. Record each further drill in `docs/review/` as its own dated
   finding, the same way the guide replays were. **Treat every phase as untested for the
   parts no drill has covered.** Re-run yearly.

## Constraints & notes

- **Order matters within a run.** Dump databases *first*, then let restic
  walk `/opt` — so the dumps in `/opt/backup/dumps` belong to the same run as
  the file trees around them.
- **Sizing.** Forgejo's registry blobs dominate and grow monotonically; the
  registry-hygiene item in [ci-supply-chain.md](ci-supply-chain.md) phase 3
  (keep last N tags / max age) is also a backup-size lever. restic's dedup
  handles repeated image layers well, but it cannot delete what the registry
  never expires.
- **Restore is a documented procedure or it doesn't exist.** `docs/backup-setup.md`
  must carry the restore path — including the ordering trap that Traefik has
  to be up before anything is reachable and Authentik before anything it
  gates, exactly as in the build order.
- **Clock skew after a rollback** is the one failure mode a restore drill will
  hit first: a restored/rolled-back guest resumes with a stale clock and every
  TLS client fails with "certificate has expired or is not yet valid".
  `init-host.sh` already handles it on the infra VM
  ([proxmox-setup.md Part 7](../proxmox-setup.md#part-7--snapshot-before-you-build));
  expect to see it during the drill and don't misdiagnose it as a bad restore.
- **Non-goals:** continuous replication, PITR/WAL archiving, HA. This is a
  one-person lab — a daily RPO is the right answer, and anything tighter buys
  complexity nobody is on call for.
