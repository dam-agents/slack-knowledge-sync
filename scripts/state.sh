#!/usr/bin/env bash
# state.sh — the one writer of slack-knowledge-sync's capture state. The agent calls it;
# it never hand-edits work/state/*. Every write takes a mkdir lock beside its file
# (an on-demand capture in the owner's DM may overlap a sweep), so two sessions never
# interleave a line.
#
#   state.sh due <id> <latest_ts>                 -> {"due":bool,"reason":…,"previous":…}
#   state.sh record <id> <latest_ts> <outcome> [path…]
#                                                 -> {"recorded":…} — appends one ledger row
#   state.sh sweep-done --started <iso> --since <iso> --captured N --skipped N --failed N
#                       --reported yes|no [--notes <comma list>]
#                                                 -> writes work/state/last_sweep.json
#   state.sh inbox-seen <msg_ts>                  -> {"seen":bool}
#   state.sh inbox <msg_ts> <action>              -> appends to work/state/inbox.jsonl
#   state.sh event <level> <event> <msg>          -> one events-log line (ids and counts only)
#
# A thread id is `<channel_id>:<thread_ts>` (CLAUDE.md → Hard invariants). Outcomes:
# captured | skipped-sensitive | skipped-noise | failed. A skipped-sensitive row carries
# NO paths: nothing about the thread is stored beyond its id (docs/capture.md →
# Sensitive topics). Every answer is one JSON object; exit 0 on success, 2 on a refused
# or failed write — the agent reads the JSON, never only the exit status.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
STATE_DIR="$WORK/state"
LEDGER="$STATE_DIR/captured.jsonl"
LAST="$STATE_DIR/last_sweep.json"
INBOX="$STATE_DIR/inbox.jsonl"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null || true
LOG_JOB="${LOG_JOB:-session}"
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ID_RE='^[CDG][A-Z0-9]{6,}:[0-9]{9,10}\.[0-9]{6}$'
TS_RE='^[0-9]{9,10}\.[0-9]{6}$'
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

out()  { printf '%s\n' "$1"; }
refuse() { jq -nc --arg e "$1" '{error:$e}'; exit 2; }

with_lock() { # <file> <fn> [args…] — a lock older than 60 s is a dead writer's;
              # a waiter writes without it only after 120 s (never bypasses a young one)
  local lock="$1.lock" i=0; shift
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 120 ] && { logev warn state_lock "lock on $(basename "$lock") held past 2 min — writing without it"; break; }
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rm -rf "$lock" 2>/dev/null
    sleep 1
  done
  "$@"; local rc=$?
  rmdir "$lock" 2>/dev/null
  return $rc
}

# the newest row for one id (the ledger is append-only; the last row wins)
latest_row() { # <id>
  [ -f "$LEDGER" ] || return 0
  grep -F "\"id\":\"$1\"" "$LEDGER" 2>/dev/null | tail -1
}

# ts comparison without floating point: both are <seconds>.<6 digits>
ts_gt() { # <a> <b> -> 0 when a > b
  local a="${1/./}" b="${2/./}"
  [ "${#a}" -lt 16 ] && a="0$a"; [ "${#b}" -lt 16 ] && b="0$b"
  [[ "$a" > "$b" ]]
}

