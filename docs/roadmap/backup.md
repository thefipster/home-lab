# Roadmap: Backup & restore (infra VM)

Goal: make every piece of **irreplaceable state on the infra VM** survive a
lost disk, a lost VM, and a bad `rm -rf` — with a restore procedure that has
actually been run, not just written down.

Half the problem is already solved and worth naming: **the configuration is
not at risk.** Compose files, init scripts, provisioning, guides and the two
registries ([dns-records.md](../dns-records.md),
[sso-applications.md](../sso-applications.md)) live in git, on GitHub, mirrored
into Forgejo. What is *not* in git is exactly what this roadmap is about: the
bind-mounted data under `/opt/<stack>`, and the gitignored `.env` files.

## What needs a backup

Every stack keeps its state in bind mounts under `/opt/<stack>` (the repo
convention), so the inventory is a walk of that tree plus the `.env` files
that make it openable.

### Tier 1 — irreplaceable; this is the backup set

| What | Path | Why it can't be rebuilt |
|---|---|---|
| Forgejo data | `/opt/forgejo/forgejo` | Git repos, LFS, attachments, **container-registry blobs**, `app.ini`, SSH host keys, the instance's internal/JWT secrets. The repos are pull-mirrors of GitHub, so those come back — the **registry does not**, and it is what the apps VM pulls from. |
| Forgejo DB | `/opt/forgejo/postgres` | Users, the Authentik OIDC source, issues/PRs, Actions history, and **package metadata** — registry blobs without it are unaddressable garbage. |
| Authentik DB | `/opt/authentik/postgres` | Every application, provider, flow, policy, group and user. This is the entire body of clickwork that `sso-applications.md` describes; the registry records the *values*, not the objects. |
| Authentik data/templates/certs | `/opt/authentik/data`, `/templates`, `/certs` | Branding uploads and any signing keypairs created in the UI. Small, and nothing regenerates them. |
| Uptime Kuma | `/opt/uptime-kuma` | SQLite: monitors, the ntfy notification config, status pages, heartbeat history, the admin bcrypt hash. The guide's monitor inventory makes it *re-creatable*, by hand, one form at a time. |
| Traefik ACME store | `/opt/traefik/letsencrypt/acme.json` | The Let's Encrypt account key **and** the wildcard cert. Reissuable — at ~10–15 min of netcup propagation, and against the duplicate-certificate rate limit (5/week) if the reissue loop goes wrong. Contains a private key: encrypt it. |
| All `.env` files | `infra/{traefik,authentik,forgejo,monitoring}/.env`, `/opt/stacks/dockge/.env` | netcup API credentials, three Postgres passwords, `AUTHENTIK_SECRET_KEY`, the Grafana OIDC client secret, break-glass admin passwords. Gitignored on purpose, generated once, **never printed again**. |

Two couplings in that table decide the shape of the whole thing:

- **`AUTHENTIK_SECRET_KEY` encrypts secrets stored in the Authentik DB.** A
  restored `/opt/authentik/postgres` without the matching key is a database
  full of undecryptable values. The DB and the `.env` must be captured
  together, or the backup is decorative.
- **Postgres keeps the password its data dir was first initialized with** —
  the `.env.example` files already say so. Restore a `postgres` directory
  next to a regenerated `.env` and the stack cannot log into its own database.

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
- **Docker images and layers** — pullable, and CI rebuilds what it built.
- **The repo checkout at `~/home-lab`** — it's a clone; `git clone` restores
  it. Only its untracked `.env` files matter, and those are Tier 1 above.

### Not on the infra VM, but part of the same story

- **UDR DNS records** — router-side, no export worth automating.
  [dns-records.md](../dns-records.md) *is* the backup.
- **The netcup public zone + API credentials** — netcup's problem, plus the
  `.env` above.
- **The Proxmox host** — `/etc/pve`, and the `prometheus-node-exporter` unit
  that `grafana-setup.md` installs by hand. Out of scope here; folded into
  phase 1 because the host's backup job is where whole-VM backups live anyway.
- **The apps VM (Coolify)** — its own state, its own story. Not this roadmap.

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
| `offen/docker-volume-backup` | Genuinely tempting: a compose container, which matches how everything else here is shaped. But it wants the **docker socket** for its stop/start hooks — a fifth root-equivalent socket mount for scheduling that a systemd timer already does — and its Postgres story still bottoms out at "run your own dump". |
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
is `sftp:backup@pve.thefipster.de:/restic`. A dedicated unprivileged `backup`
user, key-only, one key per client, confined with `ChrootDirectory` +
`ForceCommand internal-sftp` — the chroot directory must be root-owned and not
group-writable, which is the usual thing to get wrong.

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

