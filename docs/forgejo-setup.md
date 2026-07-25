# Forgejo CI + registry (infra VM)

Runs the chain **GitHub → Forgejo (pull mirror) → build → push to Forgejo
registry** on the **infra VM** (Ubuntu Server 26.04). See the [main
README](../README.md) for how this fits into the wider homelab.

Forgejo sits behind the [Traefik stack](traefik-setup.md) at
**`https://git.thefipster.de`** from its very first run — real TLS via a Let's
Encrypt wildcard, which also makes the built-in container registry a plain
trusted HTTPS registry that any Docker daemon can use with zero configuration.

## Layout on the server

Two locations, by design:

| What | Where | Why |
|------|-------|-----|
| Compose project (this repo) | `~/home-lab` — the Forgejo stack lives in `infra/forgejo/` | You edit/redeploy it as your normal user; no root needed to run `docker compose`. |
| Persistent data | `/opt/forgejo/{postgres,forgejo,runner}` | Stateful data you want to find, `chown`, and back up. Bind mounts, not named volumes. |

## CI build daemon: host Docker socket (no DinD)

The Actions runner runs job containers on the **host Docker daemon** via a
mounted `/var/run/docker.sock`, rather than a Docker-in-Docker service. It's
simpler and reuses the host's layer cache.

The tradeoff: a job with the socket has **root-equivalent control of host
Docker**. That's fine here because CI only ever builds *your own* mirrored repos.
If you ever need to build untrusted / fork code, revert to an isolated runner
(DinD or ephemeral VMs) instead.

## What's here

- `infra/forgejo/compose.yaml` — Forgejo + Postgres + an Actions runner
- `infra/forgejo/config.yml` — runner config (gets copied into place during setup)
- `scripts/init-host.sh`, `scripts/init-forgejo.sh` — Part 0 setup automation
- `Dockerfile` — multi-stage build for your Blazor app (goes in your repo)
- `build-and-push.yml` — the pipeline workflow (goes in your repo)

---

## Part 0 — Server prerequisites

Init scripts automate this section. Run them from the repo checked out in your
home folder:

```bash
cd ~ && git clone <this-repo> home-lab && cd ~/home-lab

scripts/init-host.sh      # machine-level: install Docker + add you to the docker group
# log out / back in (or: newgrp docker) so the group takes effect, then:
scripts/init-dockge.sh    # optional: the Dockge management UI
scripts/init-traefik.sh   # reverse proxy + TLS — complete docs/traefik-setup.md first!
scripts/init-forgejo.sh   # project-level: data tree, DOCKER_GID
```

> **Traefik comes first.** Forgejo's first-run screen is served at
> `https://git.thefipster.de`, so the [Traefik stack](traefik-setup.md) —
> including the staging→production certificate flow — must be up **before**
> you start Forgejo. There is no plain-HTTP phase.

> **Does Dockge replace `init-forgejo.sh`?** No. Dockge only runs the compose
> *lifecycle* (`up`/`down`/logs) for stacks already sitting in `/opt/stacks`. It
> can't do the host-level prep this stack needs — creating and `chown`ing the
> `/opt/forgejo` data dirs and computing `DOCKER_GID` — nor the one-time runner
> registration (Part B). So `init-forgejo.sh` still runs; Dockge just takes
> over starting/stopping the stack afterward. `init-forgejo.sh` symlinks the
> stack into `/opt/stacks` so it appears in the UI.

What each one does:

1. **`init-host.sh` — general host setup.** Installs Docker Engine + the compose
   plugin from Docker's official apt repo and adds the invoking user to the
   `docker` group so you can run it without `sudo`. Log out / back in (or
   `newgrp docker`) afterward for the group to take effect. Safe to re-run.

2. **`init-dockge.sh` — management UI (optional).** Copies `infra/dockge/compose.yaml`
   to `/opt/stacks/dockge/` and starts Dockge (reachable at
   `https://dockge.thefipster.de` once Traefik is up). Purely for convenience —
   skip it if you prefer driving `docker compose` from the CLI.

