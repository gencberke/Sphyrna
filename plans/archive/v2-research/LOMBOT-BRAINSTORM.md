# Lombot: the Home assistant (brainstorm)

**Date:** 18 Oct 2026 · **Kind:** design brainstorm with the user, held in its own session · **State:** the user's choices are recorded in [§9](#9-the-users-choices-18-oct). Nothing is built. Lombot is not part of Release B ([D-63](../../DECISIONS.md)). DECISIONS.md, the [product contract](../../LOOM-PRODUCT-CONTRACT.md) and [V2-PLAN](../V2-PLAN.md) are unchanged; the planner records the decisions.

**Since then (21 Oct, D-83):** Lombot is Remora (D-77), built on the core track ([V2-PLAN §14](../V2-PLAN.md#14-toward-160)). Spike S10 (`~/Library/Caches/loom-v2/evidence/core/s10/S10-REPORT.md`) and L1a's probe (`~/Library/Caches/loom-v2/evidence/core/l1a/probe.md`) replace §4.2's flag table and §4.5's estimates. The call also needs `--setting-sources ""` and `USER` in its environment, and with prompt caching on it costs about twice §4.5's estimate, because the CLI writes its cache at the 1-hour tier. The brief runs with caching off.

**The user's ask (notes of 18 Oct, translated):**

- When they open Loom, especially for the first time in a day, Lombot tells them where they left off: "last you did X there; you can continue from Y".
- They can ask it questions such as "where did we leave off in project P, and what did we do last?". It scans the sessions and answers.
- It takes the place of Home's old start box ([D-63](../../DECISIONS.md)).
- It has its own Settings tab for its model, effort level and so on.
- Context management needs thought: a context that keeps growing is not useful.

In the brainstorm the user added three wishes:

- Lombot should know the current state and also keep some memory, so it feels like an assistant.
- It should be aware of itself and of the work it does.
- They asked whether Lombot could get its own place in their second-brain vault.

**Inputs:**

- [D-57 to D-63](../../DECISIONS.md) and the V05 Home row of [V2-PLAN §3](../V2-PLAN.md#3-releases-and-slices).
- The spikes:
  - [S9](../experiments/v2-spikes/S9-ask-mode-20261018.md), the Ask mode;
  - [S6](../experiments/v2-spikes/S6-fork-20261018.md), on `--no-session-persistence`;
  - [S1](../experiments/v2-spikes/S1-wire-20261017.md), on `--bare`.
- The bounded-digest idea [I-38](ideas/I-38.md).
- Contract §1, §7, §8 and §10.
- The v2 code at edff6e9, read only. Code paths below are under `Sources/` in `~/Library/Caches/loom-v2/wt/v2`.
- The vault's `AGENTS.md`, `Home.md` and `Projects.md`, read only.
- API list prices from the claude-api reference (cached 6 Oct 2026) and from Loom's `UsagePricing.swift` (dated 7 Oct).

`claude` was not run, and the real `~/.claude` and `~/.codex` were not read. The CLI facts below come from the spike records.

## Contents

- [0. Summary](#0-summary)
- [1. What Lombot answers](#1-what-lombot-answers)
- [2. Its sources](#2-its-sources)
- [3. Context and memory](#3-context-and-memory)
- [4. How it runs](#4-how-it-runs)
- [5. Privacy](#5-privacy)
- [6. The UI](#6-the-ui)
- [7. Before building: spike S10](#7-before-building-spike-s10)
- [8. Build shape](#8-build-shape)
- [9. The user's choices (18 Oct)](#9-the-users-choices-18-oct)
- [10. Risks](#10-risks)
- [11. Open points](#11-open-points)
- [12. Doc impact for the planner](#12-doc-impact-for-the-planner)
- [13. Findings outside Lombot](#13-findings-outside-lombot)

## 0. Summary

Lombot is a read-only assistant at the top of Home, where the start box used to be. It answers questions about the user's sessions. On the first Home view of the day it says where the user left off and what comes next.

- **Every call starts fresh.** Loom picks the sources and builds a bounded context pack, about 14k tokens at most. The model gets no tools, so "it only reads" holds by construction.
- **Memory comes in two parts** (the user's choice).
  - The **working memory** stays in Loom's data folder. It holds Lombot's own journal and one note per project. The notes are rewritten once a day and stay capped.
  - The **durable memory** is one note, `Lombot.md`, in the user's second-brain vault. It holds Lombot's identity, its rules and the facts the user confirmed. Lombot writes it only on an explicit "remember" or a confirmed proposal.
- **Self-awareness** comes from two things. Loom builds a self card for every call, and the journal lets Lombot know what it said before.
- **It runs as a one-shot `claude -p` child per call.** The call follows the plan-limit probe Loom already runs: no hooks, no MCP servers, no transcript.
  - Model: Sonnet 5.5 at low effort (the user's choice).
  - The CLI's non-essential traffic is off for Lombot's calls (the user's choice, [D-20](../../DECISIONS.md)).
- **It runs on a question, a click, or once a day when Home first shows.** There is no timer, watcher or background work.
- **Answers link to sessions.** Lombot can also put an unsent draft in a session's composer when the user clicks (the user's choice). It never sends, starts, stops or changes a session.
- **Before building,** spike S10 must check the call's shape on Claude Code 2.1.300 ([§7](#7-before-building-spike-s10)).

## 1. What Lombot answers

### 1.1 Example questions

| Question | What Lombot reads | The answer |
| --- | --- | --- |
| None: the first Home view of the day | Sessions with activity since the last recap, how their runs ended, the project notes, the journal | Two to four sentences: where each active project stands and what is next, with "Continue from" chips |
| "Where did we leave off in loom-dev, and what did we do last?" | loom-dev's last three sessions (catalog and transcript tails), its project note, its vault card if there is one | The last state, the open thread and the next step, each tied to a session chip |
| "What finished yesterday evening, and what is half done?" | Runs that ended since the evening, with their end reasons (Stop, Quit, a crash, done) | Two short lists, finished and half done, each item a chip |
| "Which session touched the auth middleware?" | The palette's transcript search (first-pass budget) | The sessions with the matching line and its date |
| "What is waiting on me, and why?" | Home's Needs you and Finished not read | Each waiting item with its reason |
| "What did you tell me yesterday?" | The journal | Yesterday's recap and answers, with what has changed since |
| "What do you remember about edd?" | `Lombot.md` and edd's project note | The remembered items with their dates, kept apart from what the current state says |
| "How much of my plan did you use today?" | Lombot's own counters | Calls and tokens today, and that they count toward the Claude plan |
| "Remember that the EDD release is on Friday" | Nothing | Saved to `Lombot.md`, with Undo ([§3.5](#35-how-memory-is-managed)) |

### 1.2 What it never does

- It never starts, stops, resumes, interrupts, renames or deletes a session.
- It never sends a message, and never answers an approval, question or plan card.
- It never reads or writes a file through the model, because the model has no tools. Loom reads the sources and writes the memory files.
- It never browses the web. It never reads:
  - Codex sessions (Codex is frozen, [D-28](../../DECISIONS.md));
  - the live terminal screen;
  - the git working tree.
- It never runs on a timer.

The user's clicks can cause two writes:

- an unsent draft in a session's composer ([§1.3](#13-session-links-and-drafts));
- a durable fact saved through an explicit "remember" or a confirmed proposal ([§3.5](#35-how-memory-is-managed)).

Opening a session from a chip is navigation, not a change.

### 1.3 Session links and drafts

The user chose "links and draft" over plain text and links alone.

- **Session chips.** A session named in an answer becomes a chip: the project's stripe, the title and an arrow. A click selects the session in Loom, like a click in the sidebar. It does not resume or send.
- **Put in draft.** A "Continue from" chip also offers "Put in draft". Loom opens the session and places Lombot's suggested line in the session's composer as an unsent draft, through the V17 draft store (`<data root>/chat-drafts`). An example line: "Continue from the acceptance run: start with the Quit check".
  - Only a Chat-face session with an empty composer gets the draft. Loom never overwrites a draft: if the composer has text, the line goes to the pasteboard, and Home says "Copied. <session> already has a draft."
  - A terminal-face session gets the line on the pasteboard only. Loom never types into a terminal.
  - While a pinned card waits in that session, the chip only opens the session.
  - The draft is shown in full on the chip's hover before it is placed. Nothing is ever sent; the user sends it with the composer's own ↵.

## 2. Its sources

| Source | What it gives Lombot | Where it lives | Read cost and bound | When Lombot reads it |
| --- | --- | --- | --- | --- |
| Session catalog | Title, project, folder, ticket, created, last activity, lifecycle, how each run ended (`runs.end_reason`: requested, idle, Quit, process exit), mode, model and effort | `<data root>/catalog.sqlite3` (`LoomCore/CatalogDatabase.swift`); `CatalogModel` holds the loaded rows | Memory, or one bounded query (pages of at most 100 rows). The catalog "never stores conversation content" (`SessionCatalog.swift:189`) | Every call, as the session index |
| Home's sections | Needs you with its reason line, Finished not read with Claude's last line, Today, Continue (runs cut by Quit), plan limits with pace | Memory (`CatalogModel+Home.swift`, `SessionEventHub`) | Free. The reason line and the unread flag are kept in memory only and are lost on relaunch | Every call |
| Transcript tails | For each picked session: the last turns' user and assistant text, tool calls cut to one line, files touched, the CLI's `last-prompt` and `ai-title` records | `<profile>/projects/<encoded cwd>/<id>.jsonl`; `ClaudeTranscriptReader.readBackward`, `TranscriptLens` | Bounded per session. The last-line read is at most 2 × 64 KiB. The lens's cold open is the last 10 user turns or 1.5 MiB (3 MiB at most). Reads run off the main actor | For the three to eight sessions a call needs |
| Transcript search | Keyword hits for "which session…" questions | The palette's scanner (`PaletteTranscriptSearch.swift`) | First pass: the last 14 days, 512 MiB, 2 s, 24 hits, 2 per session; cancellable | Only for a question that needs it |
| Project page data | Sessions with their last line, branches (from git, `BranchCache`), the project's CLAUDE.md (up to 32 KiB), the week's usage | `CatalogModel+ProjectPage.swift` | The page's own bounds, read on demand | Questions about one project |
| Usage index | Tokens per session and model | `<data root>/usage-index.sqlite3` | One indexed query, at most 500 sessions | Usage questions |
| Lombot's working memory | The journal and the project notes | `<data root>/lombot/` | Small files with fixed caps ([§3.5](#35-how-memory-is-managed)) | Every call, within the memory share |
| The vault | `Lombot.md`; the project card whose `repo:` path matches the project's folder (`projects/<id>/<id>.md`) | The second-brain vault | Two small files (cards stay under 8 KB by the vault's rule) | `Lombot.md` every call; the card for questions about its project |

`<data root>` is `~/Library/Application Support/Loom`, or `Loom-Dev` in dev builds (`BuildIdentity.swift:18`).

**Not read:** Codex sessions (nothing in v2 reads them), the live terminal screen, git diffs and the working tree, the vault's other notes (`Me.md` included), and the web.

**Gaps the build must close:**

- **No cheap first prompt.** Loom's readers go backward or search; none returns a session's first real prompt.
  - For a long session's goal, the order is: the CLI's `ai-title` record (if S10 shows it is stable), then the catalog title, then a new bounded forward read of the file's head.
  - `ai-title` and `last-prompt` are listed as silent records in `LoomChat/Model/TurnModel+Ingest.swift:12`.
- **Compaction summaries.** Loom keeps only the compaction marker (`ChatEntry.swift:211`); whether the summary record itself can be used is unknown (S10).
- **Memory-only status.** The reason line and the unread flag do not survive a relaunch. The morning recap therefore uses the catalog's run end reasons and the transcripts, not Home's in-memory reasons.

## 3. Context and memory

### 3.1 The problem

One long-lived Lombot conversation would grow with every question. Each call would cost more and take longer, and old facts would crowd out current ones. Lombot needs the current state on every call and enough continuity to feel like an assistant that remembers.

### 3.2 The three options compared

| | A. Fresh context per question, with retrieval | B. Small rolling daily digest | C. Per-project summaries, cached, invalidated when a transcript changes |
| --- | --- | --- | --- |
| How | Loom picks three to five sessions for the question, cuts bounded excerpts into a pack of about 10k tokens and makes one call. Nothing is remembered | Once a day a large call (about 50k tokens) writes a digest of the previous day and stores it. Questions read the digest and a few targeted excerpts | Each project keeps a model-written summary. When one of its transcripts grows, the summary is invalid and is rewritten at the next question |
| Cost per question (Sonnet 5.5) | About 10k tokens in, about 3 ¢ at list price | About 5k tokens, plus the daily call | About 3k tokens for an unchanged project; about 20k for a changed one (rewrite plus answer) |
| Latency | One call, streamed: about 3–6 s on Sonnet 5.5 low | Instant if the digest is ready; otherwise the digest call takes 10–20 s | About 3 s on a cache hit; two calls, 6–10 s, on a miss |
| Freshness | Always current, running sessions included | Goes stale during the day | Exact, but an active project is always invalid, so it falls back to A with extra work |
| What is stored | Nothing | A model-written copy | One model-written copy per project; a summary of a summary drifts over time |
| Complexity | Lowest | Medium | Highest |

The recommendation before the user's answer was A.

### 3.3 The user's direction

The user did not pick one option. They want the current state on every call, and some memory, so Lombot feels like an assistant. They also want Lombot aware of itself and of the work it does.

The design below keeps A for the current state and adds a bounded memory:

- It takes B's daily rhythm for writing memory.
- It takes C's per-project notes, but rewrites them from current sources once a day instead of invalidating them on every change.

### 3.4 The memory model

| Layer | What it holds | Who writes it, and when | Where | Bound |
| --- | --- | --- | --- | --- |
| Current state | The catalog, Home's sections, transcript tails, search hits | Loom reads them for each call and keeps nothing | Not stored | About 8–10k tokens per call |
| Working memory: journal | One line per call: the time, the question, the answer's first sentence, the sessions read, the model and the tokens. Plus the day's recap and a short summary of each day | Loom writes the lines mechanically, with no model call. The day summary comes from the daily update | `<data root>/lombot/journal/` | 14 days of daily files; older days fold into weekly summaries, kept 12 weeks |
| Working memory: project notes | Per project: its focus, open threads, last known state, next step, recent decisions. Each item is dated and cites its sessions | The daily update rewrites the notes of the projects that moved; notes are never appended to | `<data root>/lombot/projects/<project id>.md` | 2 KiB per note |
| Durable memory | Lombot's identity and rules (the user may edit them); how the user wants answers; facts the user confirmed, each dated and tagged with its project | Only an explicit "remember" or a confirmed proposal ([§3.5](#35-how-memory-is-managed)) | `Lombot.md`, in the vault in the user's install ([§3.6](#36-where-memory-lives)) | 8 KB (the vault's card limit) |
| Self card | What Lombot is, its sources, what it cannot see, its rules, its model and effort, today's calls and tokens, when the memory was last updated, the local date and time | Loom builds it for every call; the model never writes it | Not stored | About 0.5k tokens |

### 3.5 How memory is managed

**Writing**

- **Journal.** Loom appends one line per call, with no model call.
- **The daily update.** The morning call also updates the memory. It is one call:
  - The recap text comes first and streams in on Home.
  - A fenced JSON block follows, holding:
    - the previous day's summary;
    - the rewritten notes of the projects that moved;
    - up to three proposed facts.
  - Loom strips the block from the shown text, validates it and writes the files.
  - If the block is missing or invalid, the recap still shows and the memory stays as it was. The next day's call tries again.
  - The first update of a new week also folds the past week's daily files into the weekly summary.
- **Durable facts.** There are two ways in (the user's choice of proposal and confirmation):
  - **Explicit:** the user types "remember …" or "hatırla …". Loom saves the item at once, because the vault's rule says "A specific authorized request does not need a second confirmation". Home shows "Saved to Lombot.md · Undo".
  - **Proposed:** an answer may end with a chip such as "Remember: The EDD release is on Friday? · Save · Not now". Nothing is saved without the click.
  - Lombot never saves a durable fact by itself. The vault's rule is "Never promote task instructions or inferences into durable rules", and the user chose this option.
- **Editing.**
  - The user edits `Lombot.md` in Obsidian or any editor.
  - The working memory is shown in Settings → Lombot → Memory. There the user can read the journal and the notes, edit or remove a note, remove a line, or clear everything.

**The budget per call**

The pack is ordered so the stable parts come first, which lets the CLI's prompt cache reuse them between calls:

| Part | Share |
| --- | --- |
| Lombot's rules and identity (from `Lombot.md`) | About 0.5k |
| Durable facts | Up to about 1.5k: the most relevant first when the note is larger |
| Notes of the projects in scope | Up to about 1.5k |
| Journal headlines of the last three days | Up to about 0.5k |
| Self card | About 0.5k |
| Session index and excerpts | Up to about 8–10k |
| The question, plus the previous question and answer | Up to about 1k |
| **Total** | **At most about 14k tokens, fixed** |

When the pack is over the budget, Loom drops the least relevant excerpt first, then older journal lines. The rules, the self card and the question are never dropped. The morning call's pack is larger, about 30k tokens, because it reads every session that moved since the last recap.

**Follow-ups.** A follow-up question carries only the previous question and answer. The memory continues across days, but no conversation keeps growing.

**Forgetting**

- **Journal:** daily files are kept for 14 days and then folded into a weekly summary. Weekly summaries are kept for 12 weeks; older ones are deleted.
- **Project notes:** a note stays within 2 KiB because it is rewritten, never appended to.
  - A project idle for 30 days keeps its note, marked "as of <date>".
  - A removed project, or one the user excluded from Lombot, loses its note at once.
- **`Lombot.md`:** near 8 KB, Lombot proposes merges or removals on Home. The user decides.

**Truth**

- Every claim in an answer is either current, from a source read in this call, or remembered, from memory with its date.
- The rules tell the model three things:
  - mark remembered claims ("as of 16 Oct");
  - prefer the current state when the two disagree;
  - say what it could not see.
- The next daily update corrects the note.
- The footer under the ask field says what the answer used: "Read 5 sessions · memory: loom-dev note (17 Oct)".

**Self-awareness**

- **What it is.** The self card tells Lombot:
  - what it is, what it can and cannot see, and its rules;
  - its model and effort, and its use of the plan today;
  - how fresh its memory is, and the local date and time.
  So "Which model are you?" or "Can you see Codex?" get true answers.
- **The work it did.** The journal holds Lombot's own past answers. It can say "Yesterday I said the acceptance had not run; since then two sessions ran", and it can answer "What did you tell me yesterday?".
- **Its limits.** When the sources do not cover a question, it says what it could not see: "That session's transcript is gone", or "I can't see Codex sessions".

**Deletion**

- Loom registers a `ConversationForgetting` for the working memory (`LoomCore/ConversationDeletion.swift:13`). Each journal line and each note item carries the ids of the sessions it cites. When a session is permanently deleted:
  - the journal lines that cite it are removed;
  - a note item that cites only that session is removed;
  - a note that cites it among others is rewritten without it at the next daily update.
  - The forgetter is idempotent, as the deletion flow requires.
- `Lombot.md` holds the user's own confirmed facts. Deleting a session does not change it.

**The contract**

- The working memory is derived content. It is bounded, it expires and it is deleted with its sessions.
- Contract §7's sentence "a second copy of the transcripts must not be kept" was written for task handoff, but its spirit reaches this. The user chose memory knowingly ([§9](#9-the-users-choices-18-oct)).
- §10's "must not grow without bound" holds through the caps above.

### 3.6 Where memory lives

The user chose the split.

**Working memory: Loom's data folder.**

`<data root>/lombot/` holds:

- `journal/YYYY-MM-DD.md` and `journal/YYYY-Www.md`;
- `projects/<project id>.md`;
- `state.json`: the day of the last recap and the counters.

The folder is 0700 and its files are 0600, and every write is atomic. The diagnostics export leaves the folder out.

**Durable memory: one note in the vault.**

- In the user's install the note is `second-brain/Lombot.md`.
- The path is a setting, because Loom is public and most users have no vault. Without a path the note lives at `<data root>/lombot/Lombot.md`.

**Why the split.** The vault's own `AGENTS.md` rules decide it:

- "Write only within requested maintenance or an explicit request to remember information."
- "Do not create stubs or routine conversation summaries."

The journal and the project notes are routine summaries. In the vault they would break these rules and clutter its graph and search. The durable layer fits the vault's other rules exactly: "Store confirmed facts and preferences", "Date volatile observations", one canonical source.

**How Loom writes the note:**

- It writes only that one note, and only under its own headings.
- It reads the file before every write and replaces it atomically, keeping the user's edits.
- It never commits in the vault's git repository; the vault's rule is "commit only when requested".

**What it reads from the vault:**

- `Lombot.md` on every call.
- For questions about one project, that project's card. A card's `repo:` path matches the project's folder in Loom's catalog.
- Nothing else.

**What the vault needs.** This is the user's own maintenance task; this session wrote nothing in the vault:

- one line in the vault's `AGENTS.md`: `Lombot.md` is written by Loom's Lombot on explicit remember requests and confirmed proposals;
- a link to the note from the vault's `Home.md`.

**Where facts go.** By the vault's rules, a project goal or preference belongs in that project's card. For now, Lombot writes only `Lombot.md`: facts about a project stay there, tagged with the project, until the user moves them. Writing into project cards is not proposed.

**Today the vault stays on this Mac.** Checked on 18 Oct:

- its git repository has no remote;
- Obsidian Sync is off;
- `~/Documents` is not in iCloud Drive.

If a remote or a sync is added later, `Lombot.md` travels with it.

**A sketch of `Lombot.md`:**

```markdown
---
type: agent
id: lombot
updated: 2026-10-18
---

# Lombot

Loom's Home assistant. [[Home]]

## Who I am
- I read Loom's Claude sessions and my own notes, and answer. I never start, stop or change a session.
- I mark what I remember with its date, and what I read now as current.

## How you want answers
- 2026-10-18 · Short answers; the next step first.

## Remembered
- 2026-10-18 · edd · The EDD release is on Friday 24 Oct.
```

## 4. How it runs

### 4.1 Engine options

| Engine | For | Against | Verdict |
| --- | --- | --- | --- |
| The user's Claude Code, one `claude -p` child per call | The user's login and plan; the binary Loom already drives; Loom already spawns `claude -p` children by itself for the plan limits | Claude Code's own prompt and start-up (S9: a first call created about 20k tokens of cache); some flags still to verify | **Chosen** |
| The Claude API with an API key | Full control (caching, structured output), no CLI overhead | A key to create and keep; separate billing in money; a network client in Loom | Not now |
| The Claude Agent SDK | The Claude Code harness as a library | Node; Loom has no Node (concept principle 7) | No |
| A long-lived Lombot session over stream-json, like Chat | A warm process, low latency | A growing context, and a process while idle | No |
| Apple's on-device model (Foundation Models) | Fully local and free | A small context window and weaker reasoning; not checked on this Mac | Maybe later, as an offline fallback |
| Codex | — | Frozen ([D-28](../../DECISIONS.md)) | No |

### 4.2 The call

**Process**

- One process per call, in Loom's run scope, owned like the plan-limit probe and the session children.
- Its working directory is `<data root>/lombot/run`, which stays empty. No project CLAUDE.md or project settings load.
- One call at a time:
  - A new question cancels a running question, as the palette cancels its search on each keystroke.
  - A question sent while the morning call runs waits for it, because the brief fills the tiles (a default to try).
  - Quit stops it through the run scope.
  - Timeouts: 60 s for a question, 120 s for the morning call.
- The pack goes in on stdin, never on the command line. Other local processes can read argv.

**Argv.** It is modelled on `ClaudePlanLimitsFetcher.arguments` (`LoomCore/ClaudePlanLimits.swift:174`):

```
claude -p --output-format stream-json --verbose --include-partial-messages
       --model sonnet --effort low
       --settings '{"disableAllHooks":true}' --strict-mcp-config --no-session-persistence
       --tools "" --system-prompt <Lombot's rules>            # both still to verify (S10)
```

- `--model sonnet` is the CLI's alias, so Lombot follows the CLI's current Sonnet, as the composer does. The footer shows the model id the CLI reports in `system/init`.
- **Environment:**
  - the Claude profile Loom's sessions use;
  - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (the user's choice; D-20 makes any CLI behaviour change the user's decision). It applies to Lombot's calls only; sessions keep the CLI's defaults.

| Flag | Why | Status on 2.1.300 |
| --- | --- | --- |
| `--no-session-persistence` | No transcript, no `--resume` entry, nothing for the usage index | Observed (S6 F6). The process still creates its registry entry and socket while it runs |
| `--settings {"disableAllHooks":true}` | The user's hooks do not run | Observed (the plan-limit probe) |
| `--strict-mcp-config` | No MCP server starts | Observed (the plan-limit probe) |
| `--model`, `--effort` | Sonnet at low effort | Observed (S1, S2) |
| `--output-format stream-json --verbose --include-partial-messages` | Streamed text, and `result.usage` at the end | Observed (S1) |
| `--tools ""` | No tools at all | Seen only in the SDK bundle (`evidence/chat-protocol-20261017.md`) |
| `--system-prompt` | Lombot's rules instead of Claude Code's coding prompt | Seen only in the SDK bundle |
| `--setting-sources` | Skip the user's settings (permissions, output style, env) | Seen only in the SDK bundle |
| `--max-turns 1` | Stop after one turn | Hidden from help; seen in the SDK bundle |
| `--json-schema` | A validated memory block | Seen only in the SDK bundle; it would not stream prose, so the fenced block is the first choice |
| `--bare` | — | Breaks the login (S1 Q14); not usable |

**Fallbacks** if S10 finds a flag missing:

- **No `--tools ""`:** use `--permission-mode dontAsk` with `--disallowedTools` listing every built-in tool. S9 row 2 showed that a launch-time deny removes those tools from the list.
- **No `--system-prompt`:** add `--append-system-prompt` on top of Claude Code's prompt, which S9 observed. That costs about 20k cached tokens per call.

**Registry.** A stream child (`entrypoint == "sdk-cli"`) is already ignored by Loom's registry reader (`ClaudeRegistry.swift:24`, `ProviderSessionAdapters.swift:77`). S10 checks that Lombot's call is classified the same way.

**Output**

- The text streams in on Home.
- The `result` frame gives the usage and the model. Loom writes the tokens and the duration into the journal and the counters.
- Answers end with a small fenced JSON block, which Loom strips from the text and validates. It holds:
  - the ids of the sessions cited;
  - the chips;
  - the draft lines;
  - proposed facts.
- An invalid block costs only the chips.

### 4.3 Model and effort

The user chose Sonnet 5.5 for everything, over the recommended split (Haiku 5.5 for questions, Sonnet 5.5 for the daily update).

- **Default:** Sonnet 5.5 at low effort, for questions and the morning call.
- **Settings choices:** Haiku 5.5, Sonnet 5.5 or Opus 5.5, from the composer's model list, and the effort slider from low to max. They reuse V24's model popover and effort slider. Until V24 lands, the lists are `NewSessionModels` (opus, sonnet, haiku) and low to max.
- **Why low effort:** Lombot reads a prepared pack and writes a short answer; it does not plan or write code. Low keeps answers fast. If the daily update's notes come out thin, raising the effort is the first lever.

### 4.4 When it runs

- **On a question:** Return or the send button.
- **On a click:** "Catch me up" in the ⋯ menu beside Home's heading.
- **Once a day, automatically** (the user's choice). This happens the first time Home is shown after 04:00 local time, if any session had activity since the last recap.
  - Lombot does not run at launch in the background: if Loom opens on a session, the recap waits until Home shows.
  - A model-free line from the catalog shows at once; the model's recap replaces it a few seconds later.
- **It does not run when:**
  - Lombot is off;
  - Claude is not logged in;
  - the Mac is offline (the model-free line stays);
  - under 10 % of the five-hour limit is left. The morning call waits; questions still run, with a warning line.
- There is no timer, watcher, retry loop or work while Home is hidden.

This is the first time Loom makes a model call without a direct click. The user authorized it in this brainstorm, for once a day on the first Home view.

### 4.5 Cost against the plan

Prices are the API list prices per million tokens, input and output:

| Model | Price per MTok, in / out |
| --- | --- |
| Sonnet 5.5 | $2 / $10 |
| Haiku 5.5 | $0.10 / $0.50 |
| Opus 5.5 | $4 / $20 |

Loom's `UsagePricing.swift` agrees for Sonnet 5.5 and Opus 5.5 and has no Haiku 5.5 row ([§13](#13-findings-outside-lombot)). The estimates:

| Call | Input | Output | Sonnet 5.5 (chosen) | Haiku 5.5 | Opus 5.5 |
| --- | --- | --- | --- | --- | --- |
| A question | About 13k | About 0.5k | About 3 ¢ | About 0.15 ¢ | About 6 ¢ |
| The morning call: recap and memory update | About 30k | About 2k | About 8 ¢ | About 0.4 ¢ | About 16 ¢ |
| A day: 15 questions and the morning call | | | About 55 ¢ | About 3 ¢ | About $1.10 |

- If `--system-prompt` cannot replace Claude Code's prompt, each call also carries about 20k tokens of that prompt, read from the cache after the first call. That adds about 0.4 ¢ per call on Sonnet.
- **On the subscription the cost is plan share, not money.** The plan's model weights are not published.
- **A scale:** S9 recorded the first call of a normal Chat turn reading 24–27k tokens from the cache. So a Lombot question on Sonnet costs about as much as one short Sonnet coding turn, and a day of Lombot as about 15–20 of them.
- **Loom's own count.** The call writes no transcript, so the usage index does not see it. Loom counts Lombot's tokens from `result.usage`. Settings shows "Today: 6 questions · 81k tokens", and the plan meter shows the effect as usual. Home's Today number stays the usage index's, so every number keeps one source.

## 5. Privacy

- **Transcripts stay on the Mac.** Loom reads them only for a call, within the per-session bounds of [§2](#2-its-sources) and off the main actor, like the palette's search ("reads … only while you type, and keeps nothing").
- **What leaves the Mac is the model call itself.** It carries the self card, the memory share, the excerpts and the question. It goes over the user's Claude Code login to Anthropic, the same provider that already received this content when the sessions ran.
  - With the user's choice, Lombot's child runs with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, so the CLI sends no telemetry, error reports or update checks for these calls. S10 checks this.
  - Loom itself sends nothing.
- **What is stored:**
  - the working memory in `<data root>/lombot/`: bounded, expiring, deleted with its sessions, never in logs or the diagnostics export;
  - `Lombot.md`: the user's confirmed facts.
  - There are no transcript copies, no embeddings and no index of content.
- **Per-project control.** In Settings → Lombot → "Projects it reads", an excluded project is never in a pack, a note or the journal, not even for "All projects" questions. Excluding a project deletes its note.
- **Secrets.** Before a pack leaves, Loom masks common token shapes, best effort, as in I-38:
  - `sk-…`;
  - `ghp_…` and `github_pat_…`;
  - `AKIA…`;
  - `Bearer …`;
  - PEM blocks;
  - `password=` and `token=` values.
- **No content on argv** ([§4.2](#42-the-call)).
- **Account terms.** The training and retention terms of the user's Anthropic account apply to Lombot's calls as to their sessions. Settings says so in one line.
- **The vault** is local today ([§3.6](#36-where-memory-lives)).

## 6. The UI

An HTML sketch of both surfaces was shown in the brainstorm, with Haiku 5.5 in the footer, before the user chose Sonnet. The wireframes below follow the user's choices.

The design options are in [v2-lombot-preview.html](../../design/v2-lombot-preview.html), drawn after the brainstorm at the user's request. It shows five ways to place Lombot on Home: A, the card sketched here; B, a briefing; C, a thread; D, a hero; and E, a rail. It also shows the parts every option shares: F, asking from ⌘K; G, Put in draft; H, the memory sheet; and J, Settings. The user liked B and D and asked for a synthesis of the two ([§9](#9-the-users-choices-18-oct), row 9). K to M draw it:

- **K, the brief hero: the user's pick.** D's morning page with B's brief inside it: "Where you left off", one sentence from Lombot, then one tile per project that moved. Each tile shows the time its project note was rewritten, how its session ended, the next step, an Also line for the project's other news, and Put in draft. Quiet projects fold into one line, and more than three projects continue as B's rows.
- **L, lead and brief, kept for reference.** Another balance: one lead tile for Lombot's first pick, with B's brief beside it for the other projects.
- **M, later in the day.** The morning surface folds into one line per entry once the user has picked up. Loom marks each entry picked up or still waiting, with no model call, and an answer opens under the ask field.

After the user picked K, the preview draws its states on its tiles: I, getting the brief, and N, after the brief. O shows K in the narrow window.

### 6.1 Home

The user picked K from the design preview ([§9](#9-the-users-choices-18-oct), row 9): the brief hero, a synthesis of options B and D. In the morning, Lombot takes the top of Home, where the start box was. Once the user has picked up, it folds into a short brief (M in the preview). Below it come Needs you, Finished not read, the compact plan limits (V25), Today and Continue. The sidebar's "New session" row under Home (V19) starts new work. The examples use the preview's sample projects. On screen, the morning recap is called the brief.

**In the morning:**

```
┌ Home ────────────────────────────────────────────────────────────────────────┐
│ Where you left off   Saturday 18 October · since yesterday 23:10        ⌘K ⋯ │
│ ◇ Three projects moved since yesterday. Billing is closest to done; the      │
│   only failure is in data-jobs.                                              │
│ ┌▌billing ─────── 09:12┐  ┌▌api-gateway ─── 09:12┐  ┌▌data-jobs ───── 09:12┐ │
│ │ Refactor tax rules   │  │ Webhook signature    │  │ Nightly import job   │ │
│ │ Stopped 23:10 · 4/6  │  │ check                │  │ ● Ended · 3 failing  │ │
│ │ Next: step 5, the    │  │ Stopped before push  │  │ Next: update the     │ │
│ │ rounding rules       │  │ Next: push, watch CI │  │ import fixtures for  │ │
│ │                      │  │                      │  │ the new schema       │ │
│ │ Also: Invoice PDF    │  │ Also: Rate limiter   │  │                      │ │
│ │ export waits for you │  │ tests pass (214)     │  │                      │ │
│ │ [Put in draft]  Open │  │ [Put in draft]  Open │  │ [Put in draft]  Open │ │
│ └──────────────────────┘  └──────────────────────┘  └──────────────────────┘ │
│ › loom · quiet since Wednesday                                               │
│ Remember this? billing ships on Friday 24 Oct.                Save · Not now │
│ ┌ Ask Lombot about your sessions ───────────────────── All projects ▾  (↑) ┐ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│ Read 6 sessions · memory: 3 project notes · 4.6 s · Sources · Memory…        │
│ Finished, not read                                                           │
│ ● Rate limiter tests          12 tests added, all pass                       │
│ ● Nightly import job          3 tests failed in test_import.py               │
│ 5h 100% left · Wk 74% left · on pace                                         │
│ Today …  ·  Continue …                                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Later in the day:**

```
┌ Home ────────────────────────────────────────────────────────────────────────┐
│ Today   Saturday 18 October                                               ⌘K │
│ ┌ ◇ Lombot · morning brief 09:12 · 2 of 3 picked up ───────── Show brief ⋯ ┐ │
│ │ ✓ billing     Refactor tax rules       Working · step 5 of 6       09:20 │ │
│ │ ✓ api-gateway Webhook signature check  ● Waits for you: git push   09:31 │ │
│ │ ○ data-jobs   Nightly import job       Next: the fixtures [Put in draft] │ │
│ │ ┌ Ask about your sessions ──────────────────────── All projects ▾  (↑) ┐ │ │
│ │ └──────────────────────────────────────────────────────────────────────┘ │ │
│ │ You asked at 11:20: Which session touched the webhook secret?          × │ │
│ │ Webhook signature check, yesterday at 22:40: it moved the secret into    │ │
│ │ WEBHOOK_SECRET in config/env.py. Token rotation read that file this      │ │
│ │ morning but did not change it.                                           │ │
│ │ [▌Webhook signature check →]  [▌Token rotation →]                        │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│ Needs you                                                                    │
│ ● Webhook signature check     Allow: git push origin fix/webhook-sig         │
│ Finished, not read …  ·  Plan limits …  ·  Today …  ·  Continue …            │
└──────────────────────────────────────────────────────────────────────────────┘
```

**The parts:**

- **Heading:** "Where you left off", the date and the span the brief covers ("since yesterday 23:10"). Once the brief folds, Home's own "Today" comes back. A ⋯ menu beside it holds Catch me up, Memory… and Settings.
- **Sentence:** one or two sentences from Lombot, streamed in.
- **Tiles:** one per project that moved, at most three, ranked by Lombot: closest to done, a failure, or work cut short. Each tile has:
  - the project, and the time its project note was rewritten;
  - the session and how it ended, from Loom's catalog;
  - Next, the next step from the project note;
  - Also, the project's other news, when there is any;
  - Put in draft as the first action ([§1.3](#13-session-links-and-drafts)), then Open.
- **More projects:** the fourth project that moved and any after it continue as one-line rows under the tiles, with the same two actions.
- **Quiet projects** fold into one line. Excluded projects are never named.
- **Proposed fact:** one line with Save and Not now.
- **Field:**
  - the placeholder is "Ask Lombot about your sessions";
  - a scope chip offers All projects or one project;
  - Return sends, and Esc cancels a running answer;
  - ↑ in an empty field brings back the last question.
- **Answer:** it opens under the field, with the question above it and × to close it. Its chips are the sessions it names. The next question replaces it; the previous question and answer fold into one line ("Earlier: …"), the only history carried.
- **Footer:** what the brief used and what it cost. "Sources" opens a popover listing the sessions and memory items, each a link. "Memory…" opens the memory sheet.
- **The fold:** after the first entry the user picks up (a default to try), the tiles fold into one line per entry.
  - An entry is picked up when its session has run since the brief. Loom works that out from the catalog, with no model call.
  - A picked-up line shows a tick and the session's live state. A waiting line shows an open ring, its next step and Put in draft.
  - "Show brief" brings the tiles back.
- **Narrow window:** below a panel of about 720 points, as in Loom's 780 × 500 minimum window, the tiles become B's rows. The date moves under the heading, Put in draft and Open become two small buttons, and the Also line moves into the row's tooltip.

**States** (I and N in the preview):

| State | What Home shows |
| --- | --- |
| The brief set to When I ask | The heading and Loom's line "Your latest sessions, newest first." with Catch me up. The tiles come from the catalog alone: one per project with its newest session, newest first, and Open as their only action |
| Reading | "Reading 6 sessions and 3 notes…" in the sentence's place, in secondary text. Empty tiles hold the place, so nothing jumps when the answer arrives |
| Answering | The sentence streams in, with the working indicator Loom already has (a render-server layer animation, no wakeups). The tiles fill in when the answer's block arrives. Esc or Stop ends the brief, and the tiles fall back to the catalog ones |
| Done | The sentence, the tiles and the footer |
| Saved | "Saved to Lombot.md · Undo", in the proposal's place |
| Draft placed | On the tile: "In its composer, not sent · Open". When that composer already has text, the line is copied instead: "Copied: it already has a draft" |
| Not logged in | "Lombot uses your Claude Code login. Log in with `claude` in a terminal." in the sentence's place. The tiles fall back to the catalog ones |
| Plan limit reached | "Your 5-hour Claude limit is reached until 14:40. Lombot waits." in the sentence's place. The tiles fall back to the catalog ones |
| Call failed, or offline | "Lombot could not get an answer from Claude." with Try again, in the sentence's place. The reason is in the tooltip, and the tiles fall back to the catalog ones |
| Off | No Lombot; Home starts with Needs you, as after V19 |
| No sessions yet | Home's own heading and "Lombot reads your sessions and tells you where you left off. It answers once you have a session." |

**Voice, look and accessibility:**

- **Lombot's voice.** Lombot's answers are the model's text, in first person and in the question's language. They are calm, with no exclamation marks and no emoji, and say "session", never "conversation". The morning brief uses the language of the user's last question, or the language set in Settings.
- **Loom's voice.** The heading, the tiles' catalog lines and the folded lines keep Loom's voice ([DESIGN §6](../../design/DESIGN.md#6-identity-a--night-fleece)).
- **Look.** Theme tokens only. The tiles and the folded brief sit on the panel like Home's other sections, with V25's spacing, and each carries its project's colour as a tone bar.
- **Accessibility.**
  - Lombot's surface is a group named "Lombot", and each tile is a group named after its session.
  - The sentence and an answer are announced once they are complete, not token by token.
  - Chips and tile actions are buttons, for example "Put in draft for Refactor tax rules, billing".
  - The field's label is "Ask Lombot".

### 6.2 Settings → Lombot

The tabs become General · Usage · Lombot · About (· Sessions when shown). `SettingsSection` (`LoomCatalogUI/SettingsView.swift:4`) gets one case, a title and a branch. Rows use `SettingsCard` and `SettingsRow`, and the preferences persist through `UIPreferencesStore`.

```
┌ General · Usage · [Lombot] · About ─────────────────────────────────────┐
│ Lombot                                                          [ on ]  │
│   Answers questions about your sessions on Home. It only reads.         │
│ Model                                              [ Sonnet 5.5    ▾ ]  │
│   Haiku is faster and uses much less of your plan.                      │
│ Effort                                        low ●────────────── max   │
│ Morning brief                                [ Automatic | When I ask ] │
│   One answer on the first Home view of the day.                         │
│ Brief language                         [ Same as my last question ▾ ]   │
├─────────────────────────────────────────────────────────────────────────┤
│ Projects it reads              ✓ loom-dev   ✓ edd   ✓ enmusait   ✗ …    │
│   Excluded projects are never sent and never remembered.                │
├─────────────────────────────────────────────────────────────────────────┤
│ Working memory      14 days · 4 project notes · updated today 09:12     │
│                                                      [ Show… ] [Clear…] │
│ Memory note         ~/Documents/second-brain/Lombot.md  [Choose…][Open] │
│   Lombot writes here only when you ask it to remember, or confirm one.  │
│ Propose things to remember                                      [ on ]  │
├─────────────────────────────────────────────────────────────────────────┤
│ Today               6 questions · 81k tokens · counts toward your plan  │
│ Morning brief waits while the 5-hour limit is under            [ 10% ]  │
│ Lombot reads Claude's transcript files on this Mac only while it        │
│ answers, and sends short excerpts to Claude through your Claude Code    │
│ login. Claude Code's telemetry and update checks are off for Lombot's   │
│ calls. Its memory stays on this Mac.                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

**Memory → Show…** opens a sheet. It has the journal by day and the project notes. A line can be removed and a note edited or removed. Every change is written at once.

**Defaults:**

- Lombot is on in the user's install ([§11](#11-open-points) covers the public build).
- Sonnet 5.5, low effort.
- The morning recap is Automatic.
- Every project is read.
- Proposals are on.
- The memory note is the vault path in the user's install.

A Codex row appears only when Codex returns (D-28).

## 7. Before building: spike S10

S10 is a proposal. It would run in the isolated profile (D-04) with synthetic packs only: no real transcripts and no real `~/.claude`. It needs about 10 model turns, split between Sonnet 5.5 and Haiku 5.5.

1. **The call's shape on 2.1.300.**
   - Does `--tools ""` leave `system/init.tools` empty?
   - Does `--system-prompt` replace the default prompt? Then the first call's cache creation should be far below S9's ~20k tokens.
   - Does `--setting-sources` without `user` keep the login and drop the user's settings?
   - Does `--max-turns 1` hold?
   - Does `--json-schema` work with stream-json output?
2. **Residue.** With `--no-session-persistence`:
   - nothing lands in `projects/`, and there is no `--resume` entry;
   - the registry file and the socket go at exit;
   - the child is a stream child for Loom's registry reader.
3. **Non-essential traffic.** With `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, the login holds and the model call works. A per-process network view (for example `nettop -p`) shows no other host.
4. **Memory files.** Does a user-level `CLAUDE.md` in the profile still reach a `-p` call in an empty folder with a replaced system prompt? Test it with a marker file.
5. **Latency.** Time from spawn to the first text and to `result` for Sonnet 5.5 low and Haiku 5.5 low, with a 13k-token pack and with a 30k-token morning pack.
6. **Transcript facts.**
   - Where `ai-title` and `last-prompt` sit in a real transcript recorded in the isolated profile.
   - What the compaction summary record looks like.
   - The cheapest way to find a session's first real prompt.

## 8. Build shape

This is the planner's input, not a plan. Lombot depends on V19 (Home without the start box), V24 (the model list and the effort slider) and V25 (Home's look), so it comes after Release B.

| Slice | Delivers |
| --- | --- |
| L1 Core (LoomCore) | **Pack builder:** sources to a bounded, ranked pack with the budget and the drop order of §3.5, secret masking and project exclusion. **Call runner:** the process in the run scope, stream decoding through V15's decoder, cancel, timeouts, `result.usage`, the fenced block. **Counters.** **Fake provider:** a one-shot text mode, so the tests need no real Claude |
| L2 Memory | The journal, the project notes, the daily update's parser and writer with validation, the weekly fold, the caps, the forgetter, and the `Lombot.md` writer (read before write, atomic, own headings only) |
| L3 UI | The Home surface (the B × D synthesis: the morning tiles and their fold later in the day) and its states, the chips and Put in draft through the V17 draft store, the proposal chip, Settings → Lombot, and the memory sheet |

**Acceptance proposals:**

- **Idle cost:** no process while Lombot is idle, and exactly one process per call.
- **Residue:** nothing in the profile's `projects/` after a call.
- **Project exclusion:** an excluded project never appears in a pack (a test on the pack builder).
- **Deletion:** deleting a session removes its journal lines.
- **The morning call:** it runs once per day and only while Home is shown.
- **Never acts:** Lombot never sends, starts or answers anything. A test on the fake provider covers this, including a pack whose excerpt tells the model to do so.
- **Draft safety:** a draft never overwrites a composer's text.

## 9. The user's choices (18 Oct)

| # | Question | Options offered | The user's choice |
| --- | --- | --- | --- |
| 1 | How Lombot builds its context | A fresh per question (recommended), B daily digest, C cached project summaries | None alone: the current state fresh on every call, plus a memory, so Lombot feels like an assistant and is aware of itself and its work. The user asked about a place in the second-brain vault. Answered by §3.3–§3.6 |
| 2 | The morning "where you left off" recap | Automatic once a day (recommended), or only when asked | **Automatic, once a day** |
| 3 | What answers may do with sessions | Session links (recommended), text only, links and an unsent draft | **Links and draft** |
| 4 | Answer language | The question's language (recommended), always Turkish, always English | **The question's language** |
| 5 | Where memory lives | Split (recommended), all in the vault, all in Loom | **Split:** working memory in Loom's data folder, durable memory in `second-brain/Lombot.md` |
| 6 | When Lombot writes durable memory | Proposal and confirmation (recommended), explicit requests only, automatic | **Proposal and confirmation.** An explicit "remember" saves at once, with Undo |
| 7 | Model | Haiku 5.5 for questions and Sonnet 5.5 for the daily update (recommended), all Haiku 5.5, all Sonnet 5.5 | **All Sonnet 5.5** |
| 8 | The CLI's telemetry, error reports and update checks for Lombot's calls | Off (recommended), leave as is | **Off**, for Lombot's calls only |
| 9 | Where Lombot sits on Home (asked after the brainstorm, with the [design preview](../../design/v2-lombot-preview.html)) | A card, B briefing, C thread, D hero, E rail | **A synthesis of B and D.** The preview draws it as K and L, two balances of it, and M, its fold later in the day. The user then picked **K**, one tile per project; L stays for reference |

**Planner defaults.** These are not the user's decisions; the planner may change them:

- low effort;
- the day starts at 04:00 local time;
- 14 days of daily journal and 12 weeks of weekly summaries;
- 2 KiB per project note;
- at most about 14k tokens per question and about 30k for the morning call;
- a follow-up carries one previous question and answer;
- the morning call waits under 10 % of the five-hour limit;
- timeouts of 60 s and 120 s;
- every project is read by default;
- the `Lombot.md` path is a setting;
- Lombot answers in first person.

## 10. Risks

| Risk | What could happen | Mitigation |
| --- | --- | --- |
| Prompt injection through transcripts | A tool output or a fetched page in a transcript tells Lombot to do something | The model has no tools. Its only effects are chips the user clicks, and the user sees a draft in full first. The rules mark excerpts as data. Proposed facts need a click. Project notes are rewritten from current sources every day and shown in the memory sheet |
| Memory drift | A wrong note carries forward | Notes are rewritten from current sources rather than from the old note alone. Remembered claims carry their dates and lose to the current state. Everything can be edited. The user chose Sonnet, which helps quality |
| Latency on Sonnet | 3–6 s per answer | The answer streams. Reading takes well under a second. Home shows Loom's model-free line and the tiles' catalog lines at once |
| Plan share | Lombot competes with real work | Counters, the 10 % guard, a model choice in Settings, and nothing runs without a question except the once-a-day call |
| CLI drift | A flag changes meaning or disappears | Gate flags on `--help` and on the version, as `ProviderToolchain` does. Lombot's own acceptance runs in each release's real-Claude check |
| A misread transcript | Unknown records or a format change | Unknown records are skipped. A session that cannot be read is named in the answer as unread, never summarized from nothing |

## 11. Open points

- **The vault side.** Adding the `AGENTS.md` line and the Home link for `Lombot.md` is the user's own maintenance task ([§3.6](#36-where-memory-lives)).
- **Project facts.** Facts that belong in a project card stay in `Lombot.md`, tagged with the project, until the user moves them. Whether Lombot should ever write into project cards is open; this design does not.
- **Public build.** Whether Lombot is on or off by default there. The user's install has it on.
- **Usage view.** Whether Settings → Usage should list Lombot's tokens as their own line. The proposal is yes; Home's Today stays the usage index's number.
- **Acting on sessions.** Whether Lombot may ever do more, such as start a session or send a draft. That is out of scope here and a later decision.
- **Codex.** Reading Codex sessions when Codex returns (D-28).

## 12. Doc impact for the planner

- **DECISIONS.md:** a decision that records §9. It covers:
  - Lombot's read-only scope;
  - the memory split and the confirmation rule;
  - Sonnet 5.5;
  - non-essential CLI traffic off for Lombot's calls;
  - links and drafts;
  - the once-a-day automatic call as a model call Loom makes with the user's authorization.
- **LOOM-PRODUCT-CONTRACT.md:** a note under §7 and §10. Lombot's bounded, expiring working memory and its once-a-day call are authorized by the user, and its memory is cleaned on deletion (§8 item 4).
- **V2-PLAN:**
  - a Lombot track after Release B, with S10 and slices L1–L3;
  - V05's row: Home's top holds Lombot;
  - §13 below for the Usage pricing.
- **design/DESIGN.md:** Lombot's Home surface (the B × D synthesis) and the Settings tab, once built.
- **STATUS.md:** the user's item "Lombot brainstorm" is done; S10 is next when the planner schedules it.

## 13. Findings outside Lombot

- **Haiku 5.5 pricing.** `UsagePricing.swift` (dated 7 Oct) has no Haiku 5.5 row, while the CLI's `haiku` alias resolves to `claude-haiku-5-5` (S9). The claude-api reference lists Haiku 5.5 at $0.10 / $0.50 per million tokens (prompts up to 100k tokens). Loom's Usage may price Haiku 5.5 sessions wrongly or not at all. The fallback path for unknown models was not read.
- **Lost status on relaunch.** Home's reason line and the unread flag are kept in memory only, so Finished not read and the reasons are lost on relaunch. This was found while tracing Lombot's sources; whether it is intended was not checked.
