# infra VM — repo and host setup

**Runs on:** infra VM

**Prerequisite:** [wildcard-dns-udr.md](wildcard-dns-udr.md) complete — every
record from [dns-records.md](dns-records.md) resolves, so this machine can be
reached and can reach the internet by name.

The infra VM is the only machine whose services this repo declares, so
everything from here to [uptime-kuma-setup.md](uptime-kuma-setup.md) runs out of
a checkout on this box. This guide gets the checkout there and prepares the host
underneath it: a time-sync policy that survives a snapshot rollback, the QEMU
guest agent, Docker, and automatic security updates. Nothing is routed and
nothing is served yet — that starts with Traefik.

Three scripts, in order, and the order matters: the clock comes first because
everything after it does TLS.

## Steps

### 1. Clone the repo

Ubuntu Server 26.04's standard install already carries `git`:

```bash
git --version
```

If that fails you took the minimal install path — one apt away:

```bash
sudo apt install -y git
```

```bash
cd ~ && git clone <this-repo> home-lab
```

Clone to `~/home-lab` **specifically**. The guides' `cd` commands assume that
path, and Dockge later bind-mounts this checkout at the same absolute path
inside its container so stack symlinks resolve — moving it afterwards breaks
that.

### 2. Host basics — clock and guest agent

```bash
cd ~/home-lab && scripts/init-host.sh
```

It relaxes the time-sync step policy, then installs `qemu-guest-agent`.

The clock half is the part worth understanding. A Proxmox snapshot rollback
resumes the guest with its clock frozen at the moment the snapshot was taken —
potentially days behind — and chrony's default `makestep 1 3` only steps the
clock during its first three updates after the service starts. A rollback
happens long after those, so a large offset would only ever be *slewed*, which
for hours of drift means effectively never corrected. Every TLS client on the
box then fails with `certificate has expired or is not yet valid`, which looks
like a certificate problem and is not. The script sets `makestep 1 -1` — step
at any time — so the clock corrects itself within moments of the next sync.

The guest agent is the guest half of the **Qemu Agent** tick from the Create VM
wizard: it puts this VM's IP on its Proxmox summary page, lets the hypervisor
shut it down cleanly, and lets `vzdump` freeze the filesystems for a consistent
snapshot backup.

Verify both:

```bash
timedatectl status
```

```bash
systemctl is-active qemu-guest-agent
```

### 3. Docker Engine

```bash
scripts/init-docker.sh
```

Docker Engine plus the compose plugin, from Docker's own apt repo, and your
user added to the `docker` group.

Then **log out and back in** (or run `newgrp docker`) so the group membership
takes effect — until you do, every `docker …` command fails with "permission
denied":

```bash
docker run --rm hello-world
```

> **This is the one script the apps VM does not run.** It installs Docker and
> nothing else, which is exactly why it is its own script: Coolify's installer
> brings its own Engine to that machine
> ([apps-vm-setup.md](apps-vm-setup.md)).

### 4. Automatic security updates

```bash
scripts/init-unattended-upgrades.sh
```

Check what the next run would do — it should list security updates only, and
never anything from Docker's repo:

```bash
sudo unattended-upgrade --dry-run --debug
```

Two things about this are deliberate:

- **Security pocket only.** Regular `-updates` and every third-party repo stay
  manual. Docker's repo is one of those third parties: an unattended
  `docker-ce` upgrade restarts the daemon and bounces every container on the
  box, so you bump Docker by hand, while you are watching.
- **It reboots at 04:30** when an update needs it — even with an SSH session
  open. That is the intended trade for a box nobody logs into: every stack in
  this repo is `restart: unless-stopped`, so Docker brings the lab back without
  you, and Uptime Kuma tells you about the gap. To keep reboots manual instead,
  run it as `AUTO_REBOOT=false scripts/init-unattended-upgrades.sh` — then
  watch for `/var/run/reboot-required` yourself, because a kernel patch that is
  installed but never booted into is not applied.

### Checklist

- [ ] `~/home-lab` exists and is a clone of this repo
- [ ] `timedatectl status` reports the clock synchronised
- [ ] `systemctl is-active qemu-guest-agent` → `active`, and the VM's IP now
      shows on its Proxmox **Summary** page
- [ ] `docker run --rm hello-world` succeeds **without `sudo`**
- [ ] `unattended-upgrade --dry-run --debug` lists security origins only, and
      nothing from `origin=Docker`

## Next

**[traefik-setup.md](traefik-setup.md)** — the reverse proxy and the lab's one
wildcard certificate. It is the first stack on this machine, and nothing else
is reachable until it exists.

## Troubleshooting

**`docker: permission denied` on the socket.** The group membership has not
taken effect in this shell. Log out and back in, or:

```bash
newgrp docker
```

**`Certificate verification failed` from apt or curl.** The clock, not the
certificate — most likely you are on a VM resumed from a snapshot. Force a
correction:

```bash
sudo chronyc makestep
```

(On a VM running systemd-timesyncd rather than chrony:
`sudo systemctl restart systemd-timesyncd`.)

**The VM's IP is missing from its Proxmox summary page.** The guest agent is
installed but the *virtual device* is not enabled. Tick **Qemu Agent** under
*VM → Options*, then stop and start the VM — a reboot from inside the guest
does not attach a new device.

**`git clone` asks for credentials.** Expected for a private remote. Use an
SSH remote with a key on this VM, or a token — but note that the checkout is
read-only in practice: nothing in the build order pushes from a VM.

## Layout on the server

| What | Where |
|------|-------|
| The checkout | `~/home-lab` — the path Dockge later bind-mounts |
| Time-sync policy | `/etc/chrony/conf.d/90-step-any-offset.conf` |
| Unattended upgrades | `/etc/apt/apt.conf.d/20auto-upgrades` + `52homelab-…` |
| Docker | apt packages from Docker's repo; data under `/var/lib/docker` |
| Stack data (later) | `/opt/<stack>` — one directory per stack |
| Stacks as Dockge sees them (later) | `/opt/stacks/<stack>` → symlinks into the checkout |

## How it works

**Why three scripts rather than one.** Only the middle one is about Docker, and
only one machine needs Docker installed this way. Splitting them is what lets
the apps VM run steps 2 and 4 unchanged
([apps-vm-setup.md](apps-vm-setup.md)) while skipping step 3 entirely — its
Engine arrives with Coolify's installer. Fold them together and the apps VM
needs a second copy of the clock fix, which is exactly the duplication this
split removed.

**Why the clock is first inside `init-host.sh` too.** Installing the guest
agent means apt, and apt does TLS. A script that fixed the clock after its own
package installs would fail before reaching the fix.

**Why the Proxmox host is not covered here.** It has no checkout of this repo,
and its updates ride along with the `apt dist-upgrade` in
[proxmox-setup.md Part 3](proxmox-setup.md#part-3--post-install-housekeeping).
The same reasoning is why its node exporter is a documented `apt install`
rather than a script ([grafana-setup.md](grafana-setup.md#6-add-the-proxmox-host)).

## Next

**[traefik-setup.md](traefik-setup.md)** — TLS and routing. The full sequence is
the [README build order](../README.md#build-order).
