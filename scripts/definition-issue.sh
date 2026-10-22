#!/usr/bin/env bash
# definition-issue.sh — the ONE path by which this agent opens an issue on its own
# definition repository (docs/audit.md → Definition bugs). The definition repo is
# public and the instance reads its owner's Slack, so an issue there must say which
# part of the definition fails and how to fix it — and nothing about the instance.
#
#   definition-issue.sh check <body-file> [title]  -> {"outcome":"clean"|"blocked", "hits":[…]}
#   definition-issue.sh file <title> <body-file>   -> {"outcome":"filed"|"exists"|"disabled"|"blocked"|"error", …}
#
# `file` applies the definition_issues switch (missing = disabled), scans title and
# body, dedups by exact title among open issues, and only then creates. A `blocked`
# outcome names the CATEGORY of each hit, never the matched text: rewrite in general
# words (placeholders: alice, U0123ABCD, acme/widgets) and try once more.
#
# The scan blocks: every value and table entry of work/CONFIG.md; Slack ids, user
# mentions, permalinks and channel names; URLs outside the definition repo; issue/PR
# numbers; SHAs; dates and times; e-mail addresses; IPs; credential shapes; anything in
# backticks or a fenced block; paths; identifier-shaped words (snake_case, digits in a
# word); and capitalised words that occur nowhere in the definition's own text.

set -u
export LC_ALL=C
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null || true
. "$SCRIPT_DIR/lib/config.sh" || { echo '{"outcome":"error","reason":"cannot source lib/config.sh"}'; exit 1; }
LOG_JOB="${LOG_JOB:-audit}"
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi

# placeholder examples the definition itself uses — never hits
PLACEHOLDERS='alice|U0123ABCD|acme/widgets|C0123ABCD|D0123ABCD'

scan() { # <text> -> one category per line
  local t="$1" v
  t="$(printf '%s' "$t" | sed -E "s#($PLACEHOLDERS)##g")"
  # instance values: every scalar value and every table cell of CONFIG.md
  if [ -f "$CONFIG" ]; then
    while IFS= read -r v; do
      [ "${#v}" -ge 4 ] || continue
      case "$v" in (true|false|none|local|github|enabled|disabled|default|info|debug|always|silent-when-nothing|knowledge/) continue;; esac
      printf '%s' "$t" | grep -qiF -- "$v" && echo "a configuration value"
    done < <( { sed -nE 's/^- [a-z_]+:[[:space:]]*(.*)$/\1/p' "$CONFIG";
                grep '^|' "$CONFIG" | tr '|' '\n'; } | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sort -u)
  fi
  local defrepo; defrepo="$(cfg definition_repo)"
  m() { printf '%s' "$t" | grep -qE -- "$1" && echo "$2"; }
  m '<@[UW][A-Z0-9]+>|(^|[^A-Za-z0-9])[UWCDG][A-Z0-9]{8,}([^A-Za-z0-9]|$)' "a Slack id or mention"
  m '\.slack\.com/' "a Slack link"
  m '(^|[[:space:]])#[a-z0-9][a-z0-9_-]+' "a channel name"
  if [ -n "$defrepo" ]; then
    printf '%s' "$t" | grep -oE 'https?://[^[:space:])>]+' | grep -vF -- "$defrepo" | grep -q . && echo "a URL outside the definition repo"
  else
    m 'https?://' "a URL"
  fi
  m '(^|[^A-Za-z0-9&])#[0-9]+' "an issue or PR number"
  m '(^|[^A-Za-z0-9])[0-9a-f]{7,40}([^A-Za-z0-9]|$)' "a SHA"
  m '[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}:[0-9]{2}' "a date or time"
  m '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "an e-mail address"
  m '(^|[^0-9])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9]|$)' "an IP address"
  m 'gh[pousr]_|github_pat_|xox[abeprs]-|xapp-|PRIVATE KEY' "a credential"
  m '`' "a token in backticks or a fenced block"
  m '(^|[[:space:]])(~|\.{0,2})/[A-Za-z0-9_.-]+|[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\.[a-z]{1,4}([^A-Za-z]|$)' "a path"
  m '(^|[^A-Za-z0-9])[a-z]+_[a-z0-9_]+' "an identifier-shaped word"
  m '(^|[^A-Za-z0-9])[A-Za-z]+[0-9][A-Za-z0-9]*' "a word with a digit in it"
  # capitalised words the definition never uses
  local corpus w
  corpus="$(cd "$DEF_DIR" && cat AGENTS.md CHANGELOG.md CLAUDE.md ONBOARDING.md README.md docs/*.md 2>/dev/null)"
  for w in $(printf '%s' "$t" | grep -oE '(^|[^A-Za-z])[A-Z][a-z]{2,}' | grep -oE '[A-Z][a-z]+' | sort -u); do
    printf '%s' "$corpus" | grep -qwF -- "$w" || { echo "a capitalised word the definition never uses"; break; }
  done
  # non-ASCII letters
  printf '%s' "$t" | LC_ALL=C grep -q '[^ -~[:space:]]' && echo "a character outside ASCII"
  return 0
}

