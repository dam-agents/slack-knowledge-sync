#!/usr/bin/env bash
# The Slack write wall must stay complete: every known Slack write tool is classified
# `write`, denied in denied-tools.txt, and refused by guard.sh; every read tool is
# allowed; an unclassified Slack tool is refused; and no procedure names a write tool.
set -u
. "$(dirname "$0")/lib.sh"
A="$SCRIPTS_DIR/harness/claude-code"

# The writers the Slack MCP server is known to expose. A Slack tool that writes and is
# missing here, from slack-tools.txt or from denied-tools.txt fails this test: adding a
# new one means adding it in all three places.
KNOWN_WRITERS="
mcp__slack__slack_send_message
mcp__slack__slack_send_message_draft
mcp__slack__slack_schedule_message
mcp__slack__slack_add_reaction
mcp__slack__slack_create_canvas
mcp__slack__slack_update_canvas
mcp__slack__slack_create_conversation
"

classified() { sed -e 's/#.*//' "$A/slack-tools.txt" | awk -v c="$1" '$1 == c {print $2}' | sort; }
denied() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$A/denied-tools.txt" | grep . | sort; }

writes="$(classified write)"; reads="$(classified read)"

for w in $KNOWN_WRITERS; do
  assert_contains "$w" "$writes" "$w is classified write"
  assert_contains "$w" "$(denied)" "$w is in denied-tools.txt"
done

# every `write` line is denied, and the deny list's Slack entries are exactly the writes
assert_eq "$writes" "$(denied | grep '^mcp__slack__' | sort)" "denied Slack tools == classified writes"

# no tool classified twice, no read that is also denied, every line well-formed
assert_eq "" "$(sed -e 's/#.*//' "$A/slack-tools.txt" | awk 'NF' | awk '{print $2}' | sort | uniq -d)" "no Slack tool classified twice"
assert_eq "" "$(comm -12 <(printf '%s\n' "$reads") <(denied))" "no read tool is denied"
assert_eq "" "$(sed -e 's/#.*//' "$A/slack-tools.txt" | awk 'NF && !(($1 == "read" || $1 == "write") && $2 ~ /^mcp__slack__slack_[a-z_]+$/ && NF == 2)')" "every classification line is '<read|write> mcp__slack__<tool>'"

# a read tool's name must say it reads: anything else is suspect and must be a write
for r in $reads; do
  case "${r#mcp__slack__slack_}" in
    (search_*|read_*|list_*|get_*) ;;
    (*) printf '  FAIL %s is classified read but its name does not read\n' "$r"; FAILURES=$((FAILURES+1));;
  esac
done

# guard.sh: writes refused (exit 2), reads allowed (exit 0), unknown refused
guard() { printf '{"tool_name":"%s","tool_input":{}}' "$1" | HOME=/nonexistent bash "$A/guard.sh" >/dev/null 2>&1; echo $?; }
for w in $writes; do assert_eq 2 "$(guard "$w")" "guard refuses $w"; done
for r in $reads; do assert_eq 0 "$(guard "$r")" "guard allows $r"; done
assert_eq 2 "$(guard mcp__slack__slack_delete_message)" "guard refuses an unclassified Slack tool"
assert_eq 2 "$(guard mcp__slack__slack_upload_file)" "guard refuses another unclassified Slack tool"
assert_eq 0 "$(guard mcp__platform-outbound__send_channel_message)" "guard leaves the DAM bot alone"

# fail closed: an unreadable classification refuses even a read
sandbox
chmod 000 "$D/harness/claude-code/slack-tools.txt"
if [ -r "$D/harness/claude-code/slack-tools.txt" ]; then
  echo "  skip fail-closed check (running as root)"
else
  rc="$(printf '{"tool_name":"mcp__slack__slack_read_thread"}' | HOME=/nonexistent bash "$D/harness/claude-code/guard.sh" >/dev/null 2>&1; echo $?)"
  assert_eq 2 "$rc" "guard fails closed when slack-tools.txt is unreadable"
fi
chmod 644 "$D/harness/claude-code/slack-tools.txt"

# the shell path around the MCP server
bashcmd() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | HOME=/nonexistent bash "$A/guard.sh" >/dev/null 2>&1; echo $?; }
assert_eq 2 "$(bashcmd 'curl -s https://mcp.slack.com/mcp -d @body.json')" "guard refuses curl to the Slack MCP host"
assert_eq 2 "$(bashcmd 'curl https://slack.com/api/chat.postMessage')" "guard refuses curl to the Slack Web API"
assert_eq 0 "$(bashcmd 'grep -ri slack work/knowledge/index.md')" "guard allows a local grep mentioning slack"
assert_eq 0 "$(bashcmd 'cat > n.md <<EOF
see https://files.slack.com/files-pri/T0/F0/x.pdf
EOF')" "guard allows a note quoting a Slack file link"
assert_eq 2 "$(bashcmd 'python3 -c "import urllib.request as u; u.urlopen(\"https://slack.com/api/chat.postMessage\")"')" "guard refuses a script client to the Slack API"

# no procedure, doc or onboarding text tells the agent to call a write tool
for w in $writes; do
  short="${w#mcp__slack__}"
  hits="$(grep -rlF -- "$short" "$REPO_DIR/CLAUDE.md" "$REPO_DIR/ONBOARDING.md" "$REPO_DIR/docs" 2>/dev/null \
          | grep -v 'docs/self-modification.md' || true)"
  assert_eq "" "$hits" "no doc names $short"
done

exit $FAILURES
