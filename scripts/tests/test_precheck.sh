#!/usr/bin/env bash
# The gate adapter: idle → exit 1 and no output; due → exit 0 with a readable worklist
# file; an error, non-JSON output, a missing pass and the audit → exit 2 (fail open).
set -u
. "$(dirname "$0")/lib.sh"
sandbox
pc() { CLAUDECODE= HOME="$SB" WORK_DIR="$WORK" TMPDIR="$SB" TZ=UTC bash "$D/precheck.sh" "$@" 2>/dev/null; }

out="$(pc sweep)"; rc=$?
assert_eq 1 "$rc" "unconfigured sweep declines"
assert_eq "" "$out" "a declined fire prints nothing"

write_config true; onboard
out="$(pc sweep)"; rc=$?
assert_eq 0 "$rc" "a due sweep runs"
f="$(printf '%s' "$out" | sed -n 's/^worklist: //p')"
assert_eq true "$( [ -r "$f" ] && echo true || echo false)" "worklist file is readable"
assert_eq false "$(jq -r .nothing_to_do "$f")" "worklist file is the pass's JSON"
assert_eq 600 "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" "worklist file is private (0600)"
assert_contains "sweeps_due=1" "$out" "prompt names the due key"
assert_contains "do not run preflight.sh again" "$out" "prompt says one pass"

printf 'garbage' > "$WORK/state/last_sweep.json"
pc sweep >/dev/null; assert_eq 2 "$?" "an error in the pass fails open (exit 2)"
rm -f "$WORK/state/last_sweep.json"

printf '#!/usr/bin/env bash\necho not-json\n' > "$D/preflight.sh"
pc sweep >/dev/null; assert_eq 2 "$?" "non-JSON output fails open"
rm -f "$D/preflight.sh"
out="$(pc sweep)"; rc=$?
assert_eq 2 "$rc" "a missing pass fails open"
assert_contains "missing" "$out" "and says so"

pc audit >/dev/null; assert_eq 2 "$?" "the audit is never gated"
pc >/dev/null; assert_eq 2 "$?" "no mode fails open"

out="$(pc monitor)"; rc=$?
assert_eq 1 "$rc" "a quiet monitor declines"
exit $FAILURES