cmd="${1:-}"
case "$cmd" in
  check)
    f="${2:-}"; [ -r "$f" ] || { echo '{"outcome":"error","reason":"body file unreadable"}'; exit 1; }
    hits="$(scan "$(cat "$f") ${3:-}" | sort -u | jq -R . | jq -sc .)"
    jq -nc --argjson h "$hits" '{outcome: (if ($h | length) == 0 then "clean" else "blocked" end), hits: $h}'
    ;;
  file)
    title="${2:-}"; f="${3:-}"
    [ -n "$title" ] && [ -r "$f" ] || { echo '{"outcome":"error","reason":"usage: file <title> <body-file>"}'; exit 1; }
    [ "$(cfg definition_issues)" = enabled ] || { echo '{"outcome":"disabled"}'; exit 0; }
    hits="$(scan "$title
$(cat "$f")" | sort -u | jq -R . | jq -sc .)"
    if [ "$(printf '%s' "$hits" | jq length)" -gt 0 ]; then
      logev warn definition_issue "blocked: $(printf '%s' "$hits" | jq -r 'join(", ")')"
      jq -nc --argjson h "$hits" '{outcome:"blocked", hits:$h}'; exit 0
    fi
    ref="$(cfg definition_repo)"
    [ -n "$ref" ] || ref="$(git -C "$HOME_DIR" remote get-url origin 2>/dev/null | sed -E 's#^https?://##; s#^git@([^:]+):#\1/#; s#\.git$##')"
    host=github.com; slug="$ref"
    case "$ref" in (*.*/*/*) host="${ref%%/*}"; slug="${ref#*/}";; esac
    [ -n "$slug" ] || { echo '{"outcome":"error","reason":"definition repo unresolved"}'; exit 1; }
    existing="$(gh issue list -R "$host/$slug" --state open --limit 100 --json title,url 2>/dev/null)" \
      || { echo '{"outcome":"error","reason":"could not list open issues on the definition repo"}'; exit 1; }
    url="$(printf '%s' "$existing" | jq -r --arg t "$title" '[.[] | select(.title == $t)][0].url // empty')"
    if [ -n "$url" ]; then jq -nc --arg u "$url" '{outcome:"exists", url:$u}'; exit 0; fi
    url="$(gh issue create -R "$host/$slug" --title "$title" --body-file "$f" 2>/dev/null | tail -1)" \
      || { echo '{"outcome":"error","reason":"gh issue create failed"}'; exit 1; }
    logev info definition_issue "filed"
    jq -nc --arg u "$url" '{outcome:"filed", url:$u}'
    ;;
  *) echo '{"outcome":"error","reason":"usage: definition-issue.sh check <body-file> [title] | file <title> <body-file>"}'; exit 2;;
esac
exit 0
