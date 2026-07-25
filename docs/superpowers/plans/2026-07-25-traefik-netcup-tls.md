# Traefik + netcup DNS-01 TLS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every infra-VM service a real domain name under `thefipster.de` with automatic Let's Encrypt wildcard TLS via the netcup DNS-01 challenge, and rewrite the repo's docs as a greenfield bare-server-to-current-state setup guide.

**Architecture:** A new `infra/traefik` stack terminates TLS for `git.thefipster.de` (Forgejo web + registry) and `dockge.thefipster.de`, holding one wildcard cert (`thefipster.de` + `*.thefipster.de`) issued via Traefik's built-in netcup DNS provider. Routing is by Docker labels on the target stacks over a shared external `proxy` network. Local name resolution is split-horizon on the UniFi Dream Router; the public netcup zone holds no A records.

**Tech Stack:** Traefik v3 (Docker provider, ACME DNS-01 via lego's `netcup` provider), Docker Compose, bash init scripts, UniFi Local DNS.

**Spec:** `docs/superpowers/specs/2026-07-25-internal-domains-traefik-design.md`

## Global Constraints

- Domain: `thefipster.de`, flat on the apex (`git.thefipster.de`, `dockge.thefipster.de`, `pve.thefipster.de`). The string `homelab` (as hostname) and `*.homelab.lan` must not survive anywhere except the spec/plan docs.
- IPs: Proxmox `.40`, infra VM `.41`, apps VM `.42` on `192.168.1.0/24`.
- netcup env vars (exact names, from lego): `NETCUP_CUSTOMER_NUMBER`, `NETCUP_API_KEY`, `NETCUP_API_PASSWORD`, `NETCUP_PROPAGATION_TIMEOUT=900`, `NETCUP_POLLING_INTERVAL=30`.
- Secrets: real values only in `.env` on the VM — already covered by the repo-root `.gitignore` (`.env`). Only `.env.example` with placeholders is committed. Never commit a real credential.
- Wildcard cert: `main: thefipster.de`, `sans: *.thefipster.de`, one per VM; staging CA first on new deployments.
- Shared Docker network name: `proxy` (external, created idempotently by init scripts).
- Image pinning style: major version only, matching existing stacks (`forgejo:11`, `dockge:1` → `traefik:v3`).
- Shell scripts: bash, `set -euo pipefail`, LF endings (enforced by `.gitattributes`), same `run_root` pattern as existing scripts.
- Greenfield: no migration/coexistence steps anywhere, in code or docs.
- All verification that needs the real VM/DNS/netcup account is listed as **on-VM verification** in `docs/traefik-setup.md`; repo-side verification is `docker compose config`, `bash -n`, and grep sweeps.

---

### Task 1: Traefik stack + init script

**Files:**
- Create: `infra/traefik/compose.yaml`
- Create: `infra/traefik/.env.example`
- Create: `scripts/init-traefik.sh`

**Interfaces:**
- Produces: external Docker network `proxy` (created by `init-traefik.sh` and expected by Tasks 2–3); entrypoint name `websecure` and certresolver name `letsencrypt` referenced by router labels in Tasks 2–3; data dir `/opt/traefik/letsencrypt` on the VM.

- [ ] **Step 1: Write `infra/traefik/compose.yaml`**

```yaml
# Traefik — reverse proxy + TLS termination for the INFRA VM.
#
# One wildcard certificate (thefipster.de + *.thefipster.de) from Let's
# Encrypt via the DNS-01 challenge against the netcup DNS API. Nothing is
# exposed to the internet: DNS-01 needs no inbound connectivity, and the
# public zone never holds A records for the lab (see docs/traefik-setup.md).
#
# Routing is label-based: stacks join the external `proxy` network and add
# traefik.* labels (see infra/forgejo & infra/dockge). Port 80 only redirects
# to HTTPS.
#
# Deploy (on the infra VM): scripts/init-traefik.sh, then fill in .env and
# `docker compose up -d` (or start it from Dockge).

name: traefik

services:
  traefik:
    image: traefik:v3            # pin the major; same policy as other stacks
    restart: unless-stopped
    command:
      # --- providers -------------------------------------------------------
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=proxy
      # --- entrypoints -----------------------------------------------------
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      # Every websecure router gets TLS from the letsencrypt resolver and is
      # covered by the one wildcard cert below — no per-router TLS labels.
      - --entrypoints.websecure.http.tls.certresolver=letsencrypt
      - --entrypoints.websecure.http.tls.domains[0].main=thefipster.de
      - --entrypoints.websecure.http.tls.domains[0].sans=*.thefipster.de
      # --- ACME (Let's Encrypt via netcup DNS-01) --------------------------
      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL:?set ACME_EMAIL in .env}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.dnschallenge=true
      - --certificatesresolvers.letsencrypt.acme.dnschallenge.provider=netcup
      # Check propagation against public resolvers, not the UDR: the LAN's
      # split-horizon wildcard would confuse the lookup for our own domain.
      - --certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53
      # STAGING vs PRODUCTION — first bring-up uses the staging CA (untrusted
      # certs, generous rate limits) to prove the netcup credentials and
      # propagation timing. Once staging succeeds: comment the caserver line
      # out, delete acme.json, and `docker compose up -d --force-recreate`.
      # See docs/traefik-setup.md.
      - --certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory
    environment:
      NETCUP_CUSTOMER_NUMBER: ${NETCUP_CUSTOMER_NUMBER:?set in .env}
      NETCUP_API_KEY: ${NETCUP_API_KEY:?set in .env}
      NETCUP_API_PASSWORD: ${NETCUP_API_PASSWORD:?set in .env}
      # netcup's nameservers publish TXT records slowly (often ~10 min).
      # Without a generous window, first issuance fails on propagation checks.
      NETCUP_PROPAGATION_TIMEOUT: "900"
      NETCUP_POLLING_INTERVAL: "30"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      # Read-only socket: Traefik only watches containers/labels.
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # acme.json (account key + certs) lives here — survives recreation.
      - /opt/traefik/letsencrypt:/letsencrypt
    networks:
      - proxy

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Write `infra/traefik/.env.example`**

```bash
# Copy to .env (gitignored) on the infra VM and fill in real values.
# netcup credentials: CCP (customer control panel) → Master Data → API —
# generate an API key + API password; the customer number is your CCP login.

# Let's Encrypt account email (expiry mails etc.)
ACME_EMAIL=you@example.com

NETCUP_CUSTOMER_NUMBER=123456
NETCUP_API_KEY=changeme
NETCUP_API_PASSWORD=changeme
```

- [ ] **Step 3: Write `scripts/init-traefik.sh`**

```bash
#!/usr/bin/env bash
#
# init-traefik.sh — set up the Traefik reverse-proxy stack on the infra VM.
#
# Assumes Docker is installed (run scripts/init-host.sh first). Steps:
#   1. Create the shared `proxy` Docker network (all proxied stacks join it).
#   2. Create the persistent ACME dir under /opt/traefik.
#   3. Seed infra/traefik/.env from .env.example if missing (you fill it in).
#   4. Symlink the stack into /opt/stacks so Dockge can manage it.
#
# Usage (from the repo root):
#   scripts/init-traefik.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/infra/traefik"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found — run scripts/init-host.sh first." >&2
  exit 1
fi

echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

echo "==> Creating persistent ACME dir /opt/traefik/letsencrypt"
run_root mkdir -p /opt/traefik/letsencrypt

if [ ! -f "${STACK_DIR}/.env" ]; then
  echo "==> Seeding ${STACK_DIR}/.env from .env.example — FILL IN REAL VALUES"
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
fi

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
echo "==> Linking the Traefik stack into ${STACKS_DIR}/traefik (for Dockge)"
run_root mkdir -p "${STACKS_DIR}"
run_root ln -sfn "${STACK_DIR}" "${STACKS_DIR}/traefik"

echo
echo "Done. Next (see docs/traefik-setup.md):"
echo "  1. Edit ${STACK_DIR}/.env with your netcup credentials."
echo "  2. cd ${STACK_DIR} && docker compose up -d   (staging CA first)"
echo "  3. Watch: docker compose logs -f traefik — wait for the staging cert."
echo "  4. Switch to production per the guide."
```

- [ ] **Step 4: Verify**

Run (repo root, bash):
```bash
bash -n scripts/init-traefik.sh && echo SCRIPT_OK
cd infra/traefik && docker compose --env-file .env.example config -q && echo COMPOSE_OK
```
Expected: `SCRIPT_OK` and `COMPOSE_OK` (external network `proxy` need not exist for `config`).

- [ ] **Step 5: Commit**

```bash
git add infra/traefik scripts/init-traefik.sh
git commit -m "feat: add Traefik stack with netcup DNS-01 wildcard TLS"
```

---

### Task 2: Forgejo behind Traefik

**Files:**
- Modify: `infra/forgejo/compose.yaml`
- Modify: `scripts/init-forgejo.sh`

**Interfaces:**
- Consumes: external network `proxy`, entrypoint `websecure` (Task 1).
- Produces: Forgejo served at `https://git.thefipster.de` (web, API, registry); SSH still host port 222.

- [ ] **Step 1: Update `infra/forgejo/compose.yaml`**

In the `forgejo:` service, replace the ROOT_URL comment + env block:

```yaml
      # ROOT_URL matters: it's what the registry/clone URLs advertise. Traefik
      # terminates TLS for git.thefipster.de and forwards to this container's
      # :3000 over the shared `proxy` network (see infra/traefik).
      FORGEJO__server__ROOT_URL: "https://git.thefipster.de/"
      FORGEJO__server__DOMAIN: "git.thefipster.de"
```

Replace the `ports:` block (drop 3000, keep SSH):

```yaml
    ports:
      - "222:22"      # git over SSH (host 222 -> container 22), optional
```

Add labels to the `forgejo:` service and join the proxy network:

```yaml
    labels:
      traefik.enable: "true"
      traefik.http.routers.forgejo.rule: Host(`git.thefipster.de`)
      traefik.http.routers.forgejo.entrypoints: websecure
      traefik.http.services.forgejo.loadbalancer.server.port: "3000"
    networks:
      - forgejo-net
      - proxy
```

At the bottom, declare the external network alongside the existing one:

```yaml
networks:
  forgejo-net:
    driver: bridge
  proxy:
    external: true
```

Also update the registry comment at the top of the service ("served on the same port as the web UI (3000)" stays true — append "— reached via Traefik at https://git.thefipster.de").

- [ ] **Step 2: Strip the insecure-registry machinery from `scripts/init-forgejo.sh`**

Delete: the `REGISTRY_ADDR` variable and its usage-comment lines, the entire `==> Allowing insecure (HTTP) registry` block (daemon.json handling, lines 62–77 in the current file), and the `==> Restarting Docker` block (lines 79–80) — Docker no longer needs a restart. Update the header comment: step 3 becomes the Dockge symlink. The script keeps: data tree creation, DOCKER_GID recording, `/opt/stacks/forgejo` symlink, and the "Next steps" echo (reword to mention Traefik must be up first and the UI URL `https://git.thefipster.de`).

- [ ] **Step 3: Verify**

```bash
bash -n scripts/init-forgejo.sh && echo SCRIPT_OK
cd infra/forgejo && DOCKER_GID=999 docker compose config -q && echo COMPOSE_OK
grep -n "homelab\|3000:3000\|REGISTRY_ADDR\|insecure" compose.yaml ../../scripts/init-forgejo.sh; echo "grep exit $? (want 1 = no matches)"
```
Expected: `SCRIPT_OK`, `COMPOSE_OK`, grep exit 1.

- [ ] **Step 4: Commit**

```bash
git add infra/forgejo/compose.yaml scripts/init-forgejo.sh
git commit -m "feat: serve Forgejo via Traefik at git.thefipster.de, drop insecure registry"
```

---

### Task 3: Dockge behind Traefik

**Files:**
- Modify: `infra/dockge/compose.yaml`
- Modify: `scripts/init-dockge.sh`

**Interfaces:**
- Consumes: external network `proxy`, entrypoint `websecure` (Task 1).
- Produces: Dockge at `https://dockge.thefipster.de`; `init-dockge.sh` also creates the `proxy` network so Dockge can start before Traefik exists.

- [ ] **Step 1: Update `infra/dockge/compose.yaml`**

Remove the `ports:` block. Add to the `dockge:` service:

```yaml
    labels:
      traefik.enable: "true"
      traefik.http.routers.dockge.rule: Host(`dockge.thefipster.de`)
      traefik.http.routers.dockge.entrypoints: websecure
      traefik.http.services.dockge.loadbalancer.server.port: "5001"
    networks:
      - proxy
```

And at file bottom:

```yaml
networks:
  proxy:
    external: true
```

Update the header comment: the UI line becomes `#   UI: https://dockge.thefipster.de   (via the Traefik stack — see infra/traefik)` and note that until Traefik is up, the UI is unreachable (bring stacks up via CLI during bootstrap, or temporarily `docker compose port`-publish if debugging).

- [ ] **Step 2: Create the proxy network in `scripts/init-dockge.sh`**

After the docker-presence check, add:

```bash
# Dockge's compose joins the external `proxy` network (Traefik routes to it),
# so the network must exist even though Traefik comes up later.
echo "==> Ensuring the shared 'proxy' network exists"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy
```

Update the final echo: `Dockge is coming up — reachable at https://dockge.thefipster.de once the Traefik stack is up (scripts/init-traefik.sh).`

- [ ] **Step 3: Verify**

```bash
bash -n scripts/init-dockge.sh && echo SCRIPT_OK
cd infra/dockge && docker compose config -q && echo COMPOSE_OK
grep -n "5001:5001\|homelab" compose.yaml; echo "grep exit $? (want 1)"
```

- [ ] **Step 4: Commit**

```bash
git add infra/dockge/compose.yaml scripts/init-dockge.sh
git commit -m "feat: serve Dockge via Traefik at dockge.thefipster.de"
```

---

### Task 4: New guide — docs/traefik-setup.md

**Files:**
- Create: `docs/traefik-setup.md`

**Interfaces:**
- Consumes: stack + script from Task 1.
- Produces: the guide referenced by Tasks 5–8 as `docs/traefik-setup.md`.

- [ ] **Step 1: Write the guide** covering, in order (write full prose, no placeholders):

1. **What/why** — one Traefik per VM terminates TLS with a Let's Encrypt wildcard (`thefipster.de` + `*.thefipster.de`) via DNS-01 against netcup; LAN-only, nothing inbound; public zone stays empty of A records (only temporary `_acme-challenge` TXT records appear during issuance). CT-log note: only the wildcard name is publicly logged.
2. **Prerequisites** — domain on netcup nameservers; netcup API credentials (CCP → Master Data → API: generate API key + API password; customer number = CCP login number); DNS records from `wildcard-dns-udr.md` in place; `init-host.sh` run.
3. **Bring-up** — `scripts/init-traefik.sh`, edit `.env`, `docker compose up -d`, `docker compose logs -f traefik`. State plainly: **first issuance takes 10–15 minutes** because netcup's nameservers propagate slowly; the compose sets `NETCUP_PROPAGATION_TIMEOUT=900` / `NETCUP_POLLING_INTERVAL=30` for exactly this reason.
4. **Staging → production** — the compose ships pointing at the staging CA. Verify a staging cert arrives (`docker compose exec traefik cat /letsencrypt/acme.json | grep -o '"main":"[^"]*"'`, and `curl -kIs https://git.thefipster.de` shows issuer `(STAGING) Let's Encrypt`). Then: comment out the `caserver` line in `compose.yaml`, `sudo rm /opt/traefik/letsencrypt/acme.json`, `docker compose up -d --force-recreate`, wait again, confirm `curl -Is https://git.thefipster.de` now succeeds without `-k`.
5. **Verification checklist** (on-VM) — `curl -I https://git.thefipster.de` and `https://dockge.thefipster.de` return the production cert; `docker login git.thefipster.de` from a clean daemon works with **no** insecure-registries config anywhere.
6. **Troubleshooting** — propagation timeout (raise `NETCUP_PROPAGATION_TIMEOUT`; confirm the domain actually uses netcup NS: `dig NS thefipster.de +short`); rate limits (stay on staging until it works — production allows 5 duplicate certs/week); wrong credentials (netcup API returns auth errors in the Traefik log, grep `acme`).
7. **Apps VM later (Coolify)** — apps-ready note: Coolify's bundled Traefik gets the same three `NETCUP_*` env vars + wildcard config and issues its own cert independently; wildcard DNS `*.thefipster.de → .42` already points at it. No cert copying between VMs.
8. **Escape hatch** — if netcup propagation ever becomes unbearable: CNAME `_acme-challenge.thefipster.de` to a faster ACME-DNS service (acme-dns, deSEC); documented option only.

- [ ] **Step 2: Verify**

```bash
grep -n "homelab\|TBD\|TODO" docs/traefik-setup.md; echo "grep exit $? (want 1)"
```

- [ ] **Step 3: Commit**

```bash
git add docs/traefik-setup.md
git commit -m "docs: add Traefik + netcup DNS-01 setup guide"
```

---

### Task 5: Rewrite docs/wildcard-dns-udr.md for thefipster.de

**Files:**
- Modify: `docs/wildcard-dns-udr.md`

- [ ] **Step 1: Re-root the guide.** Changes, keeping structure and UniFi instructions intact:
  - Goal/diagram: `foo.thefipster.de` / `bar.thefipster.de` → apps VM (.42); wildcard record `*.thefipster.de` → `192.168.1.42`.
  - Add a new subsection **"Exact host records for infra services"** after the wildcard record section, with a table: `git.thefipster.de → 192.168.1.41`, `dockge.thefipster.de → 192.168.1.41`, `pve.thefipster.de → 192.168.1.40` (optional). Explain: a specific Host (A) record beats the wildcard, which is how infra names escape the apps-VM wildcard.
  - Note that this is **split-horizon**: these names exist only on the LAN; the public netcup zone stays empty of A records, so nothing about the lab is exposed. Because `thefipster.de` serves nothing public, the wildcard can't shadow anything.
  - Replace the old apex caveat sentence with: the wildcard covers `foo.thefipster.de` but not the bare apex `thefipster.de` — add an apex record only if you ever need it.
  - Verification commands: `foo.homelab.lan` → `foo.thefipster.de` throughout.
  - Replace the entire **"TLS (the other half, for later)"** section with a short **"TLS"** section: TLS is real and automated — Traefik on the infra VM holds a Let's Encrypt wildcard via DNS-01 against netcup; see [traefik-setup.md](traefik-setup.md).

- [ ] **Step 2: Verify**

```bash
grep -n "homelab" docs/wildcard-dns-udr.md; echo "grep exit $? (want 1)"
```

- [ ] **Step 3: Commit**

```bash
git add docs/wildcard-dns-udr.md
git commit -m "docs: re-root DNS guide to thefipster.de with infra host overrides"
```

---

### Task 6: Rewrite docs/forgejo-setup.md — greenfield, HTTPS from first run

**Files:**
- Modify: `docs/forgejo-setup.md`

- [ ] **Step 1: Apply the rewrite.** Precise changes:
  - Intro: drop "still plain HTTP for now… later TODO"; state Forgejo sits behind the Traefik stack (link `traefik-setup.md`) at `https://git.thefipster.de` from first run.
  - Part 0 script sequence becomes: `init-host.sh` → `init-dockge.sh` → `init-traefik.sh` (**with the note: bring up Traefik and complete the staging→production cert flow BEFORE Forgejo's first run — first-run happens over HTTPS**) → `init-forgejo.sh`. Update the Dockge note ("Does Dockge replace init-forgejo.sh?") to drop "allowing the insecure registry on the host daemon" from the list.
  - `init-forgejo.sh` description: now two bullets only (data tree + DOCKER_GID); the insecure-registry bullet is deleted entirely.
  - Part A: `docker compose up -d db forgejo` unchanged; first-run URL becomes `https://git.thefipster.de` (no port-3000 reachability note, no ssh tunnel note — Traefik serves it).
  - Part B runner registration: `--instance https://git.thefipster.de`. Rewrite the "Why the host name" callout: the registered address is baked into clone/registry URLs used by the runner, the host daemon, and job containers; `https://git.thefipster.de` resolves for all three via the UDR's exact host record, and TLS is publicly trusted so no daemon config is needed anywhere.
  - Part F: pull commands become `docker login git.thefipster.de` / `docker pull git.thefipster.de/<owner>/<repo>:latest`. Delete the **"Insecure registry note"** section and the trailing TODO blockquote entirely — replace with one sentence: the registry is plain HTTPS with a trusted cert, so any Docker daemon can pull with zero configuration.
  - Layout table `~/homelab` clone path: keep the clone dir name `home-lab` per the repo name (`git clone <this-repo>` → `cd home-lab`), and fix the two `cd ~/homelab/...` occurrences accordingly.

- [ ] **Step 2: Verify**

```bash
grep -n "homelab\|:3000\|insecure" docs/forgejo-setup.md; echo "grep exit $? (want 1)"
```
(`localhost:3000` references must also be gone — the container port is an internal detail now.)

- [ ] **Step 3: Commit**

```bash
git add docs/forgejo-setup.md
git commit -m "docs: rewrite Forgejo guide — HTTPS via Traefik from first run"
```

---

### Task 7: Update docs/proxmox-setup.md

**Files:**
- Modify: `docs/proxmox-setup.md`

- [ ] **Step 1: Apply the changes.**
  - Header diagram: `pve.thefipster.de · .40`.
  - Part 2 management network: **Hostname (FQDN):** `pve.thefipster.de`; DNS note becomes "your router (`192.168.1.1`) so `*.thefipster.de` resolves".
  - Part 6 DNS records block becomes the final scheme:
    - `git.thefipster.de` → `192.168.1.41` (infra VM — Forgejo behind Traefik)
    - `dockge.thefipster.de` → `192.168.1.41` (infra VM — Dockge behind Traefik)
    - `*.thefipster.de` → `192.168.1.42` (apps VM — Coolify routes by Host header)
    - optional `pve.thefipster.de` → `192.168.1.40`
  - Delete the "Later, when Forgejo moves behind a TLS reverse proxy…" blockquote entirely.
  - Next steps: infra VM sequence gains Traefik: `init-host.sh` → Dockge → **Traefik ([traefik-setup.md](traefik-setup.md))** → Forgejo.

- [ ] **Step 2: Verify**

```bash
grep -n "homelab" docs/proxmox-setup.md; echo "grep exit $? (want 1)"
```

- [ ] **Step 3: Commit**

```bash
git add docs/proxmox-setup.md
git commit -m "docs: re-root Proxmox guide to thefipster.de, final DNS scheme"
```

---

### Task 8: Update README.md + final sweep

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Apply the changes.**
  - Architecture diagram: DNS line becomes `UniFi Dream Router — DHCP + DNS (git/dockge → infra VM, *.thefipster.de → apps VM)`; Proxmox line `pve.thefipster.de`; infra VM box gains a `Traefik: TLS + routing` line.
  - Layer table: infra VM row becomes "Traefik + Forgejo + Dockge" with TLS termination mentioned.
  - Networking & DNS section: names + HTTPS —
    - `git.thefipster.de` → infra VM (Forgejo web/registry, HTTPS via Traefik)
    - `dockge.thefipster.de` → infra VM (Dockge UI)
    - `*.thefipster.de` → apps VM (Coolify, zero DNS work per app)
    - One sentence: certs are Let's Encrypt wildcards via DNS-01 against netcup — see [docs/traefik-setup.md](docs/traefik-setup.md); nothing is exposed to the internet.
  - Repository layout tree: add `docs/traefik-setup.md`, `scripts/init-traefik.sh`, and `infra/traefik/` (compose.yaml + .env.example).
  - Build order: insert `3. **Traefik** (docs/traefik-setup.md) — reverse proxy + wildcard TLS on the infra VM` before Forgejo; renumber.
  - Status table: replace the TLS-undecided row with `| Traefik + Let's Encrypt (netcup DNS-01) | ✅ designed & built (this repo) |`; drop the trailing "Still plain HTTP throughout" blockquote.

- [ ] **Step 2: Repo-wide final sweep**

```bash
grep -rn "homelab\|\.lan\|insecure-registr" --include="*.md" --include="*.yaml" --include="*.yml" --include="*.sh" . | grep -v "docs/superpowers/" ; echo "grep exit $? (want 1)"
```
Expected: no matches outside `docs/superpowers/` (spec + plan legitimately mention the old names). Fix any stragglers found.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README for domain scheme + Traefik milestone"
```

---

## On-VM verification (from the spec — happens at deploy time, not in this repo)

- `curl -I https://git.thefipster.de` and `https://dockge.thefipster.de` serve a Let's Encrypt production cert.
- `docker login git.thefipster.de` succeeds from a clean daemon.
- An Actions build pushes to `git.thefipster.de/<owner>/<repo>`.

These live as the checklist inside `docs/traefik-setup.md` (Task 4).
