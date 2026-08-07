#!/usr/bin/env bash
#
# lib.sh — the backup recipes, sourced by every infra/<stack>/backup.sh.
#
# Contract with infra/backup/run.sh:
#   in   BACKUP_STAGE  this stack's staging dir — the runner creates and empties it
#        REPO_ROOT     the repo checkout root
#   out  dump files in $BACKUP_STAGE, and one absolute path per line in
#        $BACKUP_STAGE/paths.txt, which is the ONLY thing restic is given.
#
# paths.txt is written INCREMENTALLY, and that is load-bearing: a stack script
# that aborts partway leaves everything it declared before the failure, and
# run.sh snapshots that as a DEGRADED snapshot rather than skipping the stack.
# Hence the rule every backup.sh follows — declare the file includes first, run
# the dump last.
#
# Stack scripts are EXECUTED, not sourced, so one can be run on its own:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/authentik/backup.sh
# produces a directory you can look at — no repository, no password, no network.
#
# No `set -euo pipefail` here: the calling script sets it and a sourced file
# inherits it. Setting it again would be a second place to keep in sync.

: "${BACKUP_STAGE:?BACKUP_STAGE is not set — run this through infra/backup/run.sh}"
: "${REPO_ROOT:?REPO_ROOT is not set — run this through infra/backup/run.sh}"

# BASH_SOURCE[1] is the script that sourced us; its directory name is the stack.
# readlink -f first, because /opt/stacks/<stack> is a symlink into the checkout.
STACK="$(basename "$(dirname "$(readlink -f "${BASH_SOURCE[1]}")")")"

mkdir -p "$BACKUP_STAGE"
: > "$BACKUP_STAGE/paths.txt"

# include <path> — declare a path for restic to snapshot.
#
# Copies nothing. restic reads the live tree, which is both faster and better
# for deduplication than staging a copy would be. A missing path is an error,
# not a warning: under the caller's `set -e` it aborts the stack, and the runner
# records that stack as failed. A backup quietly missing a directory is worse
# than a backup that says it failed.
include() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo "  ! include: $path does not exist" >&2
    return 1
  fi
  printf '%s\n' "$path" >> "$BACKUP_STAGE/paths.txt"
}

# include_env — sugar for this stack's gitignored .env.
#
# It comes from the CHECKOUT, never from /opt/stacks/<stack>, which is a symlink
# restic would store as a symlink rather than descend into.
include_env() {
  include "${REPO_ROOT}/infra/${STACK}/.env"
}

# dump_postgres <stack> [service] [user] [db]
#
# Dumps through the stack's own db container, so the client version always
# matches the server. The single-argument form works because all four Postgres
# stacks are uniform: service `db`, POSTGRES_USER == POSTGRES_DB == <stack>.
dump_postgres() {
  local stack="$1"
  local service="${2:-db}"
  local user="${3:-$stack}"
  local db="${4:-$stack}"
  local out="${BACKUP_STAGE}/${stack}.sql"

  # --format=plain, NOT -Fc. A compressed dump changes in its entirety when a
  # single row changes, which defeats restic's content-defined chunking. Plain
  # SQL deduplicates across nightly runs, and restic compresses it at rest
  # anyway (--compression auto, default since 0.14) — so plain text costs
  # nothing in stored size and buys most of the dedup.
  #
  # --clean --if-exists so the dump loads into a live database rather than
  # requiring a hand-dropped one.
  ( cd "${REPO_ROOT}/infra/${stack}" \
    && docker compose exec -T "$service" \
         pg_dump --username="$user" --format=plain --clean --if-exists "$db" ) \
    > "${out}.part"

  # Rename only after pg_dump exited 0, so a truncated dump is never mistaken
  # for a good one by the next run — or by a restore.
  mv -f "${out}.part" "$out"

  include "$out"
}
