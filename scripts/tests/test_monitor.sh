#!/usr/bin/env bash
# The monitor: quiet on a fresh instance; slack_unavailable after repeated failed reads
# and cleared by a capture; sweep_stalled after a gate opened with no sweep-done;
# heartbeat_gap only while the sweep is on; claim/ack; probes claim nothing.
set -u
. "$(dirname "$0")/lib.sh"
sandbox
write_config true; onboard
ev() { # <ts> <job> <level> <event> <msg> [run]
  jq -nc --arg ts "$1" --arg j "$2" --arg l "$3" --arg e "$4" --arg m "$5" --arg r "${6:-r1}" \
    '{ts:$ts, run:$r, job:$j, level:$l, event:$e, msg:$m}' >> "$WORK/logs/events-$(today).jsonl"
}
mon() { run monitor.sh "$@"; }

out="$(mon)"
assert_eq true "$(printf '%s' "$out" | jq -r .nothing_to_do)" "fresh instance: nothing due"

# three failed Slack reads → slack_unavailable
for i in 3 2 1; do ev "$(ago_iso $((i * 600)))" sweep error slack_read_failed "C0123ABCD mcp__slack__slack_read_channel"; done
out="$(mon)"
assert_eq slack_unavailable "$(printf '%s' "$out" | jq -r '.alerts_due[0].kind')" "repeated failed reads alert"
id="$(printf '%s' "$out" | jq -r '.alerts_due[0].id')"
out="$(mon)"
assert_eq 0 "$(printf '%s' "$out" | jq '.alerts_due | length')" "a claimed alert is not re-emitted inside its claim"
mon ack "$id" >/dev/null
out="$(mon)"
assert_eq 1 "$(printf '%s' "$out" | jq .suppressed)" "an acked alert is suppressed"
ev "$(now_iso)" sweep info capture "C0123ABCD:1736935200.000100 outcome=captured paths=2"
out="$(mon)"
assert_eq 0 "$(printf '%s' "$out" | jq '[.alerts_due[] | select(.kind == "slack_unavailable")] | length')" "a capture after the failures clears it"

# a gate that opened 7 h ago with no sweep_done → sweep_stalled
ev "$(ago_iso 25200)" sweep info precheck "sweep gate: work due — sweeps_due=1"
out="$(mon)"
assert_eq sweep_stalled "$(printf '%s' "$out" | jq -r '[.alerts_due[] | .kind][0]')" "an unfinished sweep alerts"
ev "$(now_iso)" sweep info sweep_done "captured=0 skipped=0 failed=0 reported=no"
out="$(mon)"
assert_eq 0 "$(printf '%s' "$out" | jq '[.alerts_due[] | select(.kind == "sweep_stalled")] | length')" "sweep_done clears the stall"

# a probe's gate tick is not a sweep start
ev "$(ago_iso 25000)" sweep info precheck "sweep gate: work due — sweeps_due=1" probe-audit-1
out="$(mon)"
assert_eq 0 "$(printf '%s' "$out" | jq '[.alerts_due[] | select(.kind == "sweep_stalled")] | length')" "a probe never opens a stall"

# heartbeat gap: the last real gate tick 2 days ago, sweep on → alert; sweep off → none
rm -f "$WORK/logs/"*.jsonl "$WORK/MONITOR.json"
jq -nc --arg ts "$(ago_iso 172800)" '{ts:$ts, run:"r0", job:"sweep", level:"info", event:"precheck", msg:"sweep gate: nothing to do"}' \
  > "$WORK/logs/events-$(date -u -d '-2 days' +%Y-%m-%d 2>/dev/null || date -u -v-2d +%Y-%m-%d).jsonl"
touch -d '2 days ago' "$WORK/logs/"*.jsonl 2>/dev/null || true
out="$(mon)"
assert_eq heartbeat_gap "$(printf '%s' "$out" | jq -r '[.alerts_due[] | .kind] | first // "none"')" "no sweep tick for 2 days alerts while the sweep is on"
rm -f "$WORK/MONITOR.json"
write_config false
out="$(mon)"
assert_eq 0 "$(printf '%s' "$out" | jq '[.alerts_due[] | select(.kind == "heartbeat_gap")] | length')" "no heartbeat alert while the sweep is off"

# a probe pass claims nothing
write_config true
rm -f "$WORK/MONITOR.json"
LOG_RUN_ID=probe-audit-9 HOME="$SB" WORK_DIR="$WORK" bash "$D/monitor.sh" >/dev/null 2>&1
assert_eq false "$( [ -f "$WORK/MONITOR.json" ] && jq -e '.alerts | length > 0' "$WORK/MONITOR.json" >/dev/null && echo true || echo false)" "a probe writes no claim"
assert_eq "D0123ABCD" "$(mon | jq -r .config.owner_dm_chat_id)" "alerts are addressed to the owner's DM"
exit $FAILURES
