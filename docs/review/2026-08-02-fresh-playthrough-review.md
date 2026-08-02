# Fresh-playthrough review — 2026-08-02

A from-scratch read-through of the whole build order, starting at the README
and following every guide in sequence as a first-time builder would — README →
[proxmox-setup.md](../proxmox-setup.md) → … →
[home-assistant-setup.md](../home-assistant-setup.md) — with every compose
file, init script and registry read beside the guide that uses it. Performed
**by reading, on the current checkout**, not on hardware; that is the
verification a documentation repo defines for itself ("correctness is verified
by reading"), and the mechanical checks at the end are the same set the
previous reviews used.

Special attention went to the version bumps landed since the
[2026-08-01 replay](2026-08-01-guide-replay.md) — Authentik `2026.5`, Forgejo
`15` + runner `12`, Postgres `18`, Tempo `3.0.2`, the Node 24 job image —
because a fresh bump is the newest drift surface. The verdict there is good:
**every pin is consistent across compose, config, guide and CLAUDE.md**, the
`PGDATA` handling is uniform across all three Postgres services, and the Tempo
3.0 config matches its own comments. The drift this replay found is elsewhere.

Legend, matching the earlier reviews: **Confirmed** — reproducible from the
repo as written. **Confirmed, with nuance** — real issue, but the fix touches
a design decision. **Observation** — flow friction or wording; no broken
behaviour.

---

## 1. The apps VM's storage story contradicts itself in four documents — the most serious item

**Status: Confirmed, with nuance.** Two related inconsistencies, one about
where data actually lands and one about what backs it up. Each document is
locally plausible; read in build order they cannot all be true.

**(a) The repo says Docker growth lands on the data mirror; nothing makes that
happen.** Three places assign the apps VM's growth to the 300 GB `data` disk:

- [README.md:74](../../README.md) — "`data` absorbs the growth — Coolify's app
  volumes, databases and image layers"
- [proxmox-setup.md:314](../proxmox-setup.md) — "This is where Coolify's app
  volumes, databases and image layers live — the part that actually grows"
- [proxmox-setup.md:706](../proxmox-setup.md) — "app volumes, databases, build
  cache and image layers go on the `data` mirror, because that is the part
  that grows without asking"

But no step in [apps-vm-setup.md](../apps-vm-setup.md),
[coolify-setup.md](../coolify-setup.md) or `scripts/init-coolify.sh` moves
Docker's data root, and Coolify's installer installs the Engine with the
default `/var/lib/docker` — on the **80 GB root disk**. What actually lands on
`/data` is Coolify's own store (`/data/coolify`: its config, source, and the
bind mounts it creates under it). Images, layers, named volumes and build
cache — much of "the part that actually grows" — land on the root disk.
[coolify-setup.md](../coolify-setup.md)'s own layout table half-knows this:
"App data + volumes | Docker volumes, managed by Coolify" — and Docker volumes
live under the data root.

