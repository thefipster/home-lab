# Home Assistant OS (home-assistant VM)

**Runs on:** the Proxmox host shell, then the HA VM's web UI

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
wget https://github.com/home-assistant/operating-system/releases/latest/download/haos_ova-16.2.qcow2.xz
```

Check the release page for the current version number and substitute it. Then
decompress:

```bash
xz -d haos_ova-*.qcow2.xz
```

### 2. Create an empty VM

*Create VM*, with the specs from the
[proxmox-setup.md table](proxmox-setup.md#part-5--create-the-vms) — VMID **103**,
32 cores, 8192 MB, `cpuunits` 200. The settings that differ from the Ubuntu VMs:

- **OS:** select **Do not use any media**. There is no ISO to boot.
- **System:** machine **`q35`**, BIOS **OVMF (UEFI)**, EFI storage `local-lvm`,
  and **untick Pre-Enroll keys** — HA needs a non-secureboot OVMF. Tick
  **Qemu Agent**.
- **Disks:** **delete** the default disk. The real one is imported next.
- **CPU:** type `host`, 1 socket, 32 cores.
- **Memory:** 8192 MB, **untick Ballooning Device**.
- **Network:** VirtIO, bridge `vmbr0`.

Do not start it yet.

### 3. Import the HAOS disk

```bash
qm importdisk 103 /var/lib/vz/template/iso/haos_ova-*.qcow2 local-lvm
```

It appears as an **unused disk** on the VM. Attach it: *VM 103 → Hardware →
double-click `Unused Disk 0`* → bus **SCSI**, tick **Discard** on an SSD → *Add*.
Then *Options → Boot Order* → enable **`scsi0`** and move it first.

### 4. Resize the disk before first boot

```bash
qm disk resize 103 scsi0 64G
```

Do this **now**. HAOS grows its data partition when it boots, so resizing first
gets the space for free; resizing later means expanding the partition by hand
inside an appliance that does not want you in there.

### 5. Start it, then name it

Start the VM and open **Console**. First boot takes a few minutes while HAOS sets
itself up. It has no console login and nothing to configure there — you are
watching for it to settle, not logging in.

**Name it before you open it.** HAOS ships the guest agent, so Proxmox shows the
VM's address on its **Summary** tab as soon as it boots. Use that to set things up
on the **UDR** — a DHCP reservation for this VM's MAC, then the **two** records
this machine needs ([dns-records.md](dns-records.md) is the registry):

- `ha.thefipster.de` → the **infra VM** (the *service* — Traefik answers here)
- `homeassistant.thefipster.de` → **this VM** (the *machine* — what Traefik dials)

```bash
getent hosts ha.thefipster.de homeassistant.thefipster.de
```

The two answers must **differ**: the first is the infra VM, the second this one.
If they match, one of the records is wrong. Two names for one service looks
redundant until you try to collapse them — `ha.` has to point at the proxy for TLS,
so it cannot also be the proxy's backend.

### 6. Onboard

With the records in place, open **`http://homeassistant.thefipster.de:8123`** in
a browser and create your account through the onboarding wizard.

Plain HTTP and the machine name, deliberately: Traefik is not in the path yet, and
`ha.thefipster.de` would reach the infra VM, which has nothing to serve you until
the next step.

> **No USB passthrough is configured, deliberately.** Every guide for
> HA-on-Proxmox tells you to pass a Zigbee or Z-Wave stick through to the VM.
> This lab uses **Ethernet** Zigbee coordinators, so HA reaches them over the
> LAN like any other network device and the hypervisor is not involved. Nothing
> is missing here.

### 7. Make it reachable through Traefik

HA is now on the LAN but only over plain HTTP. Append the two blocks from
[`home-assistant/configuration.yaml`](../home-assistant/configuration.yaml) to
`/config/configuration.yaml` inside HA — install the **File Editor** or **Studio
Code Server** add-on (*Settings → Add-ons*) to edit it.

**Append, do not replace.** A fresh HAOS install ships that file with
`default_config:`; overwriting it strips the entire default integration set. The
fragment contains only keys HAOS does not already define, so appending is safe.

