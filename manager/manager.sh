#!/bin/bash
#
# supabase-manager: runs the OFFICIAL self-hosted Supabase docker/ setup on the
# host through the host Docker socket, using upstream's own scripts
# (setup.sh, update.sh, run.sh) unmodified, in $SUPABASE_DIR.
#
# $SUPABASE_DIR must be bind-mounted at the SAME path inside this container as
# on the host: `docker compose` sends bind-mount source paths to the host
# daemon, so ./volumes/... must resolve identically on both sides.
#
# Usage (entrypoint default is `run`):
#   manager run              reconcile (install / update / start), then stay up
#   manager reconcile        one reconcile pass, then exit
#   manager status           stack + manager state
#   manager health           exit 0 if manager state ok and all services running
#   manager backup           pg_dumpall + pgsodium key + files + .env
#   manager update [--to T] [--dry-run]
#                            update to T (default $SUPABASE_VERSION) now. Exit:
#                            0 ok/nothing to do, 3 refused (breaking gate, bad
#                            or downgrade target; nothing changed), 2 update.sh
#                            merge conflicts (containers NOT recreated), 1 other.
#                            --dry-run: gate check + `update.sh --dry-run` only;
#                            no lock, backup, write or restart.
#   manager logs <svc> [...] docker compose logs -f (passes args to `run.sh logs`;
#                            follows forever - for a bounded tail use
#                            `manager compose logs --tail N <svc>`)
#   manager psql [args]      psql as postgres inside supabase-db
#   manager compose <args>   docker compose <args> in $SUPABASE_DIR
#
# Configuration (environment; set in Openship's env editor):
#   SUPABASE_VERSION    self-hosted/vX.Y.Z | latest   (default: /opt/manager/supabase.version)
#   SUPABASE_DIR        default /srv/supabase
#   BACKUP_DIR          default /srv/supabase-backups
#   BACKUP_KEEP_DAYS    default 14 (0 = keep forever)
#   COMPOSE_OVERRIDES   space/comma list, e.g. "logrotate" or "logrotate logs".
#                       Names found in /opt/manager/overrides (docker-compose.<name>.yml,
#                       shipped from this repo) are copied in first; others must be
#                       upstream overrides. The list is authoritative.
#   ACK_BREAKING        comma list of upstream versions whose breaking/gated
#                       manual steps you have completed, e.g. "0.8.0". Required
#                       before updating across such a release.
#   AUTO_UPDATE         true = with SUPABASE_VERSION=latest, re-check daily and
#                       apply NON-breaking releases automatically (default false)
#   UPDATE_CHECK_INTERVAL  seconds between checks (default 86400)
#   SUPABASE_ENV_<KEY>  set KEY=<value> in $SUPABASE_DIR/.env on every reconcile
#                       (e.g. SUPABASE_ENV_SUPABASE_PUBLIC_URL, SUPABASE_ENV_SMTP_HOST)
#   REPO_URL            default https://github.com/supabase/supabase
#
set -euo pipefail

SUPABASE_DIR=${SUPABASE_DIR:-/srv/supabase}
BACKUP_DIR=${BACKUP_DIR:-/srv/supabase-backups}
BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-14}
COMPOSE_OVERRIDES=${COMPOSE_OVERRIDES:-}
ACK_BREAKING=${ACK_BREAKING:-}
AUTO_UPDATE=${AUTO_UPDATE:-false}
UPDATE_CHECK_INTERVAL=${UPDATE_CHECK_INTERVAL:-86400}
REPO_URL=${REPO_URL:-https://github.com/supabase/supabase}
MANAGER_HOME=${MANAGER_HOME:-/opt/manager}
STATE_DIR="$SUPABASE_DIR/.manager"
STATE_FILE="$STATE_DIR/state"
DB_CONTAINER=${DB_CONTAINER:-supabase-db}

if [ -z "${SUPABASE_VERSION:-}" ] && [ -f "$MANAGER_HOME/supabase.version" ]; then
    SUPABASE_VERSION=$(grep -vE '^\s*(#|$)' "$MANAGER_HOME/supabase.version" | head -n1 | tr -d ' \r')
fi
SUPABASE_VERSION=${SUPABASE_VERSION:-latest}

ts()   { date '+%Y-%m-%dT%H:%M:%S%z'; }
log()  { printf '%s [manager] %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s [manager] WARNING: %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s [manager] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }

set_state() {  # set_state <ok|blocked|error|installing|updating> <message>
    mkdir -p "$STATE_DIR"
    printf '%s %s %s\n' "$1" "$(ts)" "$2" > "$STATE_FILE.tmp"
    mv -f "$STATE_FILE.tmp" "$STATE_FILE"
    case "$1" in
        blocked|error) warn "state=$1: $2" ;;
        *) log "state=$1: $2" ;;
    esac
}

