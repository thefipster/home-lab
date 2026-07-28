# Traefik — TLS termination and routing (infra VM)

**Runs on:** infra VM

**Prerequisite:** [wildcard-dns-udr.md](wildcard-dns-udr.md) complete — every
record from [dns-records.md](dns-records.md) resolving, and the repo plus
Docker on the infra VM ([proxmox-setup.md, Part 7](proxmox-setup.md#part-7--repo-and-docker-on-the-infra-and-apps-vms)).

Traefik is the only thing on the infra VM that terminates TLS and routes
traffic. It serves every service on a real hostname under **one wildcard
certificate** (`*.thefipster.de`) from Let's Encrypt, obtained through the
**DNS-01 challenge** against the netcup API — so nothing is exposed to the
internet and there is no internal CA to trust. Other stacks become reachable
by joining the `proxy` network and adding `traefik.*` labels; no central
configuration file lists them.

Nothing is routed yet when this guide finishes, and that is expected — Traefik
comes up first precisely so everything after it has somewhere to be served.

## Steps

### 1. Get netcup API credentials

In the netcup CCP (customer control panel): **Master Data → API** → generate an
**API key** and an **API password**. The **customer number** is the number you
log in with. Confirm the domain still uses netcup's nameservers:

```bash
dig NS thefipster.de +short
```

### 2. Run the init script

```bash
cd ~/home-lab
```

```bash
scripts/init-traefik.sh
```

This creates the shared `proxy` Docker network and the ACME directory
(`/opt/traefik/letsencrypt`), seeds `infra/traefik/.env` from `.env.example`,
and symlinks the stack into `/opt/stacks` for Dockge later.

### 3. Fill in the credentials

Edit `infra/traefik/.env` and set `ACME_EMAIL` plus the three `NETCUP_*`
values from step 1. The file is gitignored — credentials never leave the VM.

```bash
nano ~/home-lab/infra/traefik/.env
```

### 4. Start the stack and watch the first issuance

```bash
cd ~/home-lab/infra/traefik
```

```bash
docker compose up -d
```

```bash
docker compose logs -f traefik
```

> **The wildcard request fires at startup.** The certificate domains are
> declared at the *entrypoint*, so Traefik asks for `*.thefipster.de` the
> moment it starts — no router or routed service has to exist first. Expect
> `Register...` and `Obtaining bundled SAN certificate` right away.

> **First issuance takes 10–15 minutes. This is normal.** netcup publishes new
> TXT records slowly and Let's Encrypt cannot validate until they appear. The
> compose sets a 900-second propagation timeout for exactly this reason — don't
> panic at the quiet log, and **don't restart the container mid-challenge**.
> Renewals run unattended from here; you will never watch this again.

> **`middleware "authentik@docker" does not exist` is expected here.** The
> dashboard router is gated by a middleware Authentik provides, and Authentik
> isn't up yet. The error stops once it is
> ([authentik-setup.md](authentik-setup.md)).

### 5. Verify

Everything below works with **only Traefik running** — no other stack needed.

**The certificate was issued:**

```bash
docker compose exec traefik grep -o '"main": *"[^"]*"' /letsencrypt/acme.json
```

Expect a line mentioning `thefipster.de`.

**It is the real, trusted certificate:**

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername traefik.thefipster.de 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Expect subject `*.thefipster.de`, an issuer naming **Let's Encrypt**, and a
validity window that contains today. (A self-signed `TRAEFIK DEFAULT CERT`
means issuance has not finished — keep watching the log.)

**TLS and routing are wired end to end:**

```bash
curl -Is https://traefik.thefipster.de | head -1
```

Expect **`HTTP/2 404`** — and that 404 *is* the success condition. It proves
the name resolved to this VM, the TLS handshake completed against a publicly
trusted certificate (curl verifies by default; a bad cert would error instead
of returning a status), and Traefik answered. The 404 itself is the dashboard
router refusing to load without Authentik's middleware, exactly as expected at
this point in the build.

**HTTP redirects to HTTPS:**

```bash
curl -Is http://traefik.thefipster.de | head -1
```

Expect `HTTP/1.1 301 Moved Permanently`.

### Checklist

- [ ] `acme.json` names `thefipster.de`
- [ ] `openssl s_client` shows a Let's Encrypt–issued `*.thefipster.de` cert
- [ ] `https://traefik.thefipster.de` → `HTTP/2 404` with **no** TLS warning
- [ ] `http://traefik.thefipster.de` → `301`

## Next

**[authentik-setup.md](authentik-setup.md)** — SSO. It is the first stack
Traefik actually serves, and it provides the forward-auth middleware that
makes the dashboard (and later Dockge) reachable.

## Troubleshooting

**`certificate has expired or is not yet valid` after a Proxmox snapshot
rollback.** The VM clock is stale, not the certificate — a rollback resumes the
guest with its clock frozen at snapshot time, before the cert was issued. See
[proxmox-setup.md, Part 8](proxmox-setup.md#part-8--snapshot-before-you-build);
the immediate fix is:

```bash
sudo chronyc makestep
```

**`did not return the expected TXT record`, with nothing after the colon,
while the record is visible in the CCP.** A resolver negative-cached an empty
answer from a too-early query. This is why the compose points the propagation
check at netcup's **authoritative** nameservers rather than public resolvers —
authoritative servers don't cache, so the check clears the moment netcup
publishes. If you changed the `resolvers` line, change it back.

**`did not return the expected TXT record`, but the error lists *other*
values.** The same-FQDN race: more than one name is being validated at the same
`_acme-challenge` FQDN (e.g. apex + wildcard) and netcup's non-atomic zone
writes clobbered one value. Keep the certificate wildcard-only, as shipped.

**Propagation timeout.** netcup was slower than 15 minutes. Raise
`NETCUP_PROPAGATION_TIMEOUT` (e.g. `1800`) in the compose file and recreate.
Confirm the domain really is on netcup nameservers with `dig NS`.

**Authentication errors mentioning the netcup API.**

```bash
docker compose logs traefik | grep -i acme
```

Customer number, API key or API password mismatch. Regenerate the API password
in the CCP if unsure — it is shown only once.

**Issuance keeps failing.** Don't hammer production: it allows roughly 5 failed
validations per hostname per hour and 5 duplicate certificates per week.
Uncomment the staging `caserver` line in `infra/traefik/compose.yaml` and debug
under its loose limits (certificates will be untrusted — that's fine for
debugging). Switching CAs in either direction means discarding the account and
certificate store:

```bash
sudo rm /opt/traefik/letsencrypt/acme.json
```

```bash
docker compose up -d --force-recreate
```

**A service 404s even though its stack is up.** Its container isn't on the
`proxy` network, or its `traefik.*` labels are wrong:

```bash
docker network inspect proxy
```

Traefik and the service should both be listed.

## Layout on the server

| What | Where |
|------|-------|
| Compose project (this repo) | `infra/traefik/` |
| Credentials | `infra/traefik/.env` — gitignored, VM-only |
| Dynamic routers (this repo) | `infra/traefik/dynamic/` — mounted read-only; watched, so edits apply without a restart |
| ACME account + certificates | `/opt/traefik/letsencrypt/acme.json` |
| Shared network | the external Docker network `proxy` |

`acme.json` is the only state. Back it up if you like, but losing it costs only
one re-issuance.

## How it works

**Why nothing is exposed.** The DNS-01 challenge proves domain control by
publishing a temporary `_acme-challenge` TXT record in *public* DNS. No inbound
connection is ever made to the lab, so ports 80 and 443 stay reachable only
from the LAN. Traefik's ACME client drives the netcup API to create and delete
those records itself, at first issuance and at every renewal, forever.

**Split-horizon DNS.** The public netcup zone holds no A records for the lab;
the UniFi router answers the lab's names locally
([wildcard-dns-udr.md](wildcard-dns-udr.md)). Publicly the names resolve to
nothing. The only fingerprint visible to the internet is the Certificate
Transparency entry for `*.thefipster.de` — and a wildcard keeps the individual
hostnames private.

**One wildcard, no per-router TLS.** The certificate domains are declared once,
on the `websecure` entrypoint, so every `websecure` router is covered
automatically. When adding a service, copy the label block from
`infra/forgejo` or `infra/dockge` and change the host and port — **never** add
a TLS resolver or domain per router.

**Two providers, and the second one is the exception.** Almost everything is
routed by **labels**: a stack joins the `proxy` network and Traefik reads its
`traefik.*` labels off the Docker API. That stays the default for anything
running on this VM. But labels only exist where there is a container to put them
on, and Home Assistant runs on its **own VM** — so Traefik also runs a **file
provider** over `infra/traefik/dynamic/`, mounted read-only and watched, where a
router can be declared by hand. `ha.yaml` is currently its only file. Routers
declared there are ordinary `websecure` routers: the entrypoint wildcard covers
them, so the no-per-router-TLS rule applies to them identically. Reach for a
file only when the backend is not a container on this machine.

**No apex SAN, deliberately.** Apex + wildcard would need two TXT records at
the same `_acme-challenge` FQDN, and netcup's non-atomic zone updates race on
that: one value clobbers the other and validation times out. Nothing is served
at the bare apex anyway.

**Straight to production.** First bring-up targets the production CA — one
challenge total. Staging exists only as a commented `caserver` line for
debugging repeated failures under looser rate limits.

**The dashboard is gated, not public.** `--api.dashboard=true` is on, but the
router carries `middlewares: authentik@docker`. Never serve it without that.

## Apps VM, later (Coolify)

Coolify bundles its own Traefik. Give that proxy the same three `NETCUP_*`
variables and the same wildcard-only DNS-01 configuration; it issues and renews
its **own** certificate, independent of this VM. No certificates are ever
copied between machines. The DNS side is already done —
`*.thefipster.de` points at the apps VM, so every app Coolify deploys gets a
working HTTPS hostname with no new DNS records.

## Escape hatch: if netcup propagation becomes unbearable

Delegate just the challenge record: `CNAME _acme-challenge.thefipster.de` to a
zone on a fast ACME-oriented service (acme-dns, deSEC). Traefik's ACME client
follows the CNAME and updates the fast zone instead, while netcup keeps serving
everything else. Documented as an option only — not built, and with renewals
running unattended you are unlikely to need it.

## Next

**[authentik-setup.md](authentik-setup.md)** — SSO, and the first stack served
through this proxy. The full sequence is in the
[README build order](../README.md#build-order).
