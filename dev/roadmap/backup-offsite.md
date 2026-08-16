# Task: Offsite backup

Goal: a copy that survives the building. This is phase 3 of the original backup
design ([done/backup.md](done/backup.md#phases)) — the one phase nothing on the
box can close, and the only remaining path to 3-2-1 being true rather than
aspirational.

**Where it stands.** Both layers live inside the machine they protect: `vzdump`
onto the `vmbackup` mirror, restic onto the `filebackup` mirror — real second
copies on their own drives, behind the same walls. A fire or a theft takes every
copy at once. The external drive the earlier hardware had could at least be
carried somewhere; the mirrors cannot, and the carrying was never alarmable
anyway. Client-side encryption was chosen precisely so that any target is
untrusted by construction — **what remains is choices and credentials, not
design.**

## The decisions

- **Target.** B2, netcup Storage Space, or anything rclone reaches. The deciding
  factors are price per GB at rest and whether the first full upload is feasible
  on the uplink.
- **Topology.** `restic copy` from the hypervisor (clients unchanged, one mover,
  but the repository password lands on the host) versus each client writing to a
  second repository directly (no new trust on the host, two uploads a night over
  the WAN). Either is correct; pick one in a short spec and say why.
- **Retention on the second repository** — it need not match the local one; a
  slimmer keep-set offsite is a legitimate answer to upload cost.
- **A heartbeat for the copy job.** A silent offsite copy is decorative — the
  same rule `run.sh`'s Kuma push already enforces locally.
- **`RESTIC_PASSWORD` discipline is unchanged** and worth restating in the
  guide: the authoritative copy lives outside the lab, on paper or in an account
  that survives the building — offsite bytes with an on-premises-only key are
  not offsite.

## Recommendation

Rank it second, behind only the apps-VM join. Write the one-page spec (target +
topology), run the bandwidth check against the real repository size, and treat
[registry-hygiene.md](registry-hygiene.md) as the natural predecessor — the
Forgejo registry blobs dominate the repository, so expiring them first shrinks
the first full upload — but do not let hygiene gate this: an offsite copy of a
slightly-too-big repository beats no offsite copy of a tidy one.
