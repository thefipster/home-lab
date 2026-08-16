# Forgejo Release Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manually dispatched Forgejo Actions workflow that refreshes the
pull mirror itself, waits for named release tags, and builds them into versioned
container images and generic packages.

**Architecture:** One new template file `infra/forgejo/release.yml` (destined for
the app repo at `.forgejo/workflows/release.yml`). A `plan` job validates the
dispatched tags, POSTs `mirror-sync`, polls until the tags exist, and emits three
JSON matrices. Three build jobs — `blazor`, `showcase`, `firmware` — consume
those matrices, each checking out its tag and publishing versioned artifacts.

**Tech Stack:** Forgejo Actions (GitHub Actions-compatible YAML), Docker buildx,
Node 24, PlatformIO via pip, Forgejo container + generic package registries.

## Global Constraints

- **No test system in this repo.** CLAUDE.md: correctness is verified by reading,
  not by executing. Verification steps below use ad-hoc PyYAML scripts written to
  the scratchpad — **never commit a test harness or test directory to this repo.**
- **Scratchpad for all temporary files:**
  `C:\Users\felix\AppData\Local\Temp\claude\C--Users-felix-Source-home-lab\dc806f8e-7b70-4915-9878-1da542532c28\scratchpad`
- **Branch:** all work lands on `forgejo-release-workflow`. Never commit to `main`.
- **Line endings: LF.** `.gitattributes` forces LF repo-wide. Do not let an editor
  write CRLF.
- **Never write a host IP address.** Machines are addressed by name.
- **Image pins are major-only** except the documented exceptions. New pins used
  here: `ghcr.io/catthehacker/ubuntu:act-22.04`, `python:3.12-bookworm`,
  `code.forgejo.org/oci/node:24-bookworm` — all already present in
  `build-and-push.yml`; reuse those exact tags, do not invent new ones.
- **Placeholders stay placeholders.** Every repo-specific path, PlatformIO
  environment and filesystem type ships marked as a placeholder. Do not guess real
  values for the verdure repo.
- **Component set:** `blazor` (Blazor), `showcase` (Astro), `atmos` / `terra` /
  `flux` (PlatformIO). Tag format `^(atmos|terra|flux|blazor|showcase)-v[0-9]+\.[0-9]+\.[0-9]+$`.
- **Four image tags per release:** `latest`, `X.Y.Z`, `X.Y`, `X`. No SHA tags.
- **Generic package names are owner-scoped** and therefore prefixed `verdure-`.
- **Secrets:** `REGISTRY_TOKEN` (`write:package`), `FORGEJO_API_TOKEN`
  (`write:repository`).
- **Spec:** [2026-08-05-forgejo-release-workflow-design.md](../specs/2026-08-05-forgejo-release-workflow-design.md)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `infra/forgejo/release.yml` | Create | The release workflow template — tag-driven, versioned publishing |
| `infra/forgejo/build-and-push.yml` | Modify | Stays the SHA-tagged dev builder; component names corrected |
| `docs/forgejo-setup.md` | Modify | Both secrets documented; release workflow + cut-a-release procedure |
| `docs/roadmap/ci-triggers.md` | Rewrite | Shrinks to the nightly rebuild that remains ahead |
| `CLAUDE.md` | Modify | CI bullets: two workflows, five components, four image tags |
| `README.md:150` | Modify | Repo tree gains the new template file |

---

### Task 1: Workflow skeleton and the `plan` job

**Files:**
- Create: `infra/forgejo/release.yml`
- Verify with: scratchpad script `check_release.py` (not committed)

**Interfaces:**
- Consumes: nothing (first task)
- Produces: a `plan` job with six outputs consumed by Tasks 2–4 —
  `blazor`, `blazor_any`, `showcase`, `showcase_any`, `firmware`, `firmware_any`.
  The `*_any` outputs are the strings `"true"` / `"false"`. The matrix outputs are
  JSON arrays of objects with these exact keys:
  - `blazor` / `showcase` entries: `tag`, `version`, `major`, `minor`, `dir`, `dockerfile`
  - `firmware` entries: `tag`, `version`, `component`, `dir`, `pio_env`, `filesystem`

- [ ] **Step 1: Write the verification script**

Create the scratchpad file `check_release.py`:

