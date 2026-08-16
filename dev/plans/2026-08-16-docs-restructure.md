# Docs Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `docs/` by intent — `guides/`, `reference/` and `drills/` for the lab as it is, a new top-level `dev/` for the reasoning about it, and `status.md` promoted to `STATUS.md` at the repo root — without breaking a single link that resolves today.

**Architecture:** One map-driven move. A single JSON map of old path → new path drives a Python script that rewrites every markdown link and every literal path string first, then performs the `git mv`s. The script's governing rule is that **only references which resolve before the move are rewritten** — anything already broken is left byte-identical, which is what preserves the frozen prose in `dev/specs`, `dev/plans` and `dev/reviews` as well as the repo's pre-existing link rot, for free and without a special case. Verification is a before/after diff of the broken-link set, not an absolute zero.

**Tech Stack:** Python 3 (stdlib only), `git mv`, PowerShell or Bash for the runner. No repo dependencies are added — both scripts are throwaways that live in the scratchpad.

**Spec:** `docs/superpowers/specs/2026-08-16-docs-restructure-design.md` (moves to `dev/specs/` in Task 2)

## Global Constraints

- **Every link that resolves today must resolve afterwards.** The pass condition is `diff` of the normalized broken-link set before and after → empty. Not "zero broken links".
- **The frozen tree is `docs/superpowers/specs/`, `docs/superpowers/plans/`, `docs/review/`** (→ `dev/specs/`, `dev/plans/`, `dev/reviews/`). In these, markdown links are repaired; **bare path strings in prose are never touched**.
- **`docs/roadmap/` is NOT frozen.** It is live and gets full repair, prose included.
- **No file is renamed** beyond `docs/status.md` → `STATUS.md` and `docs/review/` → `dev/reviews/`. Guides keep their `-setup.md` suffix.
- **`git mv` for every move** — never delete-and-add. History must follow the files.
- **Scratchpad only for tooling.** `scripts/` holds VM init scripts; no linter is added to the repo.
- **LF line endings.** `.gitattributes` forces LF repo-wide. Scripts must write `newline=''` so Python does not emit CRLF on Windows.
- **Durable wording in live docs.** No "the four registries" / "three directories" counts in `CLAUDE.md` or `README.md` — state facts that survive a file being added. Counts are fine inside the dated spec and this plan.
- **Baselines, measured 2026-08-16 on branch `docs/restructure` with this plan staged: 756 relative links checked, 124 broken; 184 anchor links checked, 4 broken.** Both are pass conditions by diff, not by zero.

**Scratchpad path.** Every command below assumes `$SCRATCH` is exported. Do this
first, in every shell you use:

```bash
export SCRATCH="/c/Users/felix/AppData/Local/Temp/claude/C--Users-felix-Source-home-lab/0baba981-f703-4594-ba8c-26245e271fae/scratchpad"
```

---

### Task 1: The verification harness and the baseline

Builds the test before the change. Nothing in the repo is modified by this task.

**Files:**
- Create: `$SCRATCH/check-links.py`, `$SCRATCH/check-anchors.py`
- Create: `$SCRATCH/baseline.txt`, `$SCRATCH/anchors-baseline.txt`
- Modify: nothing in the repository

**Interfaces:**
- Consumes: nothing
- Produces: `check-links.py`, invoked as `python check-links.py <repo_root>`, printing one `path:line -> target` line per broken link followed by a `--- N relative links checked, M broken ---` summary, sorted by path; and `check-anchors.py`, same invocation and output shape, reporting links whose target file exists but whose heading does not. Tasks 2–5 re-run both. Also produces `baseline.txt` and `anchors-baseline.txt`, the recorded pre-move outputs.

- [ ] **Step 1: Write the link resolver**

Create `$SCRATCH/check-links.py`:

