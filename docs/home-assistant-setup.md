# Home Assistant OS (home-assistant VM)

**Runs on:** the Proxmox host shell, then the HA VM's web UI — with side trips
to the UDR (step 5) and an infra-VM shell (step 8)

**Prerequisite:** [coolify-setup.md](coolify-setup.md) complete — the apps VM is
finished, so this is the last machine in the lab.

[Home Assistant](https://www.home-assistant.io) runs here as **Home Assistant
OS** — the full appliance, Supervisor included — at
**`https://ha.thefipster.de`**. The Supervisor is the point: ESPHome, Mosquitto
and the rest install from the add-on store instead of being hand-assembled, which
is exactly what a bare Docker container install gives up.

> **This is not the ISO path from [proxmox-setup.md](proxmox-setup.md).** HAOS
> ships a **qcow2 disk image**, not an installer ISO, and **requires UEFI to
> boot**. So the VM is created empty, its disk is imported, and there is no OS
> installer to sit through. Follow the steps below rather than the Create VM
> wizard used for the two Ubuntu VMs.

## Steps

### 1. Download the image on the Proxmox host

Open the host's shell (*Datacenter → pve → Shell*). Get the latest **KVM/Proxmox**
image from the [HAOS releases](https://github.com/home-assistant/operating-system/releases)
— the file ending `.qcow2.xz`:

```bash
cd /var/lib/vz/template/iso
```

```bash
wget https://github.com/home-assistant/operating-system/releases/download/16.2/haos_ova-16.2.qcow2.xz
```

Check the release page for the current version number and substitute it in
**both** places — the URL pins the version twice so the command keeps working
verbatim after upstream's next release, rather than pointing `latest/` at an
asset name that no longer exists in it. Then decompress:

```bash
xz -d haos_ova-*.qcow2.xz
```

`xz -d` works **in place and removes the `.xz`**, leaving the bare `.qcow2`
behind — there is no second copy to tidy up afterwards.

> **If you downloaded the wrong version first, delete it now.** Both this
> command and the `qm importdisk` in [step 3](#3-import-the-haos-disk) match
> `haos_ova-*.qcow2`, so a second image in this directory makes that glob expand
> to two paths — `qm` then reads the extra one where it expects the storage
> name, and you get either a confusing failure or the wrong version imported.
> This must return exactly **one** line before you go on:
>
> ```bash
> ls -1 /var/lib/vz/template/iso/haos_ova-*.qcow2
> ```
>
> If it returns more, `rm` the ones you do not want. A stray image costs nothing
> but space on `rpool`; a stray image plus a globbing import command costs an
> afternoon.

### 2. Create an empty VM

*Create VM*, with the specs from the
[proxmox-setup.md table](proxmox-setup.md#part-5--create-the-vms) — VMID **103**,
12 cores, 8192 MB, `cpuunits` 200. The settings that differ from the Ubuntu VMs:

- **OS:** select **Do not use any media**. There is no ISO to boot.
- **System:** machine **`q35`**, BIOS **OVMF (UEFI)**, EFI storage `local-zfs`,
  and **untick Pre-Enroll keys** — HA needs a non-secureboot OVMF. Tick
  **Qemu Agent**.
- **Disks:** **delete** the default disk. The real one is imported next.
- **CPU:** type `host`, 1 socket, 12 cores.
- **Memory:** 8192 MB, **untick Ballooning Device**.
- **Network:** VirtIO, bridge `vmbr0`.

Do not start it yet.

**Then set the CPU weight — the wizard has no field for it.** The table gives
this VM `cpuunits` **200**: the 4:1 weight over the apps VM that keeps a
runaway Coolify build from making the lights laggy. Skipping this leaves the
default weight of 100, and nothing later would notice. From the host shell you
are already in:

```bash
qm set 103 --cpuunits 200
```

```bash
qm config 103 | grep cpuunits
```

### 3. Import the HAOS disk

```bash
qm importdisk 103 /var/lib/vz/template/iso/haos_ova-*.qcow2 local-zfs
```

`local-zfs` is the root pool's storage, created by the Proxmox installer when it
mirrors the two NVMe drives — see
[proxmox-setup.md Part 2](proxmox-setup.md#part-2--install-proxmox). It is *not*
`local-lvm`; that is what an `ext4` single-disk install would have produced, and
`qm importdisk` fails outright on a storage that does not exist.

**An imported disk arrives detached and unbootable, and both halves are on
you.** It lands as `unused0`, so there is no `scsi0` yet — which is what the
next step and every step after it address. Read the volume id the import
printed:

```bash
qm config 103 | grep unused
```

Expect `unused0: local-zfs:vm-103-disk-1` — `disk-1` because the EFI disk from
[step 2](#2-create-an-empty-vm) took `disk-0`. Attach it as `scsi0`, with the
same two options the GUI path ticks (substitute the volume id you just read):

```bash
qm set 103 --scsi0 local-zfs:vm-103-disk-1,discard=on,ssd=1
```

```bash
qm set 103 --boot order=scsi0
```

```bash
qm config 103 | grep -E '^(scsi0|boot)'
```

Both lines must be there before you continue. The equivalent in the web UI is
*VM 103 → Hardware → double-click `Unused Disk 0`* → bus **SCSI**, tick
**Discard** and **SSD emulation** → *Add*, then *Options → Boot Order* → enable
**`scsi0`** and move it first — but staying in the shell keeps this step in the
same place as the import and the resize around it.

### 4. Resize the disk before first boot

```bash
qm disk resize 103 scsi0 64G
```

> **`disk 'scsi0' does not exist` means the attach in step 3 did not happen.**
> The import alone leaves the volume as `unused0`; nothing in this guide works
> on it until it is attached. Go back and run the `qm set` pair above.

Do this **now**. HAOS grows its data partition when it boots, so resizing first
gets the space for free; resizing later means expanding the partition by hand
inside an appliance that does not want you in there.

### 5. Start it, then name it

Start the VM and open **Console**. First boot takes a few minutes while HAOS sets
itself up. It has no console login and nothing to configure there — you are
watching for it to settle, not logging in.

**Name it before you open it.** HAOS ships the guest agent, so Proxmox shows the
VM's address on its **Summary** tab as soon as it boots. Use that to set things up
on the **UDR** — a DHCP reservation for this VM's MAC, then the **one record the
registry deferred until now** ([dns-records.md](dns-records.md)):

- `homeassistant.thefipster.de` → **this VM** (the *machine* — what Traefik dials)

Its sibling `ha.thefipster.de` → the **infra VM** (the *service* — Traefik
answers there) went in with the rest back in
[wildcard-dns-udr.md](wildcard-dns-udr.md); verify both now:

```bash
getent hosts ha.thefipster.de homeassistant.thefipster.de
```

The two answers must **differ**: the first is the infra VM, the second this one.
If they match, one of the records is wrong. Two names for one service looks
redundant until you try to collapse them — `ha.` has to point at the proxy for TLS,
so it cannot also be the proxy's backend.

### 6. Onboard

With the records in place, open **`http://homeassistant.thefipster.de`** in a
browser and create your account through the onboarding wizard.

Plain HTTP and the machine name, deliberately: Traefik is not in the path yet, and
`ha.thefipster.de` would reach the infra VM, which has nothing to serve you until
the next step.

> **No `:8123`, and that is new.** Home Assistant **2026.8** made port **80** the
> default for fresh HAOS installations — the only kind this guide builds. Existing
> instances keep 8123, so most writing you will find online still says otherwise.
> The port is now a UI setting under *Settings → System → Network* rather than
> `http.server_port` in YAML; if you change it there, the backend URL in
> [`infra/traefik/dynamic/ha.yaml`](../infra/traefik/dynamic/ha.yaml) has to
> agree.

> **No USB passthrough is configured, deliberately.** Every guide for
> HA-on-Proxmox tells you to pass a Zigbee or Z-Wave stick through to the VM.
> This lab uses **Ethernet** Zigbee coordinators, so HA reaches them over the
> LAN like any other network device and the hypervisor is not involved. Nothing
> is missing here.

### 7. Make it reachable through Traefik

> **The Traefik half is already in the repo — there is nothing to add there, and
> nothing you will find in a compose file.** HA has no container on the infra VM
> to hang `traefik.*` labels on, so its router is declared as a **file** instead:
> [`infra/traefik/dynamic/ha.yaml`](../infra/traefik/dynamic/ha.yaml), picked up
> by the file provider Traefik has been running since
> [traefik-setup.md](traefik-setup.md#how-it-works). It has been live all along
> and simply failing to reach a backend that did not exist yet. Only the HA side
> below is left to do.

HA is now on the LAN but only over plain HTTP, and it will **refuse** anything
Traefik forwards until it is told to trust that hop — answering `400` with a log
line about an untrusted proxy, which reads like a Traefik fault and is not one.

**This is UI configuration, not YAML.** Home Assistant **2026.8** moved the HTTP
server settings out of `configuration.yaml` and into *Settings → System →
Network*; an `http:` block left in that file now raises a **repair issue**
telling you to remove it. Older guides — and older versions of this one — tell
you to paste one in. Do not.

First get the value. It is the address `ha.thefipster.de` resolves to, which is
by definition the proxy HA is being asked to trust. From any LAN host:

```bash
getent hosts ha.thefipster.de | awk '{print $1}'
```

Derive it this way rather than reading it off the router: if the infra VM ever
moves and DNS is updated, re-running the command gives the new answer with
nothing to remember. It must be the infra VM's **LAN** address and not a Docker
subnet — Traefik's container reaches this VM outbound through the bridge, SNAT'd
to its host's LAN address, so that is the source HA actually observes.

Then in HA: *Settings → System → Network*, and in the reverse-proxy section add
that address to **trusted proxies** (the field takes addresses or CIDR ranges —
never a hostname, which is why this one value cannot follow DNS like everything
else in the lab).

> **Confirm the change when HA asks.** 2026.8 applies new network settings and
> then waits for you to confirm the instance is still reachable. Miss the
> five-minute window and it assumes it broke something, silently restores the
> previous settings and restarts — so a change that appeared to save can undo
> itself while you are looking elsewhere.

Verify from any LAN machine:

```bash
curl -sI https://ha.thefipster.de | head -1
```

Expect `HTTP/2 200`, with no certificate warning — Traefik is terminating TLS
with the lab's wildcard and proxying to `homeassistant.thefipster.de` on port 80.
Open it in a browser and confirm the frontend loads and stays live (the UI is
websocket-driven, so a blank page after login means the upgrade is not getting
through).

Then append the remaining block from
[`home-assistant/configuration.yaml`](../home-assistant/configuration.yaml) —
`prometheus:`, which [step 8](#8-wire-up-metrics) needs and which the 2026.8 move
did not touch. Install the **File Editor** or **Studio Code Server** add-on
(*Settings → Add-ons*) to edit `/config/configuration.yaml`, then *Developer
Tools → YAML → Restart*.

**Append, do not replace.** A fresh HAOS install ships that file with
`default_config:`; overwriting it strips the entire default integration set.

> **There is no Authentik redirect, and that is deliberate.** HA joins neither
> SSO pattern — see
> [sso-applications.md](sso-applications.md).

### 8. Wire up metrics

The `prometheus:` key from step 7 exposes `/api/prometheus`, which needs a token.
In HA: *your profile → Security → Long-lived access tokens → Create token*. Copy
it — it is shown once.

On the **infra VM**, put it in the monitoring stack's `.env`:

```bash
nano ~/home-lab/infra/monitoring/.env
```

Set `HA_PROMETHEUS_TOKEN=` to the token, then restart the collector:

```bash
cd ~/home-lab/infra/monitoring
```

```bash
docker compose up -d alloy
```

Confirm the target is up and the `ServiceDown` alert for it clears —
[grafana-setup.md](grafana-setup.md) has the verification queries. These are
**entity** metrics (sensor states), so they appear under `job="homeassistant"`
and **not** on the Node Exporter Full dashboard.

## Next

That is every machine. The full sequence is the
[README build order](../README.md#build-order).

Worth doing from here: add the **System Monitor** integration for this VM's
CPU/RAM/disk, and add this machine's two Kuma monitors from the registry
([uptime-kuma-monitors.md](uptime-kuma-monitors.md#home-automation--home-assistant-vm)).

## Troubleshooting

**The VM will not boot — no bootable device, or it hangs on a UEFI shell.**
Firmware. HAOS requires **OVMF**, not SeaBIOS, and a **non-secureboot** OVMF
specifically: if you left *Pre-Enroll keys* ticked, delete the EFI disk and
re-add it unticked. Also confirm *Options → Boot Order* actually has `scsi0`
enabled and first — an imported disk is not bootable until you say so.

**`https://ha.thefipster.de` returns 502.** Traefik matched the route but could
not reach the backend. Three causes, in order of likelihood:

1. The VM is down or still booting.
2. The backend in `infra/traefik/dynamic/ha.yaml` names a port. Since **2026.8**
   a fresh HAOS serves **:80**, so a leftover `:8123` dials a port nothing is
   listening on. The URL should carry no port at all.
3. `homeassistant.thefipster.de` has no exact record, so it falls through the
   wildcard to the apps VM. Check it:

```bash
getent hosts homeassistant.thefipster.de
```

> **On port 80 this one no longer fails loudly, and that is a change for the
> worse.** It used to give connection-refused, because nothing on the apps VM
> listened on 8123. Now Coolify's proxy answers on :80 — so testing the bare name
> in a browser returns a real page from the wrong machine and looks like success.
> Trust the record, not the page.

4. Someone changed the backend to `http://ha.thefipster.de`. That name resolves
   to the **infra VM**, so Traefik dials its own web entrypoint, which redirects
   to HTTPS, and the request loops rather than 502-ing cleanly — another failure
   the move to :80 made worse. It must be `http://homeassistant.thefipster.de` —
   the machine, not the service.

**`https://ha.thefipster.de` returns 404.** The opposite problem: Traefik has no
router for that name. Check `ha.thefipster.de` resolves to the **infra VM** and
not to the apps VM via the wildcard:

```bash
getent hosts ha.thefipster.de
```

**HA raises a repair issue about the `http:` block in `configuration.yaml`.**
Delete that block. 2026.8 imports it into *Settings → System → Network* on first
start and then wants it gone; older guides still tell you to add one. This repo's
fragment no longer contains it.

**HA returns `400 Bad Request` and its log mentions an untrusted proxy.** Trusted
proxies is unset, or holds an address that is no longer the infra VM's — and
since 2026.8 it is set in *Settings → System → Network*, not in YAML, so an
`http:` block you added by hand will not fix it. Re-derive the value:

```bash
getent hosts ha.thefipster.de | awk '{print $1}'
```

A Docker subnet is the intuitive-but-wrong answer: Traefik's container egresses
through the bridge, SNAT'd to its host's LAN address, so that is what HA sees. A
*stale* address is the other cause — this is the one value in the lab that does
not follow DNS automatically, and since it now lives in HA's UI rather than in a
repo file, nothing here will remind you it went stale.

**The frontend loads but stays blank after login.** A websocket problem. Traefik
needs no configuration for this, so suspect a browser extension or a stale cache
before the proxy.

**`/api/prometheus` returns 401.** The token in `infra/monitoring/.env` is wrong,
absent, or was not picked up — `docker compose up -d alloy` must run after
editing `.env`, since environment variables are read at container creation.

## Layout on the server

| What | Where |
|------|-------|
| HA configuration | `/config/configuration.yaml` **inside the VM** — not in this repo |
| HTTP server settings, incl. trusted proxies | HA's UI, *Settings → System → Network* — UI-managed since 2026.8, not YAML and not here |
| Add-ons, database, secrets | inside the VM, managed by the Supervisor |
| The config fragment | `home-assistant/configuration.yaml` in this repo — `prometheus:` only, a template you paste |
| The Traefik route | `infra/traefik/dynamic/ha.yaml` on the **infra VM** |
| The scrape token | `infra/monitoring/.env` on the **infra VM** — gitignored |

Note what is *not* here: no compose file, no init script, no `/opt/home-assistant`
data directory. HAOS manages itself, so unlike every `infra/` stack the repo is
**not** this machine's source of truth. Back it up with Proxmox snapshots and
HA's own backup feature (*Settings → System → Backups*).

## How it works

**Why UEFI.** Upstream builds the OS image to boot via UEFI and says so plainly;
there is no BIOS variant to fall back on. The secureboot detail follows from the
same place — HA's own instructions say to pick an OVMF build without `secure` or
`secboot` in the name, which in Proxmox terms is the EFI disk with *Pre-Enroll
keys* off.

**Why `ha.thefipster.de` points at the infra VM, and why there is a second name.**
`ha.` points at the infra VM because that is where the lab's only certificate
lives; pointing it at this VM would reach HA over plain HTTP with nothing to
terminate TLS.
But a proxy needs an address for its backend, and it cannot be the name that
already means "the proxy" — that resolves to the infra VM and would have Traefik
dialling its own web entrypoint, looping instead of answering. So the machine
gets its own name,
`homeassistant.thefipster.de` → this VM, and the split is deliberate: **`ha.` is
the service, `homeassistant.` is the box.** The same distinction already exists
for `pve.thefipster.de` and `apps.thefipster.de`, which name machines for
internal access rather than services for browsers.

Using a name rather than the raw IP means Traefik re-resolves per dial, so an HA
VM address change corrects itself with no config edit — the same reason Alloy
addresses every scrape target by name.

**Why a file provider instead of labels.** Every other routed service is a
container on the infra VM, so Traefik reads its `traefik.*` labels off the Docker
API. HA is on another machine — there is no container to label. Traefik therefore
also runs a watched **file provider** over `infra/traefik/dynamic/`, where a
router can be declared by hand. It is the only file there, and the routing
convention is otherwise unchanged: no per-router TLS, because the entrypoint
wildcard covers file-provider routers identically. See
[traefik-setup.md](traefik-setup.md#how-it-works).

**Why no SSO.** HA has no OIDC support, so the repo's convention would put it
behind Authentik's forward-auth middleware. It is not, and this is a decision
rather than a gap. Forward-auth would break the companion mobile app, webhooks,
and every local API caller — all of which authenticate with long-lived tokens
against the same endpoints a browser uses. And the break-glass path would be
editing Traefik config over SSH, mid-incident, in a house whose lights are the
thing that stopped working. HA keeps its own local login, for the same shape of
reason that already exempts Uptime Kuma. Recorded in
[sso-applications.md](sso-applications.md).

**Why these metrics are not node metrics.** `/api/prometheus` exports Home
Assistant **entities** — sensor states, switch positions, climate setpoints —
not CPU and memory counters. So it carries `job="homeassistant"` rather than the
`job="node"` shared by the infra VM, the apps VM and the Proxmox host, and the
vendored Node Exporter Full dashboard will not show it. HAOS cannot run
Debian's node exporter as a systemd unit, so the closest equivalent is HA's own
**System Monitor** integration, whose entities then flow through this same
endpoint.

## Next

The full sequence is the [README build order](../README.md#build-order).