```python
import sys, yaml, re, pathlib

p = pathlib.Path(sys.argv[1])
doc = yaml.safe_load(p.read_text(encoding="utf-8"))
fail = []

def check(cond, msg):
    if not cond:
        fail.append(msg)

# PyYAML resolves the bare key `on:` to the boolean True (the YAML 1.1
# "y/yes/on" rule). GitHub/Forgejo Actions means the string "on"; look under
# both so this script works whichever way the file is written.
triggers = doc.get("on", doc.get(True))
check(triggers is not None, "no `on:` block")
check(list(triggers) == ["workflow_dispatch"],
      f"triggers should be workflow_dispatch only, got {list(triggers)}")
check("tags" in triggers["workflow_dispatch"]["inputs"], "missing `tags` input")
check(triggers["workflow_dispatch"]["inputs"]["tags"]["required"] is True,
      "`tags` input must be required")

jobs = doc["jobs"]
plan = jobs["plan"]
for out in ("blazor", "blazor_any", "showcase", "showcase_any",
            "firmware", "firmware_any"):
    check(out in plan["outputs"], f"plan is missing output `{out}`")

names = [s.get("name") for s in plan["steps"]]
check(names == ["Checkout", "Validate tags", "Sync the mirror",
                "Wait for the tags to arrive", "Plan builds"],
      f"unexpected plan steps: {names}")

body = p.read_text(encoding="utf-8")
# The dispatch input is free text. It must reach the shell as an environment
# variable, never as a ${{ }} interpolation inside a run: script, or a
# dispatched string could execute as shell. Every step that reads the tags must
# therefore declare TAGS in its own env: mapping, and no run: body may contain
# the interpolation.
for step in plan["steps"]:
    if "run" in step and "inputs.tags" in step["run"]:
        fail.append(f"step '{step['name']}' interpolates inputs.tags into its script")
    if "run" in step and "$TAGS" in step["run"]:
        check(step.get("env", {}).get("TAGS") == "${{ inputs.tags }}",
              f"step '{step['name']}' uses $TAGS without an env: mapping")
check(body.count("TAGS: ${{ inputs.tags }}") == 3,
      "the three tag-reading steps must each declare TAGS in env:")
check("(atmos|terra|flux|blazor|showcase)" in body, "component regex missing")
check("PLACEHOLDER" in body, "component table must be marked PLACEHOLDER")

if fail:
    print("FAIL")
    for f in fail:
        print("  -", f)
    sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to verify it fails**

Run (from the repo root, replacing `<SCRATCH>` with the scratchpad path):

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: FAIL — `FileNotFoundError`, the workflow does not exist yet.

- [ ] **Step 3: Create `infra/forgejo/release.yml` with the header, triggers and `plan` job**

Write exactly this (comment density matches `build-and-push.yml`, which is the
house style for these templates):

```yaml
# =============================================================================
# release.yml
#
# Place this in your VERDURE REPO at: .forgejo/workflows/release.yml
#
# The TAG-DRIVEN counterpart to build-and-push.yml. That file builds whatever
# the mirror last synced and tags images by commit SHA — a dev build. This one
# builds a RELEASE: you name the git tags, it publishes versioned artifacts.
#
# Releases are cut by hand as `<component>-v<semver>` tags on GitHub, so the
# build is dispatched by hand too, in the same sitting. That is deliberate:
# Forgejo pull-mirrors fire no Actions events, and the LAN is unreachable from
# GitHub, so nothing can trigger this automatically. Polling on a schedule was
# designed and rejected — see docs/superpowers/specs/2026-08-05-*.md.
#
# A dispatched run may check out a ref that did not exist when it started: the
# dispatch pins only WHICH FILE runs (from the default branch). So step one is
# to sync the mirror, and step two is to wait for the tags to land.
#
# Components and what a tag publishes:
#   blazor-v1.2.3    -> image  <repo>/blazor      :latest :1.2.3 :1.2 :1
#   showcase-v1.2.3  -> image  <repo>/showcase    :latest :1.2.3 :1.2 :1
#                    +  generic verdure-showcase/{1.2.3,latest}/dist.tar.gz
#   atmos-v1.2.3     -> generic verdure-atmos/{1.2.3,latest}/*.bin
#   terra-v1.2.3     -> generic verdure-terra/{1.2.3,latest}/*.bin
#   flux-v1.2.3      -> generic verdure-flux/{1.2.3,latest}/*.bin
#
# The per-component paths in the `plan` job's COMPONENTS table are the ONLY
# things you should need to change to run this against the real repo. They are
# marked PLACEHOLDER.
# =============================================================================

name: Release

on:
  workflow_dispatch:
    inputs:
      tags:
        description: "Release tags, space-separated (e.g. blazor-v1.2.3 atmos-v0.4.1)"
        required: true
        type: string

env:
  FORGEJO_HOST: git.thefipster.de
  # The Forgejo account both tokens belong to. REGISTRY_TOKEN (write:package)
  # pushes; FORGEJO_API_TOKEN (write:repository) only triggers the mirror sync.
  # Two tokens so the one handed to third-party actions stays minimal.
  REGISTRY_USER: felix

jobs:
  # ===========================================================================
  # plan — the only job that thinks. Validate, sync, wait, fan out.
  # ===========================================================================
  plan:
    runs-on: docker
    outputs:
      blazor: ${{ steps.plan.outputs.blazor }}
      blazor_any: ${{ steps.plan.outputs.blazor_any }}
      showcase: ${{ steps.plan.outputs.showcase }}
      showcase_any: ${{ steps.plan.outputs.showcase_any }}
      firmware: ${{ steps.plan.outputs.firmware }}
      firmware_any: ${{ steps.plan.outputs.firmware_any }}
    steps:
      - name: Checkout
        uses: https://code.forgejo.org/actions/checkout@v4
        with:
          fetch-depth: 0

      # -----------------------------------------------------------------------
      # Fail on a typo HERE, before any toolchain container starts. $TAGS is
      # read from the environment, never interpolated into the script text —
      # a ${{ }} substitution inside a run block would let dispatch input run
      # as shell.
      # -----------------------------------------------------------------------
      - name: Validate tags
        env:
          TAGS: ${{ inputs.tags }}
        run: |
          set -euo pipefail
          test -n "${TAGS// /}" || { echo "::error::no tags given"; exit 1; }
          for t in $TAGS; do
            if ! printf '%s' "$t" | grep -Eq '^(atmos|terra|flux|blazor|showcase)-v[0-9]+\.[0-9]+\.[0-9]+$'; then
              echo "::error::'$t' is not <component>-v<major>.<minor>.<patch>"
              exit 1
            fi
            echo "ok: $t"
          done

      # -----------------------------------------------------------------------
      # mirror-sync is ASYNCHRONOUS: it queues the pull and returns 200. The
      # wait is the next step.
      # -----------------------------------------------------------------------
      - name: Sync the mirror
        env:
          API_TOKEN: ${{ secrets.FORGEJO_API_TOKEN }}
        run: |
          set -euo pipefail
          curl -sS --fail-with-body -X POST \
            -H "Authorization: token $API_TOKEN" \
            "https://${FORGEJO_HOST}/api/v1/repos/${{ github.repository }}/mirror-sync"
          echo "mirror sync queued"

      # -----------------------------------------------------------------------
      # Because the run knows exactly which refs it needs, this is a
      # deterministic wait rather than a sleep-and-hope. A tag that never
      # arrives fails the run by name.
      # -----------------------------------------------------------------------
      - name: Wait for the tags to arrive
        env:
          TAGS: ${{ inputs.tags }}
        run: |
          set -euo pipefail
          deadline=$((SECONDS + 600))
          for t in $TAGS; do
            until git ls-remote --exit-code --tags origin "refs/tags/$t" >/dev/null 2>&1; do
              if [ "$SECONDS" -ge "$deadline" ]; then
                echo "::error::timed out waiting for tag '$t' to reach the mirror"
                exit 1
              fi
              echo "waiting for $t ..."
              sleep 15
            done
            echo "found: $t"
          done
          git fetch --tags --force

      # -----------------------------------------------------------------------
      # One node script, because the default job image guarantees node and
      # nothing else (no jq, no python). Emits one JSON matrix per toolchain
      # plus an `_any` flag, so a toolchain with nothing in this release skips
      # its job instead of running an empty matrix.
      # -----------------------------------------------------------------------
      - name: Plan builds
        id: plan
        env:
          TAGS: ${{ inputs.tags }}
        run: |
          node >> "$GITHUB_OUTPUT" <<'NODE'
          // ---- PLACEHOLDERS: one row per component, the only edit you need --
          //   kind        which build job handles it
          //   dir         directory holding the project (docker build context,
          //               npm working directory, or platformio.ini location)
          //   dockerfile  repo-relative Dockerfile path (image kinds only)
          //   pio_env     the [env:...] section to build (firmware only)
          //   filesystem  "littlefs"/"spiffs" to also build a filesystem image,
          //               "" to skip that step (firmware only)
          const COMPONENTS = {
            blazor:   { kind: 'blazor',   dir: 'src/dotnet',
                        dockerfile: 'src/dotnet/Fip.Verdure.Web/Dockerfile' },
            showcase: { kind: 'showcase', dir: 'src/astro',
                        dockerfile: 'src/astro/Dockerfile' },
            atmos:    { kind: 'firmware', dir: 'src/platformio/atmos',
                        pio_env: 'esp32dev',           filesystem: 'littlefs' },
            terra:    { kind: 'firmware', dir: 'src/platformio/terra',
                        pio_env: 'esp32-c3-devkitm-1', filesystem: '' },
            flux:     { kind: 'firmware', dir: 'src/platformio/flux',
                        pio_env: 'esp32-c3-devkitm-1', filesystem: '' },
          };

          const buckets = { blazor: [], showcase: [], firmware: [] };
          const tags = (process.env.TAGS || '').trim().split(/\s+/).filter(Boolean);

          for (const tag of tags) {
            const m = /^([a-z]+)-v(\d+)\.(\d+)\.(\d+)$/.exec(tag);
            if (!m) throw new Error(`unparseable tag: ${tag}`);
            const [, name, maj, min, patch] = m;
            const c = COMPONENTS[name];
            if (!c) throw new Error(`no COMPONENTS row for: ${name}`);
            const common = {
              tag,
              version: `${maj}.${min}.${patch}`,
              major: maj,
              minor: `${maj}.${min}`,
              dir: c.dir,
            };
            if (c.kind === 'firmware') {
              buckets.firmware.push({
                ...common,
                component: name,
                pio_env: c.pio_env,
                filesystem: c.filesystem,
              });
            } else {
              buckets[c.kind].push({ ...common, dockerfile: c.dockerfile });
            }
          }

          for (const [k, v] of Object.entries(buckets)) {
            console.log(`${k}=${JSON.stringify(v)}`);
            console.log(`${k}_any=${v.length > 0}`);
          }
          NODE
          cat "$GITHUB_OUTPUT"
