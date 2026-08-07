# Backup restore drill

**Runs on:** the infra VM — a recurring drill, not a build step

**Prerequisite:** [backup-setup.md](backup-setup.md) complete — the repository
exists, `run.sh` produces snapshots, and each stack you intend to drill has a
`restore.sh`.

A backup nobody has restored from is a hypothesis. This is
[roadmap/backup.md](roadmap/backup.md) phase 5: the procedure that turns it
into a fact, per stack, and the record of what each stack's result actually
proves. **Re-run yearly**, and whenever a stack's `backup.sh` changes shape.

## The method

Every drill here is the same three moves:

1. Take a backup.
2. **Change something afterwards** — the marker.
3. Restore, and confirm the marker is gone while everything else survived.

The marker is what makes it a test. A restore that "completed" tells you a
script ran; a marker that has vanished tells you the data on disk is the data
from the snapshot, and not the live copy that was already there. Everything
else in this guide is about choosing markers that cannot lie.

> **The trap this guide exists to name: some things come back on an empty
> database.** Grafana's dashboards and datasources are provisioned from this
> repo. Traefik's routers are labels on containers. Verify against those and a
> completely failed restore looks like a success. A marker has to be something
> only the backup could have brought back.

## 1. Check the dump before you trust it

Cheap, non-destructive, and it isolates the recipe from everything else. Run
one stack's producer directly, with no repository and no network involved:

```bash
cd ~/home-lab && sudo BACKUP_STAGE=/tmp/drill REPO_ROOT="$PWD" infra/<stack>/backup.sh
```

```bash
sudo tail -3 /tmp/drill/<stack>.sql && sudo cat /tmp/drill/paths.txt
```

For a Postgres stack the last line must read `-- PostgreSQL database dump
complete`. `pg_dump` writes it only after finishing cleanly, so its presence
rules out the truncated dump that is otherwise indistinguishable from a good
one. `paths.txt` should list exactly what that stack's `backup.sh` declares.

```bash
sudo rm -rf /tmp/drill
```

## 2. Take the backup

```bash
sudo infra/backup/run.sh
```

```bash
sudo bash -c 'set -a; . infra/backup/.env; set +a; restic snapshots --tag <stack>'
```

## 3. Plant the marker

Pick from the per-stack table below. Then restore:

```bash
sudo infra/<stack>/restore.sh
```

Each script lists snapshots, names the one it will use, and requires you to
type the stack name before it does anything destructive. Running it to *look*
and aborting at the prompt is a reasonable thing to do.

## 4. Verify, then clean up

Each `restore.sh` prints its own verification list, ordered so the most
meaningful check comes first. Work through it before deleting anything.

```bash
sudo du -sh /opt/<stack>.bak-* /opt/backup/restore/<stack> 2>/dev/null
```

```bash
sudo rm -rf /opt/<stack>.bak-<timestamp> /opt/backup/restore/<stack>
```

**Not before the checks pass** — the `.bak-` tree is the way back if the
restore was wrong. Note that monitoring's is `/opt/monitoring/postgres.bak-*`,
not a whole-tree copy, because its restore is narrow.

## Per stack: what to mark, and what actually proves it

| Stack | Marker | The check that proves it |
|---|---|---|
| **authentik** | Create a user after the backup | The user is gone, and Dockge still redirects through Authentik and back |
| **dockge** | Create a second Dockge account | It is gone, and your original account still logs in |
| **forgejo** | **Delete a package** from the registry | It is back afterwards, and `docker pull` of it works |
| **monitoring** | Switch the Grafana theme (dark ↔ light) | The theme reverts, **and** Prometheus/Loki/Tempo still return pre-restore data |
| **traefik** | *(none — see below)* | The served certificate is the restored one, not a fresh reissue |
| **uptime-kuma** | Create a throwaway monitor | It is gone, and heartbeat history survived |
| **vaultwarden** | A new item **and** an attachment on an existing one | A login from an **already-paired** client still works |

### authentik

The user's absence proves the restored database is the backup's. Dockge
redirecting proves more: the forward-auth outpost and its token survived, so
`AUTHENTIK_SECRET_KEY` still decrypts what is inside that database — the `.env`
and the dump came back as one unit.

### dockge

