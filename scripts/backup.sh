#!/bin/sh
#
# Server side backup: logical dump of every database, the pgsodium root key
# (lives in the db-config named volume; without it Vault secrets are lost),
# and file data (Storage objects, Studio snippets, edge functions).
# Run as an Openship Job (cron, e.g. daily) or over SSH:
#
#   cd /srv/supabase && sh scripts/backup.sh [--keep-days 7] [--dir /srv/supabase-backups]
#
# Env: DB_CONTAINER (skip auto-detection), BACKUP_DIR, KEEP_DAYS.
# Secrets (.env) are NOT on the host - keep your own copy of .env safe.
#
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
need docker gzip tar
load_conf

BACKUP_DIR=${BACKUP_DIR:-/srv/supabase-backups}
KEEP_DAYS=${KEEP_DAYS:-7}
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-days) KEEP_DAYS=$2; shift 2 ;;
        --dir)       BACKUP_DIR=$2; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

# Openship names containers itself (container_name is ignored), so find the
# running Postgres container by image.
if [ -z "${DB_CONTAINER:-}" ]; then
    DB_CONTAINER=$(docker ps --format '{{.Names}} {{.Image}}' \
        | awk '$2 ~ /^(docker\.io\/)?supabase\/postgres:/ {print $1}')
    n=$(printf '%s\n' "$DB_CONTAINER" | grep -c . || true)
    [ "$n" = 1 ] || die "found $n running supabase/postgres containers; set DB_CONTAINER=<name>"
fi
log "Postgres container: $DB_CONTAINER"

umask 077
ts=$(date +%Y%m%d-%H%M%S)
out="$BACKUP_DIR/$ts"
mkdir -p "$out"

log "pg_dumpall -> $out/pg_dumpall.sql.gz"
# PGPASSWORD is set in the db container's environment by the compose file.
docker exec "$DB_CONTAINER" pg_dumpall -h localhost -U supabase_admin \
    | gzip -c > "$out/pg_dumpall.sql.gz"
gzip -t "$out/pg_dumpall.sql.gz"

log "pgsodium root key -> $out/pgsodium_root.key"
docker exec "$DB_CONTAINER" cat /etc/postgresql-custom/pgsodium_root.key > "$out/pgsodium_root.key"
[ -s "$out/pgsodium_root.key" ] || die "pgsodium key is empty"

log "files (data/storage, data/snippets, functions) -> $out/files.tar.gz"
tar czf "$out/files.tar.gz" -C "$SUPABASE_ROOT" data/storage data/snippets functions

( cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null ) > "$out/repo-commit.txt" || true
grep -E '^ref=' "$UPSTREAM_DIR/.supabase-version" > "$out/supabase-version.txt" || true

log "Backup complete: $(du -sh "$out" | cut -f1) in $out"

if [ "$KEEP_DAYS" -gt 0 ] 2>/dev/null; then
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -print -exec rm -rf {} + \
        | sed 's/^/pruned: /'
fi
