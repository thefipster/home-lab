# Coolify — self-hosted PaaS (apps VM)

**Runs on:** apps VM

**Prerequisite:** [uptime-kuma-setup.md](uptime-kuma-setup.md) complete — the
infra VM is finished, so this machine has TLS, SSO, CI and monitoring to lean on.

[Coolify](https://coolify.io) is a self-hosted PaaS at
**`http://192.168.1.42:8000`**, later **`https://coolify.thefipster.de`**. You
point it at a git repository and it builds, deploys and runs the result with a
domain and HTTPS — the apps VM's entire job.

It is the one machine in the lab whose workloads are **not** described by this
repo. Coolify owns this VM's Docker, keeps its own configuration store, and
manages applications through its web UI, so `apps/` holds a guide, a README and
one env template — and deliberately **no `compose.yaml`**. Every `infra/` stack
is the opposite: the repo is the source of truth and Dockge only drives it.

## Steps

### 1. Repo and Docker

Coolify's installer would install Docker itself, but run
[`init-host.sh`](../scripts/init-host.sh) first anyway: Coolify accepts a
pre-existing Engine, and the script also relaxes the time-sync step policy so a
snapshot rollback cannot leave this VM's clock permanently skewed. Full reasoning
in [proxmox-setup.md, Part 7](proxmox-setup.md#part-7--repo-and-docker-on-the-infra-and-apps-vms).

```bash
cd ~ && git clone <this-repo> home-lab
```

```bash
cd ~/home-lab && scripts/init-host.sh
```

Then **log out and back in** (or run `newgrp docker`) so your user picks up the
`docker` group.

### 2. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-coolify.sh
```

It preflights the box (Debian family, Engine ≥ 24, 30 GB free, RAM), creates a
4 GB swapfile if none is active, then downloads Coolify's official installer
**to a file** and prints its source URL and sha256 before running it as root.
That last part is the only real deviation from upstream's `curl … | sudo bash`:
same operation, but you can read the script that is about to own your machine.

Expect a few minutes and a lot of image pulls.

> **On Ubuntu 26.04 the script warns.** Coolify officially lists Ubuntu
> 20.04/22.04/24.04 and Debian 11/12. The installer is Debian-family generic, so
> the warning is expected and the script continues on purpose.

### 3. Create the admin account — immediately

```bash
echo "http://$(hostname -I | awk '{print $1}'):8000"
```

Open that URL and register. **Do it now:** a fresh Coolify instance is
unauthenticated, and it is listening on a LAN port with no Traefik and no
Authentik in front of it. This is the one window in the whole lab where a service
is reachable and unprotected.

### 4. Set the instance domain

In Coolify: *Settings → Configuration → Instance Domain* →
`https://coolify.thefipster.de`.

**No DNS record is needed.** `*.thefipster.de` already points at this VM and
Coolify's proxy routes by `Host` header — the same mechanism that serves every
app you deploy. The registry records this as a deliberate non-row; see
[dns-records.md](dns-records.md).

### 5. Give the proxy its netcup credentials

Coolify's bundled proxy issues its **own** Let's Encrypt wildcard for
`*.thefipster.de` via DNS-01. Same credentials as the infra VM, separate
certificate, separate ACME account — nothing is shared and nothing needs to be.

```bash
nano ~/home-lab/apps/.env
```

Fill in the three `NETCUP_*` values, then enter the same values in Coolify's UI
(*Settings → Proxy*). The file is the repo's record of *what* is required;
Coolify reads its own store, not this file.

The netcup caveats are unchanged and not restated here — slow propagation and
wildcard-only with no apex SAN. See
[traefik-setup.md](traefik-setup.md#how-it-works).

Verify once issuance completes:

```bash
curl -sI https://coolify.thefipster.de | head -1
```

### 6. Install the host metrics exporter

The infra VM watches this machine, and host metrics come from a node exporter
running here as a systemd unit:

```bash
scripts/init-node-exporter.sh
```

Alloy already has this host in its scrape config, so there is nothing to
configure on either side. Confirm in Grafana that the Node Exporter Full
dashboard's `instance` dropdown now offers **`apps`** alongside `infra` and
`pve` — see [grafana-setup.md](grafana-setup.md).

## Next

**[home-assistant-setup.md](home-assistant-setup.md)** — the third VM, and the
last machine in the lab.

## Troubleshooting

**The script warns about the OS version.** Expected on Ubuntu 26.04 — see step 2.

**"requires 30 GB" and the script stops.** Coolify's own installer enforces this
too; the preflight just fails earlier and names the cause. Grow the disk in
Proxmox (*VM → Hardware → Disk → Resize*), then extend the filesystem in the
guest.

**`http://<ip>:8000` never answers.** Check the containers came up:

```bash
docker ps --filter name=coolify
```

**The wildcard certificate does not issue.** Almost always netcup propagation,
not Coolify. The infra VM's diagnosis applies verbatim —
[traefik-setup.md](traefik-setup.md#troubleshooting). Remember the two proxies
issue independently: a working cert on the infra VM says nothing about this one.

**An app 404s at its hostname.** The wildcard sends every unlisted name here, so
a 404 means Coolify has no app matching that `Host` header — not a DNS or TLS
fault. Note the mirror-image failure on the infra VM: a *missing* exact record
there lands you on **this** box and produces the same 404.

## Layout on the server

| What | Where |
|------|-------|
| Coolify itself | `/data/coolify/` — source of truth for everything it manages |
| Coolify's compose | `/data/coolify/source/` — installed, not from this repo |
| App data + volumes | Docker volumes, managed by Coolify |
| netcup credentials (record) | `apps/.env` — gitignored, VM-only |
| Swap | `/swapfile`, with an `/etc/fstab` entry |

`/data/coolify/` is the thing to back up. Nothing under it is reproducible from
this repo, which is the trade Coolify asks for.

## How it works

**Why two certificates instead of one.** Traefik on the infra VM holds a
perfectly good `*.thefipster.de` wildcard, and Coolify cannot use it: it is a
different proxy on a different machine with no access to that `acme.json`, and
copying certificates between hosts on a schedule is a worse failure mode than
letting each one renew what it serves. Both talk DNS-01 to netcup, so there is no
inbound exposure either way.

**Why Coolify gets a whole VM.** It expects to own the Docker daemon — creating
networks, proxies and containers on its own terms. That conflicts directly with
the label-and-network conventions the infra VM's stacks rely on. Separate VMs
also mean separate snapshots: a Coolify upgrade that goes wrong rolls back
without touching TLS, SSO or monitoring.

**Why root.** Upstream requires it and documents non-root as not fully
supported. `init-coolify.sh` runs its own steps through the `run_root` helper
like every other script here, and hands the vendor installer the root shell it
asks for.

**Why app definitions are not in this repo.** They live in Coolify's database,
because that is what makes its UI the deployment interface. The repo describes
*machines*; Coolify describes *applications*. Trying to mirror them here would
produce a second source of truth that silently drifts.

## Next

**[home-assistant-setup.md](home-assistant-setup.md)** — the third VM.

The full sequence is the [README build order](../README.md#build-order).
