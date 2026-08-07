#!/usr/bin/env bash
#
# backup.sh — what Traefik's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/traefik/backup.sh
#
# The smallest backup in the lab, and the one where almost nothing needs
# backing up — which is the point worth understanding rather than a sign
# something was missed. Traefik's routing is LABELS on other stacks' containers
# and files under infra/traefik/dynamic/, all of which are in git. Its
# entrypoints and the wildcard request are in the compose. None of that can be
# lost. What cannot be regenerated from this repo is exactly two things.

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/traefik is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# acme.json: the Let's Encrypt ACCOUNT KEY and the issued wildcard certificate,
# with its private key. Both are reissuable, so this is not irreplaceable the
# way the vault is — but reissuing is not free either. netcup's DNS-01
# propagation runs ~10–15 minutes per attempt, and Let's Encrypt's
# duplicate-certificate limit is 5 per week, so a reissue loop that goes wrong
# locks the lab out of TLS for days rather than minutes. Restoring the file is
# seconds.
#
# It also contains a private key, which is the reason this repository is
# encrypted at all rather than merely off-machine.
include /opt/traefik/letsencrypt

# The netcup API credentials, and the one thing here this repo genuinely cannot
# regenerate: they belong to an external account. Without them Traefik cannot
# answer a DNS-01 challenge at all, so a lost .env is a lab that can never
# renew — the failure surfaces up to 90 days later, when the restored
# certificate expires and nothing can replace it.
include_env

# No dump: Traefik has no database. This is the include-only form.
