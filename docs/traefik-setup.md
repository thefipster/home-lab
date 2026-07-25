# Traefik + Let's Encrypt via netcup DNS-01 (infra VM)

Terminates TLS for every infra-VM service on real domain names —
`git.thefipster.de` (Forgejo web + registry) and `dockge.thefipster.de` — with
one **wildcard certificate** (`*.thefipster.de`) from Let's Encrypt. The
wildcard is deliberately the *only* name on the cert — no apex SAN: apex +
wildcard would need two TXT records at the same `_acme-challenge` FQDN, and
netcup's non-atomic zone updates race on that (one value clobbers the other
and validation times out). Nothing is served at the bare apex anyway. See the [main README](../README.md) for how this fits into the wider
homelab.

## How it works (and why nothing is exposed)

The **DNS-01 challenge** proves domain control by publishing a temporary
`_acme-challenge` TXT record in public DNS — no inbound connectivity needed, so
the lab stays LAN-only with ports 80/443 reachable only from your own network.
Traefik's ACME client has a built-in `netcup` provider: it creates and deletes
the TXT records through the netcup DNS API automatically, at first issuance and
at every renewal, forever.

The public netcup zone never holds A records for the lab. Name resolution is
**split-horizon**: the UniFi router answers `git.thefipster.de` → `192.168.1.41`
locally (see [wildcard-dns-udr.md](wildcard-dns-udr.md)); publicly the name
resolves to nothing. The only lab fingerprint visible to the internet is the
Certificate Transparency log entry for `*.thefipster.de` — wildcards keep the
individual hostnames private.

One Traefik per VM: this stack serves the infra VM. The apps VM (Coolify) will
run its own proxy with its own wildcard cert later — see
[Apps VM](#apps-vm-later-coolify) below. No certs are copied between machines.

## Prerequisites

- The domain uses **netcup's nameservers** (it does, unless you've delegated it
  away — check with `dig NS thefipster.de +short`).
- **netcup API credentials**: log in to the CCP (customer control panel) →
  **Master Data → API** → generate an **API key** and an **API password**. The
  **customer number** is the number you log in to the CCP with.
- The **local DNS records** from [wildcard-dns-udr.md](wildcard-dns-udr.md) are
  in place (`git`/`dockge` → `.41`, wildcard → `.42`).
- Docker is installed on the infra VM (`scripts/init-host.sh`).

## Bring-up

From the repo checked out on the infra VM:

```bash
scripts/init-traefik.sh
```

This creates the shared `proxy` Docker network, the persistent ACME dir
(`/opt/traefik/letsencrypt`), seeds `infra/traefik/.env` from `.env.example`,
and links the stack into `/opt/stacks` for Dockge.

Then:

1. Edit `infra/traefik/.env` — set `ACME_EMAIL` and the three netcup values.
   The file is gitignored; credentials never leave the VM.
2. Start the stack and watch the first issuance:

   ```bash
   cd infra/traefik
   docker compose up -d
   docker compose logs -f traefik
   ```

> **No cert request until a service needs one.** Traefik requests certificates
> when a *router* demands TLS, and routers only exist once a labeled container
> (Dockge, Forgejo) is running on the `proxy` network. With Traefik up alone,
> the log stops after `Testing certificate renew...` and stays idle — that's
> expected. Bring up the Dockge stack and the wildcard request fires
> immediately.

> **First issuance takes 10–15 minutes. This is normal.** netcup's nameservers
> are slow to publish new records, and Let's Encrypt can't validate the
> challenge until they have. The compose file sets
> `NETCUP_PROPAGATION_TIMEOUT=900` / `NETCUP_POLLING_INTERVAL=30` for exactly
> this reason — don't panic at the quiet log, and don't restart the container
> mid-challenge. Renewals (every ~60 days) run unattended; you'll never watch
> this again.

## Staging → production

