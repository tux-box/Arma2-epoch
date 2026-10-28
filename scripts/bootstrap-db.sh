#!/usr/bin/env bash
#
# Prepares the MySQL/MariaDB hive database for DayZ / DayZ Epoch.
#
# Both mods store all player and world state in a database through HiveExt.dll.
# HiveExt cannot create its own schema, so this script waits for the database,
# creates it if needed and imports the mod's SQL files exactly once (the first
# time the database is empty).
set -Eeuo pipefail

log()  { printf '[db] %s\n' "$*"; }
warn() { printf '[db] WARNING: %s\n' "$*" >&2; }
die()  { printf '[db] ERROR: %s\n' "$*" >&2; exit 1; }

PROFILE="${1:-none}"
ARMA_DIR="${ARMA_DIR:-/arma2}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-dayz_epoch}"
DB_USER="${DB_USER:-dayz}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_BOOTSTRAP_USER="${DB_BOOTSTRAP_USER:-root}"
DB_BOOTSTRAP_PASSWORD="${DB_BOOTSTRAP_PASSWORD:-${DB_ROOT_PASSWORD:-}}"
DB_WAIT_SECONDS="${DB_WAIT_SECONDS:-180}"
DB_SCHEMA="${DB_SCHEMA:-}"     # auto-detected from the installed pack when empty

[ -n "${DB_HOST}" ] || die "DB_HOST is not set"
command -v mysql >/dev/null || die "mysql client not found in the image"

admin=(mysql -h "${DB_HOST}" -P "${DB_PORT}" --connect-timeout=5)
if [ -n "${DB_BOOTSTRAP_PASSWORD}" ]; then
    admin+=(-u "${DB_BOOTSTRAP_USER}" -p"${DB_BOOTSTRAP_PASSWORD}")
else
    admin+=(-u "${DB_BOOTSTRAP_USER}")
fi

# The database container may still be starting.
deadline=$((SECONDS + DB_WAIT_SECONDS))
until "${admin[@]}" -e 'SELECT 1' >/dev/null 2>&1; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
        die "database ${DB_HOST}:${DB_PORT} not reachable after ${DB_WAIT_SECONDS}s"
    fi
    sleep 2
done
log "database ${DB_HOST}:${DB_PORT} is up"

"${admin[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`" \
    || die "cannot create database ${DB_NAME}"
# Makes the hive user work even when DB_NAME differs from the container's
# MYSQL_DATABASE. Harmless when the grants already exist.
"${admin[@]}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%'" >/dev/null 2>&1 \
    || warn "could not grant privileges to '${DB_USER}' (only needed if DB_NAME differs from MYSQL_DATABASE)"

tables="$("${admin[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" 2>/dev/null || echo 0)"
if [ "${tables}" -gt 0 ]; then
    log "database ${DB_NAME} already has ${tables} tables, not importing the schema again"
    exit 0
fi

if [ -n "${DB_SCHEMA}" ]; then
    schema="${DB_SCHEMA}"
else
    # Pick the schema belonging to this profile: both packs keep their files in
    # the same directory, so a left-over epoch.sql must not be used for DayZ.
    schema=""
    case "${PROFILE}" in
        epoch) names=(epoch.sql) ;;
        dayz)  names=(dayz.sql hive.sql dayz_hive.sql) ;;
        *)     names=() ;;
    esac
    for name in "${names[@]}"; do
        found="$(find "${ARMA_DIR}" -maxdepth 4 -type f -iname "${name}" -print -quit 2>/dev/null || true)"
        [ -n "${found}" ] && { schema="${found}"; break; }
    done
    if [ -z "${schema}" ]; then
        while IFS= read -r found; do
            case "${found,,}" in
                *epoch*) continue ;;
                *recommended*|*update*) continue ;;
            esac
            schema="${found}"
            break
        done < <(find "${ARMA_DIR}" -maxdepth 4 -type f -iname '*.sql' 2>/dev/null)
    fi
fi
if [ -z "${schema}" ] || [ ! -f "${schema}" ]; then
    # A plain Arma 2 server has no hive; a mod profile cannot work without one.
    case "${PROFILE}" in
        dayz|epoch) die "no schema .sql file found in ${ARMA_DIR}; the ${PROFILE} hive needs it (set DB_SCHEMA=/path/to/hive.sql)" ;;
        *)          log "no hive schema found, nothing to import" ; exit 0 ;;
    esac
fi

log "importing schema ${schema} into ${DB_NAME}"
"${admin[@]}" "${DB_NAME}" < "${schema}" || die "schema import failed"

# Only the events shipped alongside the chosen schema belong to this hive.
extra_events="$(dirname "${schema}")/add_recommended_mysql_events.sql"
if [ -f "${extra_events}" ]; then
    log "importing ${extra_events}"
    "${admin[@]}" "${DB_NAME}" < "${extra_events}" || warn "import of ${extra_events} failed"
fi

# Epoch's recommended events (spawn/cleanup jobs) only run with the scheduler on.
"${admin[@]}" -e 'SET GLOBAL event_scheduler = ON' >/dev/null 2>&1 \
    || warn "could not enable the MySQL event scheduler (needs SUPER privileges)"

tables="$("${admin[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" 2>/dev/null || echo 0)"
log "database ${DB_NAME} ready with ${tables} tables"
