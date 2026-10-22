#!/usr/bin/env bash
# kb-check.sh — read-only shape check of the local knowledge base (work/knowledge/).
# Called by the audit pre-flight, by verify-onboarding.sh, and by the agent after a
# capture (docs/capture.md → Self-check). Detects, never repairs.
#
#   kb-check.sh [dir]   -> {"dir", "notes", "problems":[{path, problem, severity}]}
#
# Checks: the layout (index.md, USAGE_GUIDE.md, sources/), every note's front matter
# (`sources:` with at least one Slack permalink, `updated:` as a UTC date), and a
# credential scan. A credential hit names the FILE, never the match. Content is
# never judged here — what is worth keeping is the agent's call (docs/capture.md).

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
DIR="${1:-$WORK/knowledge}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null || true

PROBLEMS='[]'
problem() { # <path> <severity> <problem>
  PROBLEMS="$(printf '%s' "$PROBLEMS" | jq -c --arg p "$1" --arg s "$2" --arg m "$3" '. + [{path:$p, severity:$s, problem:$m}]')"
}

# credential shapes (the same families scripts/log.sh masks)
SECRET_RE='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abeprs]-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}|hooks\.slack\.com/services/|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{32,}'
PERMALINK_RE='https://[A-Za-z0-9.-]+\.slack\.com/archives/[CDG][A-Z0-9]+/p[0-9]{16}'

if [ ! -d "$DIR" ]; then
  jq -nc --arg d "$DIR" '{dir:$d, notes:0, problems:[{path:".", severity:"fail", problem:"knowledge base directory missing"}]}'
  exit 0
fi

[ -f "$DIR/index.md" ] || problem index.md fail "missing — the knowledge base has no entry page"
[ -f "$DIR/USAGE_GUIDE.md" ] || problem USAGE_GUIDE.md warn "missing — readers of a shared knowledge base get no orientation"
[ -d "$DIR/sources" ] || problem sources/ fail "missing — the per-fact permalink log has no home"

NOTES=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#"$DIR"/}"
  case "$rel" in (index.md|USAGE_GUIDE.md|sources/*) continue;; esac
  NOTES=$((NOTES + 1))
  fm="$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 {print}' "$f")"
  if [ -z "$fm" ]; then problem "$rel" fail "no front matter (--- block with sources: and updated:)"; continue; fi
  printf '%s\n' "$fm" | grep -qE '^updated:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    || problem "$rel" fail "front matter has no updated: YYYY-MM-DD"
  printf '%s\n' "$fm" | grep -qE '^sources:' \
    || problem "$rel" fail "front matter has no sources: list"
  printf '%s\n' "$fm" | grep -qE "$PERMALINK_RE" \
    || problem "$rel" fail "sources: carries no Slack permalink"
done < <(find "$DIR" -type f -name '*.md' ! -name '.*' 2>/dev/null | sort)

while IFS= read -r f; do
  [ -n "$f" ] || continue
  problem "${f#"$DIR"/}" fail "credential-shaped string — redact the field and tell the owner to rotate it"
done < <(grep -rlE "$SECRET_RE" "$DIR" 2>/dev/null | sort)

# a dot-file is hidden from listings, so readers miss a note there
while IFS= read -r f; do
  [ -n "$f" ] || continue
  problem "${f#"$DIR"/}" warn "dot-named path — rename it so readers see it"
done < <(find "$DIR" -mindepth 1 -name '.*' ! -name '.*.lock' 2>/dev/null | sort)

jq -nc --arg d "$DIR" --argjson n "$NOTES" --argjson p "$PROBLEMS" '{dir:$d, notes:$n, problems:$p}'
exit 0