The compose file ships pointing at **production** (the lab's live config),
with the staging CA available as a commented-out `acme.caserver` line. On a
fresh machine, **uncomment the staging line for the first bring-up**: staging
certs are untrusted by browsers but have very generous rate limits — perfect
for proving the netcup credentials and propagation timing without risk.

**1. Verify the staging cert arrived.** In the logs, look for the certificate
being obtained; then:

```bash
docker compose exec traefik grep -o '"main": *"[^"]*"' /letsencrypt/acme.json
curl -kIs https://git.thefipster.de | head -1
```

`acme.json` should mention `thefipster.de`, and the `curl` (with `-k`, since
staging is untrusted) should return an HTTP status. You can also check the
issuer: `openssl s_client -connect git.thefipster.de:443 </dev/null 2>/dev/null | openssl x509 -noout -issuer`
— it will say `(STAGING) Let's Encrypt`.

**2. Switch to production.** Re-comment the `caserver` line in
`infra/traefik/compose.yaml`, wipe the staging state, and recreate:

```bash
sudo rm /opt/traefik/letsencrypt/acme.json
docker compose up -d --force-recreate
docker compose logs -f traefik
```

Wait for issuance again (same 10–15 min), then confirm — no `-k` this time:

```bash
curl -Is https://git.thefipster.de | head -1
```

A clean `HTTP/2 200` (or `303` to the login page) with no TLS warning means
you're done.

## Verification checklist

- [ ] `curl -I https://git.thefipster.de` — succeeds, production Let's Encrypt cert
- [ ] `curl -I https://dockge.thefipster.de` — same
- [ ] `docker login git.thefipster.de` works from a machine with **zero** Docker
      daemon config — no `insecure-registries` anywhere, on any host
- [ ] `http://git.thefipster.de` redirects to `https://`

## Troubleshooting

- **`did not return the expected TXT record` with NOTHING after the colon,
  while the record is visible in the CCP** — a resolver negative-cached an
  empty answer from a too-early query (typical after a failed order deleted
  and re-created the record). This is why the compose points the propagation
  check at netcup's **authoritative** nameservers
  (`root-dns`/`second-dns`/`third-dns.netcup.net`) instead of public
  resolvers: authoritative servers don't cache, so the check clears the
  moment netcup publishes. If you changed the `resolvers` line, change it
  back.
- **Propagation timeout in the logs** — netcup was even slower than 15 minutes.
  Raise `NETCUP_PROPAGATION_TIMEOUT` (e.g. `1800`) in the compose file and
  recreate. Also confirm the domain really is on netcup NS:
  `dig NS thefipster.de +short`.
- **`did not return the expected TXT record` but the error lists *other*
  values** — the resolver can see TXT records at `_acme-challenge`, just not
  the expected one. This is the same-FQDN race: the cert requested more than
  one name validated at the same challenge FQDN (e.g. apex + wildcard), and
  netcup's non-atomic zone writes clobbered one value. Keep the cert
  wildcard-only (the shipped config), or if you truly need the apex, expect
  retries.
- **Auth errors mentioning the netcup API** (`docker compose logs traefik | grep -i acme`) —
  customer number / API key / API password mismatch. Regenerate the API
  password in the CCP if unsure; it's only shown once.
- **Rate limits** — only relevant on the production CA (≈5 duplicate certs per
  week). The staging-first flow exists so you hit production exactly once,
  working. If you do get limited, wait a week or go back to staging to debug.
- **Cert renews but a service 404s** — the service's container isn't on the
  `proxy` network or its `traefik.*` labels are wrong; `docker network inspect
  proxy` should list traefik + the service.

## Apps VM later (Coolify)

Coolify bundles its own Traefik. When you install it on the apps VM, give that
proxy the same three `NETCUP_*` variables and the same wildcard-only
(`*.thefipster.de`) DNS-01 configuration — it issues and
renews its **own** cert, independent of the infra VM. The DNS side is already
done: `*.thefipster.de` points at `.42`, so every app Coolify deploys gets a
working HTTPS hostname with zero DNS work.

## Escape hatch: if netcup propagation ever becomes unbearable

The slow first issuance is a one-time cost per machine, but if it ever matters:
delegate just the challenge record via CNAME —
`_acme-challenge.thefipster.de` → a zone on a fast ACME-oriented DNS service
(acme-dns, deSEC). Traefik/lego follows the CNAME and updates the fast zone
instead; netcup keeps serving everything else. Documented as an option only —
not built, and with renewals running unattended you're unlikely to need it.
