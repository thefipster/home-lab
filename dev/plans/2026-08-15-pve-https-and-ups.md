# Proxmox HTTPS + UPS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the Proxmox web UI at `https://pve.thefipster.de` on port 443 with a genuine certificate, and make the lab survive a power cut with an orderly shutdown that reports itself and comes back on its own.

**Architecture:** Both additions run on the Proxmox host, which has no checkout of this repo — so they land as guide text with inline heredocs in `docs/proxmox-setup.md`, exactly as Part 9 and `grafana-setup.md` step 6 already do. The certificate comes from Proxmox's own ACME client (netcup DNS-01, exact name) and the port from an nftables DNAT rule; the UPS runs NUT in standalone mode with no client in any guest. One real file change on the infra VM: a provisioned Grafana alert rule.

**Tech Stack:** Proxmox VE (`pvenode acme`, `qm set --startup`), nftables, NUT (`usbhid-ups`, `upsd`, `upsmon`, `upssched`), systemd oneshot units and timers, Prometheus textfile collector, Uptime Kuma push monitors, Grafana provisioned alerting.

**Spec:** [docs/superpowers/specs/2026-08-15-pve-https-and-ups-design.md](../specs/2026-08-15-pve-https-and-ups-design.md)

## Global Constraints

These come from `CLAUDE.md` and the spec. Every task's requirements implicitly include them.

- **No literal IP address anywhere.** Machines are addressed by name. `dns-records.md` is the source of truth for names; the router is the source of truth for addresses. A literal address is a flag that something could not be expressed as a name.
- **From-scratch bring-up only.** No migration paths, no upgrade procedures, no "if you already have X". A `git pull` anywhere but the initial clone is a bug.
- **Guide structure, in this order:** headline; `**Runs on:** <machine>`; one-line prerequisite linking the previous guide; short explanation; numbered steps with verification, **each command in its own fenced block**; jump-off to the next guide; troubleshooting; layout on the server; detailed explanation / design notes; jump-off repeated. Doing-path first and short, all rationale below the fold.
- **Registries hold per-service values; guides link them.** Never repeat a per-service value inline in a guide.
- **Registries list their deliberate absences** beside their entries.
- **Durable wording over ordinals.** Do not write "the third push monitor" or "the four exceptions" — name the things instead, so a later addition does not silently make the sentence false. Several existing sentences violate this once this plan lands and are corrected by name below.
- **Line endings are LF**, forced repo-wide by `.gitattributes`.
- **Exact name for the certificate**, never a wildcard: `pve.thefipster.de`, validating at `_acme-challenge.pve.thefipster.de`.
- **Backstop arithmetic:** `backstop + worst-case guest shutdown < measured runtime`. Plan values: backstop `300` s, per-guest shutdown timeout `down=90`, three guests → 570 s worst case.
- **NUT UPS name is `ups`**, not the model number — it survives a hardware swap, same reasoning as Kuma's function-not-product naming.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `docs/proxmox-setup.md` | Part 1 gains the BIOS power-restore setting; Part 3 gains two subsections (certificate, 443 redirect); a new Part 10 holds the entire UPS build | 1, 2, 3 |
| `docs/dns-records.md` | The `pve` row's meaning; a note that the name is now an ACME subject. **No new record.** | 1 |
| `docs/sso-applications.md` | The Proxmox web UI as a deliberate non-joiner, plus the knock-on wording it forces | 1 |
| `docs/timetable.md` | Proxmox's ACME renewal; the 5-minute UPS timer; the push-monitor heartbeat table | 1, 3 |
| `docs/uptime-kuma-monitors.md` | The `Site Power` push monitor and its section | 3 |
| `infra/monitoring/grafana/provisioning/alerting/rules.yaml` | The `UpsBatteryAging` rule | 3 |
| `docs/status.md` | One row per addition | 4 |
| `README.md` | The architecture block and the TLS sentence | 4 |
| `CLAUDE.md` | The SSO convention's exception wording; the hypervisor's new surface | 1, 4 |

**Nothing is created under `scripts/`, `infra/<stack>/`, `apps/` or `home-assistant/`.** The scripts in this plan live inside heredocs in the guide because the hypervisor has no checkout to run them from — the same reasoning `grafana-setup.md` gives for the node exporter having no init script.

**Do not add an outpost router to `infra/authentik/compose.yaml`.** Its comment naming the hosts that deliberately have none is about hosts Traefik routes. The Proxmox UI is not routed by Traefik at all, so it does not belong in that list and that comment stays correct as written.

---

## Task 0: Set up the link checker

**Files:**
- Create: `<scratchpad>/check-links.py` (throwaway — **not** committed)

**Interfaces:**
- Produces: a pass/fail gate every later task runs. **The baseline on this branch is clean** — this exact script was run against the repo before the plan was written and printed `OK`. So later tasks require zero failures, not "no new ones".

`$SCRATCHPAD` below means this session's scratchpad directory, named in your
system prompt. Substitute the real path — it is deliberately outside the repo so
the checker is never committed.

- [ ] **Step 1: Write the checker**

Write to your scratchpad directory (not the repo). Two details in it are not
incidental and must not be "simplified":

- `re.sub(r'\s', '-', t)` has **no `+`**. GitHub replaces each space with its own
  hyphen, so `## Part 3 — Post-install housekeeping` becomes
  `part-3--post-install-housekeeping` with a *double* hyphen once the em dash is
  stripped. Collapsing whitespace produces a single hyphen and reports every
  such anchor in this repo as broken.
- Dated specs, plans and reviews are skipped **as sources** because `CLAUDE.md`
  makes them historical records that are never retro-edited; their stale links
  are not failures. They remain valid link *targets*.

