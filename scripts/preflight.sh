#!/usr/bin/env bash
# preflight.sh — deterministic pre-flight for slack-knowledge-sync.
#
# The script DETECTS, it NEVER ACTS:
#
#   - NO external writes at all (list/GET calls only),
#   - NO git commit/push (the agent persists at end of run),
#   - local writes only: per-mode log lines, the events log, and the audit's log
#     retention sweep.
#
#   preflight.sh <mode>   -> one JSON object on stdout; everything else to stderr.
#   .nothing_to_do == true  -> the agent ends the run immediately.
#   otherwise               -> the agent processes the arrays per CLAUDE.md + docs/.
#
# Modes:
#   sweep  — the daily sweep's gate. Slack is read over MCP, which a shell cannot
#            call, so this mode never reads Slack: it decides only whether a sweep is
#            due (configured, onboarded, enabled, something to watch, not run today)
#            and hands the run its window and resolved config. The run itself reads
#            Slack (docs/sweep.md).
#   audit  — the weekly self-audit's deterministic checks (docs/audit.md).
#
# Requires: bash, jq, git, sed/grep/cut/tr, GNU date (Linux pod).

set -u
export LC_ALL=C

MODE="${1:-sweep}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
STATE_DIR="$WORK/state"
LEDGER="$STATE_DIR/captured.jsonl"
LAST="$STATE_DIR/last_sweep.json"
SENTINEL="$HOME_DIR/.slack-knowledge-sync-onboarded"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MAX_WINDOW_DAYS=14

