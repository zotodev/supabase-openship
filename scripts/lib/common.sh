# shellcheck shell=sh
# shellcheck disable=SC2034  # variables are used by the scripts that source this
# Shared helpers. Source from scripts: . "$(dirname "$0")/lib/common.sh"

set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
UPSTREAM_DIR="$REPO_ROOT/upstream"
COMPOSE_OUT="$REPO_ROOT/openship-compose.yml"
VARS_OUT="$REPO_ROOT/openship.vars.json"
TOOL="$REPO_ROOT/scripts/lib/compose_tool.py"

log()  { printf '===> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not on PATH"
    done
}

load_conf() {
    [ -f "$REPO_ROOT/render.conf" ] || die "render.conf not found"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/render.conf"
    : "${SUPABASE_ROOT:?set in render.conf}" "${BIND_ADDR:?set in render.conf}"
    UPSTREAM_OVERRIDES=${UPSTREAM_OVERRIDES:-}
    ASYMMETRIC_KEYS=${ASYMMETRIC_KEYS:-1}
}

upstream_ref() {
    grep -E '^ref=' "$UPSTREAM_DIR/.supabase-version" | head -n1 | cut -d= -f2-
}
