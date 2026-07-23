# Forgejo Pipeline

Runs the chain **GitHub → Forgejo (pull mirror) → build → push to Forgejo
registry** on an **Ubuntu Server 26.04** host.

This was first prototyped on Docker Desktop; the only things that changed for the
real server are **where files live** (see below). It's still plain HTTP for now —
putting Forgejo behind a reverse proxy with real TLS is a later TODO.

## Layout on the server

Two locations, by design:

| What | Where | Why |
|------|-------|-----|
| Compose project (this repo) | `~/forgejo` (your user's home) | You edit/redeploy it as your normal user; no root needed to run `docker compose`. |
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

- `docker-compose.yml` — Forgejo + Postgres + an Actions runner
- `config.yml` — runner config (gets copied into place during setup)
- `Dockerfile` — multi-stage build for your Blazor app (goes in your repo)
- `build-and-push.yml` — the pipeline workflow (goes in your repo)

---

## Part 0 — Server prerequisites

1. Install Docker Engine + the compose plugin (Docker's official apt repo), and
   add yourself to the `docker` group so you can run it without `sudo`:

   ```bash
   sudo usermod -aG docker "$USER"
   # log out / back in (or: newgrp docker) for the group to take effect
   ```

2. Put this repo in your home folder and create the data tree under `/opt`:

   ```bash
   cd ~ && git clone <this-repo> forgejo && cd ~/forgejo

   sudo mkdir -p /opt/forgejo/{postgres,forgejo,runner}
   # Forgejo runs as UID/GID 1000 (see USER_UID/GID in the compose file) and
   # must own its data dir. Postgres manages its own dir's ownership.
   sudo chown -R 1000:1000 /opt/forgejo/forgejo /opt/forgejo/runner
   ```

   > If your login user isn't `1000:1000`, keep the compose `USER_UID`/`USER_GID`
   > and the `chown` above in agreement — they must match.

3. Give the runner access to the host Docker socket. The runner image runs as
   uid 1000, but `/var/run/docker.sock` is `root:docker` — so the runner must
   join the host's `docker` group by its numeric GID. Record it in `.env` (the
   compose file reads `${DOCKER_GID}` from there):

   ```bash
   echo "DOCKER_GID=$(getent group docker | cut -d: -f3)" >> .env
   ```

4. Tell the **host Docker daemon** to allow the plain-HTTP Forgejo registry.
   Because CI builds run on the host daemon (via the mounted socket), this is
   where the insecure-registry setting lives now. Edit `/etc/docker/daemon.json`:

   ```json
   { "insecure-registries": ["192.168.1.40:3000"] }
   ```

   ```bash
   sudo systemctl restart docker
   ```

   > Use the same address as `ROOT_URL` / the runner registration. When you add
   > TLS via a reverse proxy later, this whole step goes away.

---

## Part A — Bring up Forgejo

1. From `~/forgejo` (data dirs already created in Part 0):

   ```bash
   docker compose up -d db forgejo
   ```

   (We start everything EXCEPT the runner first — the runner waits for a
   registration file that doesn't exist yet.)

2. Open `http://<server-ip>:3000` and complete the first-run screen.
   (Make sure port 3000 is reachable — open it in `ufw`/your cloud security
   group, or tunnel in with `ssh -L 3000:localhost:3000 user@server`.)
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
       --instance http://192.168.1.40:3000 \
       --token <PASTE_TOKEN_HERE> \
       --name lab-runner \
       --labels docker
   ```

   This creates `/opt/forgejo/runner/.runner`.

   > **Why the host IP and not `forgejo:3000`?** The registered instance address
   > is baked into the clone/registry URLs handed to CI jobs, and the `docker
   > push` is performed by the host Docker daemon — which resolves hostnames via
   > the host's DNS, **not** the Compose network, so the Compose name `forgejo`
   > wouldn't resolve there. The host's published address (`192.168.1.40:3000`)
   > works everywhere — runner, daemon, and job containers — which keeps checkout
   > and registry pointing at one consistent host. (When you later add a reverse
   > proxy + TLS, swap this for the real hostname.)

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
2. Or pull it. On the server itself, `localhost:3000` works; from another host,
   use `<server-ip>:3000`. Either way it's an insecure (HTTP) registry — see
   note below.

   ```bash
   docker login <server-ip>:3000    # use your Forgejo admin creds
   docker pull <server-ip>:3000/<owner>/<repo>:latest
   ```

### Insecure registry note

Everything is still plain HTTP, so any Docker daemon that pulls from this
registry must be told to allow it. The **server's** daemon was already
configured in [Part 0](#part-0--server-prerequisites) (it's the one that runs
the CI push). To pull from **another host** (e.g. your workstation), add the
registry to that machine's `/etc/docker/daemon.json` — or Docker Desktop's
*Settings → Docker Engine* — and restart Docker:

```json
{ "insecure-registries": ["192.168.1.40:3000"] }
```

```bash
sudo systemctl restart docker
```

> **TODO (next iteration):** front Forgejo with a reverse proxy (Traefik/Caddy)
> terminating TLS on a real hostname. That removes the insecure-registry step
> entirely and lets you set `ROOT_URL`/`DOMAIN` to `https://…`.

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
