# Backup bring-up and first restore drill — 2026-08-07

The first application of [backup-setup.md](../backup-setup.md) to the running
lab, on the day the guide was written, followed by a restore drill for
Authentik. This is the record [roadmap/backup.md](../roadmap/backup.md) phase 5
asks for, and it doubles as a guide replay: the guide had never been executed
by anyone when this started.

Like the [guide replay](2026-07-26-guide-replay.md) and the [architecture
review](2026-08-01-architecture-review.md), this is a dated record. Findings
state what was found and what was done about it; the document is not
retro-edited when anything later changes.

> **Status: all five findings executed** (2026-08-07). Every one landed as a
> commit on `feature/backup-infra` before this document was written.
>
> | # | Finding | Landed as |
> |---|---------|-----------|
> | 1 | `authorized_keys` step never said whose key | `8a333fe` |
> | 2 | `sshd -T` check expected output it can never produce | `02f9d0c` |
> | 3 | "The two must match" named neither of the two | `08c2a4e` |
> | 4 | `KUMA_PUSH_URL` query string silently disarmed the deadman | `70953da` |
> | 5 | Restore leftovers had no delete command, and a managed directory looked like a third one | `84b57a0`, `1f4fc3a` |
> | — | Roadmap brought up to what is actually running | `615c4e6` |

---

## What the drill proved

A user was created in Authentik **after** a backup ran. `restore.sh` was then
run against that snapshot. Afterwards the user was gone and everything else
worked.

That is a stronger result than "the restore completed", and it is worth being
precise about why. The user's absence proves the restored database **is** the
backup's database, not a survivor of the live one. Authentik continuing to
function proves `AUTHENTIK_SECRET_KEY` still decrypts the secrets held inside
that database — so the `.env` and the SQL dump came back from the same snapshot
as a unit. That coupling is the entire reason backups are defined per stack
rather than in a central runner, and until this drill it had only ever been
asserted.

The `postgres/`-left-empty decision also held: the container re-initialised a
fresh cluster from the restored `.env` and the dump loaded into it, which is the
path that avoids a restored `.env` stranded beside a `PGDATA` initialised with a
different password.

## What the drill did not prove

Stated plainly, because the temptation is to read the above as broader than it
is:

- **Every other stack.** At the time of this drill only Authentik had a
  `backup.sh`, and six remained. Uptime Kuma, monitoring and Vaultwarden all
  landed later the same day and were drilled the same way — see the addenda —
  leaving three.
- **A VM-rollback drill.** This was an in-place restore on a working VM. The
  phase-5 drill described in the roadmap rolls the infra VM back to a snapshot
  first, which is a materially harder test — it is also where the
  clock-skew-after-rollback failure would appear.
- **The unattended timer.** Every run so far was started by hand.
- **The weekly `restic check`.** Never fired.
- **The deadman's *silent* half.** The push path is confirmed — see below — but
  nothing has yet observed the monitor going **red** because a heartbeat did
  not arrive, which is the property the whole arrangement exists for. Breaking
  one stack's `backup.sh` deliberately and watching the run exit non-zero and
  stay silent is the cheap way to test it.

> **Confirmed later the same day: the Kuma push works.** With the query string
> removed from `KUMA_PUSH_URL`, a run delivered its heartbeat and the monitor
> went green — so `run.sh` → `curl` → Kuma is proven end to end. Recorded here
> rather than by editing finding 4, because the state this document describes
> is the one the bring-up was actually conducted in: the alarm covering all of
> the above was **absent while everything else was being verified**, and that
> remains the fact worth remembering about this drill.

## 1. The `authorized_keys` step never said whose key

**Finding:** Part 1 asks you to paste a public key into
`/etc/ssh/authorized_keys/resticbackup`, and the instruction at the step read
only "Paste the single `ssh-ed25519 …` line". The operator asked whether it
should be their own user's key.

**Status: Confirmed.** The guide *did* explain it — in a blockquote at the top
of Part 1, roughly fifty lines above the step, covering the Part 1 ↔ Part 3
circular dependency. By the time you are inside `nano` it is off-screen.

The wrong answer here is not loud. A personal key works perfectly when the
connection is tested by hand and then fails every night at 01:00, because
`restic-backup.service` runs with `User=root` — the `/opt` trees are owned by
whatever UID each image runs as, so no single non-root user can read all of
them.

