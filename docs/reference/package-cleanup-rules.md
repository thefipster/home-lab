# Package cleanup rules (registry)

**Runs on:** the Forgejo web UI — registry, not a build step

Every cleanup rule on the Forgejo package registry, with the exact field
values. They are **owner-scoped clickwork** — they live on the `felix` account
under *Settings → Packages → Cleanup Rules*, not in a compose file and not per
repository — so this registry is the record of what must exist. How to add
them: [forgejo-setup.md, step 9](../guides/forgejo-setup.md#9-set-the-registry-cleanup-rules).

**A package type with no rule is never touched.** Forgejo's cleanup job
iterates the rules that exist and does nothing about a type nobody wrote one
for, so it grows forever. That is what makes the
[deliberate absences](#deliberate-absences) below load-bearing rather than
tidy: a missing rule is indistinguishable from a decision unless it is written
down.

## The rules

Both are enabled, and both leave **Apply pattern to full package name** off —
the patterns are matched against the *version* alone (`1.2.3`), never against
`package/version`.

| Field | Container rule | Generic rule |
|---|---|---|
| Type | Container | Generic |
| Keep the most recent | 10 | 10 |
| Keep versions matching | `latest\|\d+\|\d+\.\d+` | `latest` |
| Remove versions older than | *(blank)* | *(blank)* |
| Remove versions matching | `.*` | `.*` |

**Patterns are anchored and case-folded by Forgejo, not by you.** Each one is
compiled as `(?i)\A<your pattern>\z`, so `\d+` matches the whole version or
nothing — adding `^`, `$`, `\A` or `\z` yourself is at best redundant and at
worst a pattern that can never match.

**A blank field is not a neutral field**, and the two blanks above do opposite
things. Blank *Remove versions older than* removes the age protection entirely
(see [Why neither rule has an age term](#why-neither-rule-has-an-age-term));
blank *Remove versions matching* would remove the final filter, which is the
same as `.*`. The explicit `.*` is written so the rule reads as a decision
rather than as a field someone forgot.

## What the patterns are written against

The release workflow in the app repo is the only thing that publishes here, and
it publishes two shapes. The patterns are legible only next to them:

| Registry | Package | A final release publishes | A prerelease publishes |
|---|---|---|---|
| container | `verdure/web`, `verdure/showcase` | `X.Y.Z`, `X.Y`, `X`, `latest` | `X.Y.Z-rcN` only |
| generic | `verdure-<component>` | `X.Y.Z`, `latest` | `X.Y.Z-rcN` only |

So `latest`, `X` and `X.Y` are **rolling** — rewritten by every release — and
the keep pattern exists to make them unreachable by any rule. `X.Y.Z` and
`X.Y.Z-rcN` are the versions that accumulate, and they are what expires.

**The generic registry has no rolling-tag concept**, which is why its keep
pattern is just `latest`: there is no `X` or `X.Y` version to protect, and
`latest` there is a real version whose files are rewritten each release rather
than a tag. It is also the one that matters most — a device updater fetches
`verdure-<component>/latest/<file>.bin` from a stable URL.

## How the rule decides

Forgejo sorts each package's versions newest-first and walks them. A version
survives at the **first** line that matches:

1. **Container only:** it is named `latest`, or it is named by a digest
   (an untagged manifest). Skipped outright, before the keep counter is even
   incremented.
2. It is within *Keep the most recent*.
3. It matches *Keep versions matching*.
4. It was created **after** `now - Remove versions older than`.
5. It does **not** match *Remove versions matching*.

Anything reaching the bottom is deleted. The order is the whole design: step 2
runs before step 4, so **the newest ten versions of every package survive
regardless of age** — an untouched registry cannot expire itself empty, however
long the gap between releases.

**`latest` is protected twice on the container side, deliberately.** Forgejo
hard-skips it at step 1 whatever the rules say; the keep pattern says so again
at step 3. The redundancy costs nothing and survives that upstream behaviour
changing.

## Why neither rule has an age term

Because the age field only ever *protects*, and blanking it is the stricter
choice, not the looser one. The cutoff is computed as
`now - RemoveDays`; with the field blank that is **now**, nothing was created
after it, and no version is spared at step 4.

The rules are therefore purely count-based: each package keeps its newest ten
versions plus its rolling tags, and anything beyond that goes at the next
midnight rather than lingering for a fixed number of days first. The registry's
size is bounded by how many packages exist, not by how often releases are cut —
which is the property worth having in a lab where the gap between releases is
measured in weeks and nobody wants to reason about a clock.

## What actually returns disk

Deleting a version deletes a manifest, not the layers under it. The blobs go in
the same midnight run, in the pass that follows the rules: unreferenced blobs
older than `OLDER_THAN` (24 h) are dropped from the database and from the
content store, and an image's untagged child manifests are collected once
nothing references them. Anything published more than a day ago — which is
everything a rule can reach — therefore frees its space the same night.

The schedule itself is Forgejo's, not this repo's:
[timetable.md](timetable.md#continuous-and-short-interval).

## Verifying a rule before it runs

Every rule has a **preview**, and it is the only safe way to read one. It lists
exactly the versions that rule would delete right now, so the question "does
this touch a tag something still pulls?" has an answer before midnight rather
than after it.

The registry is also readable without logging in, which is the quickest check
that a night's run did what the preview promised:

```bash
curl -s https://git.thefipster.de/api/v1/packages/felix | grep -o '"version":"[^"]*"'
```

## Deliberate absences

A gap that was decided reads differently from one that was overlooked, so both
kinds are listed — the same rule the other registries follow.

- **No rule for any other package type.** Forgejo offers one per type, and the
  lab publishes containers and generic archives only. A type nobody publishes
  to needs no rule; a type someone starts publishing to needs its own, because
  the two rules above cannot reach it.
- **No rule protects an exact `X.Y.Z` beyond the newest ten.** Ten releases
  back is further than any rollback here has ever wanted, and the alternative —
  keeping every version forever — is the thing this registry exists to stop.
  Pin a genuinely load-bearing version by giving it a keep pattern of its own
  rather than by raising the count for everything.
- **Nothing here governs run artifacts.** The SBOM and the vulnerability report
  are run artifacts with a 30-day retention set in the workflow, not packages.
  A cleanup rule cannot see them and the Packages tab does not list them.
- **No schedule of ours.** The rules are applied by Forgejo's own
  `cron.cleanup_packages`, whose row is in
  [timetable.md](timetable.md#continuous-and-short-interval). There is no timer
  in this repo to add and none to break.
- **No Uptime Kuma monitor.** A cleanup that silently stops running shows up as
  a registry that grows, and the disk it grows on is already watched by the
  hypervisor's pool-capacity metric. A push monitor would need something to
  push it, and Forgejo's cron cannot.
