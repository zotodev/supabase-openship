#!/bin/sh
#
# Server side: bring the host clone at $SUPABASE_ROOT up to date with the
# repo, so bind-mounted config (config/, functions/) matches the commit
# Openship deploys. Run as an Openship Job (manual trigger) or over SSH:
#
#   cd /srv/supabase && sh scripts/sync-host.sh [--ref <branch|sha>]
#
# Bind-mounted single files are swapped on disk by git; running containers
# keep the old file until Openship recreates them (Redeploy). So: sync first,
# then Redeploy.
#
# git pull may rewrite this very file; run from a temp copy.
if [ -z "${SYNC_HOST_REEXEC:-}" ]; then
    _self=$(mktemp)
    cp "$0" "$_self"
    SYNC_HOST_REEXEC=$(cd "$(dirname "$0")" && pwd) exec sh "$_self" "$@"
fi
REPO_ROOT=$(cd "$SYNC_HOST_REEXEC/.." && pwd)
set -eu
log()  { printf '===> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v git >/dev/null 2>&1 || die "git is required"
# shellcheck disable=SC1091
. "$REPO_ROOT/render.conf"

ref=""
[ "${1:-}" = "--ref" ] && ref=${2:-}

cd "$REPO_ROOT"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    die "host clone has local modifications to tracked files - refusing to pull (git status)"
fi
before=$(git rev-parse --short HEAD)
git fetch --quiet origin
if [ -n "$ref" ]; then
    git checkout --quiet "$ref"
    git pull --quiet --ff-only 2>/dev/null || true
else
    git pull --quiet --ff-only
fi
after=$(git rev-parse --short HEAD)
log "host clone: $before -> $after ($(git log -1 --format=%s))"
sh "$REPO_ROOT/scripts/bootstrap.sh" host
if [ "$before" != "$after" ]; then
    git diff --stat "$before" "$after" -- config functions openship-compose.yml || true
    log "Now Redeploy the project in Openship so containers pick up the new files."
fi