```python
import re, sys, pathlib

# Historical records: dated specs, plans and reviews are never retro-edited
# (CLAUDE.md), so their stale links are not failures. They are still valid
# link TARGETS - only skipped as sources.
SKIP = ('.git', '.superpowers', 'superpowers', 'review')

root = pathlib.Path('.')
all_docs = [p for p in root.rglob('*.md') if '.git' not in p.parts]
sources = [p for p in all_docs if not any(s in p.parts for s in SKIP)]

def slug(t):
    t = t.strip().lower()
    t = re.sub(r'[`*_\[\]()]', '', t)
    t = re.sub(r'[^\w\s-]', '', t)
    return re.sub(r'\s', '-', t)   # each space -> one hyphen, NOT collapsed

anchors = {}
for f in all_docs:
    s = set()
    for line in f.read_text(encoding='utf-8').splitlines():
        m = re.match(r'^#{1,6}\s+(.*)', line)
        if m:
            s.add(slug(m.group(1)))
    anchors[f.resolve()] = s

bad = []
for f in sources:
    text = f.read_text(encoding='utf-8')
    for m in re.finditer(r'\]\(([^)\s]+)\)', text):
        link = m.group(1)
        if link.startswith(('http://', 'https://', 'mailto:', '#!')):
            continue
        path, _, frag = link.partition('#')
        target = (f.parent / path).resolve() if path else f.resolve()
        if not target.exists():
            bad.append(f'{f}: missing file -> {link}')
            continue
        if frag and target.suffix == '.md' and frag not in anchors.get(target, set()):
            bad.append(f'{f}: missing anchor -> {link}')

print('\n'.join(bad) if bad else 'OK: all relative links and anchors resolve')
sys.exit(1 if bad else 0)
```

- [ ] **Step 2: Confirm the baseline is still clean**

Run from the repo root:

```bash
python "$SCRATCHPAD/check-links.py"
```

Expected: `OK: all relative links and anchors resolve`. If it does not, stop — something landed on this branch between the plan being written and now, and later tasks' gates would be measuring the wrong thing.

- [ ] **Step 3: Do not commit**

The checker is a throwaway tool, not a repo asset. This repo has no test system by design (`CLAUDE.md`: "correctness is verified by reading, not by executing locally") and this plan does not introduce one.

---

## Task 1: Part A — the certificate and the 443 redirect

**Files:**
- Modify: `docs/proxmox-setup.md` — two new subsections inside Part 3, placed **after** `### Cap the ZFS ARC` and **before** `### Update and reboot`
- Modify: `docs/dns-records.md:53` (the `pve` row) and the paragraph block before `## No AAAA records, anywhere`
- Modify: `docs/sso-applications.md` — the intro count, the summary table, a new section, and the backup-job section's cross-reference
- Modify: `docs/timetable.md` — the "Continuous and short-interval" table
- Modify: `CLAUDE.md:157` — the SSO convention's exception wording

**Interfaces:**
- Produces: the anchors `#give-the-host-a-real-certificate` and `#serve-it-on-443`, which Task 4 links from `README.md` and `docs/status.md`.
- Produces: the section `## The Proxmox web UI (deliberately not joined)` in `sso-applications.md`, anchor `#the-proxmox-web-ui-deliberately-not-joined`.

- [ ] **Step 1: Add the certificate subsection to `proxmox-setup.md` Part 3**

Insert after the `### Cap the ZFS ARC` subsection ends and before `### Update and reboot`. Heading exactly:

```markdown
### Give the host a real certificate
```

Content requirements — prose is yours, these facts are not optional:

- It replaces the self-signed certificate accepted in the *Put the host's name on the router* step above, so every later visit to the UI is warning-free.
- **Exact name, not a wildcard**, and say why: the wildcard's challenge record is `_acme-challenge.thefipster.de`, which Traefik and Coolify's proxy already contend for, and netcup's zone updates are not atomic — this is the same reasoning `infra/traefik/compose.yaml` gives for carrying no apex SAN. An exact certificate validates at `_acme-challenge.pve.thefipster.de` and races with nobody.
- The netcup API credentials come from netcup's CCP and are the **same three values** Traefik will later want; they now exist on this machine too. Vaultwarden is the source of truth once it exists.
- The validation delay mirrors Traefik's `NETCUP_PROPAGATION_TIMEOUT` of 900 s because netcup publishes TXT records slowly regardless of which client asks — expect the wait.

Commands, **each in its own fenced block** per the guide convention:

```bash
pvenode acme account register default <your-acme-email>
```

```bash
printf 'NC_Apikey=%s\nNC_Apipw=%s\nNC_CID=%s\n' '<api-key>' '<api-password>' '<customer-number>' > /tmp/netcup.env
```

```bash
pvenode acme plugin add dns netcup --api netcup --data /tmp/netcup.env --validation-delay 900
```

```bash
rm -f /tmp/netcup.env
```

State plainly why that `rm` is a step and not a tidy-up: Proxmox reads the file once and stores the values in `/etc/pve/priv/acme/plugins.cfg`, so leaving it behind is a second plaintext copy of the credentials in a world-readable directory.

```bash
pvenode config set --acmedomain0 pve.thefipster.de,plugin=netcup
```

```bash
pvenode acme cert order
```

Verification — note that this runs on the host and only checks the certificate, not the port:

