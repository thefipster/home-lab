# Guide replay review — 2026-08-01

A full replay of the build order on **fresh hardware** — the target machine,
less one root drive, so `rpool` is a single disk rather than the mirrored pair
[proxmox-setup.md](../proxmox-setup.md) assumes. Everything else matches the
[hardware spec](../superpowers/specs/2026-07-31-hardware-specs-design.md).

Each finding below states what the replay hit, whether it holds up against the
repo as written, and what to change. Cross-cutting items (the Part 7 split,
build order, README) follow the per-guide sections.

Legend: **Confirmed** — reproducible from the repo as written.
**Confirmed, with nuance** — real issue, but the fix touches a design decision.
**Answered** — the finding was a question; the answer is the deliverable.

---

## 1. Proxmox guide — `by-id` listing shows each disk more than once

**Finding:** `ls -l /dev/disk/by-id/ | grep -v -- '-part'`
([proxmox-setup.md, Part 3](../proxmox-setup.md#part-3--post-install-housekeeping))
lists multiple entries per physical disk, and the guide gives no way to tell
that they are the same drive.

**Status: Confirmed.** udev writes one symlink per identifier it can derive,
and a SATA disk exposes at least two:

- `ata-<MODEL>_<SERIAL>` — from the ATA IDENTIFY model + serial strings.
- `wwn-0x…` — the World Wide Name in the drive firmware.

Both resolve to the same `../../sdX`, and on Crucial drives the WWN is derived
from the serial, so `ata-CT500MX500SSD1_2022E2A7651D` and
`wwn-0x500a0751e2a7651d` visibly share their tail. A reader who does not know
this counts six symlinks for three drives and has no way to pair them.

**Fix:** say which form to use and why. Both are equally stable across boots —
that is the whole point of `by-id` over `sdX` — but `zpool status` prints the
name the pool was created with, and that output is what tells you **which of
four physically identical drives to unplug**. `ata-…` carries the model and the
serial printed on the label; `wwn-0x…` does not get you there without a lookup.
Prefer `ata-…`, and note that entries resolving to the same `../../sdX` are one
disk.

## 2. Proxmox guide — `zpool create` fails on disks that already hold a filesystem

**Finding:** the three `zpool create` commands in Part 3 fail when the drives
carry a recognisable filesystem signature. The replay hit this on both SATA
pairs, which had been formatted exFAT.

**Status: Confirmed.** This is ZFS's safety interlock, not a fault — it refuses
a disk with a filesystem signature because that usually means the wrong device
was named. The guide never mentions it, so the first thing a reader meets after
the "wipes the target disk" warning is a command that refuses to run, with
`-f` as the obvious-looking escape.

**Fix:** document the interlock, and steer away from `-f`. `-f` tells ZFS to
ignore the signature, but the old superblock and partition table stay on disk
underneath ZFS's labels, where `blkid`, `lsblk -f` and the Proxmox disk view
will keep reporting the drive as exFAT — confusion at exactly the wrong moment.
`wipefs -a` on the **whole** disk (no `-part1`) removes both the signature and
the partition table, after which the original `zpool create` succeeds
unchanged. Include the read-only mount check before wiping, since this is the
one step in the guide that destroys data the reader might still want.

## 3. Proxmox guide — Part 7 belongs to the VMs, not to the hypervisor

**Finding:** Part 7 should be split per VM and moved: the infra half between
[wildcard-dns-udr.md](../wildcard-dns-udr.md) and
[traefik-setup.md](../traefik-setup.md), the apps half between
[uptime-kuma-setup.md](../uptime-kuma-setup.md) and
[coolify-setup.md](../coolify-setup.md).

**Status: Confirmed.** Every guide carries a `**Runs on:**` line naming the
machine whose shell you are in, and `proxmox-setup.md` says *the bare server,
then the Proxmox host shell*. Part 7 is the one section that violates its own
guide's header: it runs in **two** guest shells, neither of which is the host.

It is also mis-ordered. The build order runs Proxmox → DNS → Traefik, but Part 7
sits inside step 1, so the reader provisions both VMs before the DNS step —
then does nothing with the apps VM for seven guides. The apps half is dead
weight held across the entire infra build, and it is the reason
[coolify-setup.md](../coolify-setup.md) opens by restating it.

**Fix:** two new guides, each with a single `**Runs on:**` machine.

- **`docs/infra-vm-setup.md`** — clone, `init-host.sh`, `init-docker.sh`, the
  docker-group re-login, `init-unattended-upgrades.sh`. Build-order position 3,
  before Traefik.
- **`docs/apps-vm-setup.md`** — clone, `init-host.sh`,
  `init-unattended-upgrades.sh`, and the data-disk mount (finding 4).
  Build-order position 9, before Coolify.

Part 7 then disappears from `proxmox-setup.md` and Parts 8–10 renumber to 7–9.
That renumbering is the bulk of the work: the `#part-N--…` anchors are
referenced from the README, five guides, the backup roadmap, the alert rules and
three scripts. See [Cross-cutting](#cross-cutting).

## 4. Proxmox / Coolify guides — the apps VM's first two steps are in the wrong guide

**Finding:** [coolify-setup.md](../coolify-setup.md) steps 1 and 2 should merge
into the apps VM setup guide.

**Status: Confirmed.** Step 1 is a restatement of `proxmox-setup.md` Part 7 that
already links back to it, which is precisely the Part 0 duplication the
[2026-07-26 review](2026-07-26-guide-replay.md#4-forgejo-guide--part-0-duplicates-the-previous-guides)
collapsed everywhere else — it grew back here because Part 7 had nowhere better
to send the reader. Step 2 (mount the 300 GB disk at `/data`) is machine setup,
not Coolify setup: it must happen before the installer runs, and it would be
required on this VM even if Coolify were never installed.

**Fix:** both move into `docs/apps-vm-setup.md` (finding 3). `coolify-setup.md`
then opens the way every other stack guide does — a one-line prerequisite
pointing at the previous guide — and its remaining steps renumber.

## 5. Traefik guide — the HTTP redirect returns 308, not 301

**Finding:** [traefik-setup.md:126](../traefik-setup.md) says to expect
`HTTP/1.1 301 Moved Permanently`; the replay got `HTTP/1.1 308 Permanent
Redirect`.

**Status: Confirmed.** The redirect comes from
`--entrypoints.web.http.redirections.entrypoint.*` in
[infra/traefik/compose.yaml:65](../../infra/traefik/compose.yaml), and Traefik
issues **308** for a permanent entrypoint redirection. 301 permits a client to
rewrite the method to GET; 308 does not, which is why Traefik chose it. The
guide is simply wrong, and this is the kind of wrong that makes a reader stop
and hunt for a misconfiguration that does not exist.

**Fix:** `308 Permanent Redirect` in both the step and the checklist row.

## 6. Grafana guide — two verification steps that cost more than they prove

**Finding:** the Loki `wget` check and the Alloy `ssh -L` tunnel should be
removed from the verification path.

**Status: Confirmed.** Both are in
[grafana-setup.md, step 4](../grafana-setup.md#4-verify-the-platform):

- `docker compose exec grafana wget -qO- http://loki:3100/ready` is redundant
  by step 7, where `{job="docker"}` in Explore → Loki proves ingestion,
  storage **and** query in one action. A `ready` endpoint that answers proves
  strictly less. (The check is also a survivor of
  [2026-07-26 item 8](2026-07-26-guide-replay.md#8-grafana-guide--loki-readiness-check-uses-wget-that-isnt-in-the-image),
  which fixed *which container it runs from* rather than asking whether it
  earned its place.)
- `ssh -L 12345:127.0.0.1:12345 <infra-vm>` interrupts a browser-based
  verification to set up a port forward, and every component it asks about is
  already implied by the checks around it.

**Fix:** drop both from step 4 and from the checklist. **Keep the tunnel
command** — move it into Troubleshooting, which already tells the reader to
"check Alloy's component health through the tunnel" and would otherwise be
naming a tool the guide no longer shows. It is a debugging entry point, not a
verification step, and that is the section for it.

## 7. Grafana guide — two secrets the reader has to go find by hand

**Finding:** there should be a command that prints the generated
`GRAFANA_ADMIN_PASSWORD`, the way
[authentik-setup.md](../authentik-setup.md) does for `akadmin`. And step 5
should offer a `nano` command for editing `.env` with the OIDC client id and
secret.

**Status: Confirmed.** `init-monitoring.sh` generates
`GRAFANA_ADMIN_PASSWORD` into `infra/monitoring/.env` and never prints it, yet
[step 4](../grafana-setup.md#4-verify-the-platform) says to "log in as `admin`
with `GRAFANA_ADMIN_PASSWORD` from `.env`" — leaving the reader to work out the
`grep` themselves, mid-verification, at the one point where the break-glass
login is the only way in. The Authentik guide already sets the precedent for
printing it.

Step 5 has the matching gap in the other direction: it shows the three OIDC
lines as *file content* with an explicit "not commands to run", then never says
how to get them into the file. Every other guide that edits a `.env` gives the
`nano` command.

**Fix:** add a fenced command printing the admin password before the browser
login, and a `nano infra/monitoring/.env` step before the OIDC block.

## 8. Uptime Kuma guide — starts the stack from a path no other guide uses

**Finding:** [uptime-kuma-setup.md, step 3](../uptime-kuma-setup.md#3-start-the-stack)
runs `cd /opt/stacks/uptime-kuma && docker compose up -d`, while every other
guide starts from the repo checkout.

**Status: Confirmed.** Grafana, Forgejo, Authentik and Traefik all `cd` into
`~/home-lab/infra/<stack>`; Kuma is the only one that goes through the Dockge
symlink. It also breaks two conventions at once — the
[2026-07-26 template](2026-07-26-guide-replay.md#guide-template) requires each
command in its own fenced block, and this line chains `cd` with the command it
exists to set up.

The path difference is cosmetic (`/opt/stacks/uptime-kuma` is a symlink into the
checkout, so both resolve to the same compose file) but the *convention* is not:
the repo is the source of truth and Dockge only drives start/stop/logs. Starting
a stack through the symlink reads as though the symlink were the install.

**Fix:** two blocks, `cd ~/home-lab/infra/uptime-kuma` then
`docker compose up -d`, matching the other four.

## 9. Coolify guide — step 6 describes a UI that does not exist

**Finding:** step 6 says to enter the netcup credentials in Coolify's UI at
*Settings → Proxy*. There is no proxy section under Settings, and no
credentials form anywhere in Coolify.

**Status: Confirmed — the most serious item in this replay.** Three separate
errors compound:

1. **The path is wrong.** Proxy configuration is per-server, at
   *Servers → \<server\> → Proxy*, not under Settings.
2. **There is no form.** That page exposes the Traefik container's
   `docker-compose` YAML in an editor plus a list of file-provider dynamic
   configs (`coolify.yaml`, `default_redirect_503.yaml`). Credentials are
   entered as an `environment:` block in the compose — there are no fields for
   them, and the dynamic configs cannot carry them, since a file provider
   declares routers and middlewares but sets no environment variables and no
   CLI flags.
3. **The step that actually matters is missing entirely.** Coolify's proxy
   ships with the **HTTP-01** challenge. Nothing in step 6 switches it to
   DNS-01, so following the guide exactly leaves a proxy that cannot issue a
   wildcard at all — credentials or no credentials. Let's Encrypt does not
   issue wildcards over HTTP-01.

Upstream documents the whole procedure as a compose edit
([DNS challenge](https://coolify.io/docs/knowledge-base/proxy/traefik/dns-challenge),
[wildcard certs](https://coolify.io/docs/knowledge-base/proxy/traefik/wildcard-certs)).

**Fix:** rewrite step 6 as the edit it really is — replace the `httpchallenge`
flags with the netcup `dnschallenge` set, add the `NETCUP_*` environment block,
and declare the wildcard at the entrypoint. Two lab-specific deviations from
upstream's instructions must be called out, because copying their snippet
verbatim breaks here:

- **Coolify's entrypoints are `http`/`https`**, not the `web`/`websecure` this
  repo's own Traefik uses. An entrypoint name copied from
  `infra/traefik/compose.yaml` silently matches nothing.
- **Upstream's label block sets `tls.domains[0].sans=*.example.com` beside a
  `main` of the apex.** That requests apex + wildcard, which needs two TXT
  records at the same `_acme-challenge` FQDN — the exact race netcup's
  non-atomic zone updates lose, and the reason
  [infra/traefik/compose.yaml:77](../../infra/traefik/compose.yaml) declares
  `main=*.thefipster.de` with no SAN. Wildcard only, here too.

The propagation knobs carry over unchanged (`NETCUP_PROPAGATION_TIMEOUT=900`,
`NETCUP_POLLING_INTERVAL=30`) — without them first issuance fails on netcup's
~10 minute publish delay, which on the infra VM is already documented and on
this VM currently is not.

**One caveat to record rather than solve:** Coolify regenerates this compose
from its own store, and
[a closed issue](https://github.com/coollabsio/coolify/issues/3018) reports
server revalidation wiping custom proxy edits. That report is against a 4.0
beta and is probably long fixed, but it has not been verified on the version
this lab runs. This is the real justification for `apps/.env` existing — it is
the recovery copy when Coolify eats the config, which is a better reason than
"the repo's record of what is required" and should replace it in
[apps/.env.example](../../apps/.env.example).

## 10. Authentik — what would moving to a 2026 release cost?

**Finding:** the stack pins `2025.6`. Should it move to 2026, and what is the
impact?

**Status: Answered — and the premise is off by one release.** Upstream's current
train is `2025.6` → … → `2025.12` → `2026.2` → `2026.5`. Almost the entire cost
sits in **2025.12**, not in either 2026 release:

| Release | What it costs this lab |
|---|---|
| **2025.12** | **Storage rework** — media moves from `/media` to `/data/media` and is served under `/files`, so the `/opt/authentik/media:/media` mounts on **both** server and worker change, and `init-authentik.sh` changes with them. **RBAC rework** — group names must be unique *before* the upgrade or the migration fails; `Group.parent` becomes a many-to-many `Group.parents`; permissions must attach to a role. |
| **2026.2** | SCIM group-sync filtering changed. This lab runs no SCIM provider — no impact. |
| **2026.5** | Default listen address `0.0.0.0` → `[::]`; `AUTHENTIK_POSTGRESQL__CONN_OPTIONS` deprecated. Neither is set here — no impact. |

**The distinction that matters:** upstream requires upgrades to be performed
**sequentially**, and that constraint applies to the *running instance* — not
to this repo. Every guide here describes a from-scratch bring-up, so a fresh
build at `2026.5` steps through nothing; it just needs a compose that matches
the post-2025.12 storage layout. The sequential walk is a **live-lab operation**
that no guide in this repo covers, deliberately.

**Fix: none in this pass.** The pin stays at `2025.6` and the work is written up
in `docs/roadmap/authentik-2026.md` instead. Bumping the identity provider that
gates every other UI in the lab is a runtime change that cannot be verified by
reading, which is the only verification a documentation pass has — and it lands
in the same commit as nine guide corrections, where a failed SSO bring-up would
be indistinguishable from any of them. It wants its own branch and its own
replay.

---

## Cross-cutting

### The Part 7 split, and the renumbering it forces

Findings 3 and 4 are one change. Removing Part 7 renumbers Parts 8–10 to 7–9,
and those anchors are referenced from outside the guide in eleven places:

| Anchor | Referenced from |
|---|---|
| `#part-7--repo-and-host-setup-in-the-vms` | `dockge-setup.md`, `coolify-setup.md`, `traefik-setup.md`, `init-host.sh`, `init-unattended-upgrades.sh`, `init-coolify.sh` (×2) |
| `#part-8--snapshot-before-you-build` | `traefik-setup.md`, `forgejo-setup.md`, `roadmap/backup.md`, `init-docker.sh` |
| `#part-9--schedule-whole-vm-backups` | `README.md`, `coolify-setup.md`, `roadmap/backup.md` (×2) |
| `#part-10--notice-when-a-mirror-degrades` | `README.md` (×2), `grafana-setup.md` (×4), `uptime-kuma-setup.md` (×2), `uptime-kuma-monitors.md`, `rules.yaml` |

The Part 7 references do not simply renumber — they point at content that has
moved to a different **file**, so each one needs re-aiming at whichever of the
two new guides its context means. The three script headers are the easiest to
get wrong: `init-host.sh` and `init-unattended-upgrades.sh` run on both VMs and
should name both guides, while `init-coolify.sh` means the apps guide only.

Dated documents under `superpowers/` also mention Part 7 and Part 8. Those are
**historical records and must not be retro-edited** — the same rule that kept
the 2026-07-26 review intact.

### Build order

Two insertions, no reordering of anything that exists:

1. Proxmox + VMs
2. DNS
3. **infra VM setup** ← new
4. Traefik
5. Authentik
6. Dockge
7. Forgejo
8. Grafana
9. Uptime Kuma
10. **apps VM setup** ← new
11. Coolify
12. Home Assistant OS

The README's build order is grouped by machine, and the two new guides make that
grouping honest for the first time: each machine's section now opens with the
guide that prepares that machine.

### README and CLAUDE.md

- **README:** build order gains the two steps; the repository-layout tree gains
  both files; the `Part 9` / `Part 10` status-table links renumber to 8 and 9.
- **CLAUDE.md:** the "Docs layout" section lists the guide sequence explicitly
  and the "Deploy model & ordering" section describes the init scripts by which
  VM runs them — both must gain the two guides, or the next session will
  faithfully rebuild the single Part 7.

---

## Work items

1. Rewrite `coolify-setup.md` step 6 (finding 9) and re-word
   `apps/.env.example` around the recovery-copy justification.
2. Small corrections: Traefik `308` (finding 5), Kuma `cd` path (finding 8),
   Grafana verification trims and the two secret-handling commands
   (findings 6, 7).
3. Proxmox guide: the `by-id` note (finding 1) and the `wipefs` interlock
   (finding 2).
4. Split Part 7 into `infra-vm-setup.md` and `apps-vm-setup.md`, absorb
   `coolify-setup.md` steps 1–2, renumber Parts 8–10, and sweep every anchor in
   the table above (findings 3, 4).
5. `docs/roadmap/authentik-2026.md` (finding 10). No pin change.

Verification for this pass is the same as the last: every internal link and
heading anchor resolves, the compose stacks still parse under
`docker compose config`, `bash -n` passes on any touched script, and no file
picks up CRLF endings. What it explicitly **cannot** verify is finding 9 — the
Coolify proxy edit is written from upstream documentation and this replay's
observation of the UI, and stands unproven until the wildcard actually issues on
the apps VM.