current_ref() {
    [ -f "$SUPABASE_DIR/.supabase-version" ] || return 1
    grep -E '^ref=' "$SUPABASE_DIR/.supabase-version" | head -n1 | cut -d= -f2- | tr -d "\r\"' "
}

ver() { printf '%s' "${1#self-hosted/}" | sed 's/^v//'; }
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

latest_tag() {
    git ls-remote --tags --refs "$REPO_URL" 'self-hosted/v*' \
        | sed 's#^.*refs/tags/##' | sort -V | tail -n1
}

resolve_target() {
    if [ "$SUPABASE_VERSION" = "latest" ]; then
        latest_tag || die "could not look up latest self-hosted tag"
    else
        printf '%s' "$SUPABASE_VERSION"
    fi
}

compose() { (cd "$SUPABASE_DIR" && docker compose "$@"); }
run_sh()  { (cd "$SUPABASE_DIR" && sh run.sh "$@"); }

# Serialize manager runs (old + new manager container can overlap on redeploy).
LOCK_FD=9
take_lock() {
    mkdir -p "$STATE_DIR"
    exec 9>"$STATE_DIR/lock"
    if ! flock -w "${1:-600}" "$LOCK_FD"; then
        die "another manager process holds $STATE_DIR/lock"
    fi
}

# --- .env management -----------------------------------------------------

