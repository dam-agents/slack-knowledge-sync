# Logging & the harness adapter

Read when writing a log line by hand, when diagnosing a failure, or when touching the
harness adapter.

## Logs

- **Run logs** (append-only, one line per run): `work/SWEEP.log`
  (`<ISO> sweep due …` from the gate, `<ISO> sweep captured=N skipped=N failed=N
  reported=yes|no` from `state.sh sweep-done`), `work/AUDIT.log`, `work/MONITOR.log`.
- **Events log** `work/logs/events-YYYY-MM-DD.jsonl`, written through `scripts/log.sh`
  (`logev <level> <event> <msg>`), one JSON line
  `{ts, run, job, level, event, msg}`. Secret shapes are masked before the write;
  `debug` lines only under `log_level: debug`; files older than 14 days are deleted by
  the audit pre-flight.
- **Content rule:** a log line carries ids, counts, tool names, outcomes and classes —
  **never** message text, a note's content, a person's name or a channel name. A thread
  is named by its id only.

## Parsed events

The monitor and the audit read these; their shape is a contract.

| Event | Writer | `msg` |
| --- | --- | --- |
| `precheck` | `precheck.sh` | `<mode> gate: work due — …` / `nothing to do …` / an error |
| `preflight` | `preflight.sh` | `<mode>: not due — <reason>` / `sweep due watch=<n>` |
| `capture` | `state.sh record` | `<id> outcome=<outcome> paths=<n>` |
| `sweep_done` | `state.sh sweep-done` | `captured=<n> skipped=<n> failed=<n> reported=<yes\|no>` |
| `slack_read_failed` | the agent (`state.sh event`) and the failure hook | `<id or kind target> <tool>` / `<tool>: <error>` |
| `tool_failure` | the failure hook | `<tool> [<command>]: <error>` (inspect commands excluded) |
| `classifier_block` | the failure hook | `<tool> — <reason>` |
| `api_failure` | the failure hook | `<class>: …` |
| `slack_write_blocked` | `guard.sh` | `<tool> — <reason>` |
| `definition_issue` | `definition-issue.sh`, `guard.sh` | `filed` / `blocked: <categories>` / `guard blocked …` |
| `work_backup` | `work-backup.sh` | `pushed …` / errors |

## Harness adapter

`scripts/harness/claude-code/`, installed per instance by `install.sh` (ONBOARDING Step
1b and after an update that changes it; effective from the next session). `install.sh
--check` prints the parts not current; the monitor alerts on it, the audit reports it.

- **`slack-tools.txt`** — every tool of the `slack` MCP server classified `read` or
  `write`. The single source of truth for Slack access.
- **`denied-tools.txt` → `permissions.deny`** — every Slack `write` tool (removed from
  every session's tool list), plus tools no procedure calls (the Artifact Library,
  sub-agents, web fetch and search).
- **`guard.sh` (PreToolUse, `mcp__slack__.*|Bash`)** — allows a Slack tool only when
  `slack-tools.txt` says `read`, so a tool Slack adds later is blocked until classified;
  refuses a shell command reaching Slack's API directly; refuses any GitHub issue write
  that does not go through `scripts/definition-issue.sh`.
- **`log-tool-event.sh`** — `PostToolUseFailure`, `PermissionDenied`, `StopFailure` →
  the events above. Record only; never asks the harness to retry.
- **Auto-mode rules** tagged `[slack-knowledge-sync]` for the documented writes: notes
  under `work/knowledge/`, the scripts, the backup, GitHub-mode PRs, the owner DM.
- `scripts/tests/test_slack_readonly.sh` keeps the three files in step; a new Slack tool
  is classified in the same PR that lets the agent use it.

On any other harness the adapter installs nothing, and **the Slack write wall is
absent**: onboarding tells the owner, and the definition only claims read-only Slack on
Claude Code.
