#!/bin/bash
# Railway entrypoint for Odoo 19.0.
#
#   1. Refuse to boot without an admin password or a master password. Both
#      defaults are publicly documented ("admin"), and both are remotely
#      reachable the moment Railway publishes the domain.
#   2. Write /etc/odoo/odoo.conf. Odoo has no environment-variable configuration
#      layer, so this is the only place admin_passwd / list_db / dbfilter /
#      proxy_mode can be set at all.
#   3. Repair the volume's ownership. Railway mounts volumes uid 0 and the image
#      runs as uid 100, so the filestore is unwritable without this; the
#      published listings work around it by running the whole ERP as root
#      (RAILWAY_RUN_UID=0).
#   4. Initialise the database on first boot, then seed the administrator on
#      every boot, both before anything binds a port.
#   5. exec odoo on Railway's injected $PORT as uid 100.
#
# The stock /entrypoint.sh is deliberately NOT used: it reads $PORT as the
# POSTGRES port (check_config "db_port" "$PORT"), and Railway injects $PORT=8080
# into every service.
set -euo pipefail

log() { echo "[railway] $*"; }
die() { log "FATAL: $*"; exit 1; }

DB_NAME="${ODOO_DB_NAME:-odoo}"
DATA_DIR="${ODOO_DATA_DIR:-/var/lib/odoo}"
CONF=/etc/odoo/odoo.conf
UID_ODOO=100
GID_ODOO=101

[ -n "${ODOO_ADMIN_PASSWORD:-}" ] || die "ODOO_ADMIN_PASSWORD is empty. A stock Odoo accepts the documented default administrator password on the public URL."
[ -n "${ODOO_MASTER_PASSWORD:-}" ] || die "ODOO_MASTER_PASSWORD is empty. The database manager would then accept the compiled-in default and hand any visitor a full database backup."

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:=5432}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"

# --- volume -----------------------------------------------------------------
mkdir -p "$DATA_DIR"
chown -R "$UID_ODOO:$GID_ODOO" "$DATA_DIR" 2>/dev/null || log "warning: could not chown $DATA_DIR"
log "data_dir $DATA_DIR owner=$(stat -c %u:%g "$DATA_DIR")"

# --- config -----------------------------------------------------------------
# max_cron_threads stays at the upstream default and workers stays at 0
# (threaded mode) on purpose: in prefork mode Odoo moves the websocket bus to a
# second port (gevent_port), and Railway routes exactly one port per service, so
# workers > 0 would silently kill live notifications.
umask 077
cat > "$CONF" <<EOF
[options]
addons_path = /mnt/extra-addons
data_dir = ${DATA_DIR}
admin_passwd = ${ODOO_MASTER_PASSWORD}
list_db = False
db_name = ${DB_NAME}
dbfilter = ^${DB_NAME}\$
db_host = ${PGHOST}
db_port = ${PGPORT}
db_user = ${PGUSER}
db_password = ${PGPASSWORD}
proxy_mode = True
workers = 0
EOF
chown "$UID_ODOO:$GID_ODOO" "$CONF"
log "wrote $CONF (list_db=False, dbfilter=^${DB_NAME}\$, proxy_mode=True)"

run_as_odoo() { setpriv --reuid="$UID_ODOO" --regid="$GID_ODOO" --clear-groups "$@"; }

# --- wait for postgres ------------------------------------------------------
for i in $(seq 1 60); do
    if PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -tAc 'select 1' >/dev/null 2>&1; then
        break
    fi
    [ "$i" = 60 ] && die "postgres at $PGHOST:$PGPORT did not answer in 60s"
    sleep 1
done

# --- first-boot initialisation ----------------------------------------------
initialised=0
if PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -tAc \
        "select 1 from pg_database where datname = '${DB_NAME}'" | grep -q 1; then
    if PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB_NAME" -tAc \
            "select 1 from information_schema.tables where table_name = 'ir_module_module'" | grep -q 1; then
        initialised=1
    fi
fi

if [ "$initialised" = 0 ]; then
    log "initialising database ${DB_NAME} (base only, no demo data)"
    run_as_odoo odoo -c "$CONF" -d "$DB_NAME" -i base --without-demo=all --stop-after-init --no-http
    log "database initialised"
else
    log "database ${DB_NAME} already initialised"
fi

# --- seed the administrator, every boot -------------------------------------
log "seeding administrator"
run_as_odoo odoo shell -c "$CONF" -d "$DB_NAME" --no-http < /opt/railway/seed_admin.py

# --- serve ------------------------------------------------------------------
# $PORT is Railway's injected port and is honoured as the HTTP port, because a
# public service's healthcheck dials the injected port rather than the domain's
# target port.
log "starting odoo on port ${PORT:-8069}"
exec setpriv --reuid="$UID_ODOO" --regid="$GID_ODOO" --clear-groups \
    odoo -c "$CONF" --http-port="${PORT:-8069}" "$@"
