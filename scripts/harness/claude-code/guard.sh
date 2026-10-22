#!/usr/bin/env bash
# Claude Code harness adapter — PreToolUse hook (registered by install.sh for the
# matcher `mcp__slack__.*|Bash`). Enforces the hard rule that Slack is READ-ONLY for
# this agent: the Slack connection acts as the owner, so a write would be the owner
# speaking.
#
#   mcp__slack__<tool>  -> allowed only when slack-tools.txt classifies it `read`;
#                          a `write` tool and an unclassified one are refused.
#   Bash                -> refused when the command reaches Slack directly
#                          (mcp.slack.com, slack.com/api, hooks.slack.com): the
#                          gateway would inject the owner's token into it.
#                          Also refused: any GitHub issue write (gh issue
#                          create/comment/edit/…, a gh api or curl write to
#                          …/issues, an issue GraphQL mutation). This agent writes
#                          issues only on its definition repo, and only through
#                          scripts/definition-issue.sh, which runs gh itself.
#
# A refused call exits 2; the model reads the reason on stderr. The deny list
# (denied-tools.txt) already removes every known write tool; this hook is the wall
# for the tools Slack adds later and for the shell path around the MCP server.
# Fails CLOSED for Slack tools: an unreadable classification file refuses the call.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
# the cheap test first: nothing below concerns a call that mentions neither slack
# nor an issue
case "$INPUT" in (*[sS][lL][aA][cC][kK]*|*[iI][sS][sS][uU][eE]*|*[aA][dD][dD][cC][oO][mM][mM][eE][nN][tT]*) ;; (*) exit 0;; esac

ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_FILE="$ADAPTER_DIR/slack-tools.txt"
. "$ADAPTER_DIR/../../lib/toolpath.sh" 2>/dev/null || true

# tool name without jq when jq is missing: a Slack call must still be judged
if command -v jq >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
else
  TOOL="$(printf '%s' "$INPUT" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

block() { # <reason>
  if [ -f "${WORK_DIR:-${HOME:-/home/agent}/work}/CONFIG.md" ] \
     && . "$ADAPTER_DIR/../../log.sh" 2>/dev/null; then
    logev warn slack_write_blocked "$TOOL — $1"
  fi
  printf 'slack-knowledge-sync: blocked — %s. Slack is read-only for this agent: the Slack connection acts as its owner, so this agent never posts, replies, reacts, edits, drafts, schedules, creates or uploads anything in Slack (CLAUDE.md → Hard invariants). Report to the owner with mcp__platform-outbound__send_channel_message to owner_dm_chat_id instead.\n' "$1" >&2
  exit 2
}

issue_block() {
  if [ -f "${WORK_DIR:-${HOME:-/home/agent}/work}/CONFIG.md" ] \
     && . "$ADAPTER_DIR/../../log.sh" 2>/dev/null; then
    logev warn definition_issue "guard blocked a direct issue write"
  fi
  printf 'slack-knowledge-sync: blocked — a GitHub issue write by hand. This agent opens an issue only on its own definition repository, only through `bash "$HOME/scripts/definition-issue.sh" file "<title>" <body-file>`, which applies the definition_issues switch and the instance-data scan first (docs/audit.md → Definition bugs). Captures in GitHub mode are pull requests, never issues.\n' >&2
  exit 2
}

case "$TOOL" in
  (mcp__slack__*)
    [ -r "$TOOLS_FILE" ] || block "the Slack tool classification (slack-tools.txt) is unreadable, so no Slack call can be judged safe"
    class="$(sed -e 's/#.*//' "$TOOLS_FILE" | awk -v t="$TOOL" '$2 == t {print $1; exit}')"
    case "$class" in
      (read) exit 0;;
      (write) block "$TOOL writes to Slack";;
      (*) block "$TOOL is not classified as a read in slack-tools.txt — a new Slack tool stays blocked until the definition classifies it";;
    esac
    ;;
  (Bash)
    if command -v jq >/dev/null 2>&1; then
      CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    else
      CMD="$INPUT"
    fi
    # a network client AND a Slack API host: a note written with a heredoc may quote a
    # Slack file link, a request to Slack's API never belongs in a shell
    if printf '%s' "$CMD" | grep -qiE '(mcp|api|hooks|files|wss-[a-z0-9-]*)\.slack\.com|slack\.com/api' \
       && printf '%s' "$CMD" | grep -qE '(^|[^A-Za-z0-9_-])(curl|wget|http|https|nc|ncat|socat|python[0-9.]*|node|ruby|perl|openssl)([[:space:]]|$)'; then
      block "a shell command that reaches Slack directly, where the gateway would act as the owner"
    fi
    ONE="$(printf '%s' "$CMD" | tr '\n\t' '  ')"
    if printf '%s' "$ONE" | grep -qE '(^|[^A-Za-z0-9_-])gh[[:space:]]+issue[[:space:]]+([^|;&]*[[:space:]])?(create|comment|edit|close|reopen|delete|transfer|pin|unpin|lock|unlock|develop)([[:space:]]|$)' \
       || { printf '%s' "$ONE" | grep -qE '(^|[[:space:]])(gh[[:space:]]+api|curl)([[:space:]]|$)' \
            && printf '%s' "$ONE" | grep -qE 'repos/[^[:space:]]+/issues' \
            && printf '%s' "$ONE" | grep -qiE '(-X|--method|--request)[[:space:]=]*["'"'"']?(POST|PATCH|PUT|DELETE)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input|-d|--data[a-z-]*|--json)([[:space:]=]|$)'; } \
       || printf '%s' "$ONE" | grep -qE '(createIssue|updateIssue|addComment|closeIssue|reopenIssue|deleteIssue|transferIssue)'; then
      issue_block
    fi
    exit 0
    ;;
esac
exit 0
