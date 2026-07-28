# Proxmox VE setup (greenfield homelab foundation)

**Runs on:** the bare server, then the Proxmox host shell

Turns the bare server into a hypervisor running three VMs:

```
Proxmox VE  ·  pve.thefipster.de          ← this guide
 ├─ VM: infra            → Traefik + Authentik + Forgejo + Dockge + monitoring
 ├─ VM: apps             → Coolify + your apps
 └─ VM: home-assistant   → Home Assistant OS (Supervisor + add-ons)
```

Proxmox VE is a Debian-based type-1 hypervisor. Its native workloads are **KVM
VMs** and **LXC** system containers — there is **no Docker on the host**, by
design. Docker runs *inside* the VMs; the host stays a pure hypervisor so a bad
container day can't take down everything at once.

> This wipes the target disk. That's fine here — greenfield, nothing to lose.

---

## Part 1 — Prerequisites

1. **Enable virtualization in BIOS/UEFI**: Intel **VT-x** / AMD **AMD-V** (often
   "SVM"). Enable **IOMMU** (VT-d / AMD-Vi) too if you ever want PCI passthrough
   — harmless to leave on.
2. **Download the Proxmox VE ISO** from <https://www.proxmox.com/downloads>.
3. **Write it to a USB stick**:
   - Linux/macOS: `dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress` (pick
     the right `/dev/sdX`!), or
   - Windows: **Rufus** in **DD/raw** mode, or **balenaEtcher**.

---

## Part 2 — Install Proxmox

Boot the server from the USB stick and pick **Install Proxmox VE (graphical)**.

1. Accept the EULA.
2. **Target disk** — the disk to install onto (gets wiped). For a single disk,
   `ext4` is fine; choose **ZFS (RAID)** only if you have multiple disks and the
   RAM for it (ZFS likes RAM). `Options` lets you cap the root filesystem size.
3. Country / timezone / keyboard.
4. **root password** + an admin **email**.
5. **Management network** — the one place in the whole lab where you type
   addresses in by hand, because no DNS exists yet:
   - **Hostname (FQDN):** `pve.thefipster.de`
   - **IP (CIDR):** the `pve ip` from [dns-records.md](dns-records.md), with your
     LAN's prefix length — **static**, and the host's own address. Pick it outside
     the router's DHCP pool.
   - **Gateway:** your router's address
   - **DNS:** your router, so `*.thefipster.de` resolves
6. Install, then **reboot and remove the USB**.

The installer auto-creates a Linux bridge **`vmbr0`** on the physical NIC. VMs
attached to `vmbr0` sit directly on your LAN (bridged) and get IPs/DNS from the
UDR — exactly what we want. No extra network config needed.

---

## Part 3 — Post-install housekeeping

**First, put the host's name on the router.** You chose a static address in
Part 2, so you already know it — add the single record
`pve.thefipster.de` → `pve ip` on the UDR now
([dns-records.md](dns-records.md) is the registry,
[wildcard-dns-udr.md](wildcard-dns-udr.md) the how-to). It takes a minute and
every step from here on can use the name instead of an address. The *rest* of the
record set waits for Part 6, when the VMs exist to point at.

Then open the web UI at **`https://pve.thefipster.de:8006`** (self-signed cert →
accept the warning). Log in as `root`.

**Switch off the enterprise repo** (it 401s without a subscription) and enable the
free **no-subscription** repo. UI path: *Datacenter → pve → Updates →
Repositories* — disable the `pve-enterprise` and `ceph` enterprise repos, then
**Add → No-Subscription**. Or via the node shell:

Disable the enterprise repositories:

```bash
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
```

```bash
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list 2>/dev/null || true
```

Add the no-subscription repository:

```bash
echo "deb http://download.proxmox.com/debian/pve $(. /etc/os-release && echo $VERSION_CODENAME) pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
```

Update and reboot:

```bash
apt update && apt -y dist-upgrade
```

```bash
reboot
```

(The "No valid subscription" login popup is cosmetic — ignore it, or search the
community for the nag-removal one-liner if it bugs you.)