LOGS=()
log() { LOGS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null || true
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
LOG_JOB="$MODE"
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi

iso2epoch() { date -d "$1" +%s 2>/dev/null \
              || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
epoch2iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

logs_json() { printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -sc '[.[] | select(length>0)]'; }

fail_out() {  # nothing-to-do JSON with an error; the precheck fails open on it
  jq -n --arg mode "$MODE" --arg err "$1" --argjson logs "$(logs_json)" \
    '{mode:$mode, nothing_to_do:true, error:$err, logs:$logs}'
  logev error preflight "$MODE: $1"
  exit 0
}

decline() {   # a deliberate "not due" — never an error
  log "$1"
  jq -n --arg mode "$MODE" --argjson logs "$(logs_json)" '{mode:$mode, nothing_to_do:true, logs:$logs}'
  logev info preflight "$MODE: not due — $1"
  exit 0
}

# ---------------------------------------------------------------- config ----
# Every key with its default; env vars win where the platform sets one.
resolve_config() {
  OWNER_ID="$(cfg owner_slack_user_id)"
  OWNER_DM="$(cfg owner_dm_chat_id)"
  SWEEP_ENABLED="$(cfg sweep_enabled)"; SWEEP_ENABLED="${SWEEP_ENABLED:-false}"
  SWEEP_TIME="$(cfg sweep_time)"; SWEEP_TIME="${SWEEP_TIME:-06:00}"
  TZONE="$(cfg timezone)"; TZONE="${TZONE:-UTC}"
  KB_MODE="$(cfg kb_mode)"; KB_MODE="${KB_MODE:-local}"
  KB_REPO="$(cfg kb_repo)"
  KB_PATH="$(cfg kb_path)"; KB_PATH="${KB_PATH:-knowledge/}"
  REPORT_LEVEL="$(cfg report_level)"; REPORT_LEVEL="${REPORT_LEVEL:-silent-when-nothing}"
  SENS_OVERRIDE="$(cfg sensitive_override)"; SENS_OVERRIDE="${SENS_OVERRIDE:-none}"
  RUN_MODEL="$(cfg run_model)"; RUN_MODEL="${RUN_MODEL:-default}"
  DEF_ISSUES="$(cfg definition_issues)"; DEF_ISSUES="${DEF_ISSUES:-disabled}"
  DEF_REPO="${DEFINITION_REPO:-$(cfg definition_repo)}"
  FOCUS="$(cfg_table capture_focus | sed -E 's/^\|[[:space:]]*//; s/[[:space:]]*\|[[:space:]]*$//' \
           | jq -R . | jq -sc '[.[] | select(length > 0)]')"
  EXCL="$(cfg_table extra_exclusions | sed -E 's/^\|[[:space:]]*//; s/[[:space:]]*\|[[:space:]]*$//' \
          | jq -R . | jq -sc '[.[] | select(length > 0)]')"
  WATCH="$(cfg_table watch | jq -R '
      split("|") | map(gsub("^\\s+|\\s+$"; "")) | .[1:-1]
      | select(length >= 2 and (.[0] | length) > 0)
      | {kind: .[0], target: .[1], note: (.[2] // "")}' 2>/dev/null | jq -sc .)"
  [ -n "$WATCH" ] || WATCH='[]'
  [ -n "$FOCUS" ] || FOCUS='[]'
  [ -n "$EXCL" ] || EXCL='[]'
}

config_json() {
  jq -nc --arg owner "$OWNER_ID" --arg dm "$OWNER_DM" --arg se "$SWEEP_ENABLED" \
    --arg st "$SWEEP_TIME" --arg tz "$TZONE" --arg km "$KB_MODE" --arg kr "$KB_REPO" \
    --arg kp "$KB_PATH" --arg rl "$REPORT_LEVEL" --arg so "$SENS_OVERRIDE" \
    --arg rm "$RUN_MODEL" --arg di "$DEF_ISSUES" --arg dr "$DEF_REPO" \
    --argjson focus "$FOCUS" --argjson watch "$WATCH" --argjson excl "$EXCL" '
    {owner_slack_user_id:$owner, owner_dm_chat_id:$dm, sweep_enabled:($se == "true"),
     sweep_time:$st, timezone:$tz, kb_mode:$km,
     kb_repo:(if $kr == "" then null else $kr end), kb_path:$kp,
     kb_dir:(if $km == "local" then "work/knowledge/" else null end),
     report_level:$rl,
     sensitive_override:(if $so == "none" then [] else ($so | split(",") | map(gsub("\\s"; ""))) end),
     run_model:$rm, definition_issues:$di,
     definition_repo:(if $dr == "" then null else $dr end),
     capture_focus:$focus, watch:$watch, extra_exclusions:$excl}'
}

# ============================================================ SWEEP MODE ====
mode_sweep() {
  # Each gate below is a deliberate decline; only a file that exists but cannot be
  # read is an error (the precheck fails open on it — a failed read is never "idle").
  [ -f "$CONFIG" ] || decline "work/CONFIG.md missing — not configured yet"
  [ -f "$SENTINEL" ] || decline "onboarding not finished (no sentinel)"
  resolve_config
  [ "$SWEEP_ENABLED" = true ] || decline "sweep_enabled is not true — on-demand captures only"
  [ "$(printf '%s' "$WATCH" | jq length)" -gt 0 ] || decline "the watch list is empty — nothing to sweep"
  [ -n "$OWNER_ID" ] || fail_out "owner_slack_user_id is missing from work/CONFIG.md — the sweep cannot tell the owner's own messages apart"
  if [ -f "$LEDGER" ] && [ ! -r "$LEDGER" ]; then fail_out "work/state/captured.jsonl exists but is unreadable"; fi
  # GNU date silently falls back to UTC on an unknown zone, so check the zone file
  # where the image ships them; an image without zoneinfo cannot tell, and says so
  if [ -d /usr/share/zoneinfo ] && [ "$TZONE" != UTC ] && [ ! -f "/usr/share/zoneinfo/$TZONE" ]; then
    fail_out "timezone '$TZONE' is not an IANA zone name"
  fi

  local today since since_e prev unrep capped=false
  today="$(TZ="$TZONE" date +%Y-%m-%d)"
  prev='null'; unrep='null'
  if [ -f "$LAST" ]; then
    prev="$(jq -c . "$LAST" 2>/dev/null)" || prev=""
    [ -n "$prev" ] && [ "$prev" != null ] \
      || fail_out "work/state/last_sweep.json exists but is not valid JSON"
    if [ "$(printf '%s' "$prev" | jq -r '.local_day // empty')" = "$today" ]; then
      decline "already swept today ($today, $TZONE)"
    fi
    unrep="$(printf '%s' "$prev" | jq -c '.unreported // null')"
    since="$(printf '%s' "$prev" | jq -r '.window_end // empty')"
  else
    since=""
  fi

  if [ -z "$since" ]; then
    since="$(epoch2iso $(( NOW_EPOCH - 86400 )))"
    log "first sweep: window opens 24 h back ($since)"
  else
    since_e="$(iso2epoch "$since")"
    if [ "$since_e" -eq 0 ]; then
      fail_out "last_sweep.json window_end '$since' is not a UTC timestamp"
    elif [ $(( NOW_EPOCH - since_e )) -gt $(( MAX_WINDOW_DAYS * 86400 )) ]; then
      since="$(epoch2iso $(( NOW_EPOCH - MAX_WINDOW_DAYS * 86400 )))"; capped=true
      log "last sweep window ended more than $MAX_WINDOW_DAYS days ago — window capped at $since; report the gap to the owner"
    fi
  fi

  local n_watch
  n_watch="$(printf '%s' "$WATCH" | jq length)"
  log "sweep due: $n_watch watched target(s) since $since"
  case "${LOG_RUN_ID:-}" in (probe-*) ;; (*)
    printf '%s sweep due watch=%s since=%s\n' "$NOW_ISO" "$n_watch" "$since" >> "$WORK/SWEEP.log" 2>/dev/null;; esac
  logev info preflight "sweep due watch=$n_watch"

  jq -n --arg now "$NOW_ISO" --arg since "$since" --arg today "$today" \
    --argjson cfg "$(config_json)" --argjson unrep "$unrep" --argjson logs "$(logs_json)" \
    --argjson capped "$capped" '
    {mode:"sweep", nothing_to_do:false, now:$now, since:$since, local_day:$today,
     window_capped:$capped,
     sweeps_due:[{id:"sweep:\($today)", since:$since, until:$now, targets:($cfg.watch | length)}],
     watch:$cfg.watch, unreported:$unrep,
     read_set:["docs/sweep.md","docs/capture.md"],
     title:"Sweep \($cfg.watch | length) watched Slack targets",
     config:$cfg, logs:$logs}'
}

# ============================================================ AUDIT MODE ====
CHECKS='[]'
check() { # <id> <ok|warn|fail> <detail>
  CHECKS="$(printf '%s' "$CHECKS" | jq -c --arg i "$1" --arg s "$2" --arg d "$3" '. + [{id:$i, status:$s, detail:$d}]')"
}

mode_audit() {
  local week_ago since_iso
  week_ago=$(( NOW_EPOCH - 7 * 86400 ))
  since_iso="$(epoch2iso "$week_ago")"
  [ -f "$CONFIG" ] && check config_present ok "work/CONFIG.md present" \
                   || check config_present fail "work/CONFIG.md missing — re-run ONBOARDING Step 3"
  resolve_config

  # --- structure: the same verifier onboarding ends with (offline scope)
  local vout vrc
  vout="$(WORK_DIR="$WORK" HOME="$HOME_DIR" bash "$SCRIPT_DIR/verify-onboarding.sh" 2>&1)"; vrc=$?
  if [ "$vrc" -eq 0 ]; then check structure ok "$(printf '%s' "$vout" | tail -1)"
  else check structure fail "$(printf '%s\n' "$vout" | grep '^FAIL' | head -5 | tr '\n' ' ' | cut -c1-600)"; fi

  # --- backup invariants
  [ -d "$WORK/.git" ] && check work_not_git fail "work/.git exists — work/ must stay a plain directory (docs/persistence.md)" \
                      || check work_not_git ok "work/ is a plain directory"
  local nfs
  nfs="$(find "$WORK" -name '.nfs*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$nfs" -eq 0 ] && check nfs_junk ok "no .nfs* files" || check nfs_junk warn "$nfs .nfs* file(s) under work/ — concurrent writers"

  # --- ledger shape: every row parseable, outcome known, sensitive rows store nothing
  local rows bad sens_paths
  if [ ! -f "$LEDGER" ]; then
    check ledger_shape warn "work/state/captured.jsonl missing — nothing captured yet, or state lost"
  elif [ ! -r "$LEDGER" ]; then
    check ledger_shape fail "work/state/captured.jsonl unreadable"
  else
    rows="$(grep -c . "$LEDGER" 2>/dev/null || echo 0)"
    bad="$(jq -cR 'fromjson? // "BAD"' "$LEDGER" 2>/dev/null | jq -s '[.[] | select(. == "BAD"
        or ((.id // "") | test("^[CDG][A-Z0-9]{6,}:[0-9]{9,10}\\.[0-9]{6}$") | not)
        or ((.outcome // "") | IN("captured","skipped-sensitive","skipped-noise","failed") | not))] | length')"
    sens_paths="$(jq -cR 'fromjson? // empty' "$LEDGER" 2>/dev/null \
      | jq -s '[.[] | select(.outcome == "skipped-sensitive" and ((.paths // []) | length) > 0)] | length')"
    if [ "${bad:-0}" -gt 0 ]; then check ledger_shape fail "$bad of $rows ledger row(s) unparseable or out of shape"
    elif [ "${sens_paths:-0}" -gt 0 ]; then check ledger_shape fail "$sens_paths skipped-sensitive row(s) carry paths — they must store nothing but the id"
    else check ledger_shape ok "$rows row(s) in shape"; fi
  fi

  # --- the knowledge base (local mode): note shape, credential scan, sensitive leaks
  if [ "$KB_MODE" = local ]; then
    local kout
    kout="$(WORK_DIR="$WORK" HOME="$HOME_DIR" bash "$SCRIPT_DIR/kb-check.sh" 2>/dev/null)"
    if ! printf '%s' "$kout" | jq -e 'type == "object"' >/dev/null 2>&1; then
      check kb_shape warn "not measured — scripts/kb-check.sh printed no JSON"
    else
      local np nn
      np="$(printf '%s' "$kout" | jq '.problems | length')"; nn="$(printf '%s' "$kout" | jq '.notes')"
      if [ "$np" -eq 0 ]; then check kb_shape ok "$nn note(s), all in shape"
      else
        local sev; sev="$(printf '%s' "$kout" | jq -r 'if any(.problems[]; .severity == "fail") then "fail" else "warn" end')"
        check kb_shape "$sev" "$np problem(s) in $nn note(s): $(printf '%s' "$kout" | jq -r '[.problems[:5][] | "\(.path): \(.problem)"] | join("; ")' | cut -c1-500)"
      fi
    fi
  else
    check kb_shape ok "GitHub mode — notes live in pull requests; the audit samples them (docs/audit.md)"
  fi

  # --- the knowledge base must never be trackable by the definition repo
  if git -C "$HOME_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$HOME_DIR" ls-files -- work knowledge 2>/dev/null)" ]; then
      check kb_untracked fail "files under work/ or knowledge/ are tracked by the definition repo — remove them from the index (git rm --cached) and fix .gitignore"
    else check kb_untracked ok "nothing under work/ or knowledge/ is tracked"; fi
    local dirty; dirty="$(git -C "$HOME_DIR" status --porcelain 2>/dev/null | head -5 | tr '\n' ' ')"
    [ -z "$dirty" ] && check definition_clean ok "definition checkout clean" \
                    || check definition_clean warn "definition checkout has local changes: $dirty"
  else
    check kb_untracked warn "not measured — $HOME_DIR is not a git checkout"
    check definition_clean warn "not measured — $HOME_DIR is not a git checkout"
  fi

  # --- version currency (a read: fetch, never merge)
  local v_co v_ad v_up
  v_co="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null)"; v_ad="$(head -1 "$WORK/VERSION" 2>/dev/null)"
  v_up=""
  if git -C "$HOME_DIR" fetch -q origin main 2>/dev/null; then
    v_up="$(git -C "$HOME_DIR" show origin/main:VERSION 2>/dev/null | head -1)"
  fi
  if [ -z "$v_up" ]; then check version warn "latest not measured (fetch failed); checked out ${v_co:-?}, adopted ${v_ad:-?}"
  elif [ "$v_co" != "$v_up" ] || [ "$v_co" != "${v_ad:-1.0.0}" ]; then
    check version warn "checked out ${v_co:-?}, latest $v_up, adopted ${v_ad:-1.0.0} — version check in the direct session"
  else check version ok "up to date ($v_co)"; fi

  # --- sweep cadence (only when the owner turned the sweep on)
  if [ "$SWEEP_ENABLED" = true ]; then
    local la
    la="$(jq -r '.last_sweep_at // empty' "$LAST" 2>/dev/null)"
    if [ -z "$la" ]; then check sweep_cadence warn "sweep enabled but no sweep finished yet"
    elif [ $(( NOW_EPOCH - $(iso2epoch "$la") )) -gt 129600 ]; then
      check sweep_cadence warn "last finished sweep $la — more than 36 h ago"
    else check sweep_cadence ok "last finished sweep $la"; fi
  else
    check sweep_cadence ok "sweep disabled — on-demand only"
  fi

  # --- precheck health, timed (fail-open breakage is otherwise invisible)
  local m t0 rc dt
  for m in sweep monitor; do
    t0=$(date +%s)
    LOG_RUN_ID="probe-audit-$$" PRECHECK_BUDGET_S=60 HOME="$HOME_DIR" WORK_DIR="$WORK" \
      bash "$SCRIPT_DIR/precheck.sh" "$m" >/dev/null 2>&1; rc=$?
    dt=$(( $(date +%s) - t0 ))
    if { [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; } && [ "$dt" -lt 60 ]; then
      check "precheck_$m" ok "exit $rc in ${dt}s"
    else
      check "precheck_$m" fail "exit $rc in ${dt}s — a broken gate fails open and every fire runs a full turn"
    fi
  done

  # --- harness adapter parts
  local parts
  if [ -f "$SCRIPT_DIR/harness/claude-code/install.sh" ]; then
    parts="$(bash "$SCRIPT_DIR/harness/claude-code/install.sh" --check 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    [ -z "$parts" ] && check harness ok "hooks, auto-mode rules and tool deny list current" \
                    || check harness warn "not current: $parts — re-run scripts/harness/claude-code/install.sh"
  fi

  # --- toolchain shims (reported, never absorbed)
  local shims; shims="$(toolpath_shimmed jq gh 2>/dev/null)"
  [ -z "$shims" ] && check tool_shims ok "no CLI behind a version-manager shim" \
                  || check tool_shims warn "behind a mise shim: $shims — the pod image owns the fix"

  # --- leftovers, disk
  local left; left="$(find /tmp -maxdepth 1 -name 'slack-knowledge-sync-*' -type d -mmin +360 2>/dev/null | wc -l | tr -d ' ')"
  [ "$left" -eq 0 ] && check tmp_leftovers ok "no leftover /tmp/slack-knowledge-sync-* directories" \
                    || check tmp_leftovers warn "$left leftover /tmp/slack-knowledge-sync-* director(ies) older than 6 h"
  local use; use="$(df -P "$WORK" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if [ -z "$use" ]; then check disk warn "not measured — df failed"
  elif [ "$use" -ge 90 ]; then check disk fail "home volume ${use}% full"
  elif [ "$use" -ge 80 ]; then check disk warn "home volume ${use}% full"
  else check disk ok "home volume ${use}% full"; fi

  # --- the week's events: failures grouped into signatures, then retention
  local ev failures
  ev="$(find "$WORK/logs" -maxdepth 1 -name 'events-*.jsonl' -mtime -8 2>/dev/null | sort)"
  if [ -n "$ev" ]; then
    # shellcheck disable=SC2086
    failures="$(cat $ev 2>/dev/null | jq -cR 'fromjson? // empty' | jq -sc --arg since "$since_iso" '
      [ .[] | select(.level == "error" and .ts >= $since) ]
      | group_by(.event + " " + (.msg | gsub("[0-9]+"; "N") | gsub("[CDGU][A-Z0-9N]{6,}"; "<id>") | .[:80]))
      | map({event: .[0].event, signature: (.[0].msg | gsub("[0-9]+"; "N") | .[:120]),
             count: length, first: (map(.ts) | min), last: (map(.ts) | max)})')"
  fi
  [ -n "${failures:-}" ] || failures='[]'
  find "$WORK/logs" -maxdepth 1 -name 'events-*.jsonl' -mtime +14 -delete 2>/dev/null || true

  # --- the week in numbers (from the ledger and the run logs)
  local stats
  stats="$(jq -cR 'fromjson? // empty' "$LEDGER" 2>/dev/null | jq -sc --arg since "$since_iso" '
      [ .[] | select(.captured_at >= $since) ] as $w
      | {threads: ($w | length),
         captured: ([$w[] | select(.outcome == "captured")] | length),
         skipped_sensitive: ([$w[] | select(.outcome == "skipped-sensitive")] | length),
         skipped_noise: ([$w[] | select(.outcome == "skipped-noise")] | length),
         failed: ([$w[] | select(.outcome == "failed")] | length),
         notes_touched: ([$w[] | .paths[]?] | unique | length)}' 2>/dev/null)"
  [ -n "$stats" ] || stats='{"threads":null}'
  local sweeps
  sweeps="$(awk -v s="$since_iso" '$1 >= s && $2 == "sweep" && $3 ~ /^captured=/' "$WORK/SWEEP.log" 2>/dev/null | wc -l | tr -d ' ')"
  stats="$(printf '%s' "$stats" | jq -c --argjson s "${sweeps:-0}" '. + {sweeps_finished: $s}')"

  jq -n --arg now "$NOW_ISO" --arg since "$since_iso" --argjson checks "$CHECKS" \
    --argjson failures "$failures" --argjson stats "$stats" --argjson cfg "$(config_json)" \
    --argjson logs "$(logs_json)" '
    {mode:"audit", nothing_to_do:false, now:$now, since:$since,
     checks:$checks, failures:$failures, stats:$stats,
     read_set:["docs/audit.md"], title:"Audit the week", config:$cfg, logs:$logs}'
}

case "$MODE" in
  sweep) mode_sweep ;;
  audit) mode_audit ;;
  *) fail_out "unknown mode: $MODE (sweep|audit)" ;;
esac
