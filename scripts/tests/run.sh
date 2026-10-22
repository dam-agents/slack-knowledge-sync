#!/usr/bin/env bash
# run.sh — offline test runner for the slack-knowledge-sync scripts. Discovers and
# runs every scripts/tests/test_*.sh; a test file exits non-zero on failure.
#
# Test conventions (each test_*.sh):
#   - Sandbox: create its own WORK_DIR under a temp dir — never touch a real
#     work/ or $HOME; clean up on exit.
#   - Offline: stub external CLIs by prepending scripts/tests/bin to PATH and
#     placing fake executables there (e.g. a `gh` printing canned JSON per
#     argument pattern). Tests must pass with no network and no credentials.
#   - Determinism: pre-flight logic is pure detection, so identical stub output
#     must yield an identical worklist — assert on the emitted JSON (jq).
#
# A behavior change in a script updates its test case in the same PR
# (docs/self-modification.md §9).
# Suites: test_sweep.sh (the sweep gate), test_precheck.sh (the exit-code adapter),
# test_state.sh (the ledger writer and its dedup), test_audit.sh, test_monitor.sh,
# test_verify.sh, test_kb_check.sh, test_slack_readonly.sh (the Slack write wall),
# test_harness.sh (install, deny list vs docs), test_definition_issue.sh.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
for t in "$DIR"/test_*.sh; do
  [ -e "$t" ] || { echo "no tests found in $DIR"; exit 0; }
  name="$(basename "$t")"
  if bash "$t"; then
    echo "PASS  $name"; pass=$((pass + 1))
  else
    echo "FAIL  $name"; fail=$((fail + 1))
  fi
done
echo "tests: $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
