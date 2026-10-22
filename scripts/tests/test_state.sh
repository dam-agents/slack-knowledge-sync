#!/usr/bin/env bash
# The ledger writer: dedup by latest_ts, retry after failure, sensitive rows store
# nothing, refusals on malformed input, sweep-done carries unsent reports forward.
set -u
. "$(dirname "$0")/lib.sh"
sandbox
write_config true
st() { run state.sh "$@"; }
ID=C0123ABCD:1736935200.000100

assert_eq new "$(st due $ID 1736935200.000100 | jq -r .reason)" "unknown thread is due"
st record $ID 1736935300.000200 captured release-process.md index.md >/dev/null
assert_eq 1 "$(grep -c . "$WORK/state/captured.jsonl")" "one row written"
assert_eq false "$(st due $ID 1736935300.000200 | jq -r .due)" "same latest_ts → not due"
assert_eq false "$(st due $ID 1736935250.000000 | jq -r .due)" "an older ts → not due"
assert_eq new-replies "$(st due $ID 1736935400.000300 | jq -r .reason)" "a newer reply → due again"
assert_eq true "$(jq -r '.captured_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$WORK/state/captured.jsonl")" "captured_at is a UTC timestamp"

st record $ID 1736935400.000300 failed >/dev/null
assert_eq retry-after-failure "$(st due $ID 1736935400.000300 | jq -r .reason)" "a failed row is retried"

out="$(st record C0123ABCD:1736935500.000100 1736935500.000100 skipped-sensitive notes.md)"; rc=$?
assert_eq 2 "$rc" "a sensitive skip with a path is refused"
assert_contains "nothing but its id" "$(printf '%s' "$out" | jq -r .error)" "and says why"
st record C0123ABCD:1736935500.000100 1736935500.000100 skipped-sensitive >/dev/null
assert_eq '[]' "$(tail -1 "$WORK/state/captured.jsonl" | jq -c .paths)" "a sensitive row stores no paths"
assert_eq 5 "$(tail -1 "$WORK/state/captured.jsonl" | jq 'keys | length')" "a sensitive row has exactly the five fields"

st record bogus 1.2 captured x.md >/dev/null; assert_eq 2 "$?" "a malformed id is refused"
st record $ID 1736935400.000300 published x.md >/dev/null; assert_eq 2 "$?" "an unknown outcome is refused"
st record $ID 1736935400.000300 captured >/dev/null; assert_eq 2 "$?" "a capture without paths is refused"
st record $ID 1736935400.000300 captured ../escape.md >/dev/null; assert_eq 2 "$?" "a path with .. is refused"
st record $ID 1736935400.000300 captured https://github.com/acme/widgets/pull/7 >/dev/null; assert_eq 0 "$?" "a PR URL is a valid path"

# sweep-done: window and day recorded; an unsent report is carried forward, a sent one clears it
now="$(now_iso)"; since="$(ago_iso 86400)"
st sweep-done --started "$now" --since "$since" --captured 2 --skipped 1 --failed 0 --reported no --notes "p1,p2" >/dev/null
assert_eq "$now" "$(jq -r .window_end "$WORK/state/last_sweep.json")" "window_end is the worklist's now"
assert_eq "$(today)" "$(jq -r .local_day "$WORK/state/last_sweep.json")" "local_day recorded"
assert_eq 2 "$(jq -r .unreported.captured "$WORK/state/last_sweep.json")" "unsent report carried"
st sweep-done --started "$now" --since "$since" --captured 1 --skipped 0 --failed 0 --reported no --notes "p3" >/dev/null
assert_eq 3 "$(jq -r .unreported.captured "$WORK/state/last_sweep.json")" "carried counts accumulate"
assert_eq 3 "$(jq -r '.unreported.notes | length' "$WORK/state/last_sweep.json")" "carried permalinks accumulate"
st sweep-done --started "$now" --since "$since" --captured 0 --skipped 0 --failed 0 --reported yes >/dev/null
assert_eq null "$(jq -r .unreported "$WORK/state/last_sweep.json")" "a sent report clears the carry"
assert_contains "sweep captured=0" "$(tail -1 "$WORK/SWEEP.log")" "SWEEP.log line written"
st sweep-done --started yesterday --since "$since" --captured 0 --skipped 0 --failed 0 --reported yes >/dev/null
assert_eq 2 "$?" "a non-UTC --started is refused"

# inbox: answered once
assert_eq false "$(st inbox-seen 1736935600.000100 | jq -r .seen)" "a new DM is unseen"
st inbox 1736935600.000100 capture-thread >/dev/null
assert_eq true "$(st inbox-seen 1736935600.000100 | jq -r .seen)" "a handled DM is seen"

# a stale lock (dead writer) is taken over, a write still lands
mkdir "$WORK/state/captured.jsonl.lock"; touch -d '5 minutes ago' "$WORK/state/captured.jsonl.lock" 2>/dev/null \
  || touch -t "$(date -u -v-5M +%Y%m%d%H%M 2>/dev/null)" "$WORK/state/captured.jsonl.lock"
st record C0123ABCD:1736935700.000100 1736935700.000100 skipped-noise >/dev/null
assert_eq skipped-noise "$(tail -1 "$WORK/state/captured.jsonl" | jq -r .outcome)" "a stale lock does not block the write"
assert_eq false "$( [ -d "$WORK/state/captured.jsonl.lock" ] && echo true || echo false)" "the lock is released"
exit $FAILURES
