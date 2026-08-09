# Homepage — token-backed service widgets

**Date:** 2026-08-09
**Status:** Approved design, pending implementation plan
**Builds on:** Homepage, deployed and verified on the infra VM —
[docs/homepage-setup.md](../../homepage-setup.md),
[the original design](2026-08-08-homepage-design.md).

## Goal

Give three tiles on `home.thefipster.de` live data instead of a status dot:
**Authentik**, **Forgejo** and **Grafana**. Each needs a credential, so this is
also the change that gives the Homepage stack its first `.env` — the event the
original design named and deferred:

> Adding a widget later is an additive change, and the first one added is what
> introduces the `.env`.

Everything that made Homepage a special case follows from that one file, so the
work is one-third widget and two-thirds keeping the repo internally consistent.

## Scope

**In:** Authentik, Forgejo, Grafana.

**Out, and why** — the four other services on the page that have an upstream
widget:

- **Proxmox.** Its API is HTTPS-only on `:8006` behind a self-signed
  certificate ([proxmox-setup.md](../../proxmox-setup.md)), and Homepage is
  Node — it refuses the connection. The two fixes both cost more than the
  widget is worth. `NODE_EXTRA_CA_CERTS` means copying
  `/etc/pve/pve-root-ca.pem` off the hypervisor and mounting it, which
  reintroduces the `/opt/homepage` directory this stack is defined by not
  having. `NODE_TLS_REJECT_UNAUTHORIZED=0` is one line but disables
  certificate verification for *every* outbound request Homepage ever makes —
  a trap set for whoever adds the next widget. Host CPU and memory are already
  on Grafana's Node Exporter Full dashboard; only the VM/LXC counts are lost.
- **The Traefik dashboard.** Its router is forward-auth gated, so a widget
  would authenticate against Authentik rather than Traefik.
- **Home Assistant and the apps-VM applications.** Not built —
  [status.md](../../status.md) has the apps catalog at written-not-deployed and
  the HA VM at guide-ready. A widget pointed at a machine that does not exist
  cannot be verified, and this repo's guides describe bring-ups that were run.
- **Vaultwarden, Dockge and Coolify** have no upstream widget at all, verified
  against the widget index. Coolify's absence is worth stating plainly, because
  "the apps VM is not populated yet" reads like a reason that expires and this
  one does not.

All of these become rows in the absences section of the new registry, so the
next person to ask reads the reasoning instead of re-deriving it.

## Mechanism

Homepage substitutes environment variables into config files: the value of
`HOMEPAGE_VAR_XXX` replaces `{{HOMEPAGE_VAR_XXX}}` in any config. So the
credential lives in `.env`, the compose passes it through, and
`config/services.yaml` stays git-tracked with no secret in it — which is what
keeps the read-only config mount workable.

Four values, three secrets:

| Var | Widget | What it is |
|-----|--------|------------|
| `HOMEPAGE_VAR_AUTHENTIK_KEY` | `authentik` | Authentik API token |
| `HOMEPAGE_VAR_FORGEJO_KEY` | `gitea` | Forgejo access token |
| `HOMEPAGE_VAR_GRAFANA_USER` | `grafana` | Grafana username — not a secret |
| `HOMEPAGE_VAR_GRAFANA_PASSWORD` | `grafana` | that user's password |

Guards are `${VAR:?message}`, the repo default rather than the documented
`${VAR:-}` exceptions. An unset token stops the stack instead of silently
blanking a tile. It does not make rotation fragile: a guard fires on unset or
empty, and an **expired** token is still a non-empty string, so an expired
credential degrades one tile exactly as it should.

## Backends: container-to-container, never through Traefik

All three widgets dial the container directly over the shared `proxy` network,
which is the pattern the existing Uptime Kuma widget already uses
(`http://uptime-kuma:3001`).

