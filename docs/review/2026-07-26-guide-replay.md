# Guide replay review — 2026-07-26

A full replay of the setup guides on the infra VM (rolled back to the snapshot
taken after guest extensions + Docker/compose install) surfaced a set of
issues. Each finding below was verified against the repo; every item states
what was found, whether it holds up, and what to change. Cross-cutting items
(guide template, build order, README) follow the per-guide sections.

Legend: **Confirmed** — the finding is reproducible from the repo as written.
**Confirmed, with nuance** — real issue, but the fix touches a design decision.

> **Status: all items executed** (2026-07-26). Every finding below has landed;
> this document is kept as the record of what was found and why each decision
> went the way it did, not as an open work list. What changed:
>
> | Item | Landed as |
> |------|-----------|
> | 1 — Traefik verification | Guide verifies with Traefik alone: `acme.json`, an `openssl s_client` issuer check, and a **404 over a trusted cert** as the success condition |
> | 2 — Authentik ↔ Dockge forward references | Dockge moved to its own guide at build-order position 5; Authentik's step 3 now verifies against the Traefik dashboard only |
> | 3 — Missing Dockge guide | New [dockge-setup.md](../dockge-setup.md), stating explicitly that the init script starts the stack |
> | 4 — Forgejo Part 0 duplication | Collapsed to a one-line prerequisite plus the Forgejo-specific init step |
> | 5 — Clock skew after rollback | `init-host.sh` sets chrony `makestep 1 -1` as its first step; documented in [proxmox-setup.md Part 8](../proxmox-setup.md#part-8--snapshot-before-you-build), cross-referenced from Traefik and Forgejo troubleshooting |
> | 6 — Runner `config.yml` | Bind-mounted read-only from the repo; the manual `cp` + `chown` step is gone |
> | 7 — Forgejo SSO framed as optional | Now step 5 of the guide, with the registry linked |
> | 8 — Loki `wget` check | Runs from the `grafana` container; the Loki image ships no shell utilities |
> | 9 — Forgejo "Auto Registration" | Moved to where it actually lives: two `oauth2_client` env vars in the compose; registry corrected |
> | 10 — Monitoring guide as migration | Merged into [grafana-setup.md](../grafana-setup.md); `monitoring-setup.md` deleted; from-scratch-only policy recorded in CLAUDE.md |
> | Template / build order / README | All seven guides restructured; build order is Proxmox → DNS → Traefik → Authentik → Dockge → Forgejo → Monitoring; README gained a "Start here" jump-off |

---

## 1. Traefik guide — verification can't succeed at that point in the build order

**Finding:** during first issuance, `curl -Is https://auth.thefipster.de | head -1`
returns nothing useful and the browser shows a 404 — Authentik isn't up yet.
Same for the verification checklist.

**Status: Confirmed.** The guide half-knows this —
[traefik-setup.md:104–115](../traefik-setup.md) says the curl check needs
Authentik ("once it's up") — but it still *places* the check inside this
guide, and the verification checklist (then a section of its own)
is headed "Immediately after this guide (only Traefik + Authentik up)", which
is circular: the Authentik guide comes *after* this one. As written, the guide
cannot be completed without leaving it, doing the next guide, and coming back.

**Fix:**

- Make the checks that work with Traefik alone the completion criteria of this
  guide:
  1. The `acme.json` grep (already in the guide) — proves the cert was issued.
  2. A 404-with-valid-cert check: once the wildcard is issued, *any*
     infra-VM hostname served by Traefik answers `HTTP/2 404` over a trusted
     Let's Encrypt cert even with nothing routed. `curl -Is
     https://traefik.thefipster.de | head -1` returning `404` **without a TLS
     warning** is a complete TLS + routing-plumbing verification that needs no
     other stack. The guide should say exactly that, and that 404 here is
     success, not failure.
- Move the `auth.thefipster.de` 200/303 check and the service-by-service
  checklist rows into the guides that bring those services up (each guide's
  own verification section — see the template below). The Traefik checklist
  keeps only the two Traefik-only checks.

## 2. Authentik guide — references Dockge, which doesn't exist yet

**Finding:** the guide references Dockge before any Dockge guide/stack exists;
since Dockge is fairly standalone it should come up earlier to give a browser
view.

**Status: Confirmed, with nuance.** [authentik-setup.md:104–110](../authentik-setup.md)
verifies Part A against Dockge but has to defer to "`scripts/init-dockge.sh` —
next in the build order, documented in forgejo-setup.md, Part 0" — a forward
reference into a *later* guide for a stack this guide's verification needs.

The nuance: as shipped, Dockge cannot be "first". It publishes **no ports**
([infra/dockge/compose.yaml](../../infra/dockge/compose.yaml)) and its only
route is gated by the `authentik@docker` forward-auth middleware, so without
Traefik *and* Authentik there is no browser view at all — the container would
run, but be unreachable.

**Decision: Dockge stays behind Authentik** and moves to the slot right after
it in the build order (see [Build order](#build-order)). That keeps the flow
lean — no ports published for bootstrap and walked back later, no un-gated
path on the LAN — at the cost of no browser view for the Traefik and Authentik
bring-up themselves (which is chicken-and-egg anyway).

Consequences: the Dockge references move into a Dockge guide (next item), and
the Authentik guide's Part A verification uses only the Traefik dashboard —
the Dockge half of the forward-auth verification moves to the Dockge guide,
which immediately follows.

## 3. Dockge guide — doesn't exist

**Finding:** there is no Dockge setup guide. Setup is trivial — run the init
script, done, **no `docker compose` call needed** — but that should be written
down.

**Status: Confirmed.** No `docs/dockge-setup.md` exists; Dockge is documented
only as item 4 inside `forgejo-setup.md` Part 0 (as it then was)
and in compose comments. And correct on the compose call:
[init-dockge.sh:60](../../scripts/init-dockge.sh) runs `docker compose up -d`
itself — unique among the init scripts, which is exactly the kind of
inconsistency that must be stated explicitly or a reader will run compose
again out of habit.

**Fix:** write `docs/dockge-setup.md` following the shared template, slotted
into the build order right after Authentik (per the decision in item 2).
Content is short by nature: what Dockge is, prerequisites (Traefik + Authentik
up), `scripts/init-dockge.sh` (with an explicit "the script already started
the stack — there is no compose step"), the forward-auth join per the registry
([sso-applications.md](../sso-applications.md#forward-auth-dockge--traefik-dashboard)),
first-visit local admin creation, the two-logins-by-design note (move it here
from the Authentik guide), verification, troubleshooting, break-glass. Add it
to the README build order and repository layout.

## 4. Forgejo guide — Part 0 duplicates the previous guides

**Finding:** the server-prerequisites part is very detailed but everything in
it is already covered by the preceding guides.

**Status: Confirmed.** [forgejo-setup.md:43–126](../forgejo-setup.md) restates
what `init-host.sh`, `init-traefik.sh`, `init-authentik.sh` and
`init-dockge.sh` do — each already owned by its own guide. Per the template,
this collapses to a one-line prerequisite pointer to the previous guide, plus
only the Forgejo-specific step (`init-forgejo.sh`) with its explanation. The
"Does Dockge replace init-forgejo.sh?" note is genuinely Forgejo-specific and
stays.

## 5. Forgejo runner — cert "not yet valid" after snapshot rollback

**Finding:** the runner failed with
`tls: failed to verify certificate: x509: certificate has expired or is not
yet valid: current time 2026-07-25T20:54:09Z is before 2026-07-26T14:03:44Z`
because the VM clock was stale after the Proxmox snapshot rollback.

**Status: Confirmed — root cause identified, fix landed.** The mechanism:
rolling back to a RAM-inclusive snapshot resumes the guest with the clock
frozen at snapshot time; the wildcard cert was issued *after* that moment, so
every TLS validation fails until the clock corrects. And it doesn't reliably
correct: chrony's default step policy (`makestep 1 3`) steps the clock only
during its **first three updates after service start** — a rollback happens
long after those, so chrony detects the offset but is only allowed to *slew*
it, which for an offset of hours effectively means never.

Since this repo controls Proxmox and both VMs, the decision is to **solve it
in-repo**, not merely document it. Done:

- [`scripts/init-host.sh`](../../scripts/init-host.sh) now configures the
  time-sync daemon **as its first step**: with chrony, a
  `/etc/chrony/conf.d/90-step-any-offset.conf` drop-in containing
  `makestep 1 -1` (step at any time; still only acts on offsets over 1s, so
  normal operation is untouched); with systemd-timesyncd, a tightened
  `PollIntervalMaxSec=512` so the post-rollback stale window is minutes rather
  than ~34. It runs first because the script itself needs a sane clock — apt
  and curl both do TLS.
- [`docs/proxmox-setup.md` Part 8](../proxmox-setup.md#part-8--snapshot-before-you-build)
  (the snapshot section) now explains the rollback-skew behavior, the
  immediate fix (`sudo chronyc makestep`), and the manual drop-in for the
  **apps VM**, which never runs `init-host.sh`; Part 7 points at the note.

Remaining (folds into the guide-restructure pass): a one-line
troubleshooting cross-reference from the Forgejo guide — the runner is where
the symptom bites first, being the first non-browser TLS client — to the
Proxmox guide's note.

## 6. Forgejo runner — init script should place `config.yml`

**Finding:** couldn't `init-forgejo.sh` copy `config.yml` into
`/opt/forgejo/runner` and perform the chown?

**Status: Confirmed — good catch.** [forgejo-setup.md:195–200](../forgejo-setup.md)
has the user run `sudo cp config.yml /opt/forgejo/runner/config.yml && sudo
chown 1000:1000 ...` manually, while [init-forgejo.sh](../../scripts/init-forgejo.sh)
already creates and chowns that very directory. Two options:

- **Copy in the script** (minimal): `run_root cp` + `chown` in
  `init-forgejo.sh`. Since the repo is the source of truth, copying
  unconditionally on re-run is correct (mirrors how `init-dockge.sh` always
  overwrites the Dockge compose), and Part B step 3 disappears from the guide.
- **Bind-mount instead** (more consistent): mount the repo's
  `infra/forgejo/config.yml` read-only at `/data/config.yml` in the runner
  service, like the monitoring stack mounts all its configs. No copy at all;
  edits flow with `git pull` + restart.

Recommendation: the bind-mount — it matches the stated convention ("config
lives in the repo, bind-mounted read-only") and removes a manual step and a
drift source. The copy is the fallback if keeping `/data` self-contained
matters more.

## 7. Forgejo SSO — should not be framed as optional

**Finding:** SSO is presented as "optional, recommended"; it should be a
prominent section linking the registry.

**Status: Confirmed.** [forgejo-setup.md:155–158](../forgejo-setup.md) buries
SSO in a blockquote. Since SSO is a lab convention (every UI joins Authentik
by one of the two patterns), the guide should carry a proper "SSO" section:
Forgejo joins by **OIDC**, values live in the registry
([sso-applications.md](../sso-applications.md#forgejo-oidc)), procedure in
the Authentik guide's then-Part B,
local login stays enabled as break-glass. Not optional; the only sequencing
note is that it happens after the admin account exists.

## 8. Grafana guide — Loki readiness check uses `wget` that isn't in the image

**Finding:** `docker compose exec loki wget -qO- localhost:3100/ready` fails
with `exec: "wget": executable file not found in $PATH`.

**Status: Confirmed.** The stack pins `grafana/loki:3`
([infra/monitoring/compose.yaml:141](../../infra/monitoring/compose.yaml)), and
the 3.x image ships no wget/curl/shell utilities to speak of. Loki's port is
not published, so the check must run from a neighbouring container that *does*
have wget — both of which the docs already use elsewhere (the Grafana
container in [grafana-setup.md troubleshooting](../grafana-setup.md#troubleshooting),
the Alloy container in the since-merged `monitoring-setup.md`):

```bash
docker compose exec alloy wget -qO- http://loki:3100/ready
```

Update Part 2 and the verification checklist accordingly.

## 9. SSO registry — Forgejo "Auto Registration" is not a UI setting

**Finding:** the registry says *Auto Registration: enabled; account linking
automatic (link by email)* — no such setting exists in the Forgejo form.

**Status: Confirmed.** In Forgejo (as in Gitea), the **Add Authentication
Source** form has no auto-registration or account-linking fields. Those are
instance-level settings in the `[oauth2_client]` section of `app.ini`:
`ENABLE_AUTO_REGISTRATION` (default `false`) and `ACCOUNT_LINKING` (default
`login`, wanted: `auto`). Neither is set in
[infra/forgejo/compose.yaml](../../infra/forgejo/compose.yaml), so with the
defaults the "Sign in with authentik" flow drops the user at a manual
link-account prompt instead of linking by email silently.

**Fix:** configure it where it actually lives — the compose file:

```yaml
FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION: "true"
FORGEJO__oauth2_client__ACCOUNT_LINKING: "auto"
```

Then correct the registry row (these values are compose-side, not clickwork —
the "Where configured" column changes too) and drop the corresponding
instruction from the Authentik guide's then-Part B, step 3.

## 10. Monitoring guide — written as a migration, and should merge into the Grafana guide

**Finding:** the deployment section is really a migration ("git pull",
"upgrading a live install"); the repo should always assume from-scratch. Since
what remains is only verification, merge it into the Grafana guide.

**Status: Confirmed.** `monitoring-setup.md` (since merged away) tells a
fresh installer to `git pull` mid-build (its Deploy section) and carries an
"Upgrading a live install?" caveat plus phase-history narration — all
migration artifacts from the five-phase build. On a fresh checkout, its entire
Deploy section is a no-op (the configs ship final; the Grafana guide's
`docker compose up -d` already started everything), so the guide's real
content is *verification plus reference material*.

**Fix — adopt as policy and restructure:**

- **Policy:** guides always describe a from-scratch bring-up of the current
  checkout. No migration paths, no phase history in guides (the roadmap and
  superpowers docs keep the history). A `git pull` anywhere but the initial
  clone is a red flag in any guide.
- **Merge:** fold the verification parts (logs, metrics, OTLP, dashboards,
  alerts) into the Grafana guide's verification, and keep the genuinely
  explanatory material (the four-label design, query starters, the socket and
  open-endpoint trust notes, troubleshooting) as that guide's
  "detailed explanation" tail per the template. `monitoring-setup.md` is then
  deleted.
- **Consequences to sweep:** README (layout table, build order step 7, status
  row), cross-links in `dns-records.md` / other guides, and **CLAUDE.md**,
  whose "Docs layout" section currently documents the two-guide split as
  deliberate — it must be rewritten to match, or the next session will
  faithfully preserve the split.

---

## Cross-cutting

### Guide template

The guides grew one at a time and it shows: prerequisites are sometimes a
section, sometimes a Part 0 that re-explains earlier guides; verification is
variously inline, a Part, or a checklist; some guides link onward, some
don't. Target structure for every setup guide:

1. **Headline**
2. **Prerequisite** — one line linking the previous guide in the build order
   (not a restatement of it)
3. **What this stack is** — short general explanation
4. **Steps** — numbered, with verification where needed; **every command in
   its own fenced block** so it can be copied in one click (no comments-plus-
   commands mixed in one block, no `cd x && do-thing` chains that exist only
   to save a block)
5. **Jump-off** — link to the next guide
6. **Troubleshooting**
7. **Stack structure & layout** — where things live on disk, what's in the repo
8. **Detailed explanation** — the why, design notes, trust tradeoffs
9. **Jump-off** (repeated) — for readers who read to the end

The split puts the *doing* path first and short — steps a returning operator
can sprint through — with all explanation below the fold. Guides are written
for a from-scratch bring-up of the latest checkout (see item 10's policy).

Per-guide gaps against this template, roughly: traefik (verification placement
— item 1; explanation interleaved with steps), authentik (forward references —
item 2; Parts A–C mix steps and rationale), dockge (missing entirely — item
3), forgejo (Part 0 duplication — item 4; SSO section — item 7), grafana
(absorbs monitoring-setup — item 10), proxmox/wildcard-dns (structure pass
only; no functional findings from the replay).

### Build order

**Decided:** Dockge stays behind Authentik — publishing a port for an earlier
bootstrap view was considered and rejected (it would leave a permanently
un-gated LAN path and mean adjusting ports back afterwards; keeping the flow
lean wins). The final order:

1. Proxmox + VMs
2. DNS
3. Traefik
4. Authentik
5. **Dockge** (new position — own guide, item 3)
6. Forgejo
7. Grafana (including what was monitoring-setup)

With special mentions of the two registries — **[dns-records.md](../dns-records.md)**
at the DNS step (every later step assumes the records exist) and
**[sso-applications.md](../sso-applications.md)** at the Authentik step (every
SSO join starts with its registry row).

This fixes the forward-reference mess (item 2) with **no compose changes**,
and gives a browser view from Dockge onward — Forgejo and Grafana can be
watched and driven from its UI as they come up. Traefik and Authentik
themselves stay CLI-only bring-ups, which is inherent: they are the routing
and the gate that any browser view depends on. Align the README, the new
Dockge guide, the compose comment block, and `init-dockge.sh`'s header
comment (both already say "after Traefik and Authentik", so they mostly just
gain the guide link).

### README

- **Jump-off before Architecture:** add a short "Start here" line right after
  the intro — link to the first guide (proxmox-setup.md) and the build order —
  so a reader who wants to build doesn't scroll through architecture prose
  first.
- **Build order list:** rewrite per the chosen option above; give the two
  registries their special mentions; renumber; keep Coolify as the trailing
  TBD step. The Status table loses its monitoring-setup link if item 10's
  merge lands.

---

## Work items — all complete

1. ✅ `docs/dockge-setup.md` written; build-order position 5. Absorbed the
   Dockge references from the Authentik and Forgejo guides.
2. ✅ Forgejo compose: `oauth2_client` env vars (item 9) and the runner
   `config.yml` bind-mount (item 6). Registry and guides updated.
3. ✅ Grafana guide: Loki check fixed (item 8), `monitoring-setup.md` merged in
   and deleted (item 10).
4. ✅ All seven guides restructured to the shared template (items 1, 2, 4, 7
   folded in); clock-skew cross-references added to the Traefik and Forgejo
   troubleshooting sections (item 5).
5. ✅ README "Start here" jump-off and rewritten build order; CLAUDE.md updated
   to match the new docs layout, ordering, and the from-scratch-only policy.

**Verified after the changes:** every internal markdown link and heading anchor
across the eleven docs resolves; all five compose stacks parse under
`docker compose config` (the only errors are the intentional `${VAR:?}` guards
firing with no `.env` present); the Forgejo runner's three mounts render as
expected; `bash -n` passes on `init-host.sh`; and no file picked up CRLF
endings.

Two follow-ups worth considering, neither blocking and neither part of the
original findings:

- The runner registration command in
  [forgejo-setup.md](../forgejo-setup.md#4-register-the-runner) still passes a
  redundant `-v /opt/forgejo/runner:/data`; the compose service already mounts
  it. Left exactly as replayed, since that form is known to work.
- The whole build has not been replayed end to end *since* these edits. The
  changes are documentation plus two compose additions, but the Forgejo SSO
  path (`oauth2_client` auto-linking) and the runner config bind-mount are the
  two that genuinely change runtime behaviour and deserve a fresh-install pass.
