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
2. **Download the Proxmox VE ISO** from <https://www.proxmox.com/downloads>.
3. **Write it to a USB stick**:
   - Linux/macOS: `dd if=proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress` (pick
     the right `/dev/sdX`!), or
   - Windows: **Rufus** in **DD/raw** mode, or **balenaEtcher**.

---

## Part 2 — Install Proxmox

Boot the server from the USB stick and pick **Install Proxmox VE (graphical)**.

1. Accept the EULA.
2. **Target disks** — select **both 500 GB NVMe drives**, then *Options* →
   Filesystem **`zfs (RAID1)`**. That mirrored pair becomes `rpool`: the
   hypervisor itself and every VM root disk. Leave `ashift` on its default (`12`,
   right for any modern drive).

   **Leave the four SATA drives untouched here.** The installer only ever builds
   the boot pool; the other two mirrors are created by hand in
   [Part 3](#part-3--post-install-housekeeping), once there is a shell to do it
   from. Selecting them now would fold all six drives into one pool and throw
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
repositories, the other two mirrors, and a cap on ZFS's memory appetite. The
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

### Build the other two mirrors

The installer left the four SATA drives alone. They become two more mirrors, and
the external USB drive becomes a third pool. Address them **by `/dev/disk/by-id/`
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

The 1 TB pair becomes `backup`, the whole-VM archive target:

```bash
zpool create -o ashift=12 -O compression=lz4 backup mirror /dev/disk/by-id/<sata-1tb-a> /dev/disk/by-id/<sata-1tb-b>
```

The 500 GB pair becomes `data`, the shared pool that carries the apps VM's second
disk:

```bash
zpool create -o ashift=12 -O compression=lz4 data mirror /dev/disk/by-id/<sata-500g-a> /dev/disk/by-id/<sata-500g-b>
```

The external USB drive becomes `usbbackup`, a single-disk pool for container
backups — see [roadmap/backup.md](roadmap/backup.md):

```bash
zpool create -o ashift=12 -O compression=lz4 usbbackup /dev/disk/by-id/<usb-nvme>
```

> **If `zpool create` refuses the disks, that is the safety interlock, not a
> failure.** ZFS declines a device carrying a recognisable filesystem
> signature, because that usually means the wrong device was named. Retail and
> shucked SSDs commonly arrive formatted exFAT, so expect it on the SATA pairs
> and the USB drive.
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
pvesm add dir backup --path /backup --content backup --is_mountpoint 1 --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=3
```

A ZFS pool registered as `zfspool` accepts content `images,rootdir` **only** — it
cannot hold `vzdump` output. So the backup mirror is registered as a *Directory*
storage on the pool's mountpoint instead. Get this backwards and the pool simply
never appears in the backup job's storage dropdown, with nothing to explain why.

`--is_mountpoint 1` is the safety catch on that arrangement: it tells Proxmox to
refuse the storage when `/backup` is *not* a mounted filesystem. Without it, a
pool that failed to import leaves an ordinary empty directory behind and every
backup writes to the **root pool** — filling the disk it was meant to protect,
while reporting success.

`usbbackup` gets **no `pvesm` entry at all**. Proxmox never writes to it; it is a
plain filesystem that a restic client reaches over SFTP, which is why it is a
pool and not a Proxmox storage.

### Cap the ZFS ARC

ZFS caches in RAM, and its cache is not free memory — it competes with the VMs.
Historically the limit defaults to **half of RAM**, which here would be 48 GB
against the 64 GB the three VMs want. Recent installers write a 10% limit for new
installations, but that is a reason to *check* the value rather than assume it.
Set it explicitly to 16 GB:

```bash
echo "options zfs zfs_arc_max=17179869184" > /etc/modprobe.d/99-zfs-arc.conf
```

```bash
update-initramfs -u -k all
```

It takes effect on the reboot below. Verify afterwards — the value should be
`17179869184`, not `0` and not half your RAM:

```bash
cat /sys/module/zfs/parameters/zfs_arc_max
```

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
| Memory | 24576 MB | 32768 MB | 8192 MB |
| Ballooning | off | off | off |
| Root disk | 150 GB on `local-zfs` | 80 GB on `local-zfs` | 64 GB on `local-zfs` |
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
  **Discard** and **SSD emulation** — every pool here is on flash.
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

The target is the `backup` mirror from [Part 3](#part-3--post-install-housekeeping)
— **1 TB, deliberately double the 500 GB root pool**, and on different physical
drives, which is the entire point. A backup on the disk it protects is not a
backup.

*Datacenter → Backup → **Add***:

| Field | Value |
|---|---|
| Storage | `backup` |
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
ls -lh /backup/dump
```

```bash
zfs list backup
```

If `/backup/dump` is empty but the task said OK, the storage is not the pool —
re-read the `--is_mountpoint` note in Part 3.

The apps VM's 300 GB data disk is **not** in these archives, by the `backup=0`
set in [Part 5](#part-5--create-the-vms). That is what keeps a 1 TB target able
to hold real retention instead of a single copy.

## Part 9 — Notice when a mirror degrades

> **Come back to this after [uptime-kuma-setup.md](uptime-kuma-setup.md).** It
> needs a push URL from Kuma, which does not exist until the infra VM is built.
> It is documented here because the script runs on the *hypervisor*, not in a VM.

Six drives in mirrors buy nothing if a failure is silent — and **a degraded
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
whatever `zpool list` happens to return, because a pool whose drive vanished does
not appear in that output at all — which is precisely the USB backup drive
falling off the bus:

```bash
cat > /usr/local/bin/zfs-health-push.sh <<'EOF'
#!/usr/bin/env bash
# Push ZFS pool health to Uptime Kuma, and write pool capacity for Prometheus.
set -uo pipefail

PUSH_URL="${PUSH_URL:?PUSH_URL is not set}"
EXPECTED="rpool backup data usbbackup"
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

## Why these sizes

The host is an Intel **`i5-10600K`** (Comet Lake) with **12 threads**, **96 GB
of RAM**, and **seven drives** — six internal, paired into three mirrors, plus
one external.

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

**Ballooning is off** because 24 + 32 + 8 = 64 GB against 96 GB physical. The
balloon driver earns its keep when the sum of configured maxima *exceeds*
physical RAM; here it does not, so the only thing it could ever do is reclaim
memory from a VM in the middle of a compile.

What the leftover buys is **the ZFS ARC**, and then a genuine reserve. Mirrors
mean ZFS, ZFS caches in RAM, and its cache is not spare capacity — it competes
with the guests. Left alone it has historically taken half of RAM, which would be
48 GB against the 64 GB the VMs want. Capped at 16 GB in
[Part 3](#part-3--post-install-housekeeping), the arithmetic is
64 + 16 + the hypervisor ≈ 84 of 96 GB, leaving roughly **12 GB unallocated on
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
- **apps 32 GB, and 80 + 300 GB across two pools.** This is where real user
  workloads live, and the largest allocation on the box for that reason — though
  it is also the least evidenced one, since the VM has run nothing measurable
  yet. It is the first line to trim back if the reserve is ever wanted
  elsewhere, and the number to decide by measurement rather than argument:
  `node_memory_MemAvailable_bytes{instance="apps"}` is already scraped. The
  **root** disk carries the OS and Coolify itself — its installer demands 30 GB
  free before it will run, so 80 GB is roomy — while app volumes, databases,
  build cache and image layers go on the `data` mirror, because that is the part
  that grows without asking.
- **home-assistant 8 GB / 64 GB.** The smallest allocation on the box, and
  deliberately so even with a reserve sitting free. HAOS idles near 2 GB; its
  spike is ESPHome firmware builds and add-ons, which are CPU- and disk-bound —
  and with ballooning off, memory handed to this VM is pinned out of the host
  whether it is used or not. Its own default disk is 32 GB, and the recorder
  database plus build caches make 64 GB comfortable.

### Why the drives are split three ways

| Pool | Devices | Holds |
|---|---|---|
| `rpool` | 2 × 500 GB NVMe, mirror | Proxmox + all three VM **root** disks |
| `backup` | 2 × 1 TB SATA, mirror | `vzdump` archives — [Part 8](#part-8--schedule-whole-vm-backups) |
| `data` | 2 × 500 GB SATA, mirror | the apps VM's second disk |
| `usbbackup` | 1 × 500 GB USB 3.1 NVMe | restic repository — [roadmap/backup.md](roadmap/backup.md) |

**Every mirror answers a different question.** `rpool` is fast flash for the
hypervisor and everything that boots from it. `backup` is deliberately **double**
`rpool`, which is what makes retention rather than a single copy possible — and
it holds only the ~294 GB of VM roots, because the apps data disk is excluded
with `backup=0`. Include that disk and the ratio collapses: ~594 GB of source
against 930 GB usable is one compressed archive with nowhere to keep yesterday's.
`data` takes the growth that would otherwise crowd the root pool, on spindles
whose failure cannot take the hypervisor with it. `usbbackup` is the only copy
that can physically leave the building.

294 GB of roots on ~460 GB usable leaves real headroom, and it needs to: zvols
are sparse so actual consumption is far lower, but **ZFS snapshots live in the
same pool as the disk they snapshot**. Every `clean-install` snapshot you keep is
charged to `rpool`, not to the backup mirror.

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
