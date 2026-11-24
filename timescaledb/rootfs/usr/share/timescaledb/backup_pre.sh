#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: TimescaleDb
# Pre-backup script - dumps all databases before the Home Assistant backup runs.
# The data directory itself is excluded from the backup (backup_exclude), so these
# dumps are what a restore brings back.
#
# Per database a compressed pg_dump (custom format), plus the roles in globals.sql.
# A watchdog stops the dump when the free space on /data drops below
# BACKUP_MIN_FREE_MB, and a failed dump is always removed, so the backup can never
# fill the disk and take PostgreSQL down.
# ==============================================================================
# shellcheck source=/dev/null
source /usr/share/timescaledb/backup_common.sh
# shellcheck source=/dev/null
source /usr/share/timescaledb/pgbackrest_common.sh

declare DUMP_PID=""

removeDump() {
    rm -rf "${BACKUP_DIR}" "${LEGACY_BACKUP_FILE}" "${LEGACY_GZ_BACKUP_FILE}"
}

fail() {
    bashio::log.error "${1}"
    if [[ -n "${DUMP_PID}" ]]; then
        kill "${DUMP_PID}" 2>/dev/null || true
        wait "${DUMP_PID}" 2>/dev/null || true
    fi
    removeDump
    bashio::log.error "The database dump was removed again; this backup does not contain the database."
    exit 1
}

# Runs a dump command in the background and stops it when the disk gets too full
# $@: command
runGuarded() {
    "$@" &
    DUMP_PID=$!
    while kill -0 "${DUMP_PID}" 2>/dev/null; do
        if [[ $(backupFreeSpaceMb) -lt ${BACKUP_MIN_FREE_MB} ]]; then
            fail "Not enough free disk space: stopped the dump to keep at least ${BACKUP_MIN_FREE_MB} MiB free for PostgreSQL."
        fi
        sleep 1
    done
    if ! wait "${DUMP_PID}"; then
        DUMP_PID=""
        return 1
    fi
    DUMP_PID=""
}

bashio::log.info "Starting pre-backup process..."

if ! pg_isready -U postgres -h localhost -p 5432 >/dev/null 2>&1; then
    bashio::log.warning "PostgreSQL is not running. Skipping database dump."
    bashio::log.warning "Note: Only file-level backup will be performed."
    exit 0
fi

# Leftovers of an interrupted backup
removeDump

# With pgBackRest the data is in the repository, not in this backup: the backup holds a pointer to
# it, so a restore knows what to bring back. No dump is made.
if pgbr_enabled; then
    bashio::log.info "pgBackRest is enabled: writing a pointer to the repository instead of a dump."
    # check switches the WAL segment and waits until it is archived, so the moment of this backup is recoverable
    if ! pgbr_run check; then
        bashio::log.error "pgBackRest check failed: this backup would not point to a recoverable database."
        exit 1
    fi
    LABEL="$(pgbr_run info --output=json | jq -r --arg s "$(pgbr_stanza)" '[.[] | select(.name == $s) | .backup[]?] | sort_by(.timestamp.stop) | last | .label // empty')"
    if [[ -z "${LABEL}" ]]; then
        bashio::log.error "There is no backup in the pgBackRest repository yet: this backup would not point to a database."
        exit 1
    fi
    mkdir -p "${PGBR_STATE}"
    jq -n \
        --arg stanza "$(pgbr_stanza)" \
        --arg repo_type "$(pgbr_repo_type)" \
        --arg endpoint "$(pgbr_opt s3_endpoint)" \
        --arg bucket "$(pgbr_opt s3_bucket)" \
        --arg repo_path "$(pgbr_repo_path)" \
        --arg system_id "$(pgbr_system_id)" \
        --arg pg_version "$(pgbr_pg_major)" \
        --arg ts_version "$(psql -X -U postgres -d postgres -tAc "select default_version from pg_available_extensions where name = 'timescaledb'")" \
        --arg label "${LABEL}" \
        --arg lsn "$(psql -X -U postgres -d postgres -tAc 'select pg_current_wal_lsn()')" \
        --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg addon_version "$(bashio::app.version 2> /dev/null || echo unknown)" \
        '{format: 1, stanza: $stanza, repo_type: $repo_type, repo_s3_endpoint: $endpoint, repo_s3_bucket: $bucket,
          repo_path: $repo_path, system_id: $system_id, pg_version: $pg_version, timescaledb_version: $ts_version,
          backup_label: $label, wal_lsn: $lsn, time: $time, addon_version: $addon_version}' \
        > "${PGBR_POINTER}.new"
    mv "${PGBR_POINTER}.new" "${PGBR_POINTER}"
    bashio::log.info "Pointer written to ${PGBR_POINTER} (backup ${LABEL}). Pre-backup process completed."
    exit 0
fi

if [[ $(backupFreeSpaceMb) -lt ${BACKUP_MIN_FREE_MB} ]]; then
    fail "Only $(backupFreeSpaceMb) MiB free on /data, the dump needs to leave at least ${BACKUP_MIN_FREE_MB} MiB free. Free up disk space and try again."
fi

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

bashio::log.info "Dumping roles..."
if ! runGuarded pg_dumpall -U postgres --globals-only -f "${BACKUP_DIR}/globals.sql"; then
    fail "Failed to dump the roles!"
fi

{
    echo "# TimescaleDB add-on backup"
    echo "# $(psql -X -tA -U postgres -d postgres -c 'select version()')"
} > "${BACKUP_DIR}/databases.txt"

INDEX=0
while IFS= read -r database; do
    INDEX=$(( INDEX + 1 ))
    DUMP_FILE="database-${INDEX}.dump"
    bashio::log.info "Dumping database '${database}'..."
    if ! runGuarded pg_dump -U postgres -d "${database}" -Fc --compress=zstd:3 -f "${BACKUP_DIR}/${DUMP_FILE}"; then
        fail "Failed to dump database '${database}'!"
    fi
    # Tab separated: dump file, then the database name as is
    printf '%s\t%s\n' "${DUMP_FILE}" "${database}" >> "${BACKUP_DIR}/databases.txt"
done < <(psql -X -tA -U postgres -d postgres -c "select datname from pg_database where datallowconn and not datistemplate order by datname")

chmod 600 "${BACKUP_DIR}"/*
bashio::log.info "Database dump created in ${BACKUP_DIR}: ${INDEX} database(s), $(du -sh "${BACKUP_DIR}" | cut -f1)"
bashio::log.info "Pre-backup process completed."