apply_env_overrides() {
    local line key val n=0
    while IFS= read -r line; do
        key=${line%%=*}; key=${key#SUPABASE_ENV_}
        val=${line#*=}
        [ -n "$key" ] || continue
        case "$val" in *$'\n'*) warn "SUPABASE_ENV_$key has a newline; skipped"; continue ;; esac
        if grep -q "^${key}=" "$SUPABASE_DIR/.env"; then
            KEY="$key" VAL="$val" awk 'BEGIN{k=ENVIRON["KEY"]; v=ENVIRON["VAL"]}
                index($0, k"=")==1 {print k"="v; next} {print}' \
                "$SUPABASE_DIR/.env" > "$SUPABASE_DIR/.env.mgr" && mv -f "$SUPABASE_DIR/.env.mgr" "$SUPABASE_DIR/.env"
        else
            printf '%s=%s\n' "$key" "$val" >> "$SUPABASE_DIR/.env"
        fi
        n=$((n + 1))
    done < <(env | grep -E '^SUPABASE_ENV_[A-Za-z_][A-Za-z0-9_]*=' || true)
    chmod 600 "$SUPABASE_DIR/.env"
    [ "$n" = 0 ] || log "applied $n SUPABASE_ENV_* value(s) to .env"
}

# --- overrides -----------------------------------------------------------

sync_overrides() {
    local want name current f
    want=$(printf '%s' "$COMPOSE_OVERRIDES" | tr ',' ' ' | xargs -n1 2>/dev/null | sort -u || true)
    for name in $want; do
        f="$MANAGER_HOME/overrides/docker-compose.$name.yml"
        if [ -f "$f" ]; then
            cp -f "$f" "$SUPABASE_DIR/docker-compose.$name.yml"
        fi
    done
    current=$( { grep -E '^COMPOSE_FILE=' "$SUPABASE_DIR/.env" || true; } | head -n1 | cut -d= -f2- | tr -d "\r\"'" \
        | tr ':' '\n' | sed -n 's/^docker-compose\.\(.*\)\.yml$/\1/p' | sort -u)
    for name in $current; do
        printf '%s\n' "$want" | grep -qx "$name" || run_sh config remove "$name"
    done
    for name in $want; do
        printf '%s\n' "$current" | grep -qx "$name" || run_sh config add "$name"
    done
}

# --- install ---------------------------------------------------------------

install_fresh() {
    local target=$1 stage
    [ -z "$(find "$SUPABASE_DIR" -mindepth 1 -maxdepth 1 ! -name .manager | head -n1)" ] \
        || { set_state blocked "$SUPABASE_DIR is not empty but has no .supabase-version - refusing to install over it (see README: adopting an existing install)"; return 1; }
    set_state installing "fresh install of $target"
    stage=$(mktemp -d "$STATE_DIR/setup.XXXXXX")
    # Official installer, unmodified: no package installs, no prompts, pinned ref.
    # It creates <cwd>/<project-dir>, generates all secrets + asymmetric keys,
    # writes .supabase-version and pulls images.
    (cd "$stage" && curl -fsSL "https://raw.githubusercontent.com/supabase/supabase/$target/docker/setup.sh" -o setup.sh \
        && sh setup.sh --skip-deps -y --ref "$target" --project-dir project) \
        || { set_state error "upstream setup.sh failed"; return 1; }
    # Move the finished project into place (nothing is running yet).
    (cd "$stage/project" && tar cf - .) | (cd "$SUPABASE_DIR" && tar xpf -)
    rm -rf "$stage"
    chmod 600 "$SUPABASE_DIR/.env"
    log "installed $(current_ref) into $SUPABASE_DIR (secrets in $SUPABASE_DIR/.env)"
}

# --- backup ----------------------------------------------------------------

do_backup() {
    local tag=${1:-manual} out
    umask 077
    out="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-$tag"
    mkdir -p "$out"
    docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || die "$DB_CONTAINER not found - is the stack running?"
    log "backup -> $out"
    docker exec "$DB_CONTAINER" pg_dumpall -h localhost -U supabase_admin | gzip -c > "$out/pg_dumpall.sql.gz"
    gzip -t "$out/pg_dumpall.sql.gz"
    docker exec "$DB_CONTAINER" cat /etc/postgresql-custom/pgsodium_root.key > "$out/pgsodium_root.key"
    [ -s "$out/pgsodium_root.key" ] || die "pgsodium key backup is empty"
    (cd "$SUPABASE_DIR" && tar czf "$out/files.tar.gz" \
        .env .supabase-version docker-compose*.yml volumes/storage volumes/snippets volumes/functions)
    log "backup done: $(du -sh "$out" | cut -f1)"
    if [ "$BACKUP_KEEP_DAYS" -gt 0 ] 2>/dev/null; then
        find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_KEEP_DAYS" -exec rm -rf {} + || true
    fi
    printf '%s\n' "$out"
}

# --- update ----------------------------------------------------------------
# do_update returns 0 = updated / nothing to do, 3 = refused before changing
# anything (old stack stays as is), 2 = update.sh left merge conflicts (files
# changed, containers not recreated), 1 = failed part-way (files may have changed).

# Print upgrades.json entries (from the TARGET release) in (from, to] that need
# manual action, one "<version> <breaking> <gate>" per line.
gated_releases() {
    local from=$1 to=$2 manifest
    manifest=$(curl -fsSL "https://raw.githubusercontent.com/supabase/supabase/$to/docker/upgrades.json") \
        || die "could not fetch upgrades.json for $to"
    printf '%s' "$manifest" | jq -r --arg f "$(ver "$from")" --arg t "$(ver "$to")" '
        def v: split(".") | map(tonumber? // 0);
        to_entries[] | select(.key | test("^[0-9]+\\.[0-9]+")) |
        select((.key|v) > ($f|v) and (.key|v) <= ($t|v)) |
        select(.value.breaking == true or (.value.gate // "") != "") |
        "\(.key) \(.value.breaking) \(.value.gate // "-")"'
    printf '%s' "$manifest" | jq -r --arg f "$(ver "$from")" --arg t "$(ver "$to")" '
        def v: split(".") | map(tonumber? // 0);
        to_entries[] | select(.key | test("^[0-9]+\\.[0-9]+")) |
        select((.key|v) > ($f|v) and (.key|v) <= ($t|v)) |
        "[\(.key)] " + ((.value.requires // []) | join(" | "))' >&2
}

do_update() {  # do_update <target> [auto]
    local target=$1 auto=${2:-} from gates unacked="" v rc bdir
    from=$(current_ref) || die "no .supabase-version"
    [ "$from" != "$target" ] || { log "already on $target"; return 0; }
    case "$target" in self-hosted/v*) ;; *) set_state blocked "target '$target' is not a self-hosted/vX.Y.Z tag"; return 3 ;; esac
    case "$from" in
        self-hosted/v*)
            if ver_gt "$(ver "$from")" "$(ver "$target")"; then
                set_state blocked "downgrade $from -> $target is not supported (restore a backup instead)"; return 3
            fi ;;
    esac
    log "update requested: $from -> $target"
    log "manual-action notes for this range (from upstream upgrades.json):"
    gates=$(gated_releases "$from" "$target") || { set_state error "could not read upgrades.json for $target"; return 1; }
    while read -r v _ _; do
        [ -n "$v" ] || continue
        if [ "$auto" = auto ] || ! printf ',%s,' "$ACK_BREAKING" | tr -d ' ' | grep -q ",$v,"; then
            unacked="$unacked $v"
        fi
    done <<< "$gates"
    if [ -n "$unacked" ]; then
        set_state blocked "update $from -> $target crosses breaking/gated release(s):$unacked. Read upstream CHANGELOG + upgrades.json, do the manual steps, then set ACK_BREAKING=$(echo "$unacked" | xargs | tr ' ' ',') and redeploy. Stack left running on $from."
        return 3  # refused before touching anything
    fi

    set_state updating "$from -> $target: backup"
    marker="$STATE_DIR/backup-before-$(ver "$target")"
    if [ ! -f "$marker" ]; then
        bdir=$(do_backup "pre-$(ver "$target")" | tail -n1) || { set_state error "pre-update backup failed; not updating"; return 1; }
        printf '%s\n' "$bdir" > "$marker"
    else
        log "pre-update backup already taken: $(cat "$marker")"
    fi

    set_state updating "$from -> $target: update.sh"
    # --yes only skips update.sh's own confirmation prompt; we already refused
    # above unless every breaking/gated release is in ACK_BREAKING.
    set +e
    (cd "$SUPABASE_DIR" && sh update.sh --to "$target" --yes)
    rc=$?
    set -e
    if [ "$rc" = 2 ]; then
        set_state blocked "update.sh left merge CONFLICTS in $SUPABASE_DIR (files with <<<<<<< markers). Containers were NOT recreated and keep running $from. Resolve via 'manager compose config' / an SSH shell, re-run 'manager update'."
        return 2
    elif [ "$rc" != 0 ]; then
        set_state error "update.sh failed (exit $rc); containers not recreated"
        return 1
    fi
    if [ -f "$SUPABASE_DIR/update.sh.dist" ]; then
        mv -f "$SUPABASE_DIR/update.sh.dist" "$SUPABASE_DIR/update.sh"
        log "took new upstream update.sh"
    fi
    sync_overrides
    apply_env_overrides
    set_state updating "$from -> $target: pull + recreate"
    run_sh pull || { set_state error "image pull failed; old containers still running"; return 1; }
    run_sh recreate || { set_state error "recreate failed - check 'manager status' / 'manager logs <svc>'"; return 1; }
    set_state ok "updated $from -> $target"
}

# Report-only: what would `manager update` do? Writes nothing, takes no lock.
do_update_dry() {  # do_update_dry <target>
    local target=$1 from gates v unacked=""
    from=$(current_ref) || die "no .supabase-version"
    [ "$from" != "$target" ] || { log "already on $target - nothing to do"; return 0; }
    case "$target" in self-hosted/v*) ;; *) die "target '$target' is not a self-hosted/vX.Y.Z tag" ;; esac
    case "$from" in
        self-hosted/v*) ! ver_gt "$(ver "$from")" "$(ver "$target")" \
            || warn "a real update would be REFUSED: downgrade $from -> $target is not supported" ;;
    esac
    log "DRY RUN $from -> $target: no backup, nothing written, nothing restarted"
    log "manual-action notes for this range (from upstream upgrades.json):"
    gates=$(gated_releases "$from" "$target") || die "could not read upgrades.json for $target"
    while read -r v _ _; do
        [ -n "$v" ] || continue
        printf ',%s,' "$ACK_BREAKING" | tr -d ' ' | grep -q ",$v," || unacked="$unacked $v"
    done <<< "$gates"
    if [ -n "$unacked" ]; then
        warn "a real update would be REFUSED: breaking/gated release(s) not in ACK_BREAKING:$unacked"
    else
        log "breaking-release gate: would pass"
    fi
    (cd "$SUPABASE_DIR" && sh update.sh --to "$target" --dry-run)
}

cmd_update() {  # cmd_update [--to T] [--dry-run]
    local t="" dry=0 pinned
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) [ $# -ge 2 ] && [ -n "$2" ] || die "--to needs a self-hosted/vX.Y.Z tag"; t=$2; shift 2 ;;
            --dry-run) dry=1; shift ;;
            *) die "unknown update option: $1 (usage: manager update [--to T] [--dry-run])" ;;
        esac
    done
    [ -n "$t" ] || t=$(resolve_target)
    if [ "$dry" = 1 ]; then do_update_dry "$t"; return; fi
    take_lock 600
    do_update "$t"  # not in a condition: keep set -e; a non-zero return exits with it
    pinned=$(resolve_target 2>/dev/null || true)
    if [ -n "$pinned" ] && [ "$pinned" != "$t" ] && [ "$(current_ref 2>/dev/null)" = "$t" ]; then
        warn "SUPABASE_VERSION resolves to $pinned but the stack is now on $t. Set SUPABASE_VERSION=$t (Openship env of supabase-manager) - otherwise the next manager restart reconciles towards $pinned (a downgrade is refused and leaves the manager 'blocked')."
    fi
}

