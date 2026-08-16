# Proxmox VE setup (greenfield homelab foundation)

**Runs on:** the bare server, then the Proxmox host shell

Turns the bare server into a hypervisor running three VMs:

```
Proxmox VE  ·  pve.thefipster.de          ← this guide
 ├─ VM: infra            → Traefik + Vaultwarden + Authentik + Forgejo + Dockge + monitoring
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
2. **While you are in there, set "Restore on AC Power Loss" to *Power On***
   (some boards call it "AC Back" or "After Power Failure"). Without it the UPS
   work in [Part 10](#part-10--survive-a-power-cut) is half-finished: the host
   shuts its guests down cleanly on battery and then stays dark when mains
   returns, because nothing tells it to boot. It costs nothing now and needs a
   second trip into the firmware later.
3. **Download the Proxmox VE ISO** from <https://www.proxmox.com/downloads>.
4. **Write it to a USB stick**:
   - Linux/macOS: `dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress` (pick
     the right `/dev/sdX`!), or
   - Windows: **Rufus** in **DD/raw** mode, or **balenaEtcher**.

---

## Part 2 — Install Proxmox

Boot the server from the USB stick and pick **Install Proxmox VE (graphical)**.

1. Accept the EULA.
2. **Target disks** — select **both 1 TB NVMe drives**, then *Options* →
   Filesystem **`zfs (RAID1)`**. That mirrored pair becomes `rpool`: the
   hypervisor itself and every VM root disk. Leave `ashift` on its default (`12`,
   right for any modern drive).

   **Leave the other six drives untouched here** — the 512 GB NVMe pair and all
   four SATA SSDs. The installer only ever builds the boot pool; the other three
   mirrors are created by hand in
   [Part 3](#part-3--post-install-housekeeping), once there is a shell to do it
   from. Selecting them now would fold all eight drives into one pool and throw
   away the whole point of the split.
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

Four things before any VM exists: the host's DNS record, the package
repositories, the other three mirrors, and a cap on ZFS's memory appetite. The
last two are new to this build and the reason the reboot at the end matters.

### Put the host's name on the router

**First, put the host's name on the router.** You chose a static address in
Part 2, so you already know it — add the single record
`pve.thefipster.de` → `pve ip` on the UDR now
([dns-records.md](dns-records.md) is the registry,
[wildcard-dns-udr.md](wildcard-dns-udr.md) the how-to). It takes a minute and
every step from here on can use the name instead of an address. The *rest* of the
record set waits for Part 6, when the VMs exist to point at.

Then open the web UI at **`https://pve.thefipster.de:8006`** (self-signed cert →
accept the warning). Log in as `root`.

### Switch the package repositories

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

### Build the other three mirrors

The installer left six drives alone — the 512 GB NVMe pair and all four SATA
SSDs. They become three more mirrors. Address them **by `/dev/disk/by-id/`
path, never `/dev/sdX`** — SATA letters are assigned in discovery order and will
move between boots, which on a pool is how you end up mirroring a drive against
itself. List what is there:

```bash
ls -l /dev/disk/by-id/ | grep -v -- '-part'
```

**That lists each disk more than once, and the duplicates are not extra
drives.** udev writes one symlink per identifier it can derive, and a SATA disk
exposes at least two: `ata-<MODEL>_<SERIAL>`, built from the ATA IDENTIFY
strings, and `wwn-0x…`, the World Wide Name in the drive firmware. Entries
resolving to the same `../../sdX` are one disk — and on Crucial drives the WWN
is derived from the serial, so the tails match visibly
(`…_2022E2A7651D` and `wwn-0x500a0751e2a7651d`).

**Use the `ata-…` form.** Both are equally stable across boots, which is the
whole point of `by-id` over `sdX`. The difference shows up the day a drive
fails: `zpool status` prints the name the pool was created with, and that
output is what tells you which of four physically identical drives to unplug.
`ata-CT500MX500SSD1_2022E2A7651D` names the model and the serial printed on the
label. `wwn-0x500a0751e2a7651d` does not get you there without a lookup.

The first 1 TB SATA pair becomes `vmbackup`, the whole-VM archive target:

```bash
zpool create -o ashift=12 -O compression=lz4 vmbackup mirror /dev/disk/by-id/<sata-1tb-a> /dev/disk/by-id/<sata-1tb-b>
```

The second 1 TB SATA pair becomes `filebackup`, which holds the restic
repository — see [roadmap/backup.md](roadmap/backup.md):

```bash
zpool create -o ashift=12 -O compression=lz4 filebackup mirror /dev/disk/by-id/<sata-1tb-c> /dev/disk/by-id/<sata-1tb-d>
```

The 512 GB NVMe pair becomes `data`, which carries the apps VM's second disk:

```bash
zpool create -o ashift=12 -O compression=lz4 data mirror /dev/disk/by-id/<nvme-512g-a> /dev/disk/by-id/<nvme-512g-b>
```

> **If `zpool create` refuses the disks, that is the safety interlock, not a
> failure.** ZFS declines a device carrying a recognisable filesystem
> signature, because that usually means the wrong device was named. Retail and
> shucked SSDs commonly arrive formatted exFAT, so expect it on all three
> hand-built pairs.
>
> Confirm there is nothing on them you want — this is the one step here that
> destroys data you might not have meant to give up:
>
> ```bash
> mkdir -p /mnt/check && mount -o ro /dev/disk/by-id/<disk>-part1 /mnt/check && ls -la /mnt/check
> ```
>
> ```bash
> umount /mnt/check
> ```
>
> Then clear the signatures explicitly — on the **whole** disk, no `-part1`:
>
> ```bash
> wipefs -a /dev/disk/by-id/<disk-a> /dev/disk/by-id/<disk-b>
> ```
>
> The original `zpool create` now succeeds unchanged. **Reach for `wipefs`
> rather than `zpool create -f`:** `-f` only tells ZFS to ignore the signature,
> leaving the old superblock and partition table on disk underneath ZFS's own
> labels, where `blkid`, `lsblk -f` and the Proxmox disk view will go on
> reporting the drive as exFAT. `wipefs -a` removes the signature *and* the
> partition table, so the pool sits on a clean device and nothing contradicts
> `zpool status` later.

Confirm all four pools are `ONLINE` and each mirror shows two devices:

```bash
zpool status
```

Now register the two that Proxmox itself uses. **The two commands are different
storage types, and that is not a detail you can guess:**

```bash
pvesm add zfspool data --pool data --content images,rootdir
```

```bash
pvesm add dir vmbackup --path /vmbackup --content backup --is_mountpoint 1 --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=3
```

A ZFS pool registered as `zfspool` accepts content `images,rootdir` **only** — it
cannot hold `vzdump` output. So the backup mirror is registered as a *Directory*
storage on the pool's mountpoint instead. Get this backwards and the pool simply
never appears in the backup job's storage dropdown, with nothing to explain why.

`--is_mountpoint 1` is the safety catch on that arrangement: it tells Proxmox to
refuse the storage when `/vmbackup` is *not* a mounted filesystem. Without it, a
pool that failed to import leaves an ordinary empty directory behind and every
backup writes to the **root pool** — filling the disk it was meant to protect,
while reporting success.

`filebackup` gets **no `pvesm` entry at all**. Proxmox never writes to it; it is a
plain filesystem that a restic client reaches over SFTP, which is why it is a
pool and not a Proxmox storage.

### Cap the ZFS ARC

ZFS caches in RAM, and its cache is not free memory — it competes with the VMs.
Historically the limit defaults to **half of RAM**, which here would be 48 GB
against the 56 GB the three VMs want. Recent Proxmox installers write a 10%
limit of their own instead — **and that file beats the one you are about to
write**, so it has to go first.

See what is already set:

```bash
grep -rn zfs_arc_max /etc/modprobe.d/
```

A line holding roughly a tenth of your RAM, usually in
`/etc/modprobe.d/zfs.conf`, is the installer's. Comment it out — the goal is
exactly **one** file setting this parameter. (If the `grep` came back empty,
this installer wrote no limit: skip to the next command, since there is nothing
to neutralise and the file below will be the only one.)

```bash
sed -i 's/^options zfs zfs_arc_max=/# superseded by 99-zfs-arc.conf: &/' /etc/modprobe.d/zfs.conf
```

> **A `99-` prefix does not win here, and that is the trap.** `modprobe` reads
> `/etc/modprobe.d` in lexicographic order and the module receives the **last**
> value given for a parameter — and `9` sorts before `z`, so `zfs.conf` is
> applied *after* `99-zfs-arc.conf` and silently overrides it. This is the
> opposite of `sysctl.d` and `apt.conf.d`, where a high number wins, which is
> what makes the filename look like it should be enough. Deleting the duplicate
> is what makes the result independent of sort order.

Now set it explicitly to 16 GB:

```bash
echo "options zfs zfs_arc_max=17179869184" > /etc/modprobe.d/99-zfs-arc.conf
```

```bash
update-initramfs -u -k all
```

**That rebuild is not optional.** The root filesystem is ZFS, so the module is
loaded from the initramfs long before `/etc` is readable — the copy of
`/etc/modprobe.d` *inside* the initramfs is what decides the value, and an edit
that never reaches it changes nothing.

It takes effect on the reboot below. Verify afterwards — the value should be
exactly `17179869184`, not `0` and not a tenth of your RAM:

```bash
cat /sys/module/zfs/parameters/zfs_arc_max
```

If it still reads a tenth of your RAM, a second file is setting the parameter:
run the `grep` above again and neutralise whatever it finds.

