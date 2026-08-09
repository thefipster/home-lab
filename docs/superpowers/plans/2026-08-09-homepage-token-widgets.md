# Homepage token-backed widgets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Authentik, Forgejo and Grafana tiles on `home.thefipster.de`
live data, which gives the Homepage stack its first `.env` and pulls it into the
restic backup layer.

**Architecture:** Credentials live in `infra/homepage/.env`, are passed into the
container as `HOMEPAGE_VAR_*`, and are substituted into the git-tracked
`config/services.yaml` via `{{HOMEPAGE_VAR_*}}` placeholders — so no secret ever
enters the repo and the read-only config mount is unaffected. All three widgets
dial their backend container directly over the shared `proxy` network, never
through Traefik.

**Tech Stack:** Docker Compose, `ghcr.io/gethomepage/homepage:v1`, bash,
restic + systemd, Markdown.

**Design spec:**
[2026-08-09-homepage-token-widgets-design.md](../specs/2026-08-09-homepage-token-widgets-design.md)

## Global Constraints

- **This repo has no build, lint or test system.** Correctness is verified by
  reading, by three local checks (`bash -n`, a YAML parse, `docker compose
  config`), and finally on the infra VM. There are no unit tests to write; each
  task's verification steps below replace them and are not optional.
- **No migration paths.** The repo is treated as unpublished and describes a
  from-scratch bring-up of the current checkout. Never write an upgrade note, a
  "previously this was…", or a compatibility shim. Edit in place and let the old
  state leave no trace.
- **Delete counts, do not bump them.** No ordinal or total anywhere in this
  change gets incremented. `"the other six"` → `"the others"`; `"naming all
  seven"` → `"naming all"`. Where the *set* is the point rather than its size,
  name the members. Applies to comments in compose files and shell scripts, not
  only Markdown. Full table in the spec.
- **Never write a host IP address.** Machines are addressed by name everywhere.
- **Shell scripts:** `set -euo pipefail`, paths resolved from `$BASH_SOURCE`,
  the shared `run_root()` helper, idempotent and re-runnable.
- **New `.sh` files must be committed mode `100755`.** A file created on Windows
  defaults to `100644` and lands non-executable on the VM. Use
  `git update-index --chmod=+x <path>` and verify with `git ls-files -s`.
- **Line endings are LF**, enforced by `.gitattributes`. Never let an editor
  write CRLF into a `.sh` file — it breaks the shebang.
- **Compose guards are `${VAR:?message}`.** All four new values are required;
  none of them is one of the documented `${VAR:-}` exceptions.
- **Branch:** all work happens on `homepage-token-widgets`. Never commit to
  `main`. Commit after every task.

---

### Task 1: Wire the three widgets

**Files:**
- Create: `infra/homepage/.env.example`
- Modify: `infra/homepage/compose.yaml` (header comment block; `environment:`)
- Modify: `infra/homepage/config/services.yaml` (Authentik, Forgejo, Grafana entries)
- Modify: `scripts/init-homepage.sh` (header comment; seed `.env`; closing message)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the four variable names every later task refers to —
  `HOMEPAGE_VAR_AUTHENTIK_KEY`, `HOMEPAGE_VAR_FORGEJO_KEY`,
  `HOMEPAGE_VAR_GRAFANA_USER`, `HOMEPAGE_VAR_GRAFANA_PASSWORD`. Also produces
  the file `infra/homepage/.env`, which Task 4's `backup.sh` declares.

- [ ] **Step 1: Confirm `.env` is already gitignored**

```bash
git check-ignore -v infra/homepage/.env
```

Expected: a line naming the `.gitignore` rule that matches. If it prints
nothing, stop — a rule must be added before any `.env` can exist, or the first
`git add -A` commits secrets.

- [ ] **Step 2: Create `infra/homepage/.env.example`**

```
# Copy to .env (gitignored) on the infra VM and fill in real values.
# Every value here is minted by hand in the service it belongs to — the
# click-path for each one is docs/homepage-widgets.md.

# Authentik API token. Admin Portal → Directory → Tokens & App passwords,
# Intent: API Token. The owning user needs "Can view User" and "Can view Event".
HOMEPAGE_VAR_AUTHENTIK_KEY=changeme

# Forgejo access token. User Settings → Applications → Generate New Token,
# with the repository, issue and notification read scopes.
HOMEPAGE_VAR_FORGEJO_KEY=changeme

# A dedicated Grafana user with the Viewer role — NOT the admin account, which
# belongs to the monitoring stack and must not be copied into a second .env.
# The widget offers basic auth only; there is no token form.
HOMEPAGE_VAR_GRAFANA_USER=homepage
HOMEPAGE_VAR_GRAFANA_PASSWORD=changeme
```

- [ ] **Step 3: Replace the `.env` paragraph in the `compose.yaml` header**

Find this block near the top of `infra/homepage/compose.yaml`:

```
# NO .env and no .env.example — the second stack in the lab with none, after
# Uptime Kuma. Every widget is token-free (container state from the socket,
# service health from Kuma's status page), so there is no secret to seed. The
# two environment values below are neither secret nor machine-specific.
#
# NO /opt/homepage either, and this is the FIRST stack in the repo with no
# persistent data directory at all: everything Homepage owns is the git-tracked
# YAML in ./config. That is also why it has no backup.sh — see
# docs/roadmap/backup.md.
```

Replace it with:

```
# The .env holds one credential per token-backed widget. They are substituted
# into ./config at runtime as {{HOMEPAGE_VAR_*}}, so the config stays tracked in
# git with no secret in it and the read-only mount below still works. Where each
# credential comes from: docs/homepage-widgets.md.
#
# NO /opt/homepage: this stack has no persistent data directory at all.
# Everything Homepage owns is the git-tracked YAML in ./config plus that .env —
# which is the whole of its backup.sh, and the reason that file has one recipe
# and no dump.
```

- [ ] **Step 4: Add the four variables to `compose.yaml`'s `environment:` block**

Append inside `environment:`, after the existing `LOG_TARGETS: stdout` entry:

```yaml
      # Widget credentials. Homepage replaces {{HOMEPAGE_VAR_XXX}} in any config
      # file with the value of the matching env var, which is what keeps
      # ./config free of secrets under a read-only mount.
      #
      # Fail-fast guards, the repo default — none of these is one of the
      # documented ${VAR:-} exceptions. A guard fires on unset or EMPTY, so an
      # expired token is still a non-empty string and degrades exactly one tile
      # rather than stopping the stack.
      HOMEPAGE_VAR_AUTHENTIK_KEY: ${HOMEPAGE_VAR_AUTHENTIK_KEY:?set it in .env — see docs/homepage-widgets.md}
      HOMEPAGE_VAR_FORGEJO_KEY: ${HOMEPAGE_VAR_FORGEJO_KEY:?set it in .env — see docs/homepage-widgets.md}
      HOMEPAGE_VAR_GRAFANA_USER: ${HOMEPAGE_VAR_GRAFANA_USER:?set it in .env — see docs/homepage-widgets.md}
      HOMEPAGE_VAR_GRAFANA_PASSWORD: ${HOMEPAGE_VAR_GRAFANA_PASSWORD:?set it in .env — see docs/homepage-widgets.md}
```

