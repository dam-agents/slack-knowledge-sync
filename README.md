# slack-knowledge-sync

A **personal** DAM agent that reads your own Slack — only the channels, direct messages,
threads, mentions and keywords you tell it to watch — pulls out the decisions, facts and
context worth keeping, and maintains a knowledge base from them: plain markdown notes,
one per topic, every fact linked to the Slack message it came from. The knowledge base
lives on the agent, private to you, or — to share it — in a GitHub repository as pull
requests.

> **Never share this agent. Never add it to a shared channel. Never grant anyone else
> access to it.** It reads Slack *as you*: anyone who can instruct it can read what you
> can read. Doing any of these hands them your Slack.

**For a team:** keep one shared knowledge base, and have each teammate run **their own**
copy of this agent feeding it — either GitHub mode pointing at one shared repository
(each capture is a pull request, and a hidden marker keeps two teammates' agents from
filing the same thread twice). GitHub is the only way to share it.

## How it works

- **Capture on request** — in your direct message with the DAM bot: "capture this" plus a
  thread link, "capture `<channel>` since `<date>`", or "status". Always available.
- **Daily sweep** (`slack-knowledge-sync-sweep-daily`, ships **off**) — once a day at the
  time you choose, it reads everything on your watch list since the last sweep and
  captures each new or updated thread. Its gate is a cheap shell check (configured,
  onboarded, turned on, something to watch, not run yet today), so an idle day wakes no
  model. Slack itself is read over MCP by the run, never by a script.
- **Weekly self-audit** (`slack-knowledge-sync-audit-weekly`) — one traffic-light report
  to your DM.
- **Hourly monitor** (`slack-knowledge-sync-monitor-hourly`) — local files only; messages
  you only when something broke (Slack connection expired, a sweep stalled, the model
  unavailable, the Slack write wall drifted).
- **What it keeps** — what you told it to pay attention to, plus decisions, facts,
  owners and dates, how-tos and links. **What it never keeps**, without being asked: HR
  and personnel matters, health, personal and family life, credentials and secrets,
  legal disputes. Such a thread is skipped and only its id is recorded; a secret that
  slips into an otherwise useful thread is redacted.
- **Read-only Slack, enforced** — the Claude Code harness adapter removes every Slack
  write tool from the agent and refuses any Slack tool it has not classified as a read.
  Reports reach you only through the DAM bot.