**Landed:** the step now names root's key, gives `sudo cat
/root/.ssh/id_ed25519.pub` to print it, identifies it by its
`restic-backup@infra` comment, and carries the `User=root` reasoning inline.

## 2. The `sshd -T` check expected output it can never produce

**Finding:** the containment check
`sshd -T -C user=root | grep -iE 'chrootdirectory|forcecommand'` was documented
as *"Expected: **no output**"*. It printed `chrootdirectory none` and
`forcecommand none`.

**Status: Confirmed, and the most dangerous of the five.** `sshd -T` dumps the
*effective* configuration including defaults, so both keywords always print;
`none` is what "not set" looks like. Empty output was never achievable.

The guide therefore instructed the operator to **halt** on the correct result —
on the single step it also flags as the one that can lock you out of the
hypervisor. The follow-on diagnostic ("if *this* one is empty while the root
check was also empty, the drop-in is not being read") rested on the same false
premise, so it would have sent someone hunting a missing `Include` line for a
drop-in that was working.

**Landed:** the check is now on the **value**, not the presence of a line —
both must read `none` for root, and the `resticbackup` check fails when it
*also* reads `none`. Checklist item corrected to match.

## 3. "The two must match" named neither of the two

**Finding:** the host-key verification says to run `ssh-keygen -lf
/etc/ssh/ssh_host_ed25519_key.pub` on the Proxmox host, then "The two must
match". The operator asked whether the comparison was against the key
`init-backup.sh` generates.

**Status: Confirmed.** It is not, and the guide's own layout invited that
reading: the sentence sat directly beneath a paragraph about the **client** key
(`/root/.ssh/id_ed25519`, which proves the infra VM to the host). The
comparison is between two views of a *different* key — the **host** key, which
proves the host to the infra VM: the fingerprint `ssh-keyscan` received, versus
the one read off the hypervisor's disk.

Getting this wrong is harmless in the destructive sense — `ssh-keygen -l` is
read-only, verified — but running it on the wrong machine yields a mismatch
against a correct setup, and the guide says to stop on a mismatch.

**Landed:** a table separating the two keys by direction and destination, the
comparison named explicitly, and `sudo ssh-keygen -lF pve.thefipster.de` for
re-printing what actually landed in `known_hosts` once the script's output has
scrolled away.

## 4. The `KUMA_PUSH_URL` query string silently disarmed the deadman

**Finding:** `KUMA_PUSH_URL` arrived empty despite `.env` plainly setting it.
The value still carried the query string Kuma displays:
`…/api/push/TOKEN?status=up&msg=OK`.

**Status: Confirmed.** `.env` is sourced as shell, and `&` is a command
separator: the assignment ran in a background subshell and never reached the
parent. The emptiness guard then skipped the push **without printing anything**,
so the `! Kuma push failed` warning was never reached either. Backups succeed
nightly, the monitor stays red, and nothing says why.

**This one is the lesson of the bring-up, because the guide already warned
about it.** The warning was added by the pre-merge review that discovered the
mechanism, was bolded, and sat at the step that says to copy the URL. It did
not survive contact with someone copying a URL out of a web UI. A warning you
have to read at the right moment is not a control.

**Landed:** `run.sh` now detects the exact signature — variable empty while
`.env` matches `^KUMA_PUSH_URL=.+` — prints what to cut, and treats it as
**fatal**, so the reason lands in `journalctl -u restic-backup.service` instead
of nowhere. Tested against all three cases: it trips on the query-string form,
passes the token-only form, and does not punish a deliberately empty value,
which remains a supported way to disable the heartbeat. The troubleshooting
entry was rewritten, since its old symptom ("monitor red but the run printed
`OK`") can no longer occur.

## 5. Restore leftovers had no delete command, and a managed directory looked like a third one

**Finding:** `restore.sh` closed with "Delete it once you are satisfied, not
before" and no command, naming only one of the **two** trees it leaves. The
operator then found `/opt/backup/dumps/authentik` and reasonably asked whether
that was a third.

**Status: Confirmed for the first half, correctly-designed for the second.**
The two genuine leftovers are `/opt/<stack>.bak-<timestamp>` (never reclaimed,
accumulates one per restore) and `/opt/backup/restore/<stack>` (overwritten by
the next restore, which may be never, and usually the larger of the two — it
holds the raw `PGDATA` and a decrypted `.env`).

`/opt/backup/dumps/<stack>` is **not** cleanup material: it is the *backup's*
staging directory, wiped and rebuilt by `run.sh` at the start of every run, and
deliberately left on disk so the hypervisor's 02:00 `vzdump` captures the
current night's SQL — which is why the restic job is scheduled at 01:00 in the
first place. The pre-merge review had flagged the unreclaimed staging tree as a
Minor and it was merged as-is; the drill showed it mattered.

**Landed:** concrete `du` and `rm -rf` commands in both `restore.sh`'s closing
message and a new *Cleaning up afterwards* section, a blockquote stating that
`dumps/` is managed and why, and a layout-table row for the `.bak-` trees.

## The pattern across all five

Every one is a place where the **code was correct and the reader could not
tell**. None was a logic error; all five were prose that assumed context the
reader does not have at that moment — the guide's author and its reviewers read
top to bottom in one pass and carry that context forward, while the operator
arrives at each step cold and hours apart.

Two consequences worth carrying into the remaining six stacks:

- **An `Expected:` line that has never been run against a real system is a
  guess.** Finding 2 is the sharpest example: every review pass verified the
  *command* was right and none questioned what it would print.
- **For a failure that disables an alarm, documentation is not a fix.**
  Finding 4 had already been found, understood and documented before the
  operator hit it. The control had to be code.

## Follow-ups this leaves open

1. **Three `backup.sh` files** — Forgejo, Traefik, Dockge. (Was six. Uptime
   Kuma, monitoring and Vaultwarden all landed and were drilled the same day —
   see the addenda below. The three that remain carry no new decisions.)
2. ~~**`dump_sqlite`**, whose open question is whether `sqlite3` ships inside
   `louislam/uptime-kuma:2` or wants a small `alpine` sidecar.~~ ✅ done the
   same day. The image ships `/usr/bin/sqlite3`; no sidecar. See the addendum.
3. ~~**Confirm the deadman actually fires.**~~ ✅ done the same day, once the
   query string was cut: the heartbeat arrived and the monitor went green.
   What remains is the negative case — break a stack deliberately, confirm the
   run exits non-zero, stays silent, and the monitor turns red.
4. **A VM-rollback drill**, which is the phase-5 test this one was not, and
   where the clock-skew-after-rollback failure would surface.
5. **A heartbeat for the weekly `restic check`**, which currently has none:
   an unreadable repository stays quiet until somebody thinks to look.

---

## Addendum: Uptime Kuma wired and drilled — same day

The last recipe, done next rather than last, so the recipe set would be
complete before the four mechanical stacks. Both of the design's open questions
were settled by probing the running container rather than by reasoning about
it, and both answers changed the implementation.

**`sqlite3` ships in the image** (`/usr/bin/sqlite3` in
`louislam/uptime-kuma:2`), so `dump_sqlite` dumps through the stack's own
client exactly as `dump_postgres` does. The `alpine` sidecar the spec held in
reserve would have been materially worse than "one more container": SQLite's
backup path has to read `-wal` and `-shm` and take a lock, so it cannot run
against a read-only mount — the sidecar would have needed **write** access to
the watcher's live database.

**WAL is not a theoretical concern here.** Before the drill, `kuma.db-wal` was
**832 KB against a 380 KB `kuma.db`** — more than half the committed state
living outside the database file. A `cp` of `kuma.db` would have produced
something that looks like a backup and is missing most of it. This is the
clearest justification in the whole project for dumping rather than copying,
and it was a guess until the directory was actually listed.

**`.dump`, not the `.backup` the spec named.** Recorded as a deviation rather
than drift: the spec chose `.backup` while the image was still unknown, and
finding `sqlite3` present made the simpler shape available. `.dump` streams SQL
to stdout, so nothing is written inside the container and nothing has to be
copied back out; it lands as text, which deduplicates for the same reason
plain-format `pg_dump` does; and both are equally safe against a live WAL
database, where a reader gets a consistent snapshot and never blocks the writer.

### The drill

Same shape as Authentik's: a throwaway monitor created **after** the backup,
then `restore.sh`. Everything came back — monitors, groups, notification
bindings, heartbeat history — and the throwaway was gone.

Two behaviours worth recording as expected rather than faulty, because both
look alarming: **Kuma is the watcher**, so nothing monitors the lab while it is
down, and the script now says so at the confirmation prompt; and **both push
monitors read as down after a restore** until their next push arrives, because
nothing pushes on demand.

### One thing verified, one thing still unexplained

The rebuilt `kuma.db` came back **`root:root`**, and Kuma runs fine on it. That
verifies the mechanism `restore.sh` was built around — rebuilding through
`docker compose run --rm --entrypoint sqlite3` means the stack's *own image*
writes the file, so it lands owned by whatever UID that image runs as, with no
`chown` to get wrong. It also confirms `infra/uptime-kuma/compose.yaml`'s claim
that the image runs as root.

What is **not** explained is why `kuma.db` was owned `felix:felix` (1000:1000)
*before* the drill, while every directory beside it was `root:root`. It was
read at the time as evidence the image runs as UID 1000 and that the compose
comment was stale; the drill disproves that reading. No theory here is worth
writing down as fact. It is harmless — the restore is robust either way,
because it never sets ownership itself — but it is the one observation from
this bring-up that nothing accounts for.

---

## Addendum: monitoring wired and drilled — same day

Taken third, ahead of the four mechanical stacks, because it was the last one
with a decision in it. It turned out to carry **two** exceptions rather than
the one the roadmap predicted.

**The known one: the names do not match.** Every other Postgres stack satisfies
`POSTGRES_USER == POSTGRES_DB == <directory>`, which is what `dump_postgres`'s
single-argument form assumes. Monitoring's directory is `monitoring` and its
database is `grafana`, so it is the only caller of the override arguments —
`dump_postgres monitoring db grafana grafana`. The dump is still named after
the *stack*, which is what keeps every restore path uniform.

**The unforeseen one: this restore has to be narrow.** Every other
`restore.sh` moves the whole `/opt/<stack>` tree aside. Doing that here would
be actively destructive: five of the six directories under `/opt/monitoring`
(`prometheus/`, `loki/`, `tempo/`, `alloy/`, `grafana/`) are Tier 3 and were
never in the snapshot, so moving them aside would destroy live observability
data the backup never promised to return — and discard the per-directory
ownership `scripts/init-monitoring.sh` sets (grafana 472, prometheus 65534,
loki and tempo 10001). So this script touches `postgres/` alone and says so at
the confirmation prompt.

That is worth naming as a general rule the design had not stated: **a stack
with Tier-3 directories beside its Tier-1 ones cannot use the whole-tree
restore.** It is the only such stack today.

### The drill

Backup, then **switch the Grafana theme from dark to light**, then restore. The
theme came back dark.

The marker is better than the one originally suggested (a throwaway user), and
for a reason worth reusing: Grafana stores the theme as a per-user *preference
row*, so it proves the database was replaced, is unambiguous at a glance, and
needs no cleanup afterwards — unlike a drill user, which has to be remembered
and deleted.

**The check unique to this stack passed:** Prometheus, Loki and Tempo still
returned data from before the restore. That is what proves the narrow restore
did what it claims and left those five directories alone — no previous drill
had exercised it, because no previous stack had anything to leave alone.

One trap this drill confirmed and the guide now states: Grafana's dashboards
and datasources are **provisioned from this repo**, so they return on a
completely empty database. Verifying against them proves the stack started, not
that the restore worked. Only hand-made objects — users, tokens, preferences,
browser-built dashboards — prove anything.

---

## Addendum: Vaultwarden wired and drilled — same day

The stack the whole phase was prioritised for, and mechanically the plainest of
the four remaining: single-argument `dump_postgres`, two includes,
`include_env`. All of the care went into what the restore *checks* and what its
result is allowed to claim.

**`restore.sh` names `data/rsa_key.pem` in its own right**, rather than
trusting that `data/` exists. That key signs every access token the server
issues and the database holds what those tokens address, so a snapshot missing
it produces a working server, an intact vault, and every client locked out with
no way to prove anything. That has to abort before the tree is moved, not
surface days later as clients mysteriously demanding fresh logins.

**The `.env` is copied, never retyped**, and the script says so twice.
`VAULTWARDEN_ADMIN_TOKEN` is an Argon2id PHC string that must keep its single
quotes: Compose interpolates unquoted values, so every `$`-segment would be
expanded away, leaving an `/admin` page that rejects the password which
generated it while the container starts perfectly happily.

### The drill

A new item and an attachment on an existing item, both created after the
backup — one marker per half of the vault, because this stack's state is split
across the database and `data/` and the entire point of its backup shape is
that the halves return together. Both were gone afterwards.

**The check that matters passed: a client that was already paired logged in
without re-authenticating.** That is the result this roadmap was written
around. It proves `rsa_key.pem` and the database came back as a unit — and it
is the only check that could. Opening the web vault in a fresh browser would
have succeeded even if the key and the database had come from *different*
snapshots, because the server would simply re-issue everything. It looks like
the weakest check on the list and proves the most.

The attachment was also confirmed gone from **disk**, not merely absent from
the UI. Had the database rolled back while `data/` did not, the file would have
remained as an orphan the interface cannot show — a state that reads as success
from a browser.

### What this closes

The note at the top of `roadmap/backup.md` has been rewritten twice now. It
began as "layer 1 covers the vault only coarsely", became "phase 2 exists and
the vault has not joined it", and is now simply closed: the vault has a
granular restore, an encrypted off-machine copy, and a recovery path that does
not roll the entire VM back. What has **not** changed, and is stated in the
same place, is that `RESTIC_PASSWORD` still cannot live only in the vault —
because the vault is inside the backup.

This was also the first use of
[backup-restore-drill.md](../backup-restore-drill.md), written immediately
before it. Nothing in the guide needed correcting, which after five defects
found by execution earlier the same day is worth recording rather than assuming.
