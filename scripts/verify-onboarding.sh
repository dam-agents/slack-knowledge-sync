#!/usr/bin/env bash
# verify-onboarding.sh — one-shot structure verification of an onboarded
# slack-knowledge-sync agent.
#
# Runs during ONBOARDING — `--config` right after `work/CONFIG.md` is written, then
# `--live` at the end (after the sentinel) — from the weekly audit (offline), and as an
# upgrade step whenever a version changes what onboarding produces. Shape only:
# required files, required keys, enum values, table headers, row formats; the data
# inside (what the owner captures, what they watch) is never judged.
#
# Detects, never repairs: no external writes, no local writes beyond one events-log
# line. Every FAIL carries a `fix:`; re-run after fixing until it prints PASS.
#
#   ok   <check> — <detail>
#   warn <check> — <detail>                       informational, never blocks
#   FAIL <check> — <problem> — fix: <instruction>
#
#   --config   the CONFIG block only (mid-onboarding: no sentinel, no schedules yet)
#   (none)     every offline block: definition, harness, schedules, work/, CONFIG
#   --live     the offline blocks plus GitHub reachability, the sweep pre-flight and
#              the timed prechecks. Slack is MCP-only and cannot be probed from a
#              shell: the agent proves it in ONBOARDING Step 6.
#
# Schedules are platform state a shell cannot read: when SCHEDULES_JSON names a file
# holding the output of mcp__platform-outbound__list_schedules, every kit schedule
# name is checked against it; otherwise the check is a warn.
#
# Exit 0 iff nothing FAILed.

set -u
export LC_ALL=C

LIVE=0; STRUCTURE=1
case "${1:-}" in
  (--live)   LIVE=1;;
  (--config) STRUCTURE=0;;
  ('') ;;
  (*) printf 'usage: %s [--config|--live]\n' "$0" >&2; exit 2;;
esac

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SENTINEL="$HOME_DIR/.slack-knowledge-sync-onboarded"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null || true
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

CHECKS=0; FAILS=0; WARNS=0
ok()   { CHECKS=$((CHECKS+1)); printf 'ok   %s — %s\n' "$1" "$2"; }
fail() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf 'FAIL %s — %s — fix: %s\n' "$1" "$2" "$3"; }
warn() { WARNS=$((WARNS+1)); printf 'warn %s — %s\n' "$1" "$2"; }

. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }

# The known keys: CLAUDE.md → Runtime configuration. Scalars are `- key: value`
# bullets; the three lists are `## key` tables.
SCALARS="owner_slack_user_id owner_dm_chat_id sweep_enabled sweep_time timezone kb_mode kb_repo kb_path report_level sensitive_override run_model definition_issues definition_repo log_level heartbeat_gap_min slack_alert_threshold sweep_stall_min model_alert_threshold classifier_alert_threshold"
TABLES="capture_focus watch extra_exclusions"
WATCH_KINDS="channel dm group-dm thread mentions keyword"
SENSITIVE_CATS="hr health personal legal"

