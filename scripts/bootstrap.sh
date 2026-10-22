#!/bin/sh
#
# One-time setup. Three subcommands:
#
#   secrets   (laptop) Generate all secrets/keys with upstream's own
#             utils/generate-keys.sh + utils/add-new-auth-keys.sh into ./.env
#             (gitignored, chmod 600), set your URLs, then run `env`.
#               sh scripts/bootstrap.sh secrets --public-url https://sb.example.com \
#                   [--site-url https://app.example.com] [--force]
#
#   env       (laptop) Regenerate ./.env.openship from ./.env: one flat
#             KEY=value line for every ${VAR} openship-compose.yml uses, with
#             upstream defaults filled in. Import it in Openship (Import .env).
#               sh scripts/bootstrap.sh env
#
#   host      (server, inside the repo clone at $SUPABASE_ROOT; run over SSH
#             or as an Openship Job) Create data dirs and verify every bind
#             mount source in openship-compose.yml exists. Idempotent.
#               cd /srv/supabase && sh scripts/bootstrap.sh host
#
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_conf

cmd=${1:-}
[ -n "$cmd" ] && shift

make_env() {
    need python3
    [ -f "$REPO_ROOT/.env" ] || die ".env not found - run: sh scripts/bootstrap.sh secrets ..."
    [ -f "$VARS_OUT" ] || die "openship.vars.json not found - run: sh scripts/render.sh"
    python3 "$TOOL" resolve-env --vars "$VARS_OUT" \
        --env "$UPSTREAM_DIR/.env.example" --env "$REPO_ROOT/.env" \
        --output "$REPO_ROOT/.env.openship"
    chmod 600 "$REPO_ROOT/.env.openship"
    log "Import $REPO_ROOT/.env.openship into Openship (project > Environment > Import .env)."
    log "Then delete it or keep it somewhere safe - it contains every secret."
}

case "$cmd" in
secrets)
    need openssl
    public_url="" site_url="" force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --public-url) public_url=$2; shift 2 ;;
            --site-url)   site_url=$2; shift 2 ;;
            --force)      force=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    [ -n "$public_url" ] || die "--public-url is required (e.g. https://supabase.example.com or http://100.x.y.z:8000)"
    public_url=${public_url%/}
    site_url=${site_url:-http://localhost:3000}
    if [ -f "$REPO_ROOT/.env" ] && [ "$force" != 1 ]; then
        die ".env already exists. Regenerating secrets on a live database breaks it. Use --force only before first deploy."
    fi
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT INT TERM
    cp -a "$UPSTREAM_DIR/." "$TMP/"
    cp "$TMP/.env.example" "$TMP/.env"
    log "Generating secrets with upstream utils/generate-keys.sh"
    ( cd "$TMP" && sh utils/generate-keys.sh --update-env >/dev/null )
    if [ "$ASYMMETRIC_KEYS" = "1" ]; then
        log "Generating asymmetric API keys with upstream utils/add-new-auth-keys.sh (needs node>=16 or docker)"
        ( cd "$TMP" && sh utils/add-new-auth-keys.sh --update-env >/dev/null )
    fi
    sed -i.old \
        -e "s|^SUPABASE_PUBLIC_URL=.*$|SUPABASE_PUBLIC_URL=${public_url}|" \
        -e "s|^API_EXTERNAL_URL=.*$|API_EXTERNAL_URL=${public_url}/auth/v1|" \
        -e "s|^SITE_URL=.*$|SITE_URL=${site_url}|" \
        "$TMP/.env"
    umask 077
    cp "$TMP/.env" "$REPO_ROOT/.env"
    chmod 600 "$REPO_ROOT/.env"
    log "Wrote $REPO_ROOT/.env (gitignored). Review SMTP_*, POOLER_TENANT_ID, DASHBOARD_USERNAME."
    grep -q '^POOLER_TENANT_ID=your-tenant-id' "$REPO_ROOT/.env" \
        && warn "POOLER_TENANT_ID is still 'your-tenant-id' - fine, but you may rename it now"
    make_env
    ;;
env)
    make_env
    ;;
host)
    need docker python3
    [ "$(pwd -P)" = "$(cd "$SUPABASE_ROOT" 2>/dev/null && pwd -P)" ] \
        || warn "repo is at $(pwd -P) but render.conf says SUPABASE_ROOT=$SUPABASE_ROOT"
    for d in data/db data/storage data/snippets functions; do
        mkdir -p "$SUPABASE_ROOT/$d"
    done
    missing=0
    for src in $(python3 "$TOOL" binds --compose "$COMPOSE_OUT"); do
        case "$src" in
            "$SUPABASE_ROOT"/data/*) continue ;;   # created above / by Postgres
        esac
        if [ ! -e "$src" ]; then
            warn "missing bind source: $src"
            missing=1
        fi
    done
    [ "$missing" = 0 ] || die "fix the missing files (git pull? render.sh?) before deploying - Docker would create them as empty directories"
    log "Host layout OK under $SUPABASE_ROOT"
    if [ -n "$(ls -A "$SUPABASE_ROOT/data/db" 2>/dev/null)" ]; then
        log "data/db is not empty: Postgres will NOT re-run init SQL (expected after first boot)"
    else
        log "data/db is empty: first deploy will initialise Postgres with config/db/*.sql"
    fi
    ;;
*)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
