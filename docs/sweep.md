# Sweep — the daily capture run

Read on a **sweep run** (the `slack-knowledge-sync-sweep-daily` schedule, or the owner
asking for a sweep now in the direct session). Each thread is handled per
[capture.md](capture.md); this file is only the order of the run.

## The gate

`scripts/precheck.sh sweep` runs `scripts/preflight.sh sweep` before any model wakes. It
reads **local files only** — Slack is MCP-only and a shell cannot call it — and declines
the fire when any of these holds:

| Declined when | Why |
| --- | --- |
| `work/CONFIG.md` missing | not configured |
| no `$HOME/.slack-knowledge-sync-onboarded` | onboarding not finished |
| `sweep_enabled` is not `true` | the owner keeps the agent on-demand |
| the `watch` table is empty | nothing to sweep |
| `work/state/last_sweep.json` has today's owner-local day | already swept today |

A file that exists but cannot be read, a missing `owner_slack_user_id` or an unknown
`timezone` is an **error**, not a decline: the gate fails open, the run starts and reports
it. So "the sweep found nothing" and "the sweep could not look" never look alike.

The cron fires once a day at the platform default (`0 6 * * *` UTC); ONBOARDING
re-registers it at `sweep_time` in `timezone`. The once-a-day guard is the owner-local
day, so a re-registered or manually started sweep never runs twice in one day.

## Worklist

| Key | Holds |
| --- | --- |
| `now` / `since` | the window: from the last finished sweep's `window_end` (first sweep: 24 h back; capped at 14 days, `window_capped: true`) to now, UTC |
| `watch` | the targets: `{kind, target, note}` per row of the `watch` table |
| `unreported` | counts and permalinks a previous sweep could not deliver to the owner |
| `config` | every key resolved |

## Run

1. Rename the session to `title`; echo `logs`.
2. Per watch target, list what changed in the window, with read tools only:

   | `kind` | Read |
   | --- | --- |
   | `channel`, `group-dm`, `dm` | `slack_read_channel` with `oldest` = `since` as a Slack ts; every message with replies is a thread, every reply newer than `since` puts its parent thread in scope |
   | `thread` | `slack_read_thread` on the permalink's thread |
   | `mentions` | `slack_search_public_and_private` with `<@owner_slack_user_id>` and `after:` the window's first day |
   | `keyword` | `slack_search_public_and_private` with the keyword and `after:` the window's first day |

   Collect thread ids, deduplicated across targets (one thread can match several). Page
   until the window is covered; stop a target at 200 threads and say so in the report.
   A failed listing → `scripts/state.sh event error slack_read_failed "<kind> <target>"`
   and continue with the next target; never read it as an empty target.
3. Per thread, in order of `latest_ts`: [capture.md](capture.md) → **Per-thread sequence**.
4. Report (below), then close the sweep:
   `bash "$HOME/scripts/state.sh" sweep-done --started <now> --since <since> --captured N --skipped N --failed N --reported yes|no [--notes <permalinks>]`.
   `--started` is the worklist's `now`: the next window opens there, so nothing posted
   during the run is missed. A sweep that ends without `sweep-done` is re-read in full
   by the next one (duplicates are harmless; the ledger skips what is handled) and the
   monitor raises `sweep_stalled`.
5. Persist `work/` when `$GITHUB_REPO_WORK` is set.

## Report

`report_level: silent-when-nothing` (default): message the owner only when the sweep
captured something, failed something, skipped a credential, hit a cap, or `unreported`
is non-empty. `always`: message after every sweep.

One message, to `owner_dm_chat_id`, via `mcp__platform-outbound__send_channel_message`:

```
Slack knowledge sweep — <local date>
• Captured <n> thread(s) into <m> note(s): <note paths, at most 10>
• Skipped <k> (excluded topics or noise) · <f> failed, retried tomorrow
• <one line per problem: a failed target, a cap, a credential to rotate (permalink only)>
```

Counts, note paths and permalinks only — no summary of a thread's content, nothing about
a skipped one. Send, then `sweep-done --reported yes`; a failed send → `--reported no`
with the permalinks in `--notes`, so the next sweep carries them (send-then-record).

## Self-check

- Every target was listed or has a `slack_read_failed` event; every thread found is in
  the ledger or has one.
- `sweep-done` was called exactly once, with the worklist's `now`.
- The report went to the owner's DM only, and carries no thread content.
