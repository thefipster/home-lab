# Proxmox VE setup (greenfield homelab foundation)

Turns the bare server into a hypervisor running two VMs:

```
Proxmox VE  (pve.thefipster.de · .40)   ← this guide
 ├─ VM: infra  (.41)  → Traefik + Authentik + Forgejo + Dockge + monitoring
 └─ VM: apps   (.42)  → Coolify + your apps
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
5. **Management network**:
   - **Hostname (FQDN):** `pve.thefipster.de`
   - **IP (CIDR):** `192.168.1.40/24`  ← static, this is the host's own address
   - **Gateway:** your router, e.g. `192.168.1.1`
   - **DNS:** your router (`192.168.1.1`) so `*.thefipster.de` resolves
6. Install, then **reboot and remove the USB**.

The installer auto-creates a Linux bridge **`vmbr0`** on the physical NIC. VMs
attached to `vmbr0` sit directly on your LAN (bridged) and get IPs/DNS from the
UDR — exactly what we want. No extra network config needed.

---

## Part 3 — Post-install housekeeping

Open the web UI at **`https://192.168.1.40:8006`** (self-signed cert → accept the
warning). Log in as `root`.

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

## Part 4 — Upload an OS image for the VMs

Grab an **Ubuntu Server 26.04** ISO and upload it: *Datacenter → pve → local →
ISO Images → Upload* (or `Download from URL`).

---

## Part 5 — Create the two VMs

Click **Create VM** (top right) for each. Suggested specs:

| Setting | infra VM | apps VM (Coolify) |
|---|---|---|
| Name | `infra` | `apps` |
| Cores | 2 | 4 |
| Memory | 10240 MB | 8192 MB |
| Disk | 40 GB | 80 GB |
| Network | bridge `vmbr0`, VirtIO | bridge `vmbr0`, VirtIO |

The infra VM's 10 GB is not padding: the six monitoring containers run beside
Authentik, Forgejo, Traefik and Dockge, and at 4 GB an OOM kill would most
likely take Authentik down with it (see the prerequisites in
[grafana-setup.md](grafana-setup.md)).

In the Create VM wizard:
- **OS:** the uploaded Ubuntu ISO.
- **System:** tick **Qemu Agent**; leave BIOS on SeaBIOS + machine `q35` (fine for
  Linux). Graphic card: Default.
- **Disk:** bus **VirtIO SCSI single** (default), tick **Discard** if the host is
  on an SSD.
- **CPU:** type **`host`** (best performance on a single-node lab).
- **Memory:** as above; you can leave ballooning on.
- **Network:** model **VirtIO (paravirtualized)**, bridge **`vmbr0`**.

Start each VM, open **Console**, and run the Ubuntu installer (enable OpenSSH when
prompted).

---

## Part 6 — In-guest setup (run in each VM)

Install the guest agent so Proxmox can see the VM's IP and shut it down
cleanly:

```bash
sudo apt update && sudo apt -y install qemu-guest-agent
```

```bash
sudo systemctl enable --now qemu-guest-agent
```

Then, on the **UDR**, add a **DHCP reservation** for each VM's MAC so the IPs
are stable — the reservation targets are listed in
[dns-records.md](dns-records.md) (see [wildcard-dns-udr.md](wildcard-dns-udr.md)
for where reservations live).

Once the VMs are up, add **every** DNS record from the registry
([dns-records.md](dns-records.md)) — the wildcard to the apps VM and the exact
infra host records; [wildcard-dns-udr.md](wildcard-dns-udr.md) is the how-to.
Add the complete set now: later guides assume the records exist.

---

## Part 7 — Repo and Docker on the infra VM

Everything the infra VM runs is driven from this repo, so get it and Docker
onto that VM now:

```bash
cd ~ && git clone <this-repo> home-lab
```

```bash
cd ~/home-lab && scripts/init-host.sh
```

Then **log out and back in** (or run `newgrp docker`) so your user picks up
the `docker` group — until you do, every `docker ...` command fails with
"permission denied".

Besides Docker, the script also reconfigures the VM's time-sync daemon so a
snapshot rollback can't leave the clock permanently skewed — see the note in
[Part 8](#part-8--snapshot-before-you-build) for why that matters.

Clone to `~/home-lab` specifically: the guides' `cd` commands assume that
path, and Dockge later bind-mounts this checkout at the same absolute path —
don't move it afterwards.

The **apps VM** needs none of this — Coolify installs its own Docker via its
install script.

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
> corrected. On the **infra VM**, `scripts/init-host.sh` (Part 7) fixes the
> policy (`makestep 1 -1` — step at any time), so the clock corrects itself
> within moments of the next sync. To force it right away:
>
> ```bash
> sudo chronyc makestep
> ```
>
> (On a VM running systemd-timesyncd instead of chrony:
> `sudo systemctl restart systemd-timesyncd`.)
>
> The **apps VM** never runs `init-host.sh`, so if you snapshot it — you should
> — apply the same drop-in there once:
>
> ```bash
> printf 'makestep 1 -1\n' | sudo tee /etc/chrony/conf.d/90-step-any-offset.conf
> ```
>
> ```bash
> sudo systemctl restart chrony
> ```

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
