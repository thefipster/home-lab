#!/usr/bin/env bash
#
# backup.sh — what Homepage's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/homepage/backup.sh
#
# One recipe and no dump, which is the whole story of this stack: there is no
# database, no /opt directory, and the entire configuration — the compose and
# every file under config/ — is tracked in this repo. Snapshotting any of that
# would be snapshotting a clone.
#
# What is NOT in the clone is the .env, and it is not regenerable either: every
# value in it is a credential minted by hand in another service. Losing it does
# not lose data, but it does mean clicking through docs/homepage-widgets.md
# again in Authentik, Forgejo and Grafana.

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/homepage is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# The HOMEPAGE_VAR_* widget credentials. include_env resolves against
# $REPO_ROOT rather than /opt/stacks, because restic stores a symlink as a
# symlink instead of descending into it.
include_env
