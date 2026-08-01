# Dockge — compose management UI (infra VM)

**Runs on:** infra VM

**Prerequisite:** [authentik-setup.md](authentik-setup.md) complete — Authentik
must be running before Dockge's router will load at all.

[Dockge](https://github.com/louislam/dockge) is a small web UI for Docker
Compose stacks, at **`https://dockge.thefipster.de`**. It lists every stack
under `/opt/stacks`, and lets you start, stop, restart, edit and read logs from
a browser instead of `ssh`-ing in. The other init scripts symlink their stacks
into that directory, so from here on the remaining stacks — Forgejo, monitoring
— can be driven from this UI.

It is a *lifecycle* tool, not a provisioning tool: it never replaces the init
scripts, which do host-level work (data directories, ownership, secrets) that
Dockge cannot. See [What Dockge does and does not do](#what-dockge-does-and-does-not-do).

## Steps

### 1. Create the Dockge application in Authentik

Dockge has no SSO support of its own, so it joins by **forward-auth** at the
proxy. Follow the same click-path as the Traefik dashboard
([authentik-setup.md, step 3](authentik-setup.md#3-gate-the-traefik-dashboard-forward-auth)) —
create a **Proxy Provider**, then an **Application**, then attach it to the
embedded outpost — using the Dockge column of the registry:
[sso-applications.md](sso-applications.md#forward-auth-dockge--traefik-dashboard).

The Traefik half is already in the repo: the `authentik@docker` middleware and
the `dockge.thefipster.de` outpost router are labels on the Authentik `server`
container, and the middleware label is on Dockge's own router.

### 2. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-dockge.sh
```

> **This script starts the stack itself.** It is the only init script that
> does — the others stop after preparing directories and `.env`, leaving the
> `docker compose up -d` to you. There is **no compose step here**; when the
> script returns, Dockge is already running.

It copies `infra/dockge/compose.yaml` to `/opt/stacks/dockge/`, writes
`REPO_DIR` into the `.env` beside it, ensures the `proxy` network exists, and
brings the stack up.

### 3. Log in and create the local admin

Open **`https://dockge.thefipster.de`** in a private window. You are redirected
to Authentik; sign in, and you land on Dockge's **first-run setup screen**.
Create its local admin account there.

> **Two logins, by design.** Forward-auth is only the *outer* gate: Authentik
> decides who may reach Dockge at all, but Dockge cannot consume Authentik
> identities, so its own local login stays underneath. The account you create
> here exists only inside Dockge — Authentik usernames are never valid
> credentials in its form.
>
> If you see no Authentik redirect, you are simply still signed in from an
> earlier check; forward-auth passes a valid session through silently. The
> private window is what makes the flow visible.

### 4. Verify

- [ ] `https://dockge.thefipster.de` redirects to Authentik, and returns to
      Dockge after login
- [ ] The trusted wildcard certificate is served (no browser warning)
- [ ] Dockge lists a `dockge` stack — it manages itself
- [ ] `Dockge` appears as its own application in Authentik under
      **Admin → Events → Logs**

Stacks added later (Forgejo, monitoring) appear in the list as soon as their
init scripts symlink them in — nothing to configure in Dockge itself.

## Next

**[forgejo-setup.md](forgejo-setup.md)** — CI and the container registry. It is
the first stack you can bring up from this UI instead of the CLI.

## Troubleshooting

**404 at `dockge.thefipster.de`, and Traefik logs `middleware
"authentik@docker" does not exist`.** Authentik is not running. Dockge's router
references that middleware, and Traefik refuses to load a router whose
middleware is undefined. Start Authentik
([authentik-setup.md](authentik-setup.md)); the router loads within seconds.

**Break-glass — reaching Dockge with Authentik down.** Comment the middleware
label in `/opt/stacks/dockge/compose.yaml`:

```yaml
# traefik.http.routers.dockge.middlewares: authentik@docker
```

```bash
cd /opt/stacks/dockge && docker compose up -d
```

Dockge's own login still protects it. Restore the label afterwards. (Note this
edits the *copy* under `/opt/stacks/dockge`, not the repo — see
[Layout](#layout-on-the-server).)

**A stack is listed but Dockge cannot read its compose file.** The symlink
dangles inside the container. `/opt/stacks/<stack>` points into the repo
checkout, so the container needs that checkout mounted at the *same absolute
path* — which is what `REPO_DIR` does. Re-run `scripts/init-dockge.sh` from the
checkout, and confirm it recorded the right path:

```bash
cat /opt/stacks/dockge/.env
```

If you moved the repo after installing Dockge, this is the symptom.

**A stack is missing from the list entirely.** Dockge only shows
`/opt/stacks/<name>/compose.yaml`. Check the symlink exists:

```bash
ls -l /opt/stacks
```

Each stack's own init script creates it.

## Layout on the server

Dockge is the one stack that is **copied** rather than symlinked, because it
must keep running while you edit other stacks from it:

| What | Where |
|------|-------|
| Compose project (source of truth) | `infra/dockge/compose.yaml` in this repo |
| Deployed copy + its `.env` | `/opt/stacks/dockge/` |
| Dockge's own state | `/opt/stacks/dockge/data/` |
| Managed stacks | `/opt/stacks/<name>/` — symlinks into this repo |

To change Dockge itself, edit the repo file and re-run `scripts/init-dockge.sh`;
it overwrites the copy (the `.env` holds only `REPO_DIR`).

## How it works

**Everything hinges on identical paths.** Dockge does not reimplement Compose —
it *shells out* to `docker compose` and talks to the host Docker daemon through
the mounted socket. The containers it starts are therefore created by the host
daemon, which resolves every path against the **host** filesystem. So any path
Dockge passes must mean the same thing inside its container and outside it.
Two mounts guarantee that:

- `/opt/stacks:/opt/stacks` — the stacks directory at its real path.
- `${REPO_DIR}:${REPO_DIR}` — the repo checkout at *its* real path. The stacks
  under `/opt/stacks` are symlinks into the checkout; without this mount they
  would dangle inside the container and Dockge could not read them.

This is also why [infra-vm-setup.md](infra-vm-setup.md#1-clone-the-repo)
insists on cloning to `~/home-lab` and not moving it afterwards.

**The socket is root-equivalent.** Dockge holds `/var/run/docker.sock`, which
means full control of this VM's Docker — it can start a privileged container,
so it is effectively root on the box. That is inherent to what it does, and the
same trade Traefik, the Forgejo runner and Alloy already make. It is acceptable
because this is a single-tenant machine, and it is exactly why the UI is gated
by Authentik rather than merely by Dockge's own login.

**No ports are published.** Dockge is reachable only through Traefik, on
`proxy`. There is no plain-HTTP port on the infra VM bypassing the gate — which is
why Authentik has to come first in the build order, and why the break-glass
path above is a label edit rather than a port.

## What Dockge does and does not do

**Does:** start, stop, restart, view logs, and edit the compose file of any
stack under `/opt/stacks`.

**Does not:** create data directories, set the ownership each image needs,
generate secrets into `.env`, or perform one-time registrations. That is what
the `init-*.sh` scripts are for, and every later guide still starts with one.
Forgejo is the clearest case — its init script creates and `chown`s
`/opt/forgejo`, computes `DOCKER_GID`, and generates the database password;
Dockge only takes over starting and stopping the stack afterwards.

## Next

**[forgejo-setup.md](forgejo-setup.md)** — CI and the container registry, the
first stack you can drive from this UI. The full sequence is in the
[README build order](../README.md#build-order).
