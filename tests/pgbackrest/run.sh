#!/usr/bin/env bash
# Tests of the optional pgBackRest integration, against the add-on image in standalone mode
# (plain Docker, options in /data/options.json) and a SeaweedFS S3 repository.
#
#   IMAGE=<image under test> UPSTREAM_IMAGE=<same add-on without the feature> ./run.sh [case numbers]
#
# Needs docker, docker compose and jq. Cases build on each other: 4 and 6 restore from the
# repository that case 2 filled, so run case 2 first (the default is all cases, in order).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:?set IMAGE to the add-on image under test}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pgbr-test.XXXXXX")"
export PGBR_TEST_CERTS="${WORK}/certs"
NET=pgbr-test
S3_ENDPOINT=s3:9000
S3_BUCKET=pgbr
S3_KEY=testkey
S3_SECRET=testsecretkey
FAILED=0
PASSED=0
STARTED=()

log() { printf '\n== %s\n' "$*"; }

check() { # description, command...
    local desc="${1}"; shift
    local out
    if out="$("$@" 2>&1)"; then
        PASSED=$(( PASSED + 1 )); printf '  ok    %s\n' "${desc}"
    else
        FAILED=$(( FAILED + 1 )); printf '  FAIL  %s\n' "${desc}"
        printf '%s\n' "${out}" | head -15 | sed 's/^/          /'
    fi
}

wait_for() { # seconds, description, command...
    local limit="${1}" desc="${2}"; shift 2
    local waited=0
    until "$@" > /dev/null 2>&1; do
        sleep 2; waited=$(( waited + 2 ))
        if (( waited >= limit )); then
            FAILED=$(( FAILED + 1 )); printf '  FAIL  %s (waited %ss)\n' "${desc}" "${limit}"
            return 1
        fi
    done
    PASSED=$(( PASSED + 1 )); printf '  ok    %s\n' "${desc}"
}

cleanup() {
    [[ -z "${KEEP:-}" ]] || { echo "KEEP set: containers and ${WORK} left in place"; return; }
    docker ps -aq --filter "label=pgbr-test" | while read -r c; do docker rm -f "${c}" > /dev/null 2>&1; done
    docker compose -f "${HERE}/compose.yaml" down -v > /dev/null 2>&1
    docker volume ls -q --filter "label=pgbr-test" | while read -r v; do docker volume rm "${v}" > /dev/null 2>&1; done
    # The data belongs to the postgres user of the add-on, so it is removed from inside a container
    docker run --rm -v "${WORK}:/w" alpine find /w -mindepth 1 -delete > /dev/null 2>&1
    rmdir "${WORK}" 2> /dev/null || true
}
trap cleanup EXIT

# ---- helpers ----------------------------------------------------------------

# Options of the add-on: the pgbackrest block given as JSON ($2), on top of the usual ones
write_options() { # data dir, pgbackrest JSON
    jq -n --argjson p "${2}" '{databases: ["homeassistant"], timescale_enabled: [], max_connections: 50,
        timescaledb: {telemetry: "off"}, pgbackrest: $p}' > "${1}/options.json"
}

s3_options() { # extra pgbackrest JSON, merged over the S3 defaults
    jq -cn --argjson x "${1:-{\}}" --arg e "${S3_ENDPOINT}" --arg b "${S3_BUCKET}" --arg k "${S3_KEY}" --arg s "${S3_SECRET}" \
        '{enabled: true, repo_type: "s3", s3_endpoint: $e, s3_bucket: $b, s3_uri_style: "path", s3_verify_tls: false,
          s3_key: $k, s3_key_secret: $s} + $x'
}

# Starts the add-on: name, data dir, then extra docker run arguments
start_addon() {
    local name="${1}" data="${2}"; shift 2
    docker rm -f "${name}" > /dev/null 2>&1
    STARTED+=("${name}")
    docker run -d --name "${name}" --label pgbr-test --network "${NET}" \
        -v "${data}:/data" -v "${data}-config:/config" -v "${SHARE_MOUNT:-${data}-share}:/share" \
        -e PGBR_LOOP_SECONDS=3 "$@" "${IMAGE}" > /dev/null
}