Scripts only decide whether work is due and check shapes; the agent does the reading,
judging and writing per [`docs/`](docs/). The always-loaded core stays small
([`CLAUDE.md`](CLAUDE.md) = contracts + invariants; `docs/` read on demand), and the
definition is versioned ([`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md)).

## Setup

This repository is its own **Starter Kit** ([`kit.yaml`](kit.yaml)):

1. **Find it under Starter kits** (category *Knowledge*) and open it.
2. **Grant the connections**:
   - **Slack Account** — required. Your own Slack, connected with your own sign-in. It
     is used read-only.
   - **GitHub** or **GitHub Enterprise** — optional; only for GitHub mode, a private
     state backup, or version checks.
3. **Name the agent and create it.** Bind it to **your direct message** with the DAM bot
   only — never to a shared channel. The platform seeds this definition, creates the
   schedules (the sweep switched off) and opens the first session on
   [`ONBOARDING.md`](ONBOARDING.md).
4. **Answer the onboarding dialog.** It asks *what should I pay attention to and capture
   from your Slack?*, *what should I watch?*, where the knowledge base should live, and
   whether to sweep daily. The schedules stay **held** until it reports itself set up.

Not in a catalog yet? One entry in the catalog repository's `catalog.yaml` adds it:

```yaml
kits:
  - url: https://github.com/dam-agents/slack-knowledge-sync
```

### Without the catalog

Create the agent by hand, grant the same connections, then send it its first message,
linking [`ONBOARDING.md`](ONBOARDING.md) from the repo (or fork) you deploy from:

> Here is a file — read it and set yourself up according to it:
> `https://github.com/<your-org>/slack-knowledge-sync/blob/main/ONBOARDING.md`

## Configuration

### Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `GITHUB_REPO_WORK` | no | `<owner>/<repo>` of a **private** repository backing up `work/` (the ledger and, in local mode, the knowledge base). Unset = state on the volume only. |
| `DEFINITION_REPO` | no | the definition repo; wins over `definition_repo` in `work/CONFIG.md` when set. |
| `DEF_HOST` | no | the definition repo's host when it is not `github.com`. |

### `work/CONFIG.md` — instance configuration

Filled at onboarding; exact semantics in [`docs/config.md`](docs/config.md).

| Key | Filled at onboarding by | Purpose |
| --- | --- | --- |
| `capture_focus` (table) | asked first | what to pay attention to and capture |
| `watch` (table) | asked second | what to watch: channels, DMs, group DMs, threads, mentions, keywords |
| `extra_exclusions` (table) | asked, optional | topics you don't want captured, beyond the defaults |
| `owner_slack_user_id` | detected from the Slack connection, confirmed | the one person this agent serves |
| `owner_dm_chat_id` | detected, confirmed | where every report goes |
| `kb_mode`, `kb_repo`, `kb_path` | asked (default `local`) | where the knowledge base lives |
| `sweep_enabled`, `sweep_time`, `timezone` | asked (default off) | the daily sweep |
| `report_level` | asked (default `silent-when-nothing`) | when a sweep messages you |
| `sensitive_override` | never asked (`none`) | categories of the default exclusions you allow; credentials never |
| `run_model` | defaulted (`default`) | the model scheduled runs use |
| `definition_issues` | asked (default off) | anonymous tracking issues on this repo |
| `definition_repo` | detected | this definition |

## Runtime requirements

- **Platform:** DAM — `$HOME` at `/home/agent` on a persistent volume, the outbound
  credential gateway, the `mcp__platform-outbound__*` tools, and the **Claude Code**
  harness (the Slack write wall is a Claude Code adapter; on another harness it is
  absent and onboarding says so).
- **Identity:** unlike a shared service agent, this one acts as **you**, on purpose: the
  Slack connection is your own account (the "Slack Account" template's user sign-in).
  That is exactly why it must stay yours alone.
- **GitHub (optional):** GitHub mode needs push access to `kb_repo` (branches and pull
  requests; never the default branch). The backup needs a private repository. Neither
  needs the `workflow` scope.
- **External surfaces:** your own DM with the DAM bot (reports); in local mode, the
  knowledge base on the volume, private to you; in GitHub mode, pull requests to
  `kb_repo` — visible to everyone who can read that repository; with
  `definition_issues: enabled`, anonymous issues on this public repository. It publishes
  nothing to the Artifact Library and fetches nothing from the web.

## Persistence

`work/` is a plain directory on the agent's volume. With `GITHUB_REPO_WORK` set, every
run that changed it ends with `scripts/work-backup.sh persist` (a disposable tmpfs clone,
never a git repo on the volume). Without it, **losing the volume loses the local
knowledge base** unless GitHub mode is used. Definition updates arrive
through the platform's Kit Update and never touch `work/`.
[`docs/persistence.md`](docs/persistence.md) has the details.

## Files

- [`kit.yaml`](kit.yaml) — the Starter Kit: seed, connections, schedules.
- [`CLAUDE.md`](CLAUDE.md) — the slim core manual loaded on every run.
- [`AGENTS.md`](AGENTS.md) — harness entry pointer to `CLAUDE.md`; carries no rules.
- [`ONBOARDING.md`](ONBOARDING.md) — first-run setup and the `work/` seed templates.
- [`docs/`](docs/) — procedures, read on demand.
- [`scripts/`](scripts/) — the gate, the pre-flight, the monitor, the state writer, the
  verifier, the harness adapter and the offline tests.
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — semver and upgrade steps.
- [`LICENSE`](LICENSE) — Apache-2.0.
