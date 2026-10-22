# Weekly audit

Read on the **audit run** (`slack-knowledge-sync-audit-weekly`, ungated). Read-only toward
every external system and repair-free: it reports; the owner decides. Its only local
writes are its `work/AUDIT.log` line and memory consolidation.

## Run

1. `bash "$HOME/scripts/preflight.sh" audit` → `checks[]`, `failures[]`, `stats`. A
   missing or non-JSON result → run the checks below by hand and say so in the report.
2. **Judgment checks** (each a `ok|warn|fail` line of its own):
   - **schedules** — `mcp__platform-outbound__list_schedules`: the three designed
     schedules exist with the kit's task text and precheck, the sweep at `sweep_time` in
     `timezone` and enabled iff `sweep_enabled: true`, `model` = `run_model` (none under
     `default`), each `lastRun` within 1.5× its interval and `lastResult` a success. An
     extra schedule of the owner's is `info`. Report drift; never change a schedule here.
   - **reports reached the owner** — the week's sweeps with `reported=no` in
     `work/SWEEP.log` and a still-non-empty `unreported` in `last_sweep.json` → warn.
   - **sample three captures** of the week (local: three notes touched; GitHub: three
     PRs): front matter in shape, each fact has its permalink, nothing from an excluded
     topic, no secret, no name the thread did not use, the PR marker present. A sensitive
     slip is **fail** — name the note path only, remove the passage, record the lesson.
   - **skipped-sensitive share** — 0% over a busy week, or above 50%, is a warn: read two
     skipped threads' ledger ids against Slack and judge whether the exclusion is too
     loose or too tight. Report the counts, never the content.
   - **harness** — `checks[harness]` warn → the Slack write wall may be down; that is
     **Action needed**, not a footnote.
3. **Failure diagnosis** — per `failures[]` signature: cause and fix, classed
   *environment* (a verified cause goes to `work/LESSONS.md`), *agent mistake*, or
   *definition bug* (**Definition bugs** below).
4. **Memory consolidation** — merge duplicate entries of `work/MEMORY.md`, drop the
   stale, keep it under 60 lines and 200 characters per line; owner-stated entries are
   never dropped. One line in the report.
5. Send the report, append
   `<ISO> ok=<n> warn=<n> red=<n> sent=<dm|chat>` to `work/AUDIT.log`, persist `work/`.

## Report

Always sent, green or not, to `owner_dm_chat_id` (and the chat UI):

```
Slack Knowledge Base weekly audit — <date> · <n> ok · <n> warn · <n> fail
Week: <threads> threads · <captured> captured · <skipped> skipped · <failed> failed · <sweeps> sweeps
Checks: <one line per fail and warn, never summarised away>
Action needed: <one line per item only the owner can do, or "none">
```

Counts, check ids, note paths — no captured content. A failed send → the full report in
the chat UI, `sent=chat`.

## Definition bugs

Under `definition_issues: enabled` only, and only through the script:

```bash
bash "$HOME/scripts/definition-issue.sh" file "<title>" /tmp/slack-knowledge-sync-issue/body.md
```

Content is a closed list: which definition file and section fails, the symptom in general
words, a synthetic reproduction with placeholders (`alice`, `U0123ABCD`, `acme/widgets`),
the count and window, the proposed fix. A `blocked` outcome → rewrite once in more general
words; a second `blocked` withholds it and the report says "issue withheld". Off →
the finding stays in the report.