if [ "$STRUCTURE" = 1 ]; then
  # ------------------------------------------------------------- definition
  if git -C "$HOME_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    ok definition_checkout "$HOME_DIR is a git checkout"
    first="$(grep -v '^[[:space:]]*#' "$HOME_DIR/.gitignore" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)"
    [ "$first" = "/*" ] && ok gitignore_allowlist ".gitignore starts with /*" \
      || fail gitignore_allowlist "the .gitignore at $HOME_DIR is not the allowlist" "restore it from origin: git -C $HOME_DIR checkout origin/main -- .gitignore"
    tracked="$(git -C "$HOME_DIR" ls-files -- work knowledge 2>/dev/null | head -3 | tr '\n' ' ')"
    [ -z "$tracked" ] && ok kb_untracked "nothing under work/ or knowledge/ is tracked" \
      || fail kb_untracked "captured state is tracked by the definition repo: $tracked" "git -C $HOME_DIR rm -r --cached -- work knowledge, then never git add outside the allowlist"
    dirty="$(git -C "$HOME_DIR" status --porcelain 2>/dev/null | head -3 | tr '\n' ' ')"
    [ -z "$dirty" ] && ok definition_clean "no local changes" || warn definition_clean "local changes in the definition checkout: $dirty"
  else
    fail definition_checkout "$HOME_DIR is not a git checkout" "ONBOARDING Step 1 — on the kit path a missing checkout means the seed failed: tell the owner and stop"
  fi
  if [ -f "$SENTINEL" ]; then
    grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$SENTINEL" \
      && ok sentinel "onboarded $(cat "$SENTINEL")" \
      || fail sentinel "the sentinel holds no UTC timestamp" "date -u +%Y-%m-%dT%H:%M:%SZ > $SENTINEL"
  else
    fail sentinel "no $SENTINEL" "ONBOARDING Step 6 writes it after every earlier step succeeded"
  fi

  # ---------------------------------------------------------------- harness
  if [ "${CLAUDECODE:-}" = 1 ] || [ "${PLATFORM_HARNESS:-}" = claude-code ]; then
    parts="$(bash "$SCRIPT_DIR/harness/claude-code/install.sh" --check 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    [ -z "$parts" ] && ok harness "hooks, auto-mode rules and the tool deny list are current" \
      || fail harness "not current: $parts — the Slack write tools may be reachable" "bash $SCRIPT_DIR/harness/claude-code/install.sh, then start a new session"
  else
    warn harness "not Claude Code — the Slack write deny list and guard are not installed on this harness; tell the owner"
  fi

  # -------------------------------------------------------------- schedules
  names="$(sed -n '/^schedules:/,/^[a-z]/p' "$DEF_DIR/kit.yaml" 2>/dev/null | sed -nE 's/^[[:space:]]+-[[:space:]]*name:[[:space:]]*//p')"
  if [ -n "${SCHEDULES_JSON:-}" ] && [ -r "$SCHEDULES_JSON" ]; then
    for n in $names; do
      jq -e --arg n "$n" '[.. | objects | select(has("name")) | .name] | index($n) != null' "$SCHEDULES_JSON" >/dev/null 2>&1 \
        && ok "schedule:$n" "registered" \
        || fail "schedule:$n" "not registered on this agent" "ONBOARDING Step 5 — create it with the task text of its sub-step"
    done
  else
    warn schedules "not checkable from a shell — save list_schedules output to a file and re-run with SCHEDULES_JSON=<file> (expected: $(printf '%s' "$names" | tr '\n' ' '))"
  fi

  # ------------------------------------------------------------------ work/
  if [ -d "$WORK" ]; then
    [ -d "$WORK/.git" ] && fail work_not_git "work/.git exists" "move it out of the volume; work/ is a plain directory (docs/persistence.md)" \
                        || ok work_not_git "work/ is a plain directory"
    for f in AGENTS.md MEMORY.md LESSONS.md; do
      [ -f "$WORK/$f" ] && ok "work/$f" present || fail "work/$f" missing "ONBOARDING Step 2b seeds it"
    done
    if [ -f "$WORK/VERSION" ]; then
      [ "$(head -1 "$WORK/VERSION")" = "$(head -1 "$DEF_DIR/VERSION" 2>/dev/null)" ] \
        && ok work_version "adopted $(head -1 "$WORK/VERSION")" \
        || warn work_version "adopted $(head -1 "$WORK/VERSION") != checked out $(head -1 "$DEF_DIR/VERSION") — run the version check (docs/persistence.md)"
    else
      fail work_version "work/VERSION missing" "head -1 $DEF_DIR/VERSION > $WORK/VERSION (ONBOARDING Step 6)"
    fi
    [ -d "$WORK/state" ] && ok work_state "work/state/ present" || fail work_state "work/state/ missing" "mkdir -p $WORK/state (ONBOARDING Step 2b)"
    L="$WORK/state/captured.jsonl"
    if [ -f "$L" ]; then
      bad="$(jq -cR 'fromjson? // "BAD"' "$L" | jq -s '[.[] | select(. == "BAD" or ((.id // "") | test("^[CDG][A-Z0-9]{6,}:[0-9]{9,10}\\.[0-9]{6}$") | not))] | length')"
      [ "${bad:-1}" -eq 0 ] && ok ledger_rows "captured.jsonl rows in shape" \
        || fail ledger_rows "$bad captured.jsonl row(s) out of shape" "rows are written only by scripts/state.sh record; move the bad rows to work/state/captured.bad.jsonl"
    fi
    if [ -f "$WORK/state/last_sweep.json" ]; then
      jq -e '.local_day and .window_end' "$WORK/state/last_sweep.json" >/dev/null 2>&1 \
        && ok last_sweep "last_sweep.json in shape" \
        || fail last_sweep "last_sweep.json is not the documented JSON" "delete it; the next sweep opens a 24 h window (docs/sweep.md)"
    fi
    if [ "$(cfg kb_mode)" != github ]; then
      kout="$(WORK_DIR="$WORK" bash "$SCRIPT_DIR/kb-check.sh" 2>/dev/null)"
      nf="$(printf '%s' "$kout" | jq '[.problems[]? | select(.severity == "fail")] | length' 2>/dev/null)"
      if [ -z "$nf" ]; then warn knowledge_base "not measured — kb-check.sh printed no JSON"
      elif [ "$nf" -eq 0 ]; then ok knowledge_base "work/knowledge/ in shape ($(printf '%s' "$kout" | jq .notes) note(s))"
      else fail knowledge_base "$(printf '%s' "$kout" | jq -r '[.problems[] | select(.severity == "fail") | "\(.path): \(.problem)"][:3] | join("; ")')" "docs/capture.md → Note format; the layout seeds in ONBOARDING Step 2b"; fi
    fi
  else
    fail work_dir "$WORK missing" "ONBOARDING Step 2"
  fi