The smallest drill in the set, and the one with the least at stake — Dockge's
own accounts are kilobytes and re-creatable through its first-run form. Make a
second account as the marker; your original still logging in afterwards is what
proves the restore rather than an empty database.

**Its restore is narrow, and for a reason unique to this stack.** Dockge is the
one stack *copied* into `/opt/stacks` rather than symlinked, so
`/opt/stacks/dockge` also holds a `compose.yaml` and a `.env` written by
`scripts/init-dockge.sh`. Neither is in the backup, and the compose is what the
stack is started from — so `restore.sh` touches `data/` alone. Confirm those two
files are still there afterwards.

The stack list Dockge shows proves nothing: it is read from `/opt/stacks` at
runtime, so it would look identical if the restore had done nothing at all.

### forgejo

The largest snapshot in the repository, so allow room and time: the staged copy
under `/opt/backup/restore/forgejo` is a second copy of the registry blobs, and
the `.bak-` tree beside it is a third until you delete it.

**The best marker for this stack is a deletion, not a creation.** Delete a
package from the registry after the backup; it should be back afterwards. That
is stronger than creating a repository, because it exercises the exact thing
this stack's shape exists to protect — the registry — rather than proving the
database rolled back and inferring the rest.

> **It is also the only marker here that risks something.** If the restore
> fails, the package stays deleted. Pick one you could rebuild — a CI artifact
> rather than the only copy of anything — or create a throwaway one to delete.
> Every other stack's marker is additive and costs nothing if the restore does
> not work.

Then **`docker pull` the package that came back**. That is the one operation
needing both halves at once: the blobs live under `forgejo/` and their package
metadata lives in the database. Seeing it listed again proves the metadata
returned; pulling it proves the blobs did too. Browsing the Packages tab alone
would look identical with the blobs missing behind it.

Two more checks worth doing because nothing else covers them:

- **Clone over SSH from a machine that has pushed before.** No
  `REMOTE HOST IDENTIFICATION HAS CHANGED` means the SSH host keys under
  `forgejo/` came back. A fresh machine would not notice either way.
- **Actions → Runners shows the runner online.** That proves `.runner`
  survived. If `restore.sh` printed a `DOCKER_GID` warning, fix that first —
  on a rebuilt VM the docker group can land on a different gid than the
  snapshot recorded, and a runner that cannot reach the socket is the only
  symptom while the web UI, git and the registry all work perfectly.

### monitoring

The theme is a good marker because Grafana stores it as a per-user *preference
row*: unambiguous at a glance, and nothing to clean up afterwards, unlike a
throwaway user. **Do not use a dashboard** — they are provisioned from this
repo and return on an empty database.

The second half of the check is unique to this stack. Its restore is
deliberately **narrow**, touching `postgres/` alone and leaving `prometheus/`,
`loki/`, `tempo/`, `alloy/` and `grafana/` untouched, because those are Tier 3
and were never in the snapshot. So *Explore → Prometheus* still returning data
from before the restore is what proves the script left them alone. If they are
empty, the restore was too aggressive.

### traefik

**The only stack with no useful marker, and the reason is worth understanding.**
Almost everything about Traefik comes back whether the restore worked or not:
its routing is labels on other stacks' containers plus files under
`infra/traefik/dynamic/`, all of which are in git. The dashboard will load,
every router will be listed, every backend will resolve. None of that came from
the snapshot.

The backup holds exactly two things — `acme.json` and the netcup credentials —
so there is exactly one check:

```bash
echo | openssl s_client -connect git.thefipster.de:443 -servername git.thefipster.de 2>/dev/null | openssl x509 -noout -issuer -dates
```

**Compare `notBefore` against the snapshot's date.** A timestamp from minutes
ago means `acme.json` did *not* come back and Traefik simply went and got a new
certificate — which looks like a perfect success and is a failed restore that
also burned one of five weekly duplicate-certificate issuances. `restore.sh`
also prints a `docker compose logs traefik | grep -i acme` check: a restored
store means Traefik has no challenge work to do at startup.

The netcup credentials in the `.env` are not exercised by anything until a
renewal, roughly 30 days before expiry. A wrong `.env` is therefore invisible
for months. Nothing in a drill can surface that; the staging-CA line commented
out in `infra/traefik/compose.yaml` is what exists for testing issuance
deliberately.

