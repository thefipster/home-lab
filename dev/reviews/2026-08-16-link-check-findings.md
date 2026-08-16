# Link check after the docs restructure — 2026-08-16

The [docs restructure](../plans/2026-08-16-docs-restructure.md) moved 69 files
and rewrote roughly 540 references. Its verification was a link resolver run
before and after, diffed. That resolver reported **124 broken links before the
move and 123 after** — a number alarming enough to be worth chasing, and this is
the record of what chasing it found.

Like the [guide replay](2026-07-26-guide-replay.md) and the [backup bring-up
record](2026-08-07-backup-bring-up.md), this is a dated record. It states what
was found and what was done about it; it is not retro-edited when anything later
changes.

> **Status: no documentation was changed.** The count was an artefact of the
> tool. Live documentation had zero broken links before the restructure and has
> zero after.

## The finding

Of the 123 broken links the resolver reported, **none is a defect in the
documentation.**

| Count | What it actually is |
|---|---|
| 84 | Inside fenced code blocks |
| 37 | Embedded instruction content, unfenced |
| 2 | Genuine navigation to deliberately deleted files |
| **0** | **Broken links in live documentation** |

"Live documentation" means everything outside `dev/specs/`, `dev/plans/` and
`dev/reviews/` — every guide, every registry, the drills, `README.md`,
`STATUS.md`, `CLAUDE.md`, and the references embedded in `infra/`, `apps/` and
`scripts/`. All of it resolves.

## Why the number was wrong

**A plan quotes the markdown it wants written into a guide.** When
`2026-07-26-three-machine-lab.md` says

```markdown
- Prerequisite: one line linking [uptime-kuma-setup.md](uptime-kuma-setup.md)
  as the previous step.
```

that link is an *instruction*, and it is correct for its destination: from
`docs/guides/coolify-setup.md`, `uptime-kuma-setup.md` resolves. It fails only
when resolved from the file doing the quoting, which is the one place it was
never meant to be evaluated.

84 of those sit inside fenced code blocks, where a resolver has no excuse — it
should skip fences. The other 37 sit in bullet lists, where nothing
distinguishes quoted content from real navigation except reading it.

**Repairing them would corrupt the record.** A plan rewritten to
`../../docs/guides/uptime-kuma-setup.md` would claim it had specified a link it
never specified. That is precisely the case
[CLAUDE.md's frozen-prose rule](../../CLAUDE.md) covers: a markdown link is an
address and gets repaired when the target moves; a link inside quoted content is
a statement about what was written that day, and stays.

## The two that are real

Both point at files this repo deleted on purpose, when the example CI workflows
were removed once the real ones existed in the app repo:

- `dev/reviews/2026-08-02-fresh-playthrough-review.md:165` →
  `infra/forgejo/build-and-push.yml`
- `dev/specs/2026-08-08-apps-vm-storage-layout-design.md:145` →
  `infra/forgejo/release.yml`

There is nothing in this repo to point them at. Both records are accurate about
the day they were written — the files existed then — and inventing a substitute
target would misrepresent what those documents examined. **Left as they are,
deliberately.**

## What was changed instead

The resolver. A fence-aware version reports **684 links checked outside code
fences, 0 broken in live documentation**, and lists the historical-record hits
separately because only the first group is ever actionable.

The tool is not in the repo, for the reason the restructure spec gives:
`scripts/` holds VM init scripts, and a docs linter would be its first exception
without earning it. It is reproduced here so the next person does not have to
rediscover the fence rule.

```python
"""Fence-aware link resolver.  Usage: python check-links2.py [repo_root]"""
import os
import re
import subprocess
import sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
files = subprocess.run(['git', '-C', root, 'ls-files', '*.md'],
                       capture_output=True, text=True, check=True).stdout.split()

LINK = re.compile(r'\[[^\]]*\]\(\s*([^)\s]+?)\s*\)')
SKIP = ('http://', 'https://', 'mailto:', '#')
FROZEN = ('dev/specs/', 'dev/plans/', 'dev/reviews/')

live_broken, frozen_broken = [], []
checked = 0

for rel in sorted(files):
    rel = rel.replace(os.sep, '/')
    path = os.path.join(root, rel)
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().splitlines()
    infence = False
    for n, line in enumerate(lines, 1):
        if re.match(r'\s*(```|~~~)', line):
            infence = not infence
            continue
        if infence:
            continue
        for target in LINK.findall(line):
            if target.startswith(SKIP):
                continue
            frag = target.split('#', 1)[0]
            if not frag:
                continue
            checked += 1
            if os.path.exists(os.path.normpath(os.path.join(os.path.dirname(path), frag))):
                continue
            entry = '%s:%d -> %s' % (rel, n, target)
            (frozen_broken if rel.startswith(FROZEN) else live_broken).append(entry)

