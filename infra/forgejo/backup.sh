#!/usr/bin/env bash
#
# backup.sh — what Forgejo's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/forgejo/backup.sh
#
# This is the BIGGEST snapshot of the set, and the only one that grows without
# bound: the container-registry blobs under data/ are never expired by anything
# today. restic deduplicates repeated image layers well, but it cannot delete
# what the registry never removes — so registry hygiene, not restic, is the
# lever on the size of this repository.

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/forgejo is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# Forgejo's whole state, and it is carrying three couplings with the database
# dumped below — all three fail quietly rather than loudly:
#
#   - CONTAINER-REGISTRY BLOBS live here; their package metadata lives in the
#     database. Blobs without the metadata are unaddressable garbage, and
#     metadata without the blobs is a registry that lists images it cannot
#     serve. The apps VM pulls from this, so it is not a developer convenience.
#   - app.ini holds the instance's SECRET_KEY, INTERNAL_TOKEN and JWT secrets.
#     Restored against a different database they decrypt nothing — the same
#     shape as Authentik's AUTHENTIK_SECRET_KEY, one file deeper.
#   - The SSH HOST KEYS are in here too. Lose them and every client that has
#     ever pushed over SSH refuses to connect with "REMOTE HOST IDENTIFICATION
#     HAS CHANGED" until its known_hosts is edited by hand.
#
# The git repositories themselves are the one part that could be rebuilt — they
# are pull-mirrors of GitHub — but nothing else here can be.
include /opt/forgejo/forgejo

# Tier 2, and one small file is the whole reason: .runner holds the runner's
# registration. Re-registering is not hard, but it needs a fresh token minted
# in the Forgejo UI, which is a manual step during an incident. config.yml
# beside it is bind-mounted read-only from this repo and is already in git.
include /opt/forgejo/runner

# Raw PGDATA, and the LAST RESORT only — torn by construction, because it is
# copied from a running server. The dump below is the restore path.
include /opt/forgejo/postgres

# FORGEJO_DB_PASSWORD is the password the Postgres cluster was initialised
# with, which is why restore.sh empties postgres/ rather than restoring it.
#
# DOCKER_GID is the one value in this repo that is MACHINE-SPECIFIC rather than
# secret: scripts/init-forgejo.sh reads it from `getent group docker` on the VM
# it runs on. It is captured because the file is captured, but on a rebuilt VM
# the docker group can land on a different gid — so restore.sh compares the
# restored value against the live one and says so rather than leaving a runner
# that cannot reach the socket.
include_env

# Single-argument form: service `db`, POSTGRES_USER == POSTGRES_DB ==
# `forgejo`, like every Postgres stack here except monitoring.
dump_postgres forgejo