Three Postgres instances (`authentik`, `forgejo`, `grafana` — all
`postgres:16-alpine`) and one SQLite (Kuma). Copying a live `PGDATA` yields a
torn snapshot; stopping three stacks nightly is downtime this lab has no
reason to take. `pg_dump` runs against a **live** database — the same argument
[monitoring's phase-1 spec](../superpowers/specs/2026-07-26-monitoring-phase1-design.md)
used to pick Postgres over SQLite for Grafana in the first place. Running it as
`docker compose exec -T db pg_dump` uses the container's own client, so the
dump tool always matches the server version.

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
  pg_dump ×3 ─┐                     │
  sqlite .backup ─┼─► /opt/backup/dumps ─┐
  /opt/{forgejo,authentik,uptime-kuma,traefik,monitoring/postgres} ─┼─► restic ─┘  (encrypted)
  infra/*/.env ──────────────────────────┘                          │
                                                                    └─► Kuma push URL (deadman)

apps VM (later) ─── same repository, its own key ───────────────────────┘
```

Layer 2 is a **systemd timer**, not a compose stack — deliberately. A backup
that runs inside Docker is a backup that stops when Docker does, and the
alternative (a container that can stop other containers) means a fifth socket
mount. Precedent exists: the Proxmox node exporter is a systemd unit too. The
repo still owns the files, same as every other stack:

```
infra/backup/
  backup.sh          dump → restic backup → forget --prune → ping Kuma
  restic-backup.service / .timer
  .env.example       RESTIC_REPOSITORY (sftp:backup@pve.thefipster.de:/restic),
                     RESTIC_PASSWORD, KUMA_PUSH_URL
scripts/init-backup.sh   installs the unit, creates /opt/backup, seeds .env, restic init
docs/backup-setup.md     the guide, once phase 2 lands
```

**The one secret that cannot be in the backup: `RESTIC_PASSWORD`.** Lose it and
the repository is cryptographically gone. It belongs in a password manager and
on paper, before the first `restic init` — not in `/opt/backup/.env` alone.

## Phases

1. ~~**Layer 1 — whole-VM backups, no repo code.**~~ ✅ **done** —
   [proxmox-setup.md Part 8](../proxmox-setup.md#part-8--schedule-whole-vm-backups).
   Nightly *Datacenter → Backup* job in snapshot mode onto the `backup` mirror,
   with `qemu-guest-agent` in every guest for the fs-freeze and retention set on
   the storage. Was the biggest coverage-per-effort item in the roadmap, and it
   is the one piece of this design that needed no repo code at all.
2. **Layer 2 — the dump + restic job, USB target.** `infra/backup/` as above,
   `scripts/init-backup.sh`, `docs/backup-setup.md`. The repository is the
   `usbbackup` pool over SFTP ([Where layer 2 writes](#where-layer-2-writes)) —
   local first, so the mechanism gets debugged without also debugging cloud
   credentials. Retention `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`; a
   weekly `restic check`. Host-side prerequisites: the `backup` user, its
   chroot, and one authorized key per client.
3. **Offsite.** Point (or replicate) the repository at B2 / netcup Storage
   Space / rclone. Client-side encryption means the target is untrusted by
   construction — no additional design needed, only credentials and a
   bandwidth check against the first full upload. This is what makes 3-2-1
   true rather than aspirational. **The USB drive does not close this phase:**
   it is the second copy, on the same premises and plugged into the machine it
   protects. Unplugging it and carrying it elsewhere is a valid third copy only
   for as long as someone actually does — and nothing here can alert on a human
   step that didn't happen.
4. **Notice when it stops.** A silent backup failure is indistinguishable
   from a backup. `backup.sh` curls an **Uptime Kuma push monitor** on
   success; Kuma alerts through ntfy when the heartbeat doesn't arrive — a
   deadman switch built from infrastructure that already exists, and it lands
   on the side of the split ([Kuma notifies, Grafana
   explains](../uptime-kuma-setup.md)) that this belongs on. Optionally also
   write a `backup_last_success_timestamp` metric for Alloy's textfile
   collector, for the "why" half.
5. **Prove it.** Restore drill: roll the infra VM back to a snapshot, restore
   from restic, verify each stack comes up — Authentik with its providers
   intact, Forgejo serving a `docker pull`, Kuma with its monitors. Record it
   in `docs/review/` as a dated finding, the same way the guide replay was.
   **Until this phase runs, treat phases 1–4 as untested.** Re-run yearly.

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