psql_in() { docker exec "${1}" psql -X -U postgres -d "${2}" -tAc "${3}"; }
ready() { [[ "$(psql_in "${1}" postgres 'select not pg_is_in_recovery()' 2> /dev/null)" == "t" ]]; }
# Not "docker logs | grep -q": grep stops reading at the first match and pipefail would call that a failure
logs_have() { local t; t="$(docker logs "${1}" 2>&1)"; [[ "${t}" == *"${2}"* ]]; }
logs_lack() { ! logs_have "$@"; }
exec_pgbr() { docker exec "${1}" s6-setuidgid postgres pgbackrest --config=/run/pgbackrest/pgbackrest.conf --config-include-path=/run/pgbackrest/conf.d --stanza="${2}" "${@:3}"; }
backup_types() { exec_pgbr "${1}" "${2}" info --output=json | jq -r '[.[].backup[]?.type] | join(",")'; }
backup_count() { exec_pgbr "${1}" "${2}" info --output=json | jq -r '[.[].backup[]?] | length'; }
exit_code() { docker inspect -f '{{.State.ExitCode}}' "${1}"; }

new_data() { local d="${WORK}/${1}"; mkdir -p "${d}" "${d}-config" "${d}-share"; echo "${d}"; }
wipe_postgres() { docker run --rm -v "${1}:/data" alpine rm -rf /data/postgres; }

# ---- setup ------------------------------------------------------------------

setup() {
    log "setup: SeaweedFS with a throwaway certificate"
    mkdir -p "${WORK}/certs"
    docker run --rm -v "${WORK}/certs:/c" --entrypoint sh alpine/openssl -c \
        'openssl req -x509 -newkey rsa:2048 -nodes -keyout /c/private.key -out /c/public.crt -days 2 -subj /CN=s3 -addext subjectAltName=DNS:s3 && chmod 644 /c/*' > /dev/null 2>&1
    docker compose -f "${HERE}/compose.yaml" up -d > /dev/null 2>&1
    local tries=0 aws=(docker run --rm --network "${NET}" -e AWS_ACCESS_KEY_ID="${S3_KEY}" -e AWS_SECRET_ACCESS_KEY="${S3_SECRET}" --entrypoint aws amazon/aws-cli --endpoint-url "https://${S3_ENDPOINT}" --no-verify-ssl)
    until "${aws[@]}" s3api head-bucket --bucket "${S3_BUCKET}" > /dev/null 2>&1; do
        "${aws[@]}" s3api create-bucket --bucket "${S3_BUCKET}" > /dev/null 2>&1
        tries=$(( tries + 1 )); [[ ${tries} -lt 30 ]] || { echo "  the S3 server did not come up"; exit 1; }
        sleep 3
    done
}

# ---- cases ------------------------------------------------------------------

case1() {
    log "1. feature off: the same as the add-on without it"
    if [[ -z "${UPSTREAM_IMAGE}" ]]; then echo "  skipped: UPSTREAM_IMAGE not set"; return; fi
    for which in new old; do
        local d; d="$(new_data "off-${which}")"
        # No options at all: the add-on without the feature cannot read options.json in standalone mode
        local img="${IMAGE}"; [[ "${which}" == old ]] && img="${UPSTREAM_IMAGE}"
        docker rm -f "off-${which}" > /dev/null 2>&1
        STARTED+=("off-${which}")
        docker run -d --name "off-${which}" --label pgbr-test --network "${NET}" -v "${d}:/data" "${img}" > /dev/null
        wait_for 180 "off-${which} is up" ready "off-${which}"
        docker exec "off-${which}" /usr/share/timescaledb/backup_pre.sh > /dev/null 2>&1
        docker exec "off-${which}" sh -c 'cd /data && { find . -maxdepth 1; find postgres -maxdepth 1; find backup; } | sort; cd postgres && cat postgresql.conf pg_hba.conf postgresql.user.conf' > "${WORK}/off-${which}.txt" 2>&1
    done
    check "the files in /data and the configuration are the same as without the feature" diff "${WORK}/off-new.txt" "${WORK}/off-old.txt"
    check "no pgBackRest state was written to /data" bash -c "[[ ! -e '${WORK}/off-new/pgbackrest' ]]"
    check "the backup hook made a dump" grep -q '^backup/globals.sql' "${WORK}/off-new.txt"
    check "the pgbackrest service stays down" logs_lack off-new "pgBackRest service started"
    docker rm -f off-new off-old > /dev/null 2>&1
}