```

- [ ] **Step 4: Run the verification script to confirm it passes**

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: `PASS`

- [ ] **Step 5: Verify the node planner logic independently**

The node script is the one piece with real logic, so run it standalone. Create
the scratchpad file `plan_probe.js` containing **only the JavaScript between the
`<<'NODE'` and `NODE` markers** (copy it verbatim from the workflow), then:

```bash
TAGS="blazor-v1.2.3 atmos-v0.4.1 showcase-v2.0.0 terra-v0.1.0" node "<SCRATCH>/plan_probe.js"
```

Expected output (four lines, plus `_any` flags — exact JSON key order may vary):

```
blazor=[{"tag":"blazor-v1.2.3","version":"1.2.3","major":"1","minor":"1.2","dir":"src/dotnet","dockerfile":"src/dotnet/Fip.Verdure.Web/Dockerfile"}]
blazor_any=true
showcase=[{"tag":"showcase-v2.0.0","version":"2.0.0","major":"2","minor":"2.0","dir":"src/astro","dockerfile":"src/astro/Dockerfile"}]
showcase_any=true
firmware=[{...atmos...},{...terra...}]
firmware_any=true
```

Then confirm the empty case sets the flag correctly:

```bash
TAGS="blazor-v1.0.0" node "<SCRATCH>/plan_probe.js"
```

Expected: `firmware=[]` and `firmware_any=false`.

- [ ] **Step 6: Commit**

```bash
git add infra/forgejo/release.yml && git commit -m "feat(ci): release workflow skeleton and plan job"
```

---

### Task 2: The `blazor` job

**Files:**
- Modify: `infra/forgejo/release.yml` (append a job)

**Interfaces:**
- Consumes: `needs.plan.outputs.blazor` (JSON array), `needs.plan.outputs.blazor_any` (`"true"`/`"false"`). Matrix entry keys: `tag`, `version`, `major`, `minor`, `dir`, `dockerfile`.
- Produces: image `${FORGEJO_HOST}/${{ github.repository }}/blazor` on four tags. Establishes the `Resolve revision` step pattern (id `rev`, output `sha`) reused by Task 3.

- [ ] **Step 1: Extend the verification script**

Append to `check_release.py`, immediately before the `if fail:` block:

```python
blazor = jobs["blazor"]
check(blazor["needs"] == "plan", "blazor must need plan")
check("blazor_any == 'true'" in blazor["if"],
      f"blazor must be gated on blazor_any, got {blazor.get('if')}")
check(blazor["strategy"]["fail-fast"] is False, "blazor matrix must not fail-fast")
check("fromJSON(needs.plan.outputs.blazor)" in blazor["strategy"]["matrix"]["include"],
      "blazor matrix must come from the plan output")
check(blazor["container"]["image"] == "ghcr.io/catthehacker/ubuntu:act-22.04",
      "blazor needs the act image (node actions + docker CLI)")

bnames = [s.get("name") for s in blazor["steps"]]
check(bnames == ["Checkout", "Resolve revision", "Log in to Forgejo registry",
                 "Set up Docker Buildx", "Build and push"],
      f"unexpected blazor steps: {bnames}")

co = next(s for s in blazor["steps"] if s["name"] == "Checkout")
check(co["with"]["ref"] == "${{ matrix.tag }}", "blazor must check out the tag")

push = next(s for s in blazor["steps"] if s["name"] == "Build and push")
tags = push["with"]["tags"]
for suffix in ("blazor:latest", "blazor:${{ matrix.version }}",
               "blazor:${{ matrix.minor }}", "blazor:${{ matrix.major }}"):
    check(suffix in tags, f"blazor image is missing the tag {suffix}")
check("${{ github.sha }}" not in push["with"]["labels"],
      "revision label must be the TAG's commit, not the dispatched ref's sha")
