# apps VM — repo, host setup and the data disk

**Runs on:** apps VM

**Prerequisite:** [backup-setup.md](backup-setup.md) complete — the infra VM is
finished, so this machine has TLS, SSO, CI and monitoring to lean on.

This is the first time you open a shell on the second VM. It gets the same host
treatment as the infra VM — clock policy, guest agent, automatic security
updates — **minus Docker**, which arrives with Coolify's own installer in the
next guide. Then its second disk gets mounted, which has to happen before
Coolify exists rather than after.

Nothing here is about Coolify. Every step would be required on this machine even
if you never installed it.

## Steps

### 1. Clone the repo

Ubuntu Server 26.04's standard install already carries `git`:

```bash
git --version
```

If that fails you took the minimal install path:

```bash
sudo apt install -y git
```

```bash
cd ~ && git clone <this-repo> home-lab
```

Same `~/home-lab` path as the infra VM, for the same reason: every guide's `cd`
commands assume it.

> **This VM has a checkout at all**, unlike the Proxmox host, which is why its
> node exporter later comes from a script rather than a bare `apt install`.

### 2. Host basics — clock and guest agent

```bash
cd ~/home-lab && scripts/init-host.sh
```

Identical to the infra VM, and it matters here for the same reasons: this box
gets snapshotted too, and a rollback that leaves the clock days behind makes
every TLS client fail with `certificate has expired or is not yet valid` —
including the ACME client that is about to issue this machine's wildcard.
Full reasoning in [infra-vm-setup.md](infra-vm-setup.md#2-host-basics--clock-and-guest-agent).

```bash
timedatectl status
```

```bash
systemctl is-active qemu-guest-agent
```

### 3. Automatic security updates

Coolify's installer sets up no automatic updates, so this machine wants the same
patching policy as the infra VM:

```bash
scripts/init-unattended-upgrades.sh
```

```bash
sudo unattended-upgrade --dry-run --debug
```

Security origins only, and nothing from Docker's repo — which matters more here
than anywhere: an unattended `docker-ce` upgrade would restart the daemon
Coolify owns, bouncing every app on the box.

> **`init-docker.sh` is deliberately absent from this guide.** It is the one
> script the apps VM skips: Coolify's installer brings its own Docker Engine, so
> this VM has no Docker — and no `docker` group to join — until
> [coolify-setup.md](coolify-setup.md). The preflight there treats a missing
> Engine as normal and only version-checks one that already exists.

### 4. Mount the data disk

This VM has **two** disks: an 80 GB root on the hypervisor's NVMe mirror, and a
300 GB second disk on the `data` mirror
([proxmox-setup.md Part 5](proxmox-setup.md#part-5--create-the-vms)). Coolify
keeps everything it manages under **`/data/coolify`**, so the second disk gets
mounted at `/data` **before** the installer runs — afterwards means moving a
live data directory.

Find it. It is the one with no mountpoint and no children:

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

> **Check the size before the next command.** `mkfs` on the wrong device wipes
> the OS you just installed. The target is the empty 300 GB disk — almost
> certainly `/dev/sdb`, but confirm rather than assume.

A filesystem straight on the device, no partition table — this disk will only
ever hold one, and skipping the table makes a later resize simpler:

```bash
sudo mkfs.ext4 -L coolify-data /dev/sdb
```

Mount it by **label**, so it survives the device letter changing between boots,
and with `nofail` so a missing disk cannot leave the VM stuck at boot:

```bash
sudo mkdir -p /data
```

```bash
echo 'LABEL=coolify-data /data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
```

```bash
sudo systemctl daemon-reload && sudo mount -a
```

Verify — it must show ~300 GB, not the root disk's 80:

```bash
df -h /data
```

### Checklist

- [ ] `~/home-lab` exists and is a clone of this repo
- [ ] `timedatectl status` reports the clock synchronised
- [ ] `systemctl is-active qemu-guest-agent` → `active`, and the VM's IP shows
      on its Proxmox **Summary** page
- [ ] `unattended-upgrade --dry-run --debug` lists security origins only
- [ ] `df -h /data` shows ~300 GB — **not** 80
- [ ] `docker` is **not** installed yet, and that is correct

## Next

**[coolify-setup.md](coolify-setup.md)** — the self-hosted PaaS this machine
exists to run, and the Engine underneath it.

## Troubleshooting

**`df -h /data` shows the root disk's size.** The mount did not happen and you
are looking at the empty directory underneath it. Check the label matches what
`mkfs` wrote:

```bash
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT
```

**The VM will not boot after editing `/etc/fstab`.** This is what `nofail`
exists to prevent, so suspect a typo in the line rather than the disk. Boot into
the Proxmox console, comment the line out, and re-add it.

**`mkfs.ext4` reports the device is in use.** You named the root disk. Stop —
confirm the size in `lsblk` before running anything else.

**The clock is wrong after a snapshot rollback.** Same fix as every VM in the
lab:

```bash
sudo chronyc makestep
```

## Layout on the server

| What | Where |
|------|-------|
| The checkout | `~/home-lab` |
| The data disk | `/data` — 300 GB, `LABEL=coolify-data`, on the host's `data` mirror |
| Time-sync policy | `/etc/chrony/conf.d/90-step-any-offset.conf` |
| Unattended upgrades | `/etc/apt/apt.conf.d/20auto-upgrades` + `52homelab-…` |
| Coolify (later) | `/data/coolify/` — created by its installer |

## How it works

**Why ext4 on top of ZFS.** The hypervisor already mirrors and checksums this
disk; a second copy-on-write layer inside the guest would add write
amplification and a second ARC for redundancy that is already there. Plain ext4
in the guest is the right pairing with ZFS on the host.

**This disk is excluded from whole-VM backups** (`backup=0`), deliberately —
see [proxmox-setup.md Part 8](proxmox-setup.md#part-8--schedule-whole-vm-backups).
It is meant to be covered by the file-level backup layer instead. That layer
exists — [backup-setup.md](backup-setup.md) — but it runs on the **infra VM**,
and this machine has not joined the restic repository yet
([roadmap/backup.md](roadmap/backup.md)); joining is one more key on the
hypervisor and an `.env` value, not a redesign. Until it happens, treat
everything under `/data` as **unbacked** and deploy accordingly.

**Why this VM runs two of the three host scripts.** Neither `init-host.sh` nor
`init-unattended-upgrades.sh` touches Docker, which is the whole point of the
split — they are machine-level setup and apply to any Ubuntu guest here.
`init-docker.sh` is the only one of the three that is infra-VM-only. That split
is also what removed the manual chrony drop-in this VM used to need.

## Next

**[coolify-setup.md](coolify-setup.md)** — Coolify. The full sequence is the
[README build order](../README.md#build-order).
