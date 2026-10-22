#!/usr/bin/env bash
# Claude Code harness adapter for slack-knowledge-sync — keeps three parts current in
# ~/.claude/settings.json (idempotent; what each part is: docs/logging.md → Harness
# adapter):
#
#   hooks           PreToolUse guard.sh (Slack read-only wall) and the logging hook
#                   log-tool-event.sh (PostToolUseFailure, PermissionDenied, StopFailure)
#   automode-rules  the [slack-knowledge-sync] auto-mode classifier rules for this
#                   agent's documented writes
#   tool-deny       permissions.deny ← denied-tools.txt (every Slack write tool first)
#
#   install.sh           # install or refresh
#   install.sh --check   # print the parts not current, or nothing
#
# On another harness it prints a notice and exits 0. Changes take effect from the
# next session. The operator's own entries in settings.json are kept.
set -u

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
# CLAUDECODE is set inside a Claude Code session; PLATFORM_HARNESS is set by the
# platform's harness image for every process of the pod, the schedule prechecks too
if [ "${CLAUDECODE:-}" != "1" ] && [ "${PLATFORM_HARNESS:-}" != "claude-code" ] && [ "${SKS_FORCE_CLAUDE:-}" != "1" ]; then
  [ "$CHECK" = 1 ] && exit 0
  echo "not the Claude Code harness (CLAUDECODE != 1) — nothing installed. Without this adapter the Slack write tools are NOT blocked: tell the owner (docs/logging.md → Harness adapter)."
  exit 0
fi
command -v jq >/dev/null 2>&1 || { [ "$CHECK" = 1 ] && echo "hooks automode-rules tool-deny" || echo "jq missing — cannot install"; exit 0; }

HOME_DIR="${HOME:-/home/agent}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME_DIR/.claude/settings.json}"
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$ADAPTER_DIR/guard.sh"
LOGHOOK="$ADAPTER_DIR/log-tool-event.sh"
OWNED="$(dirname "$SETTINGS")/.slack-knowledge-sync-denied-tools.json"
TAG="[slack-knowledge-sync]"

DENY="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$ADAPTER_DIR/denied-tools.txt" 2>/dev/null \
  | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null)"
[ -n "$DENY" ] || DENY='[]'
PREV="$(jq -c 'if type == "array" then map(strings) else [] end' "$OWNED" 2>/dev/null)"
[ -n "$PREV" ] || PREV='[]'

AM_ENV="$(jq -nc --arg h "$HOME_DIR" --arg t "$TAG" '[
  "\($t) This is a personal knowledge-capture agent. It reads its owner'"'"'s Slack through the read-only slack MCP tools and writes markdown notes under \($h)/work/knowledge/. It never writes to Slack.",
  "\($t) It reports to its owner only through mcp__platform-outbound__send_channel_message or mcp__platform-outbound__reply, in the owner'"'"'s own direct message with the DAM bot."]')"
AM_ALLOW="$(jq -nc --arg h "$HOME_DIR" --arg t "$TAG" '[
  "\($t) Creating, editing or moving markdown files under \($h)/work/knowledge/ and \($h)/work/state/: that is the knowledge base and its capture ledger.",
  "\($t) Running bash \($h)/scripts/state.sh, \($h)/scripts/kb-check.sh, \($h)/scripts/preflight.sh, \($h)/scripts/monitor.sh or \($h)/scripts/verify-onboarding.sh with any arguments: they record captures, check the knowledge base and compute the run worklists.",
  "\($t) Running bash \($h)/scripts/work-backup.sh persist or restore: it backs up \($h)/work/ to the private repository GITHUB_REPO_WORK names.",
  "\($t) In GitHub mode, cloning the kb_repo of \($h)/work/CONFIG.md into /tmp/slack-knowledge-sync-*, pushing a new capture/* branch there and opening one pull request with gh pr create: that is how a capture reaches a shared knowledge base. Never a push to the default branch.",
  "\($t) Sending one direct message to the owner_dm_chat_id of \($h)/work/CONFIG.md with mcp__platform-outbound__send_channel_message: the capture, sweep, audit and monitor reports go there and nowhere else."]')"