- [ ] **Step 5: Remove the remaining ordinals from `compose.yaml`**

Three comment edits, per the Global Constraints rule:

| Find | Replace with |
|---|---|
| `# boot loop rather than a warning. All NINE skeleton files ship in` | `# boot loop rather than a warning. Every file Homepage looks for ships in` |
| `# ./config for exactly that reason; four of them are stubs.` | `# ./config for exactly that reason; several are stubs.` |
| `# Container discovery and state for this VM's stacks. The SIXTH socket` | `# Container discovery and state for this VM's stacks. One of several socket` |
| `# mount in the lab, after Dockge, the Forgejo runner, Traefik, Alloy and` | `# mounts in the lab, and it carries the same caveat as the others: `:ro`` |
| `# Uptime Kuma, and it carries the same caveat: `:ro` makes the MOUNT` | `# makes the MOUNT` |

Read the surrounding lines and join them into clean prose rather than applying
these mechanically — the result must read as if written that way.

- [ ] **Step 6: Add the three `widget:` blocks to `config/services.yaml`**

Under the existing `Authentik:` entry, after its `container:` line:

```yaml
        # Container-to-container over `proxy`, exactly like the Kuma widget
        # below — never through Traefik. A round trip through the proxy would be
        # a TLS hop back into this VM, and for a forward-auth gated host it
        # would authenticate against Authentik instead of the service.
        # `authentik-server` is an explicit network alias, declared in
        # infra/authentik/compose.yaml.
        #
        # version: 2 is required from Authentik 2025.8.0 onward; the lab pins
        # 2026.5. On version 1 the tile renders blank rather than erroring.
        widget:
          type: authentik
          url: http://authentik-server:9000
          key: "{{HOMEPAGE_VAR_AUTHENTIK_KEY}}"
          version: 2
```

Under the existing `Forgejo:` entry, after its `container:` line:

```yaml
        # `gitea`, not `forgejo` — upstream ships no Forgejo widget and the
        # Forgejo API is Gitea-compatible. Alloy already scrapes this exact
        # address over `proxy`, so the path is proven.
        widget:
          type: gitea
          url: http://forgejo:3000
          key: "{{HOMEPAGE_VAR_FORGEJO_KEY}}"
```

Under the existing `Grafana:` entry, after its `container:` line:

```yaml
        # Basic auth: this widget has no token form at all. The user is a
        # DEDICATED Grafana account with the Viewer role, not the monitoring
        # stack's admin — copying that credential here would put it in a second
        # .env and a second snapshot, and rotating it in one place would
        # silently break the other.
        #
        # version: 2 is required above Grafana v10.4; the lab pins 13.1.
        widget:
          type: grafana
          url: http://grafana:3000
          username: "{{HOMEPAGE_VAR_GRAFANA_USER}}"
          password: "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}"
          version: 2
```

**The quotes around every `{{...}}` are mandatory, not style.** In YAML a bare
`{` opens a flow mapping, so `key: {{HOMEPAGE_VAR_AUTHENTIK_KEY}}` is a parse
error and the container exits on boot.

- [ ] **Step 7: Teach `scripts/init-homepage.sh` to seed `.env`**

Replace the header paragraph:

```
# That is the whole script, and it is the thinnest one here. There is NO .env
# and nothing to generate — every widget is token-free — and there is NO
# /opt/homepage, because this stack has no persistent state at all: its entire
# configuration is the git-tracked YAML in infra/homepage/config, bind-mounted
# read-only. It is the only stack in the repo with no data directory, which is
# also why it has no backup.sh.
```

with:

```
# Nothing is GENERATED here: every value in .env is a credential minted by hand
# in the service it belongs to, so the script seeds the file from .env.example
# and leaves it to you. The click-path for each one is docs/homepage-widgets.md.
#
# There is NO /opt/homepage — this stack keeps no persistent state of its own.
# Its configuration is the git-tracked YAML in infra/homepage/config, bind-
# mounted read-only, and its .env is the only thing its backup.sh declares.
```

Also change the numbered step list at the top from two steps to three, inserting
`#   2. Seed infra/homepage/.env from .env.example if missing (you fill it in).`
and renumbering the symlink step.

- [ ] **Step 8: Add the seeding block to the script body**

Insert between the `proxy` network block and the `STACKS_DIR` block, matching
`scripts/init-traefik.sh`'s shape exactly:

```bash
if [ ! -f "${STACK_DIR}/.env" ]; then
  echo "==> Seeding ${STACK_DIR}/.env from .env.example — FILL IN REAL VALUES"
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
fi
```

- [ ] **Step 9: Update the script's closing message**

Replace the closing heredoc body with:

```
Done. Next:
  1. Mint the four credentials and put them in ${STACK_DIR}/.env —
     docs/homepage-widgets.md has the click-path for each.
  2. cd ${STACK_DIR} && docker compose up -d

Then https://home.thefipster.de — Authentik will ask you to log in first.
Guide: docs/homepage-setup.md
```

- [ ] **Step 10: Verify the guards fire with no `.env`**

```bash
cd infra/homepage && docker compose config --quiet
```

Expected: **FAIL**, with a message naming `HOMEPAGE_VAR_AUTHENTIK_KEY` and the
`set it in .env` text. A pass here means a guard is missing or misspelled.

- [ ] **Step 11: Verify it passes with a filled `.env`**

```bash
cd infra/homepage && cp .env.example .env && docker compose config --quiet && echo PASS && rm .env
```

Expected: `PASS`. The `rm` matters — a `.env` full of `changeme` left in the
checkout is a confusing thing to find on the VM later.

- [ ] **Step 12: Verify the YAML and the shell**

```bash
python -c "import yaml; [yaml.safe_load(open(f)) for f in ['infra/homepage/config/services.yaml','infra/homepage/config/settings.yaml']]; print('yaml OK')"
```

```bash
bash -n scripts/init-homepage.sh && echo "shell OK"
```

Both must print their OK line. A YAML failure here is almost certainly an
unquoted `{{`.

- [ ] **Step 13: Verify every placeholder has a matching variable**

```bash
grep -oh "HOMEPAGE_VAR_[A-Z_]*" infra/homepage/config/services.yaml infra/homepage/compose.yaml infra/homepage/.env.example | sort -u
```

