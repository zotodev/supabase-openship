#!/bin/sh
#
# Laptop side: upgrade upstream/ to a newer self-hosted Supabase release with
# upstream's own update.sh (3-way merge + breaking-change gate from
# upgrades.json), re-render the Openship files, and commit. Nothing is pushed.
#
#   sh scripts/upgrade.sh [--to self-hosted/vX.Y.Z] [--yes] [--no-commit]
#
# Before running: take a backup on the server (Openship Job "supabase-backup",
# or: ssh <server> 'cd /srv/supabase && sh scripts/backup.sh').
# After it: git push -> run Job "supabase-sync" -> Redeploy in Openship.
#
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
need git jq docker python3

to="" yes="" commit=1
while [ $# -gt 0 ]; do
    case "$1" in
        --to) to=$2; shift 2 ;;
        --yes|-y) yes="--yes"; shift ;;
        --no-commit) commit=0; shift ;;
        *) die "unknown option: $1" ;;
    esac
done

cd "$REPO_ROOT" || exit 1
[ -z "$(git status --porcelain)" ] || die "working tree not clean - commit or stash first"

from=$(upstream_ref)
log "Current upstream: $from"

printf 'Have you taken a fresh backup on the server (scripts/backup.sh)? [y/N]: '
read -r ans
case "$ans" in y|Y|yes) ;; *) die "Take a backup first (Storage/DB migrations can be one-way)." ;; esac

old_keys=$(mktemp)
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' upstream/.env.example | cut -d= -f1 | sort > "$old_keys"

# update.sh needs a .env; upstream/ is pristine, so give it the example file.
# (.env merging is handled below against your real ./.env.)
cp upstream/.env.example upstream/.env
cleanup() { rm -f "$REPO_ROOT/upstream/.env" "$old_keys"; rm -rf "$REPO_ROOT/upstream/backups"; }
trap cleanup EXIT INT TERM

set --
[ -n "$to" ] && set -- --to "$to"
log "Preview (update.sh --dry-run)"
( cd upstream && sh update.sh --dry-run "$@" )
printf 'Apply this update? [y/N]: '
read -r ans
case "$ans" in y|Y|yes) ;; *) die "Aborted; nothing changed." ;; esac

# shellcheck disable=SC2086
( cd upstream && sh update.sh $yes "$@" ) || {
    rc=$?
    [ "$rc" = 2 ] && die "update.sh reported conflicts in upstream/ (it should be pristine - did someone edit it?). Resolve, then re-run."
    die "update.sh failed (exit $rc)"
}
if [ -f upstream/update.sh.dist ]; then
    mv -f upstream/update.sh.dist upstream/update.sh
    log "Took the new upstream update.sh"
fi
new=$(upstream_ref)
log "Upstream now: $new"

# New .env keys: append upstream defaults to your local .env for review.
new_keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' upstream/.env.example | cut -d= -f1 | sort | comm -13 "$old_keys" -)
if [ -n "$new_keys" ]; then
    warn "New .env keys in $new: $(echo "$new_keys" | tr '\n' ' ')"
    if [ -f .env ]; then
        { echo ""; echo "# Added by scripts/upgrade.sh for $new - review"; } >> .env
        for k in $new_keys; do
            grep -q "^$k=" .env || grep -E "^$k=" upstream/.env.example | head -n1 >> .env
        done
    fi
fi

sh scripts/render.sh
if [ -f .env ]; then
    sh scripts/bootstrap.sh env
fi

# Manual steps for releases in (from, to] from upgrades.json.
fv=$(printf '%s' "$from" | sed 's#^self-hosted/v##')
tv=$(printf '%s' "$new" | sed 's#^self-hosted/v##')
log "Manual steps from upstream/upgrades.json for ($fv, $tv]:"
jq -r --arg f "$fv" --arg t "$tv" '
  def v: split(".") | map(tonumber? // 0);
  to_entries[] | select(.key | test("^[0-9]")) |
  select((.key|v) > ($f|v) and (.key|v) <= ($t|v)) |
  "[\(.key)]\(if .value.breaking then " BREAKING" else "" end)\n" +
  (if .value.gate then "  gate: \(.value.gate)  (upstream script assumes `docker compose` + container names; under Openship do it by hand)\n" else "" end) +
  ((.value.requires // []) | map("  - " + .) | join("\n"))' upstream/upgrades.json || true

git add -A
git status --short | head -50
if [ "$commit" = 1 ]; then
    git commit -q -m "Upgrade self-hosted Supabase $from -> $new"
    log "Committed. Next: git push; Openship Job 'supabase-sync'; import .env.openship if keys changed; Redeploy."
else
    log "Staged, not committed (--no-commit)."
fi
log "Read upstream/CHANGELOG.md for every release between $from and $new."
