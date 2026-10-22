#!/usr/bin/env bash
# definition-issue.sh: off by default; blocks every instance value and identifying
# shape, naming only the category; passes a generic body.
set -u
. "$(dirname "$0")/lib.sh"
sandbox
write_config true
B="$SB/body.md"
di() { run definition-issue.sh "$@"; }

printf 'The sweep procedure skips the second page of a long thread.\n' > "$B"
assert_eq disabled "$(di file "Sweep misses long threads" "$B" | jq -r .outcome)" "off by default"
assert_eq clean "$(di check "$B" | jq -r .outcome)" "a generic body is clean"

check_blocked() { # <body> <what>
  printf '%s\n' "$1" > "$B"
  local o; o="$(di check "$B")"
  assert_eq blocked "$(printf '%s' "$o" | jq -r .outcome)" "$2"
  assert_not_contains "C0999ZZZZ" "$o" "$2: the match is never echoed"
}
check_blocked "It failed in channel C0999ZZZZ9 again." "a Slack id"
check_blocked "See https://acme.slack.com/archives/C0999ZZZZ/p1736935200000100" "a Slack link"
check_blocked "Watching decisions on the widgets launch, with owner and date broke it." "a capture_focus value"
check_blocked "It broke on 2026-01-15 at 06:00." "a date and time"
check_blocked "Run \`state.sh due\` to see it." "a backticked token"
check_blocked "The capture_focus parser failed." "an identifier-shaped word"
check_blocked "Reported by bob@example.com" "an e-mail"
check_blocked "Zorblax mentioned it." "a capitalised word the definition never uses"

sed -i.bak 's/^- definition_issues: disabled/- definition_issues: enabled/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
printf 'It failed in channel C0999ZZZZ9 again.\n' > "$B"
assert_eq blocked "$(di file "Sweep fails" "$B" | jq -r .outcome)" "file refuses a blocked body before any network call"
printf 'The sweep procedure skips the second page of a long thread.\n' > "$B"
printf '[]' > "$SB/gh.out"
out="$(di file "Sweep misses long threads" "$B")"
assert_contains '"outcome"' "$out" "file answers with an outcome"
exit $FAILURES
