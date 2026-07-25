# Proxmox VE setup (greenfield homelab foundation)

Turns the bare server into a hypervisor running two VMs:

```
Proxmox VE  (pve.thefipster.de · .40)   ← this guide
 ├─ VM: infra  (.41)  → Traefik + Authentik + Forgejo + Dockge
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

```bash
# Disable enterprise repos
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list 2>/dev/null || true
# Add the no-subscription repo
echo "deb http://download.proxmox.com/debian/pve $(. /etc/os-release && echo $VERSION_CODENAME) pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt -y dist-upgrade
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
| Memory | 4096 MB | 8192 MB |
| Disk | 40 GB | 80 GB |
| Network | bridge `vmbr0`, VirtIO | bridge `vmbr0`, VirtIO |

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

```bash
# Let Proxmox see the VM's IP and do clean shutdowns
sudo apt update && sudo apt -y install qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Then, on the **UDR**, add a **DHCP reservation** for each VM's MAC so the IPs are
stable — `infra → 192.168.1.41`, `apps → 192.168.1.42` (see
[wildcard-dns-udr.md](wildcard-dns-udr.md) for where reservations live).

Install Docker in **each** VM (this repo's [init-host.sh](../scripts/init-host.sh)
does exactly this for the infra VM). Coolify installs its own Docker via its
script on the apps VM.

DNS records to add on the UDR once the VMs are up (details in
[wildcard-dns-udr.md](wildcard-dns-udr.md)):
- `git.thefipster.de` → `192.168.1.41` (infra VM — Forgejo behind Traefik)
- `dockge.thefipster.de` → `192.168.1.41` (infra VM — Dockge behind Traefik)
- `auth.thefipster.de` → `192.168.1.41` (infra VM — Authentik SSO portal)
- `traefik.thefipster.de` → `192.168.1.41` (infra VM — Traefik dashboard, gated)
- `*.thefipster.de` → `192.168.1.42` (apps VM — Coolify routes by Host header)
- `pve.thefipster.de` → `192.168.1.40` (optional — the Proxmox web UI)

---

## Part 7 — Snapshot before you build

Take a clean baseline you can roll back to: select the VM → **Snapshots → Take
Snapshot** (name it `clean-install`). Do this again before risky changes — this is
the payoff for choosing Proxmox.

For whole-VM backups, use *Datacenter → Backup* (to `local` or an NFS/PBS target).

---

## Optional — faster VM creation with cloud-init

Once you're comfortable, skip the ISO installer: download an Ubuntu **cloud image**,
turn it into a Proxmox **template**, and `Clone` new VMs from it with cloud-init
injecting the hostname, user, SSH key, and IP. Great when you start spinning up
more VMs. Left as a later optimization — the ISO path above is enough to get going.

---

## Next steps

1. **infra VM** — `scripts/init-host.sh`, then **Traefik**
   ([traefik-setup.md](traefik-setup.md)) for TLS + routing, then **Authentik**
   ([authentik-setup.md](authentik-setup.md)) for SSO, then
   [Dockge](../infra/dockge/) and the Forgejo stack
   ([forgejo-setup.md](forgejo-setup.md)).
2. **apps VM** — install Coolify (guide TBD); `*.thefipster.de` already points
   at it.