case2() {
    log "2. fresh install with the feature on: stanza, WAL archiving, full backup, then a diff"
    D2="$(new_data fresh)"
    write_options "${D2}" "$(s3_options)"
    start_addon fresh "${D2}"
    wait_for 240 "PostgreSQL is up" ready fresh
    psql_in fresh postgres 'create table kept as select generate_series(1,1000) as n' > /dev/null
    check "archive_mode is on" bash -c "[[ \"\$(docker exec fresh psql -X -U postgres -tAc 'show archive_mode')\" == on ]]"
    wait_for 120 "a full backup exists" bash -c "[[ \"\$(docker exec fresh s6-setuidgid postgres pgbackrest --config=/run/pgbackrest/pgbackrest.conf --config-include-path=/run/pgbackrest/conf.d --stanza=timescaledb info --output=json | jq -r '[.[].backup[]?.type] | join(\",\")')\" == full ]]"
    psql_in fresh postgres 'select pg_switch_wal()' > /dev/null
    wait_for 60 "WAL is archived" bash -c "[[ \"\$(docker exec fresh psql -X -U postgres -tAc 'select archived_count > 0 from pg_stat_archiver')\" == t ]]"
    docker exec fresh sh -c 'echo diff > /data/pgbackrest/trigger-backup'
    wait_for 120 "a diff backup follows on request" bash -c "[[ \"\$(docker exec fresh s6-setuidgid postgres pgbackrest --config=/run/pgbackrest/pgbackrest.conf --config-include-path=/run/pgbackrest/conf.d --stanza=timescaledb info --output=json | jq -r '[.[].backup[]?.type] | join(\",\")')\" == full,diff ]]"
    wait_for 30 "metrics report the backup" docker exec fresh grep -q '^backup_job_stage_success{stage="backup"} 1' /data/pgbackrest/metrics.prom
    check "metrics report the archiver" docker exec fresh grep -q '^pgbackrest_archive_last_archived_timestamp_seconds' /data/pgbackrest/metrics.prom
    check "the credentials are not in the main configuration" bash -c "! docker exec fresh grep -q '${S3_SECRET}' /run/pgbackrest/pgbackrest.conf"
    check "postgresql_settings cannot override archive_command" bash -c "! docker exec fresh grep -q 'archive_command' /data/postgres/postgresql.user.conf"
}

case3() {
    log "3. backup_pre writes a pointer and no dump"
    check "backup_pre succeeds" docker exec fresh /usr/share/timescaledb/backup_pre.sh
    check "the pointer names the latest backup" bash -c "[[ -n \"\$(docker exec fresh jq -r .backup_label /data/pgbackrest/pointer.json)\" ]]"
    check "the pointer holds no secret" bash -c "! docker exec fresh grep -q '${S3_SECRET}' /data/pgbackrest/pointer.json"
    check "there is no dump" bash -c "! docker exec fresh test -e /data/backup"
    check "backup_post succeeds and keeps the pointer" bash -c "docker exec fresh /usr/share/timescaledb/backup_post.sh && docker exec fresh test -f /data/pgbackrest/pointer.json"
}

case4() {
    log "4. the data directory is gone, the pointer is there: restore from the repository"
    docker stop fresh > /dev/null
    wipe_postgres "${D2}"
    docker rm -f fresh > /dev/null
    start_addon fresh "${D2}"
    wait_for 300 "PostgreSQL is up after the restore" ready fresh
    check "the rows are back" bash -c "[[ \"\$(docker exec fresh psql -X -U postgres -tAc 'select count(*) from kept')\" == 1000 ]]"
    check "recovery went to a new timeline" bash -c "[[ \"\$(docker exec fresh psql -X -U postgres -tAc 'select timeline_id from pg_control_checkpoint()')\" -ge 2 ]]"
    psql_in fresh postgres 'select pg_switch_wal()' > /dev/null
    wait_for 60 "the new timeline archives WAL" bash -c "docker exec fresh psql -X -U postgres -tAc 'select last_archived_wal from pg_stat_archiver' | grep -q '^0000000[2-9]'"
    check "the log says where it was restored from" logs_have fresh 'Restored backup set'
}