| Widget | URL | Notes |
|--------|-----|-------|
| `authentik` | `http://authentik-server:9000` | `version: 2` — required for Authentik ≥ 2025.8.0, and the lab pins `2026.5`. `authentik-server` is an explicit network alias declared in `infra/authentik/compose.yaml`. |
| `gitea` | `http://forgejo:3000` | Alloy already scrapes this exact address, so the path is proven. |
| `grafana` | `http://grafana:3000` | `version: 2` — required for Grafana > v10.4, and the lab pins `13.1`. |

This is not an optimisation. Going through Traefik would mean a TLS hop back
into the same VM, and for anything forward-auth gated it would mean
authenticating against Authentik rather than the service. Keeping widget
traffic on `proxy` is what makes the gate irrelevant to it.

## Grafana is a credential, not a token

The upstream widget offers `username` and `password` only — no API key, no
service-account token. That leaves two options and one of them is bad:
reusing `GRAFANA_ADMIN_PASSWORD` would copy monitoring's **admin** credential
into a second stack's `.env` and into a second restic snapshot, and rotating it
in one place would silently break the other.

Instead, a **dedicated local Grafana user `homepage` with the Viewer role**,
carrying its own password. Local login is already kept enabled as break-glass
beside OIDC, so this costs nothing that is not already there.

One thing the upstream documentation does not settle: the widget's
`datasources` field reads `/api/datasources`, which Grafana restricts to
admins. If a Viewer account blanks the whole tile rather than that one figure,
the fix is to scope the widget with `fields: [dashboards, alertstriggered]`
rather than to raise the role. **Whichever it turns out to be is verified on
the box and recorded in the registry** — the repo does not ship a permission
claim it has not run.

## The registry

A fourth registry, `docs/homepage-widgets.md`, alongside `dns-records.md`,
`sso-applications.md` and `uptime-kuma-monitors.md`. Same contract: it carries
`**Runs on:** … — registry, not a build step`, it holds the manual operations
that live outside the repo, guides link it instead of restating it, and it
lists its deliberate absences beside its entries.

Minting a token in Authentik's admin portal is exactly the kind of clickwork
the three existing registries exist to centralize. Per widget it records: where
to click, the exact scopes or role, the `.env` variable name, and the
`services.yaml` snippet.

The alternative considered was one document per integration under a new
`docs/homepage/` directory. Rejected: `docs/` is flat on purpose, and three
files would each restate the same `.env` + compose mechanism.

**Cross-registry note.** An Authentik *API token* is not an Authentik
*application*, so `sso-applications.md` gains no row — Homepage's row there
stays the forward-auth one it already has.

## The `.env` fallout

Homepage stops being the stack with no `.env`, and that property is asserted in
six places. All of them are rewritten, not patched around:

- `infra/homepage/compose.yaml` — the header block claiming no `.env` and no
  secret to seed.
- `scripts/init-homepage.sh` — the header, plus the script itself: it now seeds
  `.env` from `.env.example`, the way `init-traefik.sh` does. It stops being
  the thinnest init script in the repo.
- `scripts/init-uptime-kuma.sh` — its comment names Homepage as the other stack
  with no `.env`. Kuma becomes the only one.
- `docs/homepage-setup.md` — a new step for minting the credentials, checklist
  rows, troubleshooting entries, the layout listing, and the design note *Why
  there are no token-backed widgets*, which is now the note explaining which
  four services still have none.
- `docs/roadmap/backup.md` — the Homepage non-row becomes a row.
- `CLAUDE.md` — the backup convention paragraph, the `.env` gotcha, and the
  init-script entry.

Per repo policy there is no migration note anywhere: the guides describe a
fresh bring-up of the current checkout, and the old state leaves no trace.

## Backup

Homepage joins the restic layer: `infra/homepage/backup.sh` and
`infra/homepage/restore.sh`, so the rule *every stack that holds state is
wired* stays true with no exception to remember.

`backup.sh` is `include_env` and nothing else — the include-only form, one
recipe. Every other byte the stack owns is the git-tracked YAML in `config/`,
which is why this is the smallest backup in the lab, smaller than Traefik's.