Expected: exactly four names, each appearing in all three files. A name in
`services.yaml` with no compose entry renders the literal `{{...}}` string into
the widget and fails with no useful error.

- [ ] **Step 14: Commit**

```bash
git add infra/homepage/.env.example infra/homepage/compose.yaml infra/homepage/config/services.yaml scripts/init-homepage.sh
git commit -m "Homepage: token-backed Authentik, Forgejo and Grafana widgets"
```

---

### Task 2: The widget registry

**Files:**
- Create: `docs/homepage-widgets.md`

**Interfaces:**
- Consumes: the four variable names from Task 1.
- Produces: the anchors Task 3's guide links to — `#authentik`, `#forgejo`,
  `#grafana`, and `#deliberate-absences`.

- [ ] **Step 1: Write the registry**

Follow the structure of `docs/uptime-kuma-monitors.md` — read it first. The file
must open with:

```markdown
# Homepage widgets (registry)

**Runs on:** the services being read, not Homepage — registry, not a build step
```

then a paragraph saying every credential here is minted by hand in the service
it belongs to, that Homepage itself is provisioned entirely from the checkout,
and that the click-path is what this file records. Link
[homepage-setup.md](homepage-setup.md) for the bring-up, and state the same
convention line the other registries carry: **when a new service arrives, add
its row here first**, cross-linking `dns-records.md`,
`sso-applications.md` and `uptime-kuma-monitors.md`.

- [ ] **Step 2: Write the shared mechanism section**

One section, before the per-widget ones, stating:

- The value of `HOMEPAGE_VAR_XXX` replaces `{{HOMEPAGE_VAR_XXX}}` in any config
  file, so credentials live in `infra/homepage/.env` and the config stays in git.
- The `{{...}}` **must be quoted** in YAML or the container will not boot.
- Every widget dials its backend over the `proxy` network, never through
  Traefik — with the two-line reason (TLS hop; forward-auth would answer
  instead of the service).
- All four values carry `${VAR:?}` guards, so a missing one stops the stack
  while an expired one degrades a single tile.

- [ ] **Step 3: Write the three per-widget sections**

Each section states the exact facts below. Do not paraphrase the scopes.

**`## Authentik`**

| Field | Value |
|---|---|
| Widget type | `authentik` |
| URL | `http://authentik-server:9000` |
| `.env` variable | `HOMEPAGE_VAR_AUTHENTIK_KEY` |
| Where to mint | Admin Portal → Directory → Tokens & App passwords → Create, **Intent: API Token** |
| Permissions on the owning user | authentik Core → *Can view User*; authentik Events → *Can view Event* |
| Shows | users, logins last 24h, failed logins last 24h |

Note that `version: 2` is set in `services.yaml` and is required from Authentik
2025.8.0; the lab pins `2026.5`. Note also that an API token is **not** an
Authentik *application*, so this adds no row to `sso-applications.md` —
Homepage's entry there stays the forward-auth one.

**`## Forgejo`**

| Field | Value |
|---|---|
| Widget type | `gitea` — upstream ships no Forgejo widget |
| URL | `http://forgejo:3000` |
| `.env` variable | `HOMEPAGE_VAR_FORGEJO_KEY` |
| Where to mint | User Settings → Applications → Generate New Token |
| Scopes | repository, issue and notification **read** |
| Shows | repositories, notifications, issues, pulls |

State plainly that upstream documents this widget for Gitea and never mentions
Forgejo; the API is Gitea-compatible and this works, but a future Forgejo major
could break it in a way no other widget can.

**`## Grafana`**

| Field | Value |
|---|---|
| Widget type | `grafana` |
| URL | `http://grafana:3000` |
| `.env` variables | `HOMEPAGE_VAR_GRAFANA_USER`, `HOMEPAGE_VAR_GRAFANA_PASSWORD` |
| Where to mint | Grafana → Administration → Users and access → Users → New user |
| Role | Viewer |
| Shows | dashboards, datasources, total alerts, alerts triggered |

State that this widget has **no token form** — basic auth only — and that the
account is deliberately a dedicated Viewer rather than the monitoring stack's
admin, because that credential would then live in two `.env` files and two
snapshots.

**Leave the role line marked as pending until Task 7 settles it**, using this
exact sentence so it is obvious it is unresolved:

> **Unverified until the first bring-up:** the `datasources` figure reads
> `/api/datasources`, which Grafana restricts to admins. If a Viewer account
> blanks the whole tile rather than that one number, the fix is to scope the
> widget with `fields: [dashboards, alertstriggered]` — not to raise the role.

- [ ] **Step 4: Write the deliberate-absences section**

`## Deliberate absences` — the registry convention. One entry each:

- **Proxmox** — a widget exists, and it is not used. Its API is HTTPS-only on
  `:8006` behind a self-signed certificate, and Homepage is Node. The two fixes
  both cost more than the widget: `NODE_EXTRA_CA_CERTS` means copying
  `/etc/pve/pve-root-ca.pem` off the hypervisor and reintroducing a
  `/opt/homepage` directory, and `NODE_TLS_REJECT_UNAUTHORIZED=0` disables
  certificate verification for every outbound request Homepage makes. Host CPU
  and memory are on Grafana's Node Exporter Full dashboard already; only the
  VM/LXC counts are lost.
- **The Traefik dashboard** — a widget exists. Its router is forward-auth
  gated, so a widget would report on Authentik rather than Traefik. Same
  reasoning as the missing `Gateway Web` monitor in
  `uptime-kuma-monitors.md`; link it.
- **Vaultwarden, Dockge and Coolify** — no upstream widget exists. State this
  as a fact about upstream, not about the lab, so it does not read as a
  decision that could be revisited by trying harder.
- **Home Assistant and the apps-VM applications** — widgets exist, and those
  machines are not built. Link `status.md`. This absence expires; the others do
  not, and the file should say so.
- **Uptime Kuma** — already has a widget and needs **no credential**: it reads
  the public `homelab` status page. Cross-link
  `uptime-kuma-monitors.md#the-homelab-status-page`.

- [ ] **Step 5: Verify the links resolve**

```bash
grep -o "](\.\?[a-z0-9./-]*\.md[^)]*)" docs/homepage-widgets.md | tr -d '](' | cut -d'#' -f1 | sort -u | while read -r f; do [ -f "docs/$f" ] || echo "BROKEN: $f"; done; echo "link check done"
```

Expected: `link check done` with no `BROKEN:` lines.

- [ ] **Step 6: Verify no count phrasing crept in**

```bash
grep -niE "\b(second|third|fourth|fifth|sixth|seventh|the only stack|all (three|four|five|six|seven))\b" docs/homepage-widgets.md
```

