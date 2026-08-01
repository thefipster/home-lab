# Architecture review — 2026-08-01

An in-depth review of the whole design, commissioned while a 180° pivot is
still on the table. The question asked: **is Proxmox + three VMs still the
right approach on the hardware that was actually bought** (i5-12500HL, 12
threads, 64 GB, six internal drives + one USB), **or should the machine be set
up drastically differently?** Everything was read for this — the README, both
dated sizing specs, every guide, every roadmap, the registries and the compose
stacks — and the alternatives were weighed seriously rather than as strawmen.

Like the [guide replay](2026-07-26-guide-replay.md), this is a dated record:
findings state what was found and what to do about it, and the document is not
retro-edited when the recommendations land.

Legend per finding: **Gate** — becomes a real problem at a nameable future
step, and should block that step. **Watch** — sound today, with an arithmetic
or probability that can turn. **Note** — worth knowing, no action required.

---

## Verdict

**Keep the architecture. Do not pivot.** Proxmox + three VMs survives the
hardware change intact, for three reasons that are worth stating precisely:

1. **The topology is forced by the software choices, and the hardware change
   did not touch those.** HAOS is an OS image — it can only be a VM. Coolify
   expects to own a Docker daemon outright — it cannot share a machine with the
   label-and-network conventions the infra stacks depend on. And the infra VM
   is the one machine that must survive an experiment on either of the others.
   Any layout with fewer than three isolation domains breaks one of those three
   facts, regardless of how many threads the host has.
2. **The hypervisor has already paid for itself, in this repo's own history.**
   The guide replay was performed by snapshot rollback; the clock-skew
   engineering in `init-host.sh` exists because rollbacks are a real, used
   workflow; backup layer 1 is `vzdump`, which only exists because there is a
   hypervisor to run it. A bare Docker host loses all of that, not just the VM
   boundaries.
3. **The 32→12 thread change was absorbed correctly.** The 3:1 overcommit
   ratio was preserved and the reasoning genuinely carries over. What the
   smaller machine actually cost is **RAM headroom**, not CPU — and that is a
   sizing question (finding 5), not a topology question.

The pressure points found below are real, but every one of them is fixable
inside the current design — none of them argues for a different machine
layout. The two that matter most are **sequencing** (tier-1 data is scheduled
to land on the least-protected disk in the lab — finding 1) and
**self-observability** (the lab cannot report its own total failure — finding
2).

---

## The alternatives, weighed

The user's question deserves the alternatives considered honestly, not
dismissed. Each was evaluated against what this lab actually runs.

