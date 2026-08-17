# Home Assistant OS (home-assistant VM)

**Runs on:** the Proxmox host shell, then the HA VM's web UI — with side trips
to the router (step 5) and an infra-VM shell (step 9)

**Prerequisite:** [coolify-setup.md](coolify-setup.md) complete — the apps VM is
finished, so this is the last machine in the lab.

[Home Assistant](https://www.home-assistant.io) runs here as **Home Assistant
OS** — the full appliance, Supervisor included — at
**`https://ha.thefipster.de`**. The Supervisor is the point: ESPHome, Mosquitto
and the rest install from HA's own **Apps** store instead of being
hand-assembled, which is exactly what a bare Docker container install gives up.
That store is also where this machine gets its TLS certificate
([step 7](#7-give-it-its-own-certificate)).

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
on the **router** — a DHCP reservation for this VM's MAC, then the **one record the
registry deferred until now** ([dns-records.md](../reference/dns-records.md)):

- `ha.thefipster.de` → **this VM**

Every other record in the registry went in back at
[wildcard-dns-unifi.md](wildcard-dns-unifi.md). This one waited because it is the
only name in the lab that points at a machine which did not exist until a minute
ago. Verify it:

```bash
getent hosts ha.thefipster.de
```

It must answer with **this VM**. The failure to expect is not an error but a
wrong machine: without the exact record the name falls through the
`*.thefipster.de` wildcard to the apps VM, where Coolify's proxy answers on `:80`
and a browser test of the name returns a real page. Trust the record, not the
page.

### 6. Onboard

With the record in place, open **`http://ha.thefipster.de`** in a browser and
create your account through the onboarding wizard.

**Plain HTTP, and only until the next step.** Nothing terminates TLS for this
machine yet — this VM does it for itself, and
[step 7](#7-give-it-its-own-certificate) is where it gets the certificate and
moves to 443. Onboard first: the app you need is installed from the UI you
are about to create an account for.

> **No `:8123`, and that is new.** Home Assistant **2026.8** made port **80** the
> default for fresh HAOS installations — the only kind this guide builds. Existing
> instances keep 8123, so most writing you will find online still says otherwise.
> The port is now a UI setting under *Settings → System → Network* rather than
> `http.server_port` in YAML — which is also where the next step puts the
> certificate, beside it.

> **No USB passthrough is configured, deliberately.** Every guide for
> HA-on-Proxmox tells you to pass a Zigbee or Z-Wave stick through to the VM.
> This lab uses **Ethernet** Zigbee coordinators, so HA reaches them over the
> LAN like any other network device and the hypervisor is not involved. Nothing
> is missing here.

### 7. Give it its own certificate

**This machine terminates its own TLS.** Nothing on the infra VM proxies it —
Traefik never sees a request for `ha.thefipster.de`, and there is no router, no
backend URL and no proxy to trust. Why it is built that way is under
[How it works](#how-it-works); the short version is that the house's front door
should not go down with a reboot on another VM.

The certificate is a genuine Let's Encrypt one, issued over the same **netcup
DNS-01** challenge Traefik and Coolify use, by the official **Let's Encrypt**
app. You need the same three values from netcup's customer control panel that
[traefik-setup.md](traefik-setup.md#1-get-netcup-api-credentials) wanted —
**customer number**, **API key**, **API password** — which by now live in
[Vaultwarden](vaultwarden-setup.md).

> **This is their third copy in the lab**, after Traefik's `.env` and the compose
> Coolify's proxy is configured from. That is accepted rather than overlooked:
> each machine issues for itself and no certificate is ever copied between them,
> which is the property being paid for. Note where this copy lands — the
> Supervisor's app options, inside the VM, and therefore inside HA's own
> backups.

**Install the app.** *Settings → **Apps*** → find **Let's Encrypt** → *Install*.
Do not start it yet.

> **These are what everything else still calls add-ons.** Home Assistant renamed
> them **Apps** in the UI, and the store with them; the API did not follow. Every
> slug, service and log line still says `addon` — which is why the automation in
> [step 8](#8-keep-the-certificate-renewed) calls `hassio.addon_start` on
> `core_letsencrypt`, and why HA's own error messages mix the two words in one
> sentence. Upstream documentation you find for this app will say *add-on*
> throughout.

**Configure it.** On the app's *Configuration* tab, switch to *Edit in YAML*
and paste:

```yaml
email: <your-acme-email>
domains:
  - ha.thefipster.de
certfile: fullchain.pem
keyfile: privkey.pem
challenge: dns
dns:
  provider: dns-netcup
  propagation_seconds: 900
  netcup_customer_id: "<customer-number>"
  netcup_api_key: "<api-key>"
  netcup_api_password: "<api-password>"
```

**Ask for the exact name, never a wildcard** — the same rule the hypervisor
follows ([proxmox-setup.md, Part 3](proxmox-setup.md#give-the-host-a-real-certificate)).
Traefik requests `*.thefipster.de` and Coolify's proxy requests a wildcard of its
own, and both validate at `_acme-challenge.thefipster.de`; netcup's zone updates
are not atomic, so two clients writing one FQDN is how a challenge times out with
nothing to explain it. `ha.thefipster.de` validates at
`_acme-challenge.ha.thefipster.de` — a different record — and races with nobody.

`propagation_seconds: 900` is the same fifteen minutes Traefik allows through
`NETCUP_PROPAGATION_TIMEOUT` and Proxmox through `--validation-delay`. netcup
publishes TXT records slowly, often around ten minutes, whichever client is
asking.

**Then free port 80.** Still on the *Configuration* tab, in the **Network**
card, clear the host port beside `80/tcp` so the field is empty, and save.

> **Skip this and the app refuses to start**, with `Cannot start app
> core_letsencrypt because port 80 is already in use`. The thing using port 80
> is **Home Assistant itself** — that has been HA's default since 2026.8, and it
> is what [step 6](#6-onboard) just had you onboard through. The app publishes 80
> because that is where an **HTTP-01** challenge is answered, and it declares the
> port whether or not you use that challenge.
>
> Clearing it costs nothing and is the correct end state, not a workaround. This
> lab validates over **DNS-01**, which needs no inbound port at all; HTTP-01
> could not work here in any case, because it requires Let's Encrypt to *reach*
> the host, and these names resolve only on the LAN
> ([dns-records.md](../reference/dns-records.md)). Leave the field blank
> permanently — after HA moves to 443 below, port 80 is free again, and the
> mapping is still of no use.

**Start it and watch the log.** *Info* tab → *Start*, then the *Log* tab.

> **First issuance takes 10–15 minutes, and the log is quiet for most of it.**
> That is netcup propagation, not a hang — the same wait
> [traefik-setup.md](traefik-setup.md#4-start-the-stack-and-watch-the-first-issuance)
> describes. Do not restart the app mid-challenge. Expect it to finish with
> `Successfully received certificate`, having written `/ssl/fullchain.pem` and
> `/ssl/privkey.pem`.

> **The app then stops, and that is the end state, not a failure.** It is
> **one-shot**: it runs `certbot certonly --keep-until-expiring` and exits.
> A stopped Let's Encrypt app with a certificate on disk is a healthy one —
> [step 8](#8-keep-the-certificate-renewed) is the whole of its renewal story.

**Point HA at the files.** *Settings → System → Network*, in the same block as
the port:

| Field | Value |
|---|---|
| Server port | `443` |
| SSL certificate path | `/ssl/fullchain.pem` |
| SSL key path | `/ssl/privkey.pem` |

Leave *SSL peer certificate path* empty and *SSL profile* on **Modern** — that
is a client-certificate requirement and a Mozilla cipher profile, neither of
which this lab changes.

> **Do not touch the *Reverse proxy* section, now or later.** Nothing proxies
> this machine, so **Trust X-Forwarded-For** stays off and **Trusted proxies**
> stays empty — that absence is the whole reason the lab records no literal IP
> address anywhere
> ([dns-records.md](../reference/dns-records.md#why-this-registry-holds-no-addresses)).
> The two fields are an **inclusive pair** in HA's schema: set one without the
> other and the form refuses to save the *whole* page, port and certificate
> included. See [Troubleshooting](#troubleshooting).

> **This is UI configuration, not YAML — and the app's own documentation will
> tell you otherwise.** It still describes referencing the two files from an
> `http:` block, which Home Assistant **2026.8** retired: HTTP server settings
> moved into *Settings → System → Network*, and a leftover `http:` block now
> raises a **repair issue** telling you to delete it. Set the three fields above
> and add nothing to `configuration.yaml`.

> **Confirm the change when HA asks.** 2026.8 applies new network settings and
> then waits for you to confirm the instance is still reachable — at its new
> address, `https://ha.thefipster.de`. Miss the five-minute window and it assumes
> it broke something, silently restores the previous settings and restarts, so a
> change that appeared to save can undo itself while you are looking elsewhere.

Verify from any LAN machine:

```bash
curl -sI https://ha.thefipster.de | head -1
```

Expect `HTTP/2 200` with no certificate warning. Then check *whose* certificate
it is:

```bash
echo | openssl s_client -connect ha.thefipster.de:443 -servername ha.thefipster.de 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Subject must be **`CN = ha.thefipster.de`** and the issuer must name Let's
Encrypt. Note what it is *not*: `*.thefipster.de`. That wildcard belongs to
Traefik on the infra VM and to Coolify's proxy on the apps VM, and seeing it here
means the name resolved to one of those machines rather than to this one.

Open it in a browser and confirm the frontend loads and stays live — the UI is
websocket-driven, so a blank page after login means the upgrade is not getting
through.

> **There is no Authentik redirect, and that is deliberate.** HA joins neither
> SSO pattern — see
> [sso-applications.md](../reference/sso-applications.md).

### 8. Keep the certificate renewed

**The app renews nothing on its own.** `certbot certonly
--keep-until-expiring` asks for a certificate and exits: inside the renewal
window — the last 30 days of a 90-day certificate — it fetches a new one; outside
it, it does nothing at all, makes no ACME request and calls netcup not once. So
the entire renewal mechanism is *starting the app again*, on a schedule.

That schedule is an automation of HA's own. *Settings → Automations & scenes →
Create automation → ⋮ → Edit in YAML*:

```yaml
alias: TLS certificate renewal
description: >-
  Weekly: run the one-shot Let's Encrypt app, then restart so that a renewed
  certificate is the one actually being served.
triggers:
  - trigger: time
    at: "04:45:00"
conditions:
  - condition: time
    weekday:
      - sun
actions:
  - action: hassio.addon_start
    data:
      addon: core_letsencrypt
  - delay: "00:20:00"
  - action: homeassistant.restart
mode: single
```

Four things in there are deliberate:

**Weekly, not monthly.** The renewal window is 30 days wide, so a monthly run
gets roughly one attempt inside it and a single bad night — netcup slow, the API
down, this VM off — costs the whole window. Weekly gets four attempts and needs
no alarm of its own to survive one failure.

**The restart is unconditional.** HA reads the certificate when it starts its
HTTP server, so a file replaced underneath it is not necessarily the file being
served. A 90-day certificate renewed at 30 days left means roughly six of the
year's fifty-two runs actually change a file, and restarting after all of them
costs about thirty seconds a week. That is the cheapest way to make this correct
rather than probably-correct — cheaper than detecting which runs mattered.

**The delay covers propagation.** `propagation_seconds: 900` means a real
renewal can take a quarter of an hour, and restarting HA in the middle of one
would leave the old file in place until the following Sunday. Twenty minutes
puts the restart after certbot has either written a new file or decided not to.

**04:45 keeps it clear of the lab's night window**, which is spoken for from
01:00 to 04:30 on the other machines
([timetable.md](../reference/timetable.md#the-night-window)).

Save it, then **run it once now** — *⋮ → Run actions* on the new automation.
This is worth the twenty minutes: the failure it catches is a wrong app slug
or a service call HA rejects, which is otherwise silent for two months and
surfaces as an expired certificate. Watch the app's *Log* tab gain a second
run — it will report the existing certificate as not due for renewal — and HA
restart twenty minutes later.

> **The alarm for silent expiry is Kuma's, not this machine's.** Every HTTPS
> monitor tracks certificate expiry, so switching on *Certificate Expiry
> Notification* for the `Home Automation` monitor gives this automation a
> watcher that does not run on the machine it is watching
> ([uptime-kuma-monitors.md](../reference/uptime-kuma-monitors.md#home-automation--home-assistant-vm)).
> Alloy's scrape below is the second, slower read on the same thing: it dials
> `:443` and would start failing outright once a certificate expired.

The automation gets a row in [timetable.md](../reference/timetable.md) like
everything else in the lab that runs on a clock.

### 9. Wire up metrics

First give HA the metrics endpoint. Append the block from
[`home-assistant/configuration.yaml`](../../home-assistant/configuration.yaml) —
`prometheus:`, the one HA setting in this lab that is still YAML — to
`/config/configuration.yaml`. Install the **File Editor** or **Studio Code
Server** app (*Settings → Apps*) to edit it, then *Developer Tools → YAML →
Restart*.

**Append, do not replace.** A fresh HAOS install ships that file with
`default_config:`; overwriting it strips the entire default integration set.

That key exposes `/api/prometheus`, which needs a token. In HA: *your profile →
Security → Long-lived access tokens → Create token*. Copy it — it is shown once.

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

### 10. Add the host's own metrics

Step 9 got Home Assistant's **entities** into Prometheus. This VM's CPU, RAM and
disk are not among them — `/api/prometheus` exports entity states, and nothing
on this appliance produces machine counters on its own. HAOS cannot run Debian's
node exporter as a systemd unit the way the apps VM and the hypervisor do, so
the equivalent is an integration that turns host readings into entities, which
then flow out through the endpoint you just wired.

In HA: *Settings → Devices & Services → Add Integration → **System Monitor***.
It has no configuration to fill in.

By default it creates only a few sensors. Add the ones worth graphing from
*Settings → Devices & Services → Entities*, filtering on `System Monitor` and
enabling the disabled ones — processor use, memory use, disk use, and load
average are the set that matches what Node Exporter Full shows for the other
three machines.

Confirm they reached Prometheus. In Grafana's **Explore → Prometheus**:

```promql
{job="homeassistant", __name__=~"homeassistant_sensor.*"}
```

Expect the new sensors among the results within a scrape interval — 60 seconds
here, not the 15 the other targets use.

> **These will not appear on the Node Exporter Full dashboard, and that is not a
> fault.** They carry `job="homeassistant"` and are entity metrics with entity
> names; that dashboard is built on `job="node"` and the node exporter's metric
> names. This VM is visible in monitoring, just not on that panel set. Building
> a dashboard for these is separate work and deliberately not part of this
> guide.

## Next

That is every machine. The full sequence is the
[README build order](../../README.md#build-order).

Worth doing from here: add this machine's two Kuma monitors from the registry
([uptime-kuma-monitors.md](../reference/uptime-kuma-monitors.md#home-automation--home-assistant-vm)),
and switch on *Certificate Expiry Notification* on the HTTP one while you are
there — that is the alarm for a renewal automation that quietly stopped running,
and it is the only watcher of it that does not live on this machine.

## Troubleshooting

**The VM will not boot — no bootable device, or it hangs on a UEFI shell.**
Firmware. HAOS requires **OVMF**, not SeaBIOS, and a **non-secureboot** OVMF
specifically: if you left *Pre-Enroll keys* ticked, delete the EFI disk and
re-add it unticked. Also confirm *Options → Boot Order* actually has `scsi0`
enabled and first — an imported disk is not bootable until you say so.

**`Cannot start app core_letsencrypt because port 80 is already in use`.** Home
Assistant is what is using it: port 80 is HA's own default since 2026.8, and the
Let's Encrypt app declares 80 for the **HTTP-01** challenge whether or not you
use it. Clear the host port beside `80/tcp` in the app's *Configuration →
Network* card and start it again. Nothing is given up — this lab validates over
DNS-01, which needs no inbound port, and HTTP-01 could never have worked against
a name that resolves only on the LAN.

> **Do not free the port by moving Home Assistant instead.** Sending HA to some
> other port to get the app started leaves you onboarding through one address and
> verifying through another, and 2026.8's reachability confirmation makes each of
> those moves its own five-minute trap. The port mapping is the thing that is
> unnecessary here, so remove that.

**The app log ends in a propagation timeout, or says the expected TXT record
was not returned.** netcup was slower than the fifteen minutes
`propagation_seconds` allows, or the three credentials are wrong. Confirm the
domain is still on netcup's nameservers, from any LAN host:

```bash
dig NS thefipster.de +short
```

Then re-check `netcup_customer_id`, `netcup_api_key` and `netcup_api_password` on
the *Configuration* tab. Regenerate the API password in netcup's CCP if unsure —
it is shown only once. Do not hammer the production CA while debugging: it allows
roughly five failed validations per hostname per hour.

**`some but not all values in the same group of inclusion 'proxy'`, saving the
Network form.** The two *Reverse proxy* fields — **Trust X-Forwarded-For** and
**Trusted proxies** — are an inclusive pair: HA's schema takes both or neither,
and the form can submit one of them alone. Nothing on that page saved, the port
and the certificate paths included, so this looks like a TLS problem and is not
one.

On a fresh build there is nothing to set there and this never fires, which is why
the step above says to leave the section alone.

**Once populated, it cannot be emptied from this form.** The toggle always
submits a value and an emptied list submits none, so "clear both" produces
precisely the state the schema rejects — there is no sequence of edits that
reaches *neither*. Complete the pair with a value that can never match instead:

| Field | Value |
|---|---|
| Trust X-Forwarded-For | on |
| Trusted proxies | `192.0.2.1/32` |

That is **RFC 5737 TEST-NET-1**, reserved for documentation and routed nowhere,
so it is guaranteed never to be the peer HA sees. The group is syntactically
complete and semantically empty, and the field stops holding an address that
means anything.

> **Do not leave a real machine's address there instead.** It is inert only for
> as long as nothing else answers to it — `use_x_forwarded_for` says "trust
> `X-Forwarded-For` from this address", so whatever ends up on that address later
> is authorised to forge client IPs. A stale address that still looks
> authoritative is the exact failure this lab addresses everything by name to
> avoid
> ([dns-records.md](../reference/dns-records.md#why-this-registry-holds-no-addresses)).
> The only route to a genuinely empty pair is editing HA's own storage, which is
> appliance internals and not worth it for a field that a reserved address
> already neutralises.

**`https://ha.thefipster.de` does not answer at all.** HA is not listening on
443. Either the Network settings did not stick — the five-minute confirmation
window above — or HA could not read the certificate and fell back. Open the VM's
**Console** in Proxmox and look at the startup log; a missing or unreadable
`/ssl/fullchain.pem` is the likely cause, which means the app run in
[step 7](#7-give-it-its-own-certificate) did not finish.

**`http://ha.thefipster.de` stopped working, and that is expected.** HA serves
**one** port. Moving it to 443 in step 7 vacated 80, and nothing redirects
between them — there is no reverse proxy here to do it. Use the `https://` URL.

**The certificate is `*.thefipster.de` rather than `CN = ha.thefipster.de`.**
Then you are not talking to this machine. The name has no exact record and fell
through the `*.thefipster.de` wildcard to the apps VM, whose Coolify proxy
answers with its own wildcard certificate — a valid one, which is what makes it
convincing:

```bash
getent hosts ha.thefipster.de
```

**The certificate expired and nothing renewed it.** The app renews only when
something starts it. Check the automation from
[step 8](#8-keep-the-certificate-renewed) still exists and is enabled, and that
its last triggered time is within a week — *Settings → Automations & scenes*. A
disabled automation is silent for two months before it costs anything, which is
why the Kuma expiry notification is part of that step rather than an optional
extra.

**HA raises a repair issue about the `http:` block in `configuration.yaml`.**
Delete that block. 2026.8 imports it into *Settings → System → Network* on first
start and then wants it gone; the Let's Encrypt app's own documentation still
tells you to add one. This repo's fragment does not contain it.

**The frontend loads but stays blank after login.** A websocket problem. Nothing
sits between the browser and HA, so suspect a browser extension or a stale cache
rather than the network.

**`/api/prometheus` returns 401.** The token in `infra/monitoring/.env` is wrong,
absent, or was not picked up — `docker compose up -d alloy` must run after
editing `.env`, since environment variables are read at container creation.

## Layout on the server

| What | Where |
|------|-------|
| HA configuration | `/config/configuration.yaml` **inside the VM** — not in this repo |
| HTTP server settings: port, SSL certificate, SSL key | HA's UI, *Settings → System → Network* — UI-managed since 2026.8, not YAML and not here |
| The certificate and its key | `/ssl/fullchain.pem` and `/ssl/privkey.pem` **inside the VM**, written by the app |
| The netcup API credentials | the Let's Encrypt app's options **inside the VM** — the lab's third copy, after Traefik's `.env` and Coolify's proxy config |
| The renewal schedule | an automation in HA's own database **inside the VM** — [timetable.md](../reference/timetable.md) is the registry |
| Apps, database, secrets | inside the VM, managed by the Supervisor |
| The config fragment | `home-assistant/configuration.yaml` in this repo — `prometheus:` only, a template you paste |
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

**Why this machine holds its own certificate.** The obvious alternative is to
route `ha.thefipster.de` through Traefik on the infra VM like every other UI in
the lab, reusing the wildcard and adding no ACME client here. It is rejected for
what it costs: the front door of the *house* would then die with a VM on another
machine. A reboot, a bad Traefik change or a failed disk over there takes the HA
UI and the companion app down while Home Assistant itself is running perfectly,
and the repair happens over SSH. That is the same trade the
hypervisor's web UI already refuses
([proxmox-setup.md, Part 3](proxmox-setup.md#give-the-host-a-real-certificate)):
the surface you repair things from should not sit behind something else that can
break.

The price is a second ACME client in the lab and a third copy of the netcup
credentials. What it buys, beyond the independence, is that a whole class of
coupling disappears — there is no backend URL to keep in step with HA's port, no
`trusted_proxies` value that has to be a literal address rather than a name, and
`ha.thefipster.de` means exactly one thing: **the machine**. The same shape as
`pve.thefipster.de` and `apps.thefipster.de`, which also name boxes rather than
services.

**Why an exact certificate rather than the lab wildcard.** Two ACME clients
already ask for `*.thefipster.de` — Traefik and Coolify's proxy — and both
validate at `_acme-challenge.thefipster.de`. netcup's zone updates are not
atomic, so a third writer at that same FQDN is a challenge that times out with
nothing in any log to explain it. An exact name validates at its own record and
cannot collide. It also means nothing has to hand a private key between
machines, which is what "each machine issues for itself" is really worth.

**Why Traefik has no file provider.** Every service Traefik serves is a container
on the infra VM, so its routers arrive as `traefik.*` labels over the Docker API.
Home Assistant is the only lab UI that could never work that way — no container
there, nothing to label — and it is the one thing that would have needed a
hand-written router in a file. It is not routed through Traefik at all, so labels
are the only provider and `infra/traefik/compose.yaml` declares nothing else. See
[traefik-setup.md](traefik-setup.md#how-it-works).

**Why no SSO.** HA has no OIDC support, so the repo's convention would put it
behind Authentik's forward-auth middleware. That is now doubly not the case:
forward-auth is a Traefik middleware, and Traefik does not serve this machine, so
there is no router to attach one to — the same structural absence the Proxmox web
UI has. Even where it was possible it was refused, and that reasoning still says
why nobody should reintroduce a proxy in order to gate it: forward-auth breaks
the companion mobile app, webhooks, and every local API caller, all of which
authenticate with long-lived tokens against the same endpoints a browser uses.
HA keeps its own local login. Recorded in
[sso-applications.md](../reference/sso-applications.md).

**Why these metrics are not node metrics.** `/api/prometheus` exports Home
Assistant **entities** — sensor states, switch positions, climate setpoints —
not CPU and memory counters. So it carries `job="homeassistant"` rather than the
`job="node"` shared by the infra VM, the apps VM and the Proxmox host, and the
vendored Node Exporter Full dashboard will not show it. HAOS cannot run
Debian's node exporter as a systemd unit, so the closest equivalent is HA's own
**System Monitor** integration, whose entities then flow through this same
endpoint.

## Next

The full sequence is the [README build order](../../README.md#build-order).