3. **`init-traefik.sh` — reverse proxy + TLS.** Creates the shared `proxy`
   Docker network and the ACME data dir, seeds `infra/traefik/.env`, and links
   the stack into `/opt/stacks`. Filling in the netcup credentials and walking
   the staging→production certificate flow is its own guide:
   [traefik-setup.md](traefik-setup.md).

4. **`init-forgejo.sh` — project-specific setup.** Does the remaining Part 0
   steps that are specific to this compose stack:

   - Creates the data tree under `/opt/forgejo/{postgres,forgejo,runner}` and
     `chown`s the Forgejo + runner dirs to `1000:1000`. (Forgejo runs as
     UID/GID 1000 — see `USER_UID`/`USER_GID` in the compose file — and must own
     its data dir; Postgres manages its own dir's ownership.)

     > If your login user isn't `1000:1000`, keep the compose `USER_UID`/`USER_GID`
     > and this ownership in agreement — they must match.

   - Records the host `docker` group's numeric GID in `.env`. The runner image
     runs as uid 1000, but `/var/run/docker.sock` is `root:docker`, so the runner
     joins the host `docker` group by GID; the compose file reads `${DOCKER_GID}`
     from `.env`.

   No registry configuration happens here: the registry is served by Traefik at
   `https://git.thefipster.de` with a publicly trusted certificate, so no
   Docker daemon anywhere needs special settings to use it.

---

## Part A — Bring up Forgejo

1. Change into the Forgejo stack directory — **all `docker compose` commands in
   Parts A–F run from here**, where the compose file and `.env` live (data dirs
   already created in Part 0):

   ```bash
   cd ~/home-lab/infra/forgejo
   docker compose up -d db forgejo
   ```

   (We start everything EXCEPT the runner first — the runner waits for a
   registration file that doesn't exist yet.)

2. Open `https://git.thefipster.de` and complete the first-run screen —
   Traefik picks the container up over the `proxy` network and serves it with
   the wildcard cert; no ports to open, no tunnels.
   The database settings are already injected via env, so just:
   - Create the **admin account** (remember these credentials).
   - Everything else: accept defaults.

3. Confirm Actions is on: after logging in, go to
   **Site Administration → Actions → Runners**. You should see the Runners
   page (empty for now). If the Actions menu is missing, the
   `FORGEJO__actions__ENABLED` env didn't take — check the container logs.

---

## Part B — Register the runner (one-time, manual)

The runner needs a registration token from Forgejo. This is the step that
can't be scripted because the token is generated in the UI.

1. In Forgejo: **Site Administration → Actions → Runners → Create new runner**.
   Copy the **registration token**.

2. Register the runner into the mounted data dir:

   ```bash
   docker compose run --rm \
     -v "/opt/forgejo/runner:/data" \
     --entrypoint forgejo-runner \
     runner register --no-interactive \
       --instance https://git.thefipster.de \
       --token <PASTE_TOKEN_HERE> \
       --name lab-runner \
       --labels docker
   ```

   This creates `/opt/forgejo/runner/.runner`.

   > **Why `git.thefipster.de` and not `forgejo:3000`?** The registered
   > instance address is baked into the clone/registry URLs handed to CI jobs,
   > and the `docker push` is performed by the host Docker daemon — which
   > resolves hostnames via the host's DNS, **not** the Compose network, so the
   > Compose name `forgejo` wouldn't resolve there. `https://git.thefipster.de`
   > works everywhere — runner, daemon, and job containers all resolve it via
   > the UDR's exact host record, and because the cert is publicly trusted, no
   > daemon needs any special configuration. It must match `ROOT_URL` in the
   > compose file (it does).

3. Copy the runner config into place:

   ```bash
   sudo cp config.yml /opt/forgejo/runner/config.yml
   sudo chown 1000:1000 /opt/forgejo/runner/config.yml
   ```

4. Start the runner daemon:

   ```bash
   docker compose up -d runner
   ```

   > This works only if `DOCKER_GID` is set in `.env` (Part 0 step 3) — the
   > runner needs the host `docker` group to open the socket. If the runner
   > restart-loops with *"Cannot connect to the Docker daemon at
   > unix:///var/run/docker.sock"*, check: (a) `.env` has `DOCKER_GID`, and
   > (b) the socket volume actually mounted —
   > `docker compose run --rm --entrypoint sh runner -c 'ls -l /var/run/docker.sock'`
   > should show a socket, not "No such file". If it's missing, your running
   > compose is stale — re-run `docker compose up -d --remove-orphans`.

5. Back in **Admin → Actions → Runners**, the runner should now show as
   **Idle / online** with the `docker` label. That green status is the
   milestone — Actions can now execute.

---

## Part C — Mirror your Blazor repo from GitHub

1. In Forgejo: **+ (top right) → New Migration → GitHub**.
2. Enter your GitHub repo URL. For a private repo, supply a GitHub personal
   access token (read-only on the repo is enough).
3. **Important:** check **"This repository will be a mirror"**. Set the mirror
   interval (e.g. 10m).
4. Create. Forgejo clones the repo and will re-pull on that interval.

> Reminder: a pull mirror updates Git data but does NOT fire `push` events,
> so the workflow is schedule-driven (see below). This is expected.

---

## Part D — Add the pipeline to your repo

The workflow and Dockerfile must live in the repo being built. Because the
Forgejo copy is a *mirror* (read-only, overwritten on each pull), commit these
to **GitHub**, let them mirror in:

1. In your Blazor repo on GitHub, add:
   - `Dockerfile` at the repo root (adjust `PROJECT_PATH` / `APP_DLL` ARGs).
   - `.forgejo/workflows/build-and-push.yml` (from `build-and-push.yml` here).
2. Push to GitHub.
3. Wait for the mirror interval (or in Forgejo, open the repo →
   **Settings → Mirror Settings → Synchronize Now**).

> **Job image note:** the workflow's `container.image` must contain **both**
> Node (for the checkout/login/build-push actions) **and** the `docker` CLI +
> buildx (to build/push). A plain `node` image fails with `docker: not found`;
> this repo's workflow uses `ghcr.io/catthehacker/ubuntu:act-22.04`, which has
> both. The first run pulls that image (~1.5 GB) onto the host daemon and caches
> it. For the docker CLI inside the job to reach the daemon, `config.yml` sets
> `container.docker_host: automount`.

---

## Part E — Watch it run

- The schedule fires every 15 min. To test immediately, go to the repo's
  **Actions** tab in Forgejo → select the workflow → **Run workflow**
  (the `workflow_dispatch` trigger).
- First run: change detection sees no `last-built` tag → builds → logs into
  the registry → pushes → moves the `last-built` tag to HEAD.
- Subsequent scheduled runs with no new commits: detected as unchanged →
  skipped early. Push a new commit to GitHub → next run rebuilds.

---

## Part F — Verify the image landed

1. In Forgejo, go to your user/org → **Packages** tab. You should see a
   container package for the repo with `latest` and a SHA tag.
2. Or pull it — from any machine on the LAN. The registry is plain HTTPS with
   a trusted certificate, so any Docker daemon can pull with **zero**
   configuration:

   ```bash
   docker login git.thefipster.de    # use your Forgejo admin creds
   docker pull git.thefipster.de/<owner>/<repo>:latest
   ```

---

## Teardown

```bash
docker compose down          # stop, keep data
```

All persistent state lives in the **bind mounts** under `/opt/forgejo` — there
are no named volumes, so `docker compose down` (even with `-v`) leaves your data
untouched. For a completely clean slate, also remove the data tree:

```bash
sudo rm -rf /opt/forgejo/{postgres,forgejo,runner}
```

## Backups

Because the stateful data is bind-mounted under `/opt/forgejo`, backup is just
the filesystem plus a consistent DB dump. Stop-the-world snapshot:

```bash
docker compose down
sudo tar czf forgejo-backup-$(date +%F).tar.gz -C /opt forgejo
docker compose up -d
```

For hot backups, prefer `pg_dump` for Postgres over copying its data dir live.
