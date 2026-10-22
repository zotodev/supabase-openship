#!/bin/sh
#
# Generate the Openship-facing files from the pristine upstream/ tree:
#   openship-compose.yml   single compose file Openship deploys (composePath)
#   openship.vars.json     every ${VAR} it references + upstream defaults
#   config/                host-side config files (envoy, db init SQL, pooler)
#   functions/main/, functions/deno.jsonc   vendor edge-function entrypoint
#
# Runs on your laptop (or CI). Needs: docker CLI + compose plugin (no daemon
# needed for `docker compose config`), python3.
#
# Usage: sh scripts/render.sh
#
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
need docker python3
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
load_conf

REF=$(upstream_ref)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

log "Rendering from upstream $REF"
cp -a "$UPSTREAM_DIR/." "$TMP/"
rm -f "$TMP/.env" "$TMP/docker-compose.override.yml"

if [ "$ASYMMETRIC_KEYS" = "1" ]; then
    # Same edit upstream utils/add-new-auth-keys.sh makes to docker-compose.yml.
    sed -i.old \
        -e '/^[ ]*#GOTRUE_JWT_KEYS:/ s/#//' \
        -e '/^[ ]*#API_JWT_JWKS:/ s/#//' \
        -e '/^[ ]*#JWT_JWKS:/ s/#//' \
        -e '/^[ ]*#SUPABASE_JWKS:/ s/#//' \
        "$TMP/docker-compose.yml"
    for k in GOTRUE_JWT_KEYS API_JWT_JWKS JWT_JWKS SUPABASE_JWKS; do
        grep -q "^[ ]*$k:" "$TMP/docker-compose.yml" || die "could not enable $k (upstream changed?)"
    done
fi

set -- -f "$TMP/docker-compose.yml"
for o in $UPSTREAM_OVERRIDES; do
    case "$o" in
        logs|kong|caddy|nginx|envoy)
            die "override '$o' is not supported under Openship (see render.conf)" ;;
    esac
    f="$TMP/docker-compose.$o.yml"
    [ -f "$f" ] || die "upstream override not found: docker-compose.$o.yml"
    set -- "$@" -f "$f"
done
for f in "$REPO_ROOT"/overrides/*.yml; do
    [ -f "$f" ] || continue
    log "Layering local override: overrides/$(basename "$f")"
    set -- "$@" -f "$f"
done

docker compose --project-directory "$TMP" "$@" config --no-interpolate --format json \
    > "$TMP/.merged.json"

python3 "$TOOL" render \
    --input "$TMP/.merged.json" \
    --output "$COMPOSE_OUT" \
    --vars-out "$VARS_OUT" \
    --project-dir "$TMP" \
    --root "$SUPABASE_ROOT" \
    --bind-addr "$BIND_ADDR" \
    --ref "$REF" \
    --port-env "$UPSTREAM_DIR/.env.example" \
    --set "API_GW_HTTP_PORT=${API_GW_HTTP_PORT:-8000}" \
    --set "KONG_HTTP_PORT=${API_GW_HTTP_PORT:-8000}" \
    --set "POSTGRES_PORT=${POSTGRES_PORT:-5432}" \
    --set "POOLER_PROXY_PORT_TRANSACTION=${POOLER_PROXY_PORT_TRANSACTION:-6543}"

# Host-side config files, copied from upstream/volumes and patched.
log "Refreshing config/ from upstream/volumes"
rm -rf "$REPO_ROOT/config"
mkdir -p "$REPO_ROOT/config"
for d in api db pooler logs proxy; do
    [ -d "$UPSTREAM_DIR/volumes/$d" ] && cp -a "$UPSTREAM_DIR/volumes/$d" "$REPO_ROOT/config/"
done
rm -rf "$REPO_ROOT/config/db/data"

# Openship ignores container_name and network aliases; the hostname is the
# service name. Envoy's realtime cluster dials the upstream container name
# realtime-dev.supabase-realtime, so point it at the service name `realtime`.
# The Host header stays realtime-dev.supabase-realtime via
# host_rewrite_literal in lds.template.yaml, which Realtime needs to resolve
# its tenant ("realtime-dev").
CDS="$REPO_ROOT/config/api/envoy/cds.yaml"
if grep -q 'address: realtime-dev.supabase-realtime' "$CDS"; then
    sed -i.old 's/address: realtime-dev\.supabase-realtime$/address: realtime/' "$CDS" && rm -f "$CDS.old"
else
    warn "cds.yaml no longer dials realtime-dev.supabase-realtime - review realtime routing"
fi
grep -q 'host_rewrite_literal: realtime-dev.supabase-realtime' \
    "$REPO_ROOT/config/api/envoy/lds.template.yaml" \
    || warn "lds.template.yaml lost the realtime host rewrite - Realtime tenant lookup may break"

# Your own host-side config files (referenced from overrides/ as ./volumes/<x>)
# live in config.local/<x> and are copied over the generated config/.
if [ -d "$REPO_ROOT/config.local" ]; then
    log "Overlaying config.local/ onto config/"
    cp -a "$REPO_ROOT/config.local/." "$REPO_ROOT/config/"
fi

# Vendor edge-function entrypoint; your own functions in functions/<name>/ are left alone.
log "Refreshing functions/main and functions/deno.jsonc (vendor)"
mkdir -p "$REPO_ROOT/functions"
rm -rf "$REPO_ROOT/functions/main"
cp -a "$UPSTREAM_DIR/volumes/functions/main" "$REPO_ROOT/functions/main"
for f in "$UPSTREAM_DIR"/volumes/functions/deno.json*; do
    [ -f "$f" ] && cp -f "$f" "$REPO_ROOT/functions/"
done
[ -d "$REPO_ROOT/functions/hello" ] || cp -a "$UPSTREAM_DIR/volumes/functions/hello" "$REPO_ROOT/functions/hello"

# Sanity: nothing should still reference compose-only names.
if grep -nE 'realtime-dev\.supabase-realtime|supabase-(db|auth|rest|storage|meta|studio|envoy|kong|pooler)\b' \
    "$COMPOSE_OUT" "$CDS" | grep -v host_rewrite_literal; then
    warn "compose-only container names still referenced (see above)"
fi

log "Done. Review: git diff --stat"
