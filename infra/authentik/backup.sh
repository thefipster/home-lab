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

# ORDER MATTERS, AND THIS IS THE TEMPLATE THE OTHER SIX STACKS COPY.
#
# Files first, dump LAST. `include` only writes a line into paths.txt — it
# copies nothing — so declaring the files costs nothing and makes them survive
# a failure further down. Under `set -e` a failing dump_postgres aborts this
# script; with the dump first, paths.txt would still be empty at that point and
# run.sh would have nothing to snapshot, so a broken database would cost
# Authentik its files AND its .env as well. In this order the runner sees a
# non-empty paths.txt, takes a DEGRADED snapshot (files present, no dump) and
# still records the stack as failed. See the matching comment in
# infra/backup/run.sh.
#
# It is also what makes the raw PGDATA below more than decoration: the one
# state it exists for — "no dump" — is precisely the state this ordering keeps
# snapshottable.

include /opt/authentik/data       # uploads, branding, flow backgrounds
include /opt/authentik/templates
include /opt/authentik/certs      # signing keypairs created in the UI

# The raw PGDATA, as a LAST RESORT only. A live-copied data directory is torn by
# construction, so the restore path is always authentik.sql below — this is for
# the case where no dump exists, which a degraded snapshot is exactly how you
# get. Kept because it costs little for a database this size; it is the first
# thing to reconsider if snapshots get expensive.
include /opt/authentik/postgres

# AUTHENTIK_SECRET_KEY decrypts secrets held in the database dumped below. That
# database restored WITHOUT this file is a database full of undecryptable
# values — the two are one unit, and this line is what keeps them in one
# snapshot. Same shape as Vaultwarden's rsa_key.pem, one directory apart.
include_env

# Last, because it is the only step that can fail on its own.
dump_postgres authentik