**Coming back to this later, on a running system, needs no reboot.**
`zfs_arc_max` is writable at runtime, so this applies immediately — ARC then
shrinks toward the new ceiling over the following minutes rather than at once.
The initramfs rebuild above is what makes the value survive the next boot:

```bash
echo 17179869184 > /sys/module/zfs/parameters/zfs_arc_max
```

### Give the host a real certificate

The UI you accepted a warning for above can have a genuine one, and it is worth
doing now rather than later: every step from here on that talks to this host
over HTTPS stops needing an exception, and so does every browser you ever open
it in.

Proxmox ships its **own** ACME client, and it speaks the same DNS-provider API
set as `acme.sh` — netcup included. So the hypervisor issues its own certificate
and depends on nothing else in the lab to do it. That independence is the whole
design here, and [Serve it on 443](#serve-it-on-443) below says why it is worth
paying for.

**Ask for the exact name, never a wildcard.** [Traefik](traefik-setup.md) will
later request `*.thefipster.de`, and Coolify's proxy requests a wildcard of its
own — both validating at the same `_acme-challenge.thefipster.de`. netcup's zone
updates are not atomic, so two clients writing one FQDN is how a challenge times
out with nothing to explain it; the same hazard is why the wildcard carries no
apex SAN (`infra/traefik/compose.yaml`). An exact certificate for
`pve.thefipster.de` validates at `_acme-challenge.pve.thefipster.de` — a
different record — and races with nobody.

You need three values from netcup's customer control panel, the same three
Traefik will want later: **customer number**, **API key**, **API password**.
Once [Vaultwarden](vaultwarden-setup.md) exists that is where they live; for now
have them to hand.

Register an ACME account against Let's Encrypt:

```bash
pvenode acme account register default <your-acme-email>
```

**It prompts for a directory endpoint — pick `0`, Let's Encrypt V2
(production).** This is the same call
[traefik-setup.md](traefik-setup.md) makes: first issuance goes **straight to
the production CA**, one challenge total, with staging kept only for debugging
issuance that keeps failing.

Going to staging first would cost a second netcup propagation wait — up to ten
minutes each — for a certificate browsers still refuse, and it would tell you
nothing, because the failure you are actually likely to hit here is netcup being
slow rather than the CA objecting, and that looks identical against either
endpoint. The rate limit worth respecting (roughly five failed validations per
hostname per hour) is not in play for one exact name ordered once. If issuance
*does* keep failing, the CA is the lever to move then — not the account you
register now.

Stage the credentials in a file for the plugin to read:

```bash
printf 'NC_Apikey=%s\nNC_Apipw=%s\nNC_CID=%s\n' '<api-key>' '<api-password>' '<customer-number>' > /tmp/netcup.env
```

```bash
pvenode acme plugin add dns netcup --api netcup --data /tmp/netcup.env --validation-delay 900
```

```bash
rm -f /tmp/netcup.env
```

**That `rm` is a step, not tidying up.** Proxmox reads the file once and copies
the values into `/etc/pve/priv/acme/plugins.cfg`; leaving the original behind
means a second plaintext copy of your DNS credentials sitting in `/tmp`, where
nothing will ever remind you it is there.

The 900-second validation delay matches the `NETCUP_PROPAGATION_TIMEOUT` that
[traefik-setup.md](traefik-setup.md) sets for the same reason: netcup publishes
TXT records slowly, often around ten minutes, regardless of which client is
asking. Expect the wait rather than assuming the order has hung.

Point the node at the name and order the certificate:

```bash
pvenode config set --acmedomain0 pve.thefipster.de,plugin=netcup
```

```bash
pvenode acme cert order
```

**Expect it to sit at `pending` for a long stretch** — that is the validation
delay above waiting on netcup, not a hang. Watch it under *pve → Certificates*
or in the task log rather than interrupting it; a cancelled order leaves a
challenge record behind that the next attempt has to race.

Verify the issuer and the subject — this one runs on the host and checks the
certificate only, not yet the port:

```bash
openssl s_client -connect localhost:8006 -servername pve.thefipster.de </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

The issuer must be Let's Encrypt and the subject `CN=pve.thefipster.de`. If it
still reads `CN=pve.thefipster.de` with a Proxmox issuer, the order did not
replace anything — re-read the task log under *pve → Certificates*.

Renewal needs nothing from you. Proxmox's own `pve-daily-update.timer` renews
when fewer than 30 days remain, which is the same policy Traefik applies to the
wildcard, on a different clock ([timetable.md](timetable.md)).

### Serve it on 443

pveproxy cannot be moved off 8006 — the port is not configurable — so the way to
answer on 443 is to rewrite the destination port *below* pveproxy rather than
put another web server in front of it.

```bash
mkdir -p /etc/nftables.d
```

```bash
cat > /etc/nftables.d/pve-https-redirect.nft <<'EOF'
#!/usr/sbin/nft -f
# Serve the Proxmox web UI on :443 by rewriting the destination port to :8006.
#
# Its OWN table, declared-then-deleted-then-created so this file is idempotent.
# It deliberately does not touch /etc/nftables.conf, so it coexists with
# proxmox-firewall instead of fighting it for ownership of the ruleset.
#
# dstnat priority puts this ahead of any filter chain, so a firewall downstream
# sees dport 8006 -- which Proxmox's own management rules already permit.
# Nothing new has to be opened.
#
# DNAT rewrites the destination only, so pveproxy still sees the real client
# address. A socket proxy or an nginx front end would have had every connection
# arrive from loopback instead.
table inet pve-https
delete table inet pve-https
table inet pve-https {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    tcp dport 443 redirect to :8006
  }
}
EOF
```

```bash
cat > /etc/systemd/system/pve-https-redirect.service <<'EOF'
[Unit]
Description=Serve the Proxmox web UI on :443 by redirecting to :8006
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/pve-https-redirect.nft
ExecStop=-/usr/sbin/nft delete table inet pve-https

