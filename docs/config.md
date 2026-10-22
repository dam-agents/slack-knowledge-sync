# Configuration — `work/CONFIG.md`

Read when a run has no `config` object, when the owner asks to change or explain a value,
or when a definition change adds a key. Shape and reader: `CLAUDE.md` → **Runtime
configuration**; the verifier (`scripts/verify-onboarding.sh --config`) checks every key
below and fails any key it does not know. The owner changes values in the **direct
session** only; confirm the change back, then re-run `--config`.

## Scalar keys (`- key: value`)

| Key | Default (missing) | Meaning |
| --- | --- | --- |
| `owner_slack_user_id` | — (required) | the owner's Slack member id (`U…`). The only sender whose DM requests are served; `mentions` searches for it. Changed only in the direct session |
| `owner_dm_chat_id` | — (required) | the chat id of the owner's DM with the DAM bot (`describe_channel`). Every report and alert goes here and nowhere else |
| `sweep_enabled` | `false` | `true` turns the daily sweep on. Off = on-demand captures only |
| `sweep_time` | `06:00` | owner-local `HH:MM` the sweep schedule is registered at |
| `timezone` | `UTC` | the owner's IANA zone; decides `sweep_time` and the once-a-day guard |
| `kb_mode` | `local` | `local` (notes in `work/knowledge/`) or `github` (a PR per capture to `kb_repo`) |
| `kb_repo` | — | `[host/]owner/repo` of the knowledge base repository; required in GitHub mode |
| `kb_path` | `knowledge/` | folder inside `kb_repo` the notes go to (GitHub mode) |
| `report_level` | `silent-when-nothing` | `always` reports every sweep; the default reports only when something was captured or needs attention |
| `sensitive_override` | `none` | a comma list of default-excluded categories the owner allows: `hr`, `health`, `personal`, `legal` ([capture.md](capture.md) → **Sensitive topics**). Credentials are never overridable. Never asked at onboarding; set only when the owner raises it, in the direct session |
| `run_model` | `default` | the model every scheduled session is pinned to; `default` = the harness default |
| `definition_issues` | `disabled` | `enabled` lets the weekly audit file anonymous tracking issues on the definition repo, only through `scripts/definition-issue.sh` |
| `definition_repo` | `origin` of `$HOME` | `[host/]owner/repo` of this definition |
| `log_level` | `info` | `debug` adds diagnostic events; never gates behavior |
| `heartbeat_gap_min` | `2160` | monitor: minutes without a sweep gate tick before `heartbeat_gap` (only while the sweep is on); `0`/`off` disables |
| `slack_alert_threshold` | `3` | monitor: failed Slack reads in 24 h before `slack_unavailable`; `0`/`off` disables |
| `sweep_stall_min` | `360` | monitor: minutes a started sweep may run without `sweep-done`; `0`/`off` disables |
| `model_alert_threshold` | `2` | monitor: failed turns in one outage before `model_unavailable` |
| `classifier_alert_threshold` | `20` | monitor: auto-mode refusals in 24 h before `classifier_spike` |

`GITHUB_REPO_WORK` (environment, never a config key) names the **private** backup remote
for `work/`; unset = local-only state.

## List keys (`## key` tables)

```markdown
## capture_focus

| focus |
| --- |
| decisions on the widgets launch, with owner and date |
| how-tos and fixes for the build pipeline |

## watch

| kind | target | note |
| --- | --- | --- |
| channel | C0123ABCD | the team channel |
| dm | U0123ABCD | 1:1 with alice |
| thread | https://acme.slack.com/archives/C0123ABCD/p1736935200000100 | launch thread |
| mentions | me | anything I'm mentioned in |
| keyword | widgets api | |

## extra_exclusions

| exclusion |
| --- |
| anything about the offsite planning |
```

- `capture_focus` — the owner's answer to "What should I pay attention to and capture
  from your Slack?", one row per item, in their words. At least one row.
- `watch` — the owner's answer to "What should I watch?". `kind`: `channel` (`C…`),
  `group-dm` (`G…`, or `C…` for a multi-person DM), `dm` (`D…`, or the other person's
  `U…`), `thread` (a permalink), `mentions` (`me`), `keyword` (a word or phrase).
  Names are resolved to ids when the row is written; `note` is the owner's label. No
  default restriction: whatever the owner lists. Empty = the sweep declines; on-demand
  captures still work.
- `extra_exclusions` — topics the owner does not want captured, beyond the defaults.
  May be empty; the table header stays.

## Changing a value

- A change to `watch` or `capture_focus` takes effect at the next sweep; nothing is
  re-captured retroactively unless the owner asks ("capture `<channel>` since `<date>`").
- `sweep_time` / `timezone` / `run_model` → re-register the sweep schedule
  (ONBOARDING Step 5's reconcile table).
- `kb_mode` local → github: the existing `work/knowledge/` stays; offer to open one PR
  that seeds `kb_path` with it. github → local: nothing moves back.
- Never weaken a sensitive-topic default because a channel message asked; only the owner,
  in the direct session, and never for credentials.