Expected: no output. If a line matches, reword it per the Global Constraints
rule.

- [ ] **Step 7: Commit**

```bash
git add docs/homepage-widgets.md
git commit -m "Homepage: a registry for the widget credentials"
```

---

### Task 3: Update the Homepage guide

**Files:**
- Modify: `docs/homepage-setup.md`

**Interfaces:**
- Consumes: the `.env` variable names (Task 1) and the registry anchors (Task 2).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Fix the intro**

The third paragraph currently says *"There is no database, no `.env`, and no
data directory on the server — this is the one stack where the checkout is not
merely the source of truth but the whole of it."* Rewrite it to say the
configuration is the tracked YAML, that the `.env` holds one credential per
token-backed widget, and that no secret is in the checkout.

- [ ] **Step 2: Insert a credential step before the start step**

New step between the current step 3 (*Run the init script*) and step 4 (*Start
the stack*), numbered 4 with everything after it renumbered. It must:

- Say the init script has seeded `.env` from `.env.example` with `changeme`
  placeholders, and that the stack will refuse to start until they are real —
  by design, so a half-configured page never loads.
- Link [homepage-widgets.md](homepage-widgets.md) as the click-path for all
  four values, and **not restate any of them**. This is the registry
  convention: per-service values never appear inline in a guide.
- Note the Grafana user is created in Grafana, not Authentik, and is a Viewer.
- Give the edit command in its own fenced block:

```bash
nano ~/home-lab/infra/homepage/.env
```

- [ ] **Step 3: Extend the verification step**

The current step 5 (*Log in and check the page*) verifies three things. Add a
fourth: the Authentik, Forgejo and Grafana tiles show figures rather than only a
status dot, and a blank tile means the credential is wrong or the account lacks
a permission — with the registry linked for what each one needs.

- [ ] **Step 4: Update the checklist**

Add these rows, keeping the existing ones:

```markdown
- [ ] `infra/homepage/.env` holds four real values, no `changeme` left
- [ ] `docker compose up -d` starts the stack — a guard failure means a value is
      still empty
- [ ] The Authentik, Forgejo and Grafana tiles show figures, not just a dot
```

Reword the existing row `- [ ] All seven infra-VM tiles show container state` to
drop the count: `- [ ] Every infra-VM tile shows container state`.

- [ ] **Step 5: Add three troubleshooting entries**

In the existing `## Troubleshooting` section, in its existing bolded-symptom
style:

- **The stack refuses to start and compose names a `HOMEPAGE_VAR_*` variable.**
  That is the guard working — the value is missing or still `changeme`. Point
  at the registry.
- **One tile shows a dot but no figures.** That widget's credential is wrong,
  expired, or its account lacks a permission. The others are unaffected because
  each widget authenticates separately. Give:

```bash
docker compose logs homepage | grep -i -E "widget|401|403"
```

- **The container exits with a YAML parse error naming `services.yaml`.** A
  `{{HOMEPAGE_VAR_...}}` placeholder lost its quotes; `{` opens a flow mapping
  in YAML.

- [ ] **Step 6: Update the layout-on-server block**

Add `.env` and `.env.example` to the tree listing, and delete the closing
sentence **There is no `/opt/homepage`.** … only if it has become wrong — it has
not, so keep it and leave it as it stands.

- [ ] **Step 7: Invert the design note**

Replace the whole **Why there are no token-backed widgets** note. The new note
is **Which services have a widget, and which do not** — it says three tiles
carry live data, that this is what gave the stack its `.env` and its backup, and
that the services with no widget are listed with reasons in the registry rather
than here. Keep it short; the registry holds the detail.

- [ ] **Step 8: Fix the "no backup" design note**

The note **Why it has no backup** is now wrong. Replace it with **What its
backup contains** — the `.env` and nothing else, because every other byte is
tracked in git. Link `roadmap/backup.md`.

- [ ] **Step 9: Fix the prerequisite line in the `## Next` sections**

Both `## Next` blocks say Homepage *"is the one stack that gets none"* of the
backups. Remove that clause from both.

- [ ] **Step 10: Verify**

```bash
grep -niE "no \.env|token-free|gets none|the one stack that" docs/homepage-setup.md
```

Expected: no output. Any hit is a surviving claim that Homepage has no `.env` or
no backup.

- [ ] **Step 11: Commit**

```bash
git add docs/homepage-setup.md
git commit -m "Homepage guide: mint the widget credentials before starting"
```

---

### Task 4: Wire Homepage into the backup layer

**Files:**
- Create: `infra/homepage/backup.sh` (mode 100755)
- Create: `infra/homepage/restore.sh` (mode 100755)
- Modify: `infra/backup/run.sh` (one comment)

**Interfaces:**
- Consumes: `infra/homepage/.env` from Task 1; `include_env` from
  `infra/backup/lib.sh`.
- Produces: a restic snapshot tagged `homepage`, which Task 5's docs describe.

- [ ] **Step 1: Read the model scripts first**

```bash
cat infra/traefik/backup.sh infra/traefik/restore.sh
```

Traefik's pair is the closest model: no database, an `include_env`, and a
restore whose only real proof is not the stack coming up. Homepage's is that
shape with the `/opt` tree removed.

- [ ] **Step 2: Write `infra/homepage/backup.sh`**

```bash
#!/usr/bin/env bash
#
# backup.sh — what Homepage's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/homepage/backup.sh
#
# One recipe and no dump, which is the whole story of this stack: there is no
# database, no /opt directory, and the entire configuration — the compose and
# every file under config/ — is tracked in this repo. Snapshotting any of that
# would be snapshotting a clone.
#
# What is NOT in the clone is the .env, and it is not regenerable either: every
# value in it is a credential minted by hand in another service. Losing it does
# not lose data, but it does mean clicking through docs/homepage-widgets.md
# again in Authentik, Forgejo and Grafana.

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/homepage is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# The four HOMEPAGE_VAR_* widget credentials. include_env resolves against
# $REPO_ROOT rather than /opt/stacks, because restic stores a symlink as a
# symlink instead of descending into it.
include_env
```

- [ ] **Step 3: Write `infra/homepage/restore.sh`**

