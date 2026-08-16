# Docs restructure: separating the lab from the reasoning about it

**Date:** 2026-08-16
**Branch:** `docs/restructure`

`docs/` has accumulated four kinds of document behind one flat listing, and two
of those kinds are not about the lab at all. This splits them by intent: what
you read to **build** the lab, and what you read to understand **why it looks
like that**.

This spec is written at `docs/superpowers/specs/`, the location the repo's
convention names today, and is moved to `dev/specs/` by its own
implementation along with the other nineteen. It is a record of a decision made
while the old layout was still in force.

## The problem

Twenty-one files sit flat in `docs/`, and they are four different things:

| Kind | Count | What it does |
|---|---|---|
| Guides | 15 | Tell you to do something, in order, on a named machine |
| Registries / catalogs | 4 | Hold the values a guide refuses to repeat inline |
| Drills | 1 | Prove a thing that was built still works |
| Status | 1 | Says what is real versus what is only written down |

Beside them sit three subdirectories — `roadmap/`, `review/`,
`superpowers/{specs,plans}` — holding 46 files that describe **decisions**
rather than the lab (47 once this spec joins them). A reader opening `docs/` cannot tell which is which, and
the flat listing implies all twenty-one top-level files are peers.

Flatness was a deliberate choice, and CLAUDE.md states its reason: filenames
already carry the service name, and nesting adds a `../` to every cross-guide
link. That reason survives this change, because **guides stay in one directory
together** — the 150 guide→guide links do not move. What nesting buys is the
separation of the other three kinds, which the flat layout cannot express at
all.

## The structure

```
README.md                    the front door and the build order
CLAUDE.md                    unchanged in place; its "Docs layout" section rewritten
STATUS.md                    was docs/status.md
docs/                        THE LAB AS IT IS
├── guides/                  15 files — 14 *-setup.md plus wildcard-dns-udr.md
├── reference/                4 files — dns-records, sso-applications,
│                                       uptime-kuma-monitors, timetable
└── drills/                   1 file  — backup-restore-drill.md
dev/                         HOW IT GOT DECIDED
├── roadmap/                  5 files — was docs/roadmap/
├── specs/                   20 files — was docs/superpowers/specs/
├── plans/                   17 files — was docs/superpowers/plans/
└── reviews/                  5 files — was docs/review/
```

**The rule that decides where a new file goes:** `docs/` is what you read to
build the lab; `dev/` is what you read to understand why it looks like that.
Anything you could delete without making the lab unbuildable is `dev/`.

Within `docs/`, the three directories are told apart by what the reader is
holding when they open the file:

- **`guides/`** — an instruction to carry out, on the machine its `**Runs on:**`
  line names. Numbered steps, each with verification.
- **`reference/`** — a value to look up while carrying out a guide. Never
  instructions; the guides link here instead of repeating a per-service value.
- **`drills/`** — a procedure to re-run on a schedule against a lab that is
  already built, to prove a property still holds. Distinguished from a guide by
  recurrence: a guide is run once per rebuild, a drill is run forever.

### Four placement decisions

**`roadmap/` is development documentation.** It is forward-looking
decision-making, the same family as `specs/` — it describes work not built yet.
This is the least obvious of the four calls, because 61 references — from the
guides, the registries, STATUS, the README, CLAUDE.md and `apps/` — cite it as
the place a deliberate gap is recorded, which makes it
read like lab content. It is not: a gap statement is a decision about what the
lab will not do yet, and the guides citing it are reaching **out** of the
build instructions into the reasoning, which is exactly the boundary this
structure makes visible.

**`status.md` becomes `STATUS.md` at the repo root.** It fits none of the three
`docs/` categories — it is not an instruction, not a value, and not a
procedure. It answers "is this real?" about the whole lab, which is a
front-door question; README already devotes a section to pointing at it. At the
root it sits beside README and CLAUDE, and `docs/` is left holding exactly three
category directories and no loose file.

**The `superpowers/` layer is dropped.** It names the tool that produced the
files rather than what they are, and `dev/` already carries "how this got
decided". Consequence, and it must be recorded: the brainstorming skill writes
specs to `docs/superpowers/specs/` by default, so **CLAUDE.md has to name
`dev/specs/` and `dev/plans/` explicitly** or the next session recreates the old
tree.

