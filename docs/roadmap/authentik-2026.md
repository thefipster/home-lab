# Roadmap: move Authentik off the 2025.6 pin

Goal: get `infra/authentik` onto a current Authentik release. The stack is
pinned `2025.6` on both `server` and `worker`
([infra/authentik/compose.yaml](../../infra/authentik/compose.yaml)), and
upstream's train has since reached **2026.5**.

Raised by the [2026-08-01 guide replay](../review/2026-08-01-guide-replay.md#10-authentik--what-would-moving-to-a-2026-release-cost).
Not done in that pass, deliberately — see [Why this is not a docs
change](#why-this-is-not-a-docs-change).

## The cost is in 2025.12, not in 2026

The intuition that "moving to 2026" is the work is wrong. The intervening
releases are `2025.12` → `2026.2` → `2026.5`, and almost everything that
touches this lab landed in the first of them.

| Release | What it costs here |
|---|---|
| **2025.12** | The whole bill. Storage rework **and** RBAC rework — both below. |
| **2026.2** | SCIM group syncing now filters users by the policies bound to the application, and gains a group selector. **No impact** — this lab runs no SCIM provider. |
| **2026.5** | Default listen address moves `0.0.0.0` → `[::]`; `AUTHENTIK_POSTGRESQL__CONN_OPTIONS` is deprecated. **No impact** — the compose sets neither, and both containers are reached over Docker networks by name. |

### 2025.12, part one: storage moved

Media moves out of `/media` and under a `/data` mount, served at `/files`
instead. That is a **repo change, not clickwork** — the compose bind-mounts
`/opt/authentik/media:/media` on **both** `server` and `worker`, and
[`scripts/init-authentik.sh`](../../scripts/init-authentik.sh) creates and
`chown`s that directory to UID 1000. Both have to move together, and the
script's comment about the `tenant_files` migration creating `/media/public`
needs re-checking against the new layout rather than carried across.

For a **fresh** build this is the entire change: new paths in the compose, new
paths in the init script, done. For **this running lab** it additionally means
moving the existing media into place before the new container starts.

### 2025.12, part two: RBAC

- **Group names must be unique before the upgrade**, or the migration fails and
  needs manual remediation. Check first — this lab's groups are few (`lab-users`
  and whatever the SSO registry lists), so this is a look, not a project.
- `Group.parent` becomes a many-to-many `Group.parents`; groups now inherit
  permissions from ancestors rather than only superuser status.
- All permissions must attach to a **role**; direct user-permission grants are
  deprecated and migrated automatically.

None of this is visible in the repo — Authentik's providers, applications and
group bindings are clickwork recorded in
[sso-applications.md](../sso-applications.md), not files. The registry is what
to re-verify after the upgrade, and if any row's meaning changed, the registry
is what to correct.

## The distinction that decides the plan

Upstream requires upgrades to be performed **sequentially by major version** —
two or more releases behind means stepping through each intermediate release.
That constraint binds the **running instance**. It does not bind this repo.

Every guide here describes a from-scratch bring-up of the current checkout
([CLAUDE.md](../../CLAUDE.md)), and a fresh install at `2026.5` steps through
nothing at all. So there are two separate pieces of work, and conflating them
is the trap:

1. **Repo change** — bump both pins, move the media mount to the post-2025.12
   layout in the compose and the init script, verify a clean bring-up. This is
   what `authentik-setup.md` will describe, and it describes only this.
2. **Live-lab operation** — walk the running instance `2025.6` → `2025.12` →
   `2026.2` → `2026.5`, checking group-name uniqueness first and moving the
   media directory at the 2025.12 step. **No guide in this repo covers this, on
   purpose**: guides carry no migration paths. It belongs in a `docs/review/`
   entry once done, or nowhere.

Do (1) and (2) in the same session on the same box, but write down only (1).

## Why this is not a docs change

The replay pass that surfaced this corrected nine guides by reading. Reading is
the only verification a documentation change gets here, and it is enough for
every one of those nine. It is not enough for this: Authentik gates the Traefik
dashboard, Dockge, Grafana and Forgejo, so a failed bring-up takes the lab's
whole UI surface with it — and landing it beside nine unrelated corrections
would make a broken SSO indistinguishable from any of them.

This wants its own branch, its own snapshot, and its own replay of
[authentik-setup.md](../authentik-setup.md) end to end.

## Checklist when it happens

- [ ] Snapshot the infra VM first (`clean-install` is not enough — take a fresh
      one; [proxmox-setup.md Part 7](../proxmox-setup.md#part-7--snapshot-before-you-build))
- [ ] Confirm every Authentik group name is unique **before** starting
- [ ] Re-read the release notes for each release actually stepped through — the
      table above is a summary, and only 2025.12's two items were traced to
      files in this repo
- [ ] Compose: bump `server` and `worker` pins together; they must match, and
      outposts must match the instance
- [ ] Compose + `init-authentik.sh`: media under `/data`, not `/media`
- [ ] Keep the **major.minor** pin and its comment — the reason for it
      (breaking DB migrations between minors) is exactly what this document
      documents, so it survives the bump
- [ ] Re-verify every row of [sso-applications.md](../sso-applications.md), and
      the forward-auth middleware in particular — Dockge and the Traefik
      dashboard fail closed if `authentik@docker` does not resolve
- [ ] Break-glass check: `akadmin` still logs in locally
- [ ] Update the pin exception list in [CLAUDE.md](../../CLAUDE.md)
