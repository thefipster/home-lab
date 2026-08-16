# Task: Backup for the apps VM

Goal: the data under `/data/<stack>` on the apps VM survives a lost disk and a
bad deploy — the promise the infra VM already keeps, extended to the one machine
holding tier-1 data that no layer covers.

**Why this outranks everything else.** Layer 1 excludes the 300 GB data disk
(`backup=0`, [proxmox-setup.md Part 5](../../docs/guides/proxmox-setup.md#part-5--create-the-vms)),
and the machine has never joined the restic repository — so `/data` is covered
by **nothing**. Paperless-ngx is tier 1: scanned documents whose originals are
paper, or gone ([apps/services.md](../../apps/services.md)). Every other open
task risks convenience or visibility; this one loses documents. Today's whole
answer is Paperless' own `document_exporter`, run by hand.

## What already exists

The transport was designed for this day
([done/backup.md — Where layer 2 writes](done/backup.md#where-layer-2-writes)):
the `resticbackup` SFTP account on the hypervisor is deliberately shared rather
than per-machine, so joining is

- one more key line in the host's `authorized_keys` for `resticbackup`,
- restic plus an `.env` on the apps VM pointing at the same
  `sftp:resticbackup@pve.thefipster.de:/restic`,

and the retention grouping (`--group-by host,tags`) was chosen so a second host
joins without re-shuffling what "seven dailies" means. The tier inventory exists
too: [apps/services.md](../../apps/services.md) tiers every catalogued stack and
states that `/data/docker` must stay unbacked.

## What the design must answer

- **The inventory.** Which `/data/<stack>` trees exist and which databases the
  catalogued stacks actually run. The infra recipes cover Postgres and SQLite; a
  MariaDB recipe was explicitly left "to the apps VM" — verify what each stack
  runs before assuming it is needed.
- **Coolify's own store.** App definitions live in Coolify's database and
  nowhere else — the catalog records what runs and why, never how. Decide
  whether `/data/coolify` is tier 1 or accepted clickwork, and say so either way.
- **Where the per-stack definition lives.** The infra convention — `backup.sh`
  beside the compose file — cannot transfer literally: this machine's compose
  files live in their own Forgejo repos and its runtime is owned by Coolify. The
  collector ([apps/alloy](../../apps/alloy)) is the precedent for machine-owned
  pieces living under `apps/`.
- **What restore means here.** Coolify recreates containers from its store; the
  drill has to prove that data restored under a recreated resource is actually
  adopted, not merely present on disk.
- **Its own deadman.** A second Kuma push monitor for the new timer — one job,
  one heartbeat, exactly as the infra VM's `run.sh` does, including only
  pinging on a fully clean run.

## Recommendation

Do this first, and start with a spec (`dev/specs/`) answering the questions
above — the mechanics are a solved problem, the inventory and the Coolify
restore semantics are not. Keep two timers on two machines writing to one
repository rather than teaching `infra/backup/run.sh` to reach across the LAN:
per-machine jobs are what the shared-account transport was designed for, and a
backup that depends on another VM being up inherits that VM's outages.