**`review/` becomes `reviews/`,** so all four `dev/` children read alike.
`roadmap` stays singular: it is the roadmap, not a collection of roadmaps.

### Filenames do not change

`docs/guides/traefik-setup.md`, not `docs/guides/traefik.md`. The directory adds
the category; the filename keeps carrying the service name, which is the rule
CLAUDE.md already states and which nothing here contradicts. Renaming would also
make prose ambiguous — `backup.md` would name both the guide and the roadmap
file, and several passages cite the two in the same sentence.

## Link repair

Every link in the repository keeps working. This is a restructure, not feature
work, so a link that resolves today must resolve afterwards.

Measured inventory of what moves:

| Where | Links | Change |
|---|---|---|
| Inside `docs/`, crossing categories | 124 | 55 guide→reference, 42 reference→guide, 21 from STATUS, 6 involving the drill |
| Inside `docs/`, same category | 150 | **none** — guide→guide is untouched |
| `docs/` content → `../infra`, `../scripts` | 47 | one more `../` |
| `docs/` content → the dev tree | 30 | now `../../dev/roadmap/…` |
| README, CLAUDE.md, `apps/`, `infra/`, `scripts/` | ~159 mentions | audited; real path references rewritten |
| Inside `dev/roadmap/` (live, not frozen) | 27 | full repair, prose included |
| Inside the frozen tree | 140 | links repaired, prose frozen (see the rule below) |
| Inside the frozen tree, already broken | 23 | **left alone** — their targets genuinely no longer exist |

### Path math

| From | To | Was | Becomes |
|---|---|---|---|
| `docs/guides/` | `docs/guides/` | `traefik-setup.md` | unchanged |
| `docs/guides/` | `docs/reference/` | `dns-records.md` | `../reference/dns-records.md` |
| `docs/guides/` | `docs/drills/` | `backup-restore-drill.md` | `../drills/backup-restore-drill.md` |
| `docs/guides/` | root | `status.md` | `../../STATUS.md` |
| `docs/guides/` | `dev/` | `roadmap/backup.md` | `../../dev/roadmap/backup.md` |
| `docs/guides/` | `infra/`, `scripts/` | `../infra/…` | `../../infra/…` |
| `docs/reference/` | `docs/guides/` | `traefik-setup.md` | `../guides/traefik-setup.md` |
| `docs/drills/` | `dev/roadmap/` | `roadmap/backup.md` | `../../dev/roadmap/backup.md` |
| `STATUS.md` | `docs/guides/` | `traefik-setup.md` | `docs/guides/traefik-setup.md` |
| `dev/roadmap/` | `docs/guides/` | `../grafana-setup.md` | `../../docs/guides/grafana-setup.md` |
| `dev/specs/`, `dev/plans/` | `dev/roadmap/` | `../../roadmap/…` | `../roadmap/…` |
| `dev/specs/`, `dev/plans/` | `docs/guides/` | `../../traefik-setup.md` | `../../docs/guides/traefik-setup.md` |
| `dev/reviews/` | `dev/specs/` | `../superpowers/specs/…` | `../specs/…` |
| `dev/reviews/` | `dev/roadmap/` | `../roadmap/…` | unchanged |

### The historical-record boundary

CLAUDE.md holds that `dev/specs/`, `dev/plans/` and `dev/reviews/` are
historical records that must never be retro-edited. Moving them breaks 140
links that resolve today, so the boundary needs stating precisely:

> **If an edit changes which document a reader lands on, it is a retro-edit and
> is forbidden. If it lands them on the same document at its new address, it is
> a move-repair and is required.**

A historical record records what was **said**, not where files sat. Repairing an
address preserves the record; changing the prose rewrites it.

This splits the two kinds of path reference apart, and they are treated
differently:

- **Markdown links are addresses.** Repaired everywhere, including the frozen
  tree. `[the spec](../../roadmap/backup.md)` is navigation, and navigation that
  lands nowhere serves nobody.
