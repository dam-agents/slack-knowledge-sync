# Monitor — the agent's health alerts

Read on every **monitor run** (the `slack-knowledge-sync-monitor-hourly` schedule). The
sweep decides work only; every health alert is the monitor's.
`scripts/precheck.sh monitor` runs `scripts/monitor.sh` once per fire: local files only —
the events log, the ledger, the harness settings — no external call, no write beyond its
own ledger and log. An idle fire starts no session. The audit's and the verifier's timed
probes (`LOG_RUN_ID=probe-…`) claim nothing and are invisible to every condition.

## The alerts

| Kind | Condition | Clears when |
| --- | --- | --- |
| `model_unavailable` | `model_alert_threshold` (missing = `2`; `0`/`off` disables) runs ended on an availability-class `api_failure` in one outage — failures under 60 min apart | — (one alert per outage) |
| `model_recovered` | the outage is over and its `model_unavailable` went out while it was open | — (once per outage) |
| `classifier_spike` | `classifier_alert_threshold` (missing = `20`) `classifier_block` events in 24 h | — (once per UTC day) |
| `heartbeat_gap` | the sweep is on and no sweep gate tick for `heartbeat_gap_min` (missing = `2160`, 1.5 days) | the gate ticks again |
| `backup_failing` | a backup error no later push cleared for 6 h (only with `GITHUB_REPO_WORK`) | the next push |
| `harness_drift` | `install.sh --check` names a part that is not current — **the Slack write wall may be down** | the check prints nothing |
| `slack_unavailable` | `slack_alert_threshold` (missing = `3`) `slack_read_failed` events in 24 h with no capture after the last | a capture succeeds |
| `sweep_stalled` | a sweep's gate opened and no `sweep-done` followed within `sweep_stall_min` (missing = `360`) | the next sweep finishes |

**The ledger** — `work/MONITOR.json`: an `alerts_due` entry is claimed when emitted and
due again 30 min later until `monitor.sh ack <id>…` records it as sent, so a session that
died before its ack loses nothing. A sent alert is never emitted again (`suppressed`); a
condition that clears leaves the ledger, so its return alerts again.

## Monitor run

1. Read the worklist. Each `alerts_due` entry carries its `id`, its `kind` and the facts
   of its row above.
2. Send **one message** for the whole run to `owner_dm_chat_id`
   (`mcp__platform-outbound__send_channel_message`) and the chat UI: one line per alert —
   what happened, when (UTC), the numbers, the likely cause and the one owner action:
   - `model_unavailable` / `model_recovered` — first and last failure, runs lost, the
     classes (`server_error`, `overloaded` → the provider; `authentication_failed` →
     credentials, owner-only). A missed sweep recovers on the next day by itself.
   - `classifier_spike` — the top patterns; a documented step of the agent is an
     auto-mode rule the harness adapter lacks.
   - `heartbeat_gap` — the sweep schedule is disabled, deleted or its gate cannot start
     (`mcp__platform-outbound__list_schedules`).
   - `backup_failing` — the sample error; [persistence.md](persistence.md).
   - `harness_drift` — re-run `bash "$HOME/scripts/harness/claude-code/install.sh"`,
     effective from the next session. Until then do no capture.
   - `slack_unavailable` — the Slack connection likely expired or was revoked: the owner
     reconnects it on the platform's Connections page.
   - `sweep_stalled` — when it started; the next sweep re-reads the window by itself.
3. **After the send**, `bash "$HOME/scripts/monitor.sh" ack <every id of alerts_due>`.
   A failed send is logged and not acknowledged: the next tick after the claim retries.
4. Back up `work/` when `$GITHUB_REPO_WORK` is set.

The monitor is a signal, not a repair: never clear a lock, re-run a sweep, change a
threshold, edit settings or retry a refused action in response.

## Self-check

- Every `alerts_due` entry is in the one message, and acknowledged after the send —
  never before, never on a failed send.
- The message went to the owner's DM only; nothing repaired, re-run or reconfigured.
