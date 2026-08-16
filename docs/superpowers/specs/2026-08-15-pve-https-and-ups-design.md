# Design: the hypervisor serves HTTPS on 443, and survives a power cut

**Date:** 2026-08-15
**Status:** approved

Two additions to the Proxmox host, unrelated to each other except that both run
on the one machine in the lab with no checkout of this repo.

1. **`https://pve.thefipster.de`** — a genuine Let's Encrypt certificate on the
   web UI, reachable on **443** instead of `:8006` behind a warning.
2. **A UPS** — a CyberPower CP900EPFCLCD on USB, driving an orderly shutdown of
   the host and all three guests, and reporting into the lab's existing
   notification and metrics layers.

Neither one adds a compose stack or an init script. The hypervisor has no
checkout, so almost all of it lands as guide text with inline heredocs —
the same call [grafana-setup.md step 6](../../grafana-setup.md#6-add-the-proxmox-host)
and [proxmox-setup.md Part 9](../../proxmox-setup.md#part-9--notice-when-a-mirror-degrades)
already make. The one exception is the Grafana alert rule below, which is
provisioned from this repo like every other rule and so is a real file change on
the infra VM.

---

# Part A — HTTPS on the hypervisor

## `pve.thefipster.de` keeps meaning exactly one thing

The name already carries several consumers, and every one of them wants the
**machine**:

| Consumer | Uses it as |
|---|---|
| Proxmox itself | the node's FQDN, typed into the installer and written to `/etc/hosts` |
| Alloy | the scrape target `pve.thefipster.de:9100` |
| restic | the repository `sftp:resticbackup@pve.thefipster.de:/restic` |

Routing the UI through Traefik was considered and **rejected**. Traefik can only
serve a name that resolves to the infra VM, and its backend must be dialled by a
*different* name — the same service/machine split as `ha.` and `homeassistant.`
([dns-records.md](../../dns-records.md#home-assistant-has-two-names-on-purpose)).
That would make `pve.` the service name and force a new name on the machine,
moving all three rows above plus the installer's FQDN, the node name, and every
`ssh root@pve…` in every guide.

The second objection is the one that decides it even if the rename were free:
**it would make the hypervisor's management UI depend on one of the hypervisor's
own guests.** That UI is the repair surface — it is where you start a VM that
will not start, open a console, and roll back a snapshot. Putting it behind
Traefik means an infra VM that will not boot takes away the tool for finding out
why. This is the Vaultwarden argument
([sso-applications.md](../../sso-applications.md)) one level down: the thing you
repair *with* must not sit behind the thing you are repairing.

So: **no DNS change at all.** `pve.thefipster.de` stays an exact A record
pointing at the hypervisor, and it still needs to be exact for the reason it
always did — the `*.thefipster.de` wildcard would answer with the apps VM.

## The certificate

Proxmox ships an ACME client that supports the same DNS API set as `acme.sh`,
netcup included, so the host issues its own certificate with no help from the
infra VM.

**The subject is the exact name, not a wildcard**, and that is load-bearing. The
wildcard's challenge record is `_acme-challenge.thefipster.de`, which Traefik and
Coolify's proxy already contend for; netcup's zone updates are not atomic, which
is why `infra/traefik/compose.yaml` carries no apex SAN. An exact certificate
validates at `_acme-challenge.pve.thefipster.de` — a different FQDN — and races
with nobody. Same reasoning as the existing no-apex-SAN note, one level down.

Shape of the configuration:

```
pvenode acme account register default <ACME_EMAIL>
pvenode acme plugin add dns netcup --api netcup --data <credentials-file> --validation-delay 900
pvenode config set --acmedomain0 pve.thefipster.de,plugin=netcup
pvenode acme cert order
```

The credentials file holds `NC_Apikey`, `NC_Apipw` and `NC_CID`; Proxmox reads
it once and stores the values in `/etc/pve/priv/acme/plugins.cfg`, so the guide
deletes the staging file afterwards rather than leaving a second plaintext copy
on disk. The
validation delay mirrors Traefik's `NETCUP_PROPAGATION_TIMEOUT` of 900 s —
netcup publishes TXT records slowly regardless of which client asks.

**The netcup API credentials now exist on the hypervisor as well as on the infra
VM (Traefik's `.env`) and the apps VM (Coolify's proxy configuration).**
Vaultwarden remains the source of truth for them; this spec adds a consumer, not
a second master copy.

Renewal is Proxmox's own `pve-daily-update.timer`, which renews when under 30
days remain — the same policy Traefik applies to the wildcard, on a different
clock. It gets a row in [timetable.md](../../timetable.md) beside Traefik's.

## The port

An **nftables DNAT rule** rewrites `:443` to `:8006`, loaded by a small
`oneshot` systemd unit:

```
#!/usr/sbin/nft -f
table inet pve-https
delete table inet pve-https
table inet pve-https {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    tcp dport 443 redirect to :8006
  }
}
```

Four properties, each of which ruled out an alternative:

- **Its own table**, declared-then-deleted-then-created so the file is
  idempotent. It does not touch `/etc/nftables.conf`, so it coexists with
  `proxmox-firewall` rather than fighting it for ownership of the ruleset.
- **`dstnat` priority** puts it ahead of any filter chain, so a firewall
  downstream sees `dport 8006` — which Proxmox's own management rules already
  permit. Nothing new has to be opened.
- **DNAT preserves the source address**, so pveproxy still logs which client
  connected. A `systemd-socket-proxyd` or nginx front end would have had every
  connection arrive from loopback unless extra work was done to prevent it.
- **The certificate and the port are completely decoupled.** pveproxy holds the
  only copy of the certificate and reloads it itself on renewal; the rule is
  port-level and cert-agnostic. The nginx option would have needed a second copy
  of the certificate and a reload hook on Proxmox's renewal.

`:8006` stays open. This adds a door; it does not close one — which matters,
because `:8006` is the fallback if the rule is ever wrong.

**Verification must come from a LAN client, not from the host.**
Locally-generated traffic never traverses `prerouting`, so
`curl https://pve.thefipster.de` run on the hypervisor itself bypasses the rule
and fails in a way that looks like the rule is broken when it is fine. This is
the one gotcha in Part A that will otherwise cost an hour.

## No SSO, deliberately

Proxmox has a native **OpenID Connect realm**, so the SSO convention's rule —
anything with native OIDC uses it — points at joining. It does not join, and
[sso-applications.md](../../sso-applications.md) records it as a deliberate
absence beside Vaultwarden, Uptime Kuma and Home Assistant.

The reason is the one that placed the UI outside Traefik in the first place:
this is the console you would use to repair the machine Authentik runs on. An
OIDC realm is additive — `root@pam` would remain — so joining would not remove
the break-glass path, but it would add a moving part between you and a box you
only visit when something is already wrong, and it would put another entry in a
registry to keep in sync for no gain in the normal case.

This absence is a **stronger** version of Vaultwarden's, and it joins Vaultwarden
as an absence that declines OIDC it actually has. That makes Vaultwarden no longer the
single exception to "anything with native OIDC uses it"; the wording in
`CLAUDE.md` and `sso-applications.md` has to move with it.

---

# Part B — the UPS

## Shape

A CyberPower CP900EPFCLCD (900 VA / 540 W, line-interactive, PFC sinewave) on
**USB to the Proxmox host**. NUT in `standalone` mode: `usbhid-ups`, `upsd` and
`upsmon` all on that one machine, with `upsd` listening on loopback only.

The model is driven by `usbhid-ups`. One model-specific quirk is documented
upstream and is inherited here: **output voltage readings are wrong on this
unit** ([NUT #581](https://github.com/networkupstools/nut/issues/581)), reporting
in the 260–270 V range against a real 230 V. It is cosmetic, and the consequence
for this design is narrow: **no alert is built on any voltage reading.** Battery
charge, runtime, load and status are the fields this design trusts.

## The guests are shut down by Proxmox, not by NUT

**No NUT client runs in any VM**, and that is a decision rather than an omission.

`pve-guests.service` already shuts every guest down when the host halts — its
`ExecStop` calls `pvesh create /nodes/localhost/stopall`, which shuts each guest
down through the guest agent, falls back to ACPI, and forces off after the
per-VM shutdown timeout. Three facts make that sufficient here:

- `scripts/init-host.sh` already installs `qemu-guest-agent` on both Ubuntu VMs
  and HAOS ships it, so the agent path — the clean one — works for all three.
  The guest-agent investment made for consistent `vzdump` snapshots pays a
  second time here.
- The **home-assistant VM is an appliance** this repo has no shell in. A NUT
  client there would be unmanageable by construction, so a design needing one in
  every guest would have a hole in it from the start.
- One shutdown path is easier to reason about than four. A NUT client per guest
  means four independent opinions about when to shut down, racing the host's own.

Two things must be made explicit rather than left to defaults:

**Shutdown order.** Guests shut down in reverse start order, and guests with no
configured order go by VMID — which for `101 infra`, `102 apps`, `103 ha` already
gives `ha → apps → infra`. That happens to be exactly right, because **Uptime
Kuma runs on the infra VM and should be the last thing alive**. Relying on VMID
ordering for something load-bearing is fragile, so the order is set explicitly
with `qm set`, and the guide says why infra is last.

**Shutdown timeout.** Proxmox defaults to 180 s per guest, so three guests is
9 minutes worst case. That is the dominant term in the arithmetic below and is
trimmed to ~90 s, which both Ubuntu VMs clear comfortably.

## The trigger, and an honest finding about it

`upsmon` acts on the UPS's own low-battery flag, and an `upssched` timer started
on `ONBATT` and cancelled on `ONLINE` acts as a backstop:

```
AT ONBATT  * START-TIMER  onbatt-shutdown 300
AT ONLINE  * CANCEL-TIMER onbatt-shutdown
```

The timer's action is **`upsmon -c fsd`**, not a direct call to `shutdown`. That
routes through upsmon's normal forced-shutdown path, which is what sets the
killpower flag; calling `shutdown` directly would halt the host correctly and
silently skip the half of the sequence that gets it back on.

**The finding: low battery arrives too late to be the primary trigger.** At this
load the unit gives roughly 15–20 minutes, and it raises `LB` near the end of
that — on the order of 4–5 minutes remaining. Against a worst-case guest
shutdown, `LB` alone leaves no margin. So the backstop is not a fallback for a
tired battery; **it is what will fire in practice, and its value is therefore the
actual policy.** The design states this rather than presenting `LB` as the
mechanism and the timer as insurance.

The value is sized by arithmetic, not chosen:

> **backstop + worst-case guest shutdown < measured runtime**

With a 90 s per-guest timeout, three guests, and a 300 s backstop: 300 + 270 =
9.5 minutes, against a measured runtime the commissioning drill establishes. The
guide carries the formula and the measurement, not just the number — the same
treatment [timetable.md](../../timetable.md) gives Kuma's heartbeat sizing.

## Power return, and the trap in it

Chosen behaviour: **the lab comes back on its own.** Two halves, and both are
required — either one alone leaves the box dark.

1. **BIOS: "Restore on AC Power Loss" → Power On.** This joins VT-x and IOMMU as
   a firmware setting in Part 1 of the guide.
2. **NUT killpower.** `upsmon` writes `/etc/killpower` before halting; the
   shutdown hook then runs `upsdrvctl shutdown`, telling the UPS to cut its own
   output after a delay and restore it when mains returns. That interruption is
   what the BIOS setting reacts to.

Without step 2 there is a specific, quiet failure: if mains returns while the
host is still halting, the UPS never interrupts its output, nothing ever
power-cycles, and the server sits off until someone presses the button — after an
outage it appeared to handle correctly.

**A known Debian defect sits exactly here.** The shipped
`/usr/lib/systemd/system-shutdown/nutshutdown` gates the killpower call on
`upsmon -K`, which has been reported to always return false, so `upsdrvctl
shutdown` never runs
([Debian #835555](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=835555)). The
guide verifies the hook on the machine and, if it has that shape, replaces the
condition with a plain `[ -f /etc/killpower ]` test. The symptom of getting this
wrong appears only during a real outage, which is why it is checked at build time
and exercised in the drill.

## How UPS state reaches the lab

This mirrors `zfs-health-push.sh` deliberately, because it is the same problem:
a condition on a machine with no checkout, wanted in two places at once.

**`/usr/local/bin/ups-health-push.sh`** — one `upsc` read, two jobs:

- writes `ups_*` metrics into the node exporter's textfile directory, via a temp
  file and `mv -f` so the collector never reads a half-written file;
- pushes status to an Uptime Kuma push monitor.

Metrics: `ups_status_on_line`, `ups_status_on_battery`, `ups_status_low_battery`
(0/1, parsed from `ups.status`), `ups_battery_charge_percent`,
`ups_battery_runtime_seconds`, `ups_load_percent`. No voltage, per the quirk
above.

It is called from **two** places, and the second one is not a latency
optimisation:

- **A 5-minute systemd timer**, matching the ZFS timer's cadence. This is the
  metrics path and the deadman.
- **`upssched`, on `ONBATT` / `ONLINE` / `LOWBATT`.** `upssched` is already being
  configured for the backstop, so this is one more line rather than a new
  mechanism.

**Why the event path is required.** Uptime Kuma runs on the infra VM, which is a
guest of the machine that is about to shut down. The only window in which an
outage can be reported at all is between `ONBATT` and the infra VM halting — a
few minutes. A 5-minute poll would frequently miss it entirely, and the host
would go down having never said why. The event push is the alert; the timer is
the metrics and the heartbeat.

**Two consequences worth stating plainly rather than discovering:**

- **The deadman on this monitor is weak.** For ZFS, silence means the script or
  the host died while the lab was otherwise up. Here, the failure the monitor
  exists for takes Kuma down with it, so silence is expected during the very
  event being watched. It still catches a broken script on a healthy lab, which
  is worth having, but it is not the alarm.
- **The alert can only leave the house if the WAN termination is powered.**
  Notifications go to hosted ntfy.sh. The UPS carries the server, the UDR and the
  switch — but if the modem or ONT is on an unprotected socket, the push has
  nowhere to go. It belongs on a battery-backed outlet too, and the guide says so
  where the outlets are described.

Kuma notifies, Grafana graphs — the existing split
([uptime-kuma-monitors.md](../../uptime-kuma-monitors.md)). The monitor is
**`Site Power`**, Push type, heartbeat 300 s with 2 retries, fed by the same
cadence as `Hypervisor Storage` and sized by the same arithmetic.

**One Grafana rule, on battery ageing.** A UPS battery dies over three to five
years and its only symptom is a shorter runtime — nothing else in the lab would
notice, and `Site Power` stays green throughout. A rule on
`ups_battery_runtime_seconds` falling below the shutdown budget while on line
power is the one long-horizon failure this design can catch cheaply. Caveat to
verify at commissioning: if this model only reports a meaningful `battery.runtime`
while discharging, the rule degrades into a post-outage observation and the guide
says which of the two it turned out to be.

## Commissioning drill

The runtime figure cannot come from the datasheet, and a shutdown path nobody has
exercised is a hypothesis. So the guide ends by pulling the plug once,
deliberately, and watching the whole chain:

on-battery notification arrives → backstop fires → guests shut down in order
(`ha`, `apps`, `infra`) → host halts → UPS cuts output → mains restored → UPS
restores output → box boots itself → guests start.

What it produces: the **measured runtime**, which is the input to the backstop
arithmetic, and proof that killpower actually works — the half most likely to be
silently broken. Written up in the same spirit as
[backup-restore-drill.md](../../backup-restore-drill.md), and repeated when the
battery is replaced.

---

# Change surface

Almost everything is documentation. Nothing under `apps/`, `scripts/` or
`home-assistant/` changes, and no new compose stack or init script exists.

| File | Change |
|---|---|
| `infra/monitoring/grafana/provisioning/alerting/rules.yaml` | The `UpsBatteryAging` rule — the one non-documentation change, provisioned like every other rule. |
| `docs/proxmox-setup.md` | Part 1 gains the BIOS power-restore setting. Part 3 gains two subsections: the ACME certificate, and the 443 redirect. A new **Part 10** holds the whole UPS build, following Part 9's out-of-sequence precedent. |
| `docs/dns-records.md` | No new record. The `pve` row's *Serves* column gains the UI on 443 and the fact that the name is now an ACME subject. |
| `docs/sso-applications.md` | A deliberate non-row for the Proxmox web UI, and the wording change that follows from it being the exception that *has* OIDC. |
| `docs/uptime-kuma-monitors.md` | A `Power — Proxmox host` section with the `Site Power` Push monitor, and its place in the push-monitor arithmetic. |
| `docs/timetable.md` | The 5-minute UPS timer, and Proxmox's ACME renewal beside Traefik's. |
| `docs/status.md` | Rows for both additions. |
| `README.md` | The UPS in the architecture block; the certificate note under Networking & DNS. |
| `CLAUDE.md` | The SSO convention's "single exception" wording, and the hypervisor's new surface. |

**Part 10 rather than a separate `docs/ups-setup.md`.** Part 9 is the precedent
for hypervisor work that depends on the infra VM, and `CLAUDE.md` already
explains why it lives in `proxmox-setup.md` rather than in a guide of its own.
The cost is that file reaching roughly 1200 lines. Splitting it later is fine —
but as a deliberate cut along a real seam, not as a reaction to this addition.

# Non-goals

- **No Traefik router for the Proxmox UI**, and no rename of the hypervisor.
- **No port 80.** pveproxy speaks TLS only, and a listener that could issue a
  301 means a daemon on a box the repo keeps bare.
- **No OIDC realm on Proxmox.**
- **No NUT client in any VM**, and no NUT network listener.
- **No USB passthrough** of the UPS to a guest.
- **No `prometheus-nut-exporter`.** The textfile collector is already installed
  and already carries `zfs_pool_*`.
- **No generator, no second UPS, no offsite anything.** This buys an orderly
  shutdown, not continuity.

# Follow-ups this creates

- **The battery is a consumable with no expiry in any registry.** The Grafana
  rule above is the detection; a replacement interval is not scheduled anywhere,
  and `timetable.md` has no place for a three-to-five-year item.
- **The UPS's own self-test schedule is untouched**, left at the unit's default.
  Whether NUT should drive it (`ups.test.battery.start.quick`) is a separate
  question.
- **The apps VM and the HA VM gain nothing directly.** They are shut down
  cleanly, which is the point, but neither reports anything about power.
- **`Site Power`'s deadman is weak by construction**, as stated above. Closing it
  properly needs a watcher outside the lab's failure domain — the same gap
  [uptime-kuma-monitors.md](../../uptime-kuma-monitors.md) already records for
  Kuma itself.