---

## Part 4 — Upload an OS image for the Ubuntu VMs

Grab an **Ubuntu Server 26.04** ISO and upload it: *Datacenter → pve → local →
ISO Images → Upload* (or `Download from URL`).

The home-assistant VM does not use an ISO at all — HAOS ships a disk image that
gets imported instead, covered in
[home-assistant-setup.md](home-assistant-setup.md).

---

## Part 5 — Create the VMs

Suggested specs for all three — the reasoning is in
[Why these sizes](#why-these-sizes), below the fold:

| Setting | infra VM | apps VM (Coolify) | home-assistant VM |
|---|---|---|---|
| Name | `infra` | `apps` | `homeassistant` |
| VMID | 101 | 102 | 103 |
| IP | `infra ip` | `apps ip` | `ha ip` |
| Cores | 32 | 32 | 32 |
| CPU type | `host` | `host` | `host` |
| `cpuunits` | 100 (default) | 50 | 200 |
| Memory | 16384 MB | 24576 MB | 8192 MB |
| Ballooning | off | off | off |
| Disk | 150 GB | 500 GB | 64 GB |
| BIOS / machine | SeaBIOS / `q35` | SeaBIOS / `q35` | **OVMF** / `q35` |
| Network | bridge `vmbr0`, VirtIO | bridge `vmbr0`, VirtIO | bridge `vmbr0`, VirtIO |
| OS | Ubuntu Server 26.04 ISO | Ubuntu Server 26.04 ISO | Home Assistant OS image |

**Only the first two are built with the Create VM wizard below.** The
home-assistant VM needs a UEFI firmware and an imported disk image rather than
an ISO installer, so its creation lives in its own guide —
[home-assistant-setup.md](home-assistant-setup.md). Its row is here so the whole
host budget is visible in one place.

Click **Create VM** (top right) for the infra and apps VMs. In the wizard:
- **OS:** the uploaded Ubuntu ISO.
- **System:** tick **Qemu Agent**; leave BIOS on SeaBIOS + machine `q35` (fine for
  Linux). Graphic card: Default. The tick adds the virtual device — the daemon
  that answers on it is installed inside the guest in
  [Part 7](#part-7--repo-and-host-setup-in-the-vms).
- **Disk:** bus **VirtIO SCSI single** (default), tick **Discard** if the host is
  on an SSD.
- **CPU:** type **`host`** (best performance on a single-node lab), **1 socket**
  with all 32 cores on it. `cpuunits` is not in the wizard — set it afterwards
  under *VM → Options → CPU units*, or with
  `qm set 102 --cpuunits 50`.
- **Memory:** as above, and **untick Ballooning Device**. Fixed allocations here,
  deliberately — see [Why these sizes](#why-these-sizes).
- **Network:** model **VirtIO (paravirtualized)**, bridge **`vmbr0`**.

Start each VM, open **Console**, and run the Ubuntu installer (enable OpenSSH when
prompted).

---

## Part 6 — Give the VMs their addresses (on the router)

On the **UDR**, add a **DHCP reservation** for the MAC of each VM you just
built — infra and apps — so the IPs are stable. The reservation targets are
listed in [dns-records.md](dns-records.md) (see
[wildcard-dns-udr.md](wildcard-dns-udr.md) for where reservations live).

Then add **every** DNS record from the registry
([dns-records.md](dns-records.md)) — the wildcard to the apps VM and the exact
infra host records; [wildcard-dns-udr.md](wildcard-dns-udr.md) is the how-to.
Add the complete set now: later guides assume the records exist.

**One row waits, and only one:** `homeassistant.thefipster.de` points at the
third VM, which does not exist until
[home-assistant-setup.md](home-assistant-setup.md) — that guide creates the VM,
its reservation and that record together. Note that `ha.thefipster.de` is *not*
the exception: it points at the infra VM, so add it now like the rest.

---

## Part 7 — Repo and host setup in the VMs

Everything the infra VM runs is driven from this repo, so get the checkout onto
the VM first. The Ubuntu Server install carries no `git`, so it is one apt
install away:

```bash
sudo apt install -y git
```

```bash
cd ~ && git clone <this-repo> home-lab
```

Clone to `~/home-lab` specifically: the guides' `cd` commands assume that
path, and Dockge later bind-mounts this checkout at the same absolute path —
don't move it afterwards.

Three scripts, in this order. First the host basics — the time-sync policy and
the QEMU guest agent, which is what puts the VM's IP on its Proxmox summary
page and lets the hypervisor shut it down cleanly:

```bash
cd ~/home-lab && scripts/init-host.sh
```

Then Docker Engine + the compose plugin:

```bash
scripts/init-docker.sh
```

Then **log out and back in** (or run `newgrp docker`) so your user picks up
the `docker` group — until you do, every `docker ...` command fails with
"permission denied".

Finally, let the VM patch itself:

```bash
scripts/init-unattended-upgrades.sh
```

Check what the next run would do — it should list security updates only, and
never anything from Docker's repo:

```bash
sudo unattended-upgrade --dry-run --debug
```

The **apps VM** skips only `init-docker.sh` — Coolify installs its own Docker
via its install script. The other two apply there just as much — it gets
snapshotted too, it should report its IP to the hypervisor like the infra VM,
and Coolify's installer sets up no automatic updates — so clone the repo there
and run both:

```bash
cd ~ && git clone <this-repo> home-lab && cd home-lab
```

```bash
scripts/init-host.sh && scripts/init-unattended-upgrades.sh
```

Why the split: `init-docker.sh` installs Docker and nothing else, so it stays
on the one VM that needs it, while the host-level pieces — the clock, the guest
agent, the updates — are their own scripts and run on both guests.

Two things about the updates are deliberate, on both VMs:

- **Security pocket only.** Regular `-updates` and every third-party repo stay
  manual. Docker's repo is one of those third parties: an unattended
  `docker-ce` upgrade restarts the daemon and bounces every container on the
  box, so you bump Docker by hand, while you're watching.
- **It reboots at 04:30** when an update needs it — even with an SSH session
  open. That is the intended trade for a box nobody logs into: every stack in
  this repo is `restart: unless-stopped`, so Docker brings the lab back without
  you, and Uptime Kuma will tell you about the gap. To keep reboots manual
  instead, run it as `AUTO_REBOOT=false scripts/init-unattended-upgrades.sh` —
  then watch for `/var/run/reboot-required` yourself, because a kernel patch
  that is installed but never booted into is not applied.

The **Proxmox host** is out of scope here: it has no checkout of this repo (the
same reason its node exporter is installed by hand in
[grafana-setup.md](grafana-setup.md)), and its updates ride along with the
`apt dist-upgrade` in [Part 3](#part-3--post-install-housekeeping).

## Part 8 — Snapshot before you build

Take a clean baseline you can roll back to: select the VM → **Snapshots → Take
Snapshot** (name it `clean-install`). Do this again before risky changes — this is
the payoff for choosing Proxmox.

For whole-VM backups, use *Datacenter → Backup* (to `local` or an NFS/PBS target).

> **Rolling back skews the clock.** A rollback resumes the guest with its clock
> frozen at the moment the snapshot was taken — potentially days behind. Until
> the clock corrects, TLS fails in confusing ways: anything validating a
> certificate issued *after* the snapshot errors with `certificate has expired
> or is not yet valid`, which looks like a cert problem and isn't. Worse,
> chrony's default policy (`makestep 1 3`) steps the clock only during its
> first three updates after the service starts — a rollback happens long after
> those, so a large offset would only ever be slewed, i.e. effectively never
> corrected. `scripts/init-host.sh` (Part 7) fixes the policy
> (`makestep 1 -1` — step at any time), so the clock corrects itself within
> moments of the next sync. To force it right away:
>
> ```bash
> sudo chronyc makestep
> ```
>
> (On a VM running systemd-timesyncd instead of chrony:
> `sudo systemctl restart systemd-timesyncd`.)
>
> Both Ubuntu VMs run `init-host.sh` (Part 7), so both are already fixed. The
> home-assistant VM is not: if you snapshot it — you should — force a resync
> from HA's own terminal after a rollback, or simply reboot the VM.

---

## Why these sizes

The host has **32 threads, 64 GB of RAM and 2 TB** dedicated to VM disks.

**All 32 cores go to all three VMs.** That is 96 vCPU over 32 threads — 3:1
overcommit, on purpose. Each VM has a workload that spikes hard and briefly
(CI compiles on infra, ESPHome firmware builds on home-assistant, user load on
apps) and they rarely spike together, so sharing the whole machine beats
carving it into three permanently-too-small slices. The configuration that
actually degrades performance is a *single* VM defined wider than the host;
32 = 32 stays on the right side of that line.

What arbitrates a collision is **`cpuunits`**, not core count. It is a relative
scheduler weight — clamped to `[1, 10000]`, default **100** under cgroup v2,
which Proxmox 8 and 9 use — so only the ratios matter. home-assistant outweighs
apps 4:1, which means a runaway Coolify build cannot make your lights laggy.
Nothing is capped: `cpulimit` stays `0` everywhere, so any VM can still use the
whole box when the others are idle.

**Ballooning is off** because 16 + 24 + 8 = 48 GB against roughly 60 GB usable.
The balloon driver earns its keep when the sum of configured maxima *exceeds*
physical RAM; here it does not, so the only thing it could ever do is reclaim
memory from a VM in the middle of a compile. The ~12 GB left over is the growth
pool — raising a VM's memory later is an edit and a reboot.

Per-VM, the numbers that changed and why:

- **infra 10 → 16 GB.** The Forgejo Actions runner *compiles*, beside six
  monitoring containers, Authentik, two Postgres instances, Traefik and Dockge.
  The old 10 GB was sized before the monitoring stack existed.
- **infra 40 → 150 GB.** Prometheus 15 d, Loki 14 d, Tempo 7 d, Docker image
  layers, and Forgejo's container registry, which today gains an image per CI
  run. Registry retention is owned by the CI roadmap rather than by a disk size,
  so 150 GB buys comfortable time rather than absorbing growth forever.
- **apps 8 → 24 GB, 80 → 500 GB.** This is where real user workloads live:
  app volumes, databases, build cache and image layers. Coolify's own installer
  requires 30 GB free before it will run at all.
- **home-assistant 8 GB / 64 GB.** HAOS idles near 2 GB; the spike is ESPHome
  firmware builds and add-ons. Its own default disk is 32 GB, and the recorder
  database plus build caches make 64 GB comfortable.

That is 714 GB provisioned. Snapshots, `vzdump` backups and Proxmox itself live
on separate storage, so the 2 TB is not shared with them and there is ~1.3 TB of
headroom for growing these three or adding a fourth machine. On the default
ext4 install the disks land on `local-lvm` (LVM-thin) and are thin-provisioned,
costing only what is actually written.

Treat all of it as a starting point. These numbers will be revised as the final
storage layout settles; the reasoning above is the part meant to survive.

> One monitoring blind spot worth knowing: the `DiskAlmostFull` alert reads
> `node_filesystem_*`, so it sees filesystems *inside* the guests and on the
> hypervisor. It cannot see the LVM thin pool. Checking that is `lvs` on the
> host.

---

## Optional — faster VM creation with cloud-init

Once you're comfortable, skip the ISO installer: download an Ubuntu **cloud image**,
turn it into a Proxmox **template**, and `Clone` new VMs from it with cloud-init
injecting the hostname, user, SSH key, and IP. Great when you start spinning up
more VMs. Left as a later optimization — the ISO path above is enough to get going.

---

## Next

**[wildcard-dns-udr.md](wildcard-dns-udr.md)** — put the lab's names on the
router: the reservations and records from Part 6, with
[dns-records.md](dns-records.md) as the registry of exactly what to add. Every
guide after it assumes those records exist.

The full sequence is the [README build order](../README.md#build-order).