`restore.sh` follows the standard shape — stage the snapshot, check it before
touching anything live, replace `.env`, restart — with no `/opt` tree to move
aside, because there still is not one. It is deliberately more ceremony than
one file needs; the value is that `infra/*/restore.sh` means the same thing
everywhere.

### What joining the backup layer touches

`infra/backup/run.sh` needs **no code change**. It globs `infra/*/backup.sh`,
so a stack joins by having the file exist and leaves by deleting it — which is
the property that arrangement was chosen for, and it holds here. Verified by
reading `run.sh`, not by trusting the claim in `CLAUDE.md`.

What it does need is a **comment** change, and that comment is the first of
nine places where the backup layer states how many stacks it has:

- `infra/backup/run.sh` — "one stack failing must not cost the other **six**
  their snapshots".
- `docs/backup-setup.md` — three: the expected `OK:` line "naming all
  **seven**", the checklist row, and "one snapshot per tag — **seven** in all".
- `docs/backup-setup.md` again — it cites Homepage's design notes as the stack
  that deliberately gets no backup.
- `docs/backup-restore-drill.md` — the per-stack table of markers and proofs
  gains a `homepage` row. Its marker is to corrupt one token in `.env`; the
  check that proves it is that the tile renders data again after the restore,
  which exercises the widget and the backup in one move.
- `docs/roadmap/backup.md` — "all **seven** stacks drilled".
- `docs/status.md` — "All **seven** stateful infra stacks wired and
  restore-drilled".
- `CLAUDE.md` — the backup convention names the wired stacks explicitly:
  Authentik, Dockge, Forgejo, monitoring, Traefik, Uptime Kuma, Vaultwarden.

**Prefer durable wording to a bumped number.** Where the count is incidental —
the `OK:` line, the snapshot check, the drill summary — reword to something
that survives the stack after this one ("one snapshot per tag", "every stack
with a `backup.sh`") rather than writing "eight" and queuing the same edit up
again. Where the list is the point, as in `CLAUDE.md`, name Homepage.

Three phrases match a search for these numbers and must **not** change:
"seven dailies" in `backup-setup.md` and `CLAUDE.md` is the `--keep-daily 7`
retention policy, and "seventh root-equivalent socket mount" in
`backup-setup.md` and `roadmap/backup.md` counts socket mounts, not stacks.

### Why wire it at all

The counter-argument, recorded because it is a real one: all three credentials
are re-mintable in about three minutes by clicking through the new registry,
unlike Traefik's netcup keys (an external account) or Vaultwarden's
`rsa_key.pem` (irreplaceable). Wiring it anyway is a consistency choice — the
alternative leaves exactly one `.env` in the lab that is not covered, and a
special case with no marker on it is how a real gap gets introduced later.

## Verification

On the infra VM, after the change:

1. `docker compose ps` shows `homepage` running — a missing `.env` value now
   stops the stack, which is the guard working.
2. The Authentik tile shows user and login counts. A blank tile with
   `version: 2` removed is the ≥ 2025.8.0 API split.
3. The Forgejo tile shows repository, issue and pull counts. Upstream documents
   this widget as `gitea` and never mentions Forgejo — the API is
   Gitea-compatible, but **this is the one integration whose compatibility is
   an assumption until the tile renders.** If it does not, the widget is
   dropped and becomes an absence row rather than being worked around.
4. The Grafana tile shows dashboard and alert counts, and the registry records
   whether Viewer sufficed or the `fields` list was needed.
5. `sudo infra/homepage/backup.sh` under a staging dir produces a `paths.txt`
   naming the checkout's `.env`, not `/opt/stacks/homepage/.env` — symlinks are
   stored as symlinks, which is why `include_env` resolves against
   `$REPO_ROOT`.
6. A restore drill: `sudo infra/homepage/restore.sh`, then the three tiles
   still render.

## Out of scope

- Info widgets in `widgets.yaml`. It stays deliberately empty; the reasoning in
  that file is unaffected.
- Any change to which services appear on the page. This adds data to existing
  tiles and adds no tile.
- Bumping the Homepage image pin.