> **Traefik terminates TLS for the whole lab.** While it is down nothing is
> reachable by name — including Authentik, which everything else authenticates
> against, and Kuma, which will have nothing to report to. Drill this one when
> an outage is acceptable.

### uptime-kuma

Kuma is the watcher: while it is down nothing is monitoring the lab, and the
script says so at the prompt. Two things read as failures and are not — both
push monitors (the backup job and the hypervisor's ZFS health) show as down
after a restore until their next push arrives, because nothing pushes on
demand.

Heartbeat history is the bulkiest thing in the database, so its survival is the
clearest sign the whole dump loaded rather than just the schema.

### vaultwarden

The one stack whose loss has no other recovery path, so two extra precautions
before you start.

**Have a client already paired *before* the backup**, and leave it alone for
the rest of the drill. Device records live in the database, so a client paired
*after* the backup will not be in the restored one and the check would fail for
a reason that is not the one being tested.

**Consider a password-protected export as insurance** (*Web vault → Tools →
Export vault*), and delete it afterwards — a plaintext export is a copy of
everything.

Then mark **both halves**, because this stack's state is split and the whole
point of its backup shape is that the halves come back together: a new item for
the database, an attachment on an existing item for `data/`.

Check the attachment is gone from **disk**, not just from the UI. If the
database rolled back and `data/` did not, the file would still be there as an
orphan the UI cannot see:

```bash
sudo ls -R /opt/vaultwarden/data/attachments
```

**Why the paired-client check cannot be replaced by opening the web vault.** A
fresh browser login would succeed even if `rsa_key.pem` and the database came
from *different* snapshots — the server would simply re-issue everything. Only
a client holding a token signed by the old key can tell you the two came back
as a unit. It is the check that looks like the least and proves the most.

Also confirm `/admin` still accepts the `ADMIN_TOKEN`: that proves the Argon2id
string in `.env` survived byte-for-byte, which it only does if the file was
copied rather than retyped.

## Record the result

Each drill gets a dated finding in `docs/review/`, the same way the guide
replays do. Write down what was marked, what proved it, and — as importantly —
**what the drill did not cover**, so a narrow result is not read as a broad
one.

## Still unproven by any drill here

Stated so nothing above is mistaken for more than it is:

- **A VM-rollback drill.** Every drill so far has been an in-place restore on a
  working VM. Rolling the infra VM back to a snapshot first is a materially
  harder test, and it is where the clock-skew-after-rollback failure surfaces —
  a restored guest resumes with a stale clock and every TLS client fails with
  "certificate has expired or is not yet valid". Expect it; do not misdiagnose
  it as a bad restore.
- **The deadman's silent half.** Nothing has yet watched the Kuma monitor go
  **red** because a heartbeat did not arrive. Breaking one stack's `backup.sh`
  deliberately, then confirming the run exits non-zero, stays silent, and turns
  the monitor red, is the cheap way to test it.
- **The weekly `restic check`**, which has no heartbeat of its own — an
  unreadable repository stays quiet until somebody looks.

## Troubleshooting

**`restore.sh` aborts with "missing from the snapshot".** That is the check
working. It runs *before* anything is moved, so the stack is only stopped and
`/opt/<stack>` is untouched — bring it back up with `docker compose up -d` in
the stack directory. If the missing item is the SQL dump, the snapshot is
**degraded**: a night when the dump failed and the runner captured the files
anyway. The next move is *Last resort: the raw PGDATA* in
[backup-setup.md](backup-setup.md#last-resort-the-raw-pgdata), and it operates
on `/opt/<stack>` exactly as it stands, so do not undo anything first.

**The restore failed part-way through.** Every `restore.sh` prints where it
moved your previous tree and the command to put it back. Nothing is deleted.

**The marker is still there after the restore.** The restore did not take.
Check you restored the right snapshot — `restic snapshots --tag <stack>` lists
them with timestamps, and the scripts accept an explicit id as their first
argument.

## Next

Back to [backup-setup.md](backup-setup.md) for the mechanism itself, or
[roadmap/backup.md](roadmap/backup.md) for what phase 5 still asks for.
