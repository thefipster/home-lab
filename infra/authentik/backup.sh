#!/usr/bin/env bash
#
# backup.sh — what Authentik's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/authentik/backup.sh

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/authentik is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

dump_postgres authentik

include /opt/authentik/data       # uploads, branding, flow backgrounds
include /opt/authentik/templates
include /opt/authentik/certs      # signing keypairs created in the UI

# The raw PGDATA, as a LAST RESORT only. A live-copied data directory is torn by
# construction, so the restore path is always authentik.sql above — this is for
# the case where no dump exists. Kept because it costs little for a database
# this size; it is the first thing to reconsider if snapshots get expensive.
include /opt/authentik/postgres

# AUTHENTIK_SECRET_KEY decrypts secrets held in the database dumped above. That
# database restored WITHOUT this file is a database full of undecryptable
# values — the two are one unit, and this line is what keeps them in one
# snapshot. Same shape as Vaultwarden's rsa_key.pem, one directory apart.
include_env