# --- reconcile ---------------------------------------------------------------

reconcile() {
    local target cur
    take_lock 1800
    mkdir -p "$SUPABASE_DIR" "$BACKUP_DIR"
    docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon (is /var/run/docker.sock mounted?)"
    [ "$(cd "$SUPABASE_DIR" && pwd -P)" = "$SUPABASE_DIR" ] || warn "SUPABASE_DIR should be an absolute, symlink-free path"
    if ! target=$(resolve_target) || [ -z "$target" ]; then
        set_state error "could not resolve SUPABASE_VERSION=$SUPABASE_VERSION"
        return 1
    fi

    if ! cur=$(current_ref); then
        install_fresh "$target" || return 1
    fi
    sync_overrides || { set_state error "could not apply COMPOSE_OVERRIDES=$COMPOSE_OVERRIDES"; return 1; }
    apply_env_overrides || { set_state error "could not apply SUPABASE_ENV_* values"; return 1; }
    cur=$(current_ref)
    if [ "$cur" != "$target" ]; then
        local urc=0
        do_update "$target" || urc=$?
        if [ "$urc" = 3 ]; then
            # Nothing was changed: keep the CURRENT version running, stay blocked.
            log "keeping $(current_ref) up while the update is blocked"
            run_sh start || warn "'run.sh start' reported problems"
            return 1
        elif [ "$urc" != 0 ]; then
            return 1
        fi
    fi
    log "ensuring stack is up ($(current_ref))"
    if run_sh start; then
        set_state ok "running $(current_ref)"
    else
        set_state error "'run.sh start' did not report all services healthy - see 'manager status'"
        return 1
    fi
}

