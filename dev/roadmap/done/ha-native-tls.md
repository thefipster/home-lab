# Roadmap: Home Assistant terminates its own TLS

Goal: the house's front door stops depending on the infra VM. As built,
`ha.thefipster.de` was a Traefik route declared in a file provider, so an
infra-VM outage — a reboot, a bad Traefik change, a dead disk — took the HA UI
and the companion app down while Home Assistant itself was fine. The capability
question that forced that arrangement is closed: the official **Let's Encrypt**
app — what HA called an add-on until it renamed them — bundles
`certbot-dns-netcup` (since 4.4.0, February 2020;
rechecked 2026-08-17 against 6.4.0), so the appliance can hold its own
certificate, issued the same way Traefik's is. Decided 2026-08-17: independence
outweighs reusing the shared wildcard — the trade the original design priced in
([three-machine-lab spec](../../specs/2026-07-26-three-machine-lab-design.md#routing--a-file-provider-for-traefik)).
Clients notice nothing: the name and the trust chain both survive, so paired
companion apps reconnect without re-pairing.

## ✅ Landed

See [home-assistant-setup.md](../../../docs/guides/home-assistant-setup.md),
steps 7 and 8. The HA VM runs the **Let's Encrypt** app with a `dns-netcup`
challenge and an exact certificate for `ha.thefipster.de`, serves 443 itself,
and re-runs the one-shot app from a weekly automation of its own. Traefik's
file provider is gone with its only user, `ha.` now names the machine, and
`homeassistant.` is retired.

## The work

- **The app, on the appliance.** Let's Encrypt app, DNS challenge,
  provider `dns-netcup`, an **exact** certificate for `ha.thefipster.de` —
  exact for the `pve` reason: it validates at
  `_acme-challenge.ha.thefipster.de`, a different FQDN from the wildcard's, so
  netcup's non-atomic zone updates give it nothing to race
  ([dns-records.md](../../../docs/reference/dns-records.md#serving-the-proxmox-ui-on-443-adds-no-record-either)).
  Options `netcup_customer_id` / `netcup_api_key` / `netcup_api_password` —
  another copy of those credentials, beside Traefik's `.env` and Coolify's
  proxy config; accepted. `propagation_seconds: 900`, the value Traefik
  already proved against netcup. Its **port 80 mapping is cleared** — the app
  will not start otherwise, and the port belongs to a challenge this lab does
  not use ([below](#four-things-the-plan-did-not-have)).
- **Cert paths and port into HA's Network settings.** The app writes
  `/ssl/fullchain.pem` + `/ssl/privkey.pem`; its DOCS still say to reference
  them from an `http:` block, which 2026.8 retired — the fields live in
  *Settings → System → Network* beside the port, and the guide says so with the
  app's own documentation flagged as wrong. Port becomes **443**, so the
  bare name keeps working.
- **The renewal automation.** The app is one-shot — it runs
  `certbot certonly --keep-until-expiring` and stops, renewing nothing on its
  own — so an HA automation starts it. Outside certbot's renewal window
  (30 days before expiry) that is a no-op: no ACME traffic, no netcup calls.
  It ended up **weekly rather than nightly**, and with an unconditional
  `homeassistant.restart` twenty minutes after each run — see
  [Four things the plan did not have](#four-things-the-plan-did-not-have)
  below.
  A [timetable.md](../../../docs/reference/timetable.md) row for the automation;
  the alarm for silent expiry is the certificate-expiry notification Kuma
  already offers on HTTPS monitors, switched on for `Home Automation` and
  recorded in
  [uptime-kuma-monitors.md](../../../docs/reference/uptime-kuma-monitors.md).
- **DNS.** The `ha.` row re-points from `infra ip` to `ha ip` — it keeps its
  exact record, because the wildcard still answers with the apps VM.
  `homeassistant.` is **retired**: its only consumers were Traefik's backend
  dial and Kuma's ping monitor, which re-points at `ha.`. The
  two-names-on-purpose section of
  [dns-records.md](../../../docs/reference/dns-records.md)
  came out; `ha.` is another `pve.`-shaped name — one name meaning the
  machine, serving the UI, the scrape and the cert at once. It is also now the
  **one deferred DNS row**, the position `homeassistant.` used to hold, because
  it is the only name pointing at the last machine built.
- **Traefik sheds the file provider.** `dynamic/ha.yaml` deleted, and the
  `--providers.file.*` flags and the read-only mount with it — that router was
  the provider's only user, and a fresh bring-up keeps no vestigial mechanism.
  Labels are the only provider again.
- **Trusted proxies comes out** of HA's Network settings. With it goes the one
  value in the lab that did not follow DNS — and its silent-400 staleness trap
  ([dns-records.md](../../../docs/reference/dns-records.md#why-this-registry-holds-no-addresses)).
- **The docs sweep.** `home-assistant-setup.md` steps 5–8 became the app
  procedure and the troubleshooting matrix lost the 502/loop/untrusted-proxy
  entries that describe a route which no longer exists; `traefik-setup.md` lost
  its file-provider half; both READMEs, CLAUDE.md's topology, routing, SSO and
  DNS-facts passages, and the registries moved together. Alloy's scrape config
  kept its target — `https://ha.thefipster.de` with the token now simply
  reaches HA directly — but its rationale was rewritten: what the scrape now
  proves is HA's own TLS.

## Four things the plan did not have

All four surfaced while carrying the procedure out rather than while designing
it, and each is recorded here because the reasoning is not obvious from the
result. The first two are collisions the plan could not have predicted from
reading; the last two are choices it left open.

**The Network form's two reverse-proxy fields are an inclusive pair**, so
`use_x_forwarded_for` and `trusted_proxies` are set together or not at all. The
form will happily submit one of them alone, and HA answers `some but not all
values in the same group of inclusion 'proxy'` — rejecting the **whole page**,
port and certificate paths included, which makes a schema complaint about a
section you were trying to *empty* look like a TLS failure. A fresh build never
touches that section and never sees it, which is why "leave the reverse-proxy
section alone" is a real instruction in the guide rather than an omission.

**The sharper half: once populated, that pair cannot be emptied from the form
at all.** The toggle always submits a value and an emptied list submits none, so
there is no sequence of edits that reaches *neither* — the form can set this
setting and cannot unset it. The guide's answer is to complete the pair with
**`192.0.2.1/32`** (RFC 5737 TEST-NET-1, reserved and routed nowhere) rather
than leave a real machine's address behind: syntactically complete, semantically
empty, and never the peer HA sees. Leaving the old proxy address would have been
inert only until something else took that address, at which point it would be
authorised to forge client IPs — a stale address still reading as authoritative,
which is the failure the whole name-everything rule exists to prevent.

This is the one place the built lab differs from what a fresh bring-up produces,
and it is a property of the form rather than of the design: build it from
scratch and the pair is simply never set.

**The app will not start until its port 80 mapping is cleared**, with
`Cannot start app core_letsencrypt because port 80 is already in use`. The two
halves of that collision are both consequences of decisions made elsewhere: the
app publishes 80 because that is where an **HTTP-01** challenge is answered, and
it declares the port whether or not that challenge is selected; and **Home
Assistant itself holds 80**, which has been HAOS's default since 2026.8 and is
what onboarding runs through. Nothing about DNS-01 needs the port — and HTTP-01
could never have worked here anyway, since it needs Let's Encrypt to reach a
host whose name resolves only on the LAN — so the mapping is cleared and stays
cleared. Worth knowing that it did **not** exist before 2026.8 moved HA off
8123: this is a collision the port change created.

**The renewal automation restarts Home Assistant, unconditionally.** HA reads
its certificate when it starts its HTTP server, so a file replaced underneath a
running instance is not necessarily the file being served. Rather than depend on
whether a given HA version watches `/ssl` for changes, the automation restarts
after every run — roughly six of the year's fifty-two actually replace a file —
at about thirty seconds each. It is cheaper than detecting which runs mattered,
and it makes the renewal correct rather than probably-correct.

**Weekly, not nightly.** The restart above is what makes a nightly run
unattractive, and it is not needed: certbot's renewal window is 30 days wide, so
a weekly trigger gets four attempts inside it and survives a netcup outage, a
powered-off VM or a bad night without any alarm of its own. Monthly was the
other end and was rejected — one attempt per window means a single failure
costs the whole window.

## The ordering that made the cutover safe

Clickwork on the appliance plus a wide docs sweep — the only lab-config change
is a deletion. One ordering matters: **issue the certificate first**, while
everything still routes through Traefik — DNS-01 neither knows nor cares where
`ha.` resolves. Then flip HA to 443 with the cert paths (this is the moment
Traefik's `:80` backend breaks), re-point the `ha.` row, and delete the route.
Each step's undo is the previous step. Drill the result the same way
Vaultwarden's restore is drilled: an already-paired companion app reconnecting,
not a fresh browser.