**Fix, two honest options.** Either add a step to
[apps-vm-setup.md](../apps-vm-setup.md) (after the `/data` mount, before the
installer — order matters, moving a live data root is exactly the "afterwards
means moving a live data directory" problem the guide already names for
`/data/coolify`) that writes `/etc/docker/daemon.json` with
`{"data-root": "/data/docker"}` so the claims become true — noting that the
file must exist *before* Coolify's installer brings the Engine up; **or**
soften the three claims to what is actually configured ("Coolify's own store
and the bind mounts under it"). Option one matches the sizing arithmetic the
repo already commits to (80 GB root "roomy" only if layers live elsewhere);
option two is smaller but concedes the root disk absorbs build-cache growth.

**(b) The backup coverage claims disagree.** Four statements, mutually
exclusive as written:

| Document | Claim |
|---|---|
| [proxmox-setup.md:333](../proxmox-setup.md) | "Until it is, everything on the apps VM's data disk is **unbacked**" |
| [apps-vm-setup.md:194](../apps-vm-setup.md) | "treat everything under `/data` as **unbacked** and deploy accordingly" |
| [coolify-setup.md:224](../coolify-setup.md) | "`/data/coolify/` is **the thing to back up**. Nothing under it is reproducible from this repo" |
| [apps/services.md:108](../../apps/services.md) | "Whole-VM `vzdump` **covers this machine today**." |

The first two are correct (`backup=0` excludes the data disk from every
archive). The third is correct as advice and silently incompatible with the
first two — the thing to back up sits on the disk nothing backs up. The fourth
is the dangerous one: it sits directly under a tier table that marks
Vaultwarden and Paperless **tier 1 — irreplaceable**, and it reads as
reassurance. For anything on `/data`, `vzdump` covers *none* of it.

This is also where the [architecture review's](2026-08-01-architecture-review.md)
strongest finding (its #1, a **Gate**) asked for the opposite sentence: a
written deploy-blocker — *Vaultwarden and Paperless do not deploy until the
apps VM has a working restic job and a tested restore*. That gate has not
landed; `services.md` gained a backup section that currently claims coverage
instead. **Fix:** replace the sentence with the gate, in `apps/services.md`
and echoed in `coolify-setup.md`. One sentence each, exactly as the
architecture review specified.

## 2. The home-assistant VM never actually gets its `cpuunits 200`

**Status: Confirmed.** [proxmox-setup.md Part 5](../proxmox-setup.md#part-5--create-the-vms)
assigns the HA VM `cpuunits` **200** — the 4:1 weight over the apps VM whose
stated purpose is "a runaway Coolify build cannot make your lights laggy" —
and correctly notes that `cpuunits` **is not in the Create VM wizard**; it
shows the post-wizard command only for the apps VM (`qm set 102 --cpuunits 50`),
which is fine there because that guide builds that VM.

The HA VM is built seven guides later, in
[home-assistant-setup.md step 2](../home-assistant-setup.md#2-create-an-empty-vm),
which lists "`cpuunits` 200" among the wizard specs — a field the wizard does
not have — and never gives the command or a checklist row for it. A builder
following the guides in order creates VM 103 with the default weight of 100,
and nothing later notices: `cpuunits` has no verification step anywhere.

**Fix:** an explicit fenced block in home-assistant-setup.md after the wizard
(step 2 or 3):

```bash
qm set 103 --cpuunits 200
```

plus one verification line (`qm config 103 | grep cpuunits`). Worth a matching
verification for the apps VM in its own path if the pattern recurs.

## 3. The HAOS download URL contradicts itself

**Status: Confirmed.** [home-assistant-setup.md step 1](../home-assistant-setup.md#1-download-the-image-on-the-proxmox-host):

```
wget https://github.com/home-assistant/operating-system/releases/latest/download/haos_ova-16.2.qcow2.xz
```

`releases/latest/download/` resolves against **whatever release is currently
newest**, while the filename pins **16.2** — so this exact command 404s the
day upstream publishes 16.3, in a way that looks like a GitHub problem. The
guide already says "check the release page for the current version number and
substitute it", which fights the `latest/` path rather than working with it.

**Fix:** pin both halves —
`releases/download/16.2/haos_ova-16.2.qcow2.xz` — so the command works
verbatim until someone deliberately bumps the version (the repo's normal
model), keeping the "substitute the current version" sentence as the bump
instruction.

## 4. The Kuma registry's own count of itself is wrong

**Status: Confirmed.** [uptime-kuma-monitors.md](../uptime-kuma-monitors.md#optional-group-them-on-the-dashboard)
says grouping collapses the status page "to eight rows that expand on demand,
instead of **twenty-three** flat entries." The registry lists **22** monitors
(Gateway 1, Identity 4, Git 4, Stack management 1, Observability 7, App
platform 2, Home automation 2, Hypervisor storage 1). The stale count is
almost certainly a survivor of the Authentik Redis monitor, whose removal the
Identity section documents as a deliberate non-row ("`Auth Storage` already
covers what a `authentik-redis-1` monitor used to"). The eight-group list is
correct. **Fix:** twenty-two.

## 5. The Forgejo guide's pull example doesn't match the workflow it just installed

**Status: Confirmed.** [forgejo-setup.md step 7](../forgejo-setup.md#7-add-the-pipeline-to-your-repo)
points at the shipped template, whose web job pushes
`git.thefipster.de/<owner>/<repo>/web:latest`
([infra/forgejo/build-and-push.yml:112](../../infra/forgejo/build-and-push.yml)).
[Step 8](../forgejo-setup.md#8-run-a-build-and-verify-the-image) then verifies
with:

```bash
docker pull git.thefipster.de/<owner>/<repo>:latest
```

— two path segments where the template produces three. A builder who ran the
template unmodified gets `manifest unknown` from the guide's own verification
command. **Fix:** `git.thefipster.de/<owner>/<repo>/web:latest` in the pull
example (and "a container package named `<repo>/web`" in the Packages-tab
sentence), with a note that the path follows the `tags:` you set in step 7.

## 6. Two comments in the Forgejo compose still point at a README that no longer says it

**Status: Confirmed.** [infra/forgejo/compose.yaml:96](../../infra/forgejo/compose.yaml)
— "this dir must be chown'd to 1000:1000 — **see the README setup step**" —
and [line 112](../../infra/forgejo/compose.yaml) — "It must be REGISTERED once
(**see README**)". Both procedures moved out of the README long ago: the chown
is `scripts/init-forgejo.sh`, the registration is
[forgejo-setup.md step 4](../forgejo-setup.md#4-register-the-runner). Nothing
breaks, but a reader sent to the README finds neither. **Fix:** re-aim both
comments at the script and the guide.

## 7. `init-authentik.sh` says "two secrets" and generates three

**Status: Confirmed.** The script header
([scripts/init-authentik.sh:7](../../scripts/init-authentik.sh)) promises to
"auto-generate the **two** secrets (`AUTHENTIK_SECRET_KEY`, `PG_PASS`)", and
[infra/authentik/.env.example:1](../../infra/authentik/.env.example) repeats
it ("auto-generates `AUTHENTIK_SECRET_KEY` and `PG_PASS` if you leave them
blank"). The script body generates **three** — `AUTHENTIK_BOOTSTRAP_PASSWORD`
too, deliberately, with a good comment explaining why — and the
`.env.example`'s *own* bootstrap-password comment says so, contradicting its
own header three lines up. The guide
([authentik-setup.md step 1](../authentik-setup.md#1-run-the-init-script))
gets it right. **Fix:** both headers say three; the behaviour is correct as
is.

## 8. Build-order step 2 is a re-run of a step the reader already did

**Status: Observation — flow, works as written.**
[proxmox-setup.md Part 6](../proxmox-setup.md#part-6--give-the-vms-their-addresses-on-the-router)
instructs the reader to add the reservations **and every DNS record from the
registry**, with [wildcard-dns-udr.md](../wildcard-dns-udr.md) open as the
how-to. The README's build order then lists that same guide as **step 2**, and
its prerequisite line ("both VMs exist and have DHCP reservations") describes
the state Part 6 produced — so a reader arriving at step 2 has already
performed everything in it, and its add-the-record steps read as a puzzle
("did I miss something?") rather than as the verification pass they
effectively are.

Nothing is wrong in substance — one piece of work, two documents, and the
registry keeps it honest. But the seam should say so. **Fix, smallest
version:** one line at the top of wildcard-dns-udr.md — "If you just arrived
from proxmox-setup.md Part 6, the records already exist; treat this guide as
the how-to you were using and run the
[verification](../wildcard-dns-udr.md#verify-at-all-three-layers)."
The alternative (Part 6 becomes a pure pointer, "go do wildcard-dns-udr.md
now, then come back") restructures more for the same effect.

## 9. The architecture review's action list has no status, and most of it has not landed

**Status: Confirmed, with nuance.** The
[2026-08-01 guide replay's](2026-08-01-guide-replay.md) work items all landed
(verified in passing throughout this read: the two VM-setup guides exist, the
`308`, the `wipefs` interlock, the Kuma `cd` fix, the Grafana password/`nano`
steps, the Coolify step-4 rewrite). The
[architecture review](2026-08-01-architecture-review.md) of the same date ends
with an eight-row consequences table, and of those, only the
Vaultwarden-placement decision is visibly resolved (recorded in
`apps/services.md`). Still open, checked row by row:

- **The backup gate** (its #1, Gate) — see finding 1(b) above, where the
  landed text currently says the opposite.
- **An owner for apps-VM backup** — [roadmap/backup.md:75](../roadmap/backup.md)
  still scopes it out ("its own state, its own story"), though the obligation
  paragraph further down acknowledges the day it stops being harmless.
- **The external deadman heartbeat** (its #2, Gate) — no new Part in
  proxmox-setup.md.
- **The tier-3-vs-layer-1 contradiction** — backup.md's tier-3 section still
  says the TSDBs are "deliberately not backed up" with no note that layer 1
  hauls them nightly anyway (accept-and-say-so was named as a valid
  resolution; it needs the one sentence).
- **The dual-wildcard renewal-race paragraph** in coolify-setup.md's
  troubleshooting — not present; the section's "two proxies issue
  independently" note is about *issuance*, not the shared
  `_acme-challenge` FQDN at renewal time.

The nuance: unlike the guide replays, the architecture review carries no
status banner, so a fresh reader cannot tell open from done — and this replay
had to re-derive it. **Fix:** land the one-sentence items (the gate, the
tier-3 note, the renewal-race paragraph — together they are perhaps ten
lines), and give the architecture review the same kind of status header the
2026-07-26 review has, added as a dated postscript rather than a retro-edit.

## 10. CLAUDE.md drift, two concrete instances

**Status: Confirmed — the architecture review's finding 9, now with examples.**

- CLAUDE.md names "HA's **pre-DNS onboarding URL**" as one of the remaining
  irreducible literal addresses. There is no such URL anymore:
  [home-assistant-setup.md step 5](../home-assistant-setup.md#5-start-it-then-name-it)
  adds the `homeassistant.` record *before* onboarding, and step 6 onboards at
  `http://homeassistant.thefipster.de:8123` — by name. The genuinely
  irreducible addresses are down to the Proxmox installer screen and
  `trusted_proxies`.
- CLAUDE.md's deploy-model list describes `init-traefik.sh` as "creates the
  `proxy` network + ACME dir, seeds `.env`" — omitting the `/opt/stacks`
  symlink the script also creates (its step 4), which every sibling script's
  description includes.

Neither misleads badly; both are the restatement-drift the architecture
review predicted. **Fix:** correct both when CLAUDE.md is next edited, and
keep preferring pointers over restatement there.

## 11. Small inconsistencies, gathered

**Status: Confirmed, all minor.** None blocks a build; each is a one-line fix.

- **README architecture diagram labels the USB pool `usb`**
  ([README.md:32](../../README.md)); its name everywhere else — `zpool create`,
  the `EXPECTED` list in the health script, the pool table, the backup roadmap
  — is **`usbbackup`**. The other three rows in that diagram use the real pool
  names.
- **grafana-setup.md claims step 6 is "the only step in any guide that runs on
  the Proxmox host"** ([grafana-setup.md:213](../grafana-setup.md)).
  home-assistant-setup.md runs its first four steps in the Proxmox host shell
  (its `Runs on:` line says so). True claim: the only step in any *infra-VM*
  guide.
- **The Dockge compose header suggests "temporarily publish 5001 to debug"**
  ([infra/dockge/compose.yaml:14](../../infra/dockge/compose.yaml)) — the
  exact move the build order rejected ("publishing a port … was considered and
  rejected; it would leave an un-gated LAN path"), and unnecessary since the
  documented break-glass (comment the middleware label) exists. Drop the
  aside, or point it at the break-glass.
- **home-assistant-setup.md step 8 chains `cd ~/home-lab/infra/monitoring &&
  docker compose up -d alloy`** in one block
  ([home-assistant-setup.md:187](../home-assistant-setup.md)) — the same
  template violation the 2026-08-01 replay fixed in the Kuma guide (its
  finding 8). Two blocks.
- **grafana-setup.md's Alloy `fmt` check mounts the config via
  `/opt/stacks/monitoring/…`** ([grafana-setup.md:778](../grafana-setup.md)) —
  the Dockge-symlink path, where every other command in that guide uses the
  checkout. Works identically; the convention (repo is the source of truth)
  says `~/home-lab/infra/monitoring/alloy/config.alloy`.
- **`grafana/alloy:v1.18.0` is now written in two places** — the compose pin
  and that same troubleshooting command. When the pin moves, the guide line
  must move with it; worth a comment beside the pin naming the second site,
  the same convention the Node-24 pair already uses.

---

## What a fresh playthrough confirms is right

Named so nobody "fixes" them, in the tradition of the earlier reviews:

- **The build order holds.** Every forward reference found is deliberate and
  documented (Part 9's Kuma dependency has explicit escape hatches on both
  ends; the two deferred DNS rows are marked in the registry and re-marked in
  the guides that resolve them). No guide requires a later guide to complete,
  the failure the 2026-07-26 review was born from.
- **The version-bump hygiene worked.** All thirteen image pins, their comments,
  the guides and CLAUDE.md agree — including the tricky pairs (config.yml ↔
  build-and-push.yml on Node 24, server ↔ runner on Forgejo 15/12) and the
  three-way `PGDATA` convention.
- **The registries' deliberate absences are all still true in the code.** No
  outpost routers for `uptime.`/`ha.` in the Authentik labels, no
  `middlewares` in Kuma's compose or `ha.yaml`, no DNS rows for
  `coolify.`/`apps.` — each with its in-place comment, exactly as the
  registries claim.
- **Every internal link and anchor in the living docs resolves.** The only
  broken links in the repo are inside dated `superpowers/` and `review/`
  documents — the accepted, documented rot of the no-retro-edit rule.
- **Mechanical checks pass:** all six compose files parse (`docker compose
  config` with the `:?` guards satisfied), `bash -n` passes on all eleven
  scripts, every script is mode `100755`, no file carries CRLF, and no
  unflagged literal IP exists outside the dated directories.

---

## Work items

1. **Resolve the apps-VM storage story** (finding 1a): decide data-root vs.
   softened claims, then make README, proxmox-setup and coolify-setup agree.
2. **Replace `services.md`'s vzdump sentence with the backup gate** (finding
   1b), echo it in coolify-setup.md, and land the other one-sentence
   architecture-review items (tier-3 note, renewal-race paragraph) — finding 9.
3. **`qm set 103 --cpuunits 200`** as an explicit step + verification in
   home-assistant-setup.md (finding 2).
4. Small corrections batch: HAOS URL (3), monitor count 22 (4), pull example
   `/web` (5), Forgejo compose comment pointers (6), "three secrets" (7),
   the six nits in finding 11.
5. Flow: the one-line "already done in Part 6" note in wildcard-dns-udr.md
   (finding 8).
6. CLAUDE.md corrections on next edit (finding 10); status postscript on the
   architecture review (finding 9).

Everything here is documentation-shaped except work item 1's option one (the
`daemon.json` step), which changes what a fresh apps-VM bring-up installs and
should be verified on the machine when that VM is next built — the same
caveat the 2026-08-01 review attached to its Coolify rewrite.