```bash
#!/usr/bin/env bash
#
# restore.sh — put Homepage's widget credentials back from a restic snapshot.
#
# Usage:  sudo infra/homepage/restore.sh [snapshot-id]     (default: latest)
#
# The shortest restore in the lab: one file, no database, and no /opt tree to
# move aside because this stack has none.
#
# THE TRAP HERE IS THE SAME ONE TRAEFIK HAS. Homepage comes back looking
# perfectly healthy whether or not this restore worked — the page renders, every
# tile is there, and container state is live — because none of that came from
# the snapshot. The only thing this restore delivers is the four widget
# credentials, so the only check that means anything is whether the Authentik,
# Forgejo and Grafana tiles show FIGURES.

set -euo pipefail

STACK="homepage"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGE="/opt/backup/restore/${STACK}"
SNAPSHOT="${1:-latest}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run this as root — it reads /opt/backup and the restic repository." >&2
  exit 1
fi

BACKED_UP_TO=""

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$BACKED_UP_TO" ]; then
    echo >&2
    echo "!! This restore FAILED after moving the old .env aside." >&2
    echo "!! It is at ${BACKED_UP_TO} and was not deleted. Put it back with:" >&2
    echo "!!   mv ${BACKED_UP_TO} ${REPO_ROOT}/infra/${STACK}/.env" >&2
    echo "!! Then start the stack: cd ${REPO_ROOT}/infra/${STACK} && docker compose up -d" >&2
  fi
}
trap on_exit EXIT

set -a
# shellcheck source=/dev/null
. "${REPO_ROOT}/infra/backup/.env"
set +a

# ---- 1. Resolve the snapshot and show it -----------------------------------

echo "==> Snapshots tagged ${STACK}:"
restic snapshots --tag "$STACK" --compact

if [ "$SNAPSHOT" = "latest" ]; then
  id="$(restic snapshots --tag "$STACK" --latest 1 --json \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4)"
else
  id="$SNAPSHOT"
fi

if [ -z "$id" ]; then
  echo "no snapshot '${SNAPSHOT}' tagged ${STACK} found." >&2
  exit 1
fi

echo
echo "About to restore ${STACK} from snapshot ${id}."
echo "This stops the stack and REPLACES ${REPO_ROOT}/infra/${STACK}/.env."
echo
echo "NOTE: while Homepage is down nothing else is affected — it is a page of"
echo "links and no other stack depends on it."
echo
read -r -p "Type '${STACK}' to continue: " answer
if [ "$answer" != "$STACK" ]; then
  echo "aborted."
  exit 1
fi

# ---- 2. Stop the stack -----------------------------------------------------

echo "==> Stopping ${STACK}"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose down )

# ---- 3. Restore into staging, before touching anything live ----------------

echo "==> Restoring snapshot ${id} into ${STAGE}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
restic restore "$id" --target "$STAGE"

# ---- 4. Check the staged file BEFORE touching anything live ----------------

staged_env="${STAGE}${REPO_ROOT}/infra/${STACK}/.env"

if [ ! -s "$staged_env" ]; then
  echo "  ! the snapshot's .env is missing or EMPTY: ${staged_env}" >&2
  echo >&2
  echo "Aborting BEFORE anything was moved — the checkout is untouched and the" >&2
  echo "stack is only stopped. Bring it back up with:" >&2
  echo "  cd ${REPO_ROOT}/infra/${STACK} && docker compose up -d" >&2
  echo >&2
  echo "Then look at what the snapshot does contain:" >&2
  echo "  ls -R ${STAGE}" >&2
  exit 1
fi

# A .env full of .env.example's placeholders restores "successfully" and then
# fails every widget with a 401, which looks like a credential problem rather
# than a bad backup. Catch it here, while the old file is still in place.
if grep -q '=changeme$' "$staged_env"; then
  echo "  ! the snapshot's .env still holds 'changeme' placeholders." >&2
  echo "    It was snapshotted before the credentials were filled in." >&2
  echo "    Restoring it would replace working credentials with placeholders." >&2
  echo >&2
  echo "Aborting BEFORE anything was moved. Pick an older or newer snapshot:" >&2
  echo "  restic snapshots --tag ${STACK}" >&2
  exit 1
fi

# ---- 5. Move the old .env aside — never delete it --------------------------

ts="$(date +%Y%m%d-%H%M%S)"
live_env="${REPO_ROOT}/infra/${STACK}/.env"
if [ -f "$live_env" ]; then
  echo "==> Moving ${live_env} to ${live_env}.bak-${ts}"
  mv "$live_env" "${live_env}.bak-${ts}"
  BACKED_UP_TO="${live_env}.bak-${ts}"
fi

# ---- 6. Put it back --------------------------------------------------------

echo "==> Restoring ${live_env}"
cp -a "$staged_env" "$live_env"

# ---- 7. Bring it up --------------------------------------------------------

echo "==> Starting ${STACK}"
( cd "${REPO_ROOT}/infra/${STACK}" && docker compose up -d )

cat <<EOF

Done. Verify — and note that only the FIRST check tests this restore at all:

  1. The Authentik, Forgejo and Grafana tiles show FIGURES, not just a status
     dot. That is the only thing that came out of the snapshot.

       https://home.thefipster.de

  2. The stack started at all. A guard failure here means the restored .env is
     missing a variable that compose.yaml requires:

       cd ${REPO_ROOT}/infra/${STACK} && docker compose ps

  3. Everything else — the page, the links, container state on every tile —
     would look exactly like this even if the restore had done nothing, because
     it all comes from the checkout rather than the backup.

Two things are left behind on purpose. Delete them once the checks pass:

  the previous .env
    sudo rm -f ${BACKED_UP_TO:-${live_env}.bak-${ts}}

  the staging copy of the snapshot
    sudo rm -rf ${STAGE}
EOF
```

- [ ] **Step 4: Fix the count in `infra/backup/run.sh`**

| Find | Replace with |
|---|---|
| `# NOT `set -e`. One stack failing must not cost the other six their snapshots —` | `# NOT `set -e`. One stack failing must not cost the others their snapshots —` |

No other change to `run.sh`. Its `infra/*/backup.sh` glob picks the new stack up
on its own; **verify that rather than assuming it** in step 6.

- [ ] **Step 5: Make both scripts executable and check their syntax**

```bash
git add infra/homepage/backup.sh infra/homepage/restore.sh && git update-index --chmod=+x infra/homepage/backup.sh infra/homepage/restore.sh
```

```bash
bash -n infra/homepage/backup.sh && bash -n infra/homepage/restore.sh && echo "shell OK"
```

```bash
git ls-files -s infra/homepage/backup.sh infra/homepage/restore.sh
```

Expected: both lines start `100755`. `100644` means the VM will refuse to run
them and `run.sh` will record the stack as failed with *"is missing or not
executable"*.

- [ ] **Step 6: Verify the runner discovers the stack**

```bash
for f in infra/*/backup.sh; do basename "$(dirname "$f")"; done
```

Expected: the stack list now includes `homepage`, alphabetically between
`forgejo` and `monitoring`. This is the same glob `run.sh` uses, so a `homepage`
line here is proof the runner needs no edit.

