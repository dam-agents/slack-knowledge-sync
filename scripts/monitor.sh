#!/usr/bin/env bash
# monitor.sh — the monitor's detector for slack-knowledge-sync: the agent's health alerts,
# apart from the work heartbeat (docs/monitor.md).
#
# The ledger, the claim rule and the output are the definition template's, verbatim;
# the domain conditions are `slack_unavailable` and `sweep_stalled`. Thresholds are
# work/CONFIG.md keys with the defaults below.
#
# Detects, never acts: reads local files only — the events log, ledgers, the harness
# settings — makes no external call and costs no quota. Its writes are bookkeeping:
# the alert ledger work/MONITOR.json, MONITOR.log and the events log. This agent
# ships no direct delivery: the monitor session sends the alert to the owner's DM
# (docs/monitor.md).
#
#   monitor.sh            -> one JSON object: alerts_due[] (each with an id and a
#                            kind), suppressed, read_set, config, logs;
#                            nothing_to_do when nothing is due
#   monitor.sh ack <id>…  -> records the alerts as sent (send-then-record)
#
# An alerts_due entry is CLAIMED when emitted: a tick inside CLAIM_TTL_S skips it,
# after that it is due again — a session that died before its ack (a model outage is
# the usual cause) loses nothing. A sent alert is never emitted again. A condition
# that clears leaves the ledger, so its return alerts again.
#
# Requires: bash, jq, GNU or BSD date.

set -u
export LC_ALL=C

CMD="${1:-detect}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
STATE="$WORK/MONITOR.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LOG_JOB=monitor
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi
LOG_DIR="${LOG_DIR:-$WORK/logs}"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }

LOGS=()
log() { LOGS+=("$1"); logev info monitor "$1"; }

CLAIM_TTL_S=1800                 # an emitted, unacknowledged alert is due again after this
STATE_KEEP_S=$(( 14 * 86400 ))   # a row whose condition no tick finds goes after this
OUTAGE_GAP_S=3600                # API failures this far apart are two outages

# a non-negative integer key: missing -> <default>, off/none -> 0
int_key() { # <key> <default>
  local v; v="$(cfg "$1")"
  case "$v" in
    ('') printf '%s' "$2";;
    (off|none) printf 0;;
    (*[!0-9]*) log "$1 '$v' is not a number, 0 or off — using $2"; printf '%s' "$2";;
    (*) printf '%s' "$v";;
  esac
}

