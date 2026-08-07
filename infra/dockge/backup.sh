#!/usr/bin/env bash
#
# backup.sh — what Dockge's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/dockge/backup.sh
#
# The smallest backup in the set — kilobytes — and the only one whose stack is
# NOT symlinked into /opt/stacks. scripts/init-dockge.sh COPIES the compose to
# /opt/stacks/dockge/ and writes a .env beside it, so this script exists only
# in the checkout and can only be run from there. That difference is also why
# restore.sh is narrow; see the header there.

set -euo pipefail

# readlink -f is kept for consistency with the other stack scripts. Unlike them
# it changes nothing here, because there is no /opt/stacks/dockge/backup.sh to
# be invoked through — only the compose is copied over.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# Dockge's own state: its user accounts, and the metadata for the stacks it
# manages. Tier 2 — it is re-creatable by making the account again through
# Dockge's first-run form, and the stacks themselves are symlinks it merely
# lists. Included because it is kilobytes and skipping it would save nothing.
#
# Note the path: /opt/stacks/dockge, not /opt/dockge. Dockge lives inside the
# directory it manages, so that it manages itself too.
include /opt/stacks/dockge/data

# No include_env, deliberately. There IS a /opt/stacks/dockge/.env, but it
# holds exactly REPO_DIR=… and scripts/init-dockge.sh rewrites it on every run
# — no secret, nothing to lose. There is no .env in the checkout at all, which
# is what include_env would have looked for.

# No dump: Dockge has no database. This is the include-only form.