- **Bare paths in prose are statements.** Frozen in `dev/specs/`, `dev/plans/`
  and `dev/reviews/`. A plan whose task list says ``Modify: `docs/roadmap/backup.md` ``
  is recording what was modified on the day it ran, and the file did live there
  then. Rewriting it would make the plan claim something that never happened.

`dev/roadmap/` is **not** in the frozen tree — it is live, forward-looking and
edited routinely — so it gets full repair, prose included. So do `README.md`,
`CLAUDE.md`, `STATUS.md` and everything under `docs/`.

The 23 links already broken before this change stay broken and untouched. They
are precedent, not oversight: `dev/reviews/` records some of them as
deliberately left.

## Documents that must change, not just move

**`CLAUDE.md` — the "Docs layout" section is rewritten.** It currently opens by
listing the guides as a flat build-order chain, states the flatness rationale
for `docs/` and `scripts/` together, and names `docs/superpowers/{specs,plans}`
and `docs/review/` as the historical-record tree. All four claims change. It
must newly state: the three-way split inside `docs/` and the rule that decides
between them; that `dev/` exists and what belongs there; that specs go to
`dev/specs/` and plans to `dev/plans/`, overriding the skill default; and that
`scripts/` stays flat for its own reason, now that it no longer shares one with
`docs/`.

**`CLAUDE.md` — the topology section's one-directory-per-VM claim.** It says
"the repo root **is** the machine map". With `dev/` and `STATUS.md` added, the
root holds five non-machine entries. The claim needs qualifying rather than
deleting: the machine map is what the root's *directories about the lab* are,
and `docs/`, `dev/` and `scripts/` are the ones that are not.

**`README.md` — the "Registries & catalogs" section.** It currently mixes the
four registries with the drill and `apps/services.md` in one table. The drill is
now its own category with its own directory, so it gets its own short section;
`apps/services.md` stays in the registries table, since it is a catalog that
happens to live beside the machine it describes.

**`README.md` — the build order.** Fifteen links gain `guides/`.

**`STATUS.md` — its own header.** Its `**Runs on:** nothing — status record, not
a build step` line was written for a file inside `docs/`. At the root beside
README it still wants the line, since every other non-guide document carries one.

## Verification

A throwaway link resolver, run from the scratchpad rather than added to
`scripts/` — that directory holds VM init scripts and a docs linter would be its
first exception without earning it.

The method is a before/after comparison, not an absolute check:

1. Before any move, resolve every markdown link in every tracked `.md` file and
   record the set that fails. Expected: the 23 known-broken links in
   `dev/plans/`, plus whatever else the sweep finds.
2. Perform the restructure.
3. Resolve again.
4. **Pass condition: the after-set equals the before-set.** Not "no broken
   links" — that would demand fixing rot this change did not cause, and would
   collide with the frozen-prose rule.

Three further checks, each catching something the resolver cannot:

- **`git log --follow` on one moved file per directory** returns history from
  before the move, confirming `git mv` was used throughout rather than
  delete-and-add.
- **A grep for the old paths** — `docs/roadmap/`, `docs/review/`,
  `docs/superpowers/`, `docs/status.md` — over `README.md`, `CLAUDE.md`,
  `docs/`, `infra/`, `apps/`, `scripts/` returns nothing. Hits inside
  `dev/specs/`, `dev/plans/` and `dev/reviews/` are expected and correct: that
  is the frozen prose.
- **Anchor links survive.** 40-odd links carry `#part-8--…` style fragments;
  the resolver checks the file, so headings are spot-checked separately in
  `proxmox-setup.md`, which owns most of them.

## What this deliberately does not do

- **No file is renamed** beyond `status.md` → `STATUS.md` and `review/` →
  `reviews/`.
- **No content is rewritten** except the CLAUDE.md and README.md sections named
  above, which describe the layout and would otherwise be false.
- **The roadmap files are not folded into the guides.** Splitting each roadmap's
  gap statement out to the guide that owns it was considered and rejected for
  this change: it is a content edit across eight guides, and it is separable —
  it can be done later, against the new structure, without redoing any of this.
- **No docs index page is added.** `README.md` already indexes the guides,
  registries and status; a `docs/README.md` would be a second index to keep in
  sync.
