#!/usr/bin/env bash
#
# backup.sh — what the monitoring stack's backup consists of.
#
# Run by infra/backup/run.sh, which stages a directory and snapshots what this
# script declares. Runnable on its own for inspection:
#   sudo BACKUP_STAGE=/tmp/t REPO_ROOT="$PWD" infra/monitoring/backup.sh

set -euo pipefail

# readlink -f is not decoration: /opt/stacks/monitoring is a symlink into the
# checkout, so without it ../backup/lib.sh resolves to /opt/stacks/backup/lib.sh,
# which does not exist. Resolving first makes the script work by either path.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../backup/lib.sh"

# The ONLY directory here worth capturing, out of six under /opt/monitoring.
# The other five are Tier 3 in docs/roadmap/backup.md and their absence is a
# decision, not an oversight:
#
#   prometheus/ loki/ tempo/  observability data with SHORT retention by design
#                             (15 d / 14 d / 7 d). Hauling the TSDB around
#                             nightly is how a backup stops being run.
#   alloy/                    WAL and log positions. Self-healing; restoring it
#                             would only replay stale offsets.
#   grafana/                  file state only — the plugin dir and the renderer
#                             cache. With GF_DATABASE_TYPE: postgres there is no
#                             grafana.db here; the dashboards and datasources are
#                             provisioned from this repo.
#
# Raw PGDATA, and the LAST RESORT only — torn by construction, because it is
# copied from a running server. The dump below is the restore path.
include /opt/monitoring/postgres

# Four values, and one of them is the reason this line matters more than it
# looks. GRAFANA_OIDC_CLIENT_SECRET is regenerable in Authentik in seconds and
# GRAFANA_ADMIN_PASSWORD only applies at first DB init — but
# HA_PROMETHEUS_TOKEN is a long-lived Home Assistant token that HA shows
# EXACTLY ONCE at creation. It cannot be re-read, only re-minted and re-pasted.
# GRAFANA_DB_PASSWORD is also the password the Postgres cluster is initialised
# with, which is why restore.sh empties postgres/ rather than restoring it.
include_env

# THE STACK IS NOT THE DATABASE NAME, and this is the only stack where they
# differ. The directory is `monitoring`; POSTGRES_USER and POSTGRES_DB are both
# `grafana` (compose.yaml). Every other Postgres stack satisfies
# user == db == <directory>, which is what the single-argument form assumes —
# so this is the one caller that needs the overrides. The dump is still named
# after the STACK (monitoring.sql), which is what keeps the restore path
# uniform across stacks.
dump_postgres monitoring db grafana grafana