mkdir -p "$STATE_DIR" 2>/dev/null || refuse "cannot create $STATE_DIR"
CMD="${1:-}"; [ $# -gt 0 ] && shift

case "$CMD" in
  due)
    [ $# -eq 2 ] || refuse "usage: state.sh due <id> <latest_ts>"
    printf '%s' "$1" | grep -qE "$ID_RE" || refuse "not a thread id: $1"
    printf '%s' "$2" | grep -qE "$TS_RE" || refuse "not a Slack ts: $2"
    if [ -f "$LEDGER" ] && [ ! -r "$LEDGER" ]; then refuse "ledger unreadable"; fi
    row="$(latest_row "$1")"
    if [ -z "$row" ]; then
      out '{"due":true,"reason":"new","previous":null}'
    else
      prev_ts="$(printf '%s' "$row" | jq -r '.latest_ts // empty' 2>/dev/null)"
      prev_out="$(printf '%s' "$row" | jq -r '.outcome // empty' 2>/dev/null)"
      [ -n "$prev_ts" ] || refuse "ledger row for $1 is unreadable — fix it before capturing (docs/capture.md)"
      if [ "$prev_out" = failed ]; then
        jq -nc --argjson r "$row" '{due:true, reason:"retry-after-failure", previous:$r}'
      elif ts_gt "$2" "$prev_ts"; then
        jq -nc --argjson r "$row" '{due:true, reason:"new-replies", previous:$r}'
      else
        jq -nc --argjson r "$row" '{due:false, reason:"already-handled", previous:$r}'
      fi
    fi
    ;;

  record)
    [ $# -ge 3 ] || refuse "usage: state.sh record <id> <latest_ts> <outcome> [path…]"
    id="$1"; lts="$2"; outcome="$3"; shift 3
    printf '%s' "$id" | grep -qE "$ID_RE" || refuse "not a thread id: $id"
    printf '%s' "$lts" | grep -qE "$TS_RE" || refuse "not a Slack ts: $lts"
    case "$outcome" in (captured|skipped-sensitive|skipped-noise|failed) ;;
      (*) refuse "unknown outcome: $outcome (captured|skipped-sensitive|skipped-noise|failed)";; esac
    if [ "$outcome" = skipped-sensitive ] && [ $# -gt 0 ]; then
      refuse "a skipped-sensitive thread stores nothing but its id — record it without paths"
    fi
    if [ "$outcome" = captured ] && [ $# -eq 0 ]; then
      refuse "a captured thread names the knowledge base paths (or PR URL) it touched"
    fi
    for p in "$@"; do
      case "$p" in
        (https://*) ;;                                   # a PR URL in GitHub mode
        (/*|*..*) refuse "path must be relative to the knowledge base, without '..': $p";;
      esac
    done
    paths="$(printf '%s\n' "$@" | jq -R . | jq -sc '[.[] | select(length > 0)]')"
    row="$(jq -nc --arg id "$id" --arg l "$lts" --arg o "$outcome" --arg at "$NOW_ISO" \
      --argjson p "$paths" '{id:$id, latest_ts:$l, captured_at:$at, outcome:$o, paths:$p}')"
    append() { printf '%s\n' "$row" >> "$LEDGER"; }
    with_lock "$LEDGER" append || refuse "ledger write failed"
    logev info capture "$id outcome=$outcome paths=$(printf '%s' "$paths" | jq length)"
    jq -nc --argjson r "$row" '{recorded:$r}'
    ;;

  sweep-done)
    started=""; since=""; cap=0; skip=0; failed=0; reported=""; notes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        (--started) started="${2:-}"; shift 2;;
        (--since) since="${2:-}"; shift 2;;
        (--captured) cap="${2:-}"; shift 2;;
        (--skipped) skip="${2:-}"; shift 2;;
        (--failed) failed="${2:-}"; shift 2;;
        (--reported) reported="${2:-}"; shift 2;;
        (--notes) notes="${2:-}"; shift 2;;
        (*) refuse "unknown flag: $1";;
      esac
    done
    printf '%s' "$started" | grep -qE "$ISO_RE" || refuse "--started must be the worklist's UTC 'now'"
    printf '%s' "$since" | grep -qE "$ISO_RE" || refuse "--since must be the worklist's UTC 'since'"
    for n in "$cap" "$skip" "$failed"; do
      case "$n" in (''|*[!0-9]*) refuse "counts are whole numbers";; esac
    done
    case "$reported" in (yes|no) ;; (*) refuse "--reported yes|no";; esac
    TZV="$(CONFIG="$WORK/CONFIG.md"; . "$SCRIPT_DIR/lib/config.sh"; cfg timezone)"
    day="$(TZ="${TZV:-UTC}" date +%Y-%m-%d)"
    write_last() {
      local prev unrep
      prev="$(jq -c . "$LAST" 2>/dev/null || echo '{}')"
      # an unsent report is carried into the next sweep's report (send-then-record);
      # a sent one clears what was carried
      if [ "$reported" = yes ]; then unrep='null'
      else
        unrep="$(printf '%s' "$prev" | jq -c --argjson c "$cap" --argjson f "$failed" --arg n "$notes" '
          (.unreported // {captured:0, failed:0, notes:[]}) as $u
          | {captured: ($u.captured + $c), failed: ($u.failed + $f),
             notes: (($u.notes + ($n | split(",") | map(select(length > 0)))) | unique | .[:50])}')"
      fi
      jq -n --arg at "$NOW_ISO" --arg day "$day" --arg s "$since" --arg e "$started" \
        --argjson c "$cap" --argjson k "$skip" --argjson f "$failed" --argjson u "$unrep" '
        {last_sweep_at:$at, local_day:$day, window_start:$s, window_end:$e,
         captured:$c, skipped:$k, failed:$f, unreported:$u}' > "$LAST.tmp" && mv "$LAST.tmp" "$LAST"
    }
    with_lock "$LAST" write_last || refuse "last_sweep.json write failed"
    printf '%s sweep captured=%s skipped=%s failed=%s reported=%s\n' "$NOW_ISO" "$cap" "$skip" "$failed" "$reported" \
      >> "$WORK/SWEEP.log" 2>/dev/null
    logev info sweep_done "captured=$cap skipped=$skip failed=$failed reported=$reported"
    jq -c . "$LAST"
    ;;

  inbox-seen)
    [ $# -eq 1 ] || refuse "usage: state.sh inbox-seen <msg_ts>"
    if [ -f "$INBOX" ] && grep -qF "\"msg_ts\":\"$1\"" "$INBOX" 2>/dev/null; then
      out '{"seen":true}'; else out '{"seen":false}'; fi
    ;;

  inbox)
    [ $# -eq 2 ] || refuse "usage: state.sh inbox <msg_ts> <action>"
    printf '%s' "$1" | grep -qE "$TS_RE" || refuse "not a Slack ts: $1"
    case "$2" in (capture-thread|capture-channel|status|declined|surfaced) ;;
      (*) refuse "unknown action: $2";; esac
    row="$(jq -nc --arg t "$1" --arg a "$2" --arg at "$NOW_ISO" '{msg_ts:$t, handled_at:$at, action:$a}')"
    append_inbox() { printf '%s\n' "$row" >> "$INBOX"; }
    with_lock "$INBOX" append_inbox || refuse "inbox write failed"
    jq -nc --argjson r "$row" '{recorded:$r}'
    ;;

  event)
    [ $# -eq 3 ] || refuse "usage: state.sh event <level> <event> <msg>"
    case "$2" in (*[!a-z_]*|'') refuse "event names are lower_snake_case";; esac
    logev "$1" "$2" "$(printf '%s' "$3" | cut -c1-200)"
    out '{"logged":true}'
    ;;

  *) refuse "unknown command: ${CMD:-<none>} (due|record|sweep-done|inbox-seen|inbox|event)";;
esac
exit 0
