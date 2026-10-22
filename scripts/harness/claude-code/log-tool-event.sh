#!/usr/bin/env bash
# Claude Code harness adapter — hook target for PostToolUseFailure, PermissionDenied
# and StopFailure (registered by install.sh; event shapes: docs/logging.md). Reads the
# hook JSON from stdin and writes one events-log line:
#
#   PostToolUseFailure on mcp__slack__* -> level=error, event=slack_read_failed
#   PostToolUseFailure, anything else   -> level=error, event=tool_failure
#   PermissionDenied                    -> level=warn,  event=classifier_block
#   StopFailure                         -> level=error, event=api_failure
#
# Ids, tool names, classes and short error text only — never a tool's input or output
# body, because a Slack read's output is the owner's private conversation. Read-only
# inspect commands (grep, ls, find, test, …) answer "no match" with a non-zero exit;
# they are not failures.
#
# No-op unless a deployed instance's work/CONFIG.md exists. Always exits 0.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

evt="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] && export LOG_RUN_ID="$sid"
. "$(cd "$(dirname "$0")/../.." && pwd)/log.sh"
[ -f "$LOG_WORK/CONFIG.md" ] || exit 0

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)"
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null | tr '\n' ' ' | cut -c1-300)"

is_inspect() { # <command-string> — basename of the last element of a chain
  local last base
  last="$1"
  last="${last##*&& }"; last="${last##*|| }"; last="${last##*; }"; last="${last##*| }"
  last="${last#"${last%%[![:space:]]*}"}"
  while :; do
    case "$last" in ([A-Za-z_][A-Za-z_0-9]*=*\ *) last="${last#* }";; (*) break;; esac
  done
  base="${last%%[[:space:]]*}"; base="${base##*/}"
  case "$base" in (grep|egrep|fgrep|rg|ls|find|fd|test|'['|command|stat|which|type) return 0;; esac
  return 1
}

case "$evt" in
  (PostToolUseFailure)
    err="$(printf '%s' "$INPUT" | jq -r '[.error, .tool_response.error, .message] | map(select(. != null and . != "")) | .[0] // "non-zero exit"
      | if type == "string" then . else tojson end' 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    case "$tool" in
      (mcp__slack__*) logev error slack_read_failed "$tool: $err";;
      (Bash) is_inspect "$cmd" && exit 0
             logev error tool_failure "Bash [$cmd]: $err";;
      (*) logev error tool_failure "$tool: $err";;
    esac;;
  (PermissionDenied)
    reason="$(printf '%s' "$INPUT" | jq -j '.reason // "no reason given"' 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    logev warn classifier_block "$tool${cmd:+ [$cmd]} — $reason";;
  (StopFailure)
    err="$(printf '%s' "$INPUT" | jq -j '.error // "unknown"' 2>/dev/null | tr -c 'a-z_' '_' | cut -c1-40)"
    logev error api_failure "${err:-unknown}: turn ended on an API error";;
esac
exit 0