```bash
openssl s_client -connect localhost:8006 -servername pve.thefipster.de </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

The issuer must be Let's Encrypt and the subject `CN=pve.thefipster.de`. Renewal is Proxmox's own `pve-daily-update.timer`, which renews under 30 days remaining — the same policy Traefik applies to the wildcard, on a different clock.

- [ ] **Step 2: Add the port subsection to `proxmox-setup.md` Part 3**

Immediately after the previous subsection. Heading exactly:

```markdown
### Serve it on 443
```

Content requirements:

- pveproxy cannot be moved off 8006, so the port is solved below pveproxy with an nftables DNAT rule rather than by putting a proxy in front of it.
- **`:8006` stays open.** This adds a door; it does not close one — and it is the fallback if the rule is ever wrong.

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
# proxmox-firewall rather than fighting it for ownership of the ruleset.
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

The `-` on `ExecStop` is deliberate: deleting a table that is not there must not fail the unit.

```bash
systemctl enable --now pve-https-redirect.service
```

```bash
nft list table inet pve-https
```

- [ ] **Step 3: Write the verification-from-elsewhere warning**

This is the gotcha that otherwise costs an hour, and it belongs in the step, not in troubleshooting. Content requirements: locally-generated traffic never traverses `prerouting`, so running `curl https://pve.thefipster.de` **on the hypervisor** bypasses the rule entirely and fails in a way that looks exactly like a broken rule. Verify from a LAN client instead:

```bash
curl -sI https://pve.thefipster.de | head -1
```

From the Windows workstation, matching the PowerShell blocks in `wildcard-dns-udr.md`:

```powershell
(Invoke-WebRequest -Uri https://pve.thefipster.de -Method Head).StatusCode
```

- [ ] **Step 4: Update the `pve` row in `dns-records.md`**

Replace line 53's Serves cell. From:

```markdown
| `pve.thefipster.de` | `pve ip` | Proxmox web UI, and the host node exporter Alloy scrapes (`:9100`) |
```

To:

```markdown
| `pve.thefipster.de` | `pve ip` | Proxmox web UI on **443** (its own certificate, not Traefik's), and the host node exporter Alloy scrapes (`:9100`) |
```

- [ ] **Step 5: Add the no-new-record note to `dns-records.md`**

Directly after the paragraph beginning **The backup repository needs no new record either.** and before `## No AAAA records, anywhere`. Content requirements:

- Serving the UI on 443 adds **no record**. The name already points at the hypervisor and that is the machine the UI is on.
- Say explicitly that routing it through Traefik was rejected, and why in one sentence: `pve.` would have had to become a service name pointing at the infra VM, forcing a new name on the machine that Alloy's scrape target, the restic repository and the installer's FQDN all follow — and it would make the hypervisor's repair surface depend on one of its own guests.
- The name is now also an **ACME subject**, validating at `_acme-challenge.pve.thefipster.de` — a different FQDN from the wildcard's, which is what keeps the two issuers from racing.
- It still needs its **exact** record for the reason it always did: the wildcard would answer with the apps VM.

- [ ] **Step 6: Add the Proxmox section to `sso-applications.md`**

Insert a new section **before** `## The backup job (not an application at all)`:

```markdown
## The Proxmox web UI (deliberately not joined)
```

Content requirements:

- Proxmox has a native **OpenID Connect realm**, so unlike Kuma and Home Assistant the convention points at OIDC rather than forward-auth — and it declines anyway. That makes it the second entry here that turns down a pattern it qualifies for.
- The reason: this is the console you use to repair the machine Authentik runs on. An OIDC realm is additive — `root@pam` would remain — so joining would not remove the break-glass path, but it would put a moving part between you and a box you only visit when something is already wrong.
- It is also the one UI in the lab **Traefik does not front**: it terminates its own TLS on its own machine ([proxmox-setup.md, Part 3](proxmox-setup.md#serve-it-on-443)), so forward-auth was never available to it even as a fallback.
- Nothing to click in Authentik, and nothing to undo. State that `infra/authentik/compose.yaml` correctly carries **no** outpost router for this host and that this is not the same absence as the other three — there is no Traefik router here to gate at all.

- [ ] **Step 7: Fix the counts and the "single exception" wording in `sso-applications.md`**

Three edits, all forced by Step 6. Replace **Three** with **Four** in the intro sentence at line 26–32 and add the new link to its list. Then replace lines 36–39:

```markdown
**Only one of the three could have joined.** Kuma and Home Assistant have no
OIDC support at all, so the convention would have pointed them at forward-auth.
Vaultwarden **has** OIDC, which makes it the single service in the lab that
declines a pattern it qualifies for.
```

with wording that carries the same facts without the ordinal trap — Kuma and Home Assistant have no OIDC and would have been forward-auth candidates; Vaultwarden and the Proxmox web UI both **have** OIDC and decline it, for reasons that rhyme (each is a tool for repairing the identity provider or the machine it runs on).

Add a row to the summary table at lines 41–50:

```markdown
| Proxmox web UI | **none** (deliberate) | Proxmox's own `root@pam` login | [proxmox-setup.md, Part 3](proxmox-setup.md#give-the-host-a-real-certificate) |
```

And at line 226, `## The backup job` says it "is not counted among the **three** deliberate non-joiners". Update that count and keep its distinction intact: the backup job was never *eligible*, which is a different absence from the ones that could have joined and did not.

- [ ] **Step 8: Add the ACME renewal row to `timetable.md`**

In the **Continuous and short-interval** table, directly after the existing Traefik ACME row (line 54), matching its shape:

```markdown
| **daily** | Proxmox host | Proxmox's ACME renewal check; it renews `pve.thefipster.de` when under 30 days remain. `pve-daily-update.timer`, which also does the APT update check — nothing in this repo overrides either | [proxmox-setup.md](proxmox-setup.md#give-the-host-a-real-certificate) |
```

- [ ] **Step 9: Fix the SSO exception wording in `CLAUDE.md`**

At line 157, `**Three services join neither, deliberately.**` and the sentence ending "which makes it the single exception to 'anything with native OIDC uses it'" are now both wrong. Update to four, and change the single-exception claim to name Vaultwarden and the Proxmox web UI as the two that decline OIDC they have. Add a one-line entry for the Proxmox web UI in the bulleted list of exceptions, stating that it is outside Traefik entirely so forward-auth was never on the table either.

- [ ] **Step 10: Verify**

```bash
python "$SCRATCHPAD/check-links.py"
```

Expected: `OK: all relative links and anchors resolve`.

```bash
grep -rnE '\b(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+' docs/proxmox-setup.md docs/dns-records.md docs/sso-applications.md docs/timetable.md
```

Expected: no output. A literal address is a flag.

```bash
grep -n "Three services join neither\|single exception" CLAUDE.md; grep -n "Only one of the three\|among the \*\*three\*\*" docs/sso-applications.md
```

Expected: no output — every ordinal claim this task invalidated has been rewritten.

- [ ] **Step 11: Commit**

```bash
git add docs/proxmox-setup.md docs/dns-records.md docs/sso-applications.md docs/timetable.md CLAUDE.md
git commit -m "docs: serve the Proxmox web UI on 443 with its own certificate"
```

---

## Task 2: Part B — NUT, the shutdown chain, and killpower

**Files:**
- Modify: `docs/proxmox-setup.md` — Part 1 gains a BIOS setting; a new **Part 10** is appended after Part 9
- Modify: `docs/proxmox-setup.md` — the "Part 9 below is deliberately out of sequence" note before Part 9, so it covers Part 10's second half too

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: the Part 10 heading and anchor `#part-10--survive-a-power-cut`, which Tasks 3 and 4 link. Produces the numbered steps 1–5; Task 3 appends steps 6–8 to the same Part.

- [ ] **Step 1: Add the BIOS setting to Part 1**

Part 1's item 1 is the BIOS/UEFI item (VT-x/AMD-V, IOMMU); items 2 and 3 are the
ISO download and the USB stick. The new setting belongs **with the other
firmware settings**, so it goes into item 1 or becomes a new item 2 — not after
the ISO download, which would send you back into the BIOS on a second trip.

```markdown
2. **Set "Restore on AC Power Loss" (sometimes "AC Back" or "After Power
   Failure") to *Power On*.** Without it the UPS work in
   [Part 10](#part-10--survive-a-power-cut) is half-finished: the host shuts
   down cleanly on battery and then stays dark when mains returns, because
   nothing tells it to boot.
```

Renumber the two items that follow (ISO download → 3, USB stick → 4). They are a
plain numbered list with no anchors pointing at them, so this is safe.

- [ ] **Step 2: Extend the out-of-sequence note**

The note before Part 9 currently says "**Part 9 below is deliberately out of sequence — skip it now.**". Part 10's *reporting* half shares Part 9's dependencies (a Kuma push monitor and the host's node exporter) but its *shutdown* half depends on neither. Rewrite the note so it covers both Parts and makes that split explicit: Part 10 steps 1–5 can be done as soon as the UPS is plugged in, and only its reporting steps wait for Uptime Kuma.

- [ ] **Step 3: Open Part 10**

Append after Part 9 ends:

```markdown
## Part 10 — Survive a power cut
```

Content requirements for the opening prose:

- A banner mirroring Part 9's: steps 1–5 need nothing but the UPS and this host; steps 6–8 need a Kuma push monitor and the `prometheus-node-exporter` from [grafana-setup.md step 6](grafana-setup.md#6-add-the-proxmox-host).
- The hardware: a CyberPower CP900EPFCLCD (900 VA / 540 W, line-interactive) on **USB to this host**. The USB *data* cable, not just the power lead.
- **What is plugged into it:** the server, the UDR and the switch, all on **battery-backed** outlets rather than the surge-only ones these units also have. Then the sentence that matters — notifications go to hosted ntfy.sh, so if the modem or ONT is on an unprotected socket the alert has nowhere to go, and the whole reporting half of this Part is silent exactly when it is needed.
- What this buys: an orderly shutdown, not continuity. No generator, no second UPS, nothing offsite.

- [ ] **Step 4: Write step 1 — install NUT and find the UPS**

```markdown
### 1. Install NUT and confirm the UPS is seen
```

```bash
apt install nut-server nut-client
```

```bash
lsusb | grep -i cyber
```

```bash
nut-scanner -U
```

State that `nut-scanner` prints a ready-made `ups.conf` stanza, and that the next step writes one by hand anyway so the file carries the lab's own comments.

- [ ] **Step 5: Write step 2 — configure NUT in standalone mode**

```markdown
### 2. Configure NUT
```

State up front: **standalone mode**, `upsd` on loopback only. No VM runs a NUT client — step 3 explains why.

```bash
echo "MODE=standalone" > /etc/nut/nut.conf
```

```bash
cat > /etc/nut/ups.conf <<'EOF'
# Named `ups`, not after the model: the name appears in upsmon.conf, upsd.users,
# upssched.conf and every upsc call, and it should survive a hardware swap.
[ups]
  driver = usbhid-ups
  port = auto
  desc = "CyberPower CP900EPFCLCD"
EOF
```

```bash
cat > /etc/nut/upsd.conf <<'EOF'
# Loopback only. Nothing else on the LAN talks to this - the guests are shut
# down by Proxmox itself, not by NUT clients.
LISTEN 127.0.0.1 3493
EOF
```

Generate the monitoring password rather than inventing one, matching how every init script in this repo mints secrets. The guide must say that the next three blocks run in **one shell session** — the variable is what carries the password into both files, and a fresh shell between them writes an empty password into `upsmon.conf` that fails authentication with a message about credentials rather than about a typo:

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

Both files hold the password, so both are locked down:

```bash
chown root:nut /etc/nut/upsd.users /etc/nut/upsmon.conf && chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
```

```bash
systemctl restart nut-server nut-monitor
```

```bash
upsc ups
```

Verification prose: `ups.status` should read `OL` (on line). Then the model-specific wart, stated where someone will see it in that output — this unit reports **output voltage** in the 260–270 V range against a real 230 V ([NUT #581](https://github.com/networkupstools/nut/issues/581)). It is cosmetic, and the consequence is narrow and deliberate: nothing in this Part alerts on a voltage reading. Charge, runtime, load and status are the fields to trust.

- [ ] **Step 6: Write step 3 — let Proxmox shut the guests down**

```markdown
### 3. Set the guest shutdown order and timeout
```

Content requirements — this is the "no NUT in the guests" decision, and it must read as a decision:

- `pve-guests.service` already shuts every guest down when the host halts: its `ExecStop` calls `pvesh create /nodes/localhost/stopall`, which goes through the guest agent, falls back to ACPI, and forces off after the per-guest timeout.
- `scripts/init-host.sh` already installs `qemu-guest-agent` on both Ubuntu VMs and HAOS ships it, so the clean path works for all three — the same investment that makes `vzdump`'s Snapshot mode consistent.
- The home-assistant VM is an **appliance** this repo has no shell in, so a design needing a NUT client in every guest would have a hole in it from the start.
- **Why infra is last:** Uptime Kuma runs on the infra VM, and it should be the last thing alive so it can report for as long as possible. Guests shut down in *reverse* start order, and guests with no configured order go by VMID — which here already gives `ha → apps → infra`. That is right by accident, which is not a good enough reason to leave it implicit.

```bash
qm set 101 --startup order=1,down=90
```

```bash
qm set 102 --startup order=2,down=90
```

```bash
qm set 103 --startup order=3,down=90
```

State the arithmetic plainly: Proxmox defaults to a 180 s shutdown timeout per guest, so three guests is 9 minutes worst case — the dominant term in the backstop sizing in step 4. `down=90` is comfortable for both Ubuntu VMs and brings the worst case to 4.5 minutes.

```bash
for id in 101 102 103; do qm config $id | grep -H --label="vm$id" startup; done
```

- [ ] **Step 7: Write step 4 — the trigger and the backstop**

```markdown
### 4. Decide when to shut down
```

The finding goes here, in the doing-path, because it explains why the file below looks the way it does: at this load the unit gives roughly 15–20 minutes and raises `LB` near the end of it — around 4–5 minutes left. Against a 4.5-minute worst-case guest shutdown, `LB` alone leaves no margin. **So the backstop is not insurance for a tired battery; it is what fires in practice, and its value is the actual policy.**

Give the formula, not just the number:

> **backstop + worst-case guest shutdown < measured runtime**

300 s + 270 s = 9.5 minutes, against a runtime step 8 measures.

```bash
cat > /etc/nut/upssched.conf <<'EOF'
CMDSCRIPT /usr/local/bin/upssched-cmd
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

# The backstop. See proxmox-setup.md Part 10 step 4 for the arithmetic:
# backstop + worst-case guest shutdown must be less than measured runtime.
AT ONBATT  * START-TIMER  onbatt-shutdown 300
AT ONLINE  * CANCEL-TIMER onbatt-shutdown

# Report immediately. Kuma runs on a guest of this host and dies with it, so
# the window between ONBATT and the infra VM halting is the ONLY one in which
# an outage can be reported at all.
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
    # halt the host correctly and silently skip the half that revives it.
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

Note in prose that `power-event` calls a script step 6 creates, so until then that branch logs a failure and nothing else — which is harmless and expected if the UPS is wired up before Uptime Kuma exists.

- [ ] **Step 8: Write step 5 — killpower**

```markdown
### 5. Make the lab come back on its own
```

Content requirements — both halves are required and either one alone leaves the box dark:

1. The BIOS setting from [Part 1](#part-1--prerequisites).
2. Killpower: `upsmon` writes `/etc/killpower` before halting, and a systemd shutdown hook then runs `upsdrvctl shutdown`, telling the UPS to cut its own output after a delay and restore it when mains returns. That interruption is what the BIOS setting reacts to.

State the trap explicitly: without the second half, mains returning while the host is still halting means the UPS never interrupts its output, nothing power-cycles, and the server sits off after an outage it appeared to handle correctly.

Then the Debian defect:

```bash
cat /usr/lib/systemd/system-shutdown/nutshutdown
```

If it gates the killpower call on `upsmon -K`, that has been reported to always return false, so `upsdrvctl shutdown` never runs ([Debian #835555](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=835555)). Do **not** edit that file:

```bash
cat > /usr/lib/systemd/system-shutdown/zz-nut-killpower <<'EOF'
#!/bin/sh
# Cut UPS output after a power-fail shutdown, so the UPS cycles the load when
# mains returns and the BIOS "restore on AC power loss" setting boots the box.
#
# A SEPARATE file on purpose. Debian's own nutshutdown gates on `upsmon -K`,
# which has been reported to always return false (Debian #835555) - but it
# lives under /usr/lib and is not a conffile, so editing it in place is
# silently reverted by the next nut-client upgrade. This runs alongside it,
# from a plain file test. If nutshutdown is ever fixed, both run and the second
# one is a harmless no-op.
#
# Only on poweroff/halt. A reboot must NOT cut the UPS.
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

State what that last one proves and does not: `-t` is a dry run, so it confirms the driver would accept the command without cutting power. The real proof is step 8's drill, because this is the half most likely to be silently broken.

- [ ] **Step 9: Verify**

```bash
python "$SCRATCHPAD/check-links.py"
```

Expected: `OK: all relative links and anchors resolve`.

```bash
grep -c '^```bash' docs/proxmox-setup.md
```

Expected: a higher count than before this task — every command is in its own fenced block, per the guide convention. Spot-check that no fenced block in Part 10 holds two commands.

- [ ] **Step 10: Commit**

```bash
git add docs/proxmox-setup.md
git commit -m "docs: UPS shutdown chain on the Proxmox host (NUT, backstop, killpower)"
```

---

## Task 3: Part B — reporting, the alert rule, and the drill

**Files:**
- Modify: `docs/proxmox-setup.md` — Part 10 steps 6, 7 and 8
- Modify: `docs/uptime-kuma-monitors.md` — a new section, plus two ordinal fixes
- Modify: `docs/timetable.md` — the short-interval table and the push-monitor heartbeat table
- Modify: `infra/monitoring/grafana/provisioning/alerting/rules.yaml` — the `UpsBatteryAging` rule

**Interfaces:**
- Consumes: Task 2's `upssched-cmd`, which calls `/usr/local/bin/ups-health-push.sh` with no arguments and expects it to read `PUSH_URL` from the environment.
- Consumes: Task 2's Part 10 heading and its step numbering (steps 1–5 exist; this task adds 6–8).
- Produces: the metric names `ups_status_on_line`, `ups_status_on_battery`, `ups_status_low_battery`, `ups_battery_charge_percent`, `ups_battery_runtime_seconds`, `ups_load_percent` — the Grafana rule below depends on the first and the fifth by exact name.

- [ ] **Step 1: Add the Kuma monitor section to `uptime-kuma-monitors.md`**

Insert **after** `## Hypervisor storage — Proxmox host` and **before** `## Backup — infra VM`:

```markdown
## Power — Proxmox host

| Name | Type | Target |
|---|---|---|
| Site Power | Push | *(push URL — the host calls Kuma)* |
```

Content requirements:

- Heartbeat **300 s**, 2 retries — same cadence as `Hypervisor Storage`, sized by the same arithmetic.
- The name follows the function-not-product rule: what breaks for a user is site power, not a UPS.
- **Two things are pushed from two places**, and say why the second is not a latency optimisation: a 5-minute timer carries metrics and the heartbeat, and `upssched` fires the same script on `ONBATT`/`ONLINE`/`LOWBATT` because Kuma runs on a guest of the machine that is about to shut down — the window between on-battery and the infra VM halting is the only one in which an outage can be reported at all.
- **The deadman here is weak, and say so.** For `Hypervisor Storage`, silence means the script or the host died while the lab was otherwise up. Here the failure this monitor exists for takes Kuma down with it, so silence is *expected* during the very event being watched. It still catches a broken script on a healthy lab; it is not the alarm.
- The alert can only leave the house if the WAN termination is powered — cross-reference Part 10's opening.
- Battery *ageing* goes the other way, to Grafana, for the same reason pool capacity does: a slow drift is something to look at on a graph, not to be told about at 3am.

- [ ] **Step 2: Fix the two ordinal claims in `uptime-kuma-monitors.md`**

Under `## Hypervisor storage — Proxmox host`, this sentence is now false:

```markdown
The **first** of the two monitors here that watch a **condition** rather than a
service — [Backup](#backup--infra-vm) below is the other — and neither one's
target is something Kuma dials.
```

Under `## Backup — infra VM`, so is this one:

```markdown
The second **Push** monitor, and the second thing in this lab that watches a
condition rather than a service.
```

Rewrite both to name their companions instead of counting them — the property that matters is "watches a condition Kuma cannot dial", shared by Hypervisor Storage, Site Power and Backup Job. Durable wording is a Global Constraint; this is the sentence pair it exists for.

- [ ] **Step 3: Add the timetable rows**

In **Continuous and short-interval**, directly after the existing 5-minute ZFS row:

```markdown
| **5 min** | Proxmox host | UPS state pushed to Kuma, and `ups_*` written for Prometheus (`OnBootSec=2min`, then `OnUnitActiveSec=5min`). Also fired immediately by `upssched` on every power event | [proxmox-setup.md Part 10](proxmox-setup.md#part-10--survive-a-power-cut) |
```

Then the heartbeat table below it. Its lead-in currently reads **Kuma's two push monitors invert the rule.** — make it durable rather than counted, and add the row:

```markdown
| **300 s**, 2 retries | Site Power | the 5-minute UPS timer above, plus every `upssched` power event |
```

- [ ] **Step 4: Write Part 10 step 6 — the push script**

```markdown
### 6. Report UPS state to Kuma and Prometheus
```

Open by naming the pattern: this mirrors `zfs-health-push.sh` from [Part 9](#part-9--notice-when-a-mirror-degrades) deliberately, because it is the same problem — a condition on a machine with no checkout, wanted in two places at once. Create the Kuma monitor first and copy its push URL.

```bash
cat > /usr/local/bin/ups-health-push.sh <<'EOF'
#!/usr/bin/env bash
# Report UPS state to Uptime Kuma, and write battery/load metrics for Prometheus.
# One upsc read, two consumers - same shape as zfs-health-push.sh.
set -uo pipefail

PUSH_URL="${PUSH_URL:?PUSH_URL is not set}"
UPS="${UPS:-ups@localhost}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"

# Fail closed. If upsc cannot read the UPS, the USB link is the fault - say so
# rather than writing a stale-looking healthy metric beside a silent failure.
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

# ups.status is a space-separated set: "OL", "OL CHRG", "OB DISCHRG", "OB LB".
on_line=0;  case " $status " in *" OL "*) on_line=1 ;; esac
on_batt=0;  case " $status " in *" OB "*) on_batt=1 ;; esac
low_batt=0; case " $status " in *" LB "*) low_batt=1 ;; esac

# ---- metrics: temp file then mv, so node_exporter never reads a half-written
# ---- file. The -w test matters: this script also runs as `nut` from upssched,
# ---- which cannot write here. That path pushes and skips metrics, which is
# ---- fine - the timer below owns the metrics.
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

# ---- health: pushed to Kuma. No voltage anywhere - this model misreports it.
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

The push URL is a bearer token in a query string, so it goes in a mode-restricted file rather than in the unit — and the mode here differs from Part 9's on purpose:

```bash
install -m 640 -o root -g nut /dev/null /etc/default/ups-health-push
```

```bash
echo 'PUSH_URL=https://uptime.thefipster.de/api/push/<token>' > /etc/default/ups-health-push
```

State why plainly: Part 9's equivalent is mode 600 root-only, and this one cannot be. `upssched` runs as the `nut` user, so a root-only environment file would make every instant power-event push fail with the file unreadable — the one push that matters most, failing silently.

- [ ] **Step 5: Write Part 10 step 7 — the timer**

```markdown
### 7. Put it on a timer
```

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

```bash
systemctl start ups-health-push.service && systemctl status ups-health-push.service
```

```bash
cat /var/lib/prometheus/node-exporter/ups.prom
```

```bash
curl -s localhost:9100/metrics | grep '^ups_'
```

Prose: the Kuma monitor should go green within a minute with a message naming the battery percentage. Alloy already scrapes this endpoint, so nothing changes on the infra VM — the metrics arrive on the next scrape. Reuse Part 9's `status=22` / `curl: (22) ... 404` troubleshooting by reference rather than repeating it.

- [ ] **Step 6: Add the Grafana alert rule**

In `infra/monitoring/grafana/provisioning/alerting/rules.yaml`, after the `zfs-pool-almost-full` rule (which ends at line 86) and before the `# ---- a scrape target is down` comment block:

```yaml
      # ---- the UPS battery is ageing out ----------------------------------
      # A dying UPS battery's only symptom is a shorter runtime, and `Site
      # Power` in Uptime Kuma stays green throughout - it watches whether mains
      # is present, not whether the battery could still carry a shutdown.
      #
      # Gated on being ON LINE POWER, which is the whole point: a low runtime
      # during an actual outage is the outage, not a fault. `for: 1h` because
      # the estimate dips transiently under load.
      #
      # 900 s against a shutdown budget of 570 s (300 s backstop + 3 guests at
      # down=90) - it warns while there is still comfortable margin. Both
      # numbers are set in docs/proxmox-setup.md Part 10.
      - uid: ups-battery-aging
        title: UpsBatteryAging
        condition: C
        for: 1h
        noDataState: OK
        execErrState: Error
        labels:
          severity: warning
        annotations:
          summary: "UPS estimated runtime on {{ $labels.instance }} is below the shutdown budget while on mains"
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus
            model:
              refId: A
              instant: true
              expr: >-
                ups_battery_runtime_seconds and on(instance) (ups_status_on_line == 1)
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator: { type: lt, params: [900] }
```

- [ ] **Step 7: Verify the rules file still parses**

```bash
python -c "import yaml,sys; d=yaml.safe_load(open('infra/monitoring/grafana/provisioning/alerting/rules.yaml')); print('ok, rules:', [r['title'] for g in d['groups'] for r in g['rules']])"
```

Expected: `ok, rules: ['DiskAlmostFull', 'ZfsPoolAlmostFull', 'ServiceDown', 'CertExpiringSoon', 'UpsBatteryAging']` — order depends on where it was inserted; `UpsBatteryAging` must be present and every existing title must still be there.

- [ ] **Step 8: Write Part 10 step 8 — the commissioning drill**

```markdown
### 8. Pull the plug, once, on purpose
```

Content requirements:

- Why it exists: the runtime figure cannot come from the datasheet, and it is the input to step 4's arithmetic. And killpower is the half most likely to be silently broken, so it has to be exercised rather than reasoned about.
- The chain to watch, in order: on-battery notification arrives on the phone → backstop fires at 300 s → guests shut down `ha`, `apps`, `infra` → host halts → UPS cuts output → mains restored → UPS restores output → box boots itself → guests start in order.
- Two outputs: the **measured runtime**, which is written back into step 4's numbers if the arithmetic no longer holds, and proof that the box comes back.
- Repeat it when the battery is replaced. Cross-reference [backup-restore-drill.md](backup-restore-drill.md) as the same idea applied to backups — a path nobody has exercised is a hypothesis.

Useful commands during the drill:

```bash
journalctl -fu nut-monitor
```

```bash
upsc ups battery.runtime
```

- [ ] **Step 9: Add Part 10's troubleshooting and layout entries**

The guide convention puts troubleshooting and *Layout on the server* below the fold. `proxmox-setup.md` has no such sections today, so add the Part 10 items inline at the end of Part 10 rather than inventing document-wide sections. At minimum:

- **`upsc` says "Driver not connected"** — the driver did not start. `systemctl status nut-driver-enumerator`, and re-run it after any `ups.conf` edit.
- **The instant push never arrives but the 5-minute one does** — `/etc/default/ups-health-push` is not readable by `nut`. Re-check its mode and group.
- **The box stays dark after an outage it survived** — either the BIOS setting or killpower. Check `ls -l /etc/killpower` right after a forced shutdown and re-read step 5.
- **Layout:** `/etc/nut/*`, `/usr/local/bin/ups-health-push.sh`, `/usr/local/bin/upssched-cmd`, `/etc/default/ups-health-push`, `/etc/systemd/system/ups-health-push.{service,timer}`, `/usr/lib/systemd/system-shutdown/zz-nut-killpower`.

- [ ] **Step 10: Verify**

```bash
python "$SCRATCHPAD/check-links.py"
```

Expected: `OK: all relative links and anchors resolve`.

```bash
grep -n "ups_battery_runtime_seconds\|ups_status_on_line" infra/monitoring/grafana/provisioning/alerting/rules.yaml docs/proxmox-setup.md
```

Expected: the metric names in the alert rule match the names the script emits, exactly. This is the one cross-file contract in the plan that nothing else would catch.

```bash
grep -n "the second \*\*Push\*\*\|The \*\*first\*\* of the two\|Kuma's two push monitors" docs/uptime-kuma-monitors.md docs/timetable.md
```

Expected: no output.

- [ ] **Step 11: Commit**

```bash
git add docs/proxmox-setup.md docs/uptime-kuma-monitors.md docs/timetable.md infra/monitoring/grafana/provisioning/alerting/rules.yaml
git commit -m "docs: UPS reporting to Kuma and Prometheus, plus the battery-ageing alert"
```

---

## Task 4: The summaries

**Files:**
- Modify: `docs/status.md` — two rows
- Modify: `README.md` — the architecture block and the TLS sentence under Networking & DNS
- Modify: `CLAUDE.md` — the topology bullet for the Proxmox host, and the routing-convention note

**Interfaces:**
- Consumes: anchors produced by Tasks 1 and 2 — `#give-the-host-a-real-certificate`, `#serve-it-on-443`, `#part-10--survive-a-power-cut`.

- [ ] **Step 1: Add the status rows**

In `docs/status.md`, after the `ZFS pool health → Uptime Kuma` row:

```markdown
| Proxmox web UI on 443 with its own certificate | ⬜ planned — [Part 3](proxmox-setup.md#give-the-host-a-real-certificate). Its own Let's Encrypt cert via Proxmox's ACME client, not Traefik's wildcard; the UI is deliberately the one that does not depend on the infra VM |
| UPS: orderly shutdown, and coming back | ⬜ planned — [Part 10](proxmox-setup.md#part-10--survive-a-power-cut). NUT on the hypervisor, no client in any guest. Not yet done: the commissioning drill, which is what turns the backstop arithmetic from an estimate into a measurement |
```

Note the legend at the bottom of that file claims **No `📄` rows are left** and that everything is verified on the machine it describes. Two `⬜` rows do not contradict that, but check the surrounding prose still reads true and adjust the closing paragraphs if it does not — that file's "Every machine in the build order is built" summary now has two open items on the hypervisor.

- [ ] **Step 2: Update the README architecture block**

Line 28 currently reads:

```
Proxmox VE · pve.thefipster.de · i5-10600K · 12 threads · 96 GB · hypervisor only, no Docker
```

Add two lines beneath it, above the pool list, matching the block's indentation style:

```
    │  its own Let's Encrypt cert on :443 — the one lab UI Traefik does not front
    │  CyberPower CP900 on USB · NUT · orderly shutdown of the host and all three guests
```

- [ ] **Step 3: Update the README TLS sentence**

Under **Networking & DNS**, the paragraph beginning "Certificates are genuine Let's Encrypt wildcards" is now incomplete — it describes Traefik's wildcard as though it were the whole story. Add a sentence: the hypervisor issues its own **exact** certificate for `pve.thefipster.de` from Proxmox's built-in ACME client, deliberately outside Traefik, so the management UI does not depend on one of its own guests.

- [ ] **Step 4: Update the CLAUDE.md topology bullet**

Line 35's bullet currently reads:

```markdown
- **Proxmox host** — hypervisor only, no Docker. A bad container can't
  take the box down.
```

Extend it with the two facts a future reader needs before touching this machine: it terminates its **own** TLS for `pve.thefipster.de` on 443 (its own ACME client and its own exact certificate — the lab's one UI that is not behind Traefik, so that the repair surface does not depend on a guest), and it runs **NUT** for the UPS, shutting all three guests down through Proxmox's own guest shutdown rather than through NUT clients.

- [ ] **Step 5: Note the exception in CLAUDE.md's routing convention**

The routing convention section opens "Traefik is the only thing that terminates TLS and does routing on the infra VM" — which stays true as written, since the hypervisor is not the infra VM. Add a short note anyway, because the sentence reads as a lab-wide claim: the Proxmox host terminates its own TLS on its own machine, deliberately, and that is the one place a second certificate in the lab is correct rather than a mistake. Point at the spec.

- [ ] **Step 6: Verify**

```bash
python "$SCRATCHPAD/check-links.py"
```

Expected: `OK: all relative links and anchors resolve`. This is the run that matters most — Task 4 is the only task that links anchors created by other tasks.

```bash
grep -rnE '\b(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+' README.md CLAUDE.md docs/status.md docs/proxmox-setup.md
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add README.md CLAUDE.md docs/status.md
git commit -m "docs: record the hypervisor's own certificate and its UPS"
```

---

## Self-review notes

Run against the spec after the plan was written.

**Spec coverage.** Every section maps to a task: the name-stays-one-thing decision → Task 1 steps 4–5; the certificate → Task 1 steps 1, 8; the port → Task 1 steps 2–3; no SSO → Task 1 steps 6–7, 9; NUT shape and no-client-in-guests → Task 2 steps 5–6; trigger and arithmetic → Task 2 step 7; power return and the Debian defect → Task 2 step 8; reporting → Task 3 steps 1, 4, 5; the battery rule → Task 3 step 6; the drill → Task 3 step 8; the change-surface table → Tasks 1–4 collectively.

**Two cross-file contracts** are the places this plan can break silently, and each has an explicit verification step: the metric names shared between the push script and the Grafana rule (Task 3 step 10), and the anchors Task 4 links from Tasks 1 and 2 (Task 4 step 6).

**Ordinal debt is discharged, not added.** Existing sentences in `sso-applications.md`, `uptime-kuma-monitors.md`, `timetable.md` and `CLAUDE.md` count things this work adds to. Each is rewritten by name in the task that invalidates it, and each has a `grep` that fails if it was missed.

**Not covered here, by design** — these are the spec's stated follow-ups, not gaps in the plan: no battery replacement interval is scheduled anywhere, the UPS's own self-test schedule is left at the unit's default, and `Site Power`'s deadman stays weak because closing it needs a watcher outside the lab's failure domain.