# the retained events newer than <epoch>, one JSON object per line, torn lines skipped;
# the daily files back to that epoch, plus one for the UTC day boundary
events_since() { # <epoch>
  local f days=$(( (NOW_EPOCH - $1) / 86400 + 2 ))
  for f in $(find "$LOG_DIR" -maxdepth 1 -name 'events-*.jsonl' -mtime "-$days" 2>/dev/null | sort); do
    cat "$f" 2>/dev/null
  done | jq -cR 'fromjson? // empty' 2>/dev/null \
       | jq -c --argjson since "$1" \
           'select(((.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0) >= $since)
            | select((.run // "") | startswith("probe-") | not)' 2>/dev/null
}
# probe runs (the audit's and the verifier's timed precheck calls, LOG_RUN_ID=probe-…)
# are not gate ticks: they must neither hide a heartbeat gap nor open a stalled sweep
EP='def ep: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0;'

# ---------------------------------------------------------------- ledger ----
# {"alerts": {"<id>": {"kind", "first", "claimed", "sent"}}}; one writer at a time
# (a mkdir lock: one older than 60 s is a dead writer's, a wait past 120 s writes
# without it); a broken file reads as empty
state_read() { jq -c 'if (.alerts | type) == "object" then . else {alerts: {}} end' "$STATE" 2>/dev/null || echo '{"alerts":{}}'; }
state_write() { printf '%s\n' "$1" > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE" 2>/dev/null; rm -f "$STATE.tmp" 2>/dev/null; }
with_state_lock() { # <fn> [args…]
  local lock="$STATE.lock" i=0
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 120 ] && { log "ledger lock held past 2 min — writing without it"; break; }
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rm -rf "$lock" 2>/dev/null
    sleep 1
  done
  "$@"; local rc=$?
  rmdir "$lock" 2>/dev/null
  return $rc
}
ack_apply() { # <ids json>
  state_write "$(state_read | jq -c --argjson ids "$1" --arg now "$NOW_ISO" '
    reduce $ids[] as $i (.; .alerts[$i] = ((.alerts[$i] // {kind: ($i | split(":")[0]), first: $now}) + {sent: $now}))')"
}

if [ "$CMD" = ack ]; then
  shift
  [ "$#" -gt 0 ] || { echo '{"error":"ack needs at least one alert id"}'; exit 2; }
  ids="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  with_state_lock ack_apply "$ids"
  logev info monitor_alert_sent "$*"
  jq -nc --argjson ids "$ids" '{acknowledged: $ids}'
  exit 0
fi
[ "$CMD" = detect ] || { echo '{"error":"unknown command — use monitor.sh or monitor.sh ack <id>…"}'; exit 2; }

[ -f "$CONFIG" ] || log "work/CONFIG.md missing — running with defaults"
MODEL_THRESHOLD="$(int_key model_alert_threshold 2)"
CLASSIFIER_THRESHOLD="$(int_key classifier_alert_threshold 20)"
GAP_MIN="$(int_key heartbeat_gap_min 2160)"   # 1.5 × the daily sweep interval
SLACK_THRESHOLD="$(int_key slack_alert_threshold 3)"
STALL_MIN="$(int_key sweep_stall_min 360)"
WORK_MODE="sweep"                             # the gated mode whose gate ticks prove liveness
# the sweep is the owner's opt-in: with it off, no gate ever ticks and no gap is a fault
[ "$(cfg sweep_enabled)" = true ] || GAP_MIN=0

# candidate alerts of this tick, one JSON object per line, each with id + kind; and
# the kinds whose condition cleared, so their rows leave the ledger
CANDIDATES=""; CLEARED=""
cand() { CANDIDATES="$CANDIDATES$1"$'\n'; }
RECENT="$(events_since $(( NOW_EPOCH - 86400 )) | jq -sc .)"

# ------------------------------------------------------ model unavailable ----
# api_failure events (the StopFailure hook) of the availability classes, grouped into
# outages: failures under OUTAGE_GAP_S apart are one. An outage alerts once at the
# threshold, and once more when over if its first alert went out while it was open.
if [ "$MODEL_THRESHOLD" -gt 0 ]; then
  OUTAGES="$(printf '%s' "$RECENT" | jq -c --argjson gap "$OUTAGE_GAP_S" --argjson t "$MODEL_THRESHOLD" --argjson now "$NOW_EPOCH" "$EP"'
    [ .[] | select(.event == "api_failure" and (.msg | test("^(invalid_request|max_output_tokens)") | not))
          | {e: (.ts | ep), class: (.msg | split(":")[0])} ]
    | sort_by(.e)
    | reduce .[] as $f ([];
        if length > 0 and ($f.e - .[-1].last) < $gap
        then .[:-1] + [.[-1] | .last = $f.e | .n += 1 | .classes += [$f.class]]
        else . + [{first: $f.e, last: $f.e, n: 1, classes: [$f.class]}] end)
    | map(select(.n >= $t) | . + {open: (($now - .last) < $gap), id: "model:\(.first)"})
    | .[] | {id, kind: (if .open then "model_unavailable" else "model_recovered" end),
             first: (.first | todate), last: (.last | todate), runs_lost: .n, classes: (.classes | unique)}')"
  LEDGER="$(state_read)"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$(printf '%s' "$l" | jq -r .kind)" = model_recovered ]; then
      printf '%s' "$LEDGER" | jq -e --arg i "$(printf '%s' "$l" | jq -r .id)" '.alerts[$i].sent != null' >/dev/null 2>&1 || continue
      l="$(printf '%s' "$l" | jq -c '.id += ":recovered"')"
    fi
    cand "$l"
  done <<EOF
$OUTAGES
EOF
fi

# -------------------------------------------------------- classifier spike ----
if [ "$CLASSIFIER_THRESHOLD" -gt 0 ]; then
  N="$(printf '%s' "$RECENT" | jq '[.[] | select(.event == "classifier_block")] | length')"
  if [ "$N" -ge "$CLASSIFIER_THRESHOLD" ]; then
    cand "$(printf '%s' "$RECENT" | jq -c --argjson n "$N" --argjson t "$CLASSIFIER_THRESHOLD" --arg d "${NOW_ISO:0:10}" '
      {id: "classifier:\($d)", kind: "classifier_spike", blocks: $n, threshold: $t,
       top: ([.[] | select(.event == "classifier_block") | .msg | split(" — ")[0]]
             | group_by(.) | map({pattern: .[0], n: length}) | sort_by(-.n) | .[:3])}')"
  fi
fi

# ----------------------------------------------------------- heartbeat gap ----
# no gate tick of the work mode for GAP_MIN: the schedule is disabled, deleted or its
# gate cannot start. A fresh instance with no tick yet alerts nothing.
LAST_TICK="$(events_since $(( NOW_EPOCH - 7 * 86400 )) \
  | jq -r --arg job "$WORK_MODE" "$EP"'select(.job == $job and .event == "precheck") | .ts | ep' | sort -n | tail -1)"
if [ "$GAP_MIN" -gt 0 ] && [ -n "$LAST_TICK" ] && [ $(( (NOW_EPOCH - LAST_TICK) / 60 )) -ge "$GAP_MIN" ]; then
  cand "$(jq -nc --argjson e "$LAST_TICK" --argjson gap "$GAP_MIN" --arg mode "$WORK_MODE" \
    '{id: "heartbeat:\($mode)", kind: "heartbeat_gap", last_tick: ($e | todate), gap_min: $gap}')"
else
  CLEARED="$CLEARED heartbeat_gap"
fi

# ---------------------------------------------------------- backup failing ----
# the oldest backup error after the last successful push, once it is 6 h old
if [ -n "${GITHUB_REPO_WORK:-}" ]; then
  ERR="$(events_since $(( NOW_EPOCH - 86400 )) | jq -sc "$EP"'
    [.[] | select(.event == "work_backup")] | sort_by(.ts | ep)
    | (map(select(.msg | startswith("pushed"))) | last) as $ok
    | [.[] | select(.level == "error" and ($ok == null or (.ts | ep) > ($ok.ts | ep)))] | first')"
  if [ -n "$ERR" ] && [ "$ERR" != null ] \
     && [ $(( NOW_EPOCH - $(printf '%s' "$ERR" | jq -r "$EP"'.ts | ep') )) -ge 21600 ]; then
    cand "$(printf '%s' "$ERR" | jq -c '{id: "backup", kind: "backup_failing", since: .ts, sample: (.msg | .[:200])}')"
  else
    CLEARED="$CLEARED backup_failing"
  fi
fi

# ----------------------------------------------------------- harness drift ----
INSTALL="$SCRIPT_DIR/harness/claude-code/install.sh"
if [ -f "$INSTALL" ]; then
  PARTS="$(bash "$INSTALL" --check 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$PARTS" ]; then
    cand "$(jq -nc --arg p "$PARTS" '{id: "harness", kind: "harness_drift", parts: ($p | split(" "))}')"
  else
    CLEARED="$CLEARED harness_drift"
  fi
fi

# ------------------------------------------------------- domain conditions ----
# slack_unavailable: SLACK_THRESHOLD `slack_read_failed` events (the agent logs one
# per failed Slack MCP read, docs/capture.md) in 24 h with no `capture` event after
# the last of them — the connection expired, was revoked, or Slack is down.
if [ "$SLACK_THRESHOLD" -gt 0 ]; then
  SL="$(printf '%s' "$RECENT" | jq -c --argjson t "$SLACK_THRESHOLD" "$EP"'
    ([.[] | select(.event == "slack_read_failed")] | sort_by(.ts | ep)) as $f
    | ([.[] | select(.event == "capture")] | map(.ts | ep) | max // 0) as $ok
    | if ($f | length) >= $t and (($f | last | .ts | ep) > $ok)
      then {id: "slack:\($f[0].ts[0:10])", kind: "slack_unavailable", failures: ($f | length),
            first: $f[0].ts, last: ($f | last | .ts)}
      else empty end')"
  if [ -n "$SL" ]; then cand "$SL"; else CLEARED="$CLEARED slack_unavailable"; fi
fi

# sweep_stalled: the gate let a sweep start (a `precheck` "work due" event of the
# sweep job) and no `sweep_done` followed within STALL_MIN — the session died
# mid-sweep or ended without closing it; the next sweep re-reads the same window.
if [ "$STALL_MIN" -gt 0 ]; then
  ST="$(printf '%s' "$RECENT" | jq -c --argjson s "$(( STALL_MIN * 60 ))" --argjson now "$NOW_EPOCH" "$EP"'
    ([.[] | select(.job == "sweep" and .event == "precheck" and (.msg | test("work due")))] | map(.ts | ep) | max // 0) as $due
    | ([.[] | select(.event == "sweep_done")] | map(.ts | ep) | max // 0) as $done
    | if $due > 0 and $done < $due and ($now - $due) >= $s
      then {id: "stall:\($due)", kind: "sweep_stalled", started: ($due | todate), stall_min: ($s / 60)}
      else empty end')"
  if [ -n "$ST" ]; then cand "$ST"; else CLEARED="$CLEARED sweep_stalled"; fi
fi

# ------------------------------------------ claim against the ledger ----
# a candidate is due when its row has no `sent` and no claim younger than
# CLAIM_TTL_S; a sent one is suppressed; rows of cleared kinds, and rows older than
# STATE_KEEP_S that no candidate names, leave
DUE='[]'; SUPPRESSED=0
claim() {
  local cands new
  cands="$(printf '%s' "$CANDIDATES" | jq -sc '[.[] | objects]' 2>/dev/null || echo '[]')"
  new="$(state_read | jq -c --argjson c "$cands" --arg now "$NOW_ISO" --argjson nowe "$NOW_EPOCH" \
      --argjson ttl "$CLAIM_TTL_S" --argjson keep "$STATE_KEEP_S" --arg cleared "$CLEARED" "$EP"'
    ($cleared | split(" ") | map(select(length > 0))) as $cl
    | (.alerts | with_entries(select(
         ([.key] | inside([$c[].id]))
         or (((.value.kind as $k | $cl | index($k)) == null)
             and ($nowe - ((.value.sent // .value.claimed // .value.first // $now) | ep)) < $keep)))) as $a
    | { due: [ $c[] | select($a[.id].sent == null
                             and (($a[.id].claimed == null) or ($nowe - ($a[.id].claimed | ep)) >= $ttl)) ],
        suppressed: ([ $c[] | select($a[.id].sent != null) ] | length) } as $r
    | { due: $r.due, suppressed: $r.suppressed,
        state: {alerts: (reduce $r.due[] as $d ($a;
                  .[$d.id] = ((.[$d.id] // {kind: $d.kind, first: $now}) + {claimed: $now})))} }' 2>/dev/null)" \
    || return 1
  DUE="$(printf '%s' "$new" | jq -c .due)"
  SUPPRESSED="$(printf '%s' "$new" | jq .suppressed)"
  # a probe (the audit's timed precheck) reports what is due but claims nothing
  case "${LOG_RUN_ID:-}" in (probe-*) ;; (*) state_write "$(printf '%s' "$new" | jq -c .state)";; esac
}
with_state_lock claim || log "alert ledger unreadable — no alert claimed this tick"
[ "$SUPPRESSED" -gt 0 ] && log "suppressed $SUPPRESSED alert(s) already reported"

# ---------------------------------------------------------------- output ----
N_DUE="$(printf '%s' "$DUE" | jq length)"
NOTHING=true; [ "$N_DUE" -gt 0 ] && NOTHING=false
[ "$N_DUE" -gt 0 ] && log "alerts due: $(printf '%s' "$DUE" | jq -r 'group_by(.kind)
  | map(.[0].kind + (if length > 1 then "×\(length)" else "" end)) | join(", ")')"
printf '%s\n' "$NOW_ISO monitor nothing_to_do=$NOTHING ${LOGS[*]:-}" >> "$WORK/MONITOR.log" 2>/dev/null
logev info heartbeat "mode=monitor nothing_to_do=$NOTHING alerts=$N_DUE"

jq -n --argjson nothing "$NOTHING" --argjson due "$DUE" --argjson sup "$SUPPRESSED" \
  --argjson mt "$MODEL_THRESHOLD" --argjson ct "$CLASSIFIER_THRESHOLD" --argjson gap "$GAP_MIN" \
  --argjson st "$SLACK_THRESHOLD" --argjson sm "$STALL_MIN" --arg dm "$(cfg owner_dm_chat_id)" \
  --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" '
  {mode: "monitor", nothing_to_do: $nothing, alerts_due: $due, suppressed: $sup,
   read_set: (if $nothing then [] else ["docs/monitor.md"] end), logs: $logs,
   config: {model_alert_threshold: $mt, classifier_alert_threshold: $ct, heartbeat_gap_min: $gap,
            slack_alert_threshold: $st, sweep_stall_min: $sm,
            owner_dm_chat_id: (if $dm == "" then null else $dm end)}}'
exit 0
