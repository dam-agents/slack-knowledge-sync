#!/usr/bin/env bash
# verify-onboarding --config: the documented CONFIG.md passes; a typo'd key, a bad
# watch row, a bad enum, a missing focus table and an overridden credential fail.
set -u
. "$(dirname "$0")/lib.sh"
sandbox
v() { run verify-onboarding.sh --config; }
write_config true
out="$(v)"; rc=$?
assert_eq 0 "$rc" "the documented CONFIG.md passes --config"
assert_contains "PASS (config)" "$out" "and says PASS"

cp "$WORK/CONFIG.md" "$SB/good.md"
mut() { cp "$SB/good.md" "$WORK/CONFIG.md"; command sed -i.bak "$1" "$WORK/CONFIG.md"; rm -f "$WORK/CONFIG.md.bak"; }

mut 's/^- report_level:/- reportlevel:/'
assert_contains "FAIL config:reportlevel" "$(v)" "an unknown key fails"
mut 's/^| channel | C0123ABCD |/| channel | team-chat |/'
assert_contains "FAIL watch:1" "$(v)" "a channel name instead of an id fails"
mut 's/^| mentions | me |/| pings | me |/'
assert_contains "kind 'pings' is unknown" "$(v)" "an unknown watch kind fails"
mut 's/^- kb_mode: local/- kb_mode: notebook/'
assert_contains "FAIL kb_mode" "$(v)" "a bad kb_mode fails"
mut 's/^- kb_mode: local/- kb_mode: github/'
assert_contains "FAIL kb_repo" "$(v)" "GitHub mode without kb_repo fails"
mut '/^## capture_focus/,/^## watch/{/^## watch/!d;}'
assert_contains "FAIL capture_focus" "$(v)" "a missing capture_focus table fails"
mut 's/^- sensitive_override: none/- sensitive_override: hr,credentials/'
assert_contains "credentials can never be overridden" "$(v)" "overriding credentials fails"
mut 's/^- sensitive_override: none/- sensitive_override: hr/'
assert_contains "ok   sensitive_override" "$(v)" "an owner override of hr is accepted"
mut 's/^- owner_slack_user_id: U0123ABCD/- owner_slack_user_id: alice/'
assert_contains "FAIL owner_slack_user_id" "$(v)" "a name instead of a member id fails"

# offline structure scope on a sandbox that is not a checkout: FAILs carry a fix
cp "$SB/good.md" "$WORK/CONFIG.md"
out="$(run verify-onboarding.sh)"
assert_contains "fix:" "$(printf '%s\n' "$out" | grep '^FAIL' | head -1)" "every FAIL carries a fix"
exit $FAILURES