print('=== LIVE documentation ===')
for b in live_broken:
    print(b)
print('%d broken' % len(live_broken))
print()
print('=== historical records (dev/specs, dev/plans, dev/reviews) ===')
for b in frozen_broken:
    print(b)
print('%d broken' % len(frozen_broken))
print()
print('--- %d links checked outside code fences ---' % checked)
```

## Read this before "fixing" a link count

The restructure plan reproduces the **original**, fence-blind resolver and
records `756 links checked, 124 broken` as its baseline. That baseline was the
right tool for the job it had — a before/after diff, where counting quoted
content is harmless because it is counted identically on both sides, and where
freezing anything already broken is exactly what protected the historical
records.

It is the wrong tool for the question "how healthy are the links?", and the plan
is a frozen record, so it will keep saying 124. **The number to trust for that
question is the one above: zero.**

## Addendum: the rewriter's frozen guard went stale the moment it ran

Found later the same day, renaming `wildcard-dns-udr.md` to
`wildcard-dns-unifi.md` with the same `retarget.py`.

Its literal-path pass is skipped for the historical records, guarded by

```python
FROZEN = ('docs/superpowers/', 'docs/review/')
```

Those are the **pre-restructure** paths. The restructure moved that tree to
`dev/specs/`, `dev/plans/` and `dev/reviews/`, so from the moment it finished,
the guard matched nothing and the literal pass ran over every historical record
unprotected. The tool disarmed its own safety catch by succeeding.

It surfaced as exactly one bad edit, caught by reading the diff: the move map
recorded inside `dev/plans/2026-08-16-docs-restructure.md` had its
`wildcard-dns-udr.md` value rewritten to `wildcard-dns-unifi.md`, making the plan
claim a mapping it never performed. Reverted. The four other `dev/` edits in that
commit were markdown-link targets — address repairs, which the rule requires.

The blast radius was small only because the rename's map had a single key. A map
with the restructure's 25 keys would have rewritten paths throughout the frozen
tree, and the link resolver would not have flagged any of it: rewriting
`docs/roadmap/backup.md` to `dev/roadmap/backup.md` inside a plan's prose
produces a path that *resolves*, so the broken-set diff stays clean while the
record quietly becomes false.

**Two lessons, and the second is the one that generalizes.** A path constant that
names the tree a refactor is moving has to be updated *as part of* that refactor.
And the verification here only ever checked that links resolve — it cannot see a
frozen record being made to say something new, because the edit that corrupts it
is precisely an edit that makes a path more valid. **Reading the diff over the
frozen tree is not optional, and no resolver replaces it.**

## What this leaves open

**Anchors are checked separately and are not clean.** The anchor resolver
reports 4 broken, all in `dev/reviews/`, all pointing at headings that were
renamed after the review was written. They are frozen for the same reason as the
two links above. No live document has a broken anchor.

**The 37 unfenced quotes stay ambiguous to any tool.** Nothing separates
"instruction to write a link" from "link" except prose. If a future resolver is
built, the honest options are to skip the historical-record tree entirely or to
accept the noise — not to reformat old plans so a checker can parse them.
