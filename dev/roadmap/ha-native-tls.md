# Task: Home Assistant terminates its own TLS

Goal: the house's front door stops depending on the infra VM. Today
`ha.thefipster.de` is a Traefik route
([infra/traefik/dynamic/ha.yaml](../../infra/traefik/dynamic/ha.yaml)), so an
infra-VM outage — a reboot, a bad Traefik change, a dead disk — takes the HA UI
and the companion app down while Home Assistant itself is fine. The capability
question that forced that arrangement is closed: the official **Let's Encrypt
add-on** bundles `certbot-dns-netcup` (since add-on 4.4.0, February 2020;
rechecked 2026-08-17 against 6.4.0), so the appliance can hold its own
certificate, issued the same way Traefik's is. Decided 2026-08-17: independence
outweighs reusing the shared wildcard — the trade the original design priced in
([three-machine-lab spec](../specs/2026-07-26-three-machine-lab-design.md#routing--a-file-provider-for-traefik)).
Clients notice nothing: the name and the trust chain both survive, so paired
companion apps reconnect without re-pairing.

## The work

- **The add-on, on the appliance.** Let's Encrypt add-on, DNS challenge,
  provider `dns-netcup`, an **exact** certificate for `ha.thefipster.de` —
  exact for the `pve` reason: it validates at
  `_acme-challenge.ha.thefipster.de`, a different FQDN from the wildcard's, so
  netcup's non-atomic zone updates give it nothing to race
  ([dns-records.md](../../docs/reference/dns-records.md#serving-the-proxmox-ui-on-443-adds-no-record-either)).
  Options `netcup_customer_id` / `netcup_api_key` / `netcup_api_password` —
  another copy of those credentials, beside Traefik's `.env` and Coolify's
  proxy config; accepted. `propagation_seconds: 900`, the value Traefik
  already proved against netcup.
- **Cert paths and port into HA's Network settings.** The add-on writes
  `/ssl/fullchain.pem` + `/ssl/privkey.pem`; its DOCS still say to reference
  them from an `http:` block, which 2026.8 retired — the fields should live in
  *Settings → System → Network* beside the port. Verify on the appliance.
  Port becomes **443**, so the bare name keeps working.
- **The renewal automation.** The add-on is one-shot — it runs
  `certbot certonly --keep-until-expiring` and stops, renewing nothing on its
  own — so a nightly HA automation starts it. Outside certbot's renewal window
  (30 days before expiry) that is a no-op: no ACME traffic, no netcup calls.
  A [timetable.md](../../docs/reference/timetable.md) row for the automation;
  the alarm for silent expiry is the certificate-expiry notification Kuma
  already offers on HTTPS monitors — enable it on `Home Automation` and record
  that in [uptime-kuma-monitors.md](../../docs/reference/uptime-kuma-monitors.md).
- **DNS.** The `ha.` row re-points from `infra ip` to `ha ip` — it keeps its
  exact record, because the wildcard still answers with the apps VM.
  `homeassistant.` is **retired**: its only consumers were Traefik's backend
  dial and Kuma's ping monitor, which re-points at `ha.`. The
  two-names-on-purpose section of
  [dns-records.md](../../docs/reference/dns-records.md#home-assistant-has-two-names-on-purpose)
  comes out; `ha.` becomes another `pve.`-shaped name — one name meaning the
  machine, serving the UI, the scrape and the cert at once.
- **Traefik sheds the file provider.** Delete `dynamic/ha.yaml`, and the
  `--providers.file.*` flags and the read-only mount with it — that router was
  the provider's only user, and a fresh bring-up keeps no vestigial mechanism.
  Labels become the only provider again.
- **Trusted proxies comes out** of HA's Network settings. With it goes the one
  value in the lab that did not follow DNS — and its silent-400 staleness trap
  ([dns-records.md](../../docs/reference/dns-records.md#why-this-registry-holds-no-addresses)).
- **The docs sweep.** `home-assistant-setup.md` step 7 becomes the add-on
  procedure and the troubleshooting matrix loses the 502/loop entries that
  describe a route that no longer exists; `traefik-setup.md` loses its
  file-provider half; both READMEs, CLAUDE.md's topology and DNS-facts
  passages, and the registries move together. Alloy's scrape config is
  untouched — `https://ha.thefipster.de` with the token now simply reaches HA
  directly — but `grafana-setup.md`'s "through Traefik so a broken route
  surfaces" rationale is rewritten: what the scrape now proves is HA's own TLS.

## Recommendation

Clickwork on the appliance plus a wide docs sweep — the only lab-config change
is a deletion. One ordering matters, and it makes the cutover safe: **issue the
certificate first**, while everything still routes through Traefik — DNS-01
neither knows nor cares where `ha.` resolves. Then flip HA to 443 with the cert
paths (this is the moment Traefik's `:80` backend breaks), re-point the `ha.`
row, and delete the route. Each step's undo is the previous step. Drill the
result the same way Vaultwarden's restore is drilled: an already-paired
companion app reconnecting, not a fresh browser.
