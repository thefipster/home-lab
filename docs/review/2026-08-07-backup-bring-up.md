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

- **Every other stack.** Only Authentik has a `backup.sh`. Six remain.
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

1. **Six `backup.sh` files**, Vaultwarden first — it is the stack whose loss is
   unrecoverable by any other means, and it is one file.
2. **`dump_sqlite`**, whose open question is whether `sqlite3` ships inside
   `louislam/uptime-kuma:2` or wants a small `alpine` sidecar on the same bind
   mount.
3. ~~**Confirm the deadman actually fires.**~~ ✅ done the same day, once the
   query string was cut: the heartbeat arrived and the monitor went green.
   What remains is the negative case — break a stack deliberately, confirm the
   run exits non-zero, stays silent, and the monitor turns red.
4. **A VM-rollback drill**, which is the phase-5 test this one was not, and
   where the clock-skew-after-rollback failure would surface.
5. **A heartbeat for the weekly `restic check`**, which currently has none:
   an unreadable repository stays quiet until somebody thinks to look.