```python
"""Resolve every relative markdown link in every tracked .md file.

Usage:  python check-links.py [repo_root]
Prints one line per broken link, then a summary count.
Exit code is always 0 -- the pass condition is a diff against a baseline,
not an absolute zero.
"""
import os
import re
import subprocess
import sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
files = subprocess.run(['git', '-C', root, 'ls-files', '*.md'],
                       capture_output=True, text=True, check=True).stdout.split()

LINK = re.compile(r'\[[^\]]*\]\(\s*([^)\s]+?)\s*\)')
SKIP = ('http://', 'https://', 'mailto:', '#')

broken = []
total = 0
for rel in sorted(files):
    path = os.path.join(root, rel)
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().splitlines()
    for n, line in enumerate(lines, 1):
        for target in LINK.findall(line):
            if target.startswith(SKIP):
                continue
            frag = target.split('#', 1)[0]
            if not frag:
                continue
            total += 1
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), frag))
            if not os.path.exists(resolved):
                broken.append('%s:%d -> %s' % (rel.replace(os.sep, '/'), n, target))

for b in broken:
    print(b)
print('--- %d relative links checked, %d broken ---' % (total, len(broken)))
```

- [ ] **Step 2: Write the anchor resolver**

`check-links.py` verifies that a link's *file* exists; it says nothing about the
`#part-8--…` fragment. Roughly a quarter of the repo's links carry one. Create
`$SCRATCH/check-anchors.py`:

```python
"""Resolve every in-repo markdown link that carries a #anchor.

Usage:  python check-anchors.py [repo_root]
Reports links whose target file exists but whose heading does not.
"""
import os
import re
import subprocess
import sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
files = subprocess.run(['git', '-C', root, 'ls-files', '*.md'],
                       capture_output=True, text=True, check=True).stdout.split()


def slug(heading):
    s = heading.strip().lower()
    s = re.sub(r'`|\*|_', '', s)
    s = re.sub(r'[^\w\s-]', '', s)
    return re.sub(r'\s', '-', s)


heads = {}
for rel in files:
    hs = set()
    with open(os.path.join(root, rel), encoding='utf-8') as fh:
        for line in fh:
            m = re.match(r'#+\s+(.*)', line)
            if m:
                hs.add(slug(m.group(1)))
    heads[rel.replace(os.sep, '/')] = hs

LINK = re.compile(r'\[[^\]]*\]\(\s*([^)\s]+?)\s*\)')
bad = 0
checked = 0
for rel in sorted(files):
    path = os.path.join(root, rel)
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().splitlines()
    for n, line in enumerate(lines, 1):
        for t in LINK.findall(line):
            if t.startswith(('http://', 'https://', 'mailto:')) or '#' not in t:
                continue
            f, _, anchor = t.partition('#')
            if not f or not anchor:
                continue
            tgt = os.path.normpath(
                os.path.join(os.path.dirname(rel), f)).replace(os.sep, '/')
            if tgt not in heads:
                continue
            checked += 1
            if anchor not in heads[tgt]:
                print('%s:%d -> %s' % (rel.replace(os.sep, '/'), n, t))
                bad += 1
print('--- %d anchor links checked, %d broken ---' % (checked, bad))
```

Note `re.sub(r'\s', '-', s)` replaces each whitespace character individually
rather than collapsing runs — that is what produces GitHub's double hyphen in
`#part-8--schedule-whole-vm-backups`, where an em dash was stripped from between
two spaces. Collapsing would report every such anchor as broken.

- [ ] **Step 3: Run both and confirm they reproduce the recorded baselines**

```bash
cd /c/Users/felix/Source/home-lab && python "$SCRATCH/check-links.py" . | tail -1 && python "$SCRATCH/check-anchors.py" . | tail -1
```

Expected, exactly:

```
--- 756 relative links checked, 124 broken ---
--- 184 anchor links checked, 4 broken ---
```

If either differs, **stop**. Either the working tree is not at the state this plan was measured against (this plan file must be staged or committed — it is counted), or a script was transcribed wrongly. Reconcile before going further.

- [ ] **Step 4: Save both baselines**

```bash
cd /c/Users/felix/Source/home-lab && python "$SCRATCH/check-links.py" . > "$SCRATCH/baseline.txt" && python "$SCRATCH/check-anchors.py" . > "$SCRATCH/anchors-baseline.txt"
```

- [ ] **Step 5: Sanity-check what the baselines contain**

```bash
cut -d: -f1 "$SCRATCH/baseline.txt" | sort | uniq -c | sort -rn | head -5
```

