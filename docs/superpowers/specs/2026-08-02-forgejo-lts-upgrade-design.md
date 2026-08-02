# Forgejo image pins move to the current LTS

**Date:** 2026-08-02
**Status:** Approved design, pending implementation

## Goal

Move `infra/forgejo` off the pins it has carried since the stack was built —
`codeberg.org/forgejo/forgejo:11` and `code.forgejo.org/forgejo/runner:6` — onto
current upstream. Forgejo 11 was the LTS of its day; it is no longer, and the
runner is six majors behind. No migration path is in scope: the lab is applied
from scratch, so this is a change of what a fresh bring-up installs, nothing
more.

## Upstream state as of 2026-08-02

| Track | Version | Supported until |
|-------|---------|-----------------|
| Forgejo stable | 16.0.2 (2026-07-30) | 2026-10-29 |
| Forgejo **LTS** | **15.0.6** (2026-07-30) | **2027-07-15** |
| Forgejo, currently pinned here | 11 (last patch 11.0.16, 2026-07-09) | — |
| Runner | 12.13.2 (2026-07-23) | — |

Bare-major tags `15`, `16` and runner `12` are all published, so the repo's
major-only pin policy survives unchanged.

## Constraints & decisions made

- **The pin follows LTS, not latest stable.** `forgejo:15`, not `forgejo:16`.
  Forgejo's non-LTS majors carry roughly a three-month support window — 16 is
  already dated 2026-10-29 — while 15 runs to 2027-07-15. This lab is bumped
  when someone sits down to bump it, not on a release cadence, so the track
  that tolerates a long gap is the right one. It is also what the repo already
  did: 11 was the LTS of its day. The consequence to accept is that the pinned
  number will normally *lag* the newest release, and reads as stale to anyone
  who does not know the policy — which is why the policy gets written down in
  both `compose.yaml` and `CLAUDE.md` rather than left as a number.
- **The runner moves to `12` in the same change, not separately.** Forgejo 13
  began validating Actions workflows against a YAML schema server-side, and
  runner 8 began doing the same before starting a job. A runner from before
  that gate, paired with a server after it, means the two halves disagree about
  what a valid workflow is. Runner 12's own breaking change — it now requires a
  `git` binary to fetch remote actions — is satisfied by the OCI image, which
  ships one.
- **Nothing else in the stack changes.** Verified against the `v15.0.6` image
  rather than assumed:
  - the entrypoint still honours `USER_UID` / `USER_GID`, so the `1000:1000`
    ownership that `scripts/init-forgejo.sh` applies is still correct;
  - `EXPOSE 22 3000` and `VOLUME /data` are unchanged, so the published `222:22`
    mapping, the Traefik `loadbalancer.server.port: 3000` label and both bind
    mounts still line up;
  - runner 12's config schema still accepts every key in
    `infra/forgejo/config.yml` (`capacity`, `labels`, `cache.enabled`,
    `container.network`, `container.options`, `docker_host: automount`). The
    default for `docker_host` moved to `"-"`, but `"automount"` remains
    supported and is what this repo sets explicitly.
- **`postgres:16-alpine` stays.** Forgejo 15 imposes no new floor that a
  Postgres 16 fails to meet.

## The Authentik OIDC integration needs no changes

This was the second half of the request, and the answer is that the registry
and the compose are already correct for 15. Checked, not assumed:

- **The Forgejo-side form is unchanged.** Diffing
  `templates/admin/auth/source/oauth.tmpl` between `v11.0.16` and `v15.0.6`
  shows the same field set. The three values
  [`sso-applications.md`](../../sso-applications.md#forgejo-oidc) pins down —
  Authentication Name `authentik`, the Auto Discovery URL, and the Client ID /
  Secret — are all still there and still mean the same thing.
- **The callback path is unchanged**, so the Authentik provider's exact
  redirect URI `https://git.thefipster.de/user/oauth2/authentik/callback`
  remains right. Forgejo still builds it from the authentication source's name,
  which is why that name must stay exactly `authentik`.
- **Both instance-level settings still exist** in `[oauth2_client]` on 15:
  `ENABLE_AUTO_REGISTRATION` and `ACCOUNT_LINKING`. The compose keeps shipping
  them, and account linking still matches on **email** — so the constraint that
  the Authentik user and the Forgejo admin share an address is unchanged.
- Forgejo 16 *adds* optional OIDC fields (dynamic group maps, quota-group
  claims, a `preferred_username` option for `[oauth2_client] USERNAME`) and an
  opt-in "Remember me" for SSO sessions via `prompt=none`. None of it is on 15,
  none of it is required, and none of it changes a value in the registry.

`docs/sso-applications.md` is therefore left alone. Editing it to say "still
correct" would be churn.

## A breaking change that does not apply, and why it is not documented

Forgejo **16** removes `REVERSE_PROXY_TRUSTED_PROXIES = *` from the Docker
image's `app.ini` template, dropping to the `127.0.0.0/8,::1/128` default. Since
Traefik dials Forgejo from a Docker bridge address, that would make Forgejo
record Traefik's container IP as every client's address. Upstream declined to
backport it, and the template at `v15.0.6` still carries the `*` — so on the
chosen track there is nothing to change and nothing to warn about. It is
recorded here, in the dated spec, because that is where a decision not yet
relevant belongs; the guides describe a from-scratch bring-up of the current
checkout and must not grow a note about a version this repo does not pin.

## Changes

1. **`infra/forgejo/compose.yaml`** — `forgejo:11` → `forgejo:15`,
   `runner:6` → `runner:12`, each with a comment carrying the reasoning above.
2. **`CLAUDE.md`** — the image-pin policy paragraph: update the `forgejo:11`
   example, and state that the Forgejo pin tracks LTS. Without that, the next
   bump has no reason not to jump to whatever is newest.
3. **`docs/forgejo-setup.md`** — one troubleshooting entry for the failure mode
   the runner bump introduces: a workflow that fails schema validation never
   starts, and `forgejo-runner validate` is how you find out why. The shipped
   `build-and-push.yml` is a template whose placeholders the user edits in their
   own repo, so this is a live path, not a hypothetical.

## Out of scope

- Any upgrade or migration procedure. The lab is applied from scratch.
- `infra/forgejo/build-and-push.yml`'s action versions
  (`checkout@v4`, `upload-artifact@v4`, `login-action@v3`,
  `build-push-action@v6`) and its `node:20-bookworm` default job image. They
  work as they are; bumping them is a separate decision with its own
  verification, and folding it in here would hide it behind a version bump.
- `docs/sso-applications.md`, `docs/uptime-kuma-monitors.md`,
  `docs/dns-records.md` and `infra/monitoring/alloy/config.alloy` — none of them
  names a Forgejo version, and none of the values they hold changed.