| Alternative | Verdict |
|---|---|
| **Single Ubuntu host, Docker on bare metal** | Rejected. Loses snapshots/rollback (a used workflow, see above), loses `vzdump` (backup layer 1 would need redesigning from scratch), and forces HAOS down to HA Container — which loses the Supervisor and the add-on store, the exact reason HAOS was chosen. Coolify and the infra stacks would fight over one Docker daemon. This is the true 180°, and it gives up the most for the least. |
| **Two VMs — fold apps into infra** | Rejected. Coolify owning the infra VM's Docker breaks every `traefik.*` label convention in `infra/`, and a bad Coolify day would then roll back TLS, SSO and monitoring with it — the precise coupling the split exists to prevent. |
| **LXC containers instead of VMs** | Rejected, but this is the closest call. LXC would materially relieve the RAM pressure (finding 5) — containers share the host kernel and don't reserve fixed memory. But HAOS cannot be an LXC at all, Docker-inside-LXC is a known source of breakage across Proxmox major upgrades, and Coolify in LXC is unsupported upstream. It would trade documented, bounded friction for RAM the lab does not yet need. **Worth revisiting only if finding 5's arithmetic actually turns** — and even then only for the infra workloads, never for HAOS. |
| **k3s / Kubernetes** | Rejected. A one-person lab whose entire tooling (Dockge, Coolify, the compose-file-per-stack convention) is compose-shaped. Kubernetes replaces the repo's simplest, most legible layer with its most complex one and returns nothing this lab asks for. |
| **TrueNAS / Unraid as the base OS** | Rejected. These are storage appliances with VM support bolted on; Proxmox is a hypervisor with first-class ZFS. The four-pool layout is already built on the stronger foundation, and the storage design in the [hardware spec](../superpowers/specs/2026-07-31-hardware-specs-design.md) needs nothing TrueNAS offers. |
| **Two physical boxes** | Not an alternative to the topology — an *addition* to it, and a good one. See [hardware recommendations](#hardware-recommendations): a second small machine is the single highest-value change available, and it changes nothing about how the main box is laid out. |

The honest summary: the current design sits at a genuine local optimum. Every
neighbouring layout is worse for this specific software set, and the global
alternatives (k8s, appliance OSes) solve problems this lab does not have.

---

## Findings

Ordered by how much they matter, not by where they live.

### 1. Tier-1 data is scheduled to land on the least-protected disk in the lab — **Gate**

The strongest finding, and it is about sequencing, not design.

[apps/services.md](../../apps/services.md) catalogs **Vaultwarden** (every
credential, including the lab's own — its backup table says losing it "locks
you out of everything else, including the lab") and **Paperless-ngx** (scanned
documents whose originals are "paper, or gone") for the apps VM. Both are
tier 1 — irreplaceable. Meanwhile:

- The apps VM's 300 GB data disk — where Coolify puts all app volumes — is
  `backup=0`: excluded from `vzdump` by design, so **layer 1 covers none of
  it**.
- Layer 2 (restic) is not built, and [roadmap/backup.md](../roadmap/backup.md)
  **explicitly scopes the apps VM out**: "its own state, its own story. Not
  this roadmap."
- No other document owns it. The gap has no owner.

Every individual decision in that chain is documented and defensible — the
`backup=0` reasoning is genuinely correct, and both the Proxmox and Coolify
guides say plainly that `/data` is unbacked "until" layer 2 lands. But the
composition is: **the most irreplaceable data in the lab is planned onto the
only storage covered by nothing, with no roadmap item that will change that.**

There is a second coupling that undercuts a stated benefit. The README's
argument for the VM split is "rolling back a bad Coolify upgrade should not
take TLS, SSO and monitoring with it" — true, but a Proxmox snapshot rollback
includes **every** attached disk, the data disk with the rest. Once Vaultwarden
runs there, the casual-rollback workflow rewinds the vault to snapshot time.
Rollback stops being casual the day tier-1 services land, and nothing currently
says so.

**Recommendations:**

- **Make backup coverage a build-order gate, in writing:** Vaultwarden and
  Paperless do not deploy until the apps VM has a working restic job *and a
  tested restore*. One sentence in `apps/services.md` and one in the Coolify
  guide. The SFTP transport was explicitly designed so the apps VM joins with
  "a key and an `.env` value" — the remaining work is small; the point is that
  its absence must block the right step.
- **Give the gap an owner:** either extend `roadmap/backup.md` with an apps-VM
  phase or add a sibling roadmap file. The current scoping-out made sense when
  the apps VM was empty; the services catalog changed that.
- **Consider Vaultwarden on the infra VM instead.** A password manager holding
  the lab's own break-glass credentials is arguably lab infrastructure, not an
  "application you use" — on the infra VM it would ride layers 1 *and* 2 the
  day layer 2 exists, and it would sit on the machine designed to survive
  experiments rather than host them. The counterargument (it is a personal
  app, and `infra/` has a clean definition) is real; this is presented as an
  option, not a directive. If it stays on the apps VM, the gate above carries
  the weight.

### 2. The lab cannot report its own total failure — **Gate** (before the lab matters day-to-day)

Every notification the lab can send originates from one process: Uptime Kuma,
on the infra VM, pushing to hosted ntfy.sh. The design handles partial
failures well — Kuma deliberately joins no SSO, the pool-health push doubles
as a deadman, and because the push traverses Traefik, even a Traefik outage
correctly fires an alert (Kuma is still alive to send it).

What it cannot handle is anything that takes Kuma itself: the infra VM down,
the hypervisor down, the LAN or the internet uplink down. All of those are
**silent, and silence is indistinguishable from health.** Nothing is exposed
to the internet, so no external service can probe in — but an *outbound*
heartbeat needs no exposure:

- **A systemd timer on the Proxmox host curls a free external deadman**
  (healthchecks.io or equivalent) every few minutes. The service alerts when
  pings *stop* — host death, network death and power loss all become visible.
  One `curl` line, same shape as the existing `zfs-health-push.sh`, and it can
  live in the same guide part.
- Residual gap: host-alive does not prove the infra VM is alive. Cheap
  extension: the same timer curls `https://uptime.thefipster.de` first and
  only pings the deadman on success — then the heartbeat vouches for the host,
  DNS, Traefik *and* Kuma in one line. A failed check stops the heartbeat and
  the external service alerts.

This is deliberately the same pattern the lab already trusts (deadman via
push), pointed at the one place a deadman must live: outside the failure
domain it watches. [uptime-kuma-monitors.md](../uptime-kuma-monitors.md)'s
"deliberately not monitored: the hypervisor" reasoning — Kuma is a guest of
what it would watch — is *exactly* the argument for this being external.

### 3. Whole-VM backup arithmetic can stop fitting — **Watch**

`vzdump` archives are **full**, never incremental. Retention is
`keep-daily=7, keep-weekly=4, keep-monthly=3` — up to 14 archives — against
930 GB usable on the `backup` mirror. Today that is comfortable: the three
roots hold perhaps 40–60 GB of real data between them, zstd-compressed.

Two growth curves work against it. Forgejo's registry gains an image per CI
run and expires nothing until the CI roadmap lands its hygiene item; the
monitoring TSDBs churn toward their retention caps (~36 GB at full Prometheus
+ Loki + Tempo retention). If the infra VM's real usage reaches ~100 GB —
plausible within a year of active CI — and much of it is
already-compressed data that zstd cannot shrink (registry layers, TSDB
chunks), 14 archives approach or pass the pool. The `ZfsPoolAlmostFull` /
`DiskAlmostFull` alerts will catch it in time, so this is **Watch**, not Gate.

One inconsistency worth naming: [roadmap/backup.md](../roadmap/backup.md)
declares the TSDBs tier 3 — "deliberately **not** backed up… a backup that
hauls the TSDB around nightly is a backup nobody keeps running" — yet layer 1
hauls exactly those directories around nightly, because whole-VM archives
cannot exclude a path. The options, in ascending order of effort:

- **Accept and watch** (the current implicit position — fine, but say it in
  the roadmap so the tier-3 paragraph stops contradicting layer 1).
- **Give the infra VM a second disk** for `/opt/monitoring`'s TSDB
  directories, marked `backup=0` — the identical pattern the apps VM already
  uses, shrinking every nightly archive by the churniest data in the lab.
- **Proxmox Backup Server on a second box** — incremental + deduplicated
  archives dissolve the arithmetic entirely. The backup roadmap already names
  PBS as "the right answer if a second machine exists"; see
  [hardware recommendations](#hardware-recommendations).

### 4. Two ACME clients renew the same wildcard against a zone the repo documents as racy — **Note**

Traefik (infra VM) and Coolify's proxy (apps VM) each independently issue and
renew `*.thefipster.de` via DNS-01 against netcup. Both therefore write TXT
records at the **same FQDN**, `_acme-challenge.thefipster.de` — and the repo's
own TLS design dropped the apex SAN precisely because "two TXT records at the
same `_acme-challenge` FQDN race on netcup's non-atomic zone updates."

The difference from the apex-SAN case: these two renewals are independent
events roughly 60 days apart each, so overlap is improbable rather than
guaranteed. When it does happen, one side fails validation, retries later, and
self-heals — but the failure will present as netcup flakiness, and nothing in
the docs would lead anyone to connect it to the other VM's renewal.

**Recommendation:** a short paragraph in
[coolify-setup.md](../coolify-setup.md)'s troubleshooting ("if both proxies
renew in the same window they race on the same TXT FQDN; retry resolves it").
No config change is warranted now. If it ever bites repeatedly, the escape
hatches are delegating `_acme-challenge` via CNAME to a zone on a second
provider for one of the two, or per-hostname certs on the Coolify side (which
trades the shared FQDN away for hostnames leaking to CT logs).

### 5. RAM is the binding constraint, and the growth story now has a price — **Watch**

The [hardware spec](../superpowers/specs/2026-07-31-hardware-specs-design.md)
already says this honestly: 48 GB of VMs + 8 GB ARC + hypervisor and per-VM
QEMU overhead ≈ 60 of 64 GB, and "growing a VM's memory means taking it from
the cache." The review's job is to confirm the arithmetic and rank the
levers:

- **The allocation is spendable exactly once.** The old plan's "~12 GB growth
  pool" is gone; every future "give X more memory" decision is now a trade
  against ARC or another VM. That is workable — but it means the first
  sustained memory-pressure incident has no free fix.
- **The cheapest lever is the apps VM.** It holds 24 GB — the largest single
  allocation — for a machine that today runs nothing. Trimming it to 16 GB
  until real load exists would recreate an 8 GB reserve, and the repo's own
  reasoning ("raising a VM's memory later is an edit plus a reboot") argues
  that under-allocating a not-yet-loaded VM is the safe direction to be wrong
  in. Counterpoint: churn for a problem not yet observed. Reasonable either
  way; recorded so the lever is known before it is needed.
- **The real fix is physical** — see
  [hardware recommendations](#hardware-recommendations).

CPU, by contrast, is genuinely fine: 3:1 overcommit over 12 threads with
`cpuunits` arbitration is the right shape for three bursty, rarely-coincident
workloads, and no finding here disputes it.

### 6. The hypervisor has quietly accumulated eight hand-applied artifacts — **Note**

The hardware spec rejected a `proxmox/` root directory "until the hypervisor
accumulates a third artifact." Counting now: the repo-list switch, two
`zpool create`s + two `pvesm` registrations, the ARC cap, the node exporter
install + textfile-directory fix, `zfs-health-push.sh` + its service + timer +
env file, and the backup job. All of it is paste-from-guide clickwork on the
one machine with no checkout, and a host reinstall replays Parts 3–10 of
[proxmox-setup.md](../proxmox-setup.md) by hand.

This is still defensible — the host is rebuilt approximately never, and the
guide is genuinely complete. But the trigger condition the spec set has been
met, so the decision deserves re-taking rather than silent inheritance. A
middle path short of a `proxmox/` directory: one idempotent
`setup-pve.sh` fenced *in the guide* (the established precedent for host-side
material) that applies the post-install pieces, so a rebuild is one paste
instead of thirty.

### 7. Several designs assume a benign LAN, and the LAN includes IoT — **Note**

The flat `/24` carries the hypervisor, all three VMs, trusted clients — and,
once Home Assistant is real, ESPHome nodes and Ethernet Zigbee coordinators:
the least-trustworthy firmware in the building. Meanwhile several decisions
lean on the LAN being friendly: node exporters bind `:9100` on all interfaces
unauthenticated, Coolify's first-run window is "reachable and unprotected" on
a LAN port, and the [apps-VM logs roadmap](../roadmap/apps-vm-logs.md) already
flags that a Loki ingest path "changes that, and the LAN is not a trust
boundary this repo has leaned on before" — correctly implying it has been, so
far.

The UDR does VLANs; an IoT segment with mDNS reflection is a well-trodden
router-side project that changes nothing in this repo (names, not addresses,
everywhere — the design would not even notice). This is not a flaw in the VM
topology and does not gate anything; it is the next security investment after
the backup story, and it deserves a roadmap file when it becomes real.

### 8. Hybrid-core CPU: the 12 threads are not twelve equals — **Note**

The i5-12500HL is Alder Lake — a mix of P-cores and E-cores. With CPU type
`host` and no pinning, vCPUs land on whichever core class the host scheduler
picks, so per-thread performance varies run to run. Consequences are mild and
worth exactly one expectation-setting note: CI compile times and ESPHome build
times will show variance that is nobody's regression, and single-thread
benchmarks inside VMs are unreliable. Core pinning could fix it and is not
worth its complexity here. The docs' choice to record "12 threads without
asserting a P/E split" remains correct for sizing; this note is about
*variance*, not capacity.

### 9. CLAUDE.md restates enough of the repo to be its largest drift surface — **Note**

Repo-process rather than architecture, recorded because this review read
everything side by side. CLAUDE.md restates dozens of per-file facts (pin
policies, script orderings, exception lists) that also live in the guides and
registries. The guide replay already caught one such divergence (the
monitoring-guide split, which CLAUDE.md documented as deliberate after it was
merged away). Every restatement is a future divergence site. When CLAUDE.md is
next edited, prefer pointers into the owning guide over restated detail —
the file's unique value is the *invariants* (never write an IP; the two SSO
patterns; compose is the source of truth), not the inventory.

---

## What the hardware change actually cost — a summary

| Dimension | 32-thread plan | 12-thread reality | Verdict |
|---|---|---|---|
| CPU | 96 vCPU @ 3:1 | 36 vCPU @ 3:1 | Absorbed cleanly; ratio and reasoning intact |
| RAM | 48 GB VMs + ~12 GB free growth pool | 48 GB VMs + 8 GB ARC, **no growth pool** | The real cost — see finding 5 |
| Storage | undifferentiated 2 TB | four purpose-split pools | An outright improvement over the plan |
| Backup | abstract "two layers" | named targets, layer 1 built | Improvement — with the sequencing gap of finding 1 |

The storage redesign deserves explicit credit: the four-pool split, the
`backup=0` reasoning, the `--is_mountpoint` safety catch and the
pool-health-as-deadman design are all *better* than what the 32-thread plan
had. The hardware change made the lab smaller and simultaneously better
engineered.

---

## Hardware recommendations

Invited by the review's commission. Ranked by value per euro; none of them is
required for the current design to work.

1. **A second small machine, before any upgrade to the main box.** A used
   mini-PC or thin client (~€100–150, 8–16 GB RAM) running **Proxmox Backup
   Server** converts layer 1 from nightly fulls into incremental, deduplicated,
   verified backups — dissolving finding 3 — and puts backups on separate
   hardware, which the current design cannot offer at any price. The backup
   roadmap already names PBS as the right answer "if a second machine exists."
   The same box is the natural home for a second Uptime Kuma watching the
   first lab from outside its failure domain, closing the remainder of
   finding 2. No other purchase touches two findings at once.
2. **A UPS, with NUT or apcupsd on the hypervisor.** Currently absent from
   the design entirely. ZFS survives power loss without corruption, but
   in-flight VM writes, the 02:00 backup window and the 04:30 patch-reboot
   window do not enjoy it, and an orderly three-VM shutdown needs more than
   the ~0 seconds a power cut offers. A consumer line-interactive unit plus
   the standard NUT shutdown integration is the cheapest availability
   improvement available.
3. **RAM to 96 GB, if the platform takes it.** Finding 5's constraint is
   physical. Many DDR5 SODIMM platforms accept 2×48 GB even where the CPU's
   official maximum says 64 GB — worth checking this specific board before
   assuming either way. If it works, the growth pool returns and the ARC can
   breathe; if not, the apps-VM trim in finding 5 is the fallback lever.
4. **Do not buy CPU.** Nothing in this review found the 12 threads wanting.
   The workloads are bursty and anti-correlated, exactly what overcommit is
   for.

The USB drive's role is correct as designed — single-disk ZFS, no fstab
entry, health-monitored, restic target. Its known limitation (offsite only
when a human carries it) is already stated in the roadmap and is what phase 3
exists to fix.

---

## What is right and should not be "fixed"

An honest review names these too, because each has the surface appearance of
an oversight and a documented reason underneath. Beyond the repo's own list of
deliberate absences (registry non-rows, the SSO exceptions, Kuma's
independence), the review specifically endorses:

- **Names, not addresses, everywhere.** The wildcard-as-safety-net /
  wildcard-as-trap analysis (`pve.` needs an exact record, `apps.` must not
  have one) is subtle, correct, and correctly written down.
- **The two-certificate split** between Traefik and Coolify. Sharing one
  `acme.json` across machines would be strictly worse than the rare renewal
  race in finding 4.
- **`backup=0` on the apps data disk.** The retention arithmetic behind it is
  right. Finding 1 is about what must happen *before* that disk holds tier-1
  data, not about the flag.
- **Hosted ntfy.sh over self-hosting it** — a notifier inside the lab it
  notifies about would be finding 2 with extra steps.
- **The docs discipline itself.** Registries with deliberate absences, dated
  immutable specs, guides that are from-scratch-only: this is the reason a
  review like this one can be performed by reading. It is the repo's most
  valuable convention.

---

## Consequences — the short list

What this review asks to change, gathered in one place:

| # | Action | Where |
|---|---|---|
| 1 | Write the backup gate: Vaultwarden/Paperless deploy blocked on a tested apps-VM restic restore | `apps/services.md`, `coolify-setup.md` |
| 1 | Give apps-VM backup an owner (extend `roadmap/backup.md` or add a sibling) | `docs/roadmap/` |
| 1 | Decide Vaultwarden's home (apps VM + gate, or infra VM) before it exists anywhere | discussion, then the catalog |
| 2 | External deadman heartbeat from the hypervisor | `proxmox-setup.md` (new part) |
| 3 | Resolve the tier-3-vs-layer-1 contradiction in the backup roadmap (accept-and-say-so is a valid resolution) | `roadmap/backup.md` |
| 4 | One troubleshooting paragraph on the dual-wildcard renewal race | `coolify-setup.md` |
| 6 | Re-take the `proxmox/`-directory decision now that its trigger condition is met | discussion |
| 7 | VLAN segmentation as a roadmap file when IoT devices become real | `docs/roadmap/` |

None of these changes the machine layout. The architecture holds.