- [ ] **Step 7: Verify `backup.sh` declares the right path**

```bash
mkdir -p /tmp/hbk && BACKUP_STAGE=/tmp/hbk REPO_ROOT="$PWD" bash infra/homepage/backup.sh; cat /tmp/hbk/paths.txt; rm -rf /tmp/hbk
```

Expected: it **fails** with `! include: …/infra/homepage/.env does not exist`,
because there is no `.env` in the checkout on this machine. That failure is the
correct behaviour and proves `include_env` resolved against `$REPO_ROOT` rather
than `/opt/stacks`. To see it succeed, create a throwaway `.env` first and delete
it after.

- [ ] **Step 8: Commit**

```bash
git add infra/homepage/backup.sh infra/homepage/restore.sh infra/backup/run.sh
git commit -m "Homepage joins the backup layer: its .env, and nothing else"
```

---

### Task 5: Update the backup documentation

**Files:**
- Modify: `docs/backup-setup.md`
- Modify: `docs/backup-restore-drill.md`
- Modify: `docs/roadmap/backup.md`
- Modify: `docs/status.md`
- Modify: `docs/timetable.md`
- Modify: `infra/authentik/backup.sh` (one comment)

**Interfaces:**
- Consumes: the `homepage` snapshot tag from Task 4.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: `backup-setup.md` — the stack list and its count**

