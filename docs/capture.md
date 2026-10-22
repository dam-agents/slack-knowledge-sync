# Capture — one thread into the knowledge base

Read for every thread a sweep or a request brings, and for every request from the owner.
The unit is one Slack **thread**: id `<channel_id>:<thread_ts>`, where a lone message's
`thread_ts` is its own `ts`. Its version is `latest_ts`, the `ts` of its newest reply.

## Per-thread sequence

1. **Due?** `bash "$HOME/scripts/state.sh" due <id> <latest_ts>`. `due: false` → skip
   silently, nothing to record. An `error` → stop on this thread, report it.
2. **Read the whole thread** — `mcp__slack__slack_read_thread` (channel id, thread ts);
   a lone message needs no second read. Page until the end. A failed or partial read →
   `scripts/state.sh event error slack_read_failed "<id> <tool>"`, record nothing, go to
   the next thread. Never capture from a partial read.
3. **Sensitive?** Apply **Sensitive topics** before anything else. A hit → record
   `skipped-sensitive` with no paths, keep nothing from the thread in memory or notes,
   move on.
4. **Worth keeping?** Apply **What to keep**. Nothing qualifies → record `skipped-noise`.
5. **Write or merge** the notes (**Writing notes**), or open the PR in GitHub mode
   (**GitHub mode**).
6. **Record** — `scripts/state.sh record <id> <latest_ts> captured <path>…` with every
   knowledge base path touched (GitHub mode: the PR URL). A write that failed →
   `record … failed`; the next sweep retries it.

Record ordering per effect: a local note is **write, then record** (a rewrite by note path
is idempotent, so a crash in between costs one harmless re-merge); a PR is **search the
marker, open, then record** (the marker makes a re-run find the PR it already opened).

## Reading Slack

- Read tools only, as listed `read` in `scripts/harness/claude-code/slack-tools.txt`. Any
  other Slack tool is refused by the harness; never look for a way around it.
- Resolve a name the owner gave (a channel, a person) with `slack_search_channels` /
  `slack_search_users` once, at configuration time; the watch list stores ids.
- `slack_read_user_profile` only to turn a member id into the display name the thread
  already shows; never to collect more about a person.
- A file or canvas linked in a thread is read only when the thread's point depends on it
  and it is in the owner's own workspace; its content obeys the same rules as messages.
- **Links are recorded, never fetched.** Web tools are denied: a fetch or a search would
  carry private context off the pod.

## Sensitive topics

Always on, never asked about. A thread is **skipped whole** when its substance is any of:

| Category (`sensitive_override` name) | Covers |
| --- | --- |
| `hr` | performance, compensation, promotions, hiring and firing decisions about named people, complaints, disciplinary matters, personnel files, reorganisations before they are announced |
| `health` | anyone's health, medical leave, disability, mental health |
| `personal` | family, relationships, home life, personal finances, anything a person shares about their private life |
| `legal` | legal disputes, litigation, investigations, legal advice |
| credentials *(never overridable)* | passwords, tokens, keys, recovery codes, private URLs carrying a secret |

- **Substance, not mention.** "Alice is out sick, the release slips to Friday" → keep the
  date, drop the reason. A thread *about* someone's leave or pay → skip it.
- **When unsure, skip.** A wrong skip loses a note the owner can ask for again; a wrong
  capture stores something that should never have been written.