status() {
    printf 'manager: %s\n' "$(cat "$STATE_FILE" 2>/dev/null || echo 'no state yet')"
    printf 'version: %s (target %s)\n' "$(current_ref 2>/dev/null || echo none)" "$SUPABASE_VERSION"
    printf 'overrides: %s\n' "$(grep -E '^COMPOSE_FILE=' "$SUPABASE_DIR/.env" 2>/dev/null | cut -d= -f2-)"
    compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
}

health() {
    local st bad
    st=$(cut -d' ' -f1 "$STATE_FILE" 2>/dev/null || echo none)
    case "$st" in ok|installing|updating) ;; *) echo "manager state: $st"; return 1 ;; esac
    [ "$st" = ok ] || return 0
    bad=$(compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null \
        | awk '$2 != "running" || ($3 != "" && $3 != "healthy") {print}')
    if [ -n "$bad" ]; then echo "unhealthy: $bad"; return 1; fi
    return 0
}

main_loop() {
    local next_check
    trap 'log "SIGTERM: manager exiting; Supabase containers keep running"; exit 0' TERM INT
    # Subshell: the lock (fd 9) is released when reconcile finishes, so that
    # 'manager backup' / 'manager update' from a terminal can take it later.
    ( reconcile ) || warn "reconcile did not complete; staying up so you can inspect (manager status)"
    next_check=$(( $(date +%s) + UPDATE_CHECK_INTERVAL ))
    while :; do
        sleep 60 & wait $! || true
        if [ "$AUTO_UPDATE" = true ] && [ "$SUPABASE_VERSION" = latest ] && [ "$(date +%s)" -ge "$next_check" ]; then
            next_check=$(( $(date +%s) + UPDATE_CHECK_INTERVAL ))
            t=$(latest_tag || true)
            c=$(current_ref || true)
            if [ -n "$t" ] && [ "$t" != "$c" ]; then
                log "auto-update: $c -> $t (non-breaking only)"
                ( take_lock 60 && do_update "$t" auto ) || warn "auto-update did not apply"
            fi
        fi
    done
}

cmd=${1:-run}
[ $# -gt 0 ] && shift
case "$cmd" in
    run)       main_loop ;;
    reconcile) reconcile ;;
    status)    status ;;
    health)    health ;;
    backup)    take_lock 600; do_backup manual ;;
    update)    cmd_update "$@" ;;
    logs)      run_sh logs "$@" ;;
    psql)      exec docker exec -it "$DB_CONTAINER" psql -U postgres "$@" ;;
    compose)   compose "$@" ;;
    -h|--help|help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command: $cmd (try: manager help)" ;;
esac
