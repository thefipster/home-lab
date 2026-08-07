#!/usr/bin/env bash
#
# backup.sh — what Vaultwarden's backup consists of.
#
# THIS IS THE ONE THAT CANNOT BE REBUILT FROM ANYTHING ELSE. Every other stack
# here is painful to lose; the vault is where the credentials for repairing all
# of them are kept, so a loss has no other recovery path — including the path
# you would use to recover from losing it.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/vaultwarden/backup.sh

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/vaultwarden is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# THE COUPLING THIS WHOLE PER-STACK DESIGN EXISTS FOR, in its sharpest form.
#
# `rsa_key.pem` lives in here and signs every access token the server issues;
# the database below holds what those tokens address. Restore one without the
# other and every client is logged out of a vault it can no longer prove
# anything against — a working server, an intact database, and no way in. The
# two are one unit, and this snapshot is what keeps them together.
#
# Also in here: attachments, Sends, the icon cache, and `config.json` — the
# settings the /admin page writes, which OVERRIDE the compose environment. A
# restore without it silently reverts every choice made through that page.
include /opt/vaultwarden/data

# Raw PGDATA, and the LAST RESORT only — torn by construction, because it is
# copied from a running server. The dump below is the restore path.
include /opt/vaultwarden/postgres

# Two values, and both are couplings rather than conveniences.
# VAULTWARDEN_DB_PASSWORD is the password the Postgres cluster was initialised
# with, which is why restore.sh empties postgres/ rather than restoring it.
# VAULTWARDEN_ADMIN_TOKEN is an Argon2id PHC string and the only value in this
# repo that MUST stay single-quoted — Compose interpolates unquoted values, so
# every `$`-segment would be expanded away, leaving an /admin page that rejects
# the password that generated it while the container starts perfectly happily.
# Restoring the file byte-for-byte is what preserves that; hand-retyping it is
# what breaks it.
include_env

# Single-argument form: service `db`, POSTGRES_USER == POSTGRES_DB ==
# `vaultwarden`, like every Postgres stack here except monitoring.
dump_postgres vaultwarden
