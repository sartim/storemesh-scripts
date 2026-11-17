#!/usr/bin/env bash
set -euo pipefail

: "${STOREMESH_SOURCE_DATABASE_URL:?STOREMESH_SOURCE_DATABASE_URL is required}"
: "${STOREMESH_RESTORE_DATABASE_URL:?STOREMESH_RESTORE_DATABASE_URL is required}"

backup_file="$(mktemp -t storemesh-postgres-backup.XXXXXX.dump)"
cleanup() { rm -f "${backup_file}"; }
trap cleanup EXIT

pg_dump --format=custom --no-owner --no-privileges \
  --file="${backup_file}" "${STOREMESH_SOURCE_DATABASE_URL}"
pg_restore --clean --if-exists --no-owner --no-privileges \
  --dbname="${STOREMESH_RESTORE_DATABASE_URL}" "${backup_file}"

check_sql="${STOREMESH_RESTORE_CHECK_SQL:-SELECT 1;}"
psql --no-psqlrc --quiet --tuples-only --no-align \
  "${STOREMESH_RESTORE_DATABASE_URL}" --command="${check_sql}" >/dev/null

echo "PostgreSQL backup and restore rehearsal passed."