- `sensitive_override` names categories the owner chose, in the direct session, to allow
  (e.g. `hr` for an HR team's own policies). It allows the category's *process and
  policy* knowledge, never one person's private matter. Credentials can never be allowed.
- `extra_exclusions` adds the owner's own topics; treat each like a category above.
- A skipped thread leaves **only its id** in the ledger: no path, no summary, no reason
  text, no log line beyond the outcome.
- **Secrets inside a capturable thread** are redacted — `[redacted credential]` — never
  written, then the thread is captured normally. Tell the owner in the run's report, by
  thread permalink only, that a credential was posted in Slack and should be rotated.

## What to keep

Keep what someone would look for later; leave the conversation behind.

- **Decisions** — what was decided, by whom (the role or name *as the thread states
  it*), when, and what it replaces.
- **Facts** — numbers, limits, dates, owners, deadlines, versions, names of systems.
- **How-tos** — steps that worked, commands, the fix for a recurring problem.
- **Links** — the doc, issue, dashboard or design the thread points at, with one line on
  what it is.
- **Open questions** — only when the thread ends on one that matters; mark them open.
- Weight by `capture_focus`: a topic or kind the owner named is kept even when small; a
  thread outside every focus item is kept only if it holds a decision or a fact a
  colleague would need.

Never keep: greetings, thanks, reactions, scheduling chatter, jokes, status pings with no
content, opinions with no decision, and anything already recorded word for word.

## Writing notes

Local mode writes under `work/knowledge/`; GitHub mode writes the same files under
`kb_path` in a clone of `kb_repo`.

- **One note per topic**, `<topic-slug>.md` in lowercase-hyphen form (`release-process.md`,
  `widgets-api-limits.md`); a sub-folder only when one topic outgrows a note. Search the
  existing notes (`grep -ril`) before creating one: merge into the note that already
  covers the topic.
- **Merge, don't append.** A new decision that replaces an old one rewrites the
  statement and keeps the old one as "Previously: …, until <date>". Contradictions stay
  visible; nothing is silently overwritten.
- **Note format:**

  ```markdown
  ---
  title: Release process
  updated: 2026-01-15
  sources:
    - https://acme.slack.com/archives/C0123ABCD/p1736935200000100
  ---
  # Release process

  - Releases are cut every second Wednesday; the release owner rotates weekly. ([source](https://acme.slack.com/archives/C0123ABCD/p1736935200000100))
  - Previously: monthly releases, until 2026-01-15.
  ```

  `updated:` is the UTC date of this write; `sources:` lists every permalink the note
  draws on. Each fact links its permalink inline. Plain language, short bullets.
- **Attribute sparingly.** A decision names the person or role only as the thread does;
  never add a name the thread did not use. Quote at most one short sentence, only when
  the exact words matter.
- **Index** — `index.md` lists every note with one line each; update it with the note.
- **Source log** — append one line per captured thread to `sources/<YYYY-MM>.md`:
  `- <UTC date> <permalink> → <note paths>`. No content, no names.
- **Usage guide** — `USAGE_GUIDE.md` (seeded at onboarding) tells a reader of the shared
  knowledge base what it covers and how it is laid out; update its topic list when a new
  top-level topic appears. It never names the owner's channels or people.
- Permalinks: `https://<workspace>.slack.com/archives/<channel_id>/p<ts without the dot>`
  (add `?thread_ts=<thread_ts>&cid=<channel_id>` for a reply).

## GitHub mode

`kb_mode: github`. Each captured thread is **one branch and one pull request** to
`kb_repo`; the agent never pushes to the default branch and never merges.

1. Resolve the host: `kb_repo` is `[host/]owner/repo`, bare = `github.com`; pass the host
   on every call (`gh pr -R <host>/<owner>/<repo>`, `gh api --hostname <host>`).
2. **Marker search first**, open and closed:
   `gh pr list -R <repo> --state all --search "slack-knowledge-sync: <id>" --json number,url,state,body --limit 20`.
   A PR whose body carries the marker for this id with the same `latest_ts` → record
   `captured <url>` and stop. One with an older `latest_ts` that is still **open** →
   update that PR (push to its branch) instead of opening a second. A closed or merged
   one → a new PR for the new replies only. A failed search → record nothing, report it;
   never treat a failed search as "no PR".
3. Clone shallow into `/tmp/slack-knowledge-sync-<thread_ts>/`, branch
   `capture/<channel_id>-<thread_ts>`, write the notes under `kb_path` per **Writing
   notes**, commit as the owner's GitHub account, push the branch.
4. `gh pr create` with a title `Capture: <topic>` and a body of: the notes touched, one
   line per fact with its permalink, and as its last line the marker
   `<!-- slack-knowledge-sync: <channel_id>:<thread_ts>:<latest_ts> -->`.
5. Record `captured <pr-url>`; delete the scratch clone.

Two teammates' agents feeding one repo stay out of each other's way through the marker:
the second one finds the first one's PR and records it as captured.

## Requests from the owner

Served only when the platform says the sender is `owner_slack_user_id`, in the owner's DM
with the bot or the direct session. First `scripts/state.sh inbox-seen <msg_ts>`; `seen`
→ do nothing.

| Request | Do |
| --- | --- |
| **capture this** + a thread permalink | parse channel id and thread ts from the link; run the per-thread sequence with the owner's request as the reason to look (a `due: false` thread is re-read and merged when the owner asks again); reply with the notes touched |
| **capture `<channel>` since `<date>`** | the channel must be one the owner names now; read its history since that date (cap: 14 days back, 200 threads — say so when capped), run the per-thread sequence on each |
| **status** | last sweep (`work/state/last_sweep.json`), counts of the last 7 days from the ledger, the watch list size; no content |
| anything else | one line: what this agent can do here, and that settings change in the direct session |

Reply **once**, in the same DM thread (`mcp__platform-outbound__reply`), then
`scripts/state.sh inbox <msg_ts> <capture-thread|capture-channel|status|declined>`
(send-then-record). The reply names note paths and counts; it may quote nothing from a
skipped-sensitive thread, not even that it was sensitive beyond "skipped (excluded topic)".

## Self-check (before the run ends)

- Every due thread has exactly one new ledger row, or a `slack_read_failed` event.
- No `skipped-sensitive` row has a path; no note quotes an excluded topic.
- `bash "$HOME/scripts/kb-check.sh"` (local mode) reports no `fail` for the notes touched.
- No Slack write was attempted; nothing was fetched from the web.
- No `/tmp/slack-knowledge-sync-*` left behind.