case5() {
    log "5. a pointer but no credentials, or no repository: stop, and never run initdb (release blocker)"
    local d; d="$(new_data nocreds)"
    docker stop fresh > /dev/null
    cp -r "${D2}/pgbackrest" "${d}/pgbackrest" 2> /dev/null || docker run --rm -v "${D2}:/s" -v "${d}:/d" alpine sh -c 'mkdir -p /d/pgbackrest && cp /s/pgbackrest/pointer.json /d/pgbackrest/'
    write_options "${d}" "$(s3_options '{"s3_key": null, "s3_key_secret": null}' | jq -c 'del(.s3_key, .s3_key_secret)')"
    start_addon nocreds "${d}" -e PGBR_CREDENTIAL_WAIT_SECONDS=10
    wait_for 120 "the container stops" bash -c "[[ \"\$(docker inspect -f '{{.State.Running}}' nocreds)\" == false ]]"
    check "with a non-zero exit code" bash -c "[[ \"\$(docker inspect -f '{{.State.ExitCode}}' nocreds)\" != 0 ]]"
    check "no data directory was initialized" bash -c "! docker run --rm -v '${d}:/data' alpine test -e /data/postgres/PG_VERSION"
    check "initdb did not run" logs_lack nocreds "Initializing new postgres"
    check "the log says why" logs_have nocreds 'no credentials for the repository'

    local u; u="$(new_data norepo)"
    docker run --rm -v "${D2}:/s" -v "${u}:/d" alpine sh -c 'mkdir -p /d/pgbackrest && cp /s/pgbackrest/pointer.json /d/pgbackrest/'
    write_options "${u}" "$(s3_options '{"s3_endpoint": "nowhere:9000"}')"
    start_addon norepo "${u}" -e PGBR_CREDENTIAL_WAIT_SECONDS=10
    wait_for 180 "unreachable repository: the container stops" bash -c "[[ \"\$(docker inspect -f '{{.State.Running}}' norepo)\" == false ]]"
    check "with a non-zero exit code" bash -c "[[ \"\$(docker inspect -f '{{.State.ExitCode}}' norepo)\" != 0 ]]"
    check "no data directory was initialized" bash -c "! docker run --rm -v '${u}:/data' alpine test -e /data/postgres/PG_VERSION"
    check "initdb did not run" logs_lack norepo "Initializing new postgres"
}

case6() {
    log "6. restore_from_repo on an empty /data: restore, then the option is cleared"
    local d; d="$(new_data joiner)"
    write_options "${d}" "$(s3_options '{"restore_from_repo": true}')"
    start_addon joiner "${d}"
    wait_for 300 "PostgreSQL is up after the restore" ready joiner
    check "the rows are back" bash -c "[[ \"\$(docker exec joiner psql -X -U postgres -tAc 'select count(*) from kept')\" == 1000 ]]"
    check "restore_from_repo was cleared" bash -c "[[ \"\$(jq -r .pgbackrest.restore_from_repo '${d}/options.json')\" == false ]]"
}

case7() {
    log "7. a PostgreSQL 17 data directory: pg_upgrade, stanza-upgrade, full backup, archiving resumes"
    local d; d="$(new_data upgrade)"
    docker run --rm --label pgbr-test --network "${NET}" -v "${d}:/data" -v "${HERE}:/tests:ro" \
        -e S3_ENDPOINT="${S3_ENDPOINT}" -e S3_BUCKET="${S3_BUCKET}" -e S3_KEY="${S3_KEY}" -e S3_SECRET="${S3_SECRET}" -e STANZA=pg17 \
        --entrypoint sh "${IMAGE}" /tests/pg17_stanza.sh > "${WORK}/pg17.log" 2>&1
    check "a PostgreSQL 17 cluster with a stanza was made" bash -c "[[ \"\$(docker run --rm -v '${d}:/data' alpine cat /data/postgres/PG_VERSION)\" == 17 ]]"
    write_options "${d}" "$(s3_options '{"stanza": "pg17"}')"
    start_addon upgrade "${d}"
    wait_for 400 "PostgreSQL 18 is up" ready upgrade
    check "the cluster is PostgreSQL 18" bash -c "[[ \"\$(docker exec upgrade cat /data/postgres/PG_VERSION)\" == 18 ]]"
    check "the data survived" bash -c "[[ \"\$(docker exec upgrade psql -X -U postgres -tAc 'select count(*) from kept')\" == 1000 ]]"
    wait_for 120 "the stanza knows both versions and has a backup of PostgreSQL 18" bash -c "docker exec upgrade s6-setuidgid postgres pgbackrest --config=/run/pgbackrest/pgbackrest.conf --config-include-path=/run/pgbackrest/conf.d --stanza=pg17 info --output=json | jq -e '[.[].backup[]? | select(.database.id == 2 and .type == \"full\")] | length >= 1'"
    psql_in upgrade postgres 'select pg_switch_wal()' > /dev/null
    wait_for 60 "archiving resumed" bash -c "[[ \"\$(docker exec upgrade psql -X -U postgres -tAc 'select archived_count > 0 and failed_count = 0 from pg_stat_archiver')\" == t ]]"
}

