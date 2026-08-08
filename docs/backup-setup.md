# Backup — restic, file-level, per stack

**Runs on:** the Proxmox host shell, then the infra VM

**Prerequisite:** [homepage-setup.md](homepage-setup.md) complete — it is the
last stack on this VM. The backup job also reports to a Kuma push monitor, so
[uptime-kuma-setup.md](uptime-kuma-setup.md) has to be done as well.

This is **layer 2** of [roadmap/backup.md](roadmap/backup.md). Layer 1 —
whole-VM `vzdump` onto the internal `backup` mirror — is already built, in
[proxmox-setup.md Part 8](proxmox-setup.md#part-8--schedule-whole-vm-backups),
and the two answer different questions. **Layer 1 answers "the disk died".
Layer 2 answers "Authentik ate its database"**: one directory, one stack, one
night, restored without rolling the whole machine back to it.

[restic](https://restic.net/) is a single static binary with no daemon and
nothing to install on the far end. It encrypts client-side, deduplicates by
content, and speaks SFTP natively — so the repository is the **`usbbackup`
pool** on the hypervisor ([proxmox-setup.md Part
3](proxmox-setup.md#part-3--post-install-housekeeping)), reached over the
Proxmox host's existing `sshd` as
`sftp:resticbackup@pve.thefipster.de:/restic`.

Three things shape everything below:

- **It is a systemd timer, not a compose stack.** A backup that runs inside
  Docker stops when Docker does, and the alternative — a container allowed to
  stop other containers — means a seventh root-equivalent socket mount for
  scheduling a timer already does. Precedent: the Proxmox node exporter.
- **A stack's backup is defined beside the stack.** `infra/<stack>/backup.sh`
  says what that stack consists of; `infra/backup/run.sh` finds them by
  globbing `infra/*/backup.sh` and takes one snapshot per stack, **tagged with
  the stack name**. There is no list to keep in sync, and adding a stack is one
  file.
- **Every stack on this VM that holds state is wired up end to end**, each with
  a `backup.sh` and a `restore.sh` beside its compose file. Between them they
  cover every shape there is: four Postgres stacks, one SQLite, two with no
  database at all, and two whose restores are deliberately narrow. Every row of
  the tier-1 table in
  [roadmap/backup.md](roadmap/backup.md#tier-1--irreplaceable-this-is-the-backup-set)
  is covered. **Homepage is the one stack with neither file** — it has no `/opt`
  directory and no `.env`, so a snapshot of it would be a snapshot of a git
  checkout ([homepage-setup.md](homepage-setup.md#design-notes)).

## Part 1 — The host side: a user, a chroot, and one sshd block

**Runs on the Proxmox host shell, as root.** Nothing here is Docker and nothing
here is in this repo — the hypervisor owns the drive, so the hypervisor owns
the account that writes to it.

What you are building: an unprivileged `resticbackup` user that can do exactly
one thing — SFTP into a directory on the `usbbackup` pool — and cannot get a
shell, forward a port, or see any other part of the filesystem.

> **You need one thing from the infra VM first: root's public key.**
> `scripts/init-backup.sh` generates and prints it, and its **first** run stops
> long before it needs anything from this host. So if you have not run it yet,
> jump ahead to [Part 3](#part-3--the-infra-vm-side), run it once, and come back
> with the key in the clipboard. On a VM where it has already run,
> `sudo cat /root/.ssh/id_ed25519.pub` prints it again.

Create the chroot as its own dataset on the backup pool:

```bash
zfs create usbbackup/chroot
```

```bash
chown root:root /usbbackup/chroot && chmod 755 /usbbackup/chroot
```

Create the user, then the one writable directory *inside* the chroot:

```bash
useradd --system --home-dir /usbbackup/chroot --shell /usr/sbin/nologin resticbackup
```

```bash
mkdir -p /usbbackup/chroot/restic && chown resticbackup:resticbackup /usbbackup/chroot/restic && chmod 700 /usbbackup/chroot/restic
```

> **Not `backup`, and not `infrabackup` either.** Debian ships a stock `backup`
> system account — uid 34, home `/var/backups`, used by `cron.daily` — and
> Proxmox VE is Debian, so `useradd … backup` refuses before it starts. The
> replacement is deliberately *not* named after a machine: this account is
> shared by every **client** of the repository, not owned by one of them. The
> apps VM joins the same repository later with its own key, and `run.sh` already
> passes `--group-by host,tags` so two hosts can share one repo — `infrabackup`
> would be wrong the day that happens.

> **The two `chown`/`chmod` lines above are the step that fails silently.** The
> chroot directory itself must be **root-owned and not group-writable** —
> sshd refuses to chroot into anything else, and the entire path above it has to
> satisfy the same rule. The writable part is `restic/` *inside* it, owned by
> `resticbackup`. Get it wrong and the session is closed the instant it opens,
> with nothing useful in the client's output: restic reports only that it cannot
> open the repository, and the reason is in the *host's* journal.

That `restic/` is also why the repository path is `/restic` and not
`/usbbackup/chroot/restic` — inside the chroot, the chroot **is** the root.

Install the infra VM's public key. It goes outside the chroot, in a directory
sshd reads as root, because anything inside a chroot the confined user can write
is a place they could install their own key:

```bash
mkdir -p /etc/ssh/authorized_keys && chmod 755 /etc/ssh/authorized_keys
```

**The key is `root`'s on the infra VM, not your own user's.** Print it there:

```bash
sudo cat /root/.ssh/id_ed25519.pub
```

It is one line, starts `ssh-ed25519`, and ends with the comment
`restic-backup@infra` — which is how you tell it apart from any other key you
have lying around. `scripts/init-backup.sh` generated it and printed it on its
first run; if you have not run that yet, see the note at the top of this part.

> **Why root's and not yours.** The job is a systemd unit with `User=root`
> (`infra/backup/restic-backup.service`), because the `/opt` trees are owned by
> whatever UID each image runs as — postgres 999, forgejo 1000, grafana
> 472 — so no single non-root user can read all of them, and `pg_dump` needs
> the Docker socket anyway. Your own key would work perfectly when you test
> the connection by hand and then fail every night at 01:00, which is the
> worst shape a mistake can take here: it looks correct exactly once.

Back on the Proxmox host, paste that single line into:

```bash
nano /etc/ssh/authorized_keys/resticbackup
```

Then:

```bash
chown root:root /etc/ssh/authorized_keys/resticbackup && chmod 644 /etc/ssh/authorized_keys/resticbackup
```

One key per client, one line each — the apps VM joins the same repository later
by adding a second line here, not by redesigning anything.

Now the sshd configuration, as a **drop-in**:

```bash
nano /etc/ssh/sshd_config.d/backup-sftp.conf
```

```
Match User resticbackup
    ChrootDirectory /usbbackup/chroot
    ForceCommand internal-sftp
    AuthorizedKeysFile /etc/ssh/authorized_keys/resticbackup
    PasswordAuthentication no
    AllowTcpForwarding no
    X11Forwarding no
```

> **A `Match` block claims every line after it, to the end of the file.** There
> is no "end match" directive — the next `Match`, or EOF, is what closes it. Put
> this in `sshd_config` directly and any option that happens to follow it
> silently applies to `resticbackup` only; put something after it later and you
> have reconfigured a user you did not mean to touch. A drop-in keeps the block
> contained by construction, which is why this guide never edits `sshd_config`.
>
> **It is still the one step in this guide that can lock you out of the
> hypervisor.** So it gets verified before the daemon is restarted, and the
> restart happens from a session that stays open.

### Verify before restarting sshd

Syntax first:

```bash
sshd -t
```

Expected: **no output**.

Then the question that matters — does the block leak onto anyone else?

```bash
sshd -T -C user=root | grep -iE 'chrootdirectory|forcecommand'
```

Expected: **both lines present, and both reading `none`** — in either order:

```
chrootdirectory none
forcecommand none
```

`sshd -T` dumps the *effective* configuration including defaults, so these two
keywords always print; `none` is what "no chroot, no forced command" looks like.
It is the **value** you are checking, not whether a line appeared.

If either shows a real value instead, root would be chrooted and forced into
`internal-sftp` on the next login — that is a locked-out hypervisor. **Do not
restart sshd.** Fix the drop-in first.

Then the same question in the positive:

```bash
sshd -T -C user=resticbackup | grep -iE 'chrootdirectory|forcecommand'
```

Expected: `chrootdirectory /usbbackup/chroot` and `forcecommand internal-sftp`.
If *this* one also reads `none` for both, the drop-in is not being read at
all — check that `sshd_config` still carries its
`Include /etc/ssh/sshd_config.d/*.conf` line, and that the filename ends in
`.conf`.

Only with both results correct, and **from a terminal you keep open**:

```bash
systemctl restart ssh
```

Then open a **second** terminal and log in as root normally. Once that works,
and not before, close the first one. A restart does not disturb existing
sessions, so the old terminal is the way back if the new login is refused.

## Part 2 — The Kuma push monitor

The job reports to Uptime Kuma, and it reports by **pushing**: Kuma cannot run
a shell command, so the thing being watched calls in instead. This is the second
push monitor in the lab, after the hypervisor's pool health
([proxmox-setup.md Part 9](proxmox-setup.md#part-9--notice-when-a-mirror-degrades)),
and it has the same shape — create the monitor first, because its URL is an
input to the next part.

Its row is in
[uptime-kuma-monitors.md](uptime-kuma-monitors.md#backup--infra-vm): **Add New
Monitor**, type **Push**, heartbeat interval **90000 s**, retries **0**, with
the ntfy notification attached. Copy the push URL — **and cut the query string
off it**.

> **Kuma shows the URL with a query string already attached**, like
> `https://uptime.thefipster.de/api/push/TOKEN?status=up&msg=OK&ping=`. Keep
> only the part up to the token; delete everything from the `?` onward.
>
> This is not tidiness. `infra/backup/.env` is **sourced as shell** by
> `run.sh`, and `&` there is a command separator: the assignment runs in a
> background subshell, never reaches the parent, and `KUMA_PUSH_URL` ends up
> **empty**. The push is then skipped by the emptiness guard, so not even the
> "Kuma push failed" warning prints — backups succeed every night while the
> monitor goes red after 25 hours and stays red. `run.sh` builds the query
> itself with `curl --get --data-urlencode`, so the part you delete was
> redundant anyway.

**90000 s is 25 hours, and the hour of slack is deliberate.** The job runs once
a day, so the heartbeat window has to be longer than a day or a perfectly
healthy lab goes red every night. The extra hour absorbs the timer's
`RandomizedDelaySec` and a first run that uploads everything.

**Only a fully clean run pushes.** A run where one stack failed exits non-zero
and says nothing, so a partial success surfaces here as red rather than as a
green tick over a missing snapshot. Silence is the signal — which is exactly
what a heartbeat monitor is for.

## Part 3 — The infra VM side

**Runs on the infra VM** from here on.

```bash
cd ~/home-lab
```

```bash
scripts/init-backup.sh
```

The script installs restic, creates `/opt/backup` mode 700, seeds
`infra/backup/.env` from `.env.example`, and generates `/root/.ssh/id_ed25519`
if it does not exist. Then it does two things that need you:

**It prints the public key.** That is the one Part 1 wants in
`/etc/ssh/authorized_keys/resticbackup`.

**It records the Proxmox host key, and prints its fingerprint.** This is a
*different* key from the one above, pointing the other way — and the two are
easy to conflate, so:

| Key | Lives on | Proves | Ends up in |
|---|---|---|---|
| `/root/.ssh/id_ed25519` | infra VM | the infra VM, **to** the host | `authorized_keys` (Part 1) |
| `/etc/ssh/ssh_host_ed25519_key` | Proxmox host | the host, **to** the infra VM | `known_hosts` (here) |

A systemd timer cannot answer a trust-on-first-use prompt, so the host key has
to be accepted now. But `ssh-keyscan` believes whatever answers it — accepting
that unverified is just trusting the network. So the script prints the
fingerprint it *received*, and you check it against the real one. On the
**Proxmox host**:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare that `SHA256:…` string with the one the script printed on the infra
VM. If the script's output has scrolled away, re-print what actually landed:

```bash
sudo ssh-keygen -lF pve.thefipster.de
```

If they do not match, stop and remove the line the script appended to
`/root/.ssh/known_hosts` before doing anything else.

Then the script stops, because `RESTIC_PASSWORD` is empty. Generate one:

```bash
openssl rand -base64 32
```

> **This is the one secret that cannot be in the backup.** Lose it and the
> repository is cryptographically gone — no recovery, no support, no reset, and
> nobody to ask. **The authoritative copy belongs outside the lab**: on paper,
> or in an account that survives the building.
>
> **A copy in Vaultwarden alone closes a circle.** The vault is *inside* this
> backup. Storing the key only there means losing the infra VM loses both at
> once — the backup and the only thing that can open it. Keep it in the vault by
> all means; that is the convenient copy, not the authoritative one. The same
> reasoning applies to the Vaultwarden master password, for the same reason.

Put it, and the Kuma push URL from Part 2, into the `.env`:

```bash
nano infra/backup/.env
```

`RESTIC_REPOSITORY` is already correct. `KUMA_PUSH_URL` ships as a shape with
`changeme` where the token goes — replace that word, and **nothing else**, with
the token from Part 2.

Leave every line as plain `KEY=value` with no quoting, no `export`, no `$`, and
none of `&`, `?` or `#` — this file is read **twice**, once by `run.sh` as
shell and once by systemd as an `EnvironmentFile` for `restic-check.service`.
systemd does not run a shell over it and will not tell you it skipped a line;
the shell, worse, does not skip a line it dislikes — it **runs** it. `&` ends
the command (the assignment goes to a background subshell and never reaches the
parent), `?` is where a URL's query string starts and therefore where the `&`
comes from, and a `#` after a space is a comment to the shell and part of the
value to systemd.

Then re-run:

```bash
scripts/init-backup.sh
```

This time it gets past the gate: `restic init` creates the repository over
SFTP — the first real proof that Part 1 worked — and the four systemd units are
installed with `@REPO_ROOT@` substituted for the checkout path, then
`restic-backup.timer` and `restic-check.timer` are enabled and started.

Re-running it later is safe. It reinstalls the units from the repo, which is how
a change to a unit file reaches systemd.

## Part 4 — The first run

Run it by hand rather than waiting for 01:00. The first run uploads everything
and may take a while:

```bash
sudo infra/backup/run.sh
```

Expect a `staging` / `snapshot` pair per wired stack — `authentik`,
`dockge`, `forgejo`, `monitoring`, `traefik`, `uptime-kuma` and `vaultwarden`,
in that order, since the runner globs them alphabetically — then
`==> forget + prune`, then a final `OK:` line naming all seven. Each staging
step declares that stack's directories and runs its dump through the stack's
own container: `pg_dump` in the `db` service for the four Postgres stacks,
`sqlite3` in Kuma's single service. Traefik and Dockge have no database, so
their staging step only declares paths. The snapshot step hands restic the path
list that step produced, and nothing else.

> **Drive it through the runner, always.** A bare `infra/authentik/backup.sh`
> has no `BACKUP_STAGE` or `REPO_ROOT` and stops with a guard message. There
> *is* a standalone form and it is genuinely useful — it is in
> [Troubleshooting](#troubleshooting), where inspecting one stack's output
> without a repository is the point.

Now confirm the snapshot exists. Ad-hoc `restic` commands need the repository
and the password in the environment, and your shell does not have them —
`run.sh` and the restore scripts source `infra/backup/.env` themselves. So every
bare `restic` call in this guide takes this shape, **from `~/home-lab`**:

```bash
sudo bash -c 'set -a; . infra/backup/.env; set +a; restic snapshots --tag authentik'
```

Expected: one snapshot. The relative path is deliberate — `~` inside
`sudo bash -c` is root's home, not yours. So is the subshell: the password stays
out of `argv` this way, where any local user could read it out of `ps auxww`,
which is the same reason `scripts/init-backup.sh` uses `sudo --preserve-env`
rather than `sudo env VAR=…`.

Confirm the **Backup Job** monitor in Kuma went green — that is the deadman's
first heartbeat, and it proves `KUMA_PUSH_URL` reached the file correctly.

Confirm the timers are armed:

```bash
systemctl list-timers 'restic-*' --no-pager
```

Expected: `restic-backup.timer` next at 01:00 and `restic-check.timer` next on
Sunday at 03:00.

### Checklist

- [ ] `sshd -T -C user=root` reports `chrootdirectory none` and `forcecommand
      none`, and a fresh root login to the hypervisor still works
- [ ] `scripts/init-backup.sh` completes without stopping
- [ ] `sudo infra/backup/run.sh` ends in an `OK:` line naming all seven stacks
- [ ] `restic snapshots` lists one snapshot per tag — seven in all
- [ ] The **Backup Job** monitor is green
- [ ] Both `restic-*` timers appear in `systemctl list-timers`
- [ ] `RESTIC_PASSWORD` is written down **outside the lab**, not only in
      Vaultwarden

## Restore

> **To restore as an exercise rather than an emergency**, use
> [backup-restore-drill.md](backup-restore-drill.md). It covers what to change
> before each restore so the result proves something, and what each stack's
> outcome actually demonstrates. This section is the mechanism; that guide is
> how you find out whether it works.

Restoring Authentik is one command, and it asks before it does anything
destructive:

```bash
sudo infra/authentik/restore.sh
```

Optionally with a snapshot id — `sudo infra/authentik/restore.sh 1a2b3c4d` — for
anything but the latest. It lists the snapshots tagged `authentik` first, so
running it to *look* and then aborting at the prompt is a reasonable thing to
do.

It asks you to type `authentik` to continue, then: stops the stack, restores the
snapshot into `/opt/backup/restore/authentik`, **checks that everything it is
about to need is actually in there**, moves the live `/opt/authentik` aside to
`/opt/authentik.bak-<timestamp>` rather than deleting it, puts `data/`,
`templates/` and `certs/` back, replaces `infra/authentik/.env`, starts the
database alone, loads `authentik.sql` into it, and brings the rest of the stack
up. It prints its own verification list at the end.

**Kuma restores the same way**, with `sudo infra/uptime-kuma/restore.sh`, and
the shape is deliberately identical — same prompt, same staged restore, same
check-before-move, same `.bak-<timestamp>`. The two differences are both
consequences of SQLite: there is no cluster to re-initialise, so instead of
leaving `postgres/` empty it restores the whole data directory and then
**deletes the `kuma.db` triplet** before rebuilding the database from the dump;
and it warns you at the prompt that while Kuma is down nothing is watching the
lab. See [Why Kuma dumps instead of copying](#why-kuma-dumps-instead-of-copying).

**Monitoring restores narrowly**, with `sudo infra/monitoring/restore.sh`, and
it is the one that does *not* move the whole tree aside. It touches
`/opt/monitoring/postgres` and nothing else, because the five directories
beside it — `prometheus/`, `loki/`, `tempo/`, `alloy/`, `grafana/` — are Tier 3
and were never in the snapshot. Moving them aside would destroy live data this
backup never promised to bring back, and discard the per-directory ownership
`scripts/init-monitoring.sh` sets. Its prompt says so before you confirm.

One consequence worth knowing when you verify it: Grafana's dashboards and
datasources are **provisioned from this repo**, so they come back on an empty
database too. They prove the stack started, not that the restore worked. The
things that actually prove it are the hand-made ones — users, API tokens,
starred dashboards, anything built in the browser rather than committed.

**Vaultwarden restores like Authentik**, with `sudo infra/vaultwarden/restore.sh`
— whole tree aside, `postgres/` left empty, dump loaded into a fresh cluster.
What differs is what it checks and what proves it worked.

Its staged-snapshot check names **`data/rsa_key.pem` by itself**, rather than
trusting that `data/` exists. That file signs every access token the server
issues, and the database holds what those tokens address; restore one without
the other and you get a working server, an intact vault, and every client
logged out with no way to prove anything against it. A missing `rsa_key.pem`
therefore has to stop the restore before it moves anything, not surface later
as clients mysteriously demanding fresh logins.

So the check that actually proves this restore is **logging in from a client
that was already paired** — a browser extension or phone app you have not
re-authenticated. Opening the web vault in a fresh browser session proves much
less: it would work even if the key and the database had come from different
snapshots. Two things beyond the database are also worth confirming, because
they live in `data/` and not in Postgres: an attachment opens, and any setting
you changed through `/admin` is still as you left it (those are written to
`data/config.json`, which **overrides** the compose environment).

> **The check comes before the move, and that ordering is the whole point.**
> `data/`, `templates/`, `certs/`, the `.env` and the SQL dump are all verified
> while `/opt/authentik` is still where it belongs, so an incomplete snapshot —
> a [degraded](#last-resort-the-raw-pgdata) one, or a rebuilt VM whose checkout
> now sits at a different path than the `.env` was stored under — stops the
> script with nothing moved and nothing half-copied. Past that point, any
> failure prints where `/opt/authentik.bak-<timestamp>` is and how to put it
> back, rather than leaving you to find out.

> **`postgres/` comes back empty, on purpose.** Postgres keeps the password its
> data directory was **first initialised with**. A restored `postgres/` next to
> a restored `.env` that was generated at a different time is a stack that
> cannot log into its own database — a failure that looks exactly like a corrupt
> backup and is not one. So the container initialises a fresh cluster using the
> restored `.env`, and the dump loads into that. The `.env` and the database are
> one unit for a second reason too: `AUTHENTIK_SECRET_KEY` decrypts the secrets
> held *inside* that database.

### Cleaning up afterwards

A restore leaves **two** trees behind, both on purpose. Delete them once the
verification above passes — not before, because the first one is your way back
if it did not:

```bash
sudo du -sh /opt/authentik.bak-* /opt/backup/restore/authentik 2>/dev/null
```

The previous live tree, timestamped so repeated restores never collide:

```bash
sudo rm -rf /opt/authentik.bak-<timestamp>
```

And the staging copy of the snapshot, which is usually the larger of the two —
it holds the raw `postgres/` as well, plus a decrypted copy of the `.env`:

```bash
sudo rm -rf /opt/backup/restore/authentik
```

If you used the [raw PGDATA path](#last-resort-the-raw-pgdata) there is a third,
`/opt/backup/restore/authentik-raw`. Nothing reclaims any of these on a
schedule; the next restore overwrites the staging tree but never the `.bak-`
ones, so they accumulate until you remove them.

> **`/opt/backup/dumps/` is not cleanup material — leave it alone.** It is the
> *backup's* staging directory, not the restore's, and `run.sh` wipes and
> rebuilds it at the start of every run, so it holds last night's dump rather
> than a growing pile. It is also deliberately left on disk between runs: the
> 01:00 schedule sits an hour before the hypervisor's 02:00 `vzdump` so that
> layer 1's whole-VM archive captures the current night's SQL. Deleting it by
> hand costs you that and gains nothing — the next run recreates it anyway.

### The ordering trap

**A restore obeys the build order, because the build order is a dependency
order.** Traefik must be running before anything is reachable at all, and
Authentik must be running before anything it gates will let you in. Restore
Authentik on a machine where Traefik is down and every symptom you get is a
Traefik symptom.

The visible version of this: while Authentik is down, `dockge.thefipster.de` and
the Traefik dashboard have no forward-auth middleware to send you to, and
Traefik reports the middleware as undefined. That is expected during the restore
and it clears when the stack comes back. If you need one of those UIs *during*
the outage, comment out its `middlewares` label — that is the break-glass path,
and it is the reason Vaultwarden and Uptime Kuma deliberately join no SSO
pattern at all.

### Last resort: the raw PGDATA

The snapshot also carries `/opt/authentik/postgres` — the live data directory,
copied while it was running. **It is never the restore path**, because a
live-copied `PGDATA` is torn by construction. It rides along because it costs
little for a database this size, and it is what you have when there is no dump:
a **degraded snapshot**, taken on a night when `pg_dump` failed, or a stack
whose database was already broken when the last good run happened.

> **How a degraded snapshot happens is deliberate, not accidental.** Every
> `infra/<stack>/backup.sh` declares its *file* paths before it runs the
> database dump, so a dump that fails still leaves a non-empty `paths.txt`
> behind it — and `run.sh` snapshots that rather than skipping the stack. You
> get `data/`, `certs/`, the `.env` with `AUTHENTIK_SECRET_KEY` and this raw
> `PGDATA`; you do not get `authentik.sql`. The run still reports the stack as
> failed, still exits non-zero and still says nothing to Kuma, so it shows up
> as red — it is a worse backup than usual, not a good one. The line to look
> for in the journal is `snapshotting DEGRADED`.

Expect it not to start. Try it anyway, in this order, and only after
`restore.sh` has failed for want of a dump.

> **`restore.sh` stops that one *before* it moves anything.** The missing dump
> is caught in its staged-snapshot check, alongside `data/`, `certs/` and the
> `.env`, so it aborts with `/opt/authentik` exactly as it was and the stack
> merely stopped — which is the state the steps below assume. It says so on the
> way out and tells you not to undo anything. Take it literally: the steps below
> operate on the live tree.

1. Stop the stack — `restore.sh` already did this, so expect it to be a no-op:

```bash
cd ~/home-lab/infra/authentik
```

```bash
docker compose down
```

2. Restore only that directory, into staging — from the repo root, because the
   `.env` path is relative for the reason given in
   [Part 4](#part-4--the-first-run):

```bash
cd ~/home-lab
```

```bash
sudo bash -c 'set -a; . infra/backup/.env; set +a; restic restore latest --tag authentik --target /opt/backup/restore/authentik-raw --include /opt/authentik/postgres'
```

3. Move the live one aside — never delete it:

```bash
sudo mv /opt/authentik/postgres /opt/authentik/postgres.torn
```

4. Put the restored copy in place, preserving ownership:

```bash
sudo cp -a /opt/backup/restore/authentik-raw/opt/authentik/postgres /opt/authentik/postgres
```

5. Start the database alone and read its log before starting anything else:

```bash
cd ~/home-lab/infra/authentik
```

```bash
docker compose up -d db
```

```bash
docker compose logs -f db
```

If it recovers, take a `pg_dump` immediately and treat that dump as the real
artefact. If it does not — and "database files are incompatible", "invalid page
in block" or a WAL error are all plausible — you are rebuilding Authentik from
[sso-applications.md](sso-applications.md), which is what that registry exists
for.

## Next

**[apps-vm-setup.md](apps-vm-setup.md)** — the second machine's checkout, host
setup and data disk, followed by [coolify-setup.md](coolify-setup.md) and
[home-assistant-setup.md](home-assistant-setup.md). The full sequence is the
[README build order](../README.md#build-order).

## Troubleshooting

**`Fatal: unable to open repository`.** Three causes, all on the SFTP path:
the Proxmox host key is not in `/root/.ssh/known_hosts`, the public key is not
in `/etc/ssh/authorized_keys/resticbackup`, or the chroot permissions are wrong. Test
the transport on its own:

```bash
sudo ssh -i /root/.ssh/id_ed25519 resticbackup@pve.thefipster.de
```

**It should refuse a shell but not refuse the connection.** Getting as far as
`This service allows sftp connections only` means keys and chroot are both
fine and the problem is elsewhere. A disconnect with no message means the
chroot ownership — re-read the bold note in [Part 1](#part-1--the-host-side-a-user-a-chroot-and-one-sshd-block),
then look in the host's `journalctl -u ssh`, which is where the real reason is
logged.

**One stack shows as failed and the others succeeded.** That is the design.
`run.sh` deliberately does not use `set -e` — one stack failing must not cost
the others their snapshots — so failures are collected and named on the last
line. Read the detail in the journal:

```bash
journalctl -u restic-backup.service -n 50
```

A failed stack may still have produced a snapshot: `snapshotting DEGRADED` in
that output means the files were captured and the database dump was not. Treat
it as a snapshot you would rather not restore from — see [Last resort: the raw
PGDATA](#last-resort-the-raw-pgdata) — and fix the dump before the next night.

**The run fails with `KUMA_PUSH_URL is set in .env but arrived EMPTY`.** The
value still carries Kuma's query string. Kuma displays the URL *with* one, and
pasting it verbatim is the single most likely misconfiguration here: `&` is a
command separator to the shell that sources this file, so the assignment runs
in a background subshell and never reaches `run.sh`. Cut it back to
`https://uptime.thefipster.de/api/push/TOKEN`.

`run.sh` treats this as **fatal on purpose**, rather than skipping the push
quietly. An unnoticed empty value is the deadman failing to arm — backups
succeed nightly, the monitor stays red, and the one troubleshooting entry that
matches sends you looking at Kuma. Failing loudly puts the reason in
`journalctl -u restic-backup.service` instead. A genuinely empty value is a
supported choice (heartbeat disabled) and does not trip it.

Confirm what the shell actually sees:

```bash
sudo bash -c 'set -a; . infra/backup/.env; set +a; echo "[$KUMA_PUSH_URL]"'
```

Expected: the full token URL between the brackets. Empty brackets, or a
truncated value, is the bug above.

If it is intact, the value is simply wrong — a wrong or deleted token. A failed
push *is* reported (`! Kuma push failed`) but does not fail the run: the backup
succeeding matters more than the notification about it.

**`repository is already locked` / `unable to create lock`.** A restic run that
was killed part-way — a reboot at the wrong moment, a `systemctl stop`, a VM
snapshot rollback — leaves its lock behind. Nothing expires it on its own, so
**every** later backup and the weekly check fail the same way, the monitor goes
red and stays red, and the transport tests perfectly clean (which is what sends
people down the SFTP path above by mistake). Look first:

```bash
sudo bash -c 'set -a; . infra/backup/.env; set +a; restic list locks'
```

Make sure no `restic-backup.service` or `restic-check.service` is actually
running (`systemctl is-active restic-backup.service`) — the lock is doing its
job if one is — then remove the stale ones:

```bash
sudo bash -c 'set -a; . infra/backup/.env; set +a; restic unlock'
```

`restic unlock` removes stale locks only; add `--remove-all` only when you are
certain nothing is running, on any client.

**Re-running one stack without waiting for the others:**

```bash
sudo infra/backup/run.sh authentik
```

**Inspecting one stack's staging output with no repository at all** — no
password, no network, nothing uploaded. This is what the standalone form is for:

```bash
sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/authentik/backup.sh
```

Then look at `/tmp/t/authentik.sql` and `/tmp/t/paths.txt`. That second file is
the **only** thing restic is ever given, so if a path is missing from the
backup, it is missing from there first.

**`include: /opt/… does not exist`.** A declared path is gone, and that aborts
the stack rather than warning. Intentional: a backup quietly missing a directory
is worse than a backup that says it failed. Anything declared *before* the
failing line is still snapshotted, as a degraded snapshot — the stack is
reported failed either way.

**`restic check` fails on Sunday — and nothing tells you.** Only `run.sh`
pushes to Kuma; `restic-check.service` has no heartbeat and no Grafana rule, so
a repository that has stopped being readable is silent. **Looking is the only
way to find out**, and it is worth doing after a drive is unplugged and
replugged:

```bash
systemctl status restic-check.service
```

```bash
journalctl -u restic-check.service -n 50
```

When it does fail, suspect the drive before the job. Check pool health on the
hypervisor first (`zpool status usbbackup`); the **Hypervisor Storage** monitor
covers `usbbackup` by name precisely because a pool whose device fell off the
USB bus does not appear in `zpool list` at all — so that monitor, not this one,
is what catches the common cause.

**The clock, after a rollback.** A restored or rolled-back guest resumes with a
stale clock and every TLS client fails with "certificate has expired or is not
yet valid". `scripts/init-host.sh` relaxes the time-sync step policy for exactly
this, but expect to meet it during a restore drill and do not misdiagnose it as
a bad restore:

```bash
timedatectl status
```

## Layout on the server

| What | Where |
|------|-------|
| The runner, the recipes and the units (source of truth) | `infra/backup/` in this repo |
| Secrets | `infra/backup/.env` — gitignored, VM-only, mode 600 |
| What a stack's backup consists of | `infra/<stack>/backup.sh` |
| The inverse | `infra/<stack>/restore.sh` |
| Database dumps, overwritten every run | `/opt/backup/dumps/<stack>/` |
| Restore staging | `/opt/backup/restore/<stack>/` — kept until the next restore |
| The tree a restore displaced | `/opt/<stack>.bak-<timestamp>` — never reclaimed; [delete it yourself](#cleaning-up-afterwards) |
| Installed units | `/etc/systemd/system/restic-*.{service,timer}` |
| The key the repository is reached with | `/root/.ssh/id_ed25519` |
| The repository itself | `/usbbackup/chroot/restic` on the Proxmox host |

`/opt/backup` is mode **700**. The dumps are plain SQL and contain every
credential the lab has.

**The dumps are overwritten, not accumulated.** History lives in restic, which
is what history is for; a directory of timestamped dumps is a directory that
grows until the disk is full and takes the backup down with it.

**Nothing here is a compose stack, so nothing here appears in Dockge.** There is
no `/opt/stacks/backup` symlink and no container to look at — `systemctl status
restic-backup.service` and `journalctl -u restic-backup.service` are the
equivalent.

## How it works

**Why one snapshot per stack, tagged.** Restoring Authentik is
`restic restore latest --tag authentik`, not an include-list assembled under
pressure from a guide you are reading with the lab down. It also makes the
per-stack couplings come back as one unit by construction: Authentik's database
and its `AUTHENTIK_SECRET_KEY` are in the same snapshot because the same
`backup.sh` declared both.

**Why `--group-by host,tags` is not optional.** `restic forget` applies its
policy *per group*, and its default grouping is `host,paths`. With several
stacks in one repository, `--keep-daily 7` under the default grouping would be
decided by a partition that silently re-shuffles the moment a stack's
`backup.sh` gains or loses an include — quietly changing what "seven dailies"
means. Grouping by tag makes the policy read the way it is written: seven
dailies *of Authentik*. `host` is in there because the apps VM joins this same
repository later.

**Why plain-format dumps, not `pg_dump -Fc`.** A compressed dump changes in its
entirety when a single row changes, which defeats restic's content-defined
chunking — every night would store a whole new blob. Plain SQL deduplicates
across nightly runs, and restic compresses it at rest anyway (`--compression
auto`, the default since 0.14), so plain text costs nothing in stored size and
buys almost all of the dedup. `--clean --if-exists` is there so the dump loads
into a live database rather than requiring a hand-dropped one, and the dump is
written to `.part` and renamed only after `pg_dump` exits 0 — a truncated dump
must never be mistaken for a good one by the next run, or by a restore.

**Why the dump goes through the container.** `docker compose exec -T db pg_dump`
uses the database's own client, so the dump tool always matches the server
version. Nothing on the VM needs a `postgresql-client` package, and a Postgres
major bump cannot leave a stale client behind.

### Why Kuma dumps instead of copying

Kuma keeps SQLite in WAL mode, and on this lab the write-ahead log is routinely
**larger than the database file** — 832 KB of `kuma.db-wal` against 380 KB of
`kuma.db` when the recipe was written. A `cp` of `kuma.db` alone would capture
a file missing most of its committed state, and copying all three of the
triplet while the database is live just captures them mid-write instead. That
is why Kuma was the one stack the design deferred until the mechanism could be
checked against the real image.

The check settled it: `louislam/uptime-kuma:2` ships `/usr/bin/sqlite3`, so
`dump_sqlite` dumps through the stack's own client exactly as `dump_postgres`
does — no `alpine` sidecar, and no second process holding write access to
Kuma's live database, which is what the sidecar route would have required
(SQLite's backup path needs to read `-wal` and `-shm` and take a lock, so it
cannot run against a read-only mount).

It uses `.dump` rather than `.backup`. Both are safe against a live database —
in WAL mode a reader gets a consistent snapshot and never blocks the writer —
but `.dump` streams SQL to stdout, so nothing is written inside the container
and nothing has to be copied back out, and the result is text, which
deduplicates across nightly runs for the same reason plain-format `pg_dump`
does.

The restore mirrors the Postgres discipline one directory wider. Where those
stacks leave `postgres/` empty, Kuma's restores the whole data directory —
`db-config.json`, `upload/`, `screenshots/`, `docker-tls/` — and then deletes
the `kuma.db` triplet before rebuilding from the dump. It rebuilds through
`docker compose run --rm --entrypoint sqlite3`, which starts the stack's own
image *without* starting Kuma: the client matches the file format, and the new
`kuma.db` lands owned by the UID Kuma itself runs as, because it is that image
writing it. A database file created by root here would be one Kuma might not be
able to write to.

**Why `run.sh` does not use `set -e`.** Every other script in this repo does.
Here, one stack failing must not cost the others their snapshots — so failures
are collected into a list, reported on the last line, and turned into a non-zero
exit at the end. `-u` and `-o pipefail` still apply. The Kuma push is guarded by
that same exit path, which is what makes a partial success look like a failure
rather than a green tick.

The same reasoning runs one level deeper, *inside* a stack: a stack script that
aborts still gets its snapshot taken if it declared any paths before it died.
Failing loudly and backing up nothing are two different things, and only the
first one is wanted.

**Why 01:00.** One hour **before** the 02:00 `vzdump` job on the hypervisor, so
layer 1's whole-VM archive contains the current night's dumps rather than the
previous night's — the two layers stack instead of merely coexisting. It is also
clear of the 04:30 unattended-upgrades reboot window. `Persistent=true` means a
VM that was down at 01:00 catches up on boot rather than skipping a night, and
the weekly check runs Sunday 03:00 so it never overlaps that night's backup on
the USB drive. `vzdump` is not a third contender for that drive — it writes to
the internal `backup` mirror — but it is still worth being an hour behind: the
spacing is about host I/O, and about layer 1 finding the current night's dumps
already on disk.

**Why `check --read-data-subset=10%`.** A repository that cannot be read is not
a backup, and the only way to know is to read it. The structural half of
`restic check` — every index, every snapshot, every tree — runs **in full**
every week; `--read-data-subset` is about how much of the actual pack data gets
hashed on top of that, and 10% is the trade between proving the bytes are there
and spending a night on the USB bus doing it.

**It samples, it does not rotate.** restic's `n%` form picks a *random* subset
each run; only the `n/t` form (`--read-data-subset=3/10`) selects a
deterministic slice, and rotating one would mean a different `n` each week,
which a static unit file cannot express without wrapping the command in a
shell. So do not read this as "the whole repository every ten weeks" — nothing
guarantees a given pack has ever been read. It is a weekly spot check, and the
thing it reliably catches is a repository that has gone broadly unreadable,
which is the failure that actually happens to a USB drive.

**Why the raw `PGDATA` rides along but is never the restore path.** It is in the
snapshot because it costs almost nothing for a database this size, and because
"no dump exists" is a real state to be in — one the runner deliberately keeps
*reachable*, by declaring file paths before the dump and snapshotting whatever
was declared when a stack script dies. Without that ordering a failed
`pg_dump` would take the whole snapshot down with it and this directory would
never be there on the night it is wanted. It is not the restore path because a
`PGDATA` copied from a running server is torn by construction — the dump is the
consistent artefact, and a second path that *looks* equally valid is how a
restore goes wrong. This is the first thing to reconsider if snapshots ever get
expensive.

**Why the `.env` files come from the checkout.** `/opt/stacks/<stack>` is a
*symlink* into `~/home-lab/infra/<stack>`, and restic stores a symlink as a
symlink rather than descending into it. Backing up `/opt/stacks` would capture
the links and none of the secrets — which is why `include_env` names
`$REPO_ROOT/infra/<stack>/.env` explicitly.

**Where this is not yet finished.** The repository lives on a drive plugged into
the machine it protects. That is a real second copy and it is the only one that
can physically leave the building, but it is not offsite until someone points
restic at B2, netcup Storage Space or rclone — client-side encryption means that
step is credentials and a bandwidth check, not a redesign
([roadmap/backup.md](roadmap/backup.md#phases) phase 3). **The weekly check has
no deadman**: `run.sh` pings Kuma, `restic check` does not, so a repository that
has quietly become unreadable stays quiet — the monitor proves the backup ran,
not that it can be restored from. And **until a restore drill has actually been
run, treat a stack as untested** — that is phase 5, and the procedure is
[backup-restore-drill.md](backup-restore-drill.md), with each run recorded in
`docs/review/` as a dated finding.

## Next

**[apps-vm-setup.md](apps-vm-setup.md)** — the second machine. It joins this
same restic repository later with one more key in
`/etc/ssh/authorized_keys/resticbackup` and an `.env` value, which is why the
transport was chosen the way it was. The full sequence is the
[README build order](../README.md#build-order).