[Install]
WantedBy=multi-user.target
EOF
```

The `-` on `ExecStop` is deliberate: deleting a table that is not there must not
fail the unit.

```bash
systemctl enable --now pve-https-redirect.service
```

```bash
nft list table inet pve-https
```

**`:8006` stays open.** This adds a door; it does not close one — and that door
is the fallback the day the rule is wrong.

> **Verify from a LAN client, not from this host.** Locally-generated traffic
> never traverses `prerouting`, so running the check below *on the hypervisor*
> bypasses the rule entirely and fails in a way that looks exactly like a broken
> rule. This is the single most expensive misunderstanding in this Part.
>
> ```bash
> curl -sI https://pve.thefipster.de | head -1
> ```
>
> Or from the Windows workstation:
>
> ```powershell
> (Invoke-WebRequest -Uri https://pve.thefipster.de -Method Head).StatusCode
> ```

**Why this host and not Traefik.** Every other UI in the lab is fronted by
Traefik on the infra VM, and this one deliberately is not. Traefik can only
serve a name that resolves to the infra VM, so `pve.thefipster.de` would have to
become a *service* name pointing there — forcing a new name on the machine, which
Alloy's scrape target, the restic repository and the FQDN typed into the
installer would all have to follow. The deeper objection stands even if that
rename were free: it would make the hypervisor's management UI depend on one of
the hypervisor's own guests, and this UI is the repair surface. It is where you
start a VM that will not start and open a console to find out why. Same
reasoning that keeps [Vaultwarden](vaultwarden-setup.md) out of SSO, one level
down — and it is why the Proxmox web UI appears in
[sso-applications.md](sso-applications.md#the-proxmox-web-ui-deliberately-not-joined)
as a deliberate non-joiner rather than as a gap.

### Update and reboot

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
| Cores | 12 | 12 | 12 |
| CPU type | `host` | `host` | `host` |
| `cpuunits` | 100 (default) | 50 | 200 |
| Memory | 24576 MB | 24576 MB | 8192 MB |
| Ballooning | off | off | off |
| Root disk | 150 GB on `local-zfs` | 64 GB on `local-zfs` | 64 GB on `local-zfs` |
| Second disk | — | **300 GB on `data`**, `backup=0` | — |
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
  that answers on it is installed inside each guest by `scripts/init-host.sh`
  ([infra-vm-setup.md](infra-vm-setup.md), [apps-vm-setup.md](apps-vm-setup.md)).
- **Disk:** storage **`local-zfs`**, bus **VirtIO SCSI single** (default), tick
  **Discard** and **SSD emulation**. The two do different jobs, and neither is
  implied by the pools being flash — the host knows that, the **guest** does
  not. *Discard* passes the guest's TRIM through to the storage layer, so blocks
  freed inside the VM are released on the zvol instead of it only ever growing;
  that is the one with real consequences. *SSD emulation* only changes what the
  guest is told the media is: without it a virtual disk advertises itself as
  rotational, so the guest optimises for seeks that cannot happen. Modest on
  these Linux guests, free, and true.
- **CPU:** type **`host`** (best performance on a single-node lab), **1 socket**
  with all 12 cores on it. `cpuunits` is not in the wizard — set it afterwards
  under *VM → Options → CPU units*, or with
  `qm set 102 --cpuunits 50`.
- **Memory:** as above, and **untick Ballooning Device**. Fixed allocations here,
  deliberately — see [Why these sizes](#why-these-sizes).
- **Network:** model **VirtIO (paravirtualized)**, bridge **`vmbr0`**.

**Then give the apps VM its second disk**, on the `data` mirror rather than the
root pool. This is where Coolify's app volumes, databases and image layers live —
the part that actually grows:

```bash
qm set 102 --scsi1 data:300,discard=on,ssd=1,backup=0
```

Do it before the OS install, so the disk is present when
[coolify-setup.md](coolify-setup.md) mounts it.

**`backup=0` is load-bearing, not an optimisation.** `vzdump` includes every VM
disk by default, and 300 GB of container volumes on top of the VM roots would
leave the 1 TB backup mirror holding barely one compressed copy — no room for a
retention policy at all. Excluding it is what keeps
[Part 8](#part-8--schedule-whole-vm-backups) honest.

The trade is real and worth stating plainly: this disk is meant to be covered by
the **file-level** layer instead, which can restore a single directory. That
layer now exists ([backup-setup.md](backup-setup.md)) — but it runs on the
**infra VM**, and the apps VM has not joined the restic repository yet
([roadmap/backup.md](roadmap/backup.md)). Until it does, everything on the apps
VM's data disk is unbacked. That is currently harmless because the VM has no
services on it, and it stops being harmless the day it does.

**Confirm the disk options actually took**, on both VMs — a tick missed in the
wizard is completely silent, and the only symptom is a zvol that grows and never
shrinks:

```bash
qm config 101 | grep -E '^scsi[0-9]'
```

```bash
qm config 102 | grep -E '^scsi[0-9]'
```

Every disk line must carry `discard=on` and `ssd=1`. If one does not, tick the
two boxes under *VM → Hardware → double-click the disk*. **Then stop and start
the VM** — those options are handed to QEMU when the process starts, so a
reboot from inside the guest leaves the change pending; `qm reboot <vmid>` does
the stop/start cycle properly. Nothing is lost by having run without them, but
once Discard is live, reclaim what accumulated meanwhile from inside the guest:

```bash
sudo fstrim -av
```

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

## Part 7 — Snapshot before you build

Take a clean baseline you can roll back to: select the VM → **Snapshots → Take
Snapshot** (name it `clean-install`). Do this again before risky changes — this is
the payoff for choosing Proxmox.

Snapshots are **not** backups and they are not free: a ZFS snapshot lives in the
same pool as the disk it snapshots, so every one you keep consumes `rpool` — the
one pool a failed disk would take with it. Scheduled whole-VM backups to a
different pool are [Part 8](#part-8--schedule-whole-vm-backups).

> **Rolling back skews the clock.** A rollback resumes the guest with its clock
> frozen at the moment the snapshot was taken — potentially days behind. Until
> the clock corrects, TLS fails in confusing ways: anything validating a
> certificate issued *after* the snapshot errors with `certificate has expired
> or is not yet valid`, which looks like a cert problem and isn't. Worse,
> chrony's default policy (`makestep 1 3`) steps the clock only during its
> first three updates after the service starts — a rollback happens long after
> those, so a large offset would only ever be slewed, i.e. effectively never
> corrected. `scripts/init-host.sh` fixes the policy
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
> Both Ubuntu VMs run `init-host.sh` ([infra-vm-setup.md](infra-vm-setup.md),
> [apps-vm-setup.md](apps-vm-setup.md)), so both are already fixed. The
> home-assistant VM is not: if you snapshot it — you should — force a resync
> from HA's own terminal after a rollback, or simply reboot the VM.

## Part 8 — Schedule whole-VM backups

This is **layer 1** of the backup design: whole-VM archives that answer "the disk
died" or "I broke the VM beyond repair" with one restore. The file-level layer
that answers "Authentik ate its database" is separate and lives in
[backup-setup.md](backup-setup.md) — layer 2, built on the infra VM near the end
of the build order. This one comes first because it needs nothing but the
hypervisor.

The target is the `vmbackup` mirror from [Part 3](#part-3--post-install-housekeeping)
— **~930 GB against the 278 GB of VM roots it archives**, and on different
physical drives, which is the entire point. A backup on the disk it protects is
not a backup.

Roughly three times the source is what makes a retention policy possible instead
of a single copy. Note the ratio is target against **source**, not against
`rpool`: the two pools are now the same size, and what `vmbackup` has to hold is
the roots, not the pool they sit in.

*Datacenter → Backup → **Add***:

| Field | Value |
|---|---|
| Storage | `vmbackup` |
| Schedule | `02:00` daily |
| Selection mode | **All** — new VMs are included automatically |
| Mode | **Snapshot** |
| Compression | **ZSTD** |
| Retention | leave as *storage default* — set in Part 3 |

**Mode `Snapshot` is the one that needs the guest agent.** With
`qemu-guest-agent` running, Proxmox asks the guest to freeze its filesystems for
the instant the snapshot is taken, so the archive is consistent rather than a
torn image of a live disk. `scripts/init-host.sh` installs it on both Ubuntu VMs
([infra-vm-setup.md](infra-vm-setup.md), [apps-vm-setup.md](apps-vm-setup.md)),
HAOS ships it, and the
**Qemu Agent** tick in each VM's *Options* is the other half. Without it the job
still runs and still says "OK" — it just quietly produces the torn image.

Retention lives on the *storage* (`keep-daily=7,keep-weekly=4,keep-monthly=3`),
so the job inherits it and there is one place to change it. Run the job once with
**Run now** rather than waiting for 02:00, then check it landed on the right pool:

```bash
ls -lh /vmbackup/dump
```

```bash
zfs list vmbackup
```

If `/vmbackup/dump` is empty but the task said OK, the storage is not the pool —
re-read the `--is_mountpoint` note in Part 3.

The apps VM's 300 GB data disk is **not** in these archives, by the `backup=0`
set in [Part 5](#part-5--create-the-vms). That is what keeps a ~930 GB target able
to hold real retention instead of a single copy.

---

## Next — this guide is done for now

**Continue with [wildcard-dns-udr.md](wildcard-dns-udr.md)**: the reservations
and records from [Part 6](#part-6--give-the-vms-their-addresses-on-the-router),
with [dns-records.md](dns-records.md) as the registry of exactly what to add.
Every guide after it assumes those records exist.

**Parts 9 and 10 below are deliberately out of sequence — skip them now.** Both
run on the *hypervisor*, which is why they live in this guide, and both report
into things the infra VM has not built yet: a Kuma push monitor and this host's
node exporter.
[uptime-kuma-setup.md step 7](uptime-kuma-setup.md#7-go-back-to-the-proxmox-guide-for-the-pool-monitor)
sends you back here at the right moment. They are the only parts of the build
order that cannot be finished in their own guide's turn.

**Part 10 splits, and the split is worth knowing about.** Its shutdown chain —
steps 1 to 5 — depends on nothing but the UPS and this host, so it can be done
the day the hardware is plugged in, long before Uptime Kuma exists. Only its
reporting half waits. If you have the UPS now, do the first half now: it is the
half that protects the pools.

---

## Part 9 — Notice when a mirror degrades

> **Come back to this after [uptime-kuma-setup.md](uptime-kuma-setup.md).** It
> is documented here because the script runs on the *hypervisor*, not in a VM,
> but it depends on **two** things the infra VM build supplies first: a push URL
> from Kuma, and the `prometheus-node-exporter` that
> [grafana-setup.md step 6](grafana-setup.md#6-add-the-proxmox-host) installs on
> this host — the script writes its metrics into that package's textfile
> directory. Both exist by the time Kuma is finished, so arriving here in build
> order needs no extra installs. **Reading this while still in Part 3 is why it
> looks like a step is missing: it is, and it comes later.**

Eight drives in four mirrors buy nothing if a failure is silent — and **a degraded
mirror is exactly the failure that takes nothing down.** The host keeps running,
the VMs keep running, redundancy is quietly gone, and the second drive fails
weeks later into an audience of nobody.

Kuma has no "run a command" monitor type, so the host reports *to* it: a timer
evaluates pool health and calls a **push monitor**. Create the monitor first —
its row is in [uptime-kuma-monitors.md](uptime-kuma-monitors.md) — and copy its
push URL.

The script does **two** things from one `zpool list`, because both consumers want
the same three seconds of work: it pushes health to Kuma, and it writes pool
capacity where Prometheus can scrape it. Capacity has to come from here —
node_exporter's own `zfs` collector reports ARC statistics and per-pool I/O, but
**not** how full a pool is, and `node_filesystem_*` cannot see zvols at all.

Note that the health check walks an **expected list** of pools rather than
whatever `zpool list` happens to return, because a pool that failed to import
does not appear in that output at all. A mirror that loses one member degrades
and is still listed; a pool that loses both members, or whose controller drops,
is simply **absent** — and absence is exactly what a check that trusts
`zpool list` cannot see:

```bash
cat > /usr/local/bin/zfs-health-push.sh <<'EOF'
#!/usr/bin/env bash
# Push ZFS pool health to Uptime Kuma, and write pool capacity for Prometheus.
set -uo pipefail

PUSH_URL="${PUSH_URL:?PUSH_URL is not set}"
EXPECTED="rpool vmbackup data filebackup"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"

# Fail closed: if zpool itself errors, write nothing, push nothing, and let the
# deadman fire. A stale metric beside a silent failure is worse than neither.
health="$(zpool list -Hp -o name,size,allocated,free,health)" || exit 1

# ---- metrics: written to a temp file and moved into place, so node_exporter
# ---- never reads a half-written file
if [ -d "$TEXTFILE_DIR" ]; then
  tmp="$(mktemp "$TEXTFILE_DIR/zfs_pool.prom.XXXXXX")"
  {
    echo '# HELP zfs_pool_size_bytes Total usable size of the pool.'
    echo '# TYPE zfs_pool_size_bytes gauge'
    printf '%s\n' "$health" | awk '{ printf "zfs_pool_size_bytes{pool=\"%s\"} %s\n", $1, $2 }'
    echo '# HELP zfs_pool_allocated_bytes Space allocated in the pool.'
    echo '# TYPE zfs_pool_allocated_bytes gauge'
    printf '%s\n' "$health" | awk '{ printf "zfs_pool_allocated_bytes{pool=\"%s\"} %s\n", $1, $3 }'
    echo '# HELP zfs_pool_free_bytes Space free in the pool.'
    echo '# TYPE zfs_pool_free_bytes gauge'
    printf '%s\n' "$health" | awk '{ printf "zfs_pool_free_bytes{pool=\"%s\"} %s\n", $1, $4 }'
    echo '# HELP zfs_pool_online Whether the pool state is ONLINE.'
    echo '# TYPE zfs_pool_online gauge'
    printf '%s\n' "$health" | awk '{ printf "zfs_pool_online{pool=\"%s\"} %d\n", $1, ($5 == "ONLINE" ? 1 : 0) }'
  } > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$TEXTFILE_DIR/zfs_pool.prom"
fi

# ---- health: pushed to Kuma
problems=""
for pool in $EXPECTED; do
  state="$(printf '%s\n' "$health" | awk -v p="$pool" '$1 == p { print $5 }')"
  [ -z "$state" ] && state="MISSING"
  [ "$state" != "ONLINE" ] && problems="${problems}${pool} ${state}; "
done

if [ -z "$problems" ]; then
  curl -fsS --max-time 10 --get "$PUSH_URL" \
    --data-urlencode "status=up" --data-urlencode "msg=all pools ONLINE" >/dev/null
else
  curl -fsS --max-time 10 --get "$PUSH_URL" \
    --data-urlencode "status=down" --data-urlencode "msg=$problems" >/dev/null
fi
EOF
```

Each metric family is emitted with its `HELP`/`TYPE` and all of its samples
together, which the Prometheus text format requires — interleaving them per pool
would be easier to write and is not valid.

**The textfile directory has to exist and be the one node_exporter reads.** It is
created by the `prometheus-node-exporter` package installed in
[grafana-setup.md step 6](grafana-setup.md#6-add-the-proxmox-host), but verify
the collector is actually pointed at it rather than assuming:

```bash
ps -o args= -C prometheus-node-exporter
```

If `--collector.textfile.directory` is missing from that output, add it and
restart:

```bash
echo 'ARGS="--collector.textfile.directory=/var/lib/prometheus/node-exporter"' >> /etc/default/prometheus-node-exporter
```

```bash
systemctl restart prometheus-node-exporter
```

The `if [ -d ... ]` guard means the script still pushes health correctly on a
host where the directory does not exist — the metrics are the part that degrades,
not the alerting.

```bash
chmod +x /usr/local/bin/zfs-health-push.sh
```

The push URL is a bearer token in a query string, so it goes in a mode-600 file
rather than in the unit:

```bash
install -m 600 /dev/null /etc/default/zfs-health-push
```

```bash
echo 'PUSH_URL=https://uptime.thefipster.de/api/push/<token>' > /etc/default/zfs-health-push
```

The unit and its timer:

```bash
cat > /etc/systemd/system/zfs-health-push.service <<'EOF'
[Unit]
Description=Report ZFS pool health to Uptime Kuma
After=zfs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/zfs-health-push
ExecStart=/usr/local/bin/zfs-health-push.sh
EOF
```

```bash
cat > /etc/systemd/system/zfs-health-push.timer <<'EOF'
[Unit]
Description=Report ZFS pool health every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

```bash
systemctl enable --now zfs-health-push.timer
```

Verify it pushed, rather than trusting that it will:

```bash
systemctl start zfs-health-push.service && systemctl status zfs-health-push.service
```

The monitor in Kuma should go green within a minute, and its message should read
`all pools ONLINE`.

Then check the other half — four lines, one per pool:

```bash
cat /var/lib/prometheus/node-exporter/zfs_pool.prom
```

And confirm node_exporter is actually serving them, which is the step that
catches a wrong textfile directory:

```bash
curl -s localhost:9100/metrics | grep '^zfs_pool_'
```

Alloy already scrapes this endpoint, so nothing changes on the infra VM — the
metrics arrive on the next scrape and
[grafana-setup.md](grafana-setup.md#what-diskalmostfull-sees-under-zfs) has the
queries and the alert.

**The unit fails with `status=22` and `curl: (22) ... error: 404`.** Exit 22 is
`curl -f` on any status at or above 400, and `-f` together with `-s` discards the
response body — which is the only part that says *who* answered. Ask again by
hand, keeping the body:

```bash
set -a; . /etc/default/zfs-health-push; set +a; curl -i --get "$PUSH_URL" --data-urlencode "status=up" --data-urlencode "msg=manual test"
```

A 404 **carrying Kuma's JSON** (`{"ok":false,"msg":"Monitor not found or not
active."}`) means the request arrived and the token did not match an active push
monitor: it was never saved, it was regenerated in the edit form, or the monitor
is paused. A 404 with **no JSON** means the request never reached Kuma at all —
either the Kuma container is down, which withdraws its Traefik router along with
it and so produces a 404 rather than a 502, or the name resolved to the apps VM
and you are looking at Coolify's 404 behind a valid certificate.

Check both address families before believing the token is wrong:

```bash
getent ahostsv4 uptime.thefipster.de; echo ---; getent ahostsv6 uptime.thefipster.de
```

The IPv6 half is the one worth running. A public AAAA sends this push out to the
internet and back with nothing in `/etc/default/zfs-health-push` looking any
different — [dns-records.md](dns-records.md#no-aaaa-records-anywhere) has the
invariant and the sweep.

**What this covers, and what it doesn't.** A degraded or faulted pool pushes
`down` *with the pool name in the notification*, so ntfy tells you which drive to
look at. If the script breaks, the host loses power, or the network goes, nothing
is pushed at all and the monitor goes down as a plain deadman — two failure modes,
one monitor. What it does not cover is a disk that is dying but has not yet been
kicked from its pool; that is SMART's job, and the same script could grow a
`smartctl -H` loop later.

**Why the deadman also protects the metrics.** A textfile that stops being
updated does not disappear — node_exporter keeps serving the last version
indefinitely, so a dead script would leave Prometheus reading a frozen capacity
figure that looks perfectly healthy. That would normally need its own staleness
alert. Here it does not: the same script writes the file and pushes the
heartbeat, so a script that stops writing also stops pushing, and Kuma says so.
Keeping both jobs in one script is what makes that true — splitting them would
mean adding the staleness alert back.

`zfs-zed` is the native alternative and fires on the ZFS event itself rather than
on a five-minute poll. It is better latency, and it needs a working outbound MTA
— Proxmox's stock postfix only delivers locally, so it is a mail relay to
configure rather than a checkbox. Worth adding as a belt to this braces; not
worth blocking on.

---

## Part 10 — Survive a power cut

> **Steps 1–5 need nothing but the UPS and this host** — do them the day the
> hardware arrives. **Steps 6–8 need the infra VM**: a Kuma push monitor, and
> the `prometheus-node-exporter` that
> [grafana-setup.md step 6](grafana-setup.md#6-add-the-proxmox-host) installs
> here. Same dependency as [Part 9](#part-9--notice-when-a-mirror-degrades), and
> arriving here in build order needs no extra installs.

ZFS survives having the power pulled — that is what the transaction log is for.
The things that do not are the writes in flight inside three VMs, the 02:00
backup window, and the 04:30 patch-reboot window. A power cut offers roughly
zero seconds to finish any of them, so the fix is not better crash tolerance but
**a few minutes of borrowed time and an orderly shutdown inside it.**

The hardware is a **CyberPower CP900EPFCLCD** — 900 VA / 540 W, line-interactive,
PFC sinewave — connected to this host by its **USB data cable**, not just its
power lead. That cable is the whole integration; without it the UPS is a battery
that nothing can ask any questions.

**What goes on it.** All six outlets on this model are battery-backed *and*
surge-protected, so there is no wrong socket to pick and nothing to check on the
back panel — the only question is what you plug in, and **six is the budget**.

The server is obvious. The **UDR** and any switch between it and the server are
not, and they matter for a reason the server does not: the network has to
outlive the host so the shutdown can be reported *while it happens*, rather than
reconstructed from logs afterwards.

> **Spend one of the six on your modem or ONT.** Notifications leave the lab
> through hosted ntfy.sh, so the WAN termination is part of the alerting path
> and it is the piece most likely to be sitting on a wall socket on the other
> side of the room. Left on mains it dies with the mains, and the entire
> reporting half of this Part goes silent at exactly the moment it exists for.
> Everything else still works — the shutdown runs over USB and needs no network
> at all — you simply find out afterwards.

At 900 VA / 540 W the electrical headroom is not the constraint here; the outlet
count is. Anything you add beyond the server, the network path and the WAN
termination is spending a socket one of those might want later.

What this buys is **an orderly shutdown, not continuity**: no generator, no
second UPS, nothing offsite. The lab goes down. It goes down on purpose, in the
right order, and it comes back by itself.

### 1. Install NUT and confirm the UPS is seen

```bash
apt install nut-server nut-client
```

```bash
lsusb | grep -i cyber
```

A line naming CyberPower means the kernel has the device. Then ask NUT whether
it recognises it as a UPS:

```bash
nut-scanner -U
```

That prints a ready-made `ups.conf` stanza. The next step writes one by hand
anyway, so the file carries this lab's own comments rather than a generated
block — but a scanner that finds nothing is the signal to stop and check the
cable before going further.

### 2. Configure NUT

**Standalone mode**, with `upsd` listening on loopback only. Nothing else on the
LAN talks to it, because no VM runs a NUT client — step 3 is where that decision
lives.

```bash
echo "MODE=standalone" > /etc/nut/nut.conf
```

```bash
cat > /etc/nut/ups.conf <<'EOF'
# Named `ups`, not after the model. The name appears in upsmon.conf, upsd.users,
# upssched.conf and every upsc call, and it should survive a hardware swap --
# the same function-not-product rule the Kuma monitors follow.
[ups]
  driver = usbhid-ups
  port = auto
  desc = "CyberPower CP900EPFCLCD"
EOF
```

```bash
cat > /etc/nut/upsd.conf <<'EOF'
# Loopback only. The guests are shut down by Proxmox itself, not by NUT clients,
# so nothing off this host ever needs to reach upsd.
LISTEN 127.0.0.1 3493
EOF
```

Generate the monitoring password rather than inventing one, the same way every
init script in this repo mints a secret. **The next three blocks run in one
shell session** — the variable is what carries the password into both files, and
a fresh shell between them writes an empty password into `upsmon.conf`, which
fails later with a message about credentials rather than about a typo:

```bash
NUT_PASS="$(openssl rand -hex 24)"
```

```bash
cat > /etc/nut/upsd.users <<EOF
[upsmon]
  password = ${NUT_PASS}
  upsmon primary
EOF
```

```bash
cat > /etc/nut/upsmon.conf <<EOF
MONITOR ups@localhost 1 upsmon ${NUT_PASS} primary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POWERDOWNFLAG /etc/killpower
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONLINE   SYSLOG+EXEC
NOTIFYFLAG ONBATT   SYSLOG+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG
NOTIFYFLAG COMMBAD  SYSLOG
NOTIFYFLAG COMMOK   SYSLOG
EOF
```

Both files now hold that password, so both get locked down:

```bash
chown root:nut /etc/nut/upsd.users /etc/nut/upsmon.conf && chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
```

Now start the driver — and **this is the step that is easy to skip and produces
the most confusing failure if you do**:

```bash
systemctl restart nut-driver-enumerator
```

**The driver does not run inside `upsd`.** On Debian,
`nut-driver-enumerator` reads `ups.conf` and generates one `nut-driver@<name>`
unit per UPS in it; `nut-server` neither starts nor depends on those. So a
stanza that has never been enumerated leaves you with a `upsd` that starts
perfectly, a `nut-monitor` that starts perfectly, and `Driver not connected` in
answer to every question. **Re-run the enumerator after every edit to
`ups.conf`** — it is the one file whose changes are not picked up by restarting
the obvious services.

Check the driver is up before asking it anything, so a failure here is not
mistaken for a configuration problem two steps later:

```bash
systemctl is-active 'nut-driver@ups'
```

```bash
systemctl restart nut-server nut-monitor
```

```bash
upsc ups
```

> `upsc` prints `Init SSL without certificate database` first. That is it
> noting it has no NSS certificate database, which is expected on a
> loopback-only setup and is not an error — ignore it and read the line after.

`ups.status` should read `OL` — on line. Three other fields in that output are
worth reading now rather than during an outage:

| Field | On this lab | Means |
|---|---|---|
| `battery.runtime.low` | `300` | the `LB` threshold — the UPS raises low battery with this many seconds left. Step 4's arithmetic turns on it. |
| `ups.delay.shutdown` | `20` | how long the UPS waits after being told to cut power before it actually does. The pause you will see in step 8's drill. |
| `driver.flag.allow_killpower` | `0` | **not a problem, despite the name.** It gates the `driver.killpower` instant command, which lets an *already running* driver cut power on request. The hook in step 5 calls `upsdrvctl shutdown` after the driver has stopped, which starts a fresh one with `-k` — a different path that does not consult this flag. |

`battery.runtime.low` is writable with `upsrw` if you ever want `LB` to arrive
earlier. Step 4 explains why this lab does not move it and uses a timer instead.

> **Voltage on this model reads correctly, and that is worth stating because
> older reports say otherwise.** `output.voltage` matching `input.voltage` at
> roughly mains is the expected result on NUT 2.8.1 with the CyberPower HID 0.8
> subdriver. The 260–270 V misreporting in
> [NUT #581](https://github.com/networkupstools/nut/issues/581) did **not**
> reproduce here. Nothing in this Part alerts on a voltage reading anyway —
> charge, runtime, load and status are what the decisions turn on — but if you
> hit that bug on some other build, it is cosmetic rather than a sign the driver
> picked the wrong device.

> **`lsusb` names the wrong model, and it is not a mismatch.** The USB ID
> database maps `0764:0501` to a `CP1500 AVR UPS`, so the earlier `lsusb` check
> prints that regardless of which unit you own. `upsc` is the one that asks the
> device: `device.model` and `ups.model` both read `CP900EPFCLCD`.

### 3. Set the guest shutdown order and timeout

**No VM runs a NUT client, deliberately.** Proxmox already does this job:
`pve-guests.service` shuts every guest down when the host halts, calling
`pvesh create /nodes/localhost/stopall`, which goes through the guest agent,
falls back to ACPI, and forces off after a per-guest timeout.

Three things make that the better answer rather than merely the easier one.
`scripts/init-host.sh` already installs `qemu-guest-agent` on both Ubuntu VMs
and HAOS ships it, so the clean path works for all three — the same investment
that makes `vzdump`'s Snapshot mode consistent in
[Part 8](#part-8--schedule-whole-vm-backups). The home-assistant VM is an
**appliance** this repo has no shell inside, so a design needing a client in
every guest would have had a hole in it from the start. And one shutdown path is
easier to reason about than four racing opinions about when to begin.

Two things are left to defaults today and should not be, and the first one is
**that the guests shut down one after another at all.**

Left alone, guests with no configured order fall back to VMID and stop
sequentially — `ha`, then `apps`, then `infra`, each waiting on the last. That
is the default, and on a machine running on battery it is the wrong shape:
**sequential turns a 90-second worst case into a 270-second one**, spending
three minutes of the only resource that is actually scarce here.

Staging buys something when guests depend on each other — a database that must
outlive its clients, storage one guest serves to another. **None of that exists
in this lab.** The three VMs share the hypervisor and nothing else: Home
Assistant is *proxied* by Traefik on the infra VM, but inbound routing is not a
shutdown dependency, and neither the apps VM nor the HA VM mounts anything from
infra or needs it to halt cleanly. Independent guests, so they can go together.

So give all three the **same** `order`, which is how Proxmox is told to stop
them in parallel:

```bash
qm set 101 --startup order=1,down=90
```

```bash
qm set 102 --startup order=1,down=90
```

```bash
qm set 103 --startup order=1,down=90
```

**This also makes them start in parallel**, because one `order` field governs
both directions — start ascending, stop descending. That is a fair trade rather
than a cost tolerated: at boot there is no battery draining, nothing here
depends on anything else being up first, and `cpuunits` already arbitrates the
CPU contention of three guests booting at once (home-assistant 200, infra 100,
apps 50 — see [Why these sizes](#why-these-sizes)).

> **An earlier version of this guide staged the shutdown so that Uptime Kuma, on
> the infra VM, would stay alive longest and keep reporting.** That reasoning
> does not survive contact with the rest of the design. The power-event push in
> step 6 fires the moment the UPS reports `ONBATT`, so you already know — and
> everything Kuma has to say during the shutdown *after* that is a cascade of
> expected red for machines you deliberately turned off. It was paying three
> minutes of battery for notification noise.

**`down=90` is the second thing, and it is arithmetic rather than taste.**
Proxmox defaults to a 180-second timeout per guest, which is the ceiling on how
long one hung guest can hold up the halt. Both Ubuntu VMs stop in well under 90
seconds, so the trim costs nothing real — and in parallel it is now the whole
worst case rather than one third of it.

```bash
for id in 101 102 103; do printf '%s: ' "$id"; qm config $id | grep startup; done
```

All three lines should read `order=1` and `down=90`. Different `order` values
are the thing to look for: that is the default behaviour coming back.

### 4. Decide when to shut down

The trigger is the UPS's own low-battery flag, with an `upssched` timer started
on `ONBATT` and cancelled on `ONLINE` as a backstop. That much is the standard
arrangement. What is worth knowing before you read the file is **which of the
two actually fires**.

**`LB` arrives too late to be the primary trigger, and the unit tells you so
itself.** `battery.runtime.low` reads `300` — the UPS raises low battery with
five minutes left, and it is an estimate produced by the battery gauge whose
accuracy is the thing you are trying not to depend on. Waiting for it means
starting a shutdown on the last of the reserve, on the word of the component
most likely to be wrong about how much reserve is left.

**So the backstop is not insurance for a tired battery; it is what fires in
practice, and its value is the actual policy.** The `LB` path stays as the floor
beneath it, for the case where the battery empties faster than the timer expects.

Raising `battery.runtime.low` with `upsrw` is the other way to buy margin, and
this lab does not take it: it moves the decision *into* the UPS's own runtime
estimate, which is exactly the number that drifts as the battery ages. A wall
clock started at `ONBATT` does not care how good that estimate is.

Size it by the relationship, not by the number:

> **backstop + worst-case guest shutdown < measured runtime**

With the parallel shutdown from step 3 that is 300 s + 90 s — **6.5 minutes**,
against a runtime step 8 measures rather than assumes. Sequential shutdown would
have made it 9.5, which is the three minutes step 3 declined to spend.

**300 s is the settled value, not a placeholder to grow later**, and the reason
is what a power interruption in this lab actually looks like. Real grid outages
here are rare and brief; the realistic event is someone catching the cable, or a
breaker going. For all of those, **five minutes is a grace period rather than a
countdown** — `ONLINE` cancels the timer, so power restored inside the window
costs nothing at all and the lab never notices.

Past that window the lab shuts down with most of the battery untouched, and
**that unused reserve is the point rather than waste.** It is the margin that
absorbs everything this arithmetic cannot predict: a battery that has aged since
the last drill, a load that grew when more equipment joined the UPS, a guest
that hangs and eats its whole 90 seconds, the UPS's own `ups.delay.shutdown`
pause. A longer backstop spends that margin to ride out medium-length outages
that mostly do not happen — trading a reserve that protects every shutdown for a
convenience that applies to few.

The formula above is still how to re-derive this if the hardware changes. It is
not an invitation to tune the number for its own sake.

> **`battery.runtime` is only worth reading under the real load.** It is an
> estimate for whatever is drawing power *right now*, so a figure taken before
> the server is plugged in describes a lab that does not exist — comfortably
> over an hour at router-and-switch load, and a fraction of that once the host
> is on the same battery. Check `ups.load` alongside it: a single-digit
> percentage on a box with this CPU and eight SSDs means the host is not on the
> UPS yet, and the runtime number is measuring the wrong thing.

```bash
cat > /etc/nut/upssched.conf <<'EOF'
CMDSCRIPT /usr/local/bin/upssched-cmd
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

# The backstop. See Part 10 step 4 for the arithmetic: this value plus the
# worst-case guest shutdown must stay under the measured runtime.
AT ONBATT  * START-TIMER  onbatt-shutdown 300
AT ONLINE  * CANCEL-TIMER onbatt-shutdown

# Report immediately. Kuma runs on a guest of this host and dies with it, so the
# window between ONBATT and the infra VM halting is the ONLY one in which an
# outage can be reported at all. A five-minute poll would routinely miss it.
AT ONBATT  * EXECUTE      power-event
AT ONLINE  * EXECUTE      power-event
AT LOWBATT * EXECUTE      power-event
EOF
```

```bash
cat > /usr/local/bin/upssched-cmd <<'EOF'
#!/usr/bin/env bash
# Called by upssched (running as the `nut` user) for each AT rule above.
set -uo pipefail

case "$1" in
  onbatt-shutdown)
    # Goes through upsmon rather than calling shutdown directly. That is what
    # writes POWERDOWNFLAG, which is what tells the UPS to cut power afterwards
    # so the box comes back when mains returns. Calling `shutdown` here would
    # halt the host perfectly correctly and silently skip the half that revives
    # it -- a failure you would discover during an outage, not before one.
    logger -t upssched-cmd "backstop timer expired - forcing shutdown"
    /usr/sbin/upsmon -c fsd
    ;;
  power-event)
    /usr/local/bin/ups-health-push.sh
    ;;
  *)
    logger -t upssched-cmd "unrecognised argument: $1"
    ;;
esac
EOF
```

```bash
chmod +x /usr/local/bin/upssched-cmd
```

`power-event` calls a script **step 6** creates. Until then that branch logs a
failure and does nothing else, which is harmless and exactly what you should see
if you wired the UPS up before Uptime Kuma existed.

**Everything `upssched` runs, runs as the `nut` user** — `upsmon` drops
privileges for its notify path, keeping a root parent only to run
`SHUTDOWNCMD`. So both branches above are unprivileged, and **both can fail in
ways nothing on the happy path would ever reveal.** Test them now rather than
discovering it 300 seconds into an outage.

The backstop's branch signals `upsmon`, which an unprivileged process can only
do if the PID it is signalling belongs to `nut`:

```bash
cat /run/nut/upsmon.pid
```

```bash
ps -o pid,user,args -C upsmon
```

That PID must be the **`nut`** one, not the root parent — NUT writes the child's
PID here precisely so `upsmon -c` works from this context. Then exercise the
signal itself. `-c reload` travels the identical path as `-c fsd` and merely
re-reads the configuration, so it is safe to run at any time:

```bash
runuser -u nut -- upsmon -c reload
```

A version banner and no permission error means the backstop can fire.
`journalctl -u nut-monitor -n 5` should show the reload. **Running this as
`root` proves nothing** — root can signal anything, so it passes whether or not
the real path works. The push branch has an equivalent check in step 6, for the
same reason and with the same trap.

### 5. Make the lab come back on its own

Two halves, and **either one alone leaves the box dark.**

The first is the BIOS setting from [Part 1](#part-1--prerequisites) — *Restore
on AC Power Loss* set to *Power On*. The second is killpower: `upsmon` writes
`/etc/killpower` before halting, and a systemd shutdown hook then runs
`upsdrvctl shutdown`, telling the UPS to cut its own output after a delay and
restore it when mains returns. **That interruption is what the BIOS setting
reacts to.**

Without it there is a specific, quiet failure. If mains comes back while the
host is still halting, the UPS never interrupts its output, so nothing ever
power-cycles — and the server sits off after an outage it appeared to handle
perfectly, waiting for someone to walk over and press the button.

**A long-standing Debian defect sits exactly here.** Look at the hook the
package ships:

```bash
cat /usr/lib/systemd/system-shutdown/nutshutdown
```

If it gates the killpower call on `upsmon -K`, that command has been reported to
always return false, so `upsdrvctl shutdown` never runs
([Debian #835555](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=835555)).
**Do not edit that file** — it lives under `/usr/lib` and is not a conffile, so
the next `nut-client` upgrade silently reverts you. Add your own beside it:

```bash
cat > /usr/lib/systemd/system-shutdown/zz-nut-killpower <<'EOF'
#!/bin/sh
# Cut UPS output after a power-fail shutdown, so the UPS cycles the load when
# mains returns and the BIOS "restore on AC power loss" setting boots the box.
#
# A SEPARATE file on purpose. Debian's own nutshutdown gates on `upsmon -K`,
# which has been reported to always return false (Debian #835555) -- but it
# lives under /usr/lib and is not a conffile, so editing it in place is
# silently reverted by the next nut-client upgrade. This runs alongside it from
# a plain file test. If nutshutdown is ever fixed, both run and the second one
# is a harmless no-op.
#
# Only on poweroff/halt. A REBOOT must not cut the UPS.
case "$1" in
  poweroff|halt)
    [ -f /etc/killpower ] && /sbin/upsdrvctl shutdown
    ;;
esac
EOF
```

```bash
chmod +x /usr/lib/systemd/system-shutdown/zz-nut-killpower
```

```bash
sh -n /usr/lib/systemd/system-shutdown/zz-nut-killpower && echo "syntax ok"
```

```bash
upsdrvctl -t shutdown
```

`-t` is a dry run: it confirms the driver would accept the command without
actually cutting power. That is all it proves. The real proof is the drill in
**step 8**, because this is the half most likely to be silently broken and the
only one whose failure waits for a real outage to show itself.

> **Four parts of this Part can only fail during an outage, and each has a way
> to be tested before one.** The signal the backstop sends
> ([step 4](#4-decide-when-to-shut-down), `upsmon -c reload` as `nut`); the push
> the event path makes ([step 6](#6-report-ups-state-to-kuma-and-prometheus),
> the script run as `nut`); that the push actually **notifies** (step 6's
> by-hand `status=down`); and killpower — `upsdrvctl -t shutdown` above. Run all
> four before the drill.
>
> Each one is written the way it is because the obvious version passes while the
> real path is broken: `root` can read files and signal processes that `nut`
> cannot, and a push that Kuma *records* is not the same as a push that Kuma
> *sends*. Every one of these was found the hard way.

### 6. Report UPS state to Kuma and Prometheus

This mirrors `zfs-health-push.sh` from
[Part 9](#part-9--notice-when-a-mirror-degrades) deliberately, because it is the
same problem: a condition on a machine with no checkout of the repo, wanted in
two places at once. One `upsc` read does both jobs.

Create the Kuma monitor first — its row is in
[uptime-kuma-monitors.md](uptime-kuma-monitors.md#power--proxmox-host) — and
copy its push URL.

```bash
cat > /usr/local/bin/ups-health-push.sh <<'EOF'
#!/usr/bin/env bash
# Report UPS state to Uptime Kuma, and write battery/load metrics for Prometheus.
# One upsc read, two consumers -- same shape as zfs-health-push.sh.
set -uo pipefail

# PUSH_URL lives in /etc/default/ups-health-push, and this script has to read it
# ITSELF rather than trust a caller to have done so. EnvironmentFile= is a
# systemd mechanism, so it only covers the timer path. upssched runs this script
# directly, inheriting upsmon's environment, where nothing has ever read that
# file -- so on the event path the variable would simply be unset, and the one
# push that matters most would be the only one that fails.
if [ -z "${PUSH_URL:-}" ] && [ -r /etc/default/ups-health-push ]; then
  . /etc/default/ups-health-push
fi

PUSH_URL="${PUSH_URL:?not set, and /etc/default/ups-health-push was not readable}"
UPS="${UPS:-ups@localhost}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"

# Fail closed. If upsc cannot read the UPS then the USB link is itself the
# fault, so say so rather than leaving a stale-looking healthy metric beside a
# silent failure.
if ! vars="$(upsc "$UPS" 2>/dev/null)"; then
  curl -fsS --max-time 10 --get "$PUSH_URL" \
    --data-urlencode "status=down" \
    --data-urlencode "msg=upsc cannot read $UPS" >/dev/null
  exit 1
fi

get() { printf '%s\n' "$vars" | awk -F': ' -v k="$1" '$1 == k { print $2; exit }'; }

status="$(get ups.status)"
charge="$(get battery.charge)"
runtime="$(get battery.runtime)"
load="$(get ups.load)"

# ups.status is a space-separated SET, not one word: "OL", "OL CHRG",
# "OB DISCHRG", "OB LB". Match on padded substrings rather than equality.
on_line=0;  case " $status " in *" OL "*) on_line=1 ;; esac
on_batt=0;  case " $status " in *" OB "*) on_batt=1 ;; esac
low_batt=0; case " $status " in *" LB "*) low_batt=1 ;; esac

# ---- metrics: temp file then mv, so node_exporter never reads a half-written
# ---- file. The -w test is load-bearing: this script also runs as `nut` from
# ---- upssched, which cannot write here. That path pushes and skips metrics,
# ---- which is fine -- the timer below owns the metrics.
if [ -d "$TEXTFILE_DIR" ] && [ -w "$TEXTFILE_DIR" ]; then
  tmp="$(mktemp "$TEXTFILE_DIR/ups.prom.XXXXXX")"
  {
    echo '# HELP ups_status_on_line Whether the UPS reports running on mains.'
    echo '# TYPE ups_status_on_line gauge'
    echo "ups_status_on_line $on_line"
    echo '# HELP ups_status_on_battery Whether the UPS reports running on battery.'
    echo '# TYPE ups_status_on_battery gauge'
    echo "ups_status_on_battery $on_batt"
    echo '# HELP ups_status_low_battery Whether the UPS has raised low battery.'
    echo '# TYPE ups_status_low_battery gauge'
    echo "ups_status_low_battery $low_batt"
    if [ -n "$charge" ]; then
      echo '# HELP ups_battery_charge_percent Battery charge.'
      echo '# TYPE ups_battery_charge_percent gauge'
      echo "ups_battery_charge_percent $charge"
    fi
    if [ -n "$runtime" ]; then
      echo '# HELP ups_battery_runtime_seconds Estimated runtime remaining.'
      echo '# TYPE ups_battery_runtime_seconds gauge'
      echo "ups_battery_runtime_seconds $runtime"
    fi
    if [ -n "$load" ]; then
      echo '# HELP ups_load_percent Load as a percentage of capacity.'
      echo '# TYPE ups_load_percent gauge'
      echo "ups_load_percent $load"
    fi
  } > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$TEXTFILE_DIR/ups.prom"
fi

# ---- health: pushed to Kuma. No voltage anywhere: it reads correctly on this
# ---- unit, but it is not what any decision here turns on.
if [ "$on_line" = 1 ] && [ "$low_batt" = 0 ]; then
  curl -fsS --max-time 10 --get "$PUSH_URL" \
    --data-urlencode "status=up" \
    --data-urlencode "msg=on mains, battery ${charge:-?}%" >/dev/null
else
  curl -fsS --max-time 10 --get "$PUSH_URL" \
    --data-urlencode "status=down" \
    --data-urlencode "msg=$status, battery ${charge:-?}%, ${runtime:-?}s left" >/dev/null
fi
EOF
```

```bash
chmod +x /usr/local/bin/ups-health-push.sh
```

The push URL is a bearer token in a query string, so it goes in a
mode-restricted file rather than in the unit — and **the mode here differs from
Part 9's on purpose**:

```bash
install -m 640 -o root -g nut /dev/null /etc/default/ups-health-push
```

```bash
echo 'PUSH_URL=https://uptime.thefipster.de/api/push/<token>' > /etc/default/ups-health-push
```

Part 9's equivalent is mode 600 and root-only. This one cannot be: `upssched`
runs as the `nut` user, so a root-only environment file would make every instant
power-event push fail on an unreadable file — the one push that matters most,
failing while the five-minute timer carried on looking healthy.

**The mode is necessary and not sufficient**, which is worth being explicit
about because the two failures look identical from the outside. The permission
lets `nut` read the file; the `.` in the script above is what actually reads it.
Getting the mode right while leaving the sourcing to `EnvironmentFile=` produces
exactly the same symptom — `PUSH_URL is not set` from the event path only —
and sends you to inspect a file that was correct all along.

**Test the event path now, without waiting for a power cut.** This is the one
verification that exercises what `upssched` will do: the `nut` user, no systemd,
no environment handed in.

```bash
runuser -u nut -- /usr/local/bin/ups-health-push.sh
```

It should exit silently and push `up` to Kuma. If it prints `PUSH_URL ... not
set`, the `nut` user cannot read `/etc/default/ups-health-push` — check the mode
and group above. Running it as `root` instead proves nothing about this path,
which is exactly the trap.

**Then prove the other half: that a push becomes a notification.** Reaching Kuma
and alarming Kuma are different things, and the gap between them is silent.
Send a down by hand:

```bash
set -a; . /etc/default/ups-health-push; set +a; curl -fsS --get "$PUSH_URL" --data-urlencode "status=down" --data-urlencode "msg=notification test"
```

A push should arrive on your phone **within seconds**. Then put it back:

```bash
set -a; . /etc/default/ups-health-push; set +a; curl -fsS --get "$PUSH_URL" --data-urlencode "status=up" --data-urlencode "msg=notification test cleared"
```

**If Kuma shows the message but no notification arrives, the monitor has retries
above zero.** An explicit `status=down` then lands the monitor in *pending*,
which notifies nobody, and it takes one more down beat per retry to transition —
beats that only arrive every five minutes, from a host that halts after five.
`Site Power` is specified with **0 retries** in
[uptime-kuma-monitors.md](uptime-kuma-monitors.md#power--proxmox-host) precisely
for this, and it is the one setting on that monitor that cannot be copied from
its neighbours.

Check the notification is attached to this monitor at all while you are there —
Kuma does not add one retroactively unless *Default enabled* and *Apply on all
existing monitors* were ticked when it was created.

### 7. Put it on a timer

```bash
cat > /etc/systemd/system/ups-health-push.service <<'EOF'
[Unit]
Description=Report UPS state to Uptime Kuma
After=nut-monitor.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/ups-health-push
ExecStart=/usr/local/bin/ups-health-push.sh
EOF
```

```bash
cat > /etc/systemd/system/ups-health-push.timer <<'EOF'
[Unit]
Description=Report UPS state every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

```bash
systemctl enable --now ups-health-push.timer
```

Verify it pushed, rather than trusting that it will:

```bash
systemctl start ups-health-push.service && systemctl status ups-health-push.service
```

The monitor in Kuma should go green within a minute, with a message naming the
battery percentage. Then check the other half:

```bash
cat /var/lib/prometheus/node-exporter/ups.prom
```

```bash
curl -s localhost:9100/metrics | grep '^ups_'
```

Alloy already scrapes this endpoint, so nothing changes on the infra VM — the
metrics arrive on the next scrape, and `UpsBatteryAging` in Grafana
([grafana-setup.md](grafana-setup.md#dashboards-and-alerts)) starts evaluating
against them.

If the unit fails with `status=22` and `curl: (22) ... 404`, it is the same
diagnosis as Part 9's push — [that troubleshooting
block](#part-9--notice-when-a-mirror-degrades) applies unchanged, including the
IPv6 check.

### 8. Pull the plug, once, on purpose

The runtime figure cannot come from the datasheet — it depends on this lab's
actual load — and it is the input to step 4's arithmetic. Killpower is worse: it
is the half most likely to be silently broken, and its failure mode is a box
that stays dark after an outage it appeared to survive. Neither can be settled
by reading.

So pull the mains plug on the UPS and watch the whole chain:

1. The on-battery push arrives on your phone within seconds.
2. The backstop fires at 300 s.
3. All three guests shut down **together** — they share one `order`, so this is
   one 90-second window rather than three.
4. The host halts.
5. The UPS cuts its output, about 20 seconds later — that is
   `ups.delay.shutdown`, not a stall.
6. Plug mains back in. The UPS restores output, the board powers on, and Proxmox
   starts all three guests together.

Watch the first three from a shell before you lose it:

```bash
journalctl -fu nut-monitor
```

And note what the UPS thought it had left, which is the number this drill exists
to produce:

```bash
upsc ups battery.runtime
```

**Two outputs.** The **measured runtime**, which goes back into step 4 if
`300 + 270 < measured` no longer holds — and proof that the lab comes back
without you. Re-run it when the battery is replaced, for the same reason
[backup-restore-drill.md](backup-restore-drill.md) is re-run yearly: a path
nobody has exercised is a hypothesis, not a capability.

### Troubleshooting Part 10

**`upsc` says "Driver not connected".** `upsd` is running and has no driver
behind it. Two quite different causes, and this tells them apart:

```bash
systemctl is-active 'nut-driver@ups'
```

**`inactive` or `failed` with no such unit** — the unit was never generated,
because `nut-driver-enumerator` has not run since `ups.conf` was written. This
is the common one, and it recurs after *every* edit to that file:

```bash
systemctl restart nut-driver-enumerator && systemctl restart nut-server
```

**`failed` with the unit present** — the driver was generated and could not talk
to the UPS. Usually USB permissions on a fresh install, or the cable:

```bash
journalctl -u 'nut-driver@ups' -n 30 --no-pager
```

`no matching HID UPS found` with the device visible in `lsusb` means the `nut`
user cannot open it — reload the udev rules the package ships and re-plug the
data cable:

```bash
udevadm control --reload-rules && udevadm trigger --subsystem-match=usb
```

To watch the driver try, in the foreground, with everything it is doing:

```bash
upsdrvctl -D start ups
```

**The five-minute push works but the instant one never arrives**, with
`PUSH_URL ... not set` and `exec_cmd(...) returned 1` in `journalctl -u
nut-monitor`. The timer path gets the variable from systemd's
`EnvironmentFile=`; the event path has no systemd in it at all, so the script
must read the file itself. Confirm both halves — that the script sources it, and
that `nut` may read it:

```bash
grep -n 'ups-health-push' /usr/local/bin/ups-health-push.sh
```

```bash
ls -l /etc/default/ups-health-push
```

Then reproduce the exact failing path, which `root` cannot do for you:

```bash
runuser -u nut -- /usr/local/bin/ups-health-push.sh
```

**The box stayed dark after an outage it survived.** Either the BIOS setting or
killpower. After a forced shutdown the flag file should exist — if it does not,
`upsmon` never reached its shutdown path; if it does, re-read the hook in
step 5:

```bash
ls -l /etc/killpower
```

**Everything is green but you do not trust it.** Ask the UPS to report on
itself; `ups.status` is the field every decision in this Part turns on:

```bash
upsc ups ups.status
```

### Layout on the server (Part 10)

| Path | Holds |
|---|---|
| `/etc/nut/nut.conf` | `MODE=standalone` |
| `/etc/nut/ups.conf` | the `[ups]` stanza and the driver |
| `/etc/nut/upsd.conf` | the loopback-only listener |
| `/etc/nut/upsd.users`, `/etc/nut/upsmon.conf` | the generated password — both mode 640 `root:nut` |
| `/etc/nut/upssched.conf` | the backstop timer and the power-event hooks |
| `/usr/local/bin/upssched-cmd` | what those hooks run |
| `/usr/local/bin/ups-health-push.sh` | the metrics + Kuma push |
| `/etc/default/ups-health-push` | the push URL — mode 640 `root:nut`, **not** 600 |
| `/etc/systemd/system/ups-health-push.{service,timer}` | the five-minute cadence |
| `/usr/lib/systemd/system-shutdown/zz-nut-killpower` | the killpower hook, beside Debian's broken one |
| `/etc/killpower` | written by `upsmon`, read by the hook above — exists only between a forced shutdown and the power cut |

---

## Why these sizes

The host is an Intel **`i5-10600K`** (Comet Lake) with **12 threads**, **96 GB
of RAM**, and **eight drives** — all internal, all flash, paired into four
mirrors. Two SATA ports are left deliberately empty.

**All 12 cores go to all three VMs.** That is 36 vCPU over 12 threads — 3:1
overcommit, on purpose, and the same ratio the old 32-thread plan used. Each VM
has a workload that spikes hard and briefly (CI compiles on infra, ESPHome
firmware builds on home-assistant, user load on apps) and they rarely spike
together, so sharing the whole machine beats carving it into three
permanently-too-small slices. The configuration that actually degrades
performance is a *single* VM defined wider than the host; 12 = 12 stays on the
right side of that line.

What arbitrates a collision is **`cpuunits`**, not core count. It is a relative
scheduler weight — clamped to `[1, 10000]`, default **100** under cgroup v2,
which Proxmox 8 and 9 use — so only the ratios matter. home-assistant outweighs
apps 4:1, which means a runaway Coolify build cannot make your lights laggy.
Nothing is capped: `cpulimit` stays `0` everywhere, so any VM can still use the
whole box when the others are idle.

**Ballooning is off** because 24 + 24 + 8 = 56 GB against 96 GB physical. The
balloon driver earns its keep when the sum of configured maxima *exceeds*
physical RAM; here it does not, so the only thing it could ever do is reclaim
memory from a VM in the middle of a compile.

What the leftover buys is **the ZFS ARC**, and then a genuine reserve. Mirrors
mean ZFS, ZFS caches in RAM, and its cache is not spare capacity — it competes
with the guests. Left alone it has historically taken half of RAM, which would be
48 GB against the 56 GB the VMs want. Capped at 16 GB in
[Part 3](#part-3--post-install-housekeeping), the arithmetic is
56 + 16 + the hypervisor ≈ 76 of 96 GB, leaving roughly **20 GB unallocated on
purpose**. That reserve is what makes a future "give X more memory" an edit and a
reboot rather than a trade against the cache or against another guest — and the
ARC cap is a floor set for the VMs' benefit, not a ceiling ZFS is straining
against, so spending part of the reserve there later is equally fair game.

Per-VM, the numbers and why:

- **infra 24 GB.** The Forgejo Actions runner *compiles*, beside six monitoring
  containers, Authentik, Vaultwarden, three Postgres instances, Traefik and
  Dockge. It is also
  the machine with the worst failure mode: an OOM kill here takes SSO and
  routing down with the thing that would have shown you why.
- **infra 150 GB.** Prometheus 15 d, Loki 14 d, Tempo 7 d, Docker image layers,
  and Forgejo's container registry, which today gains an image per CI run.
  Registry retention is owned by the CI roadmap rather than by a disk size, so
  150 GB buys comfortable time rather than absorbing growth forever.
- **apps 24 GB, and 64 + 300 GB across two pools.** This is where real user
  workloads live, which argues for more — but it is also the **least evidenced**
  allocation on the box, since the VM has run nothing measurable yet. So it
  starts level with infra rather than above it, and the reserve carries the
  difference. That is the cheap direction to be wrong in: raising a VM that
  turns out to want more is an edit and a reboot against 20 GB of unallocated
  memory, whereas handing it RAM up front pins that memory out of the host
  whether anything uses it or not, ballooning being off. It is the number to
  settle by measurement rather than argument, and the measurement is already
  wired: `node_memory_MemAvailable_bytes{instance="apps"}` lands as soon as
  this VM's node exporter does. The **root** disk carries the OS, a 4 GB
  swapfile and Coolify itself — and nothing that grows, because
  `scripts/init-coolify.sh` points Docker's data-root at `/data/docker` before
  any Engine starts, so app volumes, databases, build cache and image layers
  all land on the `data` mirror.
- **Why the apps root disk is 64 GB and not 40.** Its floor is not the OS. The
  30 GB-free check on `/` runs **twice** — once in `scripts/init-coolify.sh` so
  the failure names its cause before anything is downloaded, and again inside
  the vendor installer, that time *after* the swapfile exists. 10 GB of Ubuntu
  plus 4 GB of swap plus 30 GB free is 44 GB, so **a 40 GB root disk fails a
  check that has nothing to do with the OS fitting** — which is the trap here,
  because 40 looks like the obvious number once the layers move off. 48 GB is
  the smallest figure that passes with margin; 64 leaves room for journald, the
  apt cache and an OS that grows, on a pool that is 40% empty.
- **home-assistant 8 GB / 64 GB.** The smallest allocation on the box, and
  deliberately so even with a reserve sitting free. HAOS idles near 2 GB; its
  spike is ESPHome firmware builds and add-ons, which are CPU- and disk-bound —
  and with ballooning off, memory handed to this VM is pinned out of the host
  whether it is used or not. Its own default disk is 32 GB, and the recorder
  database plus build caches make 64 GB comfortable.

### Why the drives are split four ways

| Pool | Devices | Holds |
|---|---|---|
| `rpool` | 2 × 1 TB NVMe, mirror | Proxmox + all three VM **root** disks |
| `data` | 2 × 512 GB NVMe, mirror | the apps VM's second disk |
| `vmbackup` | 2 × 1 TB SATA SSD, mirror | `vzdump` archives — [Part 8](#part-8--schedule-whole-vm-backups) |
| `filebackup` | 2 × 1 TB SATA SSD, mirror | restic repository — [roadmap/backup.md](roadmap/backup.md) |

**Every mirror answers a different question, and the bus follows the access
pattern.** `rpool` and `data` are NVMe because they carry live VM I/O — three
root filesystems, plus the apps VM's Docker data-root and Coolify's store, which
is the most seek-heavy work in the lab and the only work anyone waits on
interactively. `vmbackup` and `filebackup` are written once a night and read
during a restore, so SATA SSD costs them nothing.

`vmbackup` holds only the **278 GB** of VM roots, because the apps VM's data
disk is excluded with `backup=0`. ~930 GB against 278 GB of source is several
compressed generations with room to spare, which is what retention needs;
include that disk and it collapses to one archive with nowhere to keep
yesterday's.

`filebackup` is the same size as the single drive it replaced, and that is worth
stating plainly rather than glossing: it gained a mirror, not runway. Forgejo's
registry blobs grow monotonically and restic cannot expire what the registry
never expires, so registry hygiene remains the only lever on that number.

278 GB of roots on ~930 GB usable leaves real headroom, and it needs to: zvols
are sparse so actual consumption is far lower, but **ZFS snapshots live in the
same pool as the disk they snapshot**. Every `clean-install` snapshot you keep is
charged to `rpool`, not to a backup mirror.

**Two SATA ports are deliberately empty.** The board fits ten drives; eight are
installed. Whatever fills those ports should be a **1 TB** pair, which is the
size that can stand in for a member of three of the four pools — a smaller pair
could only ever replace into `data`.

Treat all of it as a starting point. The reasoning above is the part meant to
survive.

> Worth knowing which metric answers which question here. `DiskAlmostFull` reads
> `node_filesystem_*`, so it counts **filesystems** — and VM disks are zvols,
> block devices, while snapshots are neither. `rpool` can therefore be nearly
> full while the hypervisor reports gigabytes free. Pool capacity is a **separate
> metric**, `zfs_pool_allocated_bytes`, written by the same timer as the health
> push in [Part 9](#part-9--notice-when-a-mirror-degrades) and alerted on as
> `ZfsPoolAlmostFull`. Snapshots still show up in neither, being charged to the
> pool and attributed to nothing — `zfs list -t snapshot` is the only view of
> those. Full account:
> [grafana-setup.md](grafana-setup.md#what-diskalmostfull-sees-under-zfs).

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