| Find | Replace with |
|---|---|
| `Expect a `staging` / `snapshot` pair per wired stack — `authentik`,`<br>`dockge`, `forgejo`, `monitoring`, `traefik`, `uptime-kuma` and `vaultwarden`,`<br>`in that order, since the runner globs them alphabetically — then`<br>``==> forget + prune`, then a final `OK:` line naming all seven.` | the same sentence with `homepage` inserted between `forgejo` and `monitoring`, and ending `…then `==> forget + prune`, then a final `OK:` line naming all of them.` |

Two lines further down, *"`pg_dump` in the `db` service for the four Postgres
stacks"* and *"Traefik and Dockge have no database, so their staging step only
declares paths"* both need Homepage folding in: it has no database either.
Reword to name the stacks rather than count them.

- [ ] **Step 2: `backup-setup.md` — the Homepage exception paragraph**

| Find | Replace with |
|---|---|
| `**Homepage is the one stack with neither file** — it has no `/opt``<br>`directory and no `.env`, so a snapshot of it would be a snapshot of a git`<br>`checkout ([homepage-setup.md](homepage-setup.md#design-notes)).` | a sentence saying **every** stack has both files, and that Homepage's is the smallest — its `.env` and nothing else, because the rest of the stack is tracked in git. |

- [ ] **Step 3: `backup-setup.md` — the checklist**

| Find | Replace with |
|---|---|
| `- [ ] `sudo infra/backup/run.sh` ends in an `OK:` line naming all seven stacks` | `- [ ] `sudo infra/backup/run.sh` ends in an `OK:` line naming all the stacks` |
| `- [ ] `restic snapshots` lists one snapshot per tag — seven in all` | `- [ ] `restic snapshots` lists one snapshot per tag` |

- [ ] **Step 4: `backup-restore-drill.md` — add the row**

Add to the *Per stack* table, alphabetically between **forgejo** and
**monitoring**:

```markdown
| **homepage** | Break one credential in `.env` — change a character in `HOMEPAGE_VAR_AUTHENTIK_KEY` | The Authentik tile shows figures again. Nothing else on the page proves anything: it all comes from the checkout |
```

- [ ] **Step 5: `backup-restore-drill.md` — add the prose section**

The table is followed by one `###` section per stack. Add `### homepage` in the
same position, saying:

- The marker is deliberately a credential rather than a config change, because a
  config change is tracked in git and would come back whether the restore worked
  or not.
- This is the same trap Traefik's drill has, and the section should link it: the
  stack looks perfectly healthy either way.
- The tile showing figures again proves the restored `.env` is the backup's
  `.env`.

- [ ] **Step 6: `roadmap/backup.md` — move Homepage out of the not-backed-up list**

Delete this bullet from the tier-3 / not-backed-up list:

```
- **The Homepage stack** — `infra/homepage/` and nothing else. It has no `/opt`
  directory and no `.env`; its compose and all nine config files are tracked in
  this repo. It is the only stack with no `backup.sh` and no `restore.sh`, and
  the reason is the bullet above: backing it up would be backing up a clone.
```

Replace it with a bullet covering what is *still* not backed up about Homepage —
`infra/homepage/config/` and the compose, because they are tracked in git — and
add `homepage` to the tier-1 `.env` row, since its `.env` is now part of the
backup set.

- [ ] **Step 7: `roadmap/backup.md` — the drill count**

| Find | Replace with |
|---|---|
| `5. **Prove it.** ⚠️ **Partly done — all seven stacks drilled**, recorded in` | `5. **Prove it.** ⚠️ **Partly done — every stack drilled**, recorded in` |

Homepage's own drill has not happened yet at this point in the plan; Task 7
records it. Do not claim it has.

- [ ] **Step 8: `status.md` — the backup row**

| Find | Replace with |
|---|---|
| `All seven stateful infra stacks wired and restore-drilled, one tagged snapshot each` | `Every stateful infra stack wired and restore-drilled, one tagged snapshot each` |

- [ ] **Step 9: Verify no stack-count phrasing survives**

```bash
grep -rniE "(all|the other) (six|seven|eight)\b|seven in all|seven stacks|seven stateful" docs/ infra/ scripts/ CLAUDE.md --include="*.md" --include="*.sh" --include="*.yaml" | grep -v "docs/superpowers/" | grep -v "docs/review/"
```

This runs **before** the last two edits, so it is a worklist rather than a pass.
Expected output is exactly two lines, both handled in steps 11 and 12:

```
docs/timetable.md:...  restic file-level backup of all seven stacks ...
infra/authentik/backup.sh:16:# ORDER MATTERS, AND THIS IS THE TEMPLATE THE OTHER SIX STACKS COPY.
```

Anything **else** is a stack count that survived steps 1–8 — go back and fix it
before continuing.

- [ ] **Step 10: Confirm the two exempt cases are still intact**

```bash
grep -rn "seven dailies" docs/ CLAUDE.md | grep -v "docs/superpowers/"
```

Expected: exactly two hits, `docs/backup-setup.md` and `CLAUDE.md` — the same as
before this task. That phrase is `--keep-daily 7`, where the number *is* the
policy.

```bash
grep -n "other six drives\|all eight drives" docs/proxmox-setup.md
```

Expected: both lines, unchanged. `docs/proxmox-setup.md` is the canonical
statement of the hardware design and those numbers count **drives** — the rule
exempts hardware inventory. Do not "fix" them.

- [ ] **Step 11: `timetable.md` — the nightly backup row**

| Find | Replace with |
|---|---|
| `` `restic` file-level backup of all seven stacks, then `forget --prune` `` | `` `restic` file-level backup of every wired stack, then `forget --prune` `` |

Leave `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` in the same cell exactly
as it is, for the reason in step 10.

- [ ] **Step 12: `infra/authentik/backup.sh` — the template comment**

This is the only stack script other than Homepage's that this change touches,
and it is touched for one word.

| Find | Replace with |
|---|---|
| `# ORDER MATTERS, AND THIS IS THE TEMPLATE THE OTHER SIX STACKS COPY.` | `# ORDER MATTERS, AND THIS IS THE TEMPLATE THE OTHER STACKS COPY.` |

```bash
bash -n infra/authentik/backup.sh && echo "shell OK"
```

- [ ] **Step 13: Re-run the sweep, now expecting it clean**

```bash
grep -rniE "(all|the other) (six|seven|eight)\b|seven in all|seven stacks|seven stateful" docs/ infra/ scripts/ CLAUDE.md --include="*.md" --include="*.sh" --include="*.yaml" | grep -vE "docs/(superpowers|review)/|docs/proxmox-setup\.md"
```

Expected: no output.

- [ ] **Step 14: Commit**

```bash
git add docs/backup-setup.md docs/backup-restore-drill.md docs/roadmap/backup.md docs/status.md docs/timetable.md infra/authentik/backup.sh
git commit -m "Backup docs: Homepage is wired, and the stack counts come out"
```

---

### Task 6: Reconcile CLAUDE.md and the Kuma init script

**Files:**
- Modify: `CLAUDE.md`
- Modify: `scripts/init-uptime-kuma.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: nothing later tasks depend on.

This task is the repo's own description catching up with what Tasks 1–5 changed.
Nothing here is optional: CLAUDE.md is the file the next session reads first, and
a stale claim in it is worse than a stale claim in a guide.

- [ ] **Step 1: `CLAUDE.md` — the backup convention**

| Find | Replace with |
|---|---|
| `**Every stack that holds state is wired** — Authentik, Dockge, Forgejo,`<br>`monitoring, Traefik, Uptime Kuma and Vaultwarden — so every tier-1 and tier-2`<br>`row in `docs/roadmap/backup.md` has a `backup.sh` and a `restore.sh` beside its`<br>`compose file. **Homepage is the one stack with neither, deliberately**: it has`<br>`no `/opt` directory and no `.env`, so every byte it owns is already in this`<br>`repo and a snapshot of it would be a snapshot of a checkout.` | The same opening sentence with **Homepage** added to the list, then: **Homepage's is the smallest** — `include_env` and nothing else, because its compose and its whole `config/` tree are tracked in this repo. Its `.env` is the only thing a checkout does not already carry, and it is not regenerable: every value is a credential minted by hand in another service. |

- [ ] **Step 2: `CLAUDE.md` — the `.env` gotcha**

| Find | Replace with |
|---|---|
| `script, so it ships none; Uptime Kuma and Homepage have no `.env` at all).` | `script, so it ships none; Uptime Kuma has no `.env` at all).` |

- [ ] **Step 3: `CLAUDE.md` — the Uptime Kuma init entry**

| Find | Replace with |
|---|---|
| `stack. One of two stacks with **no `.env` and no `.env.example`** (Homepage`<br>`is the other): Kuma has no`<br>`database and creates its admin through its own first-run web form, so there`<br>`is nothing to seed.` | `stack. It has **no `.env` and no `.env.example`**: Kuma has no database and creates its admin through its own first-run web form, so there is nothing to seed.` |

Also reword the closing clause *"Only Homepage comes after, and it watches
nothing"* — it is still true and carries no count, so leave it.

- [ ] **Step 4: `CLAUDE.md` — the Homepage init entry**

Rewrite entry 11 of the deploy-order list. It must now say:

- The script ensures the `proxy` network, seeds `.env` from `.env.example`, and
  symlinks the stack. Drop **The thinnest init script here**.
- Homepage has **no `/opt/<stack>` data directory**, which is still true and
  still worth stating — but without ranking it against other stacks.
- Its `.env` holds one credential per token-backed widget, none generated, all
  minted by hand per `docs/homepage-widgets.md`.
- Keep the read-only-mount consequence, with `**all nine**` reworded to `every
  one` and `four ship as stubs` to `several ship as stubs`.

- [ ] **Step 5: `CLAUDE.md` — the docs layout section**

The `docs/` section names three registries. Add `homepage-widgets.md` as a
fourth **by naming it**, not by changing a number: the sentence *"Three
**registries** centralize the manual operations…"* becomes a form that lists
`dns-records.md`, `sso-applications.md`, `uptime-kuma-monitors.md` and
`homepage-widgets.md` without counting them. Update the paragraph below it that
says *"All three carry `**Runs on:** … — registry, not a build step`"* and *"When
adding a service, decide about all three and say so in each"* the same way.

Also add `homepage-widgets.md` to the guide list if the list enumerates
registries; it is **not** a build-order step, so it does not go in the
`proxmox-setup.md → … → home-assistant-setup.md` sequence.

- [ ] **Step 6: `CLAUDE.md` — the socket-mount list**

| Find | Replace with |
|---|---|
| `the Forgejo runner, Traefik (read-only there), Alloy (container discovery`<br>`+ log tailing), Homepage (the container state on its tiles) and Uptime Kuma` | unchanged — this names members rather than counting them, which is the form the rule asks for. Leave it. |

- [ ] **Step 7: `scripts/init-uptime-kuma.sh` — drop the ranking**

| Find | Replace with |
|---|---|
| `# There is NO .env and nothing to generate — Kuma has no database and creates`<br>`# its admin account through its own first-run web form. It is one of two stacks`<br>`# with no .env at all — Homepage is the other (Dockge also ships no`<br>`# .env.example, but its init script generates a .env for it).` | `# There is NO .env and nothing to generate — Kuma has no database and creates`<br>`# its admin account through its own first-run web form. (Dockge also ships no`<br>`# .env.example, but its init script generates a .env for it.)` |

- [ ] **Step 8: Verify the shell still parses**

```bash
bash -n scripts/init-uptime-kuma.sh && echo "shell OK"
```

- [ ] **Step 9: Verify no stale Homepage claim survives anywhere**

```bash
grep -rniE "homepage[^.]{0,80}(no \.env|token-free|only stack|thinnest)" . --include="*.md" --include="*.sh" --include="*.yaml" | grep -v "docs/superpowers/" | grep -v "docs/review/"
```

Expected: no output.

- [ ] **Step 10: Commit**

