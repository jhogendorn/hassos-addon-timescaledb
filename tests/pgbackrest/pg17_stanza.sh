#!/bin/sh
# Test helper, run in the add-on image with this directory mounted at /tests.
# Makes a PostgreSQL 17 cluster in /data/postgres, the way an add-on before 6.0 left it, with
# pgBackRest archiving to the repository in the environment and one full backup of it.
set -e
mkdir -p /tmp/pgbr /data/postgres
cat > /tmp/pgbr/pgbackrest.conf <<CONF
[global]
repo1-type=s3
repo1-path=/timescaledb/pgbackrest
repo1-s3-endpoint=${S3_ENDPOINT}
repo1-s3-bucket=${S3_BUCKET}
repo1-s3-region=us-east-1
repo1-s3-uri-style=path
repo1-s3-key=${S3_KEY}
repo1-s3-key-secret=${S3_SECRET}
repo1-storage-verify-tls=n
spool-path=/tmp/pgbr
log-path=/tmp/pgbr
[${STANZA}]
pg1-path=/data/postgres
pg1-socket-path=/run/postgresql
CONF
chown -R postgres:postgres /data/postgres /tmp/pgbr
PG17=/usr/libexec/postgresql17
as_pg() { su postgres -s /bin/sh -c "$1"; }
as_pg "${PG17}/initdb -D /data/postgres --auth=trust"
cat >> /data/postgres/postgresql.conf <<CONF
shared_preload_libraries = 'timescaledb,pg_stat_statements'
archive_mode = on
archive_command = 'pgbackrest --config=/tmp/pgbr/pgbackrest.conf --stanza=${STANZA} archive-push %p'
CONF
as_pg "${PG17}/pg_ctl -D /data/postgres -w -l /tmp/pgbr/pg.log start"
as_pg "pgbackrest --config=/tmp/pgbr/pgbackrest.conf --stanza=${STANZA} stanza-create"
as_pg "${PG17}/psql -X -d postgres -c 'create table kept as select generate_series(1,1000) as n'" 2> /dev/null \
    || as_pg "psql -X -d postgres -c 'create table kept as select generate_series(1,1000) as n'"
as_pg "pgbackrest --config=/tmp/pgbr/pgbackrest.conf --stanza=${STANZA} --type=full backup"
as_pg "${PG17}/pg_ctl -D /data/postgres -w stop"