case8() {
    log "8. archive queue cap: WAL is dropped, PostgreSQL stays up, recovery after the repository is back"
    local d; d="$(new_data cap)"
    write_options "${d}" "$(s3_options '{"stanza": "cap", "archive_queue_max": "16MiB"}')"
    start_addon cap "${d}"
    wait_for 240 "PostgreSQL is up" ready cap
    wait_for 120 "a full backup exists" bash -c "[[ \"\$(docker exec cap s6-setuidgid postgres pgbackrest --config=/run/pgbackrest/pgbackrest.conf --config-include-path=/run/pgbackrest/conf.d --stanza=cap info --output=json | jq -r '[.[].backup[]?] | length')\" -ge 1 ]]"
    docker network disconnect "${NET}" "$(docker compose -f "${HERE}/compose.yaml" ps -q s3)"
    psql_in cap postgres 'create table filler(id int, pad text)' > /dev/null
    for _ in 1 2 3 4 5 6; do
        psql_in cap postgres "insert into filler select g, repeat(md5(random()::text), 300) from generate_series(1, 4000) g" > /dev/null
        psql_in cap postgres 'select pg_switch_wal()' > /dev/null
    done
    wait_for 180 "WAL is dropped and counted" bash -c "docker exec cap grep -q '^pgbackrest_archive_dropped_total [1-9]' /data/pgbackrest/metrics.prom"
    check "the log warns about the gap" logs_have cap "dropped WAL"
    check "PostgreSQL is still up" bash -c "[[ \"\$(docker exec cap psql -X -U postgres -tAc 'select 1')\" == 1 ]]"
    docker network connect --alias s3 "${NET}" "$(docker compose -f "${HERE}/compose.yaml" ps -q s3)"
    psql_in cap postgres "insert into filler select g, 'x' from generate_series(1, 10) g" > /dev/null
    wait_for 240 "check passes again once the repository is back" bash -c "docker exec cap s6-setuidgid postgres pgbackrest --config=/run/pgbackrest/pgbackrest.conf --config-include-path=/run/pgbackrest/conf.d --stanza=cap check"
}

case9() {
    log "9. a posix repository under /share (root-owned, as in Home Assistant)"
    local d; d="$(new_data posix)"
    docker volume create --label pgbr-test pgbr-test-share > /dev/null
    write_options "${d}" '{"enabled": true, "repo_type": "posix", "stanza": "posix"}'
    SHARE_MOUNT=pgbr-test-share start_addon posix "${d}"
    wait_for 240 "PostgreSQL is up" ready posix
    wait_for 120 "a full backup is in /share" bash -c "docker exec posix ls /share/timescaledb/pgbackrest/backup/posix | grep -q F"
    check "the repository is outside /data" bash -c "! docker exec posix ls /data | grep -q timescaledb"
}

# ---- main -------------------------------------------------------------------

CASES=("$@")
[[ ${#CASES[@]} -gt 0 ]] || CASES=(1 2 3 4 5 6 7 8 9)

setup
for c in "${CASES[@]}"; do
    STARTED=()
    before="${FAILED}"
    "case${c}"
    if (( FAILED > before )); then
        for name in "${STARTED[@]}"; do
            printf '\n---- last log lines of %s ----\n' "${name}"
            docker logs --tail 40 "${name}" 2>&1 | cut -c1-240
        done
    fi
done

printf '\n%s passed, %s failed\n' "${PASSED}" "${FAILED}"
[[ "${FAILED}" -eq 0 ]]
