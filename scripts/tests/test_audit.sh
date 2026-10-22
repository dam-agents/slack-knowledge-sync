#!/usr/bin/env bash
# The audit pre-flight: always has work, catches a broken ledger row and a sensitive
# row carrying a path, groups the week's errors, never reports an unmeasured check as ok.
set -u
. "$(dirname "$0")/lib.sh"
sandbox
write_config true; onboard
printf '# Knowledge base\n' > "$WORK/knowledge/index.md"
printf '# Using this knowledge base\n' > "$WORK/knowledge/USAGE_GUIDE.md"
for f in AGENTS.md MEMORY.md LESSONS.md; do printf '# %s\n' "$f" > "$WORK/$f"; done
cp "$SB/VERSION" "$WORK/VERSION"
ts="$(now_iso)"
printf '{"id":"C0123ABCD:1736935200.000100","latest_ts":"1736935200.000100","captured_at":"%s","outcome":"captured","paths":["a.md"]}\n' "$ts" > "$WORK/state/captured.jsonl"
printf '{"ts":"%s","run":"r1","job":"sweep","level":"error","event":"slack_read_failed","msg":"C0123ABCD mcp__slack__slack_read_channel"}\n' "$ts" > "$WORK/logs/events-$(today).jsonl"

out="$(run preflight.sh audit)"
assert_eq audit "$(printf '%s' "$out" | jq -r .mode)" "audit mode"
assert_eq false "$(printf '%s' "$out" | jq -r .nothing_to_do)" "an audit always has work"
assert_eq ok "$(printf '%s' "$out" | jq -r '.checks[] | select(.id == "ledger_shape") | .status')" "a clean ledger passes"
assert_eq ok "$(printf '%s' "$out" | jq -r '.checks[] | select(.id == "work_not_git") | .status')" "plain work/ passes"
assert_eq 1 "$(printf '%s' "$out" | jq '[.failures[] | select(.event == "slack_read_failed")] | length')" "the week's errors are grouped by signature"
assert_eq 1 "$(printf '%s' "$out" | jq '.stats.captured')" "the week's captures are counted"
assert_eq warn "$(printf '%s' "$out" | jq -r '.checks[] | select(.id == "definition_clean") | .status')" "a non-checkout is not measured, never ok"
for m in sweep monitor; do
  assert_contains "exit" "$(printf '%s' "$out" | jq -r --arg m "precheck_$m" '.checks[] | select(.id == $m) | .detail')" "precheck $m is timed"
done

printf '{"id":"C0123ABCD:1736935300.000100","latest_ts":"1736935300.000100","captured_at":"%s","outcome":"skipped-sensitive","paths":["hr-notes.md"]}\n' "$ts" >> "$WORK/state/captured.jsonl"
out="$(run preflight.sh audit)"
assert_eq fail "$(printf '%s' "$out" | jq -r '.checks[] | select(.id == "ledger_shape") | .status')" "a sensitive row with a path fails"
printf 'not json\n' >> "$WORK/state/captured.jsonl"
out="$(run preflight.sh audit)"
assert_contains "unparseable" "$(printf '%s' "$out" | jq -r '.checks[] | select(.id == "ledger_shape") | .detail')" "an unparseable row fails"

mkdir -p "$WORK/.git"
out="$(run preflight.sh audit)"
assert_eq fail "$(printf '%s' "$out" | jq -r '.checks[] | select(.id == "work_not_git") | .status')" "work/.git is caught"
exit $FAILURES