fi

# ------------------------------------------------------------------- CONFIG
if [ ! -f "$CONFIG" ]; then
  fail config "work/CONFIG.md missing" "ONBOARDING Step 3 writes it in the exact shape of its example"
else
  # every bullet and every table heading is a known key
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case " $SCALARS " in (*" $k "*) ;; (*) fail "config:$k" "unknown key — the runtime never reads it" "rename it to a key of CLAUDE.md → Runtime configuration, or delete it";; esac
  done < <(sed -nE 's/^- ([A-Za-z0-9_]+):.*/\1/p' "$CONFIG")
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    case " $TABLES " in (*" $h "*) ;; (*) fail "config:## $h" "unknown table — the runtime never reads it" "the tables are capture_focus, watch and extra_exclusions";; esac
  done < <(sed -nE 's/^## (.*)$/\1/p' "$CONFIG")
  dup="$(sed -nE 's/^- ([A-Za-z0-9_]+):.*/\1/p' "$CONFIG" | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dup" ] || fail config_duplicates "keys given twice: $dup (the first wins)" "keep one bullet per key"

  v="$(cfg owner_slack_user_id)"
  printf '%s' "$v" | grep -qE '^[UW][A-Z0-9]{6,}$' && ok owner_slack_user_id "$v" \
    || fail owner_slack_user_id "missing or not a Slack member ID ('$v')" "ask the owner: Slack profile → ⋯ → Copy member ID (U…)"
  v="$(cfg owner_dm_chat_id)"
  [ -n "$v" ] && printf '%s' "$v" | grep -qE '^[A-Za-z0-9_:-]+$' && ok owner_dm_chat_id "set" \
    || fail owner_dm_chat_id "missing or malformed" "use the id of the owner's DM from mcp__platform-outbound__describe_channel (ONBOARDING Step 3)"
  v="$(cfg sweep_enabled)"
  case "$v" in (true|false) ok sweep_enabled "$v";; (*) fail sweep_enabled "'$v' is not true|false" "write - sweep_enabled: false unless the owner turned the daily sweep on";; esac
  v="$(cfg sweep_time)"
  printf '%s' "$v" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$' && ok sweep_time "$v" \
    || fail sweep_time "'$v' is not HH:MM" "write - sweep_time: 06:00 (owner-local)"
  v="$(cfg timezone)"
  if [ -z "$v" ]; then fail timezone "missing" "write the owner's IANA zone, e.g. - timezone: Europe/Prague"
  elif [ -d /usr/share/zoneinfo ] && [ "$v" != UTC ] && [ ! -f "/usr/share/zoneinfo/$v" ]; then
    fail timezone "'$v' is not an IANA zone name" "e.g. America/New_York, Europe/Prague, UTC"
  else ok timezone "$v"; fi
  km="$(cfg kb_mode)"
  case "$km" in (local|github) ok kb_mode "$km";; (*) fail kb_mode "'$km' is not local|github" "write - kb_mode: local";; esac
  kr="$(cfg kb_repo)"
  if [ "$km" = github ]; then
    printf '%s' "$kr" | grep -qE '^([A-Za-z0-9.-]+\.[A-Za-z]{2,}/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' && ok kb_repo "$kr" \
      || fail kb_repo "GitHub mode needs kb_repo as [host/]owner/repo ('$kr')" "ask the owner for the knowledge base repository, e.g. acme/widgets-knowledge"
  elif [ -n "$kr" ]; then warn kb_repo "set but unused in local mode"; fi
  kp="$(cfg kb_path)"
  case "$kp" in (''|/*|*..*) fail kb_path "'$kp' must be a relative folder without '..'" "write - kb_path: knowledge/";; (*) ok kb_path "$kp";; esac
  v="$(cfg report_level)"
  case "$v" in (silent-when-nothing|always) ok report_level "$v";; (*) fail report_level "'$v' is not silent-when-nothing|always" "write - report_level: silent-when-nothing";; esac
  v="$(cfg sensitive_override)"
  if [ "$v" = none ]; then ok sensitive_override "none — every default exclusion applies"
  elif [ -z "$v" ]; then fail sensitive_override "missing" "write - sensitive_override: none"
  else
    badc=""
    for c in $(printf '%s' "$v" | tr ',' ' '); do
      case " $SENSITIVE_CATS " in (*" $c "*) ;; (*) badc="$badc $c";; esac
    done
    [ -z "$badc" ] && ok sensitive_override "$v (owner override)" \
      || fail sensitive_override "unknown categor(ies):$badc — credentials can never be overridden" "use none, or a comma list of: hr, health, personal, legal"
  fi
  v="$(cfg run_model)"; [ -n "$v" ] && ok run_model "$v" || fail run_model "missing" "write - run_model: default"
  v="$(cfg definition_issues)"
  case "$v" in (enabled|disabled) ok definition_issues "$v";; (*) fail definition_issues "'$v' is not enabled|disabled" "write - definition_issues: disabled";; esac
  v="$(cfg definition_repo)"
  [ -z "$v" ] || printf '%s' "$v" | grep -qE '^([A-Za-z0-9.-]+\.[A-Za-z]{2,}/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || fail definition_repo "'$v' is not [host/]owner/repo" "copy it from git -C $HOME_DIR remote get-url origin"
  for k in heartbeat_gap_min slack_alert_threshold sweep_stall_min model_alert_threshold classifier_alert_threshold; do
    v="$(cfg "$k")"
    case "$v" in (''|off|none) ;; (*[!0-9]*) fail "$k" "'$v' is not a number, 0 or off" "delete the bullet to use the default";; esac
  done
  v="$(cfg log_level)"; case "$v" in (''|info|debug) ;; (*) fail log_level "'$v' is not info|debug" "delete the bullet";; esac

  # ---- tables: exact header, row shape
  table_header() { sed -n "/^## $1\$/,/^## /p" "$CONFIG" | grep '^|' | head -1 | tr -s ' '; }
  h="$(table_header capture_focus)"
  if [ "$h" != "| focus |" ]; then fail capture_focus "missing, or header is not '| focus |'" "write the owner's answer to 'What should I pay attention to and capture from your Slack?' as one row per item (ONBOARDING Step 3)"
  else
    n="$(cfg_table capture_focus | grep -cvE '^\|[[:space:]]*\|?[[:space:]]*$')"
    [ "$n" -gt 0 ] && ok capture_focus "$n item(s)" \
      || fail capture_focus "no rows" "ask the owner what to capture; at least one row"
  fi
  h="$(table_header watch)"
  if [ "$h" != "| kind | target | note |" ]; then fail watch "missing, or header is not '| kind | target | note |'" "write the owner's answer to 'What should I watch?' (ONBOARDING Step 3)"
  else
    nrow=0
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      kind="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')"
      target="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')"
      nrow=$((nrow + 1))
      case " $WATCH_KINDS " in (*" $kind "*) ;; (*) fail "watch:$nrow" "kind '$kind' is unknown" "one of: $WATCH_KINDS"; continue;; esac
      case "$kind" in
        (channel|group-dm) printf '%s' "$target" | grep -qE '^[CG][A-Z0-9]{6,}$' \
            || fail "watch:$nrow" "$kind target must be a conversation ID (C…/G…)" "resolve the name with slack_search_channels and store the ID";;
        (dm) printf '%s' "$target" | grep -qE '^(D[A-Z0-9]{6,}|[UW][A-Z0-9]{6,})$' \
            || fail "watch:$nrow" "dm target must be a DM ID (D…) or the other person's member ID (U…)" "resolve it with slack_search_users";;
        (thread) printf '%s' "$target" | grep -qE '^https://[A-Za-z0-9.-]+\.slack\.com/archives/[CDG][A-Z0-9]+/p[0-9]{16}' \
            || fail "watch:$nrow" "thread target must be a Slack permalink" "paste the thread's Copy link";;
        (mentions) [ "$target" = me ] || fail "watch:$nrow" "mentions target is 'me'" "write | mentions | me | |";;
        (keyword) [ -n "$target" ] || fail "watch:$nrow" "keyword target is empty" "the word or phrase to search for";;
      esac
    done < <(cfg_table watch)
    [ "$nrow" -gt 0 ] && ok watch "$nrow target(s)" \
      || warn watch "no targets — the daily sweep has nothing to read; on-demand captures still work"
  fi
  h="$(table_header extra_exclusions)"
  [ "$h" = "| exclusion |" ] && ok extra_exclusions "$(cfg_table extra_exclusions | grep -c . | tr -d ' ') item(s)" \
    || fail extra_exclusions "missing, or header is not '| exclusion |'" "write the table, empty when the owner named nothing"
fi

# --------------------------------------------------------------------- live
if [ "$LIVE" = 1 ]; then
  warn slack "MCP-only — not probed from a shell; the agent proves it with one read-only Slack read in ONBOARDING Step 6"
  if [ "$(cfg kb_mode)" = github ]; then
    ref="$(cfg kb_repo)"; host=github.com; slug="$ref"
    case "$ref" in (*.*/*/*) host="${ref%%/*}"; slug="${ref#*/}";; esac
    push="$(gh api --hostname "$host" "repos/$slug" --jq .permissions.push 2>/dev/null)"
    case "$push" in
      (true) ok kb_repo_access "$host/$slug — push allowed (branches + PRs)";;
      (false) fail kb_repo_access "$host/$slug readable but not writable" "the owner grants their GitHub account write access, or switches to kb_mode: local";;
      (*) fail kb_repo_access "$host/$slug not reachable" "grant the GitHub connection for $host (gh auth status) and check the slug";;
    esac
  fi
  if [ -n "${GITHUB_REPO_WORK:-}" ]; then
    priv="$(gh api "repos/$GITHUB_REPO_WORK" --jq .private 2>/dev/null)"
    case "$priv" in
      (true) ok backup_repo "$GITHUB_REPO_WORK is private";;
      (false) fail backup_repo "$GITHUB_REPO_WORK is PUBLIC — it would publish the owner's captured Slack content" "make it private, or unset GITHUB_REPO_WORK";;
      (*) warn backup_repo "$GITHUB_REPO_WORK not reachable — backups will fail until it is";;
    esac
  fi
  pf="$(LOG_RUN_ID="probe-verify-$$" HOME="$HOME_DIR" WORK_DIR="$WORK" bash "$SCRIPT_DIR/preflight.sh" sweep 2>/dev/null)"
  if printf '%s' "$pf" | jq -e 'has("nothing_to_do") and (has("error") | not)' >/dev/null 2>&1; then
    ok preflight_sweep "valid worklist (nothing_to_do=$(printf '%s' "$pf" | jq .nothing_to_do))"
  else
    fail preflight_sweep "$(printf '%s' "$pf" | jq -r '.error // "no JSON"' 2>/dev/null | cut -c1-200)" "fix what the error names, then re-run"
  fi
  for m in sweep monitor; do
    t0=$(date +%s)
    LOG_RUN_ID="probe-verify-$$" HOME="$HOME_DIR" WORK_DIR="$WORK" bash "$SCRIPT_DIR/precheck.sh" "$m" >/dev/null 2>&1; rc=$?
    dt=$(( $(date +%s) - t0 ))
    if { [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; } && [ "$dt" -lt 60 ]; then ok "precheck_$m" "exit $rc in ${dt}s"
    else fail "precheck_$m" "exit $rc in ${dt}s — a broken gate fails open" "run bash $SCRIPT_DIR/precheck.sh $m and fix what it prints"; fi
  done
fi

# ------------------------------------------------------------------- summary
if [ "$LIVE" = 1 ]; then SCOPE="structure+live"
elif [ "$STRUCTURE" = 1 ]; then SCOPE="structure"
else SCOPE="config"; fi
if [ "$FAILS" -eq 0 ]; then
  printf 'PASS (%s) — %d checks passed, %d warning(s)\n' "$SCOPE" "$CHECKS" "$WARNS"
  logev info onboarding_verify "PASS $SCOPE ($CHECKS checks, $WARNS warnings)"
  exit 0
else
  printf 'RESULT (%s): %d of %d checks FAILED — apply each fix above, then re-run this script until it prints PASS.\n' "$SCOPE" "$FAILS" "$CHECKS"
  logev error onboarding_verify "FAILED $SCOPE ($FAILS of $CHECKS checks) — agent must repair and re-run"
  exit 1
fi