check("steps.rev.outputs.sha" in push["with"]["labels"],
      "revision label must use the resolved sha")
```

- [ ] **Step 2: Run it to verify it fails**

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: FAIL with a `KeyError: 'blazor'` — the job does not exist yet.

- [ ] **Step 3: Append the `blazor` job**

```yaml
  # ===========================================================================
  # blazor — Blazor Server -> container image on four tags.
  #
  # No highest-version guard on the rolling tags: a dispatched release always
  # builds the tag you just cut, so latest/X.Y/X are correct by construction.
  # Deliberately re-releasing an OLD patch would move `latest` backwards.
  # ===========================================================================
  blazor:
    runs-on: docker
    needs: plan
    if: ${{ needs.plan.outputs.blazor_any == 'true' }}
    container:
      # Node actions AND the docker CLI in one image — the plain node image has
      # no docker binary and login-action fails with "docker: not found".
      image: ghcr.io/catthehacker/ubuntu:act-22.04
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJSON(needs.plan.outputs.blazor) }}
    steps:
      - name: Checkout
        uses: https://code.forgejo.org/actions/checkout@v4
        with:
          ref: ${{ matrix.tag }}
          fetch-depth: 0

      # `github.sha` is the DISPATCHED ref's commit (the default branch), not
      # the tag's. Resolve the real one after checkout or every image claims to
      # have been built from main.
      - name: Resolve revision
        id: rev
        run: echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"

      - name: Log in to Forgejo registry
        uses: https://code.forgejo.org/docker/login-action@v3
        with:
          registry: ${{ env.FORGEJO_HOST }}
          username: ${{ env.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Set up Docker Buildx
        uses: https://code.forgejo.org/docker/setup-buildx-action@v3

      - name: Build and push
        uses: https://code.forgejo.org/docker/build-push-action@v6
        with:
          context: ${{ matrix.dir }}
          file: ${{ matrix.dockerfile }}
          push: true
          tags: |
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/blazor:latest
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/blazor:${{ matrix.version }}
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/blazor:${{ matrix.minor }}
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/blazor:${{ matrix.major }}
          # The commit travels as a label instead of a fifth tag — traceability
          # without tag spam.
          labels: |
            org.opencontainers.image.version=${{ matrix.version }}
            org.opencontainers.image.revision=${{ steps.rev.outputs.sha }}
```

- [ ] **Step 4: Run the verification script to confirm it passes**

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add infra/forgejo/release.yml && git commit -m "feat(ci): blazor release job with four rolling image tags"
```

---

### Task 3: The `showcase` job

**Files:**
- Modify: `infra/forgejo/release.yml` (append a job)

**Interfaces:**
- Consumes: `needs.plan.outputs.showcase`, `needs.plan.outputs.showcase_any`. Matrix entry keys as Task 2.
- Produces: image `.../showcase` on four tags, plus generic package `verdure-showcase/{version,latest}/dist.tar.gz`. Establishes the delete-then-PUT publish loop reused by Task 4.

- [ ] **Step 1: Extend the verification script**

Append to `check_release.py`, before the `if fail:` block:

```python
show = jobs["showcase"]
check(show["needs"] == "plan", "showcase must need plan")
check("showcase_any == 'true'" in show["if"], "showcase must be gated on showcase_any")
check(show["strategy"]["fail-fast"] is False, "showcase matrix must not fail-fast")
check(show["container"]["image"] == "ghcr.io/catthehacker/ubuntu:act-22.04",
      "showcase needs node AND the docker CLI, so the act image")

snames = [s.get("name") for s in show["steps"]]
check(snames == ["Checkout", "Resolve revision", "Set up Node", "Build site",
                 "Archive dist", "Log in to Forgejo registry", "Set up Docker Buildx",
                 "Build and push image", "Publish archive to generic registry"],
      f"unexpected showcase steps: {snames}")

# The site must be compiled exactly once — a multi-stage Dockerfile would
# rebuild it, and the runner is capacity: 1.
body2 = p.read_text(encoding="utf-8")
check(body2.count("npm run build") == 1, "the site must be built exactly once")

arch = next(s for s in show["steps"] if s["name"] == "Publish archive to generic registry")
check("verdure-showcase" in arch["run"], "generic package must be owner-prefixed")
check("latest" in arch["run"], "archive must also publish under the latest version")
check("-X DELETE" in arch["run"], "PUT over an existing filename 409s; delete first")
```

- [ ] **Step 2: Run it to verify it fails**

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: FAIL with `KeyError: 'showcase'`.

- [ ] **Step 3: Append the `showcase` job**

```yaml
  # ===========================================================================
  # showcase — Astro -> BOTH outputs from ONE build:
  #   * dist.tar.gz in the generic registry, for classic "upload and unzip"
  #     web hosting;
  #   * an nginx image, so Coolify can deploy it like any other service.
  #
  # Its Dockerfile is a `COPY dist/ /usr/share/nginx/html` two-liner consuming
  # the dist/ this job just produced — NOT multi-stage. Multi-stage would
  # compile the site a second time on a capacity: 1 runner. The trade-off is
  # that the Dockerfile is not standalone-buildable.
  # ===========================================================================
  showcase:
    runs-on: docker
    needs: plan
    if: ${{ needs.plan.outputs.showcase_any == 'true' }}
    container:
      # Needs npm AND the docker CLI, so the act image rather than the node
      # one. Its bundled node is for the actions runtime; the site build pins
      # its own version in the next step.
      image: ghcr.io/catthehacker/ubuntu:act-22.04
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJSON(needs.plan.outputs.showcase) }}
    steps:
      - name: Checkout
        uses: https://code.forgejo.org/actions/checkout@v4
        with:
          ref: ${{ matrix.tag }}
          fetch-depth: 0

      - name: Resolve revision
        id: rev
        run: echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"

      # THIRD place Node 24 is written down (with config.yml's runner label and
      # build-and-push.yml's Astro job). Keep all three in step, and keep it an
      # LTS line — Node 20 went EOL 2026-04-30.
      - name: Set up Node
        uses: https://code.forgejo.org/actions/setup-node@v4
        with:
          node-version: 24

      # `npm ci` needs a committed package-lock.json and installs exactly it —
      # `npm install` would drift the release from the lockfile.
      - name: Build site
        working-directory: ${{ matrix.dir }}
        run: |
          npm ci
          npm run build

      # `-C dist .` archives the CONTENTS of dist/, so unpacking gives the site
      # root directly rather than a dist/ wrapper.
      - name: Archive dist
        working-directory: ${{ matrix.dir }}
        run: tar -czf dist.tar.gz -C dist .

      - name: Log in to Forgejo registry
        uses: https://code.forgejo.org/docker/login-action@v3
        with:
          registry: ${{ env.FORGEJO_HOST }}
          username: ${{ env.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Set up Docker Buildx
        uses: https://code.forgejo.org/docker/setup-buildx-action@v3

      - name: Build and push image
        uses: https://code.forgejo.org/docker/build-push-action@v6
        with:
          context: ${{ matrix.dir }}
          file: ${{ matrix.dockerfile }}
          push: true
          tags: |
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/showcase:latest
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/showcase:${{ matrix.version }}
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/showcase:${{ matrix.minor }}
            ${{ env.FORGEJO_HOST }}/${{ github.repository }}/showcase:${{ matrix.major }}
          labels: |
            org.opencontainers.image.version=${{ matrix.version }}
            org.opencontainers.image.revision=${{ steps.rev.outputs.sha }}

      # -----------------------------------------------------------------------
      # The generic registry has no rolling-tag concept, so "latest" is a second
      # VERSION whose files are rewritten each release. There is no action for
      # this registry — it is a plain HTTP PUT, and a PUT over an existing
      # filename returns 409, so delete first. That also makes re-dispatching
      # the same tag idempotent rather than an error.
      # Generic packages are OWNER-scoped, hence the `verdure-` prefix.
      # -----------------------------------------------------------------------
      - name: Publish archive to generic registry
        env:
          TOKEN: ${{ secrets.REGISTRY_TOKEN }}
        run: |
          set -euo pipefail
          BASE="https://${FORGEJO_HOST}/api/packages/${{ github.repository_owner }}/generic/verdure-showcase"
          for v in "${{ matrix.version }}" latest; do
            url="$BASE/$v/dist.tar.gz"
            curl -sS --user "${REGISTRY_USER}:$TOKEN" -X DELETE "$url" || true
            curl -sS --fail-with-body --user "${REGISTRY_USER}:$TOKEN" \
                 --upload-file "${{ matrix.dir }}/dist.tar.gz" "$url"
            echo "published $url"
          done
```

- [ ] **Step 4: Run the verification script to confirm it passes**

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add infra/forgejo/release.yml && git commit -m "feat(ci): showcase release job publishing image and dist archive"
```

---

### Task 4: The `firmware` job

**Files:**
- Modify: `infra/forgejo/release.yml` (append a job)

**Interfaces:**
- Consumes: `needs.plan.outputs.firmware`, `needs.plan.outputs.firmware_any`. Matrix entry keys: `tag`, `version`, `component`, `dir`, `pio_env`, `filesystem`.
- Produces: generic packages `verdure-<component>/{version,latest}/<component>-firmware.bin` (+ filesystem image). Completes the workflow file.

- [ ] **Step 1: Extend the verification script**

Append to `check_release.py`, before the `if fail:` block:

```python
fw = jobs["firmware"]
check(fw["needs"] == "plan", "firmware must need plan")
check("firmware_any == 'true'" in fw["if"], "firmware must be gated on firmware_any")
check(fw["strategy"]["fail-fast"] is False,
      "a board that will not compile must not cancel its siblings")
check(fw["container"]["image"] == "python:3.12-bookworm",
      "PlatformIO publishes no official image; upstream's CI recipe is pip")

fnames = [s.get("name") for s in fw["steps"]]
check(fnames == ["Checkout", "Cache PlatformIO toolchain", "Install PlatformIO Core",
                 "Build firmware", "Build filesystem image", "Stage artifacts",
                 "Publish to generic registry"],
      f"unexpected firmware steps: {fnames}")

fsstep = next(s for s in fw["steps"] if s["name"] == "Build filesystem image")
check("matrix.filesystem != ''" in fsstep["if"],
      "the buildfs target must be skipped when no filesystem is configured")

pub = next(s for s in fw["steps"] if s["name"] == "Publish to generic registry")
check("verdure-${{ matrix.component }}" in pub["run"],
      "each component gets its own owner-prefixed package")
check("-X DELETE" in pub["run"], "delete before PUT")
check("latest" in pub["run"], "firmware must also publish under the latest version")

# A .bin is not a container image, so this job must not build or push one.
# (`runs-on: docker` is the RUNNER LABEL and is expected — match on the actions
# and CLI calls instead.)
for marker in ("login-action", "buildx", "build-push-action", "docker build"):
    check(marker not in str(fw["steps"]),
          f"firmware job should not use {marker} — .bin files are not images")
```

- [ ] **Step 2: Run it to verify it fails**

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: FAIL with `KeyError: 'firmware'`.

- [ ] **Step 3: Append the `firmware` job**

```yaml
  # ===========================================================================
  # firmware — atmos / terra / flux. One matrix, not a job each: the three are
  # the same recipe in a different directory. Adding a fourth board is one row
  # in the plan job's COMPONENTS table and nothing here.
  #
  # No docker in this job at all — a .bin is not a container image, so these go
  # to the generic package registry only.
  # ===========================================================================
  firmware:
    runs-on: docker
    needs: plan
    if: ${{ needs.plan.outputs.firmware_any == 'true' }}
    container:
      # PlatformIO publishes NO official Docker image — the Docker Hub ones are
      # community builds. Upstream's own documented CI recipe is a pip install.
      # Pinned major.minor because the bare `python:3` tag moves.
      image: python:3.12-bookworm
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJSON(needs.plan.outputs.firmware) }}
    steps:
      - name: Checkout
        uses: https://code.forgejo.org/actions/checkout@v4
        with:
          ref: ${{ matrix.tag }}
          fetch-depth: 0

      # PlatformIO downloads a full cross-toolchain (hundreds of MB) on first
      # use. Keyed on platformio.ini so a changed platform/lib_deps busts it.
      - name: Cache PlatformIO toolchain
        uses: https://code.forgejo.org/actions/cache@v4
        with:
          path: |
            ~/.platformio
            ~/.cache/pip
          key: pio-${{ matrix.component }}-${{ hashFiles(format('{0}/platformio.ini', matrix.dir)) }}
          restore-keys: |
            pio-${{ matrix.component }}-

      - name: Install PlatformIO Core
        run: pip install --upgrade platformio

      - name: Build firmware
        run: pio run -d "${{ matrix.dir }}" -e "${{ matrix.pio_env }}"

      # A separate target — `buildfs` is NOT produced by a plain build.
      - name: Build filesystem image
        if: ${{ matrix.filesystem != '' }}
        run: pio run -d "${{ matrix.dir }}" -e "${{ matrix.pio_env }}" -t buildfs

      - name: Stage artifacts
        run: |
          set -euo pipefail
          BUILD_DIR="${{ matrix.dir }}/.pio/build/${{ matrix.pio_env }}"
          rm -rf dist-firmware && mkdir -p dist-firmware
          cp "$BUILD_DIR/firmware.bin" "dist-firmware/${{ matrix.component }}-firmware.bin"
          if [ -n "${{ matrix.filesystem }}" ]; then
            cp "$BUILD_DIR/${{ matrix.filesystem }}.bin" \
               "dist-firmware/${{ matrix.component }}-${{ matrix.filesystem }}.bin"
          fi
          ls -l dist-firmware

      # Same delete-then-PUT as showcase, and the same reason: 409 on overwrite,
      # owner-scoped names. `latest` is a second version, rewritten each release,
      # so a device updater has a stable URL.
      - name: Publish to generic registry
        env:
          TOKEN: ${{ secrets.REGISTRY_TOKEN }}
        run: |
          set -euo pipefail
          BASE="https://${FORGEJO_HOST}/api/packages/${{ github.repository_owner }}/generic/verdure-${{ matrix.component }}"
          for v in "${{ matrix.version }}" latest; do
            for f in dist-firmware/*; do
              url="$BASE/$v/$(basename "$f")"
              curl -sS --user "${REGISTRY_USER}:$TOKEN" -X DELETE "$url" || true
              curl -sS --fail-with-body --user "${REGISTRY_USER}:$TOKEN" \
                   --upload-file "$f" "$url"
              echo "published $url"
            done
          done
```

- [ ] **Step 4: Run the verification script to confirm it passes**

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml
```

Expected: `PASS`

- [ ] **Step 5: Confirm the file is LF-only**

```bash
python -c "d=open('infra/forgejo/release.yml','rb').read(); print('CRLF FOUND' if b'\r\n' in d else 'LF ok')"
```

Expected: `LF ok`

- [ ] **Step 6: Commit**

```bash
git add infra/forgejo/release.yml && git commit -m "feat(ci): firmware release job for atmos, terra and flux"
```

---

### Task 5: Correct the component names in `build-and-push.yml`

**Files:**
- Modify: `infra/forgejo/build-and-push.yml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing consumed later. Independent of Tasks 1–4; it exists so the two files agree on what the five components are called.

`build-and-push.yml` keeps its role as the SHA-tagged dev builder with browsable
run artifacts. Only names change — no behaviour, no new triggers.

- [ ] **Step 1: Write the verification script**

Create the scratchpad file `check_dev.py`:

```python
import sys, yaml, pathlib
p = pathlib.Path("infra/forgejo/build-and-push.yml")
body = p.read_text(encoding="utf-8")
doc = yaml.safe_load(body)
triggers = doc.get("on", doc.get(True))
fail = []

def check(cond, msg):
    if not cond:
        fail.append(msg)

# Role unchanged: manual dev builds only.
check(list(triggers) == ["workflow_dispatch"], "dev builder stays dispatch-only")
inputs = set(triggers["workflow_dispatch"]["inputs"])
check(inputs == {"build_blazor", "build_firmware", "build_showcase"},
      f"inputs should be renamed to the component names, got {sorted(inputs)}")

jobs = set(doc["jobs"])
check(jobs == {"build-blazor", "build-firmware", "build-showcase"},
      f"jobs should be renamed, got {sorted(jobs)}")

# The firmware matrix must list the three real boards.
names = [e["name"] for e in doc["jobs"]["build-firmware"]["strategy"]["matrix"]["project"]]
check(names == ["atmos", "terra", "flux"], f"matrix should be atmos/terra/flux, got {names}")

# Stale names must be gone everywhere, including comments and image paths.
for stale in ("build_web", "build_site", "/web:", "verdure-site", "sensor"):
    check(stale not in body, f"stale name still present: {stale}")

# It must still be the SHA-tagged builder — that is what distinguishes it.
check("github.sha" in body, "dev builder still tags by commit SHA")
check("upload-artifact" in body, "dev builder keeps its browsable run artifacts")
# Dev firmware stays in ONE package, deliberately: SHA versions must not land
# inside the per-component packages release.yml publishes semver into.
check("verdure-firmware" in body, "verdure-firmware must NOT be renamed")
for perc in ("verdure-atmos", "verdure-terra", "verdure-flux"):
    check(perc not in body, f"dev builder must not publish into {perc}")

if fail:
    print("FAIL")
    for f in fail:
        print("  -", f)
    sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to verify it fails**

```bash
python "<SCRATCH>/check_dev.py"
```

Expected: FAIL listing `build_web`, `build_site`, `/web:`, `verdure-site` and
`sensor` as still present.

- [ ] **Step 3: Apply the renames**

Make exactly these edits to `infra/forgejo/build-and-push.yml`:

| Current | Becomes |
|---|---|
| input `build_web` (and its description "Build + push the Blazor web image") | `build_blazor`, "Build + push the Blazor image" |
| input `build_site` (description "Build the Astro site") | `build_showcase`, "Build the Astro showcase site" |
| job `build-web` | `build-blazor` |
| job `build-site` | `build-showcase` |
| `if:` guards referencing `inputs.build_web` / `inputs.build_site` | the renamed inputs (keep both the `== true` and `== 'true'` comparisons — a boolean input can arrive as the truthy string `"false"`) |
| image path `.../web:latest` and `.../web:${{ github.sha }}` | `.../blazor:latest`, `.../blazor:${{ github.sha }}` |
| matrix entry `name: sensor`, `dir: src/platformio/sensor` | two entries, `terra` and `flux`, with `dir: src/platformio/terra` and `src/platformio/flux`, both `pio_env: esp32-c3-devkitm-1`, both `filesystem: ""` — still PLACEHOLDERS |
| generic package `verdure-site` | `verdure-showcase` |
| generic package `verdure-firmware` | **unchanged — do not rename.** Dev builds are versioned by commit SHA; keeping them in one `verdure-firmware` package stops SHA versions landing inside the per-component `verdure-atmos` / `verdure-terra` / `verdure-flux` packages, where `release.yml` publishes semver versions and `latest`. Add a comment in place saying so. |
| artifact `name: site` and path `src/astro/dist.tar.gz` | `name: showcase` (path unchanged — still a placeholder) |

Also update the header comment block's "Where each job's output ends up" table
to the new names:

```
#   blazor    OCI image  -> container registry, git.thefipster.de/<repo>/blazor
#   firmware  *.bin      -> run artifact + generic package `verdure-<component>`
#   showcase  dist.tar.gz-> run artifact + generic package `verdure-showcase`
```

And add one line to the header explaining the file's now-narrower role:

```
# This is the DEV builder: it builds whatever the mirror last synced and tags
# images by commit SHA. For a versioned release from a git tag, use
# release.yml instead.
```

- [ ] **Step 4: Run the verification script to confirm it passes**

```bash
python "<SCRATCH>/check_dev.py"
```

Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add infra/forgejo/build-and-push.yml && git commit -m "refactor(ci): rename dev-builder components to blazor/showcase/terra/flux"
```

---

### Task 6: Document the workflow in `forgejo-setup.md` and `README.md`

**Files:**
- Modify: `docs/forgejo-setup.md`
- Modify: `README.md:150`

**Interfaces:**
- Consumes: the workflow from Tasks 1–4 and the names from Task 5.
- Produces: nothing consumed later.

Guides follow a fixed structure (CLAUDE.md → Docs layout): `**Runs on:**` line,
numbered steps with verification, **each command in its own fenced block**,
troubleshooting, layout, design notes. Match it.

- [ ] **Step 1: Add the missing secrets section to step 7**

`docs/forgejo-setup.md` currently references `REGISTRY_TOKEN` at line 163 but
**never says how to create it** — a real gap. Replace the paragraph at lines
159–164 ("That template carries three jobs … no second secret.") with a
description of both templates and both secrets:

- Two templates now live in the repo:
  [`infra/forgejo/build-and-push.yml`](../infra/forgejo/build-and-push.yml) (dev
  builds from the mirrored HEAD, SHA-tagged) and
  [`infra/forgejo/release.yml`](../infra/forgejo/release.yml) (versioned builds
  from a `<component>-v<semver>` tag). Both go in `.forgejo/workflows/`.
- Both carry three jobs, one per toolchain, because `container:` is a per-job
  setting and .NET, PlatformIO and Node cannot share one.
- Two repo secrets, created under the Forgejo account at **Settings →
  Applications → Manage Access Tokens → Generate Token**, then added at the app
  repo's **Settings → Actions → Secrets**:

  | Secret | Scope | Used by |
  |---|---|---|
  | `REGISTRY_TOKEN` | `write:package` | both workflows, for the container and generic registries |
  | `FORGEJO_API_TOKEN` | `write:repository` | `release.yml` only, to trigger the mirror sync |

  Keep them separate: `REGISTRY_TOKEN` is handed to third-party actions
  (`docker/login-action`), so it stays minimal.

- [ ] **Step 2: Add a new step 9, "Cut a release"**

Insert after the existing step 8 ("Run a build and verify the image") and before
`### Checklist`. It must cover:

- Tag on **GitHub** as `<component>-v<semver>` (components: `blazor`,
  `showcase`, `atmos`, `terra`, `flux`), write the release notes there.
- In Forgejo: **Actions → Release → Run workflow**, and type the tags,
  space-separated. Its own fenced block:

  ```text
  blazor-v1.2.3 atmos-v0.4.1
  ```

- Explain that the run syncs the mirror itself and waits for those exact tags —
  no need to hit **Synchronize Now** first, and no need to wait for the mirror
  interval.
- **Verify:** the owner's **Packages** tab lists `<repo>/blazor` with `latest`,
  `1.2.3`, `1.2` and `1`, and `verdure-atmos` with versions `0.4.1` and
  `latest`. Then, in its own fenced block:

  ```bash
  docker pull git.thefipster.de/<owner>/<repo>/blazor:1.2
  ```

- One caution: the rolling tags assume you are releasing the newest version.
  Re-running an old tag moves `latest` backwards.

- [ ] **Step 3: Add the two new checklist rows**

In `### Checklist`, after "A manual workflow run completes and pushes an image":

```markdown
- [ ] A release dispatch publishes an image tagged `latest`, `X.Y.Z`, `X.Y` and `X`
- [ ] The release run's mirror sync succeeds (a `write:repository` token, not the registry one)
```

- [ ] **Step 4: Add the two troubleshooting entries**

In `## Troubleshooting`, matching the existing bold-lead-sentence style:

- **A release run times out waiting for a tag.** The mirror sync is queued, not
  synchronous, and the run polls for ten minutes. Confirm the tag exists on
  GitHub and is spelled exactly as dispatched; then check **Settings → Mirror
  Settings** in Forgejo. A 403 from the sync step means `FORGEJO_API_TOKEN`
  lacks `write:repository`.
- **A generic package upload returns 409.** A PUT over an existing filename
  conflicts. Both workflows delete before uploading, so this means the delete
  failed — almost always a `REGISTRY_TOKEN` without `write:package`.

- [ ] **Step 5: Update the "How it works" section**

The paragraph at lines 325–329 ("**CI is manual-only, on purpose.**") is still
true but now describes only half the picture. Extend it to say there are two
dispatch-only workflows — a dev builder that rebuilds the mirrored HEAD, and a
release workflow that syncs the mirror itself and builds named tags — and that a
scheduled reconciler was considered and rejected (link the spec) because manual
tagging means drift never accumulates.

- [ ] **Step 6: Update the repo tree in `README.md`**

At `README.md:150`, keep the existing line and add one below it, preserving the
box-drawing characters and column alignment of the surrounding block:

```text
│   │   ├── build-and-push.yml    CI dev-build template (goes in your app repo)
│   │   └── release.yml           CI release template (goes in your app repo)
```

Note the connector on the `build-and-push.yml` line changes from `└──` to `├──`.

- [ ] **Step 7: Verify the links resolve and the structure holds**

```bash
python -c "
import re,pathlib
d=pathlib.Path('docs/forgejo-setup.md').read_text(encoding='utf-8')
bad=[l for l in re.findall(r']\((\.\./[^)#]+)\)',d) if not (pathlib.Path('docs')/l).resolve().exists()]
print('BROKEN:',bad) if bad else print('links ok')
print('release.yml referenced:', 'release.yml' in d)
print('both secrets:', 'REGISTRY_TOKEN' in d and 'FORGEJO_API_TOKEN' in d)
print('README lists release.yml:', 'release.yml' in pathlib.Path('README.md').read_text(encoding='utf-8'))
"
```

Expected: `links ok`, and `True` on all three.

- [ ] **Step 8: Commit**

```bash
git add docs/forgejo-setup.md README.md && git commit -m "docs: document the release workflow and both CI secrets"
```

---

### Task 7: Update `CLAUDE.md` and shrink the CI-triggers roadmap

**Files:**
- Modify: `CLAUDE.md` (lines 317–320, 416–426, 427+)
- Rewrite: `docs/roadmap/ci-triggers.md`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: nothing. Final task — the repo's own guidance catches up with the change.

- [ ] **Step 1: Update the Node-written-down-twice bullet (CLAUDE.md:317)**

It currently says the runner label and `build-and-push.yml`'s Astro job name the
same tag. There is now a **third** place: `release.yml`'s `showcase` job pins
Node 24 through `setup-node`. Change "written down twice" to "three times" and
name all three, keeping the existing reasoning about picking an LTS line.

- [ ] **Step 2: Rewrite the "CI is manual-only" bullet (CLAUDE.md:416)**

Still manual-only, but now two workflows. It must state:

- `build-and-push.yml` — dev builds of the mirrored HEAD, SHA-tagged, per-toolchain
  tick-boxes, browsable run artifacts;
- `release.yml` — dispatched with `<component>-v<semver>` tags; it POSTs
  `mirror-sync` itself and polls for those exact refs, so a dispatched run can
  build a tag that did not exist when it started;
- five components across three toolchains: `blazor`, `showcase`, `atmos`,
  `terra`, `flux`;
- both keep the `== true || == 'true'` guard on boolean inputs;
- a scheduled reconciler was designed and rejected — manual tagging means there
  is no drift to reconcile.

- [ ] **Step 3: Update the "Two kinds of build output, two registries" bullet (CLAUDE.md:427)**

Add: a release publishes container images on exactly four tags (`latest`,
`X.Y.Z`, `X.Y`, `X`) with no SHA tag, the commit travelling as the
`org.opencontainers.image.revision` label; `showcase` publishes to **both**
registries from one build; and generic packages carry a `latest` version whose
files are rewritten each release. Keep the existing owner-scoping and 409 notes —
they still apply.

- [ ] **Step 4: Rewrite `docs/roadmap/ci-triggers.md`**

Per CLAUDE.md, the roadmap is forward-looking only; the spec is the historical
record. Reduce the file to what is genuinely still ahead:

- Retitle to reflect its remaining subject: nightly rebuilds.
- One short paragraph stating that tag-driven release builds **landed** —
  linking [`../superpowers/specs/2026-08-05-forgejo-release-workflow-design.md`](../superpowers/specs/2026-08-05-forgejo-release-workflow-design.md)
  for the design and [`../forgejo-setup.md`](../forgejo-setup.md) for the guide —
  and that the cron reconciler in this file's earlier version was **rejected**,
  with the spec holding the reasoning.
- Keep only the nightly section, since [`ci-supply-chain.md`](ci-supply-chain.md)
  depends on it for the CVE re-scan gap: compare the `:nightly` image's
  `org.opencontainers.image.revision` label against the mirrored HEAD, build only
  if they differ, never touch `latest`, and gate it behind the test job from
  [`ci-testing.md`](ci-testing.md).
- Delete the ledger, backfill-ordering, rolling-tag-guard and tag-prefix-table
  sections — they are either shipped or rejected.

- [ ] **Step 5: Verify nothing stale survives**

```bash
python -c "
import pathlib,sys
c=pathlib.Path('CLAUDE.md').read_text(encoding='utf-8')
r=pathlib.Path('docs/roadmap/ci-triggers.md').read_text(encoding='utf-8')
bad=[]
for t in ('written down\ntwice','written down twice'):
    if t in c: bad.append('CLAUDE.md still says '+repr(t))
for t in ('release.yml','blazor','showcase','terra','flux'):
    if t not in c: bad.append('CLAUDE.md never mentions '+t)
for t in ('registry is the build ledger','Rolling-tag caveat','on: schedule'):
    if t in r: bad.append('roadmap still contains '+repr(t))
if 'nightly' not in r.lower(): bad.append('roadmap lost the nightly section')
print('\n'.join(bad) if bad else 'PASS')
" </dev/null
```

Expected: `PASS`

- [ ] **Step 6: Verify the whole branch is consistent**

Re-run both workflow checks and confirm the diff touches only the intended files:

```bash
python "<SCRATCH>/check_release.py" infra/forgejo/release.yml && python "<SCRATCH>/check_dev.py" && git diff --stat origin/main
```

Expected: two `PASS` lines, and a diffstat listing exactly `CLAUDE.md`,
`README.md`, `docs/forgejo-setup.md`, `docs/roadmap/ci-triggers.md`,
`docs/superpowers/plans/2026-08-05-forgejo-release-workflow.md`,
`docs/superpowers/specs/2026-08-05-forgejo-release-workflow-design.md`,
`infra/forgejo/build-and-push.yml` and `infra/forgejo/release.yml`.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/roadmap/ci-triggers.md && git commit -m "docs: CI guidance for two workflows; shrink ci-triggers roadmap to nightly"
```

---

## Deferred to first run on the VM

These cannot be checked from Windows. Confirm on the first real dispatch; each
has a stated fallback in the spec:

1. `mirror-sync` is accepted on a pull-mirror repo with a `write:repository`
   token. Fallback: drop the sync step and let the tag-polling wait absorb the
   mirror interval.
2. Forgejo Actions supports `fromJSON` dynamic matrices. Fallback: a fixed matrix
   over all five components with step-level skips.
3. The authoritative YAML check is on the VM, not here:

```bash
docker compose run --rm --entrypoint forgejo-runner runner \
  validate --repository https://git.thefipster.de/<owner>/<repo>
```
