#!/usr/bin/env bash
# install.sh: writes the Slack deny list, the guard hook and the tagged auto-mode rules,
# is idempotent, keeps the operator's entries, reports drift by part; the deny list
# never names a tool a procedure calls or a tool the platform's own prompts call.
set -u
. "$(dirname "$0")/lib.sh"
sandbox
A="$D/harness/claude-code"
S="$SB/.claude/settings.json"
mkdir -p "$SB/.claude"
printf '{"permissions":{"deny":["OperatorTool"]},"autoMode":{"allow":["mine"]}}\n' > "$S"
inst() { HOME="$SB" WORK_DIR="$WORK" SKS_FORCE_CLAUDE=1 bash "$A/install.sh" "$@" 2>/dev/null; }

assert_eq "hooks automode-rules tool-deny" "$(inst --check | tr '\n' ' ' | sed 's/ $//')" "a bare settings file is not current"
inst >/dev/null
assert_eq "" "$(inst --check)" "after install every part is current"
for w in $(sed -e 's/#.*//' "$A/slack-tools.txt" | awk '$1 == "write" {print $2}'); do
  assert_eq true "$(jq --arg w "$w" '.permissions.deny | index($w) != null' "$S")" "settings deny $w"
done
assert_eq true "$(jq '.permissions.deny | index("OperatorTool") != null' "$S")" "the operator's deny entry stays"
assert_eq true "$(jq '.autoMode.allow | index("mine") != null' "$S")" "the operator's auto-mode rule stays"
assert_contains "guard.sh" "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "mcp__slack__.*|Bash") | .hooks[].command' "$S")" "PreToolUse guard registered for Slack and Bash"
before="$(cat "$S")"; inst >/dev/null
assert_eq "$before" "$(cat "$S")" "a second install changes nothing"
assert_eq 1 "$(jq '[.hooks.PreToolUse[] | select(.hooks[].command | endswith("guard.sh"))] | length' "$S")" "the guard is registered once"

# drift: a dropped deny entry is reported by part
jq '.permissions.deny -= ["mcp__slack__slack_send_message"]' "$S" > "$S.t" && mv "$S.t" "$S"
assert_eq tool-deny "$(inst --check)" "a removed Slack deny entry is drift"

# the deny list never removes a tool the platform's prompts or a procedure call
for t in set_onboarding_checklist complete_onboarding_step mark_onboarding_complete list_schedules create_schedule delete_schedule toggle_schedule report_kit_updated cancel_kit_update send_channel_message reply describe_channel rename_session get_metrics; do
  assert_eq "" "$(grep -x "mcp__platform-outbound__$t" "$A/denied-tools.txt")" "$t is not denied"
done
for t in $(sed -e 's/#.*//' "$A/denied-tools.txt" | grep -v '^mcp__slack__' | awk 'NF {print $1}'); do
  short="${t#mcp__platform-outbound__}"
  assert_eq "" "$(grep -rlwF -- "$short" "$REPO_DIR/CLAUDE.md" "$REPO_DIR/ONBOARDING.md" "$REPO_DIR/README.md" "$REPO_DIR/docs" 2>/dev/null | grep -v self-modification || true)" "denied $short is named by no procedure"
done

# on another harness: nothing installed, and it says the wall is absent
out="$(HOME="$SB" CLAUDECODE= PLATFORM_HARNESS=codex SKS_FORCE_CLAUDE= bash "$A/install.sh")"
assert_contains "NOT blocked" "$out" "another harness is told the Slack wall is absent"

# the guard refuses a hand-made issue write, allows a PR and a read
g() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | HOME=/nonexistent bash "$A/guard.sh" >/dev/null 2>&1; echo $?; }
assert_eq 2 "$(g 'gh issue create -R acme/widgets --title x --body y')" "gh issue create is refused"
assert_eq 2 "$(g 'gh api repos/acme/widgets/issues -f title=x')" "a gh api issue write is refused"
assert_eq 0 "$(g 'gh issue list -R acme/widgets')" "an issue read is allowed"
assert_eq 0 "$(g 'gh pr create -R acme/widgets --title x --body-file b.md')" "a capture PR is allowed"
assert_eq 0 "$(g 'bash "$HOME/scripts/definition-issue.sh" file "Sweep misses long threads" /tmp/b.md')" "the one issue path is allowed"
exit $FAILURES