HOOKS_JQ='
  def own($k; $cmd): [.hooks[$k][]? | select([.hooks[]?.command] | index($cmd) | not)];
  .hooks //= {} |
  .hooks.PreToolUse = (own("PreToolUse"; $g) + [{matcher:"mcp__slack__.*|Bash", hooks:[{type:"command", command:$g, timeout:10}]}]) |
  .hooks.PostToolUseFailure = (own("PostToolUseFailure"; $l) + [{matcher:"*", hooks:[{type:"command", command:$l, timeout:15}]}]) |
  .hooks.PermissionDenied = (own("PermissionDenied"; $l) + [{matcher:"*", hooks:[{type:"command", command:$l, timeout:10}]}]) |
  .hooks.StopFailure = (own("StopFailure"; $l) + [{hooks:[{type:"command", command:$l, timeout:10}]}])'

if [ "$CHECK" = 1 ]; then
  missing=""
  jq -e --arg g "$GUARD" --arg l "$LOGHOOK" '
      ([.hooks.PreToolUse[]? | select(.matcher == "mcp__slack__.*|Bash") | .hooks[]?.command] | index($g)) != null
      and ([.hooks.PostToolUseFailure[]?.hooks[]?.command] | index($l)) != null
      and ([.hooks.PermissionDenied[]?.hooks[]?.command] | index($l)) != null
      and ([.hooks.StopFailure[]?.hooks[]?.command] | index($l)) != null' "$SETTINGS" >/dev/null 2>&1 \
    || missing="$missing hooks"
  jq -e --argjson e "$AM_ENV" --argjson a "$AM_ALLOW" --arg t "$TAG" '
      def own($k): [.autoMode[$k][]? | strings | select(startswith($t))];
      own("environment") == $e and own("allow") == $a' "$SETTINGS" >/dev/null 2>&1 \
    || missing="$missing automode-rules"
  jq -e --argjson d "$DENY" '($d - (.permissions.deny // [])) == []' "$SETTINGS" >/dev/null 2>&1 \
    || missing="$missing tool-deny"
  printf '%s\n' "${missing# }" | sed '/^$/d'
  exit 0
fi

chmod +x "$GUARD" "$LOGHOOK" 2>/dev/null || true
mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

tmp="$(mktemp "$SETTINGS.XXXXXX")"
if ! jq --arg g "$GUARD" --arg l "$LOGHOOK" --arg t "$TAG" \
      --argjson e "$AM_ENV" --argjson a "$AM_ALLOW" --argjson deny "$DENY" --argjson prev "$PREV" "
    def am(\$k; \$new): .autoMode[\$k] = (((.autoMode[\$k] // [\"\$defaults\"])
        | map(select(type != \"string\" or (startswith(\$t) | not)))) + \$new);
    .autoMode //= {} | am(\"environment\"; \$e) | am(\"allow\"; \$a) |
    $HOOKS_JQ |
    .permissions //= {} |
    .permissions.deny = ([(.permissions.deny // [])[] | select(. as \$x | (\$prev + \$deny) | index([\$x]) | not)] + \$deny)
  " "$SETTINGS" > "$tmp"; then
  rm -f "$tmp"
  echo "install did not complete — settings.json left unchanged"
  exit 0
fi
if jq -e -n --slurpfile o "$SETTINGS" --slurpfile n "$tmp" '$o == $n' >/dev/null 2>&1; then
  rm -f "$tmp"; echo "hooks, auto-mode rules and tool deny list already current ($SETTINGS)"
else
  mv "$tmp" "$SETTINGS"
  echo "installed into $SETTINGS: PreToolUse -> guard.sh; PostToolUseFailure, PermissionDenied, StopFailure -> log-tool-event.sh; $TAG auto-mode rules; $(printf '%s' "$DENY" | jq length) tools -> permissions.deny"
fi
printf '%s\n' "$DENY" > "$OWNED" 2>/dev/null || true
exit 0
