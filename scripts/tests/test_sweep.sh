#!/usr/bin/env bash
# The sweep gate: declines for every documented reason, fails open (error) on an
# unreadable state file, and emits a self-contained worklist when a sweep is due.
set -u
. "$(dirname "$0")/lib.sh"
sandbox

out="$(run preflight.sh sweep)"
assert_eq true "$(printf '%s' "$out" | jq -r .nothing_to_do)" "no CONFIG.md → nothing to do"
assert_eq null "$(printf '%s' "$out" | jq -r '.error // null')" "no CONFIG.md is a decline, not an error"
assert_contains "not configured" "$(printf '%s' "$out" | jq -r '.logs[0]')" "decline says why"

write_config true
out="$(run preflight.sh sweep)"
assert_contains "onboarding not finished" "$(printf '%s' "$out" | jq -r '.logs[0]')" "no sentinel → decline"

onboard
write_config false
out="$(run preflight.sh sweep)"
assert_contains "sweep_enabled" "$(printf '%s' "$out" | jq -r '.logs[0]')" "sweep off → decline"

write_config true
sed -i.bak '/^| channel |/d; /^| mentions |/d' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
out="$(run preflight.sh sweep)"
assert_contains "watch list is empty" "$(printf '%s' "$out" | jq -r '.logs[0]')" "empty watch → decline"

# due: first sweep opens 24 h back, carries config and the watch list
write_config true
out="$(run preflight.sh sweep)"
assert_eq false "$(printf '%s' "$out" | jq -r .nothing_to_do)" "configured + on + watch → due"
assert_eq 2 "$(printf '%s' "$out" | jq '.watch | length')" "worklist carries both watch rows"
assert_eq channel "$(printf '%s' "$out" | jq -r '.watch[0].kind')" "watch row kind parsed"
assert_eq C0123ABCD "$(printf '%s' "$out" | jq -r '.watch[0].target')" "watch row target parsed"
assert_eq U0123ABCD "$(printf '%s' "$out" | jq -r '.config.owner_slack_user_id')" "config resolved into the worklist"
assert_eq "work/knowledge/" "$(printf '%s' "$out" | jq -r '.config.kb_dir')" "local mode names the knowledge base dir"
assert_eq 1 "$(printf '%s' "$out" | jq '.config.capture_focus | length')" "capture_focus parsed"
assert_eq '["docs/sweep.md","docs/capture.md"]' "$(printf '%s' "$out" | jq -c .read_set)" "read_set names the two procedures"
assert_contains "first sweep" "$(printf '%s' "$out" | jq -r '.logs | join(" ")')" "first sweep is logged as such"
assert_eq "Sweep 2 watched Slack targets" "$(printf '%s' "$out" | jq -r .title)" "title from counts only"

# the window opens at the last sweep's window_end
we="$(ago_iso 90000)"
jq -n --arg we "$we" '{last_sweep_at:$we, local_day:"2000-01-01", window_start:$we, window_end:$we, captured:0, skipped:0, failed:0, unreported:null}' > "$WORK/state/last_sweep.json"
out="$(run preflight.sh sweep)"
assert_eq "$we" "$(printf '%s' "$out" | jq -r .since)" "window opens at the previous window_end"
assert_eq false "$(printf '%s' "$out" | jq -r .window_capped)" "a 25 h window is not capped"

# a long gap is capped at 14 days and flagged
we="$(ago_iso $(( 30 * 86400 )))"
jq -n --arg we "$we" '{local_day:"2000-01-01", window_end:$we}' > "$WORK/state/last_sweep.json"
out="$(run preflight.sh sweep)"
assert_eq true "$(printf '%s' "$out" | jq -r .window_capped)" "a 30-day gap is capped"

# already swept today (owner-local day)
jq -n --arg d "$(today)" --arg we "$(now_iso)" '{local_day:$d, window_end:$we}' > "$WORK/state/last_sweep.json"
out="$(run preflight.sh sweep)"
assert_contains "already swept today" "$(printf '%s' "$out" | jq -r '.logs[0]')" "once a day"

# unreadable / corrupt state is an error (the precheck fails open on it)
printf 'not json' > "$WORK/state/last_sweep.json"
out="$(run preflight.sh sweep)"
assert_contains "not valid JSON" "$(printf '%s' "$out" | jq -r '.error // ""')" "corrupt last_sweep.json is an error, not a decline"
rm -f "$WORK/state/last_sweep.json"

sed -i.bak 's/^- owner_slack_user_id:.*/- owner_slack_user_id:/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
out="$(run preflight.sh sweep)"
assert_contains "owner_slack_user_id" "$(printf '%s' "$out" | jq -r '.error // ""')" "missing owner id is an error"

write_config true
sed -i.bak 's/^- timezone:.*/- timezone: Mars\/Olympus/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
if [ -d /usr/share/zoneinfo ]; then
  out="$(run preflight.sh sweep)"
  assert_contains "IANA" "$(printf '%s' "$out" | jq -r '.error // ""')" "unknown timezone is an error"
fi

out="$(run preflight.sh bogus)"
assert_contains "unknown mode" "$(printf '%s' "$out" | jq -r '.error // ""')" "unknown mode fails out"
exit $FAILURES
