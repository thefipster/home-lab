# Coolify — self-hosted PaaS (apps VM)

**Runs on:** apps VM

**Prerequisite:** [apps-vm-setup.md](apps-vm-setup.md) complete — this machine
has the repo checked out, the host scripts run, and its 300 GB second disk
mounted at `/data`, which the installer needs *before* it runs.

[Coolify](https://coolify.io) is a self-hosted PaaS, reached on this VM's own
address at port **8000** during install and at **`https://coolify.thefipster.de`**
once its domain is set. You point it at a git repository and it builds, deploys
and runs the result with a domain and HTTPS — the apps VM's entire job.

It is the one machine in the lab whose workloads are **not** described by this
repo. Coolify owns this VM's Docker, keeps its own configuration store, and
manages applications through its web UI, so `apps/` holds a guide, a README and
one env template — and deliberately **no `compose.yaml`**. Every `infra/` stack
is the opposite: the repo is the source of truth and Dockge only drives it.

## Steps

### 1. Run the init script

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

> **This is where the apps VM gets Docker.** It is the one machine that skips
> `init-docker.sh` ([apps-vm-setup.md](apps-vm-setup.md)), so the Engine ≥ 24
> preflight above is deliberately **soft**: a missing Engine is normal on a
> first run and only an existing one is version-checked. Making that gate hard
> would deadlock the only machine that needs this script.

> **On Ubuntu 26.04 the script warns.** Coolify officially lists Ubuntu
> 20.04/22.04/24.04 and Debian 11/12. The installer is Debian-family generic, so
> the warning is expected and the script continues on purpose.

### 2. Create the admin account — immediately

```bash
echo "http://$(hostname -I | awk '{print $1}'):8000"
```

Open that URL and register. **Do it now:** a fresh Coolify instance is
unauthenticated, and it is listening on a LAN port with no Traefik and no
Authentik in front of it. This is the one window in the whole lab where a service
is reachable and unprotected.

### 3. Set the instance domain

In Coolify: *Settings → Configuration → Instance Domain* →
`https://coolify.thefipster.de`.

**No DNS record is needed.** `*.thefipster.de` already points at this VM and
Coolify's proxy routes by `Host` header — the same mechanism that serves every
app you deploy. The registry records this as a deliberate non-row; see
[dns-records.md](dns-records.md).

### 4. Switch the proxy to the netcup DNS-01 challenge

Coolify's bundled proxy issues its **own** Let's Encrypt wildcard for
`*.thefipster.de`. Same credentials as the infra VM, separate certificate,
separate ACME account — nothing is shared and nothing needs to be.

**This is not just a credentials step.** Coolify's proxy ships configured for
the **HTTP-01** challenge, and Let's Encrypt does not issue wildcards over
HTTP-01 at all. Switching the challenge type is the part that actually matters;
the credentials are what the new challenge type needs.

First record the values in the repo's copy:

```bash
nano ~/home-lab/apps/.env
```

Then open **Servers → *your server* → Proxy → Configuration** in Coolify. That
page holds the Traefik container's `docker-compose` YAML in an editor — there is
no credentials form anywhere in Coolify, and the *Dynamic Configurations*
listed beside it (`coolify.yaml`, `default_redirect_503.yaml`) cannot carry
these values: a file provider declares routers and middlewares but sets no
environment variables and no command-line flags. Leave those two alone.

Make three changes to the `traefik` service.

**Replace the HTTP-01 lines** — they look like
`--certificatesresolvers.letsencrypt.acme.httpchallenge=true` and
`...httpchallenge.entrypoint=http` — with the netcup DNS-01 set:

```
- "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
- "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=netcup"
- "--certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=root-dns.netcup.net:53,second-dns.netcup.net:53,third-dns.netcup.net:53"
```

**Add an `environment:` block** with the values you just recorded, plus the two
propagation knobs — without them first issuance fails on netcup's ~10 minute
publish delay:

```yaml
environment:
  NETCUP_CUSTOMER_NUMBER: "..."
  NETCUP_API_KEY: "..."
  NETCUP_API_PASSWORD: "..."
  NETCUP_PROPAGATION_TIMEOUT: "900"
  NETCUP_POLLING_INTERVAL: "30"
```

**Declare the wildcard at the entrypoint**, so Traefik requests it at startup
with no router needed — the same arrangement as the infra VM:

```
- "--entrypoints.https.http.tls.certresolver=letsencrypt"
- "--entrypoints.https.http.tls.domains[0].main=*.thefipster.de"
```

> **Two deviations from Coolify's own documentation, both load-bearing.**
> Upstream's wildcard page tells you to add `tls.domains[0].sans=*.example.com`
> beside a `main` of the apex — that requests apex *and* wildcard, which needs
> two TXT records at the same `_acme-challenge` FQDN, and netcup's non-atomic
> zone updates lose that race. Wildcard only, no SAN, exactly as
> `infra/traefik/compose.yaml` does it. And Coolify names its entrypoints
> `http`/`https`, **not** the `web`/`websecure` this repo's own Traefik uses —
> an entrypoint name copied from the infra VM silently matches nothing.

Save, then restart the proxy from that same page, and watch issuance:

```bash
docker logs -f coolify-proxy
```

Verify once it completes:

```bash
curl -sI https://coolify.thefipster.de | head -1
```

> **Coolify regenerates this file from its own store.** A closed issue reports
> server revalidation wiping custom proxy edits; it dates to a 4.0 beta and is
> probably long fixed, but it is unverified on the version here. After clicking
> anything resembling *Validate Server*, re-open the Proxy tab and confirm these
> lines survived. That risk is why `apps/.env` exists — it is the recovery copy,
> not decoration.

The remaining netcup caveats are unchanged and not restated here. See
[traefik-setup.md](traefik-setup.md#how-it-works).

### 5. Install the host metrics exporter

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

**The script warns about the OS version.** Expected on Ubuntu 26.04 — see step 1.

**There is no *Settings → Proxy* page.** Correct — there never was. Proxy
configuration is per-server, at *Servers → your server → Proxy*, and it is a
YAML editor rather than a form. See [step 4](#4-switch-the-proxy-to-the-netcup-dns-01-challenge).

**The certificate is issued but for the wrong name, or only for
`coolify.thefipster.de`.** The entrypoint block did not take. Check you used
`https` and not `websecure` — Coolify's entrypoint names differ from the infra
VM's, and a flag naming an entrypoint that does not exist is silently ignored.

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
| The data disk | `/data` — mounted in [apps-vm-setup.md](apps-vm-setup.md#4-mount-the-data-disk) |
| Coolify itself | `/data/coolify/` — source of truth for everything it manages |
| Coolify's compose | `/data/coolify/source/` — installed, not from this repo |
| The proxy's compose | Coolify's own store, edited at *Servers → Proxy* — **not** in this repo |
| App data + volumes | Docker volumes, managed by Coolify |
| netcup credentials (recovery copy) | `apps/.env` — gitignored, VM-only |
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
