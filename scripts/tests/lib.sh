#!/usr/bin/env bash
# lib.sh — shared helpers for the offline tests. Sourced, never run directly.
#
# Every test gets its own sandbox: a temp $HOME holding a copy of the definition and
# a work/ tree, so nothing touches a real deployment. Offline: no script here talks to
# Slack (MCP-only), and the few that could call gh or git get a stub on PATH.
set -u
unset CLAUDECODE PLATFORM_HARNESS

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

FAILURES=0
assert_eq() { # <expected> <actual> <what>
  if [ "$1" = "$2" ]; then printf '  ok   %s\n' "$3"
  else printf '  FAIL %s: expected [%s], got [%s]\n' "$3" "$1" "$2"; FAILURES=$((FAILURES+1)); fi
}
assert_contains() { # <needle> <haystack> <what>
  case "$2" in (*"$1"*) printf '  ok   %s\n' "$3";;
    (*) printf '  FAIL %s: [%s] not found\n' "$3" "$1"; FAILURES=$((FAILURES+1));; esac
}
assert_not_contains() { # <needle> <haystack> <what>
  case "$2" in (*"$1"*) printf '  FAIL %s: [%s] present\n' "$3" "$1"; FAILURES=$((FAILURES+1));;
    (*) printf '  ok   %s\n' "$3";; esac
}

sandbox() { # -> SB (fake $HOME holding a definition copy), WORK, D (its scripts dir)
  SB="$(mktemp -d "${TMPDIR:-/tmp}/sks-test.XXXXXX")"
  WORK="$SB/work"
  mkdir -p "$WORK/state" "$WORK/logs" "$WORK/knowledge/sources" "$SB/bin"
  ( cd "$REPO_DIR" && tar -cf - --exclude=.git --exclude=work . ) | ( cd "$SB" && tar -xmf - )
  D="$SB/scripts"
  # gh and git stubs: no network ever (a test that needs a gh answer writes $SB/gh.out)
  cat > "$SB/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -f "$GH_STUB_OUT" ] && cat "$GH_STUB_OUT" && exit 0
exit 1
EOF
  chmod +x "$SB/bin/gh"
  export GH_STUB_OUT="$SB/gh.out"
  export PATH="$SB/bin:$PATH"
  trap 'rm -rf "$SB"' EXIT
}

write_config() { # [sweep_enabled] — a valid CONFIG.md in the documented shape
  cat > "$WORK/CONFIG.md" <<EOF
# Configuration — slack-knowledge-sync

- owner_slack_user_id: U0123ABCD
- owner_dm_chat_id: D0123ABCD
- sweep_enabled: ${1:-true}
- sweep_time: 06:00
- timezone: UTC
- kb_mode: local
- kb_repo:
- kb_path: knowledge/
- report_level: silent-when-nothing
- sensitive_override: none
- run_model: default
- definition_issues: disabled
- definition_repo: acme/slack-knowledge-sync

## capture_focus

| focus |
| --- |
| decisions on the widgets launch, with owner and date |

## watch

| kind | target | note |
| --- | --- | --- |
| channel | C0123ABCD | team channel |
| mentions | me | |

## extra_exclusions

| exclusion |
| --- |
EOF
}

onboard() { date -u +%Y-%m-%dT%H:%M:%SZ > "$SB/.slack-knowledge-sync-onboarded"; }

run() { # <script> [args] — stdout only, sandboxed
  HOME="$SB" WORK_DIR="$WORK" TZ=UTC CLAUDECODE= bash "$D/$1" "${@:2}" 2>/dev/null
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ago_iso() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r "$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
today() { date -u +%Y-%m-%d; }