**One value must be filled in: `trusted_proxies`.** The fragment ships the
placeholder `<infra-vm-ip>`, because this is the only place in the lab that needs
a literal address — Home Assistant accepts addresses or CIDR ranges there, never a
hostname — and the repo deliberately records no addresses
([dns-records.md](dns-records.md#why-this-registry-holds-no-addresses)).

The value you need is the address `ha.thefipster.de` resolves to, which is by
definition the proxy HA is being asked to trust. From any LAN host:

```bash
getent hosts ha.thefipster.de | awk '{print $1}'
```

Substitute that for `<infra-vm-ip>`. Derive it this way rather than reading it off
the router: if the infra VM ever moves and DNS is updated, re-running the command
gives the new answer with nothing to remember.

Then *Developer Tools → YAML → Restart*, and verify from any LAN machine:

```bash
curl -sI https://ha.thefipster.de | head -1
```

Expect `HTTP/2 200`, with no certificate warning — Traefik is terminating TLS
with the lab's wildcard and proxying to `homeassistant.thefipster.de:8123`. Open it in a browser
and confirm the frontend loads and stays live (the UI is websocket-driven, so a
blank page after login means the upgrade is not getting through).

> **There is no Authentik redirect, and that is deliberate.** HA is the second
> service in the lab that joins neither SSO pattern — see
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
cd ~/home-lab/infra/monitoring && docker compose up -d alloy
```

Confirm the target is up and the `ServiceDown` alert for it clears —
[grafana-setup.md](grafana-setup.md) has the verification queries. These are
**entity** metrics (sensor states), so they appear under `job="homeassistant"`
and **not** on the Node Exporter Full dashboard.

## Next

That is every machine. The full sequence is the
[README build order](../README.md#build-order).

Worth doing from here: add the **System Monitor** integration for this VM's
CPU/RAM/disk, and point Uptime Kuma at `ha.thefipster.de`
([uptime-kuma-setup.md](uptime-kuma-setup.md)).

## Troubleshooting

**The VM will not boot — no bootable device, or it hangs on a UEFI shell.**
Firmware. HAOS requires **OVMF**, not SeaBIOS, and a **non-secureboot** OVMF
specifically: if you left *Pre-Enroll keys* ticked, delete the EFI disk and
re-add it unticked. Also confirm *Options → Boot Order* actually has `scsi0`
enabled and first — an imported disk is not bootable until you say so.

**`https://ha.thefipster.de` returns 502.** Traefik matched the route but could
not reach the backend. Three causes, in order of likelihood:

1. The VM is down or still booting.
2. `homeassistant.thefipster.de` has no exact record, so it falls through the
   wildcard to the apps VM, where nothing listens on `:8123`. Check it:

```bash
getent hosts homeassistant.thefipster.de
```

3. Someone changed the backend in `infra/traefik/dynamic/ha.yaml` to
   `http://ha.thefipster.de:8123`. That name resolves to the **infra VM**, so
   Traefik dials its own `:8123` and finds nothing. It must be
   `http://homeassistant.thefipster.de:8123` — the machine, not the service.

**`https://ha.thefipster.de` returns 404.** The opposite problem: Traefik has no
router for that name. Check `ha.thefipster.de` resolves to the **infra VM** and
not to the apps VM via the wildcard:

```bash
getent hosts ha.thefipster.de
```

**HA will not start, and the log says the `http` config is invalid.** The
`<infra-vm-ip>` placeholder is still in `trusted_proxies` — HA validates that
field as an address and rejects the string. This is the intended failure: loud at
startup rather than a puzzling 400 later. Fill it in per step 7.

**HA returns `400 Bad Request` and its log mentions an untrusted proxy.** The
`http:` block from step 7 is missing, or `trusted_proxies` holds an address that
is no longer the infra VM's. Re-derive it:

```bash
getent hosts ha.thefipster.de | awk '{print $1}'
```

A Docker subnet is the intuitive-but-wrong answer: Traefik's container egresses
through the bridge, SNAT'd to its host's LAN address, so that is what HA sees. A
*stale* address is the other cause — this is the one value in the lab that does
not follow DNS automatically, which is exactly why it is the only literal address
anywhere in the repo.

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
| Add-ons, database, secrets | inside the VM, managed by the Supervisor |
| The config fragment | `home-assistant/configuration.yaml` in this repo — a template you paste |
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
dialling its own `:8123`. So the machine gets its own name,
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