Expected: every path is under `docs/superpowers/plans/`, except one line in `docs/review/2026-08-02-fresh-playthrough-review.md` and one in `docs/superpowers/specs/2026-08-08-apps-vm-storage-layout-design.md`. These are embedded content (markdown a plan was going to write into a *guide*, which never resolved from the plan's own directory) plus two genuinely dead targets. All 124 must stay broken and byte-identical.

Four of them are contributed by **this plan file**, which quotes markdown destined for `README.md` and `STATUS.md` inside its code blocks. They are broken from `docs/superpowers/plans/` today and stay broken from `dev/plans/` afterwards, so they need no special handling — but do not be surprised to see this plan in its own baseline.

The 4 broken anchors are all in `docs/review/` and point at headings that were
later renamed — the same kind of frozen rot. They must stay broken too.

- [ ] **Step 6: No commit**

This task touches no tracked file. Nothing to commit — confirm with:

```bash
cd /c/Users/felix/Source/home-lab && git status --porcelain
```

Expected: empty output.

---

### Task 2: The structural move

The whole restructure in one commit: every `git mv`, every link repair, every literal path repair. Machine-generated and verified by Task 1's harness.

**Files:**
- Create: `$SCRATCH/movemap.json`, `$SCRATCH/retarget.py`
- Move: `docs/roadmap/` → `dev/roadmap/`, `docs/review/` → `dev/reviews/`, `docs/superpowers/specs/` → `dev/specs/`, `docs/superpowers/plans/` → `dev/plans/`, `docs/status.md` → `STATUS.md`, 15 guides → `docs/guides/`, 4 registries → `docs/reference/`, 1 drill → `docs/drills/`
- Modify: every tracked `.md`, `.sh`, `.yaml`, `.example` file that references a moved path

**Interfaces:**
- Consumes: `check-links.py` and `baseline.txt` from Task 1
- Produces: the new tree. **This plan file moves itself** — after this task it lives at `dev/plans/2026-08-16-docs-restructure.md`, and the spec at `dev/specs/2026-08-16-docs-restructure-design.md`. Tasks 3–5 read it there.

- [ ] **Step 1: Write the move map**

Create `$SCRATCH/movemap.json`. Directory keys are expanded to their tracked files by the script; file keys are used as-is.

```json
{
  "docs/roadmap": "dev/roadmap",
  "docs/review": "dev/reviews",
  "docs/superpowers/specs": "dev/specs",
  "docs/superpowers/plans": "dev/plans",
  "docs/status.md": "STATUS.md",
  "docs/proxmox-setup.md": "docs/guides/proxmox-setup.md",
  "docs/wildcard-dns-udr.md": "docs/guides/wildcard-dns-udr.md",
  "docs/infra-vm-setup.md": "docs/guides/infra-vm-setup.md",
  "docs/traefik-setup.md": "docs/guides/traefik-setup.md",
  "docs/vaultwarden-setup.md": "docs/guides/vaultwarden-setup.md",
  "docs/authentik-setup.md": "docs/guides/authentik-setup.md",
  "docs/dockge-setup.md": "docs/guides/dockge-setup.md",
  "docs/forgejo-setup.md": "docs/guides/forgejo-setup.md",
  "docs/grafana-setup.md": "docs/guides/grafana-setup.md",
  "docs/uptime-kuma-setup.md": "docs/guides/uptime-kuma-setup.md",
  "docs/homepage-setup.md": "docs/guides/homepage-setup.md",
  "docs/backup-setup.md": "docs/guides/backup-setup.md",
  "docs/apps-vm-setup.md": "docs/guides/apps-vm-setup.md",
  "docs/coolify-setup.md": "docs/guides/coolify-setup.md",
  "docs/home-assistant-setup.md": "docs/guides/home-assistant-setup.md",
  "docs/dns-records.md": "docs/reference/dns-records.md",
  "docs/sso-applications.md": "docs/reference/sso-applications.md",
  "docs/uptime-kuma-monitors.md": "docs/reference/uptime-kuma-monitors.md",
  "docs/timetable.md": "docs/reference/timetable.md",
  "docs/backup-restore-drill.md": "docs/drills/backup-restore-drill.md"
}
```

- [ ] **Step 2: Write the retargeting script**

Create `$SCRATCH/retarget.py`:

```python
"""Move files per a map, repairing every reference that pointed at them.

Usage:  python retarget.py <repo_root> <movemap.json>

The rule: only references that RESOLVE before the move are rewritten.
Anything already broken is left byte-identical -- that is what preserves the
frozen prose in dev/specs, dev/plans and dev/reviews, and the pre-existing rot,
without needing a special case for either.
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.abspath(sys.argv[1])
RAW = json.load(open(sys.argv[2], encoding='utf-8'))

tracked = subprocess.run(['git', '-C', REPO, 'ls-files'],
                         capture_output=True, text=True, check=True).stdout.split()
old_files = set(tracked)

# Expand directory renames into per-file renames.
moves = {}
for old, new in RAW.items():
    if old in old_files:
        moves[old] = new
    else:
        pre = old.rstrip('/') + '/'
        hits = [f for f in tracked if f.startswith(pre)]
        if not hits:
            sys.exit('map key matches nothing: ' + old)
        for f in hits:
            moves[f] = new.rstrip('/') + '/' + f[len(pre):]

FROZEN = ('docs/superpowers/', 'docs/review/')
LINK = re.compile(r'(\]\(\s*)([^)\s#]+)([^)]*\))')
SKIP = ('http://', 'https://', 'mailto:')
TEXTY = ('.md', '.sh', '.yaml', '.yml', '.example', '.json5')

link_edits = 0
literal_edits = 0
# Literal replacement runs longest-key-first so nested paths win.
literal = sorted(moves.items(), key=lambda kv: -len(kv[0]))
# Bare directory mentions in prose -- "docs/roadmap/ holds forward-looking
# plans" -- carry no filename for the file-level keys to match, so the
# directory keys from the map get their own pass.
dir_literal = sorted(
    ((k.rstrip('/') + '/', v.rstrip('/') + '/')
     for k, v in RAW.items() if k not in old_files),
    key=lambda kv: -len(kv[0]))

for rel in tracked:
    if not rel.endswith(TEXTY):
        continue
    path = os.path.join(REPO, rel)
    with open(path, encoding='utf-8') as fh:
        text = fh.read()
    before = text
    old_dir = os.path.dirname(rel)
    new_dir = os.path.dirname(moves.get(rel, rel))

    # Phase 1 -- markdown links, in every .md file including the frozen tree.
    if rel.endswith('.md'):
        def fix(m):
            global link_edits
            head, target, tail = m.groups()
            if target.startswith(SKIP):
                return m.group(0)
            old_tgt = os.path.normpath(
                os.path.join(old_dir, target)).replace(os.sep, '/')
            if old_tgt not in old_files:
                return m.group(0)          # broken today -> freeze
            new_rel = os.path.relpath(
                moves.get(old_tgt, old_tgt), new_dir or '.').replace(os.sep, '/')
            if new_rel == target:
                return m.group(0)
            link_edits += 1
            return head + new_rel + tail
        text = LINK.sub(fix, text)

    # Phase 2 -- literal repo-relative path strings, LIVE files only.
    if not rel.startswith(FROZEN):
        for old, new in literal + dir_literal:
            if old in text:
                literal_edits += text.count(old)
                text = text.replace(old, new)

    if text != before:
        with open(path, 'w', encoding='utf-8', newline='') as fh:
            fh.write(text)

print('link rewrites: %d' % link_edits)
print('literal path rewrites: %d' % literal_edits)

# Phase 3 -- the moves themselves.
for old, new in sorted(moves.items()):
    dest = os.path.join(REPO, new)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    subprocess.run(['git', '-C', REPO, 'mv', old, new], check=True)
print('moved: %d files' % len(moves))
```

- [ ] **Step 3: Run it**

```bash
cd /c/Users/felix/Source/home-lab && python "$SCRATCH/retarget.py" . "$SCRATCH/movemap.json"
```

Expected: three summary lines, ending with `moved: 69 files` — 5 roadmap + 5 reviews + 20 specs + 18 plans + 15 guides + 4 reference + 1 drill + `status.md`. The spec and this plan are counted; both move themselves. If the count is not 69, **stop** — the map did not match the tree.

- [ ] **Step 4: Verify the link and anchor sets are unchanged**

Normalize the link baseline's paths through the same directory renames, then diff:

```bash
cd /c/Users/felix/Source/home-lab && sed -E 's#^docs/superpowers/(specs|plans)/#dev/\1/#; s#^docs/review/#dev/reviews/#' "$SCRATCH/baseline.txt" > "$SCRATCH/baseline-normalized.txt" && python "$SCRATCH/check-links.py" . > "$SCRATCH/after.txt" && diff "$SCRATCH/baseline-normalized.txt" "$SCRATCH/after.txt" && echo "LINKS IDENTICAL"
```

Expected: `LINKS IDENTICAL`, with no diff output above it. The summary line inside both files must still read `--- 756 relative links checked, 124 broken ---`.

A diff here means one of two failures, and they read differently: a **new** line is a link that used to resolve and now does not; a **changed target** on an existing line is a frozen-prose violation — the script rewrote embedded content it should have left alone.

Then the anchors. These cannot be path-normalized the same way: all four broken
ones sit in the frozen tree but their links *resolve*, so `retarget.py` correctly
rewrites each target to a different new directory. Compare the invariant instead
— the anchor fragments and the count:

```bash
cd /c/Users/felix/Source/home-lab && python "$SCRATCH/check-anchors.py" . > "$SCRATCH/anchors-after.txt" && diff <(cut -d'#' -f2- "$SCRATCH/anchors-baseline.txt" | sort) <(cut -d'#' -f2- "$SCRATCH/anchors-after.txt" | sort) && echo "ANCHORS IDENTICAL"
```

Expected: `ANCHORS IDENTICAL`. The summary line carries no `#`, so it passes through both sides unchanged and the count is compared along with the fragments.

- [ ] **Step 5: Verify the frozen tree's prose is untouched**

Bare paths in the historical records must still name the old locations:

```bash
cd /c/Users/felix/Source/home-lab && grep -rc 'docs/roadmap/\|docs/review/\|docs/superpowers/' dev/specs dev/plans dev/reviews | grep -v ':0' | head
```

Expected: **non-empty output** — several files still contain the old paths in prose. That is correct and required: those sentences record what was true on the day they were written.

- [ ] **Step 6: Verify no live file still names an old path**

`CLAUDE.md` is excluded here on purpose — it still describes the old layout in
prose, and rewriting that is Task 3's whole job. Task 5 re-runs this grep with
`CLAUDE.md` included.

```bash
cd /c/Users/felix/Source/home-lab && grep -rn 'docs/roadmap/\|docs/review/\|docs/superpowers/\|docs/status\.md' README.md STATUS.md docs infra apps scripts home-assistant
```

Expected: **no output.** Any hit is a literal path the script missed.

- [ ] **Step 7: Verify history followed the files**

```bash
cd /c/Users/felix/Source/home-lab && for f in docs/guides/traefik-setup.md docs/reference/dns-records.md docs/drills/backup-restore-drill.md dev/roadmap/backup.md dev/specs/2026-08-08-homepage-design.md dev/plans/2026-08-08-homepage.md STATUS.md; do echo "$f: $(git log --follow --oneline -- "$f" | wc -l) commits"; done
```

Expected: every file reports more than 1 commit. A file at exactly 1 was added rather than moved.

- [ ] **Step 8: Commit**

```bash
cd /c/Users/felix/Source/home-lab && git add -A && git commit -m "$(cat <<'EOF'
docs: split docs/ by intent and extract dev/

docs/ now holds only what you read to build the lab -- guides/, reference/
and drills/. The reasoning about it moves to a new top-level dev/:
roadmap/, specs/, plans/ and reviews/. status.md is promoted to STATUS.md
beside README and CLAUDE.

Every link that resolved before this commit still resolves. The 120
pre-existing broken links -- embedded content inside plans, plus two dead
targets -- are byte-identical, which is also what keeps the prose of the
historical records frozen.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: CLAUDE.md — the layout contract

The move is done; now the document that tells future sessions how the repo is laid out has to stop describing the old one. Three separate claims in `CLAUDE.md` are now false.

**Files:**
- Modify: `CLAUDE.md:31` (the machine-map claim), `CLAUDE.md:694-702` (the docs layout opening), `CLAUDE.md:726-733` (the registries paragraph), `CLAUDE.md:750-758` (the historical-records paragraph)

**Interfaces:**
- Consumes: the tree produced by Task 2
- Produces: the layout rules future sessions read — in particular the `dev/specs/` + `dev/plans/` override, without which the superpowers skills recreate `docs/superpowers/`

**Line numbers below are from `CLAUDE.md` as Task 2 left it, and Step 2 makes the file longer.** Either apply the steps **bottom-up** (Step 4, then 3, then 2, then 1) so every number stays valid, or match on the quoted text — each quoted block is unique in the file.

- [ ] **Step 1: Fix the machine-map claim**

`CLAUDE.md:31` currently reads:

```
Router. **The repo root is the machine map** — one directory per VM — while
`docs/` and `scripts/` stay flat, because their filenames already carry the
service name and nesting them would add a `../` to every cross-guide link:
```

Replace those three lines with:

```
Router. **The repo root's lab directories are the machine map** — one per VM.
The rest of the root is not machines: `scripts/` stays flat because it holds one
kind of file whose names already carry the service name, `docs/` holds what you
read to build the lab, and `dev/` holds why it looks the way it does:
```

- [ ] **Step 2: Rewrite the docs layout opening**

Replace `CLAUDE.md:696-702` (from ``` `docs/` holds the reproduction guides ``` through ``` `coolify-setup.md` → `home-assistant-setup.md`. ```) with:

```markdown
`docs/` holds what you read to **build** the lab, and nothing else. It is split
by what the reader is holding when they open the file:

- **`docs/guides/`** — an instruction to carry out, on the machine its
  `**Runs on:**` line names. Numbered steps, each with verification. One per
  build-order step: `proxmox-setup.md` → `wildcard-dns-udr.md` →
  **`infra-vm-setup.md`** → `traefik-setup.md` → `vaultwarden-setup.md` →
  `authentik-setup.md` → `dockge-setup.md` → `forgejo-setup.md` →
  `grafana-setup.md` → `uptime-kuma-setup.md` → `homepage-setup.md` →
  `backup-setup.md` → **`apps-vm-setup.md`** → `coolify-setup.md` →
  `home-assistant-setup.md`.
- **`docs/reference/`** — a value to look up while carrying out a guide, never
  an instruction. The registries live here.
- **`docs/drills/`** — a procedure to re-run on a schedule against a lab that is
  already built, proving a property still holds. A guide runs once per rebuild;
  a drill runs forever.

**Filenames keep the service name and the `-setup` suffix.** The directory adds
the category; the filename does not repeat it. Renaming would also make prose
ambiguous — `backup.md` would name both the guide and the roadmap file, and
several passages cite the two in one sentence.

`docs/` nests where `scripts/` stays flat, and the reasons are now separate.
`scripts/` is flat because it holds one kind of file. `docs/` had the same
argument until it grew several kinds of document, and nesting costs a `../` only
on links that cross categories — guide→guide links, the majority, stay in one
directory and did not change.
```

- [ ] **Step 3: Fix the registry count**

`CLAUDE.md:726` opens `Three **registries** centralize the manual operations…` and `:733` opens `All three carry…`. Both predate `timetable.md`, which carries the same `— registry, not a build step` header and makes them wrong. Rewrite to durable wording that survives the next registry:

- `Three **registries** centralize the manual operations that live outside the repo:` → `The **registries** in `docs/reference/` centralize the manual operations that live outside the repo:`
- `All three carry `**Runs on:** … — registry, not a build step`, and all three list` → `Every one carries `**Runs on:** … — registry, not a build step`, and every one lists`

Then check the rest of that paragraph for `three`/`all three` referring to the registries and give each the same treatment. Do **not** touch `CLAUDE.md:625`, which counts scrape targets and is unrelated.

- [ ] **Step 4: Rewrite the historical-records paragraph**

Replace `CLAUDE.md:750-758` (from `**Guides describe a from-scratch bring-up…**` through `not retro-edit them when the guides change.`) with:

```markdown
**Guides describe a from-scratch bring-up of the current checkout — always.**
No migration paths, no upgrade branches, no phase history (the roadmap and the
dated specs keep that). A `git pull` anywhere but the initial clone is a red
flag.

**`dev/` is the other half of the split: what you read to understand why the lab
looks like that.** Nothing in it is needed in order to build the lab, and that
is the test for what belongs there.

- `dev/roadmap/` — forward-looking decisions for work not built yet; a piece
  graduates from roadmap to guide when it lands. Live, and edited routinely.
- `dev/specs/` — dated design specs (`YYYY-MM-DD-<topic>-design.md`).
- `dev/plans/` — dated implementation plans (`YYYY-MM-DD-<topic>.md`).
- `dev/reviews/` — dated findings from replaying the guides end to end.

**Write new specs to `dev/specs/` and new plans to `dev/plans/`.** The
superpowers skills default to `docs/superpowers/{specs,plans}/`; this repo
overrides that, and a spec landing in the old path rebuilds a tree that was
deliberately removed.

**`dev/specs/`, `dev/plans/` and `dev/reviews/` are historical records** — do
not retro-edit them when the guides change. `dev/roadmap/` is **not** one of
them. When a path inside a historical record has to change: if the edit changes
which document a reader lands on it is a retro-edit and is forbidden; if it
lands them on the same document at its new address it is a move-repair and is
required. Markdown links are addresses and get repaired; bare paths in their
prose are statements about what was true that day and stay frozen.
```

- [ ] **Step 5: Verify no stale layout claim survives**

```bash
cd /c/Users/felix/Source/home-lab && grep -n 'docs/superpowers\|docs/review/\|docs/roadmap/\|repo root is the machine map\|Three \*\*registries\*\*' CLAUDE.md
```

Expected: no output.

- [ ] **Step 6: Verify links still balance**

```bash
cd /c/Users/felix/Source/home-lab && python "$SCRATCH/check-links.py" . > "$SCRATCH/after3.txt" && diff "$SCRATCH/baseline-normalized.txt" "$SCRATCH/after3.txt" && echo "LINKS IDENTICAL"
```

Expected: `LINKS IDENTICAL`.

- [ ] **Step 7: Commit**

```bash
cd /c/Users/felix/Source/home-lab && git add CLAUDE.md && git commit -m "$(cat <<'EOF'
docs: teach CLAUDE.md the new layout

The docs-layout section described a flat docs/ that no longer exists. It
now states the three-way split and the rule that decides between the
directories, names dev/ and what belongs in it, and records that specs go
to dev/specs and plans to dev/plans -- overriding the skill default, which
would otherwise recreate docs/superpowers.

Also corrects the registry count, which predated timetable.md, to wording
that survives the next registry.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: README.md — the front door

Task 2 already repaired every README link. What remains is the prose: the drill is now its own category and no longer belongs in a table of registries.

**Files:**
- Modify: `README.md:235-256` (the "Registries & catalogs" section)

**Interfaces:**
- Consumes: the tree from Task 2
- Produces: nothing later tasks depend on

- [ ] **Step 1: Remove the drill row from the registries table**

Delete this row from the table under `## Registries & catalogs`:

```
| **[docs/drills/backup-restore-drill.md](docs/drills/backup-restore-drill.md)** | the per-stack restore procedure, and what each stack's result actually proves. A recurring drill — yearly, and whenever a `backup.sh` changes shape |
```

(Task 2 rewrote its path; the row is otherwise as it was.)

- [ ] **Step 2: Make the absences sentence durable**

In the paragraph below the table, replace:

```
**The four registries list their deliberate absences beside their entries**, and
```

with:

```
**The registries list their deliberate absences beside their entries**, and
```

- [ ] **Step 3: Add a Drills section**

Immediately after the `## Registries & catalogs` section and before `## Status`, insert:

```markdown
## Drills

A guide runs once per rebuild. A drill runs forever — a procedure re-run on a
schedule against a lab that is already built, to prove a property still holds.

| Drill | Proves | Cadence |
|---|---|---|
| **[docs/drills/backup-restore-drill.md](docs/drills/backup-restore-drill.md)** | that each stack's snapshot actually restores it — per stack, with a marker that cannot lie | yearly, and whenever a `backup.sh` changes shape |
```

- [ ] **Step 4: Verify the section order and links**

```bash
cd /c/Users/felix/Source/home-lab && grep -n '^## ' README.md
```

Expected order: `Start here`, `Architecture`, `Storage`, `Networking & DNS`, `Build order`, `Registries & catalogs`, `Drills`, `Status`.

```bash
cd /c/Users/felix/Source/home-lab && python "$SCRATCH/check-links.py" . > "$SCRATCH/after4.txt" && diff "$SCRATCH/baseline-normalized.txt" "$SCRATCH/after4.txt" && echo "LINKS IDENTICAL"
```

Expected: `LINKS IDENTICAL`.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/felix/Source/home-lab && git add README.md && git commit -m "$(cat <<'EOF'
docs: give drills their own section in the README

The restore drill was a row in the registries table, which is now the wrong
shape: a registry holds values a guide refuses to repeat, a drill is a
procedure you re-run forever against a lab that already exists.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: STATUS.md and the final sweep

**Files:**
- Modify: `STATUS.md:1-8` (header)

**Interfaces:**
- Consumes: everything above
- Produces: the finished branch

- [ ] **Step 1: Update the STATUS.md header**

Its opening still describes a file inside `docs/`. Replace lines 1–8:

```
# Status

**Runs on:** nothing — status record, not a build step

What is actually running versus what is only written down. The
[build order](../README.md#build-order) says what to do; this says how far it has
got.
```

with:

```
# Status

**Runs on:** nothing — status record, not a build step

What is actually running versus what is only written down. The
[build order](README.md#build-order) says what to do; this says how far it has
got. It sits at the repo root rather than in `docs/` because it is neither an
instruction, a value to look up, nor a procedure — it answers "is this real?"
about the whole lab.
```

Note the link loses its `../` — Task 2 already did that; confirm rather than re-apply it.

- [ ] **Step 2: Confirm the tree is what the spec asked for**

```bash
cd /c/Users/felix/Source/home-lab && ls docs docs/guides docs/reference docs/drills dev dev/roadmap && ls STATUS.md
```

Expected: `docs/` contains exactly `guides`, `reference`, `drills` and nothing else. `docs/guides` has 15 files, `docs/reference` 4, `docs/drills` 1. `dev/` contains exactly `roadmap`, `specs`, `plans`, `reviews`.

- [ ] **Step 3: Confirm no `docs/superpowers` or `docs/review` directory survives**

```bash
cd /c/Users/felix/Source/home-lab && ls docs/superpowers docs/review docs/status.md 2>&1 | head
```

Expected: "No such file or directory" for all three.

- [ ] **Step 4: Verify no live file names an old path — CLAUDE.md now included**

The same grep Task 2 ran with `CLAUDE.md` held back. Task 3 has since rewritten it, so the full sweep must now be clean:

```bash
cd /c/Users/felix/Source/home-lab && grep -rn 'docs/roadmap/\|docs/review/\|docs/superpowers/\|docs/status\.md' README.md CLAUDE.md STATUS.md docs infra apps scripts home-assistant
```

Expected: **no output.**

- [ ] **Step 5: Final full verification**

```bash
cd /c/Users/felix/Source/home-lab && python "$SCRATCH/check-links.py" . > "$SCRATCH/final.txt" && diff "$SCRATCH/baseline-normalized.txt" "$SCRATCH/final.txt" && echo "LINKS IDENTICAL" && python "$SCRATCH/check-anchors.py" . > "$SCRATCH/anchors-final.txt" && diff <(cut -d'#' -f2- "$SCRATCH/anchors-baseline.txt" | sort) <(cut -d'#' -f2- "$SCRATCH/anchors-final.txt" | sort) && echo "ANCHORS IDENTICAL" && git status --porcelain
```

Expected: `LINKS IDENTICAL`, then `ANCHORS IDENTICAL`, then only `STATUS.md` as modified.

Anchors are unchanged by this restructure — no heading was renamed, and Task 4 only *added* one (`## Drills`) — so this confirms rather than repairs. The 4 anchors broken in the baseline stay broken; that is frozen rot, not a regression.

- [ ] **Step 6: Commit**

```bash
cd /c/Users/felix/Source/home-lab && git add STATUS.md && git commit -m "$(cat <<'EOF'
docs: STATUS.md header for its new home at the repo root

Says why it lives beside README rather than in docs/: it is neither an
instruction, a value to look up, nor a procedure.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Review the whole branch**

```bash
cd /c/Users/felix/Source/home-lab && git log --oneline main..HEAD && git diff --stat main..HEAD | tail -3
```

Expected: five commits (the spec, the move, CLAUDE.md, README.md, STATUS.md). The move commit should show ~67 renames.

---

## Notes for the executor

**The plan moves itself.** After Task 2, this file is at `dev/plans/2026-08-16-docs-restructure.md` and the spec is at `dev/specs/2026-08-16-docs-restructure-design.md`. If you are tracking progress by editing checkboxes in this file, reopen it at the new path.

**Do not "fix" the 124 broken links.** They are the baseline. Most are embedded content — markdown a plan intended to write into a guide, which never resolved from the plan's own directory and was never meant to. Two are genuinely dead targets in the frozen tree. Repairing any of them changes the historical record and breaks the verification diff.

**If the diff in Task 2 Step 4 is not empty**, do not patch links by hand. Revert (`git reset --hard HEAD` before the commit), fix the map or the script, and re-run. The whole point of the map-driven approach is that the move is reproducible.
