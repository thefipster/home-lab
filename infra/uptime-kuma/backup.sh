#!/usr/bin/env bash
#
# backup.sh — what Uptime Kuma's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/uptime-kuma/backup.sh

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/uptime-kuma is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# The whole data directory, in one line, because Kuma keeps everything in it:
# db-config.json (which database Kuma is configured to use — restore without it
# and Kuma greets you with its first-run setup wizard), upload/ and
# screenshots/ (user content), docker-tls/, and the live kuma.db beside its
# -wal and -shm.
#
# That live copy is the LAST RESORT and never the restore path. It is torn by
# construction, and here that is not a theoretical worry: the write-ahead log
# is routinely LARGER than the database file, so a plain copy of kuma.db alone
# would be missing most of the committed state. The dump below is the restore
# path. Same shape as the raw PGDATA in the Postgres stacks, one directory
# wider.
include /opt/uptime-kuma

# No include_env, deliberately. Kuma is the one stack with no `.env` and no
# `.env.example` at all: it runs no database service to hold a password for,
# and its admin account is created through its own first-run web form. There is
# nothing to capture, so this absence is a decision rather than an oversight.

# Kuma's own sqlite3, against Kuma's own database. The service is named
# explicitly because SQLite stacks have no `db` convention the way the Postgres
# ones do — here the service and the stack happen to share a name.
dump_sqlite uptime-kuma uptime-kuma /app/data/kuma.db