```bash
git add CLAUDE.md scripts/init-uptime-kuma.sh
git commit -m "CLAUDE.md: Homepage has an .env, a backup and three live widgets"
```

---

### Task 7: Bring it up on the infra VM and settle the two open questions

**Files:**
- Modify: `docs/homepage-widgets.md` (record what the bring-up settled)
- Possibly modify: `infra/homepage/config/services.yaml` (only if a widget needs
  a `fields:` list or has to be dropped)
- Modify: `docs/status.md`, `docs/roadmap/backup.md` (record the drill)

**Interfaces:**
- Consumes: everything above.
- Produces: the final state of the registry.

This task runs on the **infra VM**, over SSH. Nothing before this point has been
executed anywhere — it has only been read and syntax-checked.

- [ ] **Step 1: Pull the branch on the VM and run the init script**

```bash
cd ~/home-lab && git fetch && git checkout homepage-token-widgets && git pull
```

```bash
scripts/init-homepage.sh
```

Expected: it seeds `.env` from `.env.example` and prints the two-step next
message.

- [ ] **Step 2: Mint the three credentials**

Follow `docs/homepage-widgets.md` exactly — Authentik token, Forgejo token, and
a new Grafana Viewer user — and put the four values in
`~/home-lab/infra/homepage/.env`. This is the first end-to-end read of that
registry; **anything ambiguous in it is a bug in the registry, so fix the file
rather than working around it.**

- [ ] **Step 3: Confirm the guard fires before the values are real**

Before filling `.env` in, or with one value blanked:

```bash
cd ~/home-lab/infra/homepage && docker compose up -d
```

Expected: it refuses to start and names the empty variable. This is the one
chance to see the guard work against a real daemon.

- [ ] **Step 4: Start it and check the three tiles**

```bash
cd ~/home-lab/infra/homepage && docker compose up -d && docker compose ps
```

Open `https://home.thefipster.de` and check each of the three tiles shows
figures.

- [ ] **Step 5: Settle the Forgejo question**

If the Forgejo tile shows repository/issue/pull counts, the `gitea` widget
speaks to Forgejo — delete the *unverified* hedge from the registry and record
the Forgejo version it was verified against.

If it does **not**, read the logs:

```bash
cd ~/home-lab/infra/homepage && docker compose logs homepage | grep -i -E "gitea|401|403|404"
```

A 401/403 is a token scope problem — fix the scopes and retry. A 404 or a parse
error is a genuine incompatibility: per the spec, **drop the widget** rather
than working around it. Remove the `widget:` block from `services.yaml`, remove
`HOMEPAGE_VAR_FORGEJO_KEY` from `compose.yaml` and `.env.example`, and move
Forgejo into the registry's deliberate-absences section with the reason.

- [ ] **Step 6: Settle the Grafana role question**

If the Grafana tile shows figures with the Viewer account, delete the
**Unverified until the first bring-up** block from the registry and state that
Viewer is sufficient.

If the tile is blank, check for a 403 on `/api/datasources`:

```bash
cd ~/home-lab/infra/homepage && docker compose logs homepage | grep -i -E "grafana|403"
```

If that is the cause, add `fields: [dashboards, alertstriggered]` to the widget
block in `services.yaml` and record in the registry that Viewer works only with
the field list. **Do not raise the account to Admin** — that is the outcome the
dedicated-user decision exists to avoid.

- [ ] **Step 7: Run the backup and confirm the new snapshot**

```bash
sudo infra/backup/run.sh
```

Expected: a `staging` / `snapshot` pair for `homepage` between `forgejo` and
`monitoring`, and an `OK:` line that includes it.

```bash
restic snapshots --tag homepage --compact
```

Expected: one snapshot, containing only the `.env` path.

- [ ] **Step 8: Drill the restore**

Per the row added to `backup-restore-drill.md`: break one character in
`HOMEPAGE_VAR_AUTHENTIK_KEY`, recreate the stack, confirm the Authentik tile
loses its figures, then:

```bash
sudo infra/homepage/restore.sh
```

Confirm the Authentik tile shows figures again.

- [ ] **Step 9: Add the Kuma monitor check**

Homepage's existing `Start Page` Docker monitor covers the container. No new
monitor is needed — a widget failing does not stop the container, and a monitor
per widget would be monitoring three other services twice. **Add a line to
`uptime-kuma-monitors.md`'s Homepage section recording that as a deliberate
absence**, per the registry convention.

- [ ] **Step 10: Record the drill**

Update `docs/status.md` and `docs/roadmap/backup.md` step 5 to include
Homepage's drill among those completed, using set phrasing rather than a count.

- [ ] **Step 11: Commit and open the PR**

```bash
git add -A && git commit -m "Homepage widgets: verified on the infra VM"
```

```bash
git push -u origin homepage-token-widgets
```

Then open a PR against `main`. Felix integrates via PRs; do not merge to `main`
directly.

---

## Self-review notes

**Spec coverage.** Every section of the design spec maps to a task: Mechanism
and Backends → Task 1; Grafana-is-a-credential → Task 1 + Task 7 step 6; The
registry → Task 2; The `.env` fallout → Tasks 1, 3 and 6; Backup and *What
joining the backup layer touches* → Tasks 4 and 5; the ordinal rule → Global
Constraints plus explicit steps in Tasks 1, 5 and 6; Verification → Task 7.

**Known unknowns, deliberately left to Task 7.** Two, both flagged in the spec:
whether the `gitea` widget speaks to Forgejo 15, and whether a Grafana Viewer
account is sufficient. Each has a written decision rule so the implementer does
not have to invent one — drop the widget, and add `fields:` respectively.

**Not verified locally by anything.** Everything in Tasks 2, 3, 5 and 6 is
prose; the greps catch stale claims and stray counts but cannot judge whether
the writing is any good. Those tasks want a read-through, not a command.

**The count sweep was run while writing this plan, and it found two files the
spec had missed** — `docs/timetable.md` and `infra/authentik/backup.sh`. Both
are now steps in Task 5. It also flagged `docs/proxmox-setup.md`, which is a
false positive the plan now names explicitly so nobody chases it: those numbers
count drives, and hardware inventory is exempt.

The full worklist the sweep produces on a clean checkout is nine lines, and
every one has a step:

| Line | Handled by |
|---|---|
| `backup-setup.md` ×3 | Task 5, steps 1 and 3 |
| `homepage-setup.md` | Task 3, step 4 |
| `roadmap/backup.md` | Task 5, step 7 |
| `status.md` | Task 5, step 8 |
| `timetable.md` | Task 5, step 11 |
| `infra/authentik/backup.sh` | Task 5, step 12 |
| `infra/backup/run.sh` | Task 4, step 4 |
