# Loom v2 concept: Studio

**Date:** 17 Oct 2026 · **Kind:** concept, the second pass of the v2 round · **State:** a proposal waiting for the user's decisions. Nothing here is decided. [DECISIONS.md](../../DECISIONS.md), the [product contract](../../LOOM-PRODUCT-CONTRACT.md) and [design/DESIGN.md](../../design/DESIGN.md) are unchanged.

**The user's ask (17 Oct, second message, in Turkish, paraphrased):** the first pass did not offer enough improvement or the revision the user wants. The app should be fuller and more substantial: useful every day, but never overwhelming. The design system may change for this. The chat interface deserves a deeper look.

**Prototype:** [design/v2-studio-preview.html](../../design/v2-studio-preview.html). Open it in a browser. The arrow keys switch between its 12 screens. The controls at the top try the design-system options on every screen. Each screen ends with an "Underneath" line that says which mechanism it needs.

**Planning (17 Oct, after the user's answer).** The user accepted this concept with changes ([D-57](../../DECISIONS.md), [D-58](../../DECISIONS.md), [D-59](../../DECISIONS.md)). [V2-PLAN](../V2-PLAN.md) and the [chat behaviour spec](../v2/CHAT-SPEC.md) build on it and win where they differ. The main changes:

- Chat comes first. The header loses its Chat | Terminal switch, and "Continue in Terminal" moves to ⋯.
- The new-session sheet gives way to the draft session N1 ([D-59](../../DECISIONS.md), [options](../../design/v2-new-session-preview.html)).
- The composer bar takes the look of Codex's.
- The sidebar's Glass and Solid become a setting.
- The plan's Releases A, B and C replace the release plan in §7.

## How to read this

| File | What it holds |
| --- | --- |
| This file | The thesis, the information architecture, the chat in depth, the Night Fleece 2 design system, the release plan, spikes, risks and the decisions for the user |
| [Prototype](../../design/v2-studio-preview.html) | 12 screens of the proposed app at 1360 × 860, with the design-system controls |
| [evidence/chat-protocol-20261017.md](evidence/chat-protocol-20261017.md) | The Claude Code stream-json protocol brief: how the CLI's structured mode works, what Loom can reuse, the policy text, and 15 questions for a live test |
| [evidence/chat-ui-anatomy-20261017.md](evidence/chat-ui-anatomy-20261017.md) | How the leading agent apps build their chat (T3 Code, Zed, Paseo, OpenChamber, Happy, Superset, Codex, Cursor, Claude Desktop), with the patterns to copy and to avoid |
| [V2-BRAINSTORM.md](V2-BRAINSTORM.md) | The first pass: 19 products studied, 44 ideas, three directions. Its research stays valid. Its recommended path and decisions are replaced by this file ([mapping](#11-the-first-passs-decisions-mapped)) |

## 1. Why a second pass

**What the user said.** The first pass played safe. It kept the terminal at the centre, added a read-only Conversation view, and pushed the chat-centred look to an optional track after months of use. The user wants Loom to be the place where development work happens, with a chat at its centre.

**What changed in the evidence.** The first pass ruled out a live chat for three reasons. The protocol brief answers each one:

| First-pass concern | What the protocol brief found | Consequence |
| --- | --- | --- |
| Writing into a live session is risky (blind PTY writes, stray Enter into a dialog) | The CLI has a documented structured mode (`claude -p` with stream-json input and output). Claude's desktop app and VS Code extension host Claude Code this way. A message is one JSON line, and `--replay-user-messages` echoes it back with its id, so delivery is proven | The Chat face writes nothing into a PTY. The riskiest item of the first pass disappears |
| Answering approvals from Loom races the TUI's own dialog | In structured mode the CLI asks the host through a `can_use_tool` control request and waits for the answer. There is no TUI dialog to race | Approvals, questions and plans become native cards whose answer is the answer |
| A Chat child costs about 230+ MB per idle session and drifts from the CLI | A Chat session's process **replaces** the terminal session's process; it is not an extra one. Loom spawns the user's own installed `claude`, not a bundled SDK copy, so features arrive with each CLI update | Memory per session must still be measured (spike S3), but the count of processes does not grow |

**What stays.** Loom's identity from the first pass holds: light, honest about status, nothing running that the user did not start. The first pass's research and idea catalog stay valid, and so do its [findings about today's Loom](V2-BRAINSTORM.md#findings-about-todays-loom) and most of its [do-not-build list](IDEAS.md#do-not-build). Two items on that list deserve a precise reading. "No SDK engine for the main session" still holds: the Chat face uses no SDK, no Node runtime and no bundled CLI. Loom speaks the installed CLI's own structured mode from Swift. "No blind writes into the PTY" also holds: in the Chat face there is no PTY, and in the Terminal face the user types.

## 2. Thesis and principles

**Thesis.** Every session is a native chat over the real Claude Code, with its terminal one click away. Everything that needs the user, everything that changed and what it costs sit on one calm screen.

1. **One session, two faces.** Chat and Terminal are two ways to run the same Claude Code session: the same binary, transcript, skills, MCP servers, hooks, CLAUDE.md and plugins. The header's Chat | Terminal switch says which face runs it. (Planning drops the switch: Chat comes first, and the terminal stays one click away in ⋯.)
2. **One owner at a time.** Only one process ever runs a session. Switching faces hands the session over in a fixed order (see [Lifecycle](#56-lifecycle)).
3. **Calm by default, full on demand.** Three layers, below. The default view shows what matters now. Detail is one click away, and everything is reachable on purpose.
4. **Whatever waits on you is pinned and named.** An approval, a question or a plan never scrolls away. It is pinned above the composer, and the sidebar card says what it is ("Asks which PDF library to use").
5. **A stopped session costs nothing.** No process, no watcher, no timer. Nothing stops by itself while idle ([D-38](../../DECISIONS.md)). A live session costs one Claude process, as it does today.
6. **Truth over guesses.** A message counts as delivered when the CLI echoes it, not before. Status comes from Loom's hooks and the stream. Every number says where it comes from.
7. **Native and light.** AppKit and SwiftUI, no web view, no Node, no daemon. Budgets are tests ([§5.7](#57-performance-budgets)).

**What "fuller" means without overwhelm**

| Layer | What is there | Example |
| --- | --- | --- |
| Always visible | What needs you and why (dot, reason line, pinned card); what Claude is doing now (one working line); the composer | "Editing src/auth/middleware.py · 2m 41s" |
| One click | Folded turns; popovers from the pills above the composer; inspector tabs; the command palette | "Worked for 4m 12s · read 9 files, edited 5, ran 3 commands" |
| On purpose | The Verbose view (⌃O) with every step and the full thinking; raw rows for records Loom does not know; the Terminal face | Every tool call with its input and output |

## 3. What is new, screen by screen

```
┌ sidebar (glass) ─┐┌ panel ────────────────────────────────────────────────────────┐
│ Search · ⌘K      ││ title · ticket · state · project + branch · Chat|Terminal · ▤ · ⋯│
│ Home          3  ││ tabs (optional, D-33)                                          │
│ Active           ││ ┌ stream (reading column 700) ─────────┐ ┌ inspector (closed) ┐ │
│  card + reason   ││ │ turns, folded work, cards, markers   │ │ Overview  Changes  │ │
│ Projects         ││ │ working line                         │ │ Tasks Agents Side  │ │
│  one-line rows   ││ ├ pinned: what waits on you (1 of N)   │ │                    │ │
│ Sessions         ││ ├ pills: tasks · agents · changes      │ │                    │ │
│ usage · ⚙        ││ └ composer: + @ / · mode · model · ring │ └────────────────────┘ │
└──────────────────┘└───────────────────────────────────────────────────────────────┘
```

| Screen | Prototype | What it adds | Built on |
| --- | --- | --- | --- |
| Home | [#home](../../design/v2-studio-preview.html#home) | Loom opens on a calm overview: a start box (project, branch, face, mode, model; Return starts), presets, Needs you (answerable here for Chat sessions), finished but unread with Claude's last line, plan limits with a pace line, and sessions cut by Quit or a crash. The sidebar gets a Home row with a count; Active cards say what each session waits for or did last; project groups list calm one-line rows | Catalog, hooks, plan-limit reads. No process and no polling of its own |
| Chat | [#chat](../../design/v2-studio-preview.html#chat) | The default face: turns with folded work, edit and command cards, a thinking line, an honest working line, pills above the composer, a composer with mode, model, effort and a context ring, and the inspector | The Chat engine ([§5.1](#51-engine)) |
| Composer | [#compose](../../design/v2-studio-preview.html#compose) | `/` for the session's skills and commands, `@` for files, folders and other sessions, images and files, per-session drafts, message actions, a stopped session that resumes on send | Stream-json input |
| Plan review | [#plan](../../design/v2-studio-preview.html#plan) | Plan mode as a first-class step: the plan reads like a document; Approve with a mode choice, or Keep planning with a note; earlier versions kept | `can_use_tool` for ExitPlanMode |
| Approvals and questions | [#approve](../../design/v2-studio-preview.html#approve) | Permission requests and questions as pinned cards, one at a time with a counter; answered ones fold to one line; the Agents tab beside the main thread | `can_use_tool`, AskUserQuestion |
| Review changes | [#review](../../design/v2-studio-preview.html#review) | A real review surface: scope (last turn, session, branch), line comments sent to Claude as one message, Rewind files with an honest label | Git in the session folder, the turn's edit records, `rewind_files` |
| Side chat | [#side](../../design/v2-studio-preview.html#side) | A side thread beside the work that never enters the main session; Send to main as a note; a quick one-shot question | A forked Claude process; `/btw` for the quick version |
| Terminal face | [#terminal](../../design/v2-studio-preview.html#terminal) | Today's terminal, unchanged, as the other face of every session; the Chat view of a terminal session is a read-only rendering of its transcript | Today's PTY path |
| Command palette | [#palette](../../design/v2-studio-preview.html#palette) | ⌘K: needs you, recent sessions, actions, slash commands and skills; full-text search over local transcripts | Catalog and transcripts, bounded reads |
| Project page | [#project](../../design/v2-studio-preview.html#project) | One page per codebase: sessions with their last line, presets, the CLAUDE.md, skills and MCP servers Claude loads, branches, the week's usage | Catalog plus the last session's `system/init` frame |
| New session | [#newsession](../../design/v2-studio-preview.html#newsession) | One sheet: project, ticket, first message, branch (worktree optional), face, permission mode; Save as preset | Today's launch path and the D-40 ticket check |
| Design system | [#system](../../design/v2-studio-preview.html#system) | Night Fleece 2: tokens, components and the rule changes | [§6](#6-night-fleece-2) |

## 4. The two faces in one picture

| | Chat face (new, proposed default) | Terminal face (today) |
| --- | --- | --- |
| Process | `claude -p` in stream-json mode, in the session's run scope through `SPAWN_STDIO` | `claude` in a PTY, in the session's run scope |
| Input | One JSON line per message, delivery proven by the replay echo | The user types in the TUI |
| Approvals, questions, plans | Native pinned cards (`can_use_tool`) | The TUI's own dialogs; Loom shows what is asked |
| Status | Loom's hooks, plus the stream for detail | Loom's hooks |
| Chat view | Live | Read-only, rendered from the transcript |
| What it cannot do | vim mode, dialogs Loom does not model, `/login` and other terminal-only commands | Nothing new; it is the CLI |
| Way out | "Continue in terminal", one click | "Continue in Chat", one click |

## 5. The chat in depth

### 5.1 Engine

**The process.** One child per live Chat session, started by the existing supervisor inside the session's run scope through the run host's `SPAWN_STDIO` mode (`Sources/LoomCore/RunScope.swift:354-357`, `Sources/loom-run-host/main.c:31`):

```
claude -p --input-format stream-json --output-format stream-json --verbose
       --include-partial-messages --replay-user-messages
       --permission-prompt-tool stdio
       --session-id <uuid> | --resume <uuid>
       --permission-mode <mode> --effort <level> --model <model>
       --settings <Loom's hook settings> --plugin-dir <Loom's plugin>
```

The environment is today's launch environment: `CLAUDE_CONFIG_DIR` only for explicit profiles, `LOOM_HOOK_*`, `LOOM_CLI`, `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`. It adds the session-state switch (`CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS` or `CLAUDE_CODE_SDK_READS_SESSION_STATE`; spike S1 decides which) and, for rewind, `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true`. Loom never passes `--bare` (it skips the user's login) and never sets `CLAUDE_CODE_ENTRYPOINT`. Permission mode, effort and model go on every spawn, because `-p --resume` does not restore the permission mode ([brief §2f](evidence/chat-protocol-20261017.md)).

**New components**

| Component | Responsibility | Reuses |
| --- | --- | --- |
| `StdioProcess` | The pipe sibling of `PTYProcess`: three descriptors, non-blocking reads, a bounded stdin writer with backpressure, end-of-file detection, reaping | `RunScope.spawn(stdio: .descriptors…)`; the run host's `setsid` and exit reports; the fetcher's writer and finish sequence (`ClaudePlanLimits.swift:236-322`) |
| `StreamJSONDecoder` | NDJSON framing for lines of several MB (tool results, images); unknown types and subtypes pass through as raw records, never errors | The fetcher's framing, without its 1 MiB line limit (`ClaudePlanLimits.swift:301`) |
| `ControlChannel` | The request table: ids, pending `can_use_tool` requests, cancels in both directions, timeouts, capability checks from `system/init` | The envelope parser in `ClaudePlanLimits.swift:195-203` |
| `ChatSessionDriver` | One session's state machine: spawn, send, interrupt, answer, set mode, model and effort, stop, hand over to the Terminal face | `ProcessSupervisor` guards: ownership markers and the same-session guard (`ProcessSupervisor.swift:~296-340`) |
| `TranscriptLens` | Builds turns from transcript JSONL for stopped sessions, terminal sessions and subagents; bounded backward paging | `SubagentTranscriptParser`, `SubagentTranscriptTail` |
| `TurnModel` | One turn model for three sources (live stream, session transcript, subagent transcript), so one renderer serves them all | — |

**Data flow**

```
 composer ──▶ ChatSessionDriver ──▶ stdin   ┐
                     ▲                      │ claude -p (run scope, SPAWN_STDIO)
 cards ◀── ControlChannel ◀── decoder ◀── stdout ┘
                     │
                     ▼
 TranscriptLens ──▶ TurnModel ──▶ stream view · pinned cards · pills · inspector
 hooks (unchanged) ──▶ SessionEventHub ──▶ sidebar, Dock badge, menu bar, notifications
```

**Hooks stay.** `-p` runs hook settings ([brief §3](evidence/chat-protocol-20261017.md)), so today's status pipeline keeps feeding the sidebar, the Dock badge, the menu bar and notifications. Where a hook stays silent under `-p` (spike S1, question 7), the driver feeds the same hub from `session_state_changed` and `result`.

**Plan limits get cheaper.** While a Chat session is live, Loom can ask `get_usage` over its control channel instead of starting the short headless process, and `rate_limit_event` arrives in the stream on its own.

**A documented fallback for approvals.** `--permission-prompt-tool stdio` is what the SDK uses, but the CLI reference documents only an MCP tool for that flag. If `stdio` ever breaks, the documented alternative is a PreToolUse hook that returns `allow` with `updatedInput` ([brief §2e](evidence/chat-protocol-20261017.md)). Loom already has that hook pipeline over its authenticated socket.

### 5.2 Wire mapping

| What the user sees | Chat face (stream-json) | Terminal face |
| --- | --- | --- |
| Send (↵) | `user` line with a client uuid, `origin:{kind:"human"}`, `priority:"next"`; shown as delivered when the `isReplay` echo with the same uuid arrives | Typed in the TUI |
| After this turn (⌘↵) | Held in Loom's queue strip and sent when the turn's `result` arrives | — |
| Interrupt (Esc, the composer's square) | `interrupt{cancel_queued:true}`; the reply lists the cancelled sends, which go back to the composer as drafts | Esc in the TUI |
| Stop (header) | Interrupt if needed, close stdin, wait for exit, verify the scope drained (today's verified stop) | Today's verified stop |
| Working line | `session_state_changed`, `stream_event`, `tool_progress` | Hooks |
| Turn fold "Worked for…" | `result.duration_ms` and the turn's `tool_use` names | Transcript |
| Thinking line | Thinking deltas with summarized display; the first heading | Transcript thinking blocks, if present |
| Tool rows and cards | `assistant` `tool_use` blocks, `user` tool results with `tool_use_result` | Transcript |
| Subagent cards, Agents tab | `parent_tool_use_id`, `system/task_*`, subagent transcripts | Hooks and subagent transcripts (today) |
| Approval card | `can_use_tool` → allow (`updatedInput`, `updatedPermissions`) or deny (`message`) | The TUI dialog; answering from Loom only after spike S5 |
| Question card | `can_use_tool` for AskUserQuestion → allow with `updatedInput.answers` | The TUI |
| Plan card | `can_use_tool` for ExitPlanMode → allow (then `set_permission_mode`) or deny with feedback | The TUI |
| Mode, model, effort chips | `set_permission_mode`, `set_model`, `apply_flag_settings{effortLevel}` | `/model`, `/effort`, Shift+Tab in the TUI |
| Context ring | `result.usage`; `get_context_usage` when the popover opens | The last assistant message's usage in the transcript |
| `/` menu | `system/init`: `skills`, `slash_commands`; `terminal_slash_commands` are marked "opens the terminal" | — |
| `@` files | The CLI expands `@path` in the text | — |
| `@` session | Loom inserts the other session's transcript path and last answer as text | — |
| Images | `image` content blocks | Paste into the TUI |
| MCP servers (Overview) | `mcp_status`, `mcp_reconnect` | — |
| Rewind files | `rewind_files{user_message_id, dry_run}` | `/rewind` in the TUI |
| Retry and limit banners | `system/api_retry`, `rate_limit_event`, `result.terminal_reason` | Hooks (StopFailure) |
| Compaction marker | `system/status: compacting`, `system/compact_boundary` | Transcript |
| `/clear`, plan exit with a clear | `conversation_reset` → the stream remounts with a marker | Transcript |
| Quick side question (⌘;) | `side_question` (bundle-only, undocumented; spike S6) | `/btw` typed in the TUI |
| Side chat panel | A second process with `--resume <id> --fork-session` | — |
| Background work | `system/background_tasks_changed`, `stop_task` | Hooks |

### 5.3 The stream

From the anatomy study ([evidence](evidence/chat-ui-anatomy-20261017.md), "Top 15" and "Patterns to avoid"), fitted to Loom:

1. **Turn shape.** Your message, Claude's prose, and the work between them as one-line rows. Reads and searches fold into "Explored · read 5 files, searched 3 patterns". Edits, commands and subagents get cards.
2. **Fold only what has settled.** A finished turn folds to "Worked for 4m 12s · read 9 files, edited 5, ran 3 commands" above the answer and a changed-files card. A live turn, a failed or interrupted one, and one with a pending decision never fold.
3. **Success is quiet, failure is loud.** A passing command is one line with a check and "42 passed" in the success colour. A failing one opens with its last 12 lines and its exit code.
4. **Edits.** "Edited src/auth/token_service.py +31 −6", collapsed by default with a setting to expand. An inline diff stops at about 200 lines, then "Open in Changes".
5. **Thinking.** One line with Claude's current heading. The full text appears in the Thinking and Verbose views.
6. **Working line.** "Editing migrations/0042_token_family.py · 3m 05s", from a start timestamp. When nothing has arrived for 40 s it says "No activity for 40s" instead of looking busy. Esc interrupts.
7. **Markers** are hairline dividers: session started (model, effort, mode), compacted, resumed, interrupted ("You stopped after 1m 4s"), model changed, stopped four days ago.
8. **Banners** above the composer only for blockers, each with an action: usage limit with the reset time, sign-in needed (Open terminal), retrying (attempt 2 of 4), a protocol drift notice.
9. **Message actions** on hover: copy, fork from here, rewind files to this point, open in terminal.
10. **Unknown records** appear as a collapsed raw row plus one drift notice per session. Nothing is dropped silently.
11. **Scrolling.** The stream sticks to the bottom and re-arms within about 48 px. A "Jump to latest" pill appears when you scroll up. Older pages load with the anchor held.
12. **No per-turn cost.** Tokens and cost live in the context ring's popover and on the Usage page.
13. **Three views, one key.** Normal (folded work, thinking as one line), Thinking (adds the thinking), Verbose (every step). ⌃O cycles them, like the CLI and Claude's desktop app. Each view does what it says everywhere.

### 5.4 The composer

| Input | Meaning |
| --- | --- |
| ↵ | Send now. Claude reads it after the current step, or starts a turn when idle (`priority:"next"`) |
| ⌘↵ | After this turn. The message waits in the queue strip above the composer, where it can be edited, reordered or removed |
| ⇧↵ | New line |
| Esc while a turn runs | Interrupt. Messages Claude had not read yet come back as drafts, and the queue pauses ("Queue paused because you interrupted · Resume · Clear") |
| Typing while a card waits | Answers it in your own words: a denial with your text as the reason, the "Other" answer to a question, or plan feedback. A message never strands behind a pending request |
| `/` at the start | The session's skills and commands from Claude's own list, plus Loom's actions (Ask on the side, Continue in terminal). A command that only works in the terminal says so and opens it |
| `@` | Files and folders (Claude expands them), and other sessions (their transcript path and last answer, as plain text; no channel between sessions) |
| `+`, paste, drop | Images and files. A very large paste becomes an attachment chip instead of a wall of text |
| ↑ in an empty composer | Earlier messages of this session |

Rules that hold everywhere:

- **Delivery is proven.** A sent message shows dimmed until its echo arrives. If the process ends before the echo, it reads "Not delivered" with Retry and Copy. Loom never resends on its own, and the text is never lost.
- **Drafts are per session.** Loom saves them on blur, on send and on Quit, in its own data folder and never in the transcript.
- **Return never approves and Esc never denies.** This extends DESIGN.md §6 to the Chat face. A card can be answered from the keyboard after moving focus to it; the exact keys are checked against the Turkish Q layout ([decision 10](#10-decisions-for-the-user)).
- **Mode, model and effort** change the live session at once. The context ring shows tokens first, and a percentage only where the model's window is known.

### 5.5 Approvals, questions and plans

**Pinned, not inline.** Everything that waits on the user sits in one strip above the composer. It shows one item at a time, with "1 of 3" when several wait. A subagent's request names the subagent. The sidebar card, Home and the Dock badge show the same item.

**Approvals.** The card shows the tool, the full command or a diff summary (long ones scroll inside the card), and Claude's reason (`decision_reason`, with ANSI stripped). It offers three answers:

- **Allow once.**
- **Allow for this session.** This echoes Claude's own suggested rule with the destination `session`, so no settings file is written.
- **Deny**, with an optional note.

Permanent rules stay where they are today: the CLI's `/permissions` and the user's settings files. An answered request folds to one line in the stream: "Allowed: git push origin fix/webhook-sig".

**Questions.** AskUserQuestion becomes a card with its header, the question, two to four options with their descriptions and previews, multi-select where asked, and a free-text "Other". The answer goes back as `updatedInput.answers`. Afterwards the stream keeps "Asked: which header… · You chose: X-Signature".

**Plans.** The plan appears in the stream as a document with its file path and "Open full plan". The decision is pinned:

- **Approve** with a choice of how much freedom the build gets: Ask before edits, Accept edits or Auto. The mode applies at once (`set_permission_mode`, or `setMode` in the answer; S1 decides).
- **Keep planning** with a note, which is a denial with feedback.

Every version of the plan stays in the transcript, so versions can be compared. Approving turns the plan's steps into the Tasks tab.

**In the Terminal face** the TUI's dialogs answer, and Loom shows what is asked on the card, on Home and in notifications. Answering from Loom there needs spike S5 (the hook against the dialog) and is not planned before it passes.

### 5.6 Lifecycle

| State | Process | What the user sees | Leaves by |
| --- | --- | --- | --- |
| Starting | Child spawning | "Starting" marker | The first `system/init` → Ready |
| Ready | Resident child (Chat) or TUI (Terminal) | Composer | A send |
| Working | Same | Working line | `result` → Ready, or Finished (blue) when unread |
| Needs you | Same, blocked on a request | Pinned card, orange dot | The answer |
| Stopped | None | The Chat view from the transcript; "Stopped 4 days ago · sending resumes it" | A send, which spawns with `--resume` |
| Stale | None | As today (contract §5) | As today |

- **Stop.** If a turn runs, Loom interrupts and waits for the `result`, closes stdin, waits for the exit, then checks that the run scope has drained. SIGTERM and SIGKILL come only after the grace period, as in today's verified stop. Loom never sends SIGTERM in the middle of a turn.
- **Switching faces.** The order is: interrupt, wait for the `result`, close stdin, wait for the exit, check that the scope drained, then start the other face with `--resume` and the same session id, passing mode, effort and model. If a decision is waiting, Loom asks first, because closing stdin cancels pending requests. The existing same-session guard (`conversationAlreadyRunning`) keeps two owners from running at once.
- **Idle.** Nothing stops by itself (D-38). A live Chat session keeps its process until the user stops it, as a terminal session does today. An opt-in idle stop for Chat sessions is [decision 7](#10-decisions-for-the-user).
- **Quit.** As today: Loom asks while sessions work or wait, then stops each one verifiably. After the next launch, Home's Continue list offers the sessions that Quit cut short.
- **Crash.** The run host ends the children, as today. The transcript is Claude's own, so nothing is lost. A turn cut mid-way is marked interrupted, and "Continue the interrupted turn" is offered explicitly, never automatically.
- **Side chats.** A side chat is listed under its parent's Side tab. Closing it stops its process, and the next question resumes it. Discard deletes the fork through Loom's verified deletion path.
- **The switch.** Settings → Sessions → "New sessions start in: Chat | Terminal". If the structured mode fails to start, or a policy signal arrives (`billing_error` or `oauth_org_not_allowed` on `api_retry` or an assistant error), a banner offers "Continue in terminal" and to change the default. Running sessions move one by one, without loss.

### 5.7 Performance budgets

| Budget | Starting target | Checked by |
| --- | --- | --- |
| Loom's CPU while a Chat session streams | No more than today's terminal rendering of the same output; the CPU40 ceiling holds | S4 with `loom-fake-provider` |
| Loom idle, window visible | No wakeups from the chat code | Measurement on an idle day |
| Window hidden or occluded | No layout and no timers; decoding continues so the pipe drains | S4 |
| Claude child memory | Measured fresh, mid-session and long, against the TUI process | S3 |
| Stopped session | No process, watcher or timer | Existing lifecycle tests, extended |
| Cold open of a long session | At most about 1.5 MiB read from the transcript tail; older pages on scroll | S7 with a 50–100 MB synthetic transcript |
| Streaming text | At most one layout pass per frame while visible; markdown parsed per completed block | S4 |
| Large content | Tool output kept as head and tail (64 KiB in memory to start), with "Show all" reading the transcript; no syntax highlighting above about 20,000 characters; a bounded highlight cache | S4 |
| Decoder | Lines of tens of MB decode, with memory bounded by the largest line | Unit tests with fixtures |
| Rows | Virtualized; no hidden bodies mounted | S4 |

### 5.8 Policy

**The facts (fetched 17 Oct 2026, [brief §4](evidence/chat-protocol-20261017.md)):**

- **The support article** has two banners.
  - 7 Oct: the Agent SDK, `claude -p` and third-party apps can still be used with subscription limits, and Max and Team plans now include monthly API credits.
  - 15 June: the announced change was paused.
- **The legal page** allows an end user to sign in to the unmodified Claude Code binary with their own subscription. It forbids products that offer claude.ai login or handle the user's credentials.

**Loom's position.** Loom runs the user's own unmodified binary with the user's own login. It never touches a token, never uses `--bare`, never pretends to be another entrypoint, and names no feature "Claude Code …".

**The exposure.** The headless surface is where billing policy moved four times in ten months. If Chat-face use stopped counting toward plan limits, the Chat face would cost money where the terminal does not.

**The mitigations:**

- the switch in §5.6;
- the drift signals;
- re-reading the support article before every release, added to the release checklist;
- the Terminal face, which always works.

Accepting this exposure is [decision 2](#10-decisions-for-the-user).

## 6. Night Fleece 2

The same identity: dark, quiet, the ram mark's fleece accent, a glass sidebar. It gains the depth a chat-centred app needs. The prototype's controls try every option below.

### 6.1 Tokens

| Group | Tokens |
| --- | --- |
| Surfaces, back to front | Sidebar glass `#0B0E16` at 0.6 (today) · backdrop `#0B0E16` (today) · inspector `#141318` · chat canvas `#19181E` · terminal `#1D1C22` (today's panel) · card and composer `#222128` · raised and hover `#2A2930` · popover and palette `#302F38` |
| Lines and fills | Hairline white 8 %, strong hairline 13 %, fill 6 %, hover fill 9 % |
| Text | Primary `#ECE8F4`, secondary `#9A9EB0`, tertiary `#636779` (today `#E0DBEB`, `#828799`, `#5A5F70`) |
| Accent ramp | High `#A9B0E3` (accent text on raised surfaces), base `#8791CF` (today's Fleece), low `#5E68A8` (strokes and fills that carry no text); text on a filled accent stays `#0B0E16` |
| Status | Attention `#FF9E0A`, unviewed `#5C8CFF`, failure `#F2615C` (all today), with their light text variants `#FFB547`, `#8FB0FF`, `#FF8A85` |
| Success (new, content only) | `#4CC38A`, light `#7BDBA8`: added lines, passing checks, "42 passed". Never a status indicator |
| Project tones | Unchanged (D-48, D-50) |
| Radii | 4 · 6 · 8 · 10 · 14 · 18 |
| Type | Display 24 · Title 17 · Reading 14/22 · Body 13 · Small 12 · Label 11 medium · Mono 12 · Terminal 14 |
| Rhythm | Reading column 700 · sidebar card row 46 · 4 pt grid |
| Shadows | Card: an inset top highlight and a 2 pt drop · raised: 28 pt soft · popover: 64 pt soft with a hairline ring |

**Contrast.** Computed on every surface, against DESIGN.md §6's tiers:

- **Primary** reads at least 10.9:1. **Secondary** reads at least 4.97:1; today's secondary on the terminal is 4.73:1.
- **Four pairs fall short, and each has a rule:**

| Pair | Ratio | Rule |
| --- | --- | --- |
| Tertiary on popovers | 2.36:1 (the floor is 2.5:1) | Popovers use secondary for placeholders |
| Base accent as text on popovers | 4.39:1 | Popovers use the high accent (6.3:1) |
| Unviewed and failure as text on popovers | about 4.2:1 | Their light variants, as today's pills already do |
| Primary on the low accent | 4.33:1 | The low accent never carries text |

`LoomThemeTests` would check all of these.

### 6.2 Components

| Component | Shape |
| --- | --- |
| Composer | Card surface, radius 14, raised shadow; text area, then a bar with `+`, `@`, `/`, the mode, model and effort chips, the context ring and Send (Stop while a turn runs) |
| Pills above the composer | 26 pt capsules: tasks with a progress bar, subagents running, changed files with +/−; each opens a popover. Never stacked cards |
| Pinned cards | Radius 12 on the card surface with the raised shadow and a hairline border in the status hue (orange for approvals and questions, accent for plans); a counter and a stepper; buttons in Title Case |
| Tool rows | 30 pt, an SF Symbol, verb, subject, trailing status; edit and command cards on the card surface, radius 8 |
| Turn fold | A one-line row with a hairline border and a chevron |
| Thinking line | A secondary line with a sparkle symbol and Claude's heading |
| Markers | A hairline with centred small text |
| Inspector | 328 pt (556 for review), inspector surface, tabs Overview, Changes, Tasks, Agents and Side; the open tab shows its name, the others their symbol and count |
| Session card | Title and time, then a reason line: what it waits for or did last ("Allow: git push origin fix/webhook-sig", "3 tests failed in test_import.py") |
| Home blocks | Card surface, radius 12, a heading row with a count |
| Palette | Popover surface, radius 14, 620 pt wide, grouped rows |

Every symbol maps to an SF Symbol. The prototype draws them as SVG only because a browser cannot load SF Symbols.

### 6.3 Density and views

- **Density** (Settings): Comfortable is the default. Compact tightens rows to 40, the reading size to 13/20 and the column to 760, for small screens.
- **Views** (per session, ⌃O): Normal, Thinking and Verbose (§5.3).

### 6.4 The options in the prototype

| Option | Choices (first = proposed default) |
| --- | --- |
| Accent | Fleece `#8791CF` · Iris `#9C8CFF` · Glacier `#7FB2E5` |
| Sidebar glass | 0.6 (today, D-44) · 0.86 · solid |
| Canvas | Ink `#19181E` · Graphite `#1E1D22` · Deep `#131218` |
| Reading size | 14 · 13 · 15 |
| Density | Comfortable · Compact |

### 6.5 Rule changes against DESIGN.md

DESIGN.md stays as it is until the user decides ([decision 5](#10-decisions-for-the-user)). The changes it would take:

| Rule today | Proposed | Why |
| --- | --- | --- |
| §2.6, §6 Header: "it is never replaced by a custom chat UI" | Every session has a Chat face and a Terminal face; the terminal stays, unchanged, one click away | The user's direction; the contract wording is [decision 3](#10-decisions-for-the-user) |
| §6 Colour: two surfaces | Five levels in the panel: inspector, canvas, card, raised, popover; the terminal keeps today's panel colour | A stream with cards, a composer and popovers needs depth; one flat surface reads as a wall |
| §6 Colour: one accent value | An accent ramp around the same Fleece | Accent text on raised surfaces needs the lighter step to keep 4.5:1 |
| §6 Colour: three status hues | Plus a success hue for content only | "42 passed" and added lines need a positive colour that is not a status |
| §6 Typography: fixed UI sizes 11–13 | Plus a reading size 14/22 for Claude's prose and your messages, adjustable 13–15 | Long answers read like a document; the rest of the UI keeps today's sizes |
| §6 Shape: concentric radii, panel 10 ≥ card 10 ≥ search 8 ≥ control 6 | Nested surfaces stay concentric; floating surfaces take their own radii (composer and palette 14, pinned cards 12) | A floating surface is not nested in its panel's corner |
| §6 Header: transparent, no divider | A hairline under the header and the inspector tabs | The stream scrolls under the header; the line keeps it from blending |
| §6 Header (D-53): pill, chip, control group | Adds the Chat \| Terminal switch and an inspector toggle before Stop and ⋯ | The face and the inspector are per-session controls |
| D-34: no right sidebar | One inspector on the right, closed by default, remembered per session | Side chat, subagents, changes and tasks beside the work, not in its place ([decision 4](#10-decisions-for-the-user)) |
| §2.4: the card's second row is the branch | A reason line; the branch stays in the session header (D-53) | "What does it want" beats "which branch" at a glance ([decision 8](#10-decisions-for-the-user)) |
| §6 Status language | Unchanged, plus: anything that waits on you is also pinned above the composer | Principle 4 |

## 7. Release plan

The order puts value first and the engine behind its spikes. v2.0 needs no new engine and makes today's Terminal face feel like the new app. v2.1 builds the renderer read-only first, then the live engine.

| Release | Goal | Contents | Size |
| --- | --- | --- | --- |
| **v2.0 "Studio shell"** | The new app around today's terminal | Night Fleece 2 tokens; sidebar v2 (Home row, reason lines, one-line project rows); Home; command palette (sessions and actions; transcript search if the corpus measurement fits); new-session sheet and presets; project page; the inspector frame with Overview and Agents (today's subagent transcript moves there); context ring and plan pace from data Loom already reads; the first pass's status fixes (background tasks, `idle_prompt`, "Why this status?") | ~5–6 weeks |
| **v2.1a "Read"** | Every session readable as chat | `TurnModel`, `TranscriptLens` and the stream renderer; the read-only Chat view for stopped and terminal sessions; the "+N −M" changes card from the turns' edit records (Loom has no diff data before the renderer); markers, folding, density and views; budgets S4 and S7 as tests | ~4 weeks |
| **v2.1b "Chat"** | The live Chat face | `StdioProcess`, the decoder, `ControlChannel`, `ChatSessionDriver`; the composer with queue, drafts, `/` and `@`; pinned approvals, questions and plans; mode, model and effort chips; switching faces; the switch and drift signals. Chat becomes the default only after the user has tried it ([decision 1](#10-decisions-for-the-user)) | ~6–8 weeks after S1–S3 |
| **v2.2 "Review and aside"** | Review where the time goes; the side thread | Changes tab with scopes and line comments; Rewind files; side chat as a fork plus the quick question; subagent requests surfaced on the parent | ~5–6 weeks after S6 and S8 |
| **v2.3 "Flow"** | Tracks by need | Tickets in more places, PR and CI chip, optional worktrees, read and wait verbs for agents (the D-46 channel stays undated), Remote Control toggle, actionable notifications | 1–3 weeks each |

About five to six months to v2.2 at the pace of earlier rounds; agent runs may compress it, but the user's eyes and the spikes set the pace.

## 8. Spikes

All real-Claude work runs in an isolated `CLAUDE_CONFIG_DIR` with a throwaway working directory, never the real `~/.claude`. Logging that profile in is the user's own action. Measurements of the window and CPU wait until the user says the Mac is idle.

| Spike | Decides | Turns | Before |
| --- | --- | --- | --- |
| **S1 Wire test** | The brief's 15 questions: whether `-p` and `stdio` are needed, which session-state switch works, `init` timing and capabilities, ExitPlanMode's input and the mode after allow, hooks and registry under `-p`, `priority` behaviour, stdin closing during a request, error categories as drift signals | ~70 | v2.1b |
| **S2 Switching faces** | Handover order, transcript continuity both ways, mode and effort carried, hooks after a switch, what the CLI's `/resume` picker shows | ~30 | v2.1b |
| **S3 Resources** | Memory and idle CPU of a mid-session `-p` child against the TUI, at three session lengths; spawn and resume latency; cache reads after resume. This is the go or no-go for Chat as the default | ~30 | v2.1b |
| **S4 Rendering budget** | Synthetic streams through `loom-fake-provider` (no real turns): token rate, large outputs, long markdown, hidden windows; CPU and memory against §5.7 | 0 | v2.1a ships |
| **S5 Terminal approvals** | Whether a held PermissionRequest hook can answer for the TUI without racing its dialog | ~20 | answering terminal sessions' requests from Loom |
| **S6 Fork and side question** | Whether a fork with the same model and tools reuses the main session's prompt cache (the first question should be mostly cache reads); how edits are refused in a fork; `side_question`'s shape and side effects; fork residue and deletion | ~30 | v2.2 |
| **S7 Transcript fixtures** | Record types and sizes, compaction, `/clear` and rewind ids, cold open of at most ~1.5 MiB, a 50–100 MB synthetic transcript | from S1/S2 sessions | v2.1a |
| **S8 Rewind** | `rewind_files` with checkpointing and replay; the accuracy of a dry run; what Bash and subagent edits leave untouched | ~20 | v2.2 |

The budget is about 200–300 short turns in total. A budget of this size needs the user's approval (D-04).

## 9. Risks

| Risk | Likelihood | Effect | Mitigation |
| --- | --- | --- | --- |
| Billing for `-p` changes again | Medium | Chat-face use might leave plan limits | The switch, drift signals, a re-read before each release; the Terminal face always works |
| Protocol drift: stream-json is typed in the SDK but not described in prose, and some parts (`stdio` permissions, `side_question`) are bundle-only. Claude Code shipped 26 releases in the 30 days before 17 Oct | Medium–high | A feature breaks after a CLI update | A decoder that passes unknown records through; capability and version checks from `system/init`; fixtures per CLI version; today's drift detection (D-45) extended; the PreToolUse-hook fallback for approvals; Terminal as the way out |
| Memory per live Chat child is larger than the TUI's | Unknown | Many live sessions strain the Mac | S3 first; it replaces the TUI process; stopped sessions cost nothing; an opt-in idle stop ([decision 7](#10-decisions-for-the-user)) |
| Engineering size: the largest change since CP5 | High | A long wait for the main feature | v2.0 ships value without the engine; v2.1a ships the renderer alone; every slice sits behind its spike |
| Two owners, or a lost turn during a switch | Low–medium | Interleaved transcript or lost work | The existing same-session guard, the ordered handover, the verified scope drain, S2 |
| Hooks behave differently under `-p` | Medium | Gaps in sidebar status | S1; the driver feeds the hub from the stream where hooks are silent |
| Chat lacks a TUI feature (vim mode, unmodelled dialogs, `/login`, agent teams) | Certain | Some tasks need the terminal | Terminal-only commands are marked; "Continue in terminal" is one click; Loom declares only the dialog kinds it models |
| `-p` sessions are hidden from the CLI's `/resume` picker | Certain | A plain terminal does not list Chat sessions | They resume by id; Loom's "Copy Resume Command" already gives it |
| A long session renders slowly | Medium | Jank, memory | S4 and S7 budgets as tests; virtualization; caps |
| An approval is answered by accident | Low | An unwanted command runs | Return never approves, Esc never denies; "for this session" never writes settings files |
| New tokens break contrast tiers | Low | Unreadable text | The contrast table in §6.1 as `LoomThemeTests` cases |

## 10. Decisions for the user

Each lists options; the first is the planner's recommendation.

1. **Default face for new sessions.**
   - (a) Chat, with a per-project override and the switch. It becomes the default only after v2.1b passes S1–S3 and you have used it for a week (recommended).
   - (b) Terminal by default, Chat on demand.
   - (c) No live Chat face, only the read-only Chat view.
2. **Policy exposure.**
   - (a) Accept it for the Chat face with the switch, the drift signals and a re-read before every release (recommended).
   - (b) Read-only Chat view and terminal only.
3. **Contract wording.** This replaces contract §3 "The real CLI/terminal experience … will be preserved" and DESIGN.md §2.6.
   - (a) Adopt: *"The live session is always the user's own unmodified Claude Code CLI in a process Loom owns, in its terminal or in its structured mode, with one owner at a time. The terminal face is always one click away."* (recommended).
   - (b) Keep today's rule. Decision 1 then becomes (c).
4. **Right side (D-34).**
   - (a) Lift D-34 for one inspector, closed by default and remembered per session, with the tabs Overview, Changes, Tasks, Agents and Side. Its frame ships in v2.0 (recommended).
   - (b) Keep D-34. The side chat and subagents then replace the stream.
5. **Night Fleece 2.**
   - (a) Adopt it with the values you pick in the prototype's controls (proposed: Fleece, glass 0.6, Ink, reading 14, Comfortable) and the rule changes in §6.5 (recommended).
   - (b) The new tokens, but keep two surfaces and today's radii.
   - (c) Keep Night Fleece as it is.
6. **Launch view.**
   - (a) Loom opens on Home; the last session is one click away (recommended).
   - (b) Loom opens on the last session; Home stays in the sidebar.
7. **Idle Chat sessions.**
   - (a) Keep D-38: nothing stops by itself. Offer an opt-in "Stop Chat sessions idle for N hours" in Settings, off by default (recommended).
   - (b) Leave it out.
   - (c) On by default, which amends D-38.
8. **Card reason line.**
   - (a) The card's second row says what the session waits for or did last, and the branch stays in the header (recommended).
   - (b) Keep the branch on the card; the reason goes in the tooltip.
9. **Chat view default.**
   - (a) Normal (settled work folded, thinking as one line), with ⌃O for Thinking and Verbose (recommended).
   - (b) Verbose by default.
10. **Names and keys.**
    - (a) The faces are "Chat" and "Terminal", and the noun stays "session" (the vocabulary rule holds; "Chat" names a face, not a session). Every new shortcut is checked on the Turkish Q layout and against macOS defaults. For example, ⌘; needs Shift there, and Option combinations type characters (recommended).
    - (b) Other labels.

**Facts only you have:**

- GitHub or GitLab for the work repositories.
- One worktree per ticket, or several sessions in one folder.
- The tracker and its key prefixes.
- Whether you run your own statusLine.
- The permission mode you normally use.
- How much memory the Mac has (for S3's limits).

**Spike access:**

- Approve about 200–300 short turns in isolated profiles.
- Log in to the isolated profile yourself.
- Say when the Mac is idle for S4.

## 11. The first pass's decisions, mapped

| First pass ([V2-BRAINSTORM](V2-BRAINSTORM.md#decisions-for-the-user)) | Here |
| --- | --- |
| 1 Product rule | Replaced by decision 3 |
| 2 How far the chat look goes now | Replaced by decisions 1 and 2: the chat is the headline |
| 3 Right panel (D-34) | Decision 4: an inspector frame in v2.0 |
| 4 Side chat shape | Answered by the design: a forked session in the Side tab. It keeps the main session's model and tools so it can reuse the prompt cache, and refuses edits unless you allow them. Closing stops its process; Discard deletes it. The quick question is the CLI's `/btw`. S6 checks the mechanism |
| 5 Stopped sessions' default view | Answered: the Chat view from the transcript, with the last-screen snapshot kept as a fallback when a transcript cannot be resolved |
| 6 Writing into sessions | Answered by the Chat face: input is a documented message with a proven echo. In the Terminal face the user types; no Loom write path |
| 7 Approvals | Native cards in Chat. In Terminal, the CLI answers until S5 passes. Your usual permission mode is still a fact to give |
| 8 Card density and privacy | Decision 8. Notification text that shows content stays behind a switch that is off by default |
| 9 Facts only you have | Unchanged, plus the Mac's memory |
| 10 Cross-session channel (D-43, D-46) | Unchanged. `@session` passes text only; read and wait verbs are in v2.3 |
| 11 Spike budget | Updated to ~200–300 turns |
| 12 Naming | Decision 10 |

## 12. Findings outside the concept

These came up while checking the code. They are not part of v2, and nothing was changed.

1. **`get_usage` scans a week of transcripts on every ask.**
   - **Where:** Loom's plan-limit request omits `skip_behaviors:true` (`Sources/LoomCore/ClaudePlanLimits.swift:189`).
   - **Effect:** per the SDK typings, each request makes the CLI read every transcript touched in the last seven days.
   - **Fix:** one line, plus a fixture update in `loom-fake-provider`. It waits for the user's go-ahead.
2. **A process outside a run scope.**
   - **Where:** `docs/ARCHITECTURE.md` (lines 4–5) says every provider process starts inside a Loom-owned run scope. The plan-limits child is a plain `Foundation.Process` (`ClaudePlanLimits.swift:250`).
   - **Fix:** either record it as a short-lived exception or move it into a scope.
3. **Flags missing from `--help`.**
   - **Where:** `claude --help` on 2.1.300 does not list `--permission-prompt-tool`, `--max-turns`, `--thinking` or `--resume-session-at`, although the docs and the SDK use them.
   - **Effect:** today's capability check reads the help text (`ProviderLaunchProfile.swift:15-28`), so it cannot detect these flags. The Chat engine has to gate them by version.
4. **The first pass's findings still stand.** They cover background tasks keeping a session "under way", the meaning of `idle_prompt`, the outbound cross-session gap, and agent view being disabled. See [V2-BRAINSTORM](V2-BRAINSTORM.md#findings-about-todays-loom).

## 13. Out of scope

- **Codex** stays frozen (D-28, D-46). Its app-server already gives Loom structured events, which leaves room for a Chat face later.
- **Excluded by the first pass's do-not-build list:** an embedded browser, a PTY daemon, a relay or phone app, a kanban runner, a plugin marketplace and per-repository polling.

## 14. Evidence

- **Protocol brief:** [evidence/chat-protocol-20261017.md](evidence/chat-protocol-20261017.md).
  - Sources: SDK 0.3.302 typings and bundle read as text, code.claude.com docs, and Loom's code with file:line references.
  - It includes the policy text and 15 live-test questions.
- **Chat anatomy study:** [evidence/chat-ui-anatomy-20261017.md](evidence/chat-ui-anatomy-20261017.md).
  - Sources: shallow clones read without running anything, docs, and issue threads.
  - It includes the top 15 patterns and the avoid list.
- **Prototype:** [design/v2-studio-preview.html](../../design/v2-studio-preview.html), 12 screens with the design-system controls.
- **First pass:** [V2-BRAINSTORM.md](V2-BRAINSTORM.md), [IDEAS.md](IDEAS.md), [DIRECTIONS.md](DIRECTIONS.md), [products/](products/).
- **Loom code checked for this concept:**
  - `RunScope.swift:354-357` and `loom-run-host/main.c:31` (pipe mode exists);
  - `ProcessSupervisor.swift:282, 344-376` and `ProcessSupervisor+Scopes.swift:93-105` (the supervisor is PTY-typed);
  - `ClaudePlanLimits.swift:94-96, 187-213, 236-322` (stream-json already in use);
  - `loom-fake-provider/main.swift:88-89` (the test double speaks stream-json);
  - `ProviderLaunchProfile.swift:110-166` (the launch profile).
