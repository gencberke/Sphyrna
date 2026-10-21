# Loom v2 "Studio": plan

**Date:** 17 Oct 2026 · **State:** building since 17 Oct under [D-60](../DECISIONS.md), on branch `v2`; since 21 Oct the run toward 1.6.0 ([§14](#14-toward-160)) · **Owner:** the planner-reviewer (main session).

**The release is 1.6.0** ([D-83](../DECISIONS.md)), Sphyrna's first stable release; today's code is its 1.5.0 pre-release. Where an earlier section says 1.5.0, read 1.6.0.

**Authority.** [D-57](../DECISIONS.md): the user accepted the v2 concept overall and asked to start planning v2, with five points:

1. A new design for the new-session screen.
2. Glass and Solid as a sidebar setting.
3. Chat first, with the terminal expected to become unnecessary.
4. Inherit the chat from a product that does it well; T3 Code is the reference.
5. Codex planning after v2.

[D-58](../DECISIONS.md) adds a sixth point: the composer bar takes the look of Codex's.

**Inputs:**

- [Concept](v2-research/V2-CONCEPT.md) and its prototype (`design/v2-studio-preview.html`, in git).
- New-session options (`design/v2-new-session-preview.html`, in git), for the user's pick.
- [Chat behaviour spec](v2/CHAT-SPEC.md), which sets out what Loom inherits from T3 Code.
- Evidence:
  - the [Loom code map](experiments/v2-planning-scans/loom-code-map-20261017.md);
  - three T3 Code studies: the [timeline](v2-research/evidence/t3code-timeline-20261017.md), the [composer](v2-research/evidence/t3code-composer-20261017.md) and the [shell](v2-research/evidence/t3code-shell-20261017.md);
  - the [protocol brief](v2-research/evidence/chat-protocol-20261017.md) and the [chat UI anatomy](v2-research/evidence/chat-ui-anatomy-20261017.md).

## 1. Goal

Make Loom the user's main development app. Every session becomes a native chat over the real Claude Code CLI, inside a fuller and calm app, drawn in Ink since 20 Oct ([D-74](../DECISIONS.md), §13; it replaced Night Fleece 2). Loom keeps what makes it Loom:

- light;
- honest about status;
- owning exactly the processes it starts;
- costing nothing for a stopped session.

The terminal stays as a fallback until the chat has proven it unnecessary (D-57 point 3).

## 2. What changed against the concept

| Concept | Plan | Why |
| --- | --- | --- |
| Chat and Terminal as two equal faces, switched in the header | **Chat first.** After Release B new sessions start in Chat. Since [D-69](../DECISIONS.md) (1) the face is one app-wide switch, Settings → General → "Sessions run in", and no session moves between faces from its header or menu; the terminal stays as a face ([§9](#9-decision-points-for-the-user) item 7) | D-57 point 3. The terminal code stays because it is the policy fallback and covers what the chat does not model (vim mode, `/login`, unmodelled dialogs) |
| A modal new-session sheet | **A draft session (N1)**, chosen in [D-59](../DECISIONS.md): an empty chat that asks "What should we work on in [project]?", with the session's own composer, one strip for the branch, presets, ticket detection with the duplicate check, and defaults remembered per project. The options' preview kept the quick launcher (N2) and the inline sidebar field (N3) for reference; neither is planned | D-57 point 1. N1 follows T3 Code's draft flow ([shell study §1](v2-research/evidence/t3code-shell-20261017.md)) and fixes T3's known gap there: defaults that depend on the entry point (T3 #6508) |
| Sidebar glass 0.6, 0.86 or solid | **Settings → General → Sidebar: Glass \| Solid.** Glass is today's 0.6; Reduce Transparency forces Solid. In Ink, [D-81](../DECISIONS.md) moves it to Settings → Theme → Sidebar, Solid by default and Glass at 0.8 | D-57 point 2 |
| Chat rules from the anatomy study | **[CHAT-SPEC](v2/CHAT-SPEC.md)**: concrete rules taken from T3 Code's code (fold conditions, work summaries, the scroll latch, the live activity row, composer and card behaviour), adapted to the stream-json wire and native views | D-57 point 4 |
| The composer and card keys of [concept §5.4–§5.5](v2-research/V2-CONCEPT.md#54-the-composer) | Kept: ↵ sends into the running turn and ⌘↵ waits for the turn's end. Added: Esc interrupts only when no card waits; a 1.5 s typing guard; the driver never answers a request by itself; every answer leaves a line in the stream | T3's lessons ([CHAT-SPEC → Composer](v2/CHAT-SPEC.md#composer)): its steer cancels running tools, so T3 queues on Enter; its plan-mode bug #15503; its typing guard |
| "+N −M" changes chip in v2.0 from data Loom already reads | A changed-files card from the renderer's edit records (Release A, V13), with no git process. The Changes tab (Release C) uses git | The code map found no diff data today ([code map §4](experiments/v2-planning-scans/loom-code-map-20261017.md)) |
| Releases v2.0, v2.1a, v2.1b, v2.2, v2.3 | **Releases A, B, C, then tracks**, with engine work running beside the shell from the start ([§4](#4-waves)) | The user's priority is the chat, so its core starts in wave 1 instead of after the shell |
| A composer bar of chips with boxes, a separate `@` and `/` button, and the context as a percentage | **The bar after Codex's:** + (files, images, `@`, `/`), the mode as plain text, the context ring, the model with its effort, a round Send. No mode gets a warning colour, Full access included. [D-63](../DECISIONS.md) replaced this: each mode has an icon and its own colour (V24) | [D-58](../DECISIONS.md): the user likes Codex's composer bar |
| — | **Codex planning after v2** ([§8](#8-after-v2-codex)) | D-57 point 5 |

## 3. Releases and slices

Slice ids are V01–V26; V24 to V26 came from the user's feedback of 18 Oct ([D-63](../DECISIONS.md)). Releases A, B and C are milestones on `v2`, each evaluated; Loom v2 ships once as 1.6.0, when Releases A, B and C, the Ink revision, the chat-performance slice and Remora (Lombot until D-77) are stable and the build meets D-83's three goals ([D-68](../DECISIONS.md), [D-70](../DECISIONS.md), [D-77](../DECISIONS.md), [D-83](../DECISIONS.md), §14). The concept's spikes keep their names S1–S8; S0, the recording day, and S9, the Ask mode, are added here ([§6](#6-real-claude-budget)). Write areas are summaries; each Brief names exact files. The sizes are the planner's estimates.

### Release A: Studio shell and the read-only Chat view

The app around today's terminal sessions: the new look, Home, palette, new-session draft, inspector, project page, context and pace. Every session's history becomes readable as chat, including a running terminal session.

| Slice | Delivers | Write area (summary) | Depends on | Done when |
| --- | --- | --- | --- | --- |
| **V01 Tokens** | Night Fleece 2 tokens ([concept §6.1](v2-research/V2-CONCEPT.md#61-tokens)); the Glass \| Solid setting with a dynamic tint | `LoomTheme.swift`, new `LoomTheme+*.swift`, `scripts/check-theme-literals.sh` (exempt `LoomTheme*.swift`), `UIPreferences.swift`, `SettingsView.swift` (General row), `SidebarBackground.swift` | — | `LoomThemeTests` cover every new pair and the four §6.1 rules; the guard passes; today's surfaces look the same apart from the token shift; screenshots match the prototype's system board |
| **V02 Shell seams** | `DetailContent` becomes a computed route in its own file; the inspector container (SwiftUI inside the panel); the panel fill moves into the content branches; `CatalogModel` sub-model holders; `installMenus` split into an extension; a launch-view preference | `DetailView.swift`, new `DetailRoute.swift`, `CatalogModel.swift` (holders only), `AppDelegate+Menus.swift`, `UIPreferences.swift` | V01 | No visible change; all suites pass; the restored selection does not override a Home launch |
| **V03 Reason data and status truth** | The hub carries a reason that changes only at hook boundaries. It covers the tool and a command summary for approvals, the question header, "Plan ready", the first line of the last message, and failure details. Plus the first pass's fixes, with the details [S0](experiments/v2-spikes/S0-hooks-20261017.md) recorded: work counts from `Stop.background_tasks` (`shell` and `subagent`), so a Stop with tasks left means "turn done, work running"; a turn whose prompt starts with a task notification is automatic, not the user's; "needs you" comes from `PermissionRequest`, because `Notification` is late or missing and `idle_prompt` (60 s) is only a reminder; a `SubagentStop` with no start and an empty `agent_type` is ignored; Esc on a dialog fires no hook, so an approval also needs a second signal to clear (the registry status or the transcript's tool result) | `ClaudeHook.swift`, `ProviderSessionAdapters.swift`, `SessionEventHub.swift`, tests | S0 recordings | Payload fixtures from S0 pass; content never reaches logs; notifications show content only behind the off-by-default switch; equality still suppresses unchanged publishes |
| **V04 Sidebar v2** | Home row with its count; Active cards with the reason line; one-line project rows; the "Sessions" group kept. From the batch 1 review: `SidebarBackground` takes `model.sidebarStyle`, the `sidebarTransparencyOverride` bridge goes, and the evidence snapshot reports the style on its own. From V03: show a card's reason through a per-card observed property (`row.live?.reason`), keep the reason text out of the evidence snapshot, and add the registry's `status: "shell"` (seen while a background shell runs) to `ClaudeRegistry.knownStatuses` | `SidebarView.swift` (one owner), `SubagentTree.swift`; first extract `ChromeButtonStyle`, `RowButtonStyle`, `KeyboardNavigation` | V01, V02, V03 | `SidebarRenderTests` and `CatalogHotPathTests` budgets hold (reason text changes only at hook boundaries); accessibility labels; stripe geometry; user eye check |
| **V05 Home** | The launch view: Needs you, Finished not read, plan limits with pace, Today, Continue (runs ended by Quit), and the start box (the N1 composer). From V10: draw `usage.paces(at:)` with `PlanPaceLine` on the model's minute tick. From the batch 2a review: the Home route comes before "Add a project", so Home needs its own empty state for an empty catalog | new `Home*.swift`, `CatalogModel+Home.swift`, a `SessionCatalog` query for runs cut by Quit | V02, V03, V07 | No process and no polling; numbers match their sources; empty states in the identity voice |
| **V06 Command palette** | ⌘K: needs you, recent sessions, actions, slash commands; transcript search stage 1 only if the corpus measurement fits | new `Palette*.swift`, a window-level overlay, a menu item | V02 | Every keystroke cancels the previous search; reads are bounded; nothing runs while closed |
| **V07 New session** | The draft session N1 ([D-59](../DECISIONS.md), [CHAT-SPEC → Draft session](v2/CHAT-SPEC.md#draft-session)): the draft with the project in its question, one reusable empty draft per project, the branch strip, presets, ticket detection with the D-40 duplicate check, branch creation on the first send, defaults remembered per project, and `--permission-mode` and `--model` in the launch profile | new `NewSession*.swift`, `ConversationController.start`, `SessionRuntime.startConversation`, `ProviderLaunchProfile.claude`, preset storage | V02 | A draft costs nothing until sent and an empty one is invisible; the first send starts through today's path with the message; the mode always shows and Loom never picks Full access; flags not listed in `--help` are gated by version, not by help text |
| **V08 Project page** | Sessions with their last line, presets, branches, the week's usage, the project's CLAUDE.md (skills and MCP servers from the last `system/init` once Chat exists) | new `Project*.swift`, a usage query per project | V02, V07 | Reads happen only when the page opens |
| **V09 Inspector and Agents** | The right inspector: closed by default, remembered per session, Overview and Agents tabs. The subagent transcript moves into Agents, so the terminal is no longer replaced | `CatalogModel+Subagents.swift`, `SubagentPanelViews.swift`, `DetailView.swift` header branch, new `Inspector*.swift` | V02 | Obsolete header and back controls removed; opening the inspector over a terminal resizes the PTY once, by the user's toggle only; a change of selection never animates the inspector (batch 1 review). From V10: call `usage.trackContext(sessions:)` for the visible sessions and draw `ContextRing(usage:)` |
| **V10 Context and pace** | Context ring (tokens; a percentage only when the model's window is known) and the plan pace line; `get_usage` sends `skip_behaviors:true` | `ClaudeUsageIndex.swift` (latest main-thread message per session), `UsageModel.swift`, `ClaudePlanLimits.swift`, the ring view | V02 | Fixture tests; no new process; the plan-limit read no longer scans transcripts |
| **V11 Fake provider chat mode** | Scripted stream-json sessions in `loom-fake-provider`. They cover: init, partial text, thinking (including Claude 5.1+ pre-tool thinking), tools and results, subagents, `can_use_tool` (approval, question, plan), interrupt with `cancel_queued`, replay echo, every `result` subtype, `rate_limit_event`, `api_retry`, `compact_boundary`, `conversation_reset`, unknown types and MB-sized lines | `Sources/loom-fake-provider/`, its fixtures | — | The scenarios drive V12–V19 tests with no real Claude |
| **V12 Transcript model** | The new `LoomChat` target with `TurnModel` and `TranscriptLens`; a public main-session transcript reader in `LoomCore` (locator, reverse pager, generic tail) | new `Sources/LoomChat/`, `LoomCore` transcript files, `Package.swift`, `scripts/release/Package.release.swift`, `scripts/release/allowlist.sh`, `scripts/check.sh` | S7 fixtures | Cold open reads the last 10 user turns or at most about 1.5 MiB; unknown records are kept raw; oversized lines are marked, never dropped silently; the same model reads subagent transcripts |
| **V13 Stream view** | The renderer from [CHAT-SPEC](v2/CHAT-SPEC.md): rows, folds, markdown and code, dividers, the scroll latch, the Normal, Thinking and Verbose views, and the changed-files card from edit records. It is the read-only Chat view for stopped sessions (the D-54 snapshot stays as the fallback) and a live-tailing view for running terminal sessions | `Sources/LoomCatalogUI/Chat/`, `DetailRoute.swift` cases | V02, V12 | S4 budgets pass as tests; long transcripts stay smooth; user eye check |

### Release B: the live Chat

Gate in: spikes S1–S3 passed. Gate out: Release B's evaluation; [D-69](../DECISIONS.md) (4) dropped the week of use.

| Slice | Delivers | Write area (summary) | Depends on | Done when |
| --- | --- | --- | --- | --- |
| **V14 Pipe plumbing** | Pipe children in the run scope (`SPAWN_STDIO`); a `PipeEndpoint` beside `TerminalEndpoint`; the supervisor launch generalised; verified Stop and Quit | `ProcessSupervisor.swift`, `ProcessSupervisor+Scopes.swift`, new `PipeEndpoint.swift`, `ManagedSession.swift`, `SessionRuntime.swift` | — | Ownership tests with `loom-test-child`; the PTY path unchanged; dormant until V16 |
| **V15 Protocol** | `StreamJSONDecoder` (MB lines, unknown types passed through) and `ControlChannel` (request table, cancels both ways, timeouts, capability checks) | `Sources/LoomChat/Protocol/` | V12 (target) | Contract tests on V11 scenarios and S1 recordings |
| **V16 Chat driver** | `ChatSessionDriver`. It spawns and resumes with the stream argv, correlates replay echoes, owns the queue (kept with the session; paused by an interrupt, a failure or a relaunch), interrupts, sets mode, model and effort, and feeds status to the hub. Also: the registry bypass for `-p` children, interrupt-then-close in the stop hooks, drift detection, and the policy switch. [S1 §D](experiments/v2-spikes/S1-wire-20261017.md#d-corrections-to-the-plan-and-spec) sets the details: Ready on the `initialize` response, delivery from `command_lifecycle`, `--thinking-display summarized`, mode and effort passed on every spawn, and a pipe Stop grace long enough for the interrupt's `result`. [S2](experiments/v2-spikes/S2-handover-20261017.md) adds: model, mode and effort on every spawn, the terminal's `--resume` included, with the same model in both faces; a face switch during a turn or with a card waiting is tested here. From the batch 1 review: the driver tells `TurnModel` when Loom sent the interrupt, so a `now` send that cuts a stream never reads "You stopped", and it ends a running turn when the process dies. The fake still orders three things unlike the CLI (`can_use_tool` before its message's `message_stop`, `rate_limit_event` after the first message, an extra text block before tools); V16 aligns them where its tests depend on order. From V10: feed `setContextWindow` from each `result.modelUsage.<model>.contextWindow`; windows are keyed by the canonical model id, so a 1M variant needs a key of its own. From the Release A architecture review: mode, model and effort live per session in the catalog, written by the runtime and read on resume in both faces (not in the UI's `new-session.json`); a run-endpoint kind (terminal or pipe) replaces "has a terminal view" as the meaning of running; the driver's owner is an app-made holder outside `CatalogModel`, and pipe starts go through `startConversation`'s guards; pending requests get a provider-independent summary in LoomCore. From S8: `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` on every Chat spawn | `Sources/LoomChat/Driver/`, `ProviderLaunchProfile.swift`, `SessionRuntime+Claude.swift`, `ClaudeRegistry.swift` | V03, V11, V14, V15, S1–S3 | Every [concept §5.6](v2-research/V2-CONCEPT.md#56-lifecycle) transition is tested on the fake provider; the real-Claude acceptance passes ([§6](#6-real-claude-budget)) |
| **V17 Composer** | The bar after Codex's ([D-58](../DECISIONS.md), [CHAT-SPEC → The bar](v2/CHAT-SPEC.md#the-bar)), input semantics, the send button, the queue strip (edit, reorder, send now, resume), drafts, history, the `/` and `@` menus, attachments, the mode, model and effort chips, the context ring popover and delivery states ([CHAT-SPEC](v2/CHAT-SPEC.md#composer)) | `Sources/LoomCatalogUI/Chat/Composer*` | V13, V16 | Return and Esc rules hold; nothing is lost on interrupt, crash or Quit; key equivalents checked on the Turkish Q layout; the stream's row builder is incremental before live deltas arrive every 50 ms (V13 rebuilds every row per delta: 235 ms in debug at about 21k rows); the chat model is split into a source that sends deltas (transcript or driver) and a presentation model kept per session, built with the incremental rows |
| **V18 Pinned cards** | Approvals, questions and plans above the composer, one at a time with a counter, folded to one line when answered; Home, the sidebar, the Dock badge and notifications see them | `Sources/LoomCatalogUI/Chat/Pinned*`, `ApprovalNotificationPlanner` | V16, V17 | Return never approves and Esc never denies; the driver never answers a request by itself, in any mode; a card that arrives while you type never takes your text; a card retires only on its own `tool_use_id`; answering through Loom equals answering in the CLI; the cards read the provider-independent pending-request summary V16 adds |
| **V19 Chat first** | Chat as the default face; "Continue in Terminal" and "Continue in Chat" in ⋯ with the ordered handover; Settings → "New sessions start in"; face-aware focus and menu keys; a composer on stopped Chat sessions; one banner for the policy signal and drift. From [D-63](../DECISIONS.md): a "New session" row under Home in the sidebar opens the draft in the last used project; the start box leaves Home; a request reads the same in both faces. [D-69](../DECISIONS.md) (1) later took the moves out of ⋯ and made the face one app-wide switch (§12, fix round 3) | `ConversationController.swift`, `SessionHeaderViews.swift`, `SettingsView.swift`, `SessionRuntime.swift`, `SidebarView.swift`, `Home*.swift`, `StatusReason.swift` | V13–V18 | Handover never runs two owners and never loses a turn; the switch moves every new session to the terminal; the owning face is the runtime's persisted fact, not a view flag |
| **V24 Chat bar** | From [D-63](../DECISIONS.md): only Loom's modes, Ask, Ask before edits, Accept edits, Auto and Full access, each with an icon and a colour; no "Claude's default" (a new session starts in its project's last mode, else Ask before edits); Ask's backend from spike S9; a model popover and an effort slider after Codex's, in the draft and the live composer. Plus the V17 and V18 checkpoint follow-ups ([§12](#release-b-18-and-19-oct)) | `Sources/LoomCatalogUI/Chat/Composer*`, `NewSessionDefaults.swift`, `NewSessionComposer.swift`, `ClaudePermissionMode`, the driver's mode switch, `LoomTheme+Composer.swift`, the fake provider | V17, V18, S9 | The menus have no "Claude's default" and no Plan; Ask changes nothing, on the fake provider and in the acceptance on the real CLI; live mode, model and effort changes go through the driver; each follow-up has a test |
| **V25 Look** | From [D-63](../DECISIONS.md): a Codex-like rounded highlight on hover and selection across the app; a spacing pass; Home's usage made compact and readable | the shared row and button styles, `LoomTheme*.swift`, the sidebar, palette and Home views | V19, V24, V26 | Every value is a token; hover and selection read the same on every list; screenshots in both themes; user eye check |
| **V26 Themes** | From [D-63](../DECISIONS.md): Settings → Theme with Dark, Light and Match system, three tones for the main pane (the panel values of the three identity directions of the identity proposal) and the sidebar's Glass or Solid; a cozy light theme over every surface except the terminal face, which stays dark because the CLIs draw for a dark background | `LoomTheme*.swift`, `TerminalTheme.swift`, `UIPreferences.swift`, `SettingsView.swift`, the colour-scheme sites | built beside V19 and V24, merged after them | `LoomThemeTests` hold every contrast rule in both appearances and every tone; switching is live; screenshots of every surface in both; user eye check |

### Release C: review and aside

Gate in: spikes S6 and S8. C0 comes first; then V20 to V23 run one at a time, in order ([D-71](../DECISIONS.md)).

| Slice | Delivers | Depends on |
| --- | --- | --- |
| **C0 Driver split** | `ChatSessionDriver` split into one extension file per cluster (lifecycle, handover, sending, requests, mode, queue, ingestion). The handover's five flags become one state. One place where a request becomes a card, the seam for V22's policy and V23. No behaviour change. Both Release B reviews asked for it at the start of Release C | — |
| **V20 Changes tab** | Scopes (last turn, session, branch), diffs from edit records and git, line comments sent as one message | V13, V16 |
| **V21 Rewind files** | `rewind_files` with a dry run first and an honest label. From [S8](experiments/v2-spikes/S8-rewind-20261018.md): the action is on user messages ("Rewind files to before this message"); the dry run is the confirmation sheet and says that Bash and subagent changes stay; Loom lists files the user changed since Claude's last write and copies them aside for Undo; off while the session works or waits; checkpointing is on from the first turn (V16 sets the env var) | V16, S8 |
| **V22 Side chat** | A forked session in the Side tab (same model and tools, edits refused unless allowed, Discard through verified deletion) and the quick question. From [S6](experiments/v2-spikes/S6-fork-20261018.md): ⌘; is `side_question`, not a fork; the fork spawns with `--fork-session --permission-mode default` and Loom denies edits in `can_use_tool`; Loom stores the parent link and Discard removes S6's six items after exit; the Side tab says "Sees the session up to <time>"; forks are listed only under their parent's Side tab (planner default). From [S6b](experiments/v2-spikes/S6b-fork-identity-20261020.md): the fork takes a `--session-id` Loom chooses, so its card holds that id before the spawn and the `"fork"` SessionStart makes no second card; copied records keep the parent's message ids, so usage must not move them to the fork. Built in three parts, one at a time: the quick question; the fork underneath (route, identity, catalog link, hidden lists, the request policy, Discard); the Side tab | V16, S6, S6b |
| **V23 Agents live** | A subagent's request surfaced on its parent; live subagent text | V09, V18 |

### Remora, the Home assistant (Lombot until D-77)

The Home assistant of [D-64](../DECISIONS.md), designed in [LOMBOT-BRAINSTORM](v2-research/LOMBOT-BRAINSTORM.md). Spike S10 first, then L1 Core (the pack builder and the call runner), L2 Memory and L3 UI (§8 of the brainstorm). It depends on V19, V24 and V25, and comes after Release C, when the UI has settled further ([D-68](../DECISIONS.md)); the order puts its build after the Ink build and the chat-performance slice ([ROADMAP](../ROADMAP.md#order)), and D-83's run takes the spike first, so that its cost is known before the build (§14). [D-77](../DECISIONS.md) renamed it Remora, and [the reference](../design/reference.html#remora) draws it ([D-80](../DECISIONS.md)). Its morning tiles need the read state and Home's reasons kept across a relaunch; today they live in memory only. When it is built, LOOM-PRODUCT-CONTRACT gets a note: Remora's once-a-day call and its bounded, expiring working memory are authorized by the user, and its memory is cleaned when a session is deleted.

### After Release C: tracks by need

- PR and CI chip.
- Worktree management.
- Read and wait verbs for agents (the D-46 channel stays undated).
- Remote Control toggle.
- Actionable notifications.
- Transcript search stage 2.
- N2 or N3 on top of N1, if wanted.

## 4. Waves

Write areas decide what runs in parallel ([code map §5–§6](experiments/v2-planning-scans/loom-code-map-20261017.md)). Hot files have one owner per wave:

- `AppDelegate` menus;
- `Package.swift` and the release manifest;
- `SidebarView.swift`;
- `DetailView.swift` and `DetailRoute.swift`;
- `CatalogModel.swift`;
- `ProcessSupervisor*`.

| Wave | Slices (parallel inside a wave) | Gate to the next wave |
| --- | --- | --- |
| 0 | Spikes S0, S1–S3 (real Claude, isolated profile) · V11 fake provider chat mode | S0 recorded; V11 accepted |
| 1 | V01 Tokens · V03 Reason data · V12 Transcript model (owns `Package.swift`) · V14 Pipe plumbing · V15 Protocol (after V12's target lands) | each slice accepted |
| 2 | V02 Shell seams first, then in parallel: V04 Sidebar v2 · V05 Home · V06 Palette · V07 New session · V08 Project page · V09 Inspector · V10 Context and pace · V13 Stream view (menu items serialised in `AppDelegate+Menus.swift`) | Release A evaluation ([§7](#7-evaluation-per-release)) |
| 3 | V16 Chat driver (S1–S3 passed) · then V17 Composer · V18 Pinned cards · then V19 Chat first · V24 Chat bar · spike S9 · V26 Themes · then V25 Look | Release B evaluation ([D-69](../DECISIONS.md) (4) dropped the week of use) |
| 4 | Spikes S6, S8 · C0, then V20 · V21 · V22 · V23, one at a time (D-71) | Release C evaluation |

Critical path to the live chat: S1–S3 and V11 → V12 → V15 → V16 → V17 → V18 → V19.

The shell (V01–V10) is off that path, so Release A can ship while the engine is still being built.

## 5. Protocol for every implementer slice

This is the same protocol as [run 1](RUN-1.md#protocol-for-every-implementer-slice), with these settings:

- **Worktree.** Each implementer has its own git worktree at `~/Library/Caches/loom-v2/wt/<name>`, detached at the integration commit named in the Brief, with its own scratch path under `~/Library/Caches/loom-v2/build/`.
  - The implementer never commits.
  - The planner-reviewer reviews the diff, copies it onto the integration branch `v2` and commits one commit per accepted slice, under [D-60](../DECISIONS.md). Slices one implementer built together share a commit.
  - No push, PR, merge, rebase, tag or history rewrite.
- **Build slot.** Every build, test, package or measurement runs through `scripts/with-build-slot.sh`. Each slice gets its own scratch path under `~/Library/Caches/loom-v2/`. Builds never run in parallel ([D-13](../DECISIONS.md)).
- **Tests.**
  - Narrow suites for the change.
  - A regression test must fail without its fix.
  - Window tests and the full suite run only when the user says the Mac is idle.
  - One named owner runs the full suite on the combined tree.
- **User data.** These are never touched: the real `~/.claude` and `~/.codex`, the installed apps, the default dev catalog. Real-Claude work runs only in isolated profiles.
- **Design rules.** A slice that needs a rule change lists it under Needs. The concept's rule changes ([§6.5](v2-research/V2-CONCEPT.md#65-rule-changes-against-designmd)) go into `design/DESIGN.md` in the slice that builds them, under D-57's defaults; the user sees them at the release check.
- **Porting from T3 Code.** Rules marked [attribute] in [CHAT-SPEC](v2/CHAT-SPEC.md) get a comment naming T3 Code (MIT, Copyright 2026 T3 Tools Inc.). No T3 code or assets are copied as is.
- **Report:** Status / Result / Evidence / Unverified / Needs / Doc impact, plus the worktree path and the commands run.

## 6. Real-Claude budget

All real-Claude work runs in an isolated `CLAUDE_CONFIG_DIR` with a throwaway working directory. The working directory lives outside `HOME`: under `HOME`, the CLI also loaded the real `~/.claude/CLAUDE.md`, read only, as an ancestor folder's project memory ([S0](experiments/v2-spikes/S0-hooks-20261017.md)). Logging that profile in is the user's own action. Turns use Haiku unless the spike measures something model-specific.

| Use | Turns | When |
| --- | --- | --- |
| S0 recording day: hook payloads for V03 (PermissionRequest inputs, Notification text, Stop's last message, `background_tasks` types, `idle_prompt` timing) | ~30 (15 used) | wave 0 |
| S1 wire test: the 15 questions in the [protocol brief](v2-research/evidence/chat-protocol-20261017.md) and the 8 in [CHAT-SPEC](v2/CHAT-SPEC.md#questions-added-to-spike-s1) | ~80 (78 used, [S1 §F](experiments/v2-spikes/S1-wire-20261017.md#f-turn-ledger)) | wave 0 |
| S2 handover between the two faces | ~30 (12 used) | wave 0 |
| S3 resources: child memory and CPU against the TUI; resume latency and cache | ~30 (62 used; 40 built the long sessions) | wave 0 |
| Release A check (`claude_real.py`) | ~4 (2 used) | end of wave 2 |
| V16 driver smoke: Ready, delivery, interrupt, Stop, resume | 8 used, from the reserve | wave 3 |
| S9 Ask mode: the candidate flags and rules, Bash, the live switch; S9b: web tools, subagents, the user's allow rules | 18 used (S9 12, S9b 6), from the reserve | wave 3, 18 Oct |
| Release B acceptance: send, queue, interrupt, approve, question, plan, handover, stop, resume | ~20 | end of wave 3 |
| S6 fork and quick question; S8 rewind | ~50 (56 used: S6 36, S8 20) | wave 4, run early on 18 Oct |
| S6b a fork's identity and subagent hooks under `-p` | 5 used, from the reserve | wave 4, 20 Oct |
| Release C slices' own checks: V21 up to 4; V22's parts up to 2 (and 2 quick questions), 4 and 3; V23 up to 3 | up to 16, from the reserve (used: V21 18, 16 of them by a suite filter that matched every real test; V22 2 turns and 2 questions, 4 and 3; V23 1) | wave 4 |
| Release C check | ~10 (planned 12 + 2 quick questions; used 17 turns and 6 quick questions, within the user's allowance, D-72 (4); R4 passed again on 371aaf6) | end of wave 4, 20 Oct |
| S10 Remora's call (Lombot's in the brainstorm): flags, residue, traffic, memory files, latency ([LOMBOT-BRAINSTORM §7](v2-research/LOMBOT-BRAINSTORM.md#7-before-building-spike-s10)) | ~10, Sonnet 5.5 and Haiku 5.5 (15 used: 11 Haiku, 4 Sonnet; `evidence/core/s10/S10-REPORT.md`) | 21 Oct, on the core track, before Remora's build |
| Reserve | ~30 | — |
| **Total** | **~285** | |

A ledger like [run 1's](RUN-1.md#real-claude-budget) records every use.

## 7. Evaluation per release

Run 1's [stage-end recipe](RUN-1.md#stage-end-evaluation-recipe) applies to each release, with these additions:

- **Budgets as tests.** The chat budgets from [concept §5.7](v2-research/V2-CONCEPT.md#57-performance-budgets) run as tests: synthetic streams through the fake provider and a 50–100 MB synthetic transcript.
- **Screenshots.** UI evidence screenshots of every new surface at 1220×780 and 780×500.
- **Optimizer review.** It runs before each release closes ([AGENTS.md](../AGENTS.md#checkpoint-closure)).
- **Release checklist.** Each release re-reads the [support article](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) on SDK and `-p` use, from Release B on.
- **Stage R.** Its remaining items fold into these checks, if the user agrees ([§9](#9-decision-points-for-the-user) item 5):
  - first-run and empty states go to Home;
  - crash and Force Quit guarantees go to V14 and V16;
  - resource budgets (O-01) go to the chat budgets;
  - the release checklist applies to every release.

## 8. After v2: Codex

Planning Codex is the extra step after v2 (D-57). Codex stays frozen until then (D-28).

Starting points:

- the [Codex backlog](cp5/CODEX-BACKLOG.md);
- Loom's existing per-session Codex app-server;
- the T3 Code [shell study](v2-research/evidence/t3code-shell-20261017.md), which traces how T3 drives Codex's app-server (thread and turn methods, approvals, events).

The Chat face's driver and renderer are built provider-neutral where that costs nothing: the turn model, the cards and the composer. Codex can then get a Chat face without a second UI.

## 9. Decision points for the user

1. **New session:** decided. New sessions start as the draft session N1 ([D-59](../DECISIONS.md)).
2. **Build authority:** decided ([D-60](../DECISIONS.md), [D-61](../DECISIONS.md)). It was asked as follows (as D-30 did for run 1):
   - an integration branch `v2`, cut from today's `swarm/1`;
   - one commit per accepted slice;
   - worktrees under `~/Library/Caches/loom-v2/`;
   - no push, PR, merge or tag.
   - Also say whether the Mac counts as idle for the run or only in windows you name.
3. **Real-Claude budget:** decided. The budget is open, Haiku in the isolated profile ([D-60](../DECISIONS.md)), and a release's check may spend more than planned ([D-72](../DECISIONS.md) (4)). The plan's estimate was about 285 short turns in isolated profiles (§6), and you log the isolated profile in yourself.
4. **Releases and versions:** decided. Loom v2 ships once as 1.5.0, when Releases A, B and C, the Ink revision, the chat-performance slice and Remora are stable, through the clean loom path ([D-68](../DECISIONS.md), [D-70](../DECISIONS.md), [D-77](../DECISIONS.md), [D-41](../DECISIONS.md)). [D-83](../DECISIONS.md) makes it 1.6.0, the first stable release, accepted against three goals (§14).
5. **Stage R:** decided. It folds into 1.5.0's evaluation ([D-68](../DECISIONS.md), [D-69](../DECISIONS.md)).
6. **Facts only you have:** answered in [D-69](../DECISIONS.md) (8): GitHub and Bitbucket; worktrees for general users; no tracker keys in the general product; 16 GiB. The questions were:
   - GitHub or GitLab;
   - one worktree per ticket or several sessions in one folder;
   - tracker and key prefixes (V07 uses them);
   - whether you run your own statusLine;
   - your usual permission mode;
   - the Mac's memory.
7. **After Release B:** decided. The terminal stays as a face, chosen by one app-wide switch in Settings; the per-session move leaves the header and menu ([D-69](../DECISIONS.md)).
8. **Concept defaults:** decided. They stand, except that Settings names the default permission mode (Full access included) and cards keep the branch; the contract wording is adopted ([D-69](../DECISIONS.md)). The defaults were:
   - one inspector (D-34 lifted);
   - Home as the launch view;
   - the reason line in place of the branch on cards;
   - idle stop stays off (D-38);
   - Normal view by default;
   - while Claude works, ↵ sends into the running turn and ⌘↵ waits for the turn's end (T3 Code does the reverse; [CHAT-SPEC → Keys](v2/CHAT-SPEC.md#keys) says why);
   - a new session starts in the mode last used in its project, else Ask before edits (D-63 removed "Claude's default"), and Loom never picks Full access;
   - the contract wording of [concept decision 3](v2-research/V2-CONCEPT.md#10-decisions-for-the-user), recorded at Release B.

## 10. Risks

[Concept §9](v2-research/V2-CONCEPT.md#9-risks) lists the main risks: policy, protocol drift, memory, size, handover, hooks under `-p`, and missing TUI features. Wave 0 settled three of them. A chat child takes about 150 MB of footprint, 15–25 MB less than the terminal, with the same idle CPU ([S3](experiments/v2-spikes/S3-resources-20261017.md)). Hooks fire under `-p` ([S1](experiments/v2-spikes/S1-wire-20261017.md), [S0](experiments/v2-spikes/S0-hooks-20261017.md)). The clean handover works both ways ([S2](experiments/v2-spikes/S2-handover-20261017.md)). The plan adds four:

| Risk | Mitigation |
| --- | --- |
| Native rendering of rich markdown and long transcripts is the costliest part (T3's own scroll bugs: #4668, #16650) | One follow latch measured from the true content bottom; cached row heights; budgets as tests from V13 on ([CHAT-SPEC](v2/CHAT-SPEC.md#scrolling)) |
| Claude 5.1+ writes pre-tool text as thinking blocks (T3 #18355) | S1 found plain text blocks on 2.1.300 with Haiku 5.5, so no promotion rule is built. Fixtures cover both shapes ([CHAT-SPEC](v2/CHAT-SPEC.md#thinking)) |
| A `-p` child trips the registry and hook-silence watchdog | S1 (Q7): the child writes a registry file with `entrypoint:"sdk-cli"` and its hooks fire. V16 keys the bypass on that |
| Scope creep from a large reference app | CHAT-SPEC separates must, should and later; "later" items need the user's word |

## 11. Records

- **Slice Briefs:** `evidence/<slice>-brief.md` under `~/Library/Caches/loom-v2/`, written when each slice starts; `plans/v2/` holds the specs (CHAT-SPEC).
- **Results:** recorded in this file under a Results section per release.
- **Evidence:** spike evidence goes under `plans/experiments/v2-spikes/`.
- **Doc impact by slice:**
  - `design/DESIGN.md` and `design/UI-MAP.md`: V01, V04, V05, V07, V09, V13, V17–V19.
  - `docs/ARCHITECTURE.md`: V12, V14–V16.
  - The contract (§1 purpose, §3 core experience): at Release B, after the user confirms the wording.
- **Drift found while planning** (fixed with the first touching slice):
  - UI-MAP said the sidebar tint is 0.86; the code has 0.6. Fixed in V01.
  - ARCHITECTURE does not list the unscoped plan-limits child and helper spawner as exceptions to "every provider process starts in a run scope". V10 fixes it.

## 12. Results

### Release A

#### Batch 1: wave 0 and the engine core (17–18 Oct)

Branch `v2`, on top of 24d8cfb:

| Commit | Slices |
| --- | --- |
| 3e4d59b | V14 pipe plumbing |
| 8cb089f | V11 fake provider chat mode |
| 90679a1 | V12 and V15, the `LoomChat` engine core |
| 564e2a3 | V01 tokens and V02 shell seams |
| 030563e | Docs and the real-Claude scripts |

- **Spikes.** S0–S3 are done, with evidence in [v2-spikes](experiments/v2-spikes/). Their answers are folded into [CHAT-SPEC](v2/CHAT-SPEC.md) and the rows above. Real-Claude turns so far: about 172 of the ~285 in §6.
- **Reviews.** Both found nothing that needed rework, and both accepted after fixes:
  - UI foundation (V01, V02), fixed:
    - Increase Contrast secondary text is now `#BCC0D0`, at least 7:1 on every surface;
    - two contrast numbers in DESIGN.md;
    - a test that loads 0.4.4 preferences.
  - Engine path (V11, V12, V14, V15), a strict review. Fixed:
    - transcript paging gave duplicate row ids and false "oversized" rows;
    - contract tests were missing; they now run the fake and the S1 recordings through the decoder, channel and model;
    - two places where the fake differed from the CLI;
    - `account` was not stripped from every control response;
    - the decoder's 256 MiB line cap, now 64 MiB;
    - SIGHUP reached pipe children on a mixed Quit;
    - the stdin-close wait had no grace of its own;
    - an early exit lost the child's output;
    - a failed launch leaked its scope.
- **Real data.** The transcript lens read 137 real transcripts from the test profiles. Unknown rows went from 1,190 to 0, with no duplicate ids.
- **Checks.** One full release run (`scripts/check.sh --full --idle`) on the combined tree.
  - The release build and the staged release tree passed.
  - About 1,280 tests ran, with 4 issues:
    - Two pipe tests raced their own child's exit. They are fixed in the tests and pass in release on reruns.
    - A Codex recovery test and a banner-fade timing test fail only under the full run's load. Both pass alone. The Codex suite's flake also exists on 24d8cfb (2 of 40 runs).
- **Isolation.** Real-Claude work dirs now live under `/private/tmp/loom-real`. Under `HOME`, the CLI had also loaded `~/.claude/CLAUDE.md`, read only.
- **Carried to later slices:** see rows V04, V09 and V16.

#### Batch 2a: navigation, reasons, context (18 Oct)

| Commit | Slices |
| --- | --- |
| 2be0022 | V02b navigation seam: destinations, routes, the menu command table (added to the plan to keep the shell slices apart) |
| 767d140 | V03 reason data and status truth |
| 2afbda1 | V10 context and pace |
| e3697c5 | ARCHITECTURE for the three |

- **Review.** Accepted after fixes. One must-fix: a turn the user interrupted could stay "Working", because `idle_prompt` was ignored. The fixes, all made before the commit:
  - The reminder now ends a turn that nothing else ended.
  - `permission_prompt` and the registry back up a lost `PermissionRequest`.
  - A finished card keeps its last line.
  - Pace gives no verdict early in a window and measures at the read time.
  - The new usage index is best-effort.
  - 1M windows are kept apart.
  - Removing a project leaves its page.
- **Real Claude.** V03 replayed four recorded cases (interrupt, Esc on an approval, Esc on a plan, a background shell) through the adapter, using 5 Haiku turns. V10 checked `get_usage` with `skip_behaviors` in 1 turn.
- **Checks.** All test targets passed on the combined tree, except one hook-read timeout in `OpenSessionTests` under load. It passes alone (3 of 3). `SidebarRenderTests` and `CatalogHotPathTests` passed with windows.
- **V13**, the stream view, was reviewed on its own and committed as e8b3430, after fixes:
  - a user message in the middle of a folded turn was dropped;
  - "Show all" could freeze the main thread;
  - the live tail could stay stale after a stop in the middle of a read;
  - the entry view rebuilt its model on every render.

  Budgets on a debug build, with a 60 MB transcript:
  - cold open: 19 ms to the first rows;
  - wheel scroll: p95 6.9 ms;
  - a delta: only the changed rows redraw.

  A delta still rebuilds every row, so V17 makes the builder incremental before live chat.

#### Batch 2b: sidebar, palette, draft, inspector, and the chat route (18 Oct)

| Commit | Slices |
| --- | --- |
| 68bcc64 | V07 the new-session draft N1 |
| 0cdd165 | V06 the command palette, with stage-1 transcript search; also fixes the dead shell menu |
| f20b38a | V04 sidebar v2, with draft rows |
| ec38231 | V09 inspector; stopped sessions open as Chat (V13 routed) |
| a3f867e | Docs, and the two v2 previews in `design/` |

- **Found along the way.** V02b's menu target method `perform(_:)` collided with `NSObject.perform(_:)`, so every new shell menu item was dead. V06 found it. The method is now `runShellCommand`, and a test dispatches each item through AppKit.
- **Integration glue** (one implementer on the combined tree):
  - the chat route (`SessionChatView`, `ChatRouteKey`), with the read-only chat on by default;
  - Show Chat and Show Terminal in the header's ⋯ menu (D-57: no face switch in the header);
  - draft rows in the sidebar;
  - the "+" and project menus go through the draft;
  - a "Search session text" switch in Settings, on by default.
- **Review.** Accepted after fixes. Fixed before the commit:
  - Chat after a relaunch: the config folder was set too late.
  - A failed start now undoes its new branch or worktree.
  - A git hook that leaves a child behind can no longer hang a start.
  - A first message over 128 KiB is refused before any git step.
  - Return can no longer approve in the chat fallback.
  - A keystroke in a draft redraws only its row.
  - `new-session.json` is written with mode 0600.
  - Full access kept from earlier is marked.
- **Decisions taken by the planner.** The user may change any of them:
  - Transcript search ships as stage 1, an on-demand scan with no index (concept: the corpus fits), with a switch that is on by default.
  - New worktrees go under `<repo>/.claude/worktrees/`, made by Loom's own bounded git child rather than the CLI's `--worktree` flag, so the branch name the user typed is kept. The folder shows as untracked in the repo's `git status`.
  - The Agents tab of a session from an earlier run says "Agents show while the session runs"; reading the subagent files waits for V23.
- **Checks.** The combined tree passed every test target with window tests (695 UI and 86 LoomChat tests), except the one below.
- **Open.** `OpenSessionTests.aRequestIsAcceptedOnlyFromTheLiveRunOfItsCardWithTheRunToken` times out in full LoomCore runs since batch 2a, and passes alone. Resolved in batch 2c (75188b9).

#### Batch 2c: Home and the project page (18 Oct)

| Commit | Slices |
| --- | --- |
| 75188b9 | The `OpenSessionTests` timeout: control and hook queues at user-initiated priority |
| f750d91 | V05 Home and V08 the project page, with the review's fixes |
| a81aa2f | Docs |


- **Built in parallel** from a3f867e: V05 Home and V08 the project page. They overlapped in one evidence dispatch line, and both handlers were kept.
- **Review.** No blockers. Four should-fix findings, all fixed with a test each:
  - transcript tail reads that outlive their rows and the page;
  - crashed runs that miss Continue on the launch after a crash;
  - a transcript miss that scans every Claude project folder;
  - branch labels that vanish when the sidebar prunes.

  The fixes for items 1–6 and 8–10 were checked by disabling each one: its test then failed. Minor fixes in the same round:
  - the project list now follows new sessions;
  - a resumed Continue card stays gone;
  - Today's count is re-read;
  - a crash shows the right age;
  - a read failure gets its own state;
  - a cut `packed-refs` no longer invents a branch;
  - Home's sizes move into `LoomTheme.Home`;
  - the debounce test no longer depends on timing;
  - Today shows its token split, which was V05's need.
- **Decisions taken by the planner.** The user may change either:
  - Today shows four bars of today's tokens by kind, not the preview's hourly bars. Hourly bars would add an index query to the chip's refresh path.
  - Every Continue card says "Last active <age> ago", dated by the session's last use. The catalog cannot tell a crash from a Quit.
- **The `OpenSessionTests` timeout.** The cause was not in v2's code:
  - The control server's accept and serve queues, and the hook server's receive queue, ran at utility priority.
  - In a CPU-bound test process, utility work waited 6–12 s for a CPU, past the client's 10 s read timeout. The base (030563e) failed the same way once in four runs.
  - Those queues now run at user-initiated priority, because a session waits on the answer.
  - Tests that raced teardown under load now wait for it. The pipe-leak checks use more runs and still catch a leak of one pipe per launch.
  - Still seen under heavy load, about once in six full LoomCore runs: `RunScopeTests.quitDrainsAdversarialChurnWithoutTouchingOutsideProcesses`. Once: `ClaudeUsageIndexTests.forgottenSessionsSurviveANewIndexInstance` ("prepare failed (21)"), which passed on the next run.
- **Checks.** Every test target passed with window tests on the combined tree: 746 UI, 754 LoomCore and 86 LoomChat tests.
- **Not now:** an index on `runs(end_reason, ended_at)` (the table is small and needs no schema change yet), and a persisted Dismiss on Continue cards.
- **Palette budget check.** With the user's permission, the size of the real `~/.claude/projects` was measured once (D-61, size only, no content): 1.1 GiB in total. The palette's default search covers 14 days up to 512 MiB, and the widened one covers 30 days up to 4 GiB. Both fit it.
- **Order.** V16 (the chat driver) and incremental chat rows (a V17 prerequisite that also lowers Release A's cost per live update) are being built in their own worktrees during the Release A evaluation. They are integrated into `v2` only after it passes.

### Release A evaluation (18 Oct)

On `v2` at a81aa2f. Evidence: `~/Library/Caches/loom-v2/evidence/release-a/` (README index; outside the repo).

- **Full gate** (`scripts/check.sh --full --idle`). The release build, the staged release tree and every check passed. About 1,650 tests ran in five targets, with one failure: `aBannerFadesInOverTwoHundredMillisecondsOnlyWithoutReduceMotion`, a timing check under load, which passes alone in release.
- **Package.** `packages/v2-A-candidate` (0.5.0, a81aa2f) is signed and verified.
- **Performance matrix** against a 0.4.4 package built from 24d8cfb (the package-I reference is gone): **pass**. All 12 cells were valid, and the thermal state was nominal throughout.

  | Cell | Result |
  | --- | --- |
  | stream1, app CPU median | 25.32 % of a core, against 24.76 for the paired reference: +0.6, inside the 1.5 limit |
  | stream1, total | 26.65–27.45 %; CPU40 holds |
  | spinner1 | 11.8–12.6 % |
  | stream1, window hidden | 3.25 % |
  | Latency, p95 | 18.2 and 18.7 ms |

  The first attempt was invalid in every visible cell because another app covered the Loom window; DEVELOPMENT §7 now says so.
- **Indicator cost.** App CPU 0.008–0.028 %, 0 idle wakeups, at most 77 MiB.
- **Real Claude.** `claude_real.py` ran 2 Haiku turns and passed 11 of 11 checks.
- **Screenshots.** 29 surfaces, 56 files, at 1220×780 and 780×500.
- **Found by the measurement run.** With the inspector open, growing the window clips the chat text and the user bubbles at the right edge. At 780×500 with the inspector open, the chat column is very narrow. The fix goes in with the Release B chat work.
- **UI review of the screenshots.** It found 3 must-fix defects, 9 should-fix defects and some polish; a fix round is running in its own worktree (`wt/uifix`). The must-fix defects:
  - an empty catalog shows the old start screen instead of Home;
  - the inspector squeezes the content below a usable width; the planner's default is to draw it over the content when the detail minus 328 pt is under 480 pt;
  - the session tab strip shows on pages that show no session.

  The should-fix defects:
  - counts that contradict each other;
  - mixed time and date formats;
  - the composer's pickers;
  - the narrow draft title and project page;
  - raw Markdown in palette snippets;
  - the changed-files card;
  - the view chip covering text;
  - the record view's wording.

  Two items wait for the user: the plan-limit meters fill in opposite directions on Home and in the footer, and the pace line uses the success colour, which DESIGN §3 keeps for content.
- **Commits after the review.**

  | Commit | Contents |
  | --- | --- |
  | 6d066bd | The fix round: the architecture review's silent failures, and the optimizer's draft, palette, Home and git items |
  | c4f9c68 | Incremental chat rows, a Release B prerequisite: a small delta costs about 4 ms at 21k rows, against 241 ms before |
  | 77eab8a | Docs |

  Before these commits, all test targets passed with window tests on the combined tree: 747 UI, 798 LoomCore and 96 LoomChat tests.
- **UI fix round** (f1bd0fc), from the screenshot review. Every must-fix, should-fix and polish item is fixed with a test; new screenshots are in the evidence folder's `ui-fix-shots/`. The full run passed except `RunScopeTests.quitDrainsAdversarialChurnWithoutTouchingOutsideProcesses`, a known load flake that passes alone.

  Decisions taken by the planner, which the user may change:
  - A failure is unread until viewed. A viewed failure leaves Home, the Dock badge and the jump set, as it leaves the sidebar's Active section. This narrows "needs the user" (D-45) to unread failures.
  - Below 480 pt of content, the inspector draws over the content.
  - The view chip turns compact below 700 pt.
  - First-run Home offers New Codex Session only in builds that start Codex.
- **Release A state.** All evaluation steps have run, and every finding is fixed or recorded. Release A waits only for the user's look. Their eye-check list holds:
  - the ⌥ shortcuts on the Turkish Q layout;
  - hover, menus, glass and motion;
  - the overlay inspector's shadow;
  - keyboard selection against hover in the palette;
  - the terminal colour against the panel;
  - two choices: the plan-limit meters fill in opposite directions, and the pace line uses the success colour.

- **Architecture and scalability review.** The module structure holds: LoomCore and LoomChat import no UI, the evidence code stays out of release builds, and the new state holders, reads and caps are bounded. Three seams must change before Release B, and were sent to the V16 and incremental-rows slices while they were being built:
  - per-session mode, model and effort move from the UI's `new-session.json` (300 entries, no effort) into the catalog, owned by the runtime;
  - "running" stops meaning "has a terminal view": a run-endpoint kind decides it;
  - the chat model splits into a delta source and a per-session presentation model.

  Also before Release B: a provider-independent pending-request summary (V18) and the driver's owner outside `CatalogModel` (V16). Silent failures go to the Release A fix round: draft save errors, an unreadable `new-session.json`, palette search errors and an overstated "completed" search, and project usage errors.
- **Optimizer** (Opus 5.5, xhigh). Nothing breaks a product guarantee; every cost below is read from code and still unmeasured.
  - **To the incremental-rows slice:**
    - R1: the growth feed queues updates, so each one gets a full rebuild, and a feed start that changes nothing still rebuilds and resets the 40 s activity timer;
    - R3: the stream controller is O(N) per update beyond the builder.
  - **To V16:**
    - R9: pipe stops sample the whole process table every 10 ms, while the run scope's members would do;
    - R9: the control queue is unbounded.
  - **To the Release A fix round** (`wt/afix`, with the architecture review's silent failures):
    - R5: per-keystroke passes over a draft's whole text;
    - R6: the palette repeats file lookups and folds on every query. Planner decision: the file list is resolved once per palette open;
    - R7: Home re-runs the Continue query after every usage refresh;
    - S2, part: copied file and line helpers;
    - `GitWorkspace` blocking a concurrency thread.
  - **To a chat-performance slice** after V16 and the incremental rows land:
    - R2: cold open parses every record twice, and the 19 ms budget fixture has no `toolUseResult`;
    - R4: a resize re-asks every row's height;
    - R8: growth reads ignore the 4 MiB line limit;
    - S2: one record classifier for the palette, `ProjectLastLine` and the lens;
    - S4: window visibility computed twice.
  - **Later:**
    - S1: the Agents tab still runs its own subagent transcript pipeline beside the lens. The lens is the target, after R2, with V23.
    - S3: `StdioProcess` copies the PTY exit handling. One shared exit watcher, when V16 next touches it.

### Release B (18 and 19 Oct)

| Commit | Slices |
| --- | --- |
| c4f9c68 | Incremental chat rows, the V17 prerequisite (also listed under Release A) |
| d0b9ee9 | V16 the chat driver, with the live chat view |
| 0e399bc | The live view's review fixes: the join, start markers, earlier runs' rows, feed lifetime |
| c3fe908 | V17 the composer and V18 the pinned cards, merged with their strict-review fixes and D-62 |
| edff6e9 | Docs for V17 and V18 |
| 8d4ddd3 | V19 Chat first and V24 the chat bar, merged with their strict-review fixes |
| e20bdb3 | Docs for V19 and V24 |
| 91ca023 | V26 Themes, moved onto 8d4ddd3 |
| 28a8f14 | Docs for V26 |
| 3711b3e | The Release B real-Claude acceptance harness |
| 1e3e939 | V25 Look |
| eadfdc8 | Docs for V25 |
| 3341a29 | Fix round 1: the double move on `/clear`, denied tools, the probe retry, the price table |
| 3215666 | Docs for fix round 1 |
| 93eb445 | Fix round 2, UI part: popover contrast, Settings → Usage meters, one composer, long user rows, the `@` menu |
| d2d7cc1 | Docs for fix round 2's UI part |
| c8081f1 | The evaluation's harness: the Chat stream scenario and its cost cells |
| 1f9822a | Docs for the harness |
| c6ec72b | Fix round 2, driver part: the handover hold, held messages, stored choices and launch records |
| 5a71108 | The queue stays paused after Back in Chat until the user resumes it (the planner's call) |
| dc3458e | Docs for fix round 2's driver part |
| 0a2e44e | The UI review's fixes: Home's limits verdict on a second line, shorter card notes |
| c69bc77 | The flaky-test triage: tests wait for state, and the run-scope shell race |
| d524db2 | The queue edit test keeps the composer's own read-back; docs for the triage |
| 0aa978c | The Chat stream's CPU: streaming text once per 80 ms, a row on screen updated in place |
| caed99e | The stream interval test kept free of load; docs for the stream's cost |
| 1e5d897 | The gate's three load failures wait for a state (tests only) |
| c13472f | The flaky list in DEVELOPMENT gets the gate's load failures |
| d980c6a | Fix round 3 B: cards keep their bottom row, Codex shown but not startable, the failure diamond, the Loom mark |
| d6f47b5 | Docs for fix round 3 B, and O-03 closed |
| 5506691 | Fix round 3 C: session cleanup in every build, two numbers to set, Remove from Loom Only, DP-CP4-7 and DP-CP4-8 |
| 28d7fbc | Docs for fix round 3 C |
| c055069 | Fix round 3 A: one app-wide face switch, the default mode in Settings |
| 630517c | Docs for fix round 3 A |
| 6339703 | The contract pass (O-08, O-10, the live session wording), approved by the user |
| d53203e | Fix round 3 D: tracker keys leave the general product |
| 546df1a | Docs for fix round 3 D |
| 4cf421c | Fix round 3 F: the model and context fill on every face |
| 43e5531 | Docs for fix round 3 F |
| 4fde89e | Fix round 3 E: the Chat start race and the render probe lock |
| acf494e | Docs for fix round 3 E |
| e8e4bb1 | Fix round 3 G: render probes count only what a test hosts |
| a2f3ddf | Docs for fix round 3 G |
| 6a8a539 | Perf scripts: the terminal cells switch the face to Terminal |
| 67fb090 | Fix round 3 H: a verified Stop leaves the session the user came back to |
| 4ac791b | Docs for fix round 3 H |
| 24e69ef | Fix round 3 I: Home's plan limits as the previews show them |
| 3bf83c7 | Docs for fix round 3 I |
| 8591d59 | The Codex early-exit test gets a startup timeout load cannot cross |
| bb914ec | Fix round 3 J: Claude names Chat sessions, and a resume keeps its model |
| 9fb8751 | Docs for fix round 3 J |

- **V16.**
  - Built in its own worktree from a3f867e. A strict review found one blocker and five should-fix defects, all fixed with tests; the mutation checks confirmed eight of the fixes. The blocker: `/clear` moved the run to a new card but left the driver on the old one.
  - The Release A architecture review's three seams are in V16: launch choices in the catalog, the run endpoint as the meaning of running, and the driver's own owner (`ChatSessionHost`). It also adds one list of waiting requests for both providers. From S8, every Chat spawn turns file checkpointing on.
  - Merged onto f1bd0fc, then joined to the incremental view. `LiveHistoryJoin` puts the transcript history and the newest run's live model together; `LiveChatFeed` holds one presentation per session. The full suite passed, with the debug row check on in the feed tests.
  - An in-app run on the fake provider worked through every state: send, a request, interrupt, Read now, `/clear`, Stop and resume.
  - Real Claude, 8 Haiku turns: Ready in 0.86 s; Stop with no signal in 0.63 s; resume with the catalog's choices.
  - Still open:
    - Stopping background tasks before a Stop waits for `stop_task`'s wire shape.
    - The real CLI's `queued_command` record carries a `source_uuid`; whether it is the uuid Loom sent is checked in Release B's acceptance. The join no longer depends on it.
    - The "cleared" marker now stays across runs within one launch; after a relaunch, check what the new card's transcript shows.
    - Quit after `/clear`: the 18 Oct clear probe's app stayed open for an hour after a hand-sent `quit`, its evidence folder deleted right after. Either Quit hung or the deleted data root broke the shutdown; the unified log holds nothing of it. Release B's acceptance runs chat start, `/clear`, a send to each card and Quit on a package, and checks that the app exits.
- **Live view review fixes (0e399bc).**
  - The join no longer relies on uuids alone: a transcript prompt is the run's by its id, a Read now alias, or its text when written since the run began. A mid-turn send's `queued_command` record now shows as the user's message.
  - One "Session started", or "Resumed" for a resume (after a relaunch too). Earlier runs' Loom-only rows stay, by time. A new run is found by a generation number, so one that added nothing still re-reads the history. "No activity" follows the CLI's output. At most four idle feeds are kept.
  - Built in its own worktree from 5bb0c58 and applied unchanged, so its full run (754 + 144 + 839 tests, window tests included) is the integration check. Two minor fixes have no test: the older-turns read's lens check and Show all waiting for a history read.
- **V17 and V18 built (18 Oct, from d0b9ee9).**
  - V17, the composer, is one component for the draft and the live session, with the D-58 bar, keys, delivery states, the queue strip, drafts in `<data root>/chat-drafts`, `/` and `@` menus, and attachments. Its full run passed except one LoomCore test, which passed alone.
  - V18, the pinned cards, covers approvals, questions and plans with a counter, folded lines, a cut-off card, the Stop path, and Chat-face requests reaching Home, the sidebar, the Dock and notifications. Its full run passed.
  - Full access in the live chip (D-62, the user's decision): every Chat spawn and resume passes `--allow-dangerously-skip-permissions`. Release B's acceptance checks the live switch to Full access and back on the real CLI, with no tool run in Full access beyond a harmless command inside `/private/tmp/loom-real`.
- **The merge (c3fe908).**
  - Built in `wt/intb` from c211ba3 and applied unchanged: the committed tree equals the tested one. The final full run passed: 755, 184 and 961 tests, window tests included.
  - The seam:
    - the cards sit in the composer's slot, at most 0.55 of the pane;
    - the composer's text is the note, the "Other" answer and the feedback, with a hint line above it;
    - one key rule: with a card shown, ↵ and ⌘↵ send nothing and Esc only closes a menu; Tab and Shift-Tab move between the composer and the card, and the ring starts on no button;
    - the typing guard follows the real composer, on system uptime.
  - Every blocker and should-fix item of both reviews is fixed with a test. So are most minor items, including Undo, Redo and Cut in the Edit menu.
  - A transient `.stopped` phase before `.failed(.notReady)` was found and fixed: `aChildThatNeverAnswersIsNotReadyAndIsStopped` had failed in heavy runs.
  - Evidence: 44 screenshots in `evidence/intb/shots/` with `INDEX.md`.
- **Checkpoint (18 Oct, afternoon).** The user asked to stop at a healthy point. Everything is committed; V19 waits.
- **Re-plan after the user's feedback (18 Oct, [D-63](../DECISIONS.md)).**
  - The user tried a playground build: the V17/V18 package with fake sessions, made by `evidence/tools/playground.py`. Their notes are D-63.
  - Release B now ends with five pieces, then the acceptance and the evaluation. The planner stops and reports before Release C.
    - **V19, Chat first,** with the sidebar's New session row, Home without the start box, and one reason wording.
    - **V24, the chat bar:** Loom's modes with icons and colours, Ask in place of Plan, the model popover and the effort slider, and the follow-ups below.
    - **Spike S9:** how to build Ask over the CLI and switch it live.
    - **V26, Themes:** Settings → Theme, a light theme and the main pane's tones. It runs beside V19 and V24, because it touches mostly the theme files, and merges after them.
    - **V25, Look:** the hover and selection highlight, spacing and Home's compact usage. It follows V19, V24 and V26, which touch the same views.
  - Wave 1 started from edff6e9: V19 in `wt/v19`, V24 in `wt/v24`, V26 in `wt/v26`, and S9 on the real CLI. The briefs are `evidence/v19-brief.md`, `v24-brief.md`, `v26-brief.md` and `s9-brief.md`. The user freed the Mac for window tests and screenshots; the implementers take turns on the screen through the build slot.
  - **S9 (Ask mode), done** ([evidence](experiments/v2-spikes/S9-ask-mode-20261018.md), 12 Haiku turns): Ask is the CLI's `dontAsk` mode plus live deny rules for Write, Edit and NotebookEdit plus a Loom-owned output style shipped as a plugin (`--plugin-dir`). A live session enters and leaves it with `set_permission_mode` and `apply_flag_settings`, about 60 ms each, with no relaunch and the prompt cache kept. The rules never go on the command line, because launch-layer rules cannot be removed live. `permissions.disableBypassPermissionsMode` is never sent: it removes Full access for the process for good. The planner checked the recordings (`e-live`, `h-probe`, `i2-probe`). Sent to V24.
  - **S9b, done** (6 Haiku turns):
    - WebSearch and WebFetch need an allow rule in Ask; with it they run and nothing else changes.
    - Subagents inherit `dontAsk` and the deny rules, and a finished background subagent makes the CLI start an extra turn.
    - The user's own allow rules are honoured in Ask: a project `Bash(mkdir:*)` let `mkdir` run. A live deny with the same text beats it.
    - Planner decision, sent to V24: on entering Ask, Loom mirrors every non-flag allow rule into `deny`, except those for Read, Glob, Grep, WebFetch, WebSearch and Agent. This covers MCP tools, which S9b's Bash-only proposal left open.
  - Planner defaults:
    - with no last used mode in its project, a new session starts in Ask before edits, passed explicitly;
    - the face setting replaces `SessionFaces.liveChatEnabled`;
    - Home's top stays empty for Lombot, which gets its own brainstorm and is not built in Release B.
  - The user's answers since: "Ask before edits" keeps its name next to Ask (V24 proposed "Confirm edits"); Lombot's place on Home is K ([D-65](../DECISIONS.md)), whose compact plan-limit line ("5h 100% left · Wk 74% left · on pace") is V25's target for Home's usage. (Corrected on 19 Oct: K's preview shows a "Plan limits" card with both meters, not one line; fix round 3's I brings the card back.)
  - After the stable release (D-63): the chat-performance slice above and central session management. The Release B evaluation still measures and fixes regressions.
- **Wave 1 results (18 Oct, evening).**
  - V19, V24 and V26 are built, each in its own worktree from edff6e9; V26's full run passed (989 + 184 tests).
  - **V24's strict review** found one blocker: Ask reached the terminal face as `dontAsk` with no rules, so the user's allow rules would run. It also found six should-fix and seven minor items. All are fixed in `wt/v24`, with tests that fail without them. Ask is now Chat-only: the terminal runs it as Ask before edits, with a notice. Mode changes run through one FIFO lock. Entering Ask is refused while a tool approval waits, because the driver never answers a request itself.
  - **V19's strict review** found one blocker: Continue in Chat was refused for a terminal session idle at its prompt, because `idle_prompt` read as a request. It also found five should-fix and nine minor items. All are fixed in `wt/v19`. Every handover now has a point of no return, and a Chat start reports started only after Ready. V19 also found a bug from V17: the live chat covered the session header. The whole top stack now sits above the stream.
  - **Evidence-tool lessons:**
    - a zsh EXIT trap set inside a function fires when the function returns;
    - the evidence toolchain stub's `--help` must list every flag Loom gates on, or a Chat start with choices fails;
    - an evidence script stops at its first failed step, so it never holds the slot with nothing to show.
  - **Flaky test:** `nothingIsAnsweredWhileTheSessionStops` fails 5 to 6 times in 20 when run alone, on the base and on V19 alike. It goes to the gate's triage.
  - **Merge (8d4ddd3).** Built in `wt/intc` from edff6e9 and applied unchanged: the committed tree equals the tested one.
    - Conflicts: 4 files and 6 hunks; both sides were kept.
    - Seams, each with tests:
      - Ask is Chat-only at one choke point, `SessionRuntime.terminalAskRule`, which every terminal spawn passes;
      - a pick during a waiting handover is held for the target face;
      - markers use Loom's names and sit before their turn.
    - Two defects showed only in the merged tree, and both are fixed: the composer stayed bound to a feed the host had released, and a resumed run's mode marker landed after the message.
    - Both full runs passed except `SidebarStatusTests.hostedWorkingIndicator…`, in both runs, and `SessionRuntimeCodexRecoveryTests.automaticIdleSeesTheServersForkedWork`, once. Both pass alone and are on the flaky list for the gate.
  - **Docs (e20bdb3).** DESIGN, UI-MAP, ARCHITECTURE and DEVELOPMENT for V19 and V24; the planner wrote CHAT-SPEC's part. The docs agent checked every claim against the code and corrected seven, among them the 38 pt bar, the draft's fixed model list and the banner's place between the stream and the cards.
  - **V26 on the merged head (91ca023).** Moved onto 8d4ddd3 in `wt/v26b` and applied unchanged: the committed code equals the tested code.
    - Conflicts in three files; both sides were kept. Settings → General now holds "New sessions start in", Terminal font size and Search session text; Theme sits between General and Usage.
    - V24's mode tones got light values, each at least 4.5:1 on every level and tone, also under the hover fill. Dark Full access moved from `#EE9A6E` to `#EF9C70`, because the old value gave exactly 4.5 on a hovered row.
    - V19's banner, notices and New session row needed no new colours.
    - The full run passed except two tests that pass alone: `ChatDeltaBudgetTests.aDeltaCostsTheNewestTurnNotTheTranscript` (a timing ceiling under load) and `ChatComposerBehaviorTests.aQueuedMessageCanBeEditedUpdatedCancelledAndSentWhileEdited`. Both join the flaky list.
    - Screenshots: `evidence/v26/rebase-shots/`. Home's near-black usage bar in Light goes to V25.
  - **Docs for V26 (28a8f14).** Checked against the code: the launch still sets `darkAqua` until the stored appearance is read (for the damaged-catalog question), and the inspector stays dark beside a terminal face.
  - **V25 Look (1e3e939).** Built in `wt/v25` from 91ca023 and applied unchanged: the committed code equals the tested code. The full run passed (1069 and 237 tests); evidence in `evidence/v25/shots/` (118 files, before and after, Dark and Light, both sizes).
    - **One pill** for hover, selection and press on every list, card, popover and chrome button except the tab strip. It is inset 8 pt, with radius 10, 8 or 6. Its fills are white overlays in Dark (0.06, 0.09, 0.12) and ink overlays in Light (0.05, 0.07, 0.10). Hover state lives in each pill, so a hover re-evaluates only that pill.
    - **Spacing:** about 100 values moved onto the 4 pt grid; the header, centre line and terminal insets are unchanged.
    - **Home's usage:** one card, with the plan-limits line "5h 62% left · Wk 74% left · on pace" (a click opens the meters) and one Today line. The bar chart is gone.
    - **Planner decisions:**
      - Home rows now open their session on click, because a hover pill on a row that does nothing would mislead.
      - The header test's middle width moved from 600 to 620 pt, because the on-grid paddings take about 6 pt more.
    - **Open choices, with the planner's defaults**, for the user at the report:
      - **Plan meters:** they fill the share left, in neutral grey, turning orange under 20% left or over pace, with a tick for the elapsed share and no green. Settings → Usage still fills the used share. Default: Settings → Usage follows, in the evaluation's fix round.
      - **Popover rows under hover:** secondary text reads about 4.1:1 there. Default: restore 4.5:1 in the fix round.
  - **Docs for V25 (eadfdc8).** The docs agent found that the draft composer (`NewSessionLayout`) kept its old insets (text 18, top 10, chips 6) while the live composer moved to 16, 12 and 8, and that `LoomTheme.Chat.rowSpacing` is read by nothing. Both go to the evaluation's fix round.
  - **Architecture and scalability review (read-only, on eadfdc8).** No proven blocker.
    - Release A's three seams were all made: choices live in the catalog, running is decided by the run endpoint, and the chat model is split into a delta source and a per-session presentation.
    - LoomCore and LoomChat import no UI.
    - **Must-fix**, both checked by the planner in the code:
      - a handover that does not happen (Cancel, `/clear`, a request or background work) leaves the queue unreleased, because the hold's turn skipped the release and the failure path never releases it;
      - a stopped Chat session opened after a relaunch shows "Mode" and "Default model", because the driver reads the stored choices only when it launches.
    - **Should-fix:**
      - the driver releases its hold before the terminal has the session, so a send can race the move;
      - a card change after the point of no return is not seen;
      - a message sent mid-turn and not yet read is lost on a crash (V17 promises otherwise);
      - Ask's layer is re-applied after a reset in a background task, so a send could slip in first;
      - a failed held-pick replay leaves the catalog and the chip wrong;
      - `pendingUserMessageIDs` scans the whole model on every update;
      - stopped drivers, composers and `@` file lists are never evicted;
      - the feed LRU described in ARCHITECTURE is not what the code does (V24 releases a feed as soon as no view shows it);
      - drafts have several writers and no lock;
      - `new-session.json` still collects `launched` entries nothing reads, and a live mode change never updates the project's last used mode;
      - deletion cleans up through three paths;
      - small items (a stale `.handover` pause reason after "Back in Chat", an unused `leaveChat`, a silent registry overwrite).
    - **Later:**
      - Loom-only rows (markers, answered requests) do not survive a relaunch; a product call, with Lombot's persistence;
      - provider neutrality: a `ChatSessionControl` protocol and one tool-vocabulary table, before Codex;
      - Release C prerequisites:
        - V20 needs `ChatWork.changedFiles` in LoomChat and a full edit scan;
        - V22 needs an injected request policy, a `parent_session_id` and list filters;
        - V23 needs one subagent authority;
        - splitting the 1,758-line driver (the mode and Ask machine, the handover) is best done at the start of Release C;
      - the library-side evidence seams ship inert in LoomCatalogUI.
  - **Optimizer (Opus 5.5 at xhigh, read-only on eadfdc8).** Nothing blocks Release B.
    - **Clean:**
      - idle sessions wake nothing;
      - no timer survives a handover;
      - a hidden window builds no rows and runs no clock;
      - V25's hover is local to each pill, and V26's tokens are prebuilt per tone.
    - **Should-fix:**
      - a test-only plan-approval path that already behaves differently from the UI's;
      - `composerState()` scanning the whole model on every read, which works against "Chat costs no more than the terminal";
      - a pasted chip of up to 16 MB scanned on every hover of its row;
      - images Loom sends kept at full size in the live rows.
    - **Later:**
      - splitting the 1,758-line driver and turning its five handover flags into one state, at the start of Release C;
      - a narrow `ChatRunServices` protocol, so the driver's tests need no process, and one shared copy of `ProcessHeavyGate`;
      - the composer depending on the feed, and drivers created in a view body;
      - per-session objects never released;
      - the streaming answer re-scanned per update (measure first);
      - three polls (the handover's 50 ms, its 1 s timed waits, Quit's 1 ms loop);
      - the `@` menu rebuilt per keystroke (done in fix round 2's UI part);
      - draft saves on the main thread.
    - **For the evaluation:** add a long-session Chat cell and a cell with several Chat sessions streaming while hidden. Both are added to the evaluation brief.
  - **Fix round 2,** in two parts by write area:
    - **UI** (`evidence/b-fixround-2u.md`, `wt/fixu` from eadfdc8, done; the record is below):
      - the popover's hover contrast back to 4.5:1;
      - Settings → Usage meters filling the share left (the planner's default);
      - the draft composer on the live composer's insets;
      - the unused token;
      - bounded long user rows;
      - the `@` menu's index and candidates.
    - **Driver** (`evidence/b-fixround-2d.md`, `wt/fixd` from 3215666, running), started after fix round 1 because both change `ChatSessionDriver`:
      - the two must-fix items;
      - the handover hold;
      - a card change during a handover;
      - mid-turn messages surviving a crash, with one owner for the draft file;
      - Ask after a reset;
      - the held-pick replay;
      - `composerState()`'s cost;
      - bounded images;
      - one plan-approval path;
      - the legacy launch list;
      - one deletion cleanup;
      - small items, and the 50 ms poll.
  - **Fix round 2, driver part (c6ec72b, the queue's pause 5a71108, docs dc3458e).** Built in `wt/fixd` from 3215666 and applied to 1f9822a, where the tree matched up to hunk headers. The touched suites passed on the combined tree: 851 tests, and the only failure was the known flaky `nothingIsAnsweredWhileTheSessionStops`.
    - **Must-fix:**
      - D1: a handover that ends without a move releases the queue;
      - D2: a driver shows a stopped session's stored choices before any launch.
    - **The handover:**
      - D3: the hold lasts until the caller finishes the move;
      - D4: a card change during a move is followed both ways;
      - D7: a held model or effort that the child refuses is taken back.
    - **Messages:**
      - D5: a message sent mid-turn is held in the draft file until Claude reads it, under one lock for every draft operation;
      - D6: a send waits for a mode transition, and for Ask's layer after a reset. On the real CLI, `dontAsk` and the live rules survive `/clear` (1 Haiku turn).
    - **Costs:**
      - D8: `composerState()` costs 2.7 to 3.0 µs at 1k to 50k entries, down from 222 to 10,790 µs;
      - D9: Loom's own images in live rows take the 2 MiB bound;
      - D15: finished feed tasks are pruned; Terminal to Chat waits on the hub (6 reads in a 3 s turn, about 70 before); Quit's loops back off.
    - **Cleanups:**
      - D10: one plan-approval path;
      - D11: launch records live in the catalog, imported once, and live changes count;
      - D12: the Chat host is a `ConversationForgetter`;
      - D13: `terminalAskRule` is pure;
      - D14: the small items.
    - **Declined:** dropping `DetailRoute.isRunning`'s terminal check. The terminal is adopted before the row sees the run, so Resume would flash during a start.
    - **The planner's call:** the agent made Back in Chat send the queue. The planner changed it: the queue stays paused until the user resumes it, because what was queued before the move may not fit what was done in the terminal. This goes to the user at the report.
    - **Left:**
      - the composer's debounced save can still race an end-of-run `prepend` for a moment; the text comes back on the next save;
      - no revert checks for D11, D13, the return to Chat and the Quit backoff.
  - **Fix round 2, UI part (93eb445, docs d2d7cc1).** Built in `wt/fixu` from eadfdc8. It was applied to 3215666, where the tree matched (the only difference was fix round 1), and the touched suites passed on the combined tree (158 tests).
    - **Popover hover:** a lit popover row lifts its secondary text to `#A6AABD` in Dark, at least 4.7:1 on the hover fill in every tone. The fill stays the shared one, and Light needs no lift. `HighlightTests` now holds 4.5:1.
    - **Settings → Usage** fills the share left with "N% left", under Home's colour rules (the planner's default; the user confirms it at the report). The agent also found that exactly 20 % left read as low, a floating-point edge in `PlanPaceLine.isLow`; it now compares whole percent.
    - **The draft composer** takes the live composer's tokens: inset 16, top 12, chip gap 8.
    - **`Chat.rowSpacing`** is removed; nothing read it.
    - **Long user rows:**
      - `isLong` is bounded (the UTF-8 length and an early exit): under 1 ms on 4 MB;
      - a collapsed row draws a 1,200-character prefix;
      - a hover redraws only the footer;
      - CRLF now counts as a line break.
    - **The `@` menu** lets its file index and session rows go when it closes, and builds the session rows once per opening.
    - **A new flaky test:** `ChatHandoverTests.anIdleSessionHandsOverToTheTerminalAndBackWithItsQueueAndDraft` failed once in the agent's full run and passes alone.
  - **Fix round 1 (3341a29, docs 3215666).** Built in `wt/fixb` from 3711b3e. It was applied to the head with V25, built there, and the touched suites passed (114 tests); the full run is the evaluation's gate.
    - **The double move on `/clear`:** measured on the real CLI. `/clear` writes `conversation_reset`, the SessionStart(clear) hook, `system/init` and `result`, and the reset's `new_conversation_id` is the record's own uuid. The driver adopted it, then the real id. Now it moves once. On the real CLI, `a8` and `b12` pass: one move, two cards, and two sidebar rows.
    - **Denied tools** read Denied, from the wire's `non_execution_kind`.
    - **The capability probe** is retried once and journaled with its kind.
    - **Prices:** Haiku 5.5's tier is priced per message through a long-prompt bit derived in SQL, and Sonnet 5.5's read is 0.05x.
    - **Ask's re-cache** comes from the switch to `dontAsk` itself, not from the rules or the style. Planner decision: Ask keeps `dontAsk` (CHAT-SPEC).
    - 10 Haiku turns. A new flaky test: `RunScopeTests.environmentScopeIsKeptWhileStartupWorkIsAlive`.
  - **Testing rule from now on ([D-66](../DECISIONS.md), the user's word).** An agent runs only the suites it touches and its new regression tests, with no final full run of its own. The full run happens once, on the combined tree, at the evaluation's gate. The planner sent the change to both fix round 2 agents.
  - **The evaluation's harness (c8081f1, docs 1f9822a).** Built in `wt/evh` from d2d7cc1, the tree applied unchanged.
    - **What it adds:**
      - `/scenario stream <seconds> <chars/s>` in the fake provider (the rate holds within 0.2 % per 10 s window);
      - `scripts/perf/chat_stream_cost.py`, with visible, hidden, several sessions and a 10,000-record session;
      - the terminal's `stream600` and `stream6000`.
    - **A cold open of the long session** reads only the tail: 30 history rows under 0.3 s.
    - **Smoke runs** (10 s windows on `v2-fixu`, not measurements):

      | Cell | App CPU % |
      | --- | --- |
      | Chat 600 characters/s, visible | 41.9 |
      | Chat 600, hidden | 3.4 |
      | Chat 600, three sessions, hidden | 8.3 |
      | Chat 600, long session | 30.7 |
      | Terminal 600 bytes/s | 5.5 |
      | Terminal 6,000 bytes/s | 20.9 |

      If the measurement agrees, a visible Chat stream breaks concept §5.7's first budget (no more than the terminal for the same output). That is a Release B defect, not the deferred chat-performance slice, which covers cold open, resize and growth reads.
  - **The overnight order ([D-67](../DECISIONS.md)).** The order keeps the one full gate last, with every fix in:
    1. the driver part of fix round 2;
    2. three agents at once:
       - the Chat stream's CPU (`evidence/b-perf-chat-stream-brief.md`);
       - the flaky-test triage (`b-flaky-triage-brief.md`);
       - the UI review's screenshots (`b-ui-shots-brief.md`, the evaluation's step 7 taken early);
    3. the UI review's fixes;
    4. the evaluation from its gate (steps 1–6), and the packaged candidate.
  - **The UI review (shots in `evidence/release-b/shots/`, fixes 0a2e44e).** The screenshots agent took 337 window shots from dc3458e (package `v2-B-shots`), listed in `INDEX.md`:
    - every Release A surface and Release B's new ones;
    - Dark and Light, with Workshop and Instrument in Dark;
    - 1220×780 and 780×500;
    - the hover states, both list modes, and the sidebar open and collapsed.

    The Mac's screen locked at about 02:30. An occluded window does no layout, so the live Chat shots taken after that are empty. They are retaken after the unlock (`slot-run.sh b_chat <variant>`).
    - **Fixed** (0a2e44e, `ReleaseBReviewTests`; the touched suites passed, 44 tests):
      - Home's plan-limits line at 1220×780 cut a verdict that names another day ("Wk runs out Tu…"). The verdict now takes a second line when the line does not fit, and a line that fits stays one row (rendered offscreen at the side card's 308 pt).
      - The card's note in the compact composer at 780×500 was cut: each note took 430 pt or more of a 362 pt line. The notes are shorter, and each fits one line of the narrowest composer: "If you deny, Claude gets this as your note.", "Claude gets this as your own answer.", "If you keep planning, Claude gets this as feedback."
    - **Looked at and kept:**
      - the sidebar's "Claude session" against "Claude · orbit" (the two list modes' default titles);
      - Finished with Stop on an idle live Chat;
      - the plan card's preview, which scrolls;
      - the draft bar without `+`;
      - the read-only stream's top edge;
      - the placeholder during a handover.
  - **The flaky-test triage (c69bc77, the planner's change and docs d524db2).** Built in `wt/flaky` from dc3458e and applied to 0a2e44e, where the tree matched. Each fixed test passed 20 of 20 alone and each touched suite 3 of 3 (`evidence/flaky/rates.md`).
    - **Reproduced:** only `nothingIsAnsweredWhileTheSessionStops` failed alone, 6 in 20. Its Stop is now held at the `leave` hook, so the session stays in `stopping` while all three answers are refused.
    - **Full-run failures only:** the others passed alone. Their causes come from the failing assertions in earlier full-run logs:
      - the not-ready child: a phase read before it settled;
      - the handover: the turn's end released the queue and sent the item queued after it. The item is now queued under the handover's hold;
      - the queued-message edit: the queue was read before the composer read it back;
      - the Codex join bound: the count depended on timing. The test now feeds turns up to the bound of 3, then one more;
      - the Codex idle teardown: a second teardown caller returned before the entry was dropped. The test waits for it.
    - **A product race:** in a run scope the host reaps the environment shell at once. A shell that ended before the job registered it failed the terminal's start with "Environment shell identity unavailable". The job observes nothing in a scope, so it now returns early; `RunScopeTests.aShellThatEnded…` fails without the fix (mutation check).
    - `RunScopeTests` and both Codex runtime suites are now `.processHeavy`. `OpenSessionTests` and `DiagnosticsExportTests` had no flaky test.
    - **The planner's change:** the edit test's wait called `refresh()` itself, so a composer that never read the queue back would pass. It now waits for the composer's own refresh (`ChatComposerBehaviorTests`, 38 tests passed).
    - **Left:**
      - the window test `hostedWorkingIndicatorRunsOnlyWhenTheEnvironmentAllowsIt` waits for its view now, but has not run while the screen is locked;
      - `realSidebarRunsAWorkingRowOnlyForAnActiveWindowAndExpandedSidebar` has the same fixed sleep;
      - the churn test can still lose to CPU starvation; the fix would be in `terminate()` (`ProcessSupervisor+Stop.swift`).
    - **Seen, not changed:** after "Claude did not answer" the phase goes failed, stopping, stopped and back to failed, though `outputEnded`'s comment says it never flashes.
  - **The Chat stream's CPU (0aa978c, the planner's change and docs caed99e).** Built in `wt/perf` from dc3458e and applied to d524db2, where the tree matched. The agent's touched suites passed (47 tests), and `ChatStreamCostTests` passed again on the combined tree (8 tests).
    - **Where the cost was** (profiled off screen with `sample`, because the screen was locked): not Markdown, which is about 1 % since SwiftUI already skips unchanged blocks, but the presentation and the stream controller.
      - Each delta, about 50 a second at 600 characters/s, derived the rows, remeasured the row and updated the table.
      - `reloadData(forRowIndexes:)` made AppKit walk the cell's view tree for its key view loop: 57 % of a delta.
    - **Fixes:**
      - Streaming text is shown at most once per 80 ms (`ChatPresentation.rowsInterval`). Off screen, 250 deltas took 91 rebuilds instead of 250, and handed the Markdown parser 14,494 characters instead of 75,840.
      - A row on screen is configured in place. The stream update per rebuild, forced through layout, went from 3.4 and 7.3 ms (the first and last tenth of a 3,000-character answer) to 2.1 and 4.1 ms.
    - **Tests:** `ChatStreamCostTests` is new; with both fixes off it records 9 issues. `ChatDeltaBudgetTests` counts turns derived, entries carried and rows redrawn instead of time ceilings, so it leaves the flaky list.
    - **Hidden cells** (valid while locked): app CPU 4.2 % on the base and 4.1 to 4.3 % after, unchanged as expected. The hidden cost is the driver's JSON decode, about 60 % of the samples.
    - **Not measured:** every visible cell, because the screen is locked. Whether Chat now stays under the terminal's 5.5 % at 600 characters/s is unverified; the evaluation's step 4 measures it.
    - **Left:** the row cost still grows with the answer (3.4 to 7.3 ms over 3,000 characters), because the whole prose row is configured and remeasured on each update. Splitting a streaming message into finished blocks and one open block is the chat-performance slice, after the stable release (D-63). The decoder's cost is the driver's.
    - **The planner's change:** the sustained-streaming test also asserted fewer than 50 rebuilds for 100 deltas, which a starved main thread breaks. The bound that no load can cross stays.
    - **Seen, not changed:** an older-history load that lands while streaming text waits drops the wait. The newest row shows that text at the next change: the next delta or the end of the block.
  - **The gate (the evaluation's step 1, on caed99e; `evidence/release-b/gate/`).** `check.sh --full --idle` took 20 minutes, with the thermal state nominal before and after. The static checks, the release build and the staged release tree passed. The release suite ran 2,204 tests:

    | Target | Tests | Result |
    | --- | --- | --- |
    | LoomCatalogUITests | 1,095 | 2 failed (3 issues) |
    | LoomCoreTests | 772 | passed |
    | LoomChatTests | 271 | passed |
    | LoomTerminalTests | 58 | 2 failed |
    | LoomLaunchOptionsTests | 8 | passed |

    - **Failed under the run's load, passed alone in release** (`rerun-*.log`), each a clock that the load crossed:
      - `ChatFirstTests.aNewSessionStartsInChatByDefaultAndInTheTerminalWhenSettingsSaySo`: the suite's first start (environment capture and a run scope) took over 15 s. Alone it took 1.4 s.
      - `ConversationControllerTests.productionControllerRefusesToResumeACodexRecord`: the refusal reads the catalog first, and 400 ms was not enough.
      - `TerminalRunControllerTests.repeatedRequestsStartAtMostOneRun(requests: 2)`: a launch took over 5 s, as it had three times before (7 and 12 Oct).

      1e5d897 gives each a state to wait for, or a deadline that load does not cross. The change is test-only, and the three suites passed (67 tests). The two first-time failures came with the first full run that has `ChatStreamCostTests`, whose record test keeps the main thread busy for about 17 s.
    - **Window tests with the screen locked:** three of the four passed, among them the triaged `hostedWorkingIndicatorRunsOnlyWhenTheEnvironmentAllowsIt`. `TerminalPartialDrawTests.layerBackingStorePreservesPixelsOutsideTheDirtyRect` failed with "captured image is blank (screen locked …)". It runs again after the unlock.
  - **The candidate (step 2):** `packages/v2-B-candidate` (`CFBundleVersion` 168, `LoomRevision` 1e5d897, whose product code is caed99e's; `codesign --verify --deep --strict` passed) and `packages/v2-B-fixtures` (the gate's release `loom-fake-provider` and `loom-test-child`). The sha256 of every binary is in `evidence/release-b/candidate-sha256.txt`.
  - **Step 4's hidden cells** on the candidate (valid with the screen locked; `evidence/release-b/chat-stream/`, thermal nominal):

    | Cell | App CPU % | Total CPU % | App idle wakeups/s | App footprint MiB |
    | --- | --- | --- | --- | --- |
    | Chat 600 characters/s, hidden | 4.00 | 4.92 | 0.03 | 38.5 |
    | Three Chat sessions at 600, hidden | 9.56 | 12.01 | 0.00 | 41.2 |

    The budget asks for about the hidden stream1 cell; 0.4.4's is 3.52 % (final matrix I). The hidden cost is the driver's JSON decode (the perf agent's profile), and three sessions cost about three times one.
  - **Waiting for the unlock** (the screen locked at about 02:30, and only the user can unlock it):
    - the window test `layerBackingStorePreservesPixelsOutsideTheDirtyRect`, alone with `--windows --idle`, and `InspectorWindowTests` (fix round 3 F changed it);
    - step 3, the matrix against 0.4.4;
    - step 4's visible cells: Chat at 600 characters/s (3 runs), at 6,000, the long session, and the terminal at both rates. The hidden cells run while locked;
    - step 5, the indicator cost;
    - step 6, real Claude: its 60 s observer window is a visible measurement;
    - step 7: the live Chat shots taken after the lock again (`shots/slot-run.sh b_chat <variant>`, five variants), and confirmation shots of the fixed surfaces (Home's limits line at 1220×780, the compact composer under each card at 780×500, a streaming answer).

    About three hours with the Mac idle and the screen unlocked. Each on-screen run holds `caffeinate -d` for its length ([D-68](../DECISIONS.md)).
  - **The user's answers at the report ([D-68](../DECISIONS.md), [D-69](../DECISIONS.md)) and the order they give.** Loom v2 ships once as 1.5.0, after A, B, C and Lombot; Lombot comes after C. The answers add a fix round 3 to Release B, before its on-screen evaluation, so the shots and the final gate cover it:
    - **Faces:** one app-wide switch in Settings (today's "New sessions start in") decides the face; "Continue in Terminal" and "Continue in Chat" leave the session's header and menu. The planner's default, which the user may change: a running session keeps its face until it stops, and the switch applies at its next start or resume. A queue paused for a move stays paused until the user resumes it.
    - **Default permission mode** in Settings → General, Full access included. Loom still never picks Full access by itself.
    - **Session cards keep their bottom row:** the branch and the provider (harness) icon stay the card's last line. For a card in the Active section the reason line goes between the title and that row, so such a card is one line taller while it needs the user.
    - **Codex's places:** 1.5.0 behaves as if Loom supports Codex. Its entries stay where dev builds show them (the first-run Home, the new-session menus), shown but not startable while Codex is frozen (D-28).
    - **Tracker keys leave the general product.** An explorer scoped it (`evidence/r3d-tickets-scope.md`). Search has no ticket logic. The ticket lives in three places: the draft (its ticket line, the re-check, and the branch and title taken from a key), D-40's open requests (`--ticket`, the `exists` reply and notice, the Ticket row), and the catalog's `ticket_key` column. The planner's decisions (`evidence/r3d-tickets-out-brief.md`):
      - the draft loses the concept: `loom/<words>` is the only branch suggestion, and Claude names the session;
      - D-40 keeps `openedBy`, the origin line, the single pending request, `title`, `project` and `message`; the `exists` reply and its notice go;
      - `loom open` accepts `--ticket` and ignores it, so older agent rules, the user's own included, still exit 0. A repeated request now asks to open a second session;
      - the column and its decode stay for old rows; new rows write NULL.

      Slice D builds it after A, since both touch `CatalogModel+NewSession.swift`.
    - **Settings → Sessions in every build,** with configurable numbers, plus DP-CP4-7 (block only a folder that can hold the conversation's files, and offer "remove from Loom only") and DP-CP4-8 (read the login shell's environment once in the background at launch).
    - **O-12:** the failure diamond under Differentiate without color, and the Loom mark on the empty Home if it fits.
    - **A check:** both faces show the model, the branch and the context fill.

    Then Release B's full gate runs again (D-69) with its on-screen steps, under `caffeinate -d`. Optimization weighs more with v2 (D-69): if the visible cells put Chat above the terminal, the chat-performance slice that D-63 placed after the stable release comes before 1.5.0, since 1.5.0 is now that release. Then Release C, Lombot, 1.5.0's evaluation (with O-01's budgets and O-09) and the release. The user then uses 1.5.0 and brings feedback, including Release A's eye checks. Later tracks: GitHub and Bitbucket features, and more worktree management for general users.
  - **Fix round 3 (19 Oct).** Slices A (faces and the default mode, `wt/r3a`), B (cards, Codex, identity, `wt/r3b`), C (cleanup, `wt/r3c`) and D (tracker keys, after A); then E (a Chat start race), F (the model and context fill) and G (the render probes), each in its own `wt/r3<x>`. Each slice's builds and touched suites only, while the user uses the Mac (D-66).
    - **B**, integrated as identical trees (d980c6a, docs d6f47b5). The planner's call on its question: a project row's failure dot is the diamond too, under the same rule (`ProjectAttention.drawsDiamond`), so the two marks cannot drift apart. Its touched suites passed (143 tests, then 26 after that change). Not seen on screen: the card, the diamond, the mark and the disabled menu entries.
    - **C**, integrated after a planner's change (5506691, docs 28d7fbc). Its tree is C's tested tree plus exactly B's changes; the two touched different places in `CatalogModel.swift` and `AppDelegate.swift`. Two of the Brief's points were wrong:
      - The 15-day number is the deletion wait for every stale session (`minimumStaleDuration`, counted from the later of the stale start and the last view), not a wait added for viewed sessions. It becomes "Wait before deleting".
      - With automatic deletion off in every build, the 45-day absence and the 10-candidate limit change only the due notice's wording, so they leave the page. The page keeps two numbers, "Review again after" (30 days) and "Wait before deleting" (15). D-69's list of four is the planner's reading of DP-CP4-2, and the user hears of the change.
      - The confirm sheet's "Remove from Loom Only" asks through the same alert as the banner's. Not seen on screen: the alert relies on SwiftUI running a button's action before it dismisses, so its Remove must be tried once on the 1.5.0 install.
      - B's and C's 19 suites on the combined tree (5506691) passed: `swift build`, then 92 and 170 tests (`evidence/r3-bc-combined-check.log`).
    - **A**, integrated (c055069, docs 630517c; CHAT-SPEC "As changed in fix round 3"). Its tree is A's tested tree plus exactly B's and C's changes.
      - **Faces:** "Sessions run in" (Chat | Terminal) is the face of every start and resume. A running session keeps its face; a stopped one follows the switch. The ⋯ and `/` menus lose the moves, and the policy banner's "Switch to Terminal" sets the switch and moves the session.
      - **Mode:** "Mode of new sessions" is last used in the project or one fixed mode. Full access asks once in Settings. The order is pick, Settings' fixed mode, last used, Ask before edits.
      - **Settings order:** General, Theme, Usage, Sessions, About.
      - **Its touched suites:** a 344-test batch with one failure, `ChatFirstTests.aNewSessionStartsInChatByDefaultAndInTheTerminalWhenSettingsSaySo` (a 60 s timeout; it passed alone twice).
      - **The check of D-69's facts:** the branch shows on every route (the header's chip). The context fill shows in the live chat's composer bar, and on the terminal face and the read-only chat only in the inspector's Overview. The model shows only in the live chat's composer bar; on the terminal face only the TUI's own status line can show it. The user said Loom must show all three. F closes the gap after D and E (`evidence/r3f-model-context-chip-brief.md`): a header segment after the project chip with the model and a small context ring on every route but the live chat, and a Model fact in the inspector. The user did not object to the plan.
    - **E, a Chat start race and the render probe**, integrated (4fde89e, docs acf494e; `evidence/r3e-chat-start-race-brief.md`). Two ChatFirstTests tests had failed intermittently on unchanged code since the morning. E's change is the one it tested, applied onto 43e5531 with a three-way merge at one context line (D's doc comment in `ChatSessionHost`).
      - **A failed Chat start kept its driver.** `startInChat` never let the host forget the driver of a start that failed before Ready. The card stays, as after a failed terminal start, so `aChatStartThatFailsBeforeReady…` passed only when it read the rows before the list reload (a 100 ms debounce) added that card. The controller now forgets the driver before it reports; a Stop's cancel is excluded.
      - **A second start right after the first was dropped.** The project's start key was held until the first message had gone out, after Ready, so a send in that moment failed `canSendDraft` and did nothing: the 60 s timeout of `aNewSessionStartsInChatByDefault…`. The key is now released when "started" is told, and a one-shot keeps the old start from releasing a newer one's key.
      - **The render probe:** every test that watches or resets `SidebarRenderProbe` takes the `.renderProbe` trait (one async lock) and checks that it holds it.
      - **Evidence:** before the fix, the first test failed 5 of 10 runs and the second 2 of 12. With the controller reverted, both regression tests fail 3 of 3; with the fix, 20 runs of the three tests pass 60 of 60, and the touched suites pass (166 tests). Two probe suites that each watch for 400 ms fail 3 of 3 without the trait and pass with it.
      - **The planner's default on its question:** a Chat start that fails before Ready keeps its card with the issue line, as a failed terminal start does; the user can remove it from Loom.
    - **D, tracker keys out**, integrated (d53203e, docs 546df1a). Its code tree is exactly the one it tested; only docs and the contract were committed in between.
      - The draft starts at once, is never titled by Loom, and suggests `loom/<words>`.
      - D-40 keeps its request without the `exists` reply, the Ticket row or the wire field. `loom open --ticket` exits 0 and is ignored, and the skill tells an agent to ask the user before reusing a session.
      - `ticket_key` stays for old rows and is written NULL.
      - The regression test failed on c055069 and passes. Its touched suites passed (about 85 tests).
      - `scripts/perf/fb2_accept_real.py` was rewritten without tickets (compiled, not run).
    - **F, the model and context fill**, integrated as an identical tree (4cf421c, docs 43e5531).
      - A header segment after the project chip shows a small ring (or a token count while the model's window is unknown) and the model's short name, on every Claude face without the composer bar. Before the first reply it shows the launch model if one was picked.
      - The inspector's Overview gains a Model fact.
      - A reading redraws the segment, not the row. `inspectorContextSessions` also names the selected session while the segment shows.
      - Its touched suites passed (34 tests, 11 new).
      - Not run: the window test `InspectorWindowTests.theOverviewDrawsTheContextRingAndNamesOnlyTheSelectedSession`, whose assertions it updated. It joins the on-screen steps.
      - The planner's answer to its question: a stopped live chat keeps no header segment. That route always builds a driver in the stopped phase, so its composer bar carries the ring.
    - **A, B and C together** (630517c, the 34 suites they touched, `evidence/r3-abc-combined-check.log`): 484 tests, one failure. `SidebarRenderTests.aSelectionChangeEvaluatesOnlyTheOldAndTheNewCard` counted no card at all. The cause is older than the round: `SidebarRenderProbe` is global, and `SessionChatViewTests` (another suite, run in parallel) replaced its watched set mid-test. Each suite is serialized only within itself, so any run with both can fail by timing. E gets it: one shared lock for every test that watches or resets the probe. ChatFirstTests passed in this run.
    - **D, E and F together** (4fde89e's tree, the suites the three touched, `evidence/r3-def-combined-check.log`): `swift build`, then 361 tests with one failure. `ChatHosted.ChatEntryViewTests.aParentRenderKeepsTheModelAndANewSessionIdShowsTheNewSession` counted two stream controllers instead of one. `ChatRenderProbe` is a global too, and suites that hosted a chat at the same moment (the composer, the header segment, the inspector's Agents tab) added theirs. The test is from V13, untouched by the round, and passes alone (`r3-def-chatentry-alone.log`).
    - **G, the render probes** (`wt/r3g` from acf494e, `evidence/r3g-render-probes-brief.md`), integrated as an identical tree with the planner's composer fix (e8e4bb1, docs a2f3ddf). It was paused at 17:46, when the user shut the Mac down, and resumed at 20:04.
      - **Result:** `ChatRenderProbe.watch(scope:)` counts only the views whose `ChatRowContext.probeScope` is the watched scope (a transcript's session id). `SidebarRenderProbe.watch(_:model:)` counts the project list and draft rows of that model, and `onScreen` for the watched sessions. Every test that watches a probe takes `.renderProbe` (`RenderProbeExclusive.watchChat`, `watchHeader`). No budget number changed, and `RenderProbeScopeTests` fail 3 of 3 without the scopes. `ChatDeltaBudgetTests.aDeltaCostsTheNewestTurnNotTheTranscript` reads a count of the same class; no failure log confirms it was this flake.
      - **The composer test.** With G's change, `ChatComposerBehaviorTests.returnWhileClaudeWorksAlwaysSendsNextEvenWhenOnlyABashCallRuns` failed in about half of the combined runs. Its margin was half a second: the fake's `work 4000` runs three Bash steps of about 1.3 s, a `next` message is read at the end of the running step, and the test checks that it is still queued 600 ms later. G's new tests stall the main actor long enough. The planner's fix, in the same tree: the fake's `work <ms> hold <path>` keeps a step open while the file exists, and the test holds it until it has checked. With a 1 s main-actor stall injected, the old test fails at that check and the new one passes (`evidence/r3g/planner-stall-*.log`).
      - **D to G together** on that tree (24 suites, `evidence/r3g/planner-union-*.log`): runs 1 and 2 passed (58 and 281 tests each). Run 3 had one failure, outside G's files: `ChatFirstTests.aStoppedChatSessionShowsItsComposerAndASendResumesItInChat` at line 143. It had failed twice on 18 Oct at an earlier line, and passed in about 35 runs.
      - **The planner first read it as a lost selection. It was not:** the one issue is the `#expect` itself, so the `#require` found the row.
      - **What a read-only explorer found:**
        - Line 143 reads `runEndpoint(of:)` without waiting. The resumed run reaches the row as two hub frames: `.runStarted` resets the endpoint, then `.runEndpoint` sets it (`ProcessSupervisor.swift:499-500`, `SessionEventHub.swift:326`). The driver already had the fake's answer, and the catalog said pipe at line 144. A read race in the test, under load.
        - **A separate product defect** (`ConversationController.swift:405-422`). A verified Stop calls `closeTab` when it returns, even if the user selected the session again while the Stop was verifying. The window then leaves the session the user came back to; the window is short. Fix: close only if nothing navigated since the Stop began, and otherwise unpin without navigating. Test: a `stopGate` seam like `handoverGate`.
        - The 18 Oct failures were a real nil selection, on code before 8d4ddd3; no writer at HEAD explains them.
      - Both go to slice H after the evaluation, so the candidate's product code stays the gated tree's.
    - **Release B's gate again (D-69)**, on a2f3ddf with the Mac idle and `caffeinate -d`, 20:12–20:33 (`evidence/release-b/gate-r3/README.md`).
      - Every check and build passed, and 2,252 Swift Testing tests ran in release, the window tests included.
      - The window tests passed: `layerBackingStorePreservesPixelsOutsideTheDirtyRect`, and `InspectorWindowTests` with F's updated test.
      - One test failed under load: `CodexAppServerManagerTests.delayedStartupSucceedsAndStops` (a 3 s startup timeout around a 0.15 s delay). It passed alone in release, and it had failed once before, on 8 Oct, in 98 runs. H gives it a timeout that load cannot cross.
    - **The candidate:** `packages/v2-B-candidate-r3` (CFBundleVersion 184, from a2f3ddf) and `v2-B-fixtures-r3`, sha256 in `evidence/release-b/candidate-r3-sha256.txt`.
    - **The evaluation's steps 3 to 7** ran on the candidate through an agent, 20:37–23:01 (`evidence/release-b-eval-r3-addendum.md`; results in `evidence/release-b/r3/README.md`).
      - **Conditions:** `caffeinate -d` and the thermal gate around every step; the thermal state stayed nominal. The Mac ran on battery all evening, which the user accepted (DEVELOPMENT §3 asks for the adapter). A loop brought Finder back to the front whenever the Claude desktop app covered Loom's window.
      - **Matrix: pass.**
        - CPU40: the stream1 total peaks at 28.42.
        - stream1's app median is 25.95, against the paired reference's 26.72 (limit 28.22).
        - spinner1 is 13.18, hidden stream1 3.35, latency p95 18.55 ms.
        - The Claude app covered the reference's r1 cell twice, so it ran once more alone, 35 minutes later. The planner accepts that: it changes no gate.
      - **Chat stream cost: one budget missed.**
        - Visible Chat costs 3.8 times the terminal at 600 characters a second: the app median is 23.08 % against 6.13 %, three runs each, which agree within 0.06 points.
        - At 6,000 a second it costs 1.9 times: 48.77 % against 25.16 %. Its total, 49.97 %, is above CPU40.
        - Hidden Chat (3.91 %), a 10,000-record session (22.81 %) and three hidden sessions (9.51 %) keep their budgets.
        - Under D-69 the chat-performance slice therefore comes before 1.5.0. The user decides whether it runs before or after Release C.
      - **Indicator cost: pass.** 0.009–0.028 % app CPU and no idle wakeups, as in Release A.
      - **Real Claude: pass.** 11 of 11 checks in 2 Haiku turns, on the terminal face.
        - The repo's `indicator_cost.py` and `claude_real.py` no longer worked on the Chat default: a start follows "Sessions run in", so their terminal waits time out. The agent's copies turn the face to Terminal first; 6a8a539 ports that.
        - Five older scripts also wait for terminal sessions and need the same step when they next run: `tab_strip.py`, `claude_resume_real.py`, `fb2_accept_real.py`, `cp4-deletion-real.py` and `cp5-c-acceptance.sh`.
      - **Shots:** 259 (`shots/INDEX.md`). What they show:
        - the cards' bottom row, the reason line and the header's model segment, as D-69 asks;
        - at 780×500 with the sidebar open, the header drops the model segment and then the branch, in its drop order (UI-MAP, Header);
        - Settings → General cuts the descriptions of "Sessions run in" and "Mode of new sessions" with an ellipsis. This goes to I.
        - a stopped Chat session's composer says "Default model" while its transcript ran on Haiku, and its header has no model segment (F's rule). A follow-up below.
        - live Chat sessions on the fake provider are titled "Claude session" in the sidebar. Not checked with real Claude.
      - **Not taken:** the failure diamond (it needs a system setting), Codex's disabled entries (the dev package starts Codex) and the Remove-from-Loom alert (no command opens it). They wait for the 1.5.0 install.
      - **The agent's harness** stays in `evidence/release-b/r3/tools/`, uncommitted: the step drivers, the Finder loop and the round's shot script (`shots/c_r3.py`).
    - **H and I** ran beside each other from 6a8a539 (`wt/r3h`, `wt/r3i`).
      - **H**, integrated as an identical tree (67fb090, docs 4ac791b; `evidence/r3h-stop-close-brief.md`).
        - `CatalogModel.navigationCount` counts the window's moves. A verified Stop closes the tab only if nothing navigated since it began; otherwise it only unpins it, and the window stays where the user came back to.
        - A `stopGate` seam holds the Stop before that decision. `aVerifiedStopAfterTheUserOpenedTheSessionAgainOnlyUnpinsItsTab` fails without the fix, and passes 3 of 3 with it. Its twin without navigation keeps today's close.
        - `ChatFirstTests` line 143 waits for the resumed row's endpoint, and its message names the row's live state. `delayedStartupSucceedsAndStops` gets a 30 s startup timeout.
        - H's combined run found `CodexAppServerManagerTests.earlyExit` at 3.2 s against its 2 s check, the same class. The planner gave it a 30 s timeout and a 15 s check (8591d59).
      - **I**, integrated (24e69ef, docs 3bf83c7; `evidence/r3i-home-plan-limits-brief.md`). Its tree is I's tested tree plus one planner's change: with nothing to say, `HomeUsage` draws nothing instead of an empty stack, which took a gap in the side column.
        - **Home:** a "Plan limits" card ("updated HH:MM", then each window's name, "N% left", the meter and its reset and pace line) and a "Today" card, as in the previews. The line button, the popover and their tokens are gone. VoiceOver reads the limits as one element, and the tooltip keeps each window's sentence.
        - **Meter:** a pace sentence that does not fit takes a second line. `PlanPaceLine`'s meter drew 10 pt tall (the tick's height); the track and the fill keep 6 pt now. That also changes Settings → Usage.
        - **Settings:** `SettingsRow`'s text column sized itself from the control beside it, so the two General descriptions were cut. It takes the lines it needs now.
        - **Tests:** its three new tests fail on the old code and pass (`evidence/r3i/new-old.full.log`, `new-fixed.log`).
      - **H and I together** on the final tree: 13 suites, 14 and 192 tests, all passed (`evidence/r3hi-combined-check.log`).
      - **Home's confirmation shots** on a package of 8591d59 (`packages/v2-B-r3hi`; `evidence/r3hi-shots/`, its script `tools/home_r3i.py`), Dark and Light, sent to the user:
        - at 1220×780 the Plan limits card shows both meters with their reset and pace lines, the weekly window in attention orange over pace, and the Today card under it, as in the previews;
        - at 780×500 the side column sits under the lists, below the fold. At 780×900 it shows in full, nothing cut;
        - Settings → General shows both descriptions in full.
    - **The contract pass** (O-08, O-10, and concept decision 3's wording with the app-wide switch), approved by the user and committed as 6339703 (the diff is `evidence/contract-pass/contract-pass.diff`). It also holds C's cleanup lines: the 15-day wait and the 30-day review are defaults, and the policy in force is DP-CP4-2's.
  - **Ready:** the evaluation's briefs (`evidence/release-b-eval-brief.md`, `release-b-arch-brief.md`, `release-b-optimizer-brief.md`). The evaluation adds a Chat stream cost cell: the matrix measures only the terminal face, and Chat is now the default.
- **Follow-ups** (the reason wording goes to V19, the flaky tests to the gate, the rest to V24):
  - **Late Stop close:** done in fix round 3, H (67fb090).
  - **Home's plan limits:** done in fix round 3, I (24e69ef).
    - The user remarked on 19 Oct, evening, that Home's usage lacks the reference's bars, and expects the previews' design.
    - V25 had folded the meters into a popover behind one line ("5h 62% left · Wk 74% left · on pace"). That came from the planner's reading of D-63 and from a wrong note in this plan's Release B record, which says K's compact line was V25's target. K's preview (`HOME.morning.right` in the Lombot preview), like the Studio preview, shows a "Plan limits" card with both meters, their reset times and the pace line.
    - I brings that card back on Home, from the popover's own rows. It runs after the evaluation, beside H, and also fixes Settings → General's two cut descriptions.
  - **Chat performance** (D-69): the evaluation's visible Chat cells cost 3.8 times the terminal at 600 characters a second, so the slice comes before 1.5.0. The user placed it after Release C (D-70).
  - **Closing Release B (19 Oct, night; D-70).** A read-only explorer checked every open follow-up at 8591d59, and the planner re-checked the evidence in code.
    - **Closed by 8d4ddd3 (V19 and V24):**
      - the layout at 780×500 (a compact composer while a card waits);
      - the duplicate after Retry (`withdrawFromDrafts`);
      - Send now into a waiting request (`requestWaiting`);
      - the reason wording (one formatter, `SessionReasonLine.approvalText`);
      - the four missing tests;
      - the draft reads off the main thread.
    - **`card-state` after a kill:** fixed for the case seen. A residual, that it reads `{"cards": false}` when no feed exists, is unconfirmed and left.
    - **Real Claude 2.1.300 in stream-json mode** (Haiku, one turn, isolated profile): its transcript has no `ai-title` record. The stream's `post_turn_summary` carries a status, not a title. So Chat sessions stay "Claude session" with real Claude too, because only the terminal's title event names a session.
    - **Slice J** (`wt/r3j` from 8591d59, `evidence/r3j-close-b-brief.md`) takes what is left:
      - a resume keeps the session's last model, read from the transcript as the effort is, on both faces, and the composer chip names it;
      - an untitled Chat session is named by Claude itself, as in the terminal. The user rejected the planner's first design, a title from the first message. The TUI names a session with its own `generateSessionTitle` (a Haiku call on the first user message) and writes an `ai-title` record. The SDK control request `generate_session_title` (`description`, `persist: true`) does the same on demand: real Claude 2.1.300 answered "Binary search explanation" and wrote the record. Loom sends it once for an untitled Chat session, and a rename wins;
      - five old perf scripts get `live-chat:off`;
      - two stale comments.
    - **J, integrated as an identical tree** (bb914ec, docs 9fb8751).
      - **Titles:** the Chat driver sends `generate_session_title` once, on the first message that is not a slash command. The answer goes through the non-custom title path. A failure is silent. The fake answers "Fake title: <first three words>".
      - **Model:** a resume passes the transcript's last model (`ClaudeTranscriptModel`), unless the configured default is that model (`ClaudeDefaultModel`: the profile's `settings.json` `model`, else `ANTHROPIC_MODEL`). The composer chip names the observed model.
      - **The planner's review** found a regression in J's first version: the user's own default is `opus[1m]`, and the transcript's id has no `[1m]`, so a resumed Opus session would have dropped to the 200K window. J fixed it with the default comparison above, and its test fails on the first version.
      - **Tests:** its new tests fail on the old code. The planner's own run on v2 passed 16 suites (66, 54 and 169 tests, `evidence/r3j-planner-check.log`).
      - **Real Claude in the app** (package `v2-B-r3j`, isolated profile, one Haiku turn, `evidence/r3j/title-real/README.md`): a Chat session started in the app was titled "Binary search explanation", not custom, and the transcript holds the same `ai-title`.
    - **Release B is closed** (D-70), except the chat-performance slice, which comes after Release C. The 1.5.0 install keeps the eye checks: Release A's, the diamond, Codex's disabled entries and the Remove alert.
  - **The stopped Chat composer's model:** done in J (bb914ec): a resume keeps the session's model and the chip names it.
  - **Live Chat titles:** done in J (bb914ec): Claude names a Chat session through `generate_session_title`, checked on real Claude in the app.
  - **On the 1.5.0 install**, besides Release A's eye checks: the failure diamond under Differentiate without color, Codex's disabled entries in the production identity, and the Remove-from-Loom alert.
  - **Real Claude on the Chat face at app level:** the evaluation's step 6 drives the terminal face. The Chat face against real Claude is covered by the driver suites and `release_b_accept.py`; 1.5.0's evaluation decides whether it needs its own app-level step.
  - **Layout:** at 780×500, an approval card's buttons can fall below the fold; a more compact composer while a card waits would fix it.
  - **Duplicate message:** run-end unread messages go both to the draft store and to `returnedDrafts`, so a successful Retry can leave a duplicate.
  - **Send now:** `sendQueuedNow` still sends `now` into a running turn. Guard it against a waiting request.
  - **Evidence tool:** `card-state` reads `{"cards": false}` after a killed process, though the cut-off card shows.
  - **Reason wording:** Home and the sidebar word the same request kind differently by face. A Chat-face Bash request reads "Allow: make step1"; a terminal-face one reads "Asks to run a command". Seen in the user's playground on 18 Oct.
  - **Missing tests:** the Edit menu, a request arriving during Stop, the payload drop, and the "no longer waiting" path.
  - **Main thread:** draft thumbnails and the draft file read are still partly on the main thread.
  - **Flaky tests:** triaged before the gate (the triage's record above). Left:
    - `SidebarStatusTests.hostedWorkingIndicatorRunsOnlyWhenTheEnvironmentAllowsIt`, fixed but not run while the screen is locked;
    - `ChatDeltaBudgetTests.aDeltaCostsTheNewestTurnNotTheTranscript`, with the Chat stream's CPU work (fix round 3's G checks whether the global Chat probe is its cause);
    - `RunScopeTests.quitDrainsAdversarialChurnWithoutTouchingOutsideProcesses` under CPU starvation.
  - **Found by the Lombot brainstorm** (its §13), for the Release B evaluation:
    - `UsagePricing` has no Haiku 5.5 row, while the CLI's `haiku` alias is `claude-haiku-5-5`. The planner checked the [official pricing page](https://platform.claude.com/docs/en/about-claude/pricing) on 18 Oct:
      - Haiku 5.5 costs $0.10 input and $0.50 output per million tokens for a prompt up to 100,000 tokens, and $0.50 and $2.50 above that. The prompt length counts every input token of the request, cache reads and writes included. Its cache multipliers are the standard ones, and the US-geo multiplier applies to both tiers.
      - Sonnet 5.5's cache read is 0.05x, like Opus 5.5's; the table has 0.1x.
      - Mythos 5.1 and Mythos 5 were already in the table, with the right prices; the planner's search had missed them.
      - The usage index keeps one row per message, so the tier can be priced per request.
    - Home's reason line and the unread flag live in memory only, so Finished not read and the reasons are lost on relaunch. The planner checked: this is as in 0.4.4, where `SessionEventHub` keeps read state as display state only, like the ended screens (contract §8). It is not a Release B regression. Lombot's morning tiles (D-65) need it kept across a relaunch, so it moves to the Lombot track.
  - **Release checklist, done early:** the planner re-read the [SDK support article](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) on 18 Oct. It is unchanged since 17 Oct: its latest update (7 Oct) adds monthly API credits to Max and Team plans, and the Agent SDK, `claude -p` and third-party apps still draw on subscription limits.
  - **Release B acceptance on the real CLI (18 Oct, done).** 17 checks and about 24 Haiku turns (`evidence/release-b-accept/`; harness committed as 3711b3e). None failed, and three pass with a caveat.
    - **Driver level:**
      - the uuid join: `queued_command.source_uuid` is the uuid Loom sent;
      - an approval, allowed, then denied with a note;
      - a question, and a plan approved into `acceptEdits`;
      - an interrupt that cancels the unread message and pauses the queue;
      - `stop_task`: the request is `{subtype: "stop_task", task_id}` and it is answered `{}`. The task id comes from `system/task_started`.
      - Full access switched live and back;
      - `/clear` in the same process.
    - **Ask:**
      - Entering it keeps the pid and sets `dontAsk`. Nothing in the work dir changes and no request reaches Loom, and leaving it makes the same edits work.
      - Caveat: Haiku follows the Ask style and attempts no tool at all. A second run, with the rules and no style, showed the CLI itself refusing Write, Edit, `mkdir` (through the mirrored project allow rule) and `echo >`.
    - **App level:**
      - a Chat start from the draft, Stop, and a resume from the composer;
      - Continue in Terminal, with the whole turn on disk and remembered;
      - Continue in Chat after the idle reminder, with the turn once in the stream. This also settles the SIGHUP question.
      - Quit after `/clear`, with no process left.
    - **Found, and sent to fix round 1** (`evidence/b-fixround-1.md`, `wt/fixb`, from 3711b3e):
      - one `/clear` moves the session twice and leaves an empty card (must-fix);
      - a denied tool reads as failed in the stream;
      - a capability probe failed once in six launches, and the start failed with no retry;
      - entering Ask re-caches about 10k tokens, where S9 expected a full read (to investigate).

      The price table fix goes with them: Haiku 5.5's tiers, Sonnet 5.5's cache read, and the Mythos rows.
- **The strict reviews (18 Oct).**
  - V18: no blocker and five should-fix items: Deny and stop releasing the queue, answers while stopping, a too-broad redirect check, unbounded card text, and Esc passing through.
  - V17: one blocker, a message Claude never read lost when the run ends, and eight should-fix items, among them attachments lost on a failed send, the model chip not following a live change, ↵ able to send `now` into a pending approval, and an unbounded `@` folder read.
  - Both fix rounds go to the merge (`evidence/intb-fixround-v17.md`, `-v18.md`).
- **Planner decisions (18 Oct).**
  - ↵ always sends `next`, as CHAT-SPEC's Keys table says; Read now stays the fast path. S1 §D item 3's Bash-only `now` is not taken: it can land on a pending approval, it races a Bash that just finished, and it moves the command to the background silently.
  - Messages Claude never read are written to the draft store by the driver when a run ends, so nothing sent is lost before V19 puts a composer on stopped sessions.
  - The Edit menu gains Undo, Redo and Cut.

### Closing Release B and opening Release C (20 Oct, night)

The user's word ([D-71](../DECISIONS.md)):
- run the optimizer on the code it had not seen;
- commit the planner docs (164f759);
- write C0's Brief;
- before C, a documentation round and a removal of what is no longer needed;
- then, overnight: if B's close and C's start pass cleanly, go on through Release C in order.

- **The optimizer's delta review** (Opus 5.5, xhigh, read-only, `eadfdc8..9fb8751`; `evidence/release-b-optimizer-delta-report.md`). The planner verified ST-1, X-1, RS-1 and RS-2 in the code.
  - **Blocking, ST-1:** a driver write to the draft store deletes an attachment the composer has not listed yet. The composer writes the file first and lists it at its next save, 300 ms later; `hold` and `release` remove every unlisted file meanwhile. The image is gone after a relaunch.
  - **Should-fix:**
    - RS-1: the cleanup review scans the Claude profile once per row, and runs git even on dismiss;
    - RS-2: two login shells per launch;
    - X-1: a title lands on the wrong card after `/clear`;
    - ST-2: one global lock over every session's draft IO.
  - **Later:**
    - ST-3: mode, model and effort in five places;
    - ST-4: four probe registries;
    - ST-5: `ChatSessionHost.forget` doing two jobs;
    - ST-6: two ways into the forgetters;
    - RS-3: J's resume reads the transcript twice;
    - RS-4: an attachment written twice;
    - RS-5: driver init IO on the main actor;
    - RS-6: an uncapped title retry.
  - **Dead code:** D-1, D-4, D-5, D-6 and D-9 go; D-2, D-7 and D-8 stay. D-3, the terminal-to-Chat handover that release builds cannot reach since D-69, waits for the user.
  - **The planner's decisions:**
    - ST-1, RS-1, RS-2 and the dead code go to the closing fixes (`evidence/b-close-fixes-brief.md`).
    - X-1, with RS-6's cap, comes right after C0, in the title code C0 moves.
    - ST-2 goes to the chat-performance slice, with the known main-thread draft saves.
    - The later items stay recorded here.
- **The closing gate** (`evidence/release-b/gate-close/README.md`). On 9fb8751, 02:39–02:59, every check and build passed, and 2,266 tests ran in release, window tests included, with no failure. This is D-69 (2)'s second run after the r3 gate's one failure, and it covers H, I and J.
- **The closing fixes** (`evidence/b-close-fixes-brief.md`, `wt/bclose`, integrated as 88337a2).
  - **ST-1:** a draft write removes only the files the previous draft file listed and the new one does not. `recoverHeld` sweeps unlisted files once, when a driver is made and no composer exists yet; the planner checked that the only composer is made after its driver.
  - **RS-1:** one worktree verdict per working directory; one batched dry run for every row's size, equal per row to the single plan (the planner checked that the scan's residual does not depend on the ids); a dismissal reads `CleanupPlanner.due` alone.
  - **RS-2:** one login shell per launch, shared through `SystemProviderToolchains.terminalEnvironment()`.
  - **Dead code:** D-1, D-5 and D-9 went.
    - D-4 (`runEndpoint(sessionID:)`) and D-6 (`pendingUserMessageIDs`) stay for now: driver tests use them. They go with the X-1 fix, after C0.
  - **Tests:** the touched suites passed. Six new tests fail on the old code (`evidence/b-close/old-code-demo.out`).
- **C0, the driver split** (`evidence/c0-driver-split-brief.md`, `wt/c0`, integrated as 7f1966f).
  - **The layout:** `ChatSessionDriver.swift` went from 1,961 lines to 532: the declaration, all stored state grouped by the file that works on it, `init`, Reading and the shared helpers. Seven extensions hold the rest: `+Lifecycle`, `+Handover`, `+Sending`, `+Requests`, `+Mode`, `+Queue` and `+Ingestion`.
  - **The planner's check:** a line multiset of the old file against the eight new ones. It differs only in access modifiers, the handover rewrite and the two request cases. The moved bodies keep their awaits, and the public API is the same except `sessionID`'s setter, now internal.
  - **The handover's five flags** are one `HandoverState`. The planner checked each transition against the old flags. The one edge that reads differently, `finishHandover` during the wait, cannot be reached from the controller.
  - **The seam for V22 and V23:** `receiveToolRequest` and `receiveCancel` in `+Requests` are the one place where a request becomes a card.
  - **Tests:**
    - in the slice: the driver suites twice and the UI suites once; two mutations caught;
    - on the combined tree: the union with the closing fixes' suites, 476 tests, all passed (`evidence/integration-c0/`).
- **The planner's X-1 fix** (65ab336):
  - a title answer names the card it was asked for, and only a card the run is still on has its title state changed;
  - a card gets at most three failed tries (RS-6);
  - D-4 and D-6 went: the tests read the session record's endpoint and keep `pendingUserMessageIDs` as a test helper.
  - **Tests:** the nine touched suites passed. Both new tests fail on the old driver (`evidence/x1/`), with two new fake provider switches (`LOOM_FAKE_CHAT_TITLE_DEFER`, `LOOM_FAKE_CHAT_TITLE_LOG`).
- **V20, the Changes tab** (`evidence/v20-changes-tab-brief.md`, `wt/v20`, integrated as dc61a7e).
  - **What it does:**
    - Last turn and Whole session read Claude's own edits from the transcript (`EditScan`, LoomChat, 64 MiB backward).
    - Branch reads git against the merge base (`GitChanges`, LoomCore, through `captureHelper`, which now takes an output limit).
    - Reads happen only while the tab is open.
    - The tab is 556 pt wide, and its width changes only on the user's switch, never animated.
    - Line comments go as one message through the composer's send path.
    - The card's "Open in Changes" opens the tab.
  - **Built differently, accepted:**
    - the hunk model is in LoomCore (`DiffHunk`), so git and the scan share it;
    - a NotebookEdit has no patch, so its hunk has no line numbers;
    - "Open in Changes" picks its scope at the click;
    - the list keeps 1,000 files;
    - changed-line bands are 8%, so secondary text keeps 4.5:1.
  - **The planner's integration changes:**
    - git runs with `-c core.fsmonitor=false`, and the list with `--no-textconv`. Without the flag a repository's own fsmonitor hook ran during a read; the new test fails then.
    - the file cap applies before untracked files are read;
    - the 4 MiB error wording is restored;
    - the inspector evidence command opens Changes;
    - V20's new test used the call D-4 removed. The combined run caught it.
  - **Tests:**
    - seven new suites, with mutations shown in the slice;
    - the touched suites on the combined tree, 204 tests (`evidence/integration-v20/`).
  - **Unverified until the evaluation's window and eye checks:**
    - the hover "+" and click-to-comment flow;
    - the width change as a PTY resize, and `.task(id:)` in a hosted window;
    - Return in the comment box;
    - the git reader in the running app;
    - a stopped Chat session's resume-and-send;
    - real transcripts.
  - **Later (small):** `CleanupWorktreeProtection.live` and `GitWorkspace` run git in the user's folders without `core.fsmonitor=false`. It is the user's own repository, so the risk is low; the same flag would make every read Loom starts by itself start nothing else.
- **V21, Rewind files** (`evidence/v21-rewind-files-brief.md`, `wt/v21`, integrated as e039434).
  - **What it does:**
    - "Rewind files to before this message" sits in a user row's hover footer, on prompts Claude read. It is on only at the prompt: ready, no turn, no request, no handover, no rewind. Otherwise it is off and says why.
    - The dry run is the sheet: relative paths, "+N −M", the "changed outside Claude" marks from V20's scan, and the honest label. Cancel is Esc; Return does nothing.
    - **The driver's order:** the rule, a fresh dry run, Loom's copy, the rule again, the CLI call, then the hashes and the marker.
    - **The copy** is `ChatRewindStore`, in `<data root>/chat-rewinds/`, owner-only, at most 64 MiB a file and 256 MiB a rewind, the newest 3 per session.
    - **Undo** is on the newest rewind's marker until the next send. It names files changed since, checks the copies' hashes, writes atomically and moves a file that did not exist before to the Trash.
    - **The fake provider** keeps checkpoints per message (`ChatCheckpoints.swift`). Its Write over an existing file is now an update with a patch, because V20's scan reads edits from that shape.
  - **Built differently, accepted:**
    - the marker sits at the end of the stream, not right after the target message: it is an event of now, and it names the message;
    - history rows are named by their row id: a history prompt's id is its record uuid, and `LiveHistoryJoin` renames only made-up ids, which are never offered;
    - the real call waits at most 60 s;
    - Undo is not offered after a relaunch; the copies stay until retention or deletion.
  - **The planner's integration changes:**
    - **A rewind Claude never answered** (a timeout, the process ended) kept the copy but placed no marker. The sheet told the user of a copy they could not reach. Now the marker is placed with Undo. A new fake switch (`LOOM_FAKE_CHAT_CHECKPOINTS=die`) and a test cover it.
    - **The queue's Send now and Resume** did not wait for a rewind or an Undo under way, against the driver's own rule. Now they answer busy, with a test.
  - **Tests:**
    - in the slice: the driver suite (12 tests), the store, the UI and flow suites, and the fake provider. Mutations of the idle rule and of the copy-before-call order made 8 of the 12 driver tests fail;
    - on the combined tree: the touched suites, 290 tests (`evidence/integration-v21/`). The one failure was the planner's own wording change, pinned by a test; its rerun passed. Both new tests fail on the slice's driver (`old-code.out`);
    - real Claude: the V21 test passed, with a dry run, the marks from a real transcript, a rewind over a user-edited file, and Undo.
  - **The real-Claude overspend:** 18 Haiku turns against V21's 4.
    - `--suite RealClaudeAcceptanceTests` ran every real test: a1–a8, a7c and a2b.
    - a2 and a7 failed on files that runs on 18 Oct left in their work dirs (`approve/allowed.txt`, `ask/madedir`), not on V21.
    - The later Briefs now run real tests by exact name, in fresh work dirs.
  - **Unverified until the evaluation:** the footer, the sheet and the marker on screen; a rewind of a history row in a resumed session.
  - **Later (small):** `AccRig` reuses its work dirs, so a rerun of the acceptance tests fails on leftovers. It should make a fresh dir per run.
- **The remaining Briefs** now say to run real tests by exact name, in fresh work dirs. V22b and V22c also say that a side chat has no files rewind: the fork shares the parent's folder.
- **V22's first part, the quick question** (`evidence/v22a-quick-question-brief.md`, `wt/v22a`, integrated as 70d7036).
  - **What it does:**
    - ⌘; (File → "Ask a Quick Question…", and the palette's "Ask a quick question") opens a floating card over a live Chat session's stream, at the composer's width.
    - One question at a time goes through `side_question`, with a 120 s wait. Nothing is kept: closing drops the question and the answer, and a late answer is discarded.
    - The panel closes when the session can no longer take a question: stopped, starting, stopping, or held by a handover.
    - **Errors:** a timeout, an error frame, and a CLI without the request each have their own line, and the question goes back to the field.
  - **Built differently, accepted:**
    - "This Claude version has no quick questions" is read from the CLI's own text, "Unsupported control request subtype", because the wire names no capability for the request;
    - the palette action sits in `PaletteAction.swift`, where the enum is;
    - three small edits outside the write area: a `.quick` mode in `ComposerKeys`, one case in `ChatComposerModel+Editor`, and the menu handler in `AppDelegate`.
  - **The planner's integration changes:**
    - **The field takes the keyboard when the panel opens,** also from the main composer. The editor's focus on appearing never takes it from another text field. So with the composer focused, which is the usual case, Return would have sent the question to the session. The new test fails without the fix.
    - the real test no longer switches to `bypassPermissions`; it allows the Bash card once;
    - the unused `QuickQuestionState.closeAll` went, and DEVELOPMENT lists the fake's side-question switches.
  - **Tests:**
    - in the slice: 11 driver tests, and the holder, keys, theme and model-flow suites. Mutations of the late-answer guard and of the stopped refusal made six tests fail;
    - on the combined tree: the touched suites, 263 tests (`evidence/integration-v22a/`).
  - **Real Claude:** 2 Haiku turns and 2 questions.
    - The idle question was answered in 3.1 s, named the code word, and left the transcript byte-identical and without the question.
    - The second met a waiting card instead of a running tool, and was answered in 4.8 s. Its transcript check was taken before the tool call's records landed, so it does not count.
    - The test is fixed, not rerun. A rerun costs 2 turns and 2 questions; it belongs to Release C's real-Claude check.
  - **Unverified:** the panel on screen (placement, focus in a real window, the timer, Esc); ⌘; on a Turkish Q layout; the close on a face switch.
- **V22's second part, the fork engine** (`evidence/v22b-fork-engine-brief.md`, `wt/v22b`, integrated as 9ecc7a9).
  - **What it does:**
    - **The start:** `SessionRuntime.startSideChat` makes the card first, with the fork's lower-case id, in the parent's project and folder, with the parent's model and effort and `--permission-mode default`. It then spawns `--resume <parent> --fork-session --session-id <id>`. A failed spawn takes the card with it.
    - **Identity:** ids are compared without regard to case. A fork-route run's `"fork"` SessionStart never adopts anything or makes a card.
    - **Hiding:** three nullable columns link the card to its parent. One SQL predicate (`listed`) hides side chats from every list, count and search, and one Swift check hides them from the live-state consumers.
    - **The policy** (`SideChatPolicy`) refuses edits and plan mode, allows the Bash commands `ReadOnlyCommand` proves read-only, and leaves the rest as cards. "Allow edits" turns the refusals into cards. "Allow for this session" is not offered.
    - **The ask rules:** `permissions.ask` for the edit tools and Bash in the fork's `--settings`, so the user's allow rules never let an edit through.
    - **The driver's guards:** no "/" sends, no title, no mode, model or effort change, no handover, no rewind store.
    - **Usage:** a side chat's copy of a message never takes it from another session, and the parent's record takes it back.
    - **Deletion:** deleting a parent, removing it from Loom only, or removing a project takes its side chats first, through the verified path.
  - **Step 0 on the real CLI:**
    - the fork read 99.99% of its first context from cache;
    - a `Write` that the folder's allow rules allowed still came as `can_use_tool`.

    The ask rule stays. The real test then showed `echo hi > y.txt` refused as well.
  - **Built differently, accepted:**
    - the usage rule marks side-chat rows with a stored flag bit, fed by a source closure on every refresh;
    - the fork's safety net sits in `ClaudeSessionAdapter`, where the hook's source is known;
    - "Remove from Loom only" removes the side chats the same way, so their files stay too;
    - the fake gained a `~scenario` alias, because a side chat sends no "/" text;
    - the real test reused step 0's own parent dir, made in the same task. The planner accepts it: it was no older test's dir.
  - **The planner's integration changes:**
    - **After a relaunch the supervisor did not know any side chat.** Its restore read the list query, which now hides side chats, so a side chat's next launch, a plain resume, would find no session. The restore now reads `sessions(includingSideChats: true)`.
    - **Removing a project deleted side chats too early.** It deleted the side chats of the sessions still in the project before the emptiness check refused the removal, and the slice's own test asserted that. Now nothing is deleted while a session is left.
    - Both new tests fail on the slice's code (`evidence/integration-v22b/old-code.out`).
  - **Tests:**
    - in the slice: the touched LoomCore (236), LoomChat (170) and LoomCatalogUI (184) suites, and the new suites. The one-card test fails without the stored id, and the usage tests fail without the rule;
    - on the combined tree: the touched suites, 727 tests (`evidence/integration-v22b/`). The one failure, `OpenSessionIntegrationTests.claudeSessionsStartWithLoomsSkillFolderWrittenBeforeThem`, is in code V22b did not touch: Loom's plugin folder was missing from one launch's arguments under load. Its suite passed alone (19 of 19), and the test passed in the five earlier full runs that logged it. Release C's full gate watches it.
  - **Real Claude:** 4 Haiku turns: step 0 used 3, the real test 1. The fork kept the parent's card count at one, refused the two writes, allowed `ls` through the policy, and its discard left the parent's transcript byte-identical.
  - **Unverified:**
    - resuming the parent on the real CLI after a discard;
    - a fork of a parent in mid-turn;
    - the safety net's mismatch branch, which has no test;
    - a side chat resumed after a relaunch on the real CLI: the restore is tested, the resume is not.
  - **Later (small):**
    - the real test needs a parent made beforehand (`LOOM_V22B_PARENT`). For Release C's check it should make its own.
    - `ChatSessionHost.driver(for:)` makes a main driver for any id. Part 3 must always reach a side chat through `sideChatDriver(for:parentSessionID:)`.
- **V22's third part, the Side tab** (`evidence/v22c-side-tab-brief.md`, `wt/v22c`, integrated as 12c2784).
  - **What it does:**
    - **The tab:** the inspector's fourth tab, 392 pt (`Rhythm.inspectorWidthSide`), on a Claude session that has a provider conversation id, in either face. Never on Codex or on a side chat. Where the chosen tab is not offered, the inspector shows Overview.
    - **The thread:** the main chat's own rows over the fork's driver, from its first question on. `TurnModel.sideThread` drops the parent's copied records, and the stream has no composer, so no "Rewind files", "Read now" or "Retry".
    - **The composer:** "Ask on the side". The first question forks, a stopped side chat resumes on the next one, and "New side chat" forks again. "/" text is refused in place before any fork exists. The bar holds Close, the session's model (read only), "Allow edits", "…" (Discard) and Send.
    - **Send to main as a note:** one message to the parent through the composer's path, with the Brief's exact text, then "Sent to the main session". It is off on a terminal-face parent.
    - **Discard:** a sheet whose default button is Cancel, then part 2's path. The parent's deletion sheet names its side chats.
    - **Waiting:** a dot in the tab's count slot, and nothing outside the tab. The slice's flow test compares the attention count, the lists, the menu bar, Home and the palette against a baseline.
  - **Built differently, accepted:**
    - the texts say "session", not "conversation", because the wording guard refuses the latter;
    - Loom learns that a CLI cannot fork by trying: the engine has no capability query;
    - `TurnModel.sideThread` sits in `LoomChat`, because the model's setters are internal;
    - small seams: `sideFirstUUID` in `LiveChatFeed`, `offersSessionGrants` in the pinned cards, `sideNotes` and `columnPadding` in `ChatRowContext`;
    - the side list is read while the inspector is open on an eligible session, not only on the Side tab, so the tab bar's dot has it.
  - **The planner's integration changes:**
    - **"Allow edits" outlived a run of its side chat.** The UI turned it off on Close and before a resume it started, but a run that ended any other way, such as the process exiting or a stop from elsewhere, kept the permission for the next start. The driver now turns it off at every launch, and the UI's reset before a resume went. The new driver test fails on the slice's code (`evidence/integration-v22c/old-code.out`).
    - four unused tokens went (`chipGap`, `sendSide`, `sendGlyph`, `toggleGap`);
    - the docs now say the dot is the attention hue, and that the side list is read while the inspector is open;
    - DEVELOPMENT names `LiveRig.make(forkable:)` and the real test's `LOOM_V22C_*` switches.
  - **Tests:**
    - in the slice: 58 + 3 tests across the new and touched suites. Mutations of the thread's cut, of the "/" refusal and of the note's text made their tests fail;
    - on the combined tree: the touched suites, 313 tests (`evidence/integration-v22c/`). The one failure, `LiveChatDriverViewTests.everyKindOfSendShowsOnceUnderAnOverlappingHistoryRead`, is a timing test: under load its mid-turn send landed after the step had ended, so the fake ran it as a turn of its own. V22c leaves a main session's feed as it was. The test passed alone, and so did its suite. Release C's full gate watches it.
  - **Real Claude:** 3 Haiku turns: the parent's long turn, the side question, and the note.
    - The fork answered the side question, asked while the parent's text streamed. Its thread showed one prompt and one answer, with no card.
    - The parent never saw the side question.
    - The note reached the parent as one message with the exact text, and the parent replied. Discard returned `.deleted`.
  - **Unverified:**
    - "while the parent finishes its turn" only partly: the parent's turn had ended by the time the side answer arrived;
    - a discard that the engine reports as incomplete;
    - the tab on screen.
  - **Later (small):** the engine has no "can this CLI fork" query; Loom learns it on the first fork.
- **V23, Agents live** (`evidence/v23-agents-live-brief.md`, `wt/v23`, integrated as df529d9).
  - **What it does:**
    - **One authority:** the hook ledger lists a run's subagents in both faces. The stream's task records stay the main chat's subagent cards, and the two meet only on `agent_id` = `task_id`.
    - **The hub's request** carries the asking subagent (`ProviderRequestAgent`: id, name, description), filled where a Chat request becomes the hub's. A main-thread, terminal or Codex request carries none.
    - **Waiting, on the Chat face:** the Agents row says "Waiting for you" in the attention tone; the sidebar tree shows the attention mark in place of the chase and keeps that row past the 3-row cap. The open subagent's notice reads "Waiting for you: answer it in the chat", and "Show the request" makes that request the pinned card and scrolls the pinned stack, never the stream.
    - **Waiting, on the terminal face:** the `PermissionRequest` hook carries `agent_id` (real Claude 2.1.300), so the tracker marks that subagent while the session waits. Today's "answer it in the session's terminal" notice stays as the fallback when no hook named one.
    - **A stopped session** lists its subagents from its folder (`SubagentFolderReader`: at most 500, the newest kept, an unreadable meta file skipped). An Agent call without a result in the main transcript, within the lens's bound, reads "Interrupted" (`AgentCallScan`). The read runs only while the Agents tab is open on that session, off the main actor. The empty text is "No subagents in this session."
    - **The subagent card:** one line of the subagent's newest words while it runs, cut at the end, and "Open in Agents".
  - **Built differently, accepted:**
    - the stopped list keeps the view's oldest-first order; "newest first" picks which 500 are kept;
    - `SubagentRecord` gained `wasInterrupted` and `awaitsApproval`, so both states travel in the ledger's entry shape;
    - the newest words already reached the card (`latestProgress`); the slice fixed a cache key that could show a stale line and limited the line to one.
  - **The planner's integration change:** a stopped Claude session whose folder cannot be read stayed blank. With no profile (a refused layout) or no conversation yet, the list waited for a read that never came, so the tab showed no row and no text. Such a list is now empty at once, and the tab says "Agents show while the session runs." The new test fails on the slice's code (`evidence/integration-v23/old-code.out`).
  - **Tests:**
    - in the slice: 261 tests across the touched and new suites. Mutations showed the guards: a main-thread request given an agent, the waiting set's fallback, the tab condition of the folder read, and the old cache key;
    - on the combined tree: the touched suites, adapter, supervisor and lifecycle included, 503 tests, all passed (`evidence/integration-v23/`).
  - **Real Claude:** 1 Haiku turn.
    - A subagent's Bash request reached the hub with its `agent_id`, the card named the subagent, and the ledger listed it under the same id.
    - The `PermissionRequest` hook's payload carried `agent_id` and `agent_type`.
    - **New fact:** the CLI launched the subagent in the background (`async_launched`), so the foreground case is unverified, and the card had no words of its own to show.
  - **Unverified:** the foreground subagent on the real CLI; the live line on the real CLI; the mark, the notice and the card's "Open in Agents" on screen.
  - **Later (small):** a background subagent's Agent call is answered at launch, so a stopped session lists it as "Done" even when the run ended with it still going.
- **Release C's full gate** on df529d9 (`evidence/release-c/gate-1/README.md`), 07:44–08:09, under `caffeinate -d`.
  - **Every check and build passed,** and 2,477 tests ran in release, window tests included.
  - **One window test failed:** `TerminalPartialDrawTests.layerBackingStorePreservesPixelsOutsideTheDirtyRect`. Its capture was blank, because the screen had been locked since 04:39. `--idle` needs an unlocked screen, and the planner did not check it first.
    - Release C changed no line of `LoomTerminal` since 9fb8751, whose gate passed the test.
    - The two flakes the slices met passed in the gate.
  - **Finished at 08:43:** with the screen unlocked, the two window suites ran again: 12 tests passed, the failed one among them. **The gate passes** for df529d9.
- **Next, for the user:** the rest of Release C's evaluation: the real-Claude check (with V22a's rerun), the screenshots, the optimizer and the eye checks.
- **For Release C's Briefs.** A read-only explorer mapped V20–V23 (`evidence/release-c-touch-points.md`). Three technical choices came before their Briefs: V20's diff source per scope, V21's "last write" baseline, and V22's fork identity.
- **Spike S6b** ([record](experiments/v2-spikes/S6b-fork-identity-20261020.md), 5 Haiku turns).
  - **The fork's identity:** `--resume <parent> --fork-session --session-id <uuid>` works, and the fork takes that id everywhere. The SessionStart source is `"fork"`. Nothing names the parent.
  - **Subagent hooks:** `SubagentStart` and `SubagentStop` fire under `-p`, and `agent_id` = `task_id` = the subagent file's id.
  - **The planner's check of its files:** copied records keep their timestamps (25 of 25) and their message ids (4 of the fork's 5 assistant ids). So the usage index could move the parent's messages to a fork; V22's second part guards it.
- **The Briefs** are written, one per slice, in `evidence/`:
  - V20: `v20-changes-tab-brief.md`;
  - V21: `v21-rewind-files-brief.md`;
  - V22, in three parts: `v22a-quick-question-brief.md`, `v22b-fork-engine-brief.md` and `v22c-side-tab-brief.md`;
  - V23: `v23-agents-live-brief.md`.
- **The planner's decisions in them:**
  - **V20:** edit records for the turn scopes, and git against the merge base for Branch.
  - **V21:**
    - the dry run is the sheet;
    - Loom copies the listed files aside before every rewind (64 MiB per file, 256 MiB per rewind, the last 3 kept) and offers Undo from that copy;
    - "changed outside Claude" compares the file's modification time with Claude's last edit record of it.
  - **V22:**
    - the fork's card holds its id before the spawn;
    - one SQL and one Swift predicate hide side chats from every list;
    - a request policy refuses edits and non-read-only commands, by a conservative classifier;
    - `permissions.ask` in the fork's settings, if a two-turn check shows it keeps the cache, stops the user's own allow rules from letting edits through;
    - a copied message stays the parent's in usage.
  - **V23:**
    - the hook ledger is the list's one authority;
    - a subagent's request is marked on that subagent only;
    - a stopped session lists its subagents from its folder;
    - the main chat's card shows the subagent's newest words;
    - the subagent transcript view itself waits for the user's feedback on the panel and the chat-performance slice's R2.
- **For the user: the removals that cannot be undone (D-71).** The disk had 47 GiB free at the night's start and 37 GiB after Release C's gate (20 Oct, 08:15), so nothing needs the space yet.
  - the build caches of integrated slices: about 31 of the 35 GB under `~/Library/Caches/loom-v2/build/` (`v2` and `v2-release*` stay; every slice is integrated now);
  - 35 worktrees of integrated slices under `~/Library/Caches/loom-v2/wt/`, all but `v2`. With `v2` they take 785 MB, and each holds its slice's diff, which is in `v2`;
  - about 650 of the 750 MB of dev packages under `~/Library/Application Support/Loom-Dev/packages/` (the 0.4.4 reference, the latest candidate and its fixtures stay);
  - `~/Library/Caches/loom-v2-research/repos`, 3.9 GB of cloned reference repos;
  - the D-3 code.

### Release C evaluation (20 Oct)
- **The plan,** at the user's word (20 Oct, morning):
  - the real-Claude check, the optimizer and the UI screenshots, then the fix rounds;
  - the gate once more if code changed (D-69 (2)), then the matrix (CPU40);
  - C's eye checks go to the 1.5.0 list.

  Steps that need the screen are asked first.
- **The real-Claude check** (`evidence/release-c/real/RESULTS.md`). The tests were written by an implementer in `wt/evc` (`evidence/release-c-real-brief.md`) and integrated as e9446d8, test-only. The planner ran each by its exact name in the user's Terminal panel.
  - **R1** (V22a, the quick question idle and while an allowed Bash command runs): passes on its third run. The idle answer took 3.3 s; the answer while the tool ran took 3.2 s, and the tool still ran after it. The transcript was unchanged.
    - The first two runs failed on the test. Claude Code 2.1.300 blocks a standalone `sleep`, and the rig's PATH has no `/sbin`, so `ping` was not found and the model asked again, a card nobody answered.
    - The test now runs `/sbin/ping` and refuses any further card.
  - **R2** (V22b, a fork while the parent waits on a card, a relaunch, Discard, the parent resumes): passes.
  - **R3** (V22c, the Side tab's path while the parent waits on a card, then the note): passes.
  - **R5** (V21 after a resume): passes. The history row's dry run lists the file, the rewind restores it, and Undo gives it back.
  - **R4** (V23, a foreground subagent): **a product finding.**
    - The subagent ran in the foreground, the request and the hub carried its `agent_id`, the ledger listed it, and its folder listed it as Done.
    - But its words never reached the card. Claude Code 2.1.300 forwards a subagent's text and thinking only with `--forward-subagent-text`, which Loom does not pass, while the fake provider sends them without it.
    - Goes to fix round 1. R4 runs once more after it.
  - **Spent:** 17 turns and 6 quick questions (§6).
- **The optimizer** (`evidence/release-c-optimizer-brief.md`, read-only, 9fb8751..df529d9) found nothing blocking. The planner checked the decisive findings in the code:
  - **ST-7, confirmed.** The quick-question, Changes and side holders keep a deleted session's state, and its side chat followers, for as long as the app runs.
  - **RS-7, confirmed, and heavier than reported.** Each git call of a Changes Branch read opens its own run scope: a LaunchServices launch of LoomRunHost (`/usr/bin/open -n -g -j`), a handshake and ledger writes. That is 7–8 launches per read.
  - **RS-8, confirmed.** A waiting card moves the indicator off `.working`, so every card makes the Changes tab read again.
  - **RS-10, confirmed.** "New side chat" and opening another side chat leave the previous process running, and the parent's stop does not stop its side chats.
  - **RS-11, confirmed but small.** Each draft save re-reads the draft file. It goes with ST-2 to the chat-performance slice.
  - **RS-13, confirmed.** Three rewinds are kept per session, up to 256 MiB each, but Undo is offered only for the newest, and only in memory.
  - **ST-9, confirmed.** `quickQuestionPanel(for:)` and `ClaudeUsageIndex.setSideChatSource` have no caller. `ChatSessionHost.sideChats(of:)` and `SideChatSummary` serve one test.
  - **ST-8:** the planner found no path that ends a turn or a handover during a rewind, so the queue release's missing rewind guard is recorded as later.
  - **Later:**
    - RS-9: the Changes data of live sessions;
    - RS-12: no index on `parent_session_id`;
    - RS-14: a parent's deletion scans the profile once per side chat;
    - RS-8's other parts: cancelling unwanted scans, and the hidden window.
- **The user's decisions** ([D-72](../DECISIONS.md)):
  - a side chat's process runs only while it is the open one;
  - a rewind's copies live only while its Undo is offered, and are made as APFS clones;
  - the screenshots run now;
  - more Haiku turns are fine.
- **Fix round 1** (`evidence/release-c-fix1-brief.md`, an implementer in `wt/fc1` from e9446d8) covers R4's flag (with the fake provider made to match the CLI), ST-7, RS-8's read at a card, RS-7's one scope per read, and ST-9. **Fix round 2** (`evidence/release-c-fix2-brief.md`, the same worktree) covers D-72's two rules. Both are in progress.
- **The UI screenshots** (`evidence/release-c-ui-shots-brief.md`, an implementer in `wt/shc` from e9446d8, package `v2-C-shots`) are in progress.
- **Next:**
  - review and integrate the fix rounds;
  - run R4 again;
  - the UI review of the shots, and its fixes;
  - the gate once more, with the screen unlocked;
  - the matrix;
  - C's eye checks on the 1.5.0 list, and the close report.

### Release C after its evaluation (20 Oct, afternoon)

- **[D-73](../DECISIONS.md) changed the rest of the evaluation:** the screenshots stopped, and their review and C's eye checks are dropped (D-72 (3) is superseded); the terminal matrix is skipped, because C changed no terminal code; the health check below ran instead. The earlier "Next" and "in progress" lines about Release C's evaluation are superseded by this section.
- **Integrated** as 371aaf6, after the planner's review: fix rounds 1 and 2 (R4's flag, ST-7, RS-7, RS-8, ST-9, and D-72's side chat and rewind-copy rules). Each regression test fails on the old code (`evidence/release-c/fix1`, `fix2`).
- **The health check of D-73** on 371aaf6 (`evidence/release-c/health/`):
  - R4 passes: a waiting subagent's card carries its words;
  - Release A's real app check (`claude_real.py`) passes every check: a turn and its status, an idle session's cost, Stop empties the run scope, and Quit leaves no owned process and touches no outsider.
- **The gate once more** (`evidence/release-c/gate-2/`) failed one test, SideChatFlowTests line 349. It is a test race:
  - the test's wait counted the parent's pending message row as an answer, so the fork could copy the parent's file before the message was in it;
  - the test-only fix in `wt/sideflake` waits for the CLI's answer. It passed the suite 10 times out of 10 and the whole LoomCatalogUITests target (`gate-2/sideflake/`). It is not integrated yet.
- **The same investigation found a rare product bug.** A side chat's first send awaits the catalog write before `beginTurn()`. When the fork's first turn ends inside that wait, the side chat stays "working". It is reproduced only with an injected delay, and is proposed as its own task.
- **Next, at the user's word:** integrate the test fix, record Release C's close, and commit the planner docs. Meanwhile the UI revision goes on (§13).

### Release C's close (21 Oct, night)

- **Closed** by [D-83](../DECISIONS.md), as v2 cc54a17, after the planner's review; the "Next, at the user's word" line above is done.
- **The test race:** SideChatFlowTests waits for the CLI's answer before the fork copies the parent's file (`evidence/release-c/gate-2/sideflake/`).
- **The rare product bug:** a side chat whose first turn ends while its send still awaits the catalog write no longer stays "working". The driver counts the turns that end and begins one after the send only when none ended during it. A side chat with a message on its way is not settled, so retiring it waits for its turn's end. Both regression tests fail on the old code (`beginturn-1-unfixed.log` there).
- **Before it,** v2 4080709 carries the Ink design and its docs (D-73 to D-82).
- **Left for the 1.6.0 install:** Release A's and B's eye checks; C's were dropped (D-73).

## 13. The UI revision: Ink

**Authority.**
- [D-73](../DECISIONS.md): start the UI revision as soon as possible after Release C. The user does not like the current look (not clean, not modern).
- [D-74](../DECISIONS.md): Ink is adopted, the design docs follow it, and the next preview comes after them.
- [D-75](../DECISIONS.md): Phase 2, the chat, is accepted, and the user calls the direction v3.
- [D-76](../DECISIONS.md): preview 03, the project page, is accepted.
- [D-77](../DECISIONS.md): the identity is accepted: Sphyrna, Remora, the Rising icon and the Front mark.
- [D-78](../DECISIONS.md): preview 05, the review surfaces, is accepted.
- [D-79](../DECISIONS.md): preview 06, the edge and system states, is accepted, with the Animated art switch.
- [D-80](../DECISIONS.md): preview 07, Remora, is accepted, with the remora's disc.
- [D-81](../DECISIONS.md): preview 04, Settings and About, is accepted with the planner's answers: the tones as casts, Glass at 0.8 with Solid the default.
- [D-82](../DECISIONS.md): one design reference holds every preview's current state, a landing page comes from it, the old design files go, and the design docs are audited.

**The design came first, in previews, and is done.** The planner drew each phase as an HTML preview, the user reacted by eye, and the accepted state went into [design/DESIGN.md](../design/DESIGN.md). Every preview is accepted: Phase 1, the language and the shell (D-74); Phase 2, the chat (D-75); 03, the project page and the new-session page (D-76); the identity (D-77; its open questions, O-14, settled by D-83); 04, Settings and About (D-81); 05, the review surfaces (D-78); 06, the edge and system states (D-79); and 07, Remora (D-80).
- **The reference** ([design/reference.html](../design/reference.html), D-82) gathers them, each brought up to date with the decisions that came after it, and is the build's visual target: a step is checked against its window there (DESIGN §1, §3 Visual acceptance). Its sources are `design/reference-src/`, built by `build.py`.
- **The landing page** ([design/landing.html](../design/landing.html), D-82) shows eight of those windows with plain copy, in Sphyrna's voice.
- **Settled by [D-83](../DECISIONS.md):** O-14, the rename's macOS identity (§14), and the reference's two Settings readings, which DESIGN §2 now holds as rules.

**The build** runs since 21 Oct on the ink track, in steps that the main session integrates on `v2` ([D-83](../DECISIONS.md), §14). Each step:
- carries its regression tests and the contrast tests for its pairs;
- updates UI-MAP for what it moved.

Screenshots waited for the user's word (D-73); D-83 gives it for the run, so each step is compared with its window in the reference in evidence screenshots. The user's eye checks stay on the 1.6.0 install's list.
- **I1 Tokens.** The Ink and Paper values in `LoomTheme`, by role: the canvas, raised 1 and 2, the popover, the lines and fills, the four text tiers, and the tree, grid and art colours. The old panel family is remapped, its three tones become the casts Neutral, Warm and Cool ([D-81](../DECISIONS.md)), and the contrast tests move to Ink's floors.
- **I2 The shell.**
  - The one canvas: no panel inset or border, and the sidebar Solid by default.
  - The header with its hairline and the control family.
  - The session tab row: 36 pt, tinted pills with the project's mark.
  - The inspector's view tabs and its facts layout.
- **I3 Status and rows.**
  - The braille spinner, as a layer animation of pre-drawn frames. It replaces `ChaseDots`, the menu bar badge included, and its WindowServer cost is measured.
  - The 7 pt dots, the project mark and the tinted selection.
  - The harness marks on every row, card, tab and header. `ProviderIcon` learns to draw the ChatGPT knot as a template image.
  - The list heading's view switch and the activity view's cards.
  - The subagent branches.
- **I4 Pages:** Home's band and lists, the new-session page, the project page as [the reference](../design/reference.html#project) draws it, and the empty and waiting panes.
- **I4b Settings and About,** as [the reference](../design/reference.html#settings) draws them (D-81): the window with its view tabs in the title band, Theme's tone casts, the sidebar Solid by default with Glass at 0.8, Usage's four cards with plan limits first, and About. Remora's tab comes with Remora.
- **I4c The edges,** as [the reference](../design/reference.html#edges) draws them (D-79, DESIGN §19): the ended line and the record, the banners, the menu bar's states and its menu (the Front mark itself is I7's), the notification, the Dock badge and the alerts.
- **I5 The art.** A spike comes first: a native ASCII renderer, at most 24 fps while visible and zero wakeups while hidden, with its cost weighed against O-01. Then the school goes onto the surfaces of DESIGN §17, with Theme's Animated art switch (D-79), which moved here from I4b so that the switch comes with what it controls.
- **I6 The chat,** as [the reference](../design/reference.html#session) draws it: the stream, the composer with the one model chip, the pinned cards and the asides.
- **I6b The review surfaces,** as [the reference](../design/reference.html#review) draws them (D-78): the Changes tab's status letters, old paths, wrapping lines and four empty sentences with their sharks; the Agents tab's rows without the accent badge and its transcript at 556 in two voices, with "Result"; and the sheets' one rule, which changes Delete's filled red button and Discard Side Chat's Cancel default, and splits Delete's facts into Removed and Kept; with Title Case for every command (D-69).
- **I7 The identity** (D-77), with 1.6.0: the app icon from its two layers, the Front menu bar mark in place of the ram's (the badge slot stays), the name in the bundle and in every sentence that names the app, and README's text and renders (`scripts/release/README.release.md`, and new Ink sources, `design/readme/*.html`, from the reference's documents, as the Night Fleece ones were removed on 21 Oct); the README and `assets/readme/` still show 0.4.4's terminal-only app. Remora's place and arrival on Home come with Remora. How the rename reaches macOS is D-83's: the bundle id, the data folder and the repository stay, and the wordmark is SF Pro (§14).

**Order** (D-83, §14). The build comes after Release C's close and before the chat-performance slice, so that the slice measures the Ink chat, and within it the chat (I6) comes early. D-70 placed the slice after C; D-73 asked for the UI revision as soon as possible.

**Records.** The planner recorded each phase's acceptance here and in DESIGN.md; the reference changes with DESIGN.md, and UI-MAP follows each build step. The design docs are written on `v2` and mirrored on `swarm/1` when the planner docs are committed.

## 14. Toward 1.6.0

**Authority.** [D-83](../DECISIONS.md), 21 Oct, night: the user sets the path to Sphyrna 1.6.0, the first stable release, and gives the main session full authority for the run. Today's code is its 1.5.0 pre-release, and the design is Ink (v3, §13).

**The flow and the goals.** Design first (done, §13), then a structure that fully supports it, then optimization, sustainability and scalability, then acceptance against three goals:

1. **Light.** RAM, CPU, disk and energy never tire the user, and every function stays.
2. **Sessions, not harnesses.** Sphyrna is the one place that manages every session, whatever its harness, so that work can pass between Claude and Codex, and sessions can find, or ask to open, the sessions they need.
3. **Cost out of sight.** The subscription quota and the context cost stay invisible. Nothing enters a session's context beyond the project's own instructions, except that the session knows it runs in Sphyrna and can use some of its functions.

**Tracks.** Two planner-reviewer sessions (Opus 5.5, xhigh) run the work. Each has its own branch and worktree, cut from `v2` at cc54a17, its own implementers, and its plan, Briefs and evidence in `~/Library/Caches/loom-v2/evidence/` (`ink/`, `core/`).

| Track | Branch and worktree | Queue | Write area |
| --- | --- | --- | --- |
| sphyrna-ink, the Ink build (§13) | `ink`, `wt/ink` | In batches, each reported once accepted: I1; I2 and I3; I6, reported as soon as it is ready; I4; I4b and I4c; I6b; I7; then I5's spike. Remora's UI waits for the main session's word | `Sources/LoomCatalogUI`, the app's UI files in `Sources/loom-app`, `assets/`, `design/UI-MAP.md`, `Tests/LoomCatalogUITests` |
| sphyrna-core, the structure | `core`, `wt/core` | C1, the session service's design note, which the main session accepts before C2; C3, the cost and context audit, with the contract's rules proposed and their guard tests; C4, Remora's spike S10; C2, the refactor into the session service, in steps without behaviour change; C5, the channel's first step: a session lists sessions, read only, and asks to open one with the user's approval (D-40, D-42); C5c, the skill's description that says the session runs inside Sphyrna (D-85); C6, the core changes the edges need, on request; C7, the chat-performance slice, from a baseline taken first, after I6 is integrated; C8, the resource budgets (O-01) | `Sources/LoomCore`, `Sources/LoomChat`, `Sources/LoomLaunchOptions`, the helper executables, `scripts/`, their tests, docs/ARCHITECTURE.md and DEVELOPMENT.md |

Shared files (`CatalogModel*`, `ConversationController.swift`, the app's evidence and live-rig files) change in one track at a time, in the order the main session sets. A track that needs a change in the other's area asks the main session, which relays it or grants it for one slice.

**Protocol.**
- A track commits each accepted slice on its own branch and tells the main session "Ready for integration: <track> <sha>", with its checks and its Doc impact.
- The main session reviews the diff and the decisive evidence, applies the slice on `v2` and commits it there. When the branches drift, it asks the track to rebase on `v2`.
- Only the main session writes STATUS, ROADMAP, DECISIONS, `plans/`, the contract and DESIGN.md.
- Builds and heat follow DEVELOPMENT §2 to §4: one build at a time through the build slot, a clean `pmset -g therm` before a heavy step, 90 s between heavy cells, and `caffeinate -d` for runs that need the screen. Real Claude runs only in the isolated profile, with Haiku by default; S10 may use a few Sonnet 5.5 turns (§6).
- **Tests** (D-83): each slice runs `scripts/check.sh` and its own regression tests, which fail without the fix when run alone. Whole suites run at a batch's end where it changed behaviour or ownership, and the full gate runs on the integrated head before acceptance, not after every step.
- **Idle windows** (D-85): the Mac is in use through the working day, and the user says when it is idle (about an hour at lunch, and the evening). During the day, slices build and run their own suites off screen, one build at a time, and deliveries are integrated on those checks. Window tests, visual pairs, whole-target sweeps, measurements and long real-Claude runs wait in the idle queue, which each Ready message adds to with a rough duration. The main session runs the queue in the windows the user announces, with the tracks' builds paused. A failure found there becomes a fix slice and holds nothing else.
- **Disk:** a slice's scratch build folder (`~/Library/Caches/loom-v2/build/<slice>`) goes once the slice is integrated. On 21 Oct the build folders of finished slices had grown to 76 GB and left the Mac 9.6 GB free; removing 59 of them freed 56 GB.

**The planner's decisions under D-83.**
- **The rename:** the app is named Sphyrna wherever it is named. The bundle id `local.loom.desktop`, the data folder and the repository stay (D-83). The executable's and the bundle's file names stay too for now, so that the scripts and the promote path keep working; the user can rename them at the release. The wordmark is SF Pro.
- **Codex** stays frozen (D-28): its entries are shown but cannot start (D-69). The session service takes it as a second harness behind the same protocol.
- **The session service** (C1's note, `evidence/core/SESSION-SERVICE.md`, accepted on 21 Oct). Today a session is owned in about nine places, and the UI decides the face and orchestrates Chat. The target:
  - a `SessionService` façade in LoomCore owns every session's lifecycle, transition state and face;
  - `FacePolicy` decides the face of every start, resume and approved opening;
  - `SessionDirectory` answers harness-neutral summaries for the channel, the palette and Remora;
  - `HarnessCapabilities` replaces the UI's `provider ==` gates, and later a `Harness` protocol takes the adapters;
  - LoomChat stays Claude's structured face, behind a LoomCore protocol;
  - no new target, and views and `CatalogModel`'s view-facing API keep their shape.

  It comes in steps R0 to R7, each without behaviour change and with its proof: R0 to R4 tonight; R5 and R6, which move the orchestration and split `ChatSessionHost`, after I6 is integrated, each rebased on `v2`; R7, the `Harness` protocol, when the queue allows.

  R5 comes in two halves (21 Oct, afternoon):
  - **R5a** moves start, resume, stop, the answers (the open requests' too) and deletion, with their transition state (`busy`, the start keys, the approvals in flight), into `SessionService` in LoomCore. Two protocols sit behind it: `StructuredFaceHost`, which `ChatSessionHost` conforms to, and `TerminalFaceSinks`, which `ConversationController` implements. The views and the `ConversationIntents` seam do not change.
  - **R5b** moves the Chat → terminal handover, rename, pin and titles, and removes the evidence duplicates and the test-only members.
- **The handover between the faces** (the optimizer's D-3) goes in R1, in one direction only. Terminal → Chat goes: only an evidence command calls it. Chat → terminal stays: release builds reach it through the policy banner's Switch to Terminal.
- **An approved opening** starts in the face that "Sessions run in" names, as every other start does (D-69 (1)); today it always starts in the terminal. The change comes in C5, with its own test.
- **Remora's build** (L1 to L3) goes ahead: S10 shows that its cost fits the third goal, with one background brief a day, capped and switchable, and questions only when the user asks. L1 follows R0 to R4 and C5 on the core track, L2 follows L1, and L3, the UI, waits for the ink track.
- **The contrast floors** (batch A): DESIGN §3's values missed three of its own floors. The tree's turns are structure, like the hairlines, and keep their colour with no 3:1 floor; the pressed fill, being momentary, sets no text floor; Paper's tertiary becomes #67656B (DESIGN §3, v2 62b0423).
- **Remora's calls keep prompt caching** (D-84), **for an hour** (D-85). The planner had first turned it off (`DISABLE_PROMPT_CACHING=1`), because two consecutive packs shared only 1.7 to 6.5 % of their tokens and the CLI's 1-hour write doubles a cold call's input price, and then proposed a five-minute lifetime; the user rejected both. Slice L1c, on the core track with or before L2, turns caching back on and pins the hour (`CLAUDE_CODE_PROMPT_CACHE_TTL=1h`). It orders the pack so that calls share their prefix: what stays first (the rules, `Remora.md`, the project notes, a stable session index), and what changes with every call last (today's journal lines, the sessions' moving fields, the counters, the time, the previous exchange and the question). A follow-up keeps its picks, and the brief and a question over an unchanged catalog share their leading blocks byte for byte. Its probe asks a question ten minutes after the first.
- **An agent knows it runs in Sphyrna** (D-85): slice C5c rewords the one skill's description so that it first says that the session runs inside Sphyrna, the desktop app that hosts it, then what Sphyrna can do for it, in at most 300 characters. Nothing else enters the context (contract §10).
- **Remora's role** (D-85): its rules gain one sentence on what it is for, after the one that names it (L1c).
- **The sidebar's search field** is the palette's door, as DESIGN §2 and the reference draw it: "Search" with ⌘K in mono, and a click opens the palette. ⌘F opens it too, the palette's session matching covers the old filter's title, provider and project, and the inline filter goes.
- **The inspector's Overview** (I2c, after I6) follows the reference. It has no Why line and no Last activity row: the header's pill and reason line say the state, and the sidebar's row says the time. Agents shows once the session has had an agent, as "Agents · N running", and Started is the session's creation. There the effort is the CLI's own lowercase word, while the composer's chip keeps "High". Its two LoomCore fields come first as core's C6a: the toolchain's version, and the live permission mode and effort from the hooks.
- **The sidebar's default width** stays 300 (DESIGN §3); the reference's 260 is its mock window.
- **Batch D's pages** (I4) follow the reference where DESIGN was silent, and DESIGN §8 and §9 now say so:
  - Home's Continue is the lists' first card, above Needs you, in both layouts; below 820 the side column goes under the lists.
  - Home's rows carry the harness's mark before the title (§6, and the reference's rows).
  - The draft page's header line holds the reference's crumb ("<project> / new session") and "N sessions in <project>", a small ghost button to the project's page, left out while the project has none.
  - The draft's folder line shows the folder and branch only. Its clean or dirty state would need Git before the first send, and nothing runs before it (DESIGN §8; `GitWorkspace` runs Git only at the first send).
  - A new branch's or worktree's name is asked in a small popover from its segment.
  - P8, the project page's ⋯ menu, waits only for 9b, and the draft's Send tooltip goes with the draft page: neither changes a start call, so neither waits for R5a. Batch D's shared files are `CatalogModel+Home.swift` and `CatalogModel+ProjectPage.swift`, additive.

**Acceptance of 1.6.0.**
1. Every surface matches its window in the reference, in Ink and Paper and in every tone, and UI-MAP says what the code draws.
2. The full gate passes on the integrated head: every suite, the window tests, the ownership, Stop, Quit and deletion suites, and the real-Claude checks.
3. O-01's budgets are set from fresh measurements and met, and a visible Chat stream costs no more than the terminal for the same output.
4. One session service owns every session's life and state, whatever its face or harness. No session is lost when the face changes or the app relaunches, and a session can find sessions and ask to open one, with the user's approval.
5. Every model call Sphyrna makes on its own is listed, measured and under its ceiling, and a session's context holds only the additions the contract names. Guards fail when either grows.
6. The optimizer's review (Opus 5.5, xhigh) is done, and its blocking findings are closed.

**Stopping.** Nothing is rushed to finish by morning (D-83). The run stops in a healthy state: each track ends on a committed slice, `v2` passes `scripts/check.sh` at its head, and STATUS says where each track stands. The tag, the promote, the install, the push and the GitHub release wait for the user.

### Results toward 1.6.0

- **S10** (C4) is done: 15 calls, 11 Haiku and 4 Sonnet (`evidence/core/s10/S10-REPORT.md`).
  - The one-shot call works with no tools, a replaced system prompt (about 650 tokens of overhead), no setting sources and no session persistence. It leaves no residue, and the non-essential-traffic switch leaves two sockets, both Anthropic's.
  - A Sonnet brief costs about $0.13 cold and $0.01 warm; a Sonnet question about $0.06 cold and $0.01 warm; Haiku about a sixteenth of that. That is about twice the brainstorm's estimate, because the CLI writes the cache at the 1-hour tier.
  - The child needs `USER` in its environment, and a classifier's refusal reads `is_error: true` with the subtype success.
- **Integrated on `v2`:**
  - **R2, the session directory** (465be7e, a fast-forward of `core`): `SessionDirectory` answers harness-neutral `SessionSummary` values (title, project, state word, harness, live face, last activity) in one bounded catalog read joined with the hub's snapshot. It holds no transcript content and no path, and its state word follows the sidebar's indicator, held together by a test. It is additive, with no caller yet.
  - **I1, the Ink and Paper tokens** (bc0366c, cherry-picked from `ink` 56dd041). Every colour token resolves by role to its Ink or Paper value in the three casts, and the Night Fleece names alias their Ink roles, so the whole app draws Ink's colours before any surface is redrawn. A stored tone decodes as its cast, and Ink's type and shape scale are tokens no view uses yet. The check on the combined head passed: build and four suites, 51 tests, the 14 known issues being the three contrast questions decided above.
  - **I1's follow-up** (f20a38c, a fast-forward): Paper's tertiary at #67656B, the contrast tests under the new floors with no known issue left, and LoomTerminal's compiled default background at Ink's Neutral canvas.
  - **R0, the characterization tables** (6f03faa): the face of a start, a resume, a stopped view and an approved opening under the switch, and each harness's capabilities in the production and development identities, as today's code answers them. The refactor's later steps must keep them.
  - **R1, the optimizer's D-3** (2af1755): the terminal-to-Chat handover is gone, with its six tests. Chat → terminal stays, for the policy banner, and `continue-in:<id>:chat` is refused as unsupported.
  - **C3, the cost and context guards** (9a58b3c): a Chat session's title asks from at most 2,000 characters of the first message, cut as the CLI cuts its own; before, the whole message went. `PluginContractTests`, `LaunchContractTests`, `HookSilenceTests` and `ChatModelCallTests` pin what Sphyrna adds to a session's context and which requests cost a model call; each was shown to fail on a planted break. The contract's §10 holds the rule (9b9b12b).
  - **C5a, the channel's first step** (c4e6187): `"$LOOM_CLI" sessions` lists the user's other sessions from the directory, read only: id, harness, title, project, state word, face and last activity, at most 100 rows and 60,000 bytes, on the control socket and token of `open`. It holds no content, path or transcript and needs no approval. The plugin's one skill names both verbs in 279 characters and says Sphyrna; `open` always starts a new session. Contract §7 and DESIGN's open-request rule follow (da34711).
  - **R3, the harness capabilities** (f7c456d): `HarnessCapabilities` answers what a harness may do in this build, and every gate in `CatalogModel*` and `ConversationController` reads it instead of the provider.
  - **R4, the face policy** (09fcde3): `FacePolicy` decides the face of a start, a resume and a stopped session in one pure place; an approved opening still starts in the terminal until C5b. The `SessionService` class comes with R5, when it takes its first duties, rather than as an empty skeleton.
  - R0's tables passed unchanged after R3 and R4.
  - **Remora's L1a, the call** (b3c39c0, a fast-forward). The supervisor gains an owned streaming helper: stdin written then closed, bounded stdout and stderr, a deadline that sends SIGTERM and then SIGKILL, an end on cancel, and Quit stops it. Locally spawned helpers now start with default signal dispositions and an empty mask, as the run host's do.
    - A new target, `LoomRemora`, runs one `claude -p` child per question or brief with S10's argv and an exact environment, the pack on stdin. It streams the text, then the answer with usage, cost and model, and reads a failure from `is_error` or `terminal_reason`. A closing `remora` block is bounded and validated. Not wired into the app yet.
    - Its probe, one real Haiku brief with prompt caching off: no cache write, $0.0047 against S10's $0.0069. The planner then turned caching off for every Remora call, with L1b; the user rejected that, and Remora keeps caching (D-84, L1c).
  - **C5b, an approved opening's face** (4e83775, a fast-forward): it follows "Sessions run in", like every other start. In Chat the new session takes the request's title (no title call) and the request's message as its first message. Its regression test fails on the old code, and R0's face table changed in that one cell. DESIGN and contract §7 follow (1469b4f).
  - **R7, the `Harness` protocol** (a73bc22, a fast-forward): the runtime holds a `HarnessRegistry` (Claude's and Codex's harness) in place of the two adapter fields. The harness answers the provider-specific part of a start, a resume, a run's end and a deletion, so the runtime no longer branches on the provider there. The shared launch helpers stay runtime extensions. LoomCoreTests passed whole, 884 tests.
- **The second holistic check** on `v2` 1469b4f (C5a, R3, R4, L1a and C5b with the first batch) passed 2,569 of 2,570 tests (`check-20261021T040644-37920.log`). The one failure, `SessionRuntimeCodexTests.stoppingOneCodexConversationEndsItsOwnTUIServerAndScopeOnly(scoped: true)`, timed out waiting for the Codex threads to bind under load; it passed alone three times in 2.9 s and in R7's whole LoomCoreTests run. It goes to the core track for hardening before the full gate.
  - **The process-heavy tests' hardening** (4c04a5c, tests only): waits after a process start allow 30 s, a failed Codex join ends its wait at once and names the card's issue, and the streamed-helper tests prove streaming by order, not by clock. It fixes the Codex flake and a second one of the same kind that core found under load. The next holistic run is the proof.
  - **Remora's L1b, the pack and the brief's schedule** (4ca3d5c, a fast-forward). `RemoraPackBuilder` lays out memory, the fixed self lines, now, the session index from the directory, masked transcript excerpts (about 6 KiB a session, at most 8 sessions, picked by relevance), the previous answer and the question. It stays within 14,000 tokens for a question and 30,000 for a brief. Codex sessions are listed and never read, secrets are masked, block tags in session text are defused, and an excluded project never appears. `RemoraSchedule` decides run, wait or skip for the morning brief; the day starts at 04:00. Measured on 50 synthetic sessions: a question pack is 13,722 tokens and a brief pack 15,362. It also ran every call with prompt caching off, which D-84 reverses (L1c).
  - **The design folder** (a7374c7, docs, the user's change of 21 Oct, morning): the previews from before the reference are kept in `design/pre-reference-preview-pages/`, and the README's Night Fleece sources are gone.
  - **Ink's batch B, the shell and the status** (e5b52a0, a fast-forward of ten commits): the shell on one canvas with the 52 pt header and the tab row; the inspector's view tabs and facts; the braille spinner and the 7 pt marks; the sidebar in Ink, its search field the palette's door (⌘F and Edit > Find open the palette, and the inline filter is gone); the subagent branches, with the rows' status column on the branches' 22 pt line. Its check off screen: LoomCatalogUITests whole, 1,255 tests with one issue, the inspector's width test expecting the old 756 against the flush pane's 772, fixed by value (`check-20261021T103325-92184.log`). That run put windows on screen for a moment, because its filter missed the window suites nested under `WindowEventTests`; runs off screen now leave that suite out whole. Its doc impact (db9ba46): the knot's template is bundled, DEVELOPMENT §5's search rows mean the palette, and DESIGN takes its notes. Its window tests and visual pairs wait in the idle queue (D-85).
  - **Remora's L1c, the cache** (7c434a1, a fast-forward; D-84, D-85). Caching is back on, with `CLAUDE_CODE_PROMPT_CACHE_TTL=1h` in the guarded environment. The probe showed that a pack on stdin, one block, is never read back beyond the rules (842 tokens), because the API reads a cache only at a block boundary where an earlier request wrote one. So the stable part goes into the system prompt after the rules, through a per-call `--system-prompt-file` (0600 under `<data root>/remora/`, removed after the call, only its path on argv): `<memory>` (`Remora.md` and the project notes), `<self>`, and the session index (id, title, project and harness, in id order). A question a minute after a brief then read 4,193 tokens. What moves goes late: `<activity>` (each session's state and last activity), `<journal>` (today's and yesterday's lines), the excerpts oldest activity first, `<previous>`, `<now>` and the question. Remora's rules gain the sentence on what it is for. Four Haiku calls, all at 5m (`evidence/core/l1c/probe.md`).
    - **The tail's lifetime** (O-15, settled by D-86): the tail, the excerpts and the question (about 13k tokens), is new with every call and is written to the cache too, never read. At 1h on everything, a Sonnet question's input side costs about $0.054, against $0.035 with caching off. An undocumented CLI key, `CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL=5m`, keeps the system part's hour and writes the tail at 1.25× (about $0.034). Remora takes it, since a probe of three Haiku calls confirmed it: the system part (3,540 tokens) was written under the hour and read back by a question a minute later and by another about eleven minutes after the write, and every tail was written under five minutes. On Sonnet's prices a question's input side is then about $0.0385, against $0.0376 with caching off and $0.0614 at the hour on everything (`evidence/core/l1c/probe.md`, "Mixed lifetime"). The key, its guard and a drift count in `RemoraUsage` (a call whose hour-long write is more than three times its system prompt) land with L2.
  - **Remora's L2, its memory and persisted use** (cf0da73, with 98d900a, a fast-forward; D-86). `RemoraMemory`, an actor over `<data root>/remora/` (files 0600, directories 0700, atomic writes), keeps:
    - the journal: one line per call, by day for 14 days, then by ISO week for 12 weeks;
    - the project notes: at most 2 KiB, dated and citing session ids, with edit, remove and undo;
    - `Remora.md`: Remora writes only under its own headings, at most 8 KB, and leaves the user's own text as it is;
    - `usage.json`: 14 days of use.
    "Remember …" (and "Hatırla …") saves without a call. Applying an answer writes the journal line, replaces only the moved projects' notes and returns the proposed facts. Excluding a project deletes its note, Clear keeps `Remora.md` and the use counters, and a permanently deleted session's journal lines go, as LOMBOT §3.5 says. The share fills L1c's two parts, at most about 3,000 tokens. D-86's key is in the guarded environment, a drift count records calls whose hour-long write is more than three times the system prompt, and stale system prompt files are removed. 105 tests (`check-20261021T112142-14020.log`). Remora's probes since L1a: 8 Haiku calls, about $0.027 (L1a 1, L1c 4, the mixed lifetime's 3).
    - **For L3:** register `RemoraMemoryForgetter` as a `ConversationForgetting`; pass `memory.usage` to `RemoraCall` and remove stale system prompt files at start; give the share the session→project and project-name maps; choose `Remora.md`'s default path and Settings' Choose…; show the drift count in the usage view.
  - **C5c, an agent knows it runs in Sphyrna** (33b0cf6, a fast-forward; D-85): the one skill's description, 283 characters, now opens "This session runs inside Sphyrna, the desktop app that hosts it." and then says what Sphyrna can do for the session and when to use it. `PluginContractTests` pins the text, its opening and the 300-character cap; no system prompt or hook output is added.
- **Lunch's idle window** (21 Oct, 12:03–12:23, D-85):
  - Batch B's window tests passed: WindowEventTests and SidebarStatusTests, 40 tests (`check-20261021T120337-24846.log`).
  - Its 18 visual pairs (the shell, the header and tab row, the sidebar in both views; Ink and Paper in three tones) match the reference in look (`evidence/ink/batch-b-lunch.md`). Five small sidebar gaps go to ink's fix slice 9b: the activity headings' inset, the project head's attention dot, the New session row's mark and key, the rows' spacing and the titles' start.
  - Hover passed. The Glass sidebar's shots look like Solid at 0.8, so Glass goes to the user's eyes (DESIGN §3 Visual acceptance).
  - **The third holistic check** passed on `v2` 33b0cf6: every test target without the window tests, 2,679 tests, LoomCoreTests whole among them (`check-20261021T120511-25534.log`). The Codex stop test that failed under load in the second check passed, which proves 4c04a5c's hardening.
- **C6a, the Overview's LoomCore fields** (b9dce6b, a fast-forward; for I2c). The terminal face's hooks now report the session's permission mode and effort in the CLI's own words (UserPromptSubmit, PermissionRequest and Stop on 2.1.300; main-thread events only, since a subagent may run in its own mode). The hub keeps the last known value and clears both when a run starts or ends. `SessionRuntime.toolchainVersion(for:)` answers the cached `--version` probe, with no new process. A change by Shift+Tab or `/effort` shows at the next hook, and a session that still runs an older binary after a CLI update shows the newer version. 95 tests, with a mutation check of the subagent guard (`check-20261021T122947-35896.log`).
- **C8's tooling** (3794c22, a fast-forward): `chat_stream_cost.py --idle` measures Chat sessions at rest, for C8's idle budgets (O-01). Each session runs one short turn, then the cell samples it at rest, and a record inside the window makes the cell invalid. Checked off screen; its first run with the app is the evening's smoke cell.
- **Ink's batch C, the chat in Ink (I6)** (7168e7f, a fast-forward of four commits; its doc impact f7e2ca7):
  - The stream (I6s): the user's message is the one bubble. Work rows are 26 pt, a failure loud (the dot, an output box with the last 12 lines, a failure edge) and a success quiet. Groups and turn folds sit on the tree's branches (`ChatTree`). Also the live row, the markers, thinking, the cards, code blocks, the view chip, Jump to Latest and "Rewind Files to Before This Message".
  - The composer (I6m): the docked card in the chat's 700 column, with one model chip and one 332 pt popover (the other harness's models dimmed, the effort track inside). Send says what Return does. Also the mode chip, the + menu, the context ring's popover, the queue drawer, attachments and the / and @ menus.
  - The pinned cards and the asides (I6p): the cards per E1–E3 ("1 of 3" with step buttons, the command box, numbered options), and the chat banner as §19's box with a "+N" peek. The live row says "Waiting for you" while a request waits. Jump to Latest and the quick question sit above the composer, and the Side tab is drawn in Ink.
  - Checks:
    - The offscreen run of the UI tests (WindowEventTests left out) on 9bbad33 had 1,293 tests and one issue (`check-20261021T135035-59034.log`): a 3 s wait for the waiting flag, which a loaded run outlasted.
    - 7168e7f gives that wait 10 s, as LiveChatFeedTests' waits have. PinnedInkTests and LiveChatFeedTests then passed, 31 tests (`check-20261021T135938-61410.log`).
    - The chat's budgets hold. ChatStreamCost: 150 rebuilds configured, 154 measured. ChatDeltaBudget: 24 of 2,102 rows redrawn (ratio 1.03).
    - Each slice's regression tests failed on the old code.
  - Doc impact (f7e2ca7):
    - DEVELOPMENT §5's composer row.
    - Four DESIGN notes, where the code follows DESIGN over the reference: Send round and 30 (the Side composer's too), the mode popover's small "Mode" header, the model popover's notes in secondary, and a pinned card 16 inside.
    - The design docs are mirrored on `swarm/1`, with the UI-MAP lines from batch B that the mirror had missed.
  - Known gaps, placed by the planner:
    - I6b: the diff's line numbers and hunk line, and the changed-files card's status letters.
    - I4, with a custom popover host: the popovers' anchoring (the model popover aligned with its chip's trailing edge on the draft page, the / and @ menus' gap and entrance: they open above the card, as DESIGN §11 says and the code already does; "above their control" had no source).
    - Ink's list: block Markdown in a question.
    - I7: "Loom" stays in the banner's and the discard sheet's copy until then.
  - Its window tests, chat pairs and hover and focus pass wait in the idle queue (D-85).
- **Ink's I2c, the inspector's Overview** (ddb4f96, a fast-forward; DESIGN §6's Overview row, be22723):
  - Five sections in the reference's order: Session, Context, Worktree, Changes · last turn and Agents · N running. There is no Why line and no Last activity row (the planner's I2c decisions).
  - The CLI's version reaches the Overview through `ConversationIntents.toolchainVersion(provider:)`: two seams in `CatalogModel.swift` and `ConversationController.swift`, ahead of R5a by the planner's order. The Chat face's version comes from LoomChat's `ChatComposerState.claudeCodeVersion` (a one-slice grant).
  - The base branch is read from the repository's files (`GitBaseBranch`), with no Git process.
  - The last turn's files are the Changes tab's own read (`EditScan`, backward from the transcript's end to the newest prompt), made while the Overview is open: on opening and when a turn ends.
  - Checks: six suites, 71 tests (`check-20261021T142522-73878.log`), and ChatDriverTests alone, 29 (`check-20261021T143546-82233.log`), off screen.
  - Open: no test covers the Chat face's values (the composer's mode, effort and version win there); ink adds one with batch D. Its window test runs in the WindowEventTests run, and its pairs and a VoiceOver pass over the facts wait in the idle queue.
- **Core's R5a, the session service takes the lifecycle** (3be5c0d, a fast-forward):
  - `SessionService` (LoomCore, `@MainActor`) is the one owner of a session's lifecycle: a start in the face `FacePolicy` names, resume, stop, the answers, the open requests' approve, deny and dismiss, and the deletion calls. Each operation claims its busy state, start key or approval in the call itself and runs on a task it returns, so a second call at once sees the claim.
  - `SessionTransitions` (busy, the start keys, the preparing starts) is the one state, and the model reads it through computed properties, so no view changed. `StructuredFaceHost` carries a face's verbs, and `ChatSessionHost` conforms in LoomChat. `ConversationController` implements `TerminalFaceSinks` and keeps the surfaces, the ended screens, the captures and the handover.
  - The UI words a failure from a typed `SessionFailure`, with the same banner texts. Every ordering is kept: the card is told at Ready before a Chat first message, the stop capture comes before any signal, a failed structured start forgets its driver, a stopping cancellation is not reported, and Stop decides about the tab while busy is held.
  - Checks: the service's own tests (15 cases with fakes), R0's face and capability tables unchanged, and the suites that build the controller. Three runs, 39, 7 and 156 tests, all passed off screen (`check-20261021T144040-86263.log`). The implementer's mutations (the start-key guard, the forget on failure, the stopping silence, the busy release) each fail a test.
  - Open: the app was not launched, so the `AppDelegate` wiring is compile-checked only. A short app smoke runs in the evening's window, and LoomChatTests run whole in the full gate.
  - Next: R5b (the handover, rename and pin through the service; §3.2's test-only members removed) under the shared-file lock. R5c, the evidence duplicates, is ordered against ink's evidence edits later.
- **Ink's 9b, I2c's follow-up and I4-0** (990c1c1, a fast-forward of three commits; DESIGN 36b4302):
  - **9b** closes the five sidebar gaps from lunch's pairs: the activity headings start on the status column's edge, the project head's attention dot sits at its trailing end, the New session row has its `+` and the ⌘N key cap, the rows keep the reference's rhythm with no gap between entries, and the titles start 37 pt in. The subagent trunk reads its start from the card's top instead of a 3 pt lift. Its new tests failed with the old values put back (5 tests, 16 issues).
  - **The follow-up** makes one tested rule of where the Overview's version, mode and effort come from: the composer's words on the Chat face, then the hooks', then the stored launch choices and the probe.
  - **I4-0:** Home and the project page draw no header row, so their content starts at the window's top. While the sidebar is collapsed, the window buttons, Show Sidebar and the Preparing notice float over their top line, and a page keeps clear of them (`\.detailLeadingClearance`; DESIGN §3's centre line). The draft draws its header line as §8 says. `CanvasGrid`, the faint grid, is ready but not yet placed.
  - Checks: the combined run on 990c1c1, 222 tests (`check-20261021T145715-93226.log`), off screen. No shared file changed.
  - Until (a) and (c) land, Home's and the project page's current content sits 52 pt higher, and with the sidebar collapsed the floating buttons overlap the project page's head. (c) keeps its head and the Preparing notice clear of them.
- **Core's R5b, the handover, rename and pin join the session service** (2b21a56, a fast-forward):
  - The Chat → terminal handover's state is `SessionTransitions.handovers`, and `model.handovers` reads it. `Handover`, its phases and `HandoverRefusal` move to LoomCore with their names and words. The Chat face takes part through new `StructuredFaceHost` verbs, and `ChatSessionHost` keeps the driver a move began with, so a /clear that re-keys the driver does not lose it. The service's resume refuses a session that is being moved, and its stop ends a move.
  - The controller keeps the UI's side: the terminal face chosen, the start shown, the cleared note, the banner "The session could not be moved" and the `handoverGate` seam.
  - Rename and pin go through `SessionRecordWrites`, which the service holds.
  - §3.2's test-only members are gone (`SessionLifecycleController.resume`, the pending-prompt members, `SessionRuntime.reactivate`), with the one test that tested only them.
  - Checks: 18 suites, LoomCore 80, LoomChat 47 and LoomCatalogUI 149 tests, off screen (`check-20261021T152035-8573.log`). The implementer's mutations (the resume refusal off, Cancel offered at the point of no return, a skipped `finishHandover`) failed 7 and 14 tests.
  - Open: no app run of a handover yet. Core's evening smoke gains a handover step, on its own package from 2b21a56.
  - Next: R5c (the evidence duplicates and R5b's leftovers) after ink's (a), under a lock; R6, the split of `ChatSessionHost`, once its file list clears batch D.
- **Ink's batch D, Home and the draft page** (7513b2c, a fast-forward of two commits; DESIGN 47a9eb4). Their commits say "I4a" and "I4b"; they are batch D's Home and draft page, not §13's I4b and I4c.
  - The draft page: the question in display type, its picker underlined in the project's tone; the folder line with the branch and no state; the composer 680 wide; the keys line; the branch strip as a segmented control with the name's popover; the presets as chips; the reference's rhythm with the 70 pt lift. Send's tooltip says "Start a Claude Code session", and `sendDraft` and every start path are unchanged.
  - Home:
    - The band (the date line, the sentence with only "needs you" in attention, the counts) is one unit Remora can replace.
    - Continue comes first in both layouts. Needs you always shows; Finished shows only with entries.
    - List cards have 42 pt heads, and rows are one line with the harness's mark.
    - The side column goes under the lists below 820.
    - The no-Claude notice is a card, and the first run is Home's own view with the app icon.
  - "Needs you" in the sentence counts both lists, as the Dock and the menu bar do (the planner's call, DESIGN §9). The empty Needs you card's line names only what it lists: "A session that waits for your answer is listed here." (6e21881).
  - Shared hunks, as granted: `CatalogModel+Home.swift` (the entries' provider, and the working count read after `liveRevision`).
  - Checks: the combined run on 7513b2c, 160 tests and 9 XCTest (`check-20261021T160912-32408.log`), and the draft page alone, 93 (`check-20261021T155430-24801.log`), off screen. Four suites' assertions moved with the new look (HomeRender, ContextPace, Highlight, UIFixRound).
  - Unverified until the evening: Home's pairs (Ink and Paper, three casts, wide and narrow, hover, the first run, no Claude), the draft page with a real Git folder, its strip and popover live and at 780×500, and the window buttons over Home. The evening package is rebuilt for them.
- **Core's R6, the Chat host splits and the service owns it** (77751bc, a fast-forward):
  - The live feeds and composers the app keeps per driver move out of `ChatSessionHost` into LoomCatalogUI's `ChatAttachments`: the limit of four, the least-recently-used trim and the in-use rule. The host's `forget` tells them first, so a composer hears that its host forgot it before the queue, draft and rewind files go.
  - The app makes the host with the model's closures and hands it to `SessionService`, its one strong owner; `model.chatSessions` reads it through the service.
  - The side chat's retirement (D-72) moves into the service, keyed by session. The Side tab reports what it shows and leaves, and the service closes a side chat through new face verbs.
  - The rule itself is unchanged: an idle side chat that is not open closes at once, a busy one when it settles, and one reopened before it settles stays. The parent's stop retires the open one too, and a move is not a stop.
  - Review found one difference, after a /clear in the parent. It is fixed, with a test that fails on the old check.
  - Checks, off screen:
    - 23 suites before the rebase: 42, 98 and 170 tests (`check-20261021T161424-35355.log`).
    - After the rebase: the build, SessionServiceTests (36) and SideChatFlowTests (15) (`check-20261021T162645-39949.log`).
    - The implementer's mutations each failed exactly their own tests.
  - Open: no app run of a side chat or of the host's wiring yet. Core's evening smoke moves to a package from 77751bc with a side-chat step, and LoomChatTests run whole in the full gate.
  - Every R step but R5c is done. R5c holds its files under the lock.
- **Ink's batch D, the project page** (35c2a80, a fast-forward; DESIGN 8f4066c). Batch D is complete with it.
  - The page:
    - the head on the first 52 pt line: the mark, the name and the selectable folder, with ⋯ and New session at the trailing end;
    - the stats line, and the view tabs with counts (`ViewTabs`);
    - flat session rows, with the harness's mark and a structured last line;
    - the Presets and Past 7 days cards, with Presets above the list under 760;
    - the Branches and Instructions tabs, and the empty project's line.
  - P8: `ProjectActionsMenu` follows DESIGN's order, set by a tested `ProjectMenuPlan`. The sidebar's head, its context menu and the page's ⋯ all draw it. `NewConversationAction.perform` is unchanged, and `ChipButtonStyle` is gone.
  - The planner's calls (DESIGN §10): "0 sessions" shows in an empty project, as the reference draws it; the head starts past the window buttons with the sidebar collapsed; the Preparing notice does not show on this page, in a one-line change that follows.
  - Checks: the slice's suites, 117 tests, off screen. Ink also ran LoomCatalogUITests whole without the window tests by day, 1,376 tests (`check-20261021T164902-47271.log`). That was a slip against D-85, and so was batch C's sweep at 13:50. Both passed. From now on, whole-target sweeps run only in the idle windows.
  - Known gaps, with their slices:
    - "I4 hosts", a custom popover and menu host, first in batch E: the model popover's anchoring (DESIGN §8), the / and @ menus' place, and the project menu's swatch row (§10).
    - I5: the empty project's hammerhead.
  - Unverified until the evening:
    - the project page's pairs: 1280×800 and 940×700, the empty project, the three tabs, Ink and Paper in the casts, and Increase Contrast;
    - hover and focus, and the ⋯ menu in both places;
    - the window buttons over the page.
- **Ink's notice fix** (2e2b66b, a fast-forward): the Preparing notice is not drawn on the project page, whose head holds the line. A pure test pins the rule, and the hosted test checks that the head no longer moves.
- **Core's R5c, the evidence shortcuts through the service** (4b4ffbb, cherry-picked from core 8145360 onto 2e2b66b; no shared file). With it, the refactor's steps R0 to R7 are done.
  - The evidence's lifecycle goes through `SessionService`: `chat-start` is the draft page's send through `NewSessionIntents`, and `chat-stop` and `chat-resume` are the model's Stop and Resume. `startChatSession`, `resumeChat` and `resumeHomeForEvidence` are gone.
  - R5b's leftovers go: `stop`'s `willStop`, the controller's `refusal` seam, and `SessionLifecycleController`'s unwritten pending prompts and generations with the inert interruption branch.
  - The side chat gets three evidence commands through the real Side paths: `side-ask`, `side-new` and `side-state`. `side-state` holds ids, booleans and phase words only, which `SideTabEvidenceTests` pins.
  - The evidence contract changes, written in DEVELOPMENT §5:
    - A verified `chat-stop` closes the session's tab when nothing else was navigated, as a user's Stop does.
    - `chat-stop` and `chat-resume` write no error file.
    - A start's face follows "Sessions run in".
    - A second `chat-start` on a key that is starting is refused.
    - `newestChatSession` is set at the start's outcome.
    The perf scripts read correctly against these. Ink's shots tool waits for a new session id before its next package, so tonight's pairs run on a 2e2b66b package.
  - The planner's call: the Chat face's evidence readers and drivers (`interruptChat`, `readNowChat`, the summaries, `composerEvidence`, `activityOwningFaces`) stay in LoomCatalogUI. They duplicate no lifecycle path, and moving them would need public Chat models or a package change.
  - Checks: 11 suites, 89 and 91 tests, off screen (`check-20261021T170246-52321.log`).
  - Unverified: the perf scripts and the side commands have not run in the app (tonight's smoke runs the side commands), and the failed-start path and the 60 s waits have no test.
  - Next on core: L3a, Remora's core wiring with no UI, once its Brief and file list are approved; C7's optimization after tonight's baseline.
- **Core's smoke package from 4b4ffbb** (`~/Library/Application Support/Loom-Dev/packages/smoke-4b4ffbb/`, `Loom Dev` sha256 fdf66606…, every hash in `evidence/core/r5/smoke-4b4ffbb-sha256.txt`). Tonight's smoke runs on it with the side-chat step. The 77751bc package and R5c's build folder are deleted. `chat_long_session.py` sends no command of its own, and its caller is unaffected by R5c.
- **Batch E's map and L3a's Brief approved, with the shared files' order** (17:26).
  - Batch E (ink), from its map (`evidence/ink/e-map.md`). "I4 hosts" starts first. I4b, Settings and About, starts after the five-hour window's reset at 19:00. The planner's answers:
    - The / and @ menus stay above the card (DESIGN §11). Only the gap (6) and the entrance (160 ms with the 3 pt rise, instant under Reduce Motion) change.
    - The host is a window-level layer that flips, then clamps 8 pt inside the window. Its placement is a pure, tested rule, 780×500 included. It takes Esc only while one of its popovers or menus is open, and never binds a default or cancel key. `PinnedFixRoundTests`' guard, which keeps such keys from answering a pinned card, scans its files too.
    - The ⋯ buttons open the custom project menu with the swatch row, as the reference draws it, with the label and icons where DESIGN is silent. The right-click menu stays native, with Color as a submenu, and DESIGN §10 will say so.
    - I4b builds §6's sheet family now, as one shared component, for the Full Access and Delete sheets. It is modal, with a pure keys rule, and the evidence can open it for the pairs. I6b moves the main window's sheets onto it.
    - I4b's two menu pickers stay native behind one seam until the host is in. Animated art's switch moves to I5 (§13).
    - The evidence: additive commands in `EvidenceStudioCommands.swift` (the draft's popovers), `EvidenceProjectPageCommands.swift` (the project menu) and `EvidenceSettingsCommands.swift`.
  - L3a (core), Remora's core wiring and the model API with no UI (`evidence/core/l3a-brief.md`):
    - What it builds: the package edge LoomCatalogUI → LoomRemora, and a `@MainActor` `RemoraHost` in LoomRemora that the app makes and the model holds, as with `ChatSessionHost`. With it come the model's observable Remora state and `RemoraPreferences` in `UIPreferences`. Nothing calls Remora until L3b.
    - The planner's notes:
      - The forgetter runs off the main actor, and it is registered before `start()` recovers pending deletions; a tested wiring function holds that order.
      - A morning brief that waits does not use the day. One that never reached the model (`notLoggedIn`, `couldNotStart`) gives the day back, and every other failure keeps it (`RemoraSchedule`'s cost rule). Offline is L3b's one check at the call site, with no watcher.
      - At launch, only the stale system-prompt files are looked for; the memory is read on first use.
      - The code defaults are LOMBOT §6.2's, in one place. Whether the public build has Remora on with the automatic brief, as the user's install does, is LOMBOT §11's open point and goes to the user before L3b.
  - The shared files: L3a holds `Package.swift` and the release manifest, `CatalogModel.swift` (one property), a new `CatalogModel+Remora.swift`, `UIPreferences.swift`, `AppDelegate.swift`, `AppDelegate+Usage.swift`, `docs/ARCHITECTURE.md`, and new test files in `Tests/LoomCatalogUITests/`; `UIPreferences.swift` and the tests are lent from ink's area. Batch E holds the three evidence files. No file is in both, and a slice that needs another stops and asks.
  - Load: the five-hour window was at 71 % at 17:23, so each track runs one implementer until the reset at 19:00.
- **The pause and the user's test rule** (17:30 to 19:32). The user closed the Mac for the way home, and it slept rather than shut down. Both tracks had stopped with nothing written: L3a's implementer before its first file (core's resume note is in its evidence folder), and I4 hosts' while it read the code (its worktree clean at 4b4ffbb). Back home, the user set D-87: development first, and the tests in one end batch before 1.6.0's acceptance, with each slice's own suites off screen as the gate for its integration. The tracks resumed at 19:32 on a fresh five-hour window: core with L3a, and ink with I4 hosts and I4b side by side.
- **C7's four profiled cells** (19:35 to 19:47, all four valid). They ran on C7's candidate package (f7e2ca7, I6's head), on AC power, with no thermal warning, and every build paused for them. Under D-87 they are the one test core's work could not go on without: C7 cuts what a visible Chat stream costs over the terminal, and it needs the hot path first.
  - Chat against the terminal, in total CPU of one core, one run each:
    - at 600 characters a second, 24.72 % against 6.03 % (4.10×);
    - at 6000, 54.44 % against 20.30 % (2.68×).
  - At 6000, Chat's footprint peaks at about 2.7 times the terminal's: 325.6 MiB against 119.5 in the run's summary table.
  - The hot path, from a 10 s sample at 6000:
    - Every patch rebuilds the presentation and re-measures the growing row through `NSHostingController.sizeThatFits`, a full SwiftUI layout with CoreText shaping. That is about 670 to 750 of some 1,230 busy samples.
    - The display cycle then lays the row out again, about 940 more.
    - Markdown parsing takes under 100.
  - C7's first candidates:
    - measure once per frame rather than per patch;
    - measure only the changed row, and keep the others' heights;
    - measure a growing text row with TextKit or CoreText at a fixed width.
    The footprint gets its own look.
  - The cells are in the baseline's run folder, so the end batch's `c7base` measures only the other 12.
  - C7's files are the chat's controller and presentation, in ink's I6 area. Core names them for a lock once L3a is in review.
- **Core's L3a, Remora's host and model API with no UI** (c6ba7ec, a fast-forward; the contract's and DEVELOPMENT's lines in 3170b08). Nothing calls Remora yet, so no model call is made.
  - What it builds:
    - `RemoraHost` (LoomRemora, `@MainActor`) is Remora's one owner in the app. It holds the memory, opened on first use through a thread-safe box; `Remora.md`; the pack builder; the call; the day's brief record; and the one call in flight. Its outcomes are values.
    - The maps from session to project come from one catalog read with no row limit, so LoomCore is unchanged.
    - `RemoraPreferences` in `UIPreferences` holds the defaults in one place, decoded field by field.
    - `CatalogModel+Remora` holds the observable state and the API. Without a host, every method refuses quietly.
    - The app installs the host before `start()`, and `loom-app` does not import LoomRemora. The edge LoomCatalogUI → LoomRemora is in both manifests.
  - The planner's four notes hold, each with a test:
    - the forgetter needs no main actor and reaches a deletion recovered at start; a control that registers after start misses it;
    - a brief that waits records nothing, and one that never reached the model gives the day back;
    - launch reads only the folder listing;
    - the defaults live in one place.
  - The planner's calls:
    - a brief the user asks for takes the day too;
    - undo tokens die when `Remora.md` moves;
    - turning Remora off, or excluding a project, stops the call in flight, which (a) below builds.
  - Review found one edge, which (a) fixes: a call applies with the exclusions it started with, so a project excluded during a brief could be written to the memory again.
  - Checks: LoomRemoraTests whole, 129 tests, and five suites, 38 and 40 tests, off screen (`check-20261021T195502-69029.log`).
  - Unverified: no app run yet. The end batch's service smoke runs on a package from the head of that time, with Remora installed.
  - Next on core, two implementers with disjoint files:
    - (a) the Remora guard. A source test fails when a second unasked path to Remora's call appears, when a timer or a watcher comes into LoomRemora, or when a host is made outside the model's install. It comes with the fix for the edge above.
    - (b) C7, from the profile. It holds the chat's stream files from ink's I6 area. It is performance only, and every height that stops coming from the hosting controller is pinned against it.
- **C7's map corrects the profile's reading** (20:14). The stream does not measure on every patch: text growth is gathered and rebuilt once every 80 ms, and only the growing row is measured. The cost is that each measure lays out the whole message, which grows with it, so a stream costs about the square of its length. The display cycle also re-evaluates every block of the row on each flush. The footprint is a sawtooth that follows the open message, 185 to 309 MiB at 6000 against the terminal's flat 113, and not a leak.
  - C7's plan, in order:
    - settled blocks become an Equatable head that a flush does not re-evaluate;
    - the open block alone is measured, and the settled blocks' heights are cached;
    - the split into settled and open blocks becomes incremental.
    CoreText heights stay out.
  - Pins: each settled block is evaluated once per stream, and again only after a change of look or width. The measuring work per flush does not grow with the message. The composed height stays within 0.5 pt of the whole-row measure, over a corpus at three widths.
  - C7's lock gains the chat's heights, row views, Markdown views and content split. Ink's batch E touches none of them.
  - The end batch adds `footprint` readings at the 6000 peak and at a message's end. They decide whether the footprint gets a slice of its own.
- **Ink's I4 hosts, the popover and menu host** (4ddc154, a fast-forward; DEVELOPMENT §5's row and DESIGN §10's line in aa12894).
  - `InkHost` is one window-level layer. It draws one popover or menu at a time on the popover surface, with no arrow, entering in 160 ms with a 3 pt rise (instantly under Reduce Motion). While nothing is open, it answers no hit and takes no key.
  - It closes in three ways:
    - an outside click, which goes no further, so a second click on the chip toggles;
    - Esc;
    - the window losing key.
    It then gives the keyboard back to the composer or to the draft's editor.
  - Placement: the pure `InkPlacement` puts the popover 6 from its control. It flips when that side doesn't fit, and clamps 8 inside the window. `InkOpeners` holds the planner's table: above in the live chat and below on the draft page; the model aligned trailing, the mode and the + leading.
  - Moved into it: the model, mode, + and ring popovers, the draft's branch-name popover, and the project menu.
    - Both ⋯ open the reference's menu with the swatch row, and the right-click menu stays native.
    - The / and @ menus sit 6 above the card and rise in.
  - Esc: only the host takes it, and only while something is open, with no default or cancel binding. `PinnedFixRoundTests` scans the host's five files, and a test pins that Esc passes through while nothing is open.
  - The planner's calls:
    - the ⋯ is a plain button with the hint "Opens a menu", until the VoiceOver pass judges it;
    - the + popover and Compact Now gain keys;
    - a ring opened by hover leaves the keyboard in the composer;
    - a swatch pick leaves the menu open.
  - Debt: `InkOpenState`, a shared singleton for the draft's and the project menu's open flags, moves into the model when a slice next holds `CatalogModel.swift`.
  - A follow-up after I4b: the mode list's and the / and @ menus' pill sits 8 inside their edge, where DESIGN says 6. It goes to 6.
  - Checks, off screen:
    - on 4b4ffbb, 34 host tests and the suites the move touched, 147, 72, 15 and 38 tests;
    - after the rebase, the build and 42 tests (`check-20261021T201619-84924.log`).
  - Unverified until the end batch, about 25 min of screen:
    - the look in Ink and Paper, the casts and Increase Contrast;
    - real clicks, keys and focus, and a resize with a popover open;
    - VoiceOver;
    - the two window tests the slice moved.
- **Core's Remora reach guard, with the stop on Off or a new exclusion** (a0e1d24, cherry-picked from core 261dfcd onto aa12894, since `v2` had moved; no shared file; ARCHITECTURE's, the contract's and DEVELOPMENT's lines in 8cdbb66).
  - `update(settings:)`: when Remora turns off or the excluded set grows, it first cancels the call in flight. It then sets the new settings, waits for the call to end, and only after that switches the note and deletes the newly excluded notes. A cancelled call applies nothing.
  - `briefIfDue` answers When I ask and an already-briefed day before it reads the catalog.
  - `RemoraReachTests` scans every source file, with comments and strings blanked, against exact lists:
    - one place makes the host, and one makes the call;
    - `briefIfDue` has one caller;
    - the model's Remora entries have none until L3b, whose commit adds its Home sites to the lists;
    - LoomRemora and the model API hold no timer, watcher, observer, delayed dispatch or sleep.
  - Failing first: before the fix, the exclusion, Off and cheap-rules tests failed, and the control passed. A planted second `briefIfDue` call failed the guard and was removed.
  - Checks, off screen: 34 and 11 tests on 3170b08. Then, on core's rebase onto aa12894, whose Sources and Tests match `v2` 8cdbb66, `RemoraReachTests` and `RemoraHostTests` passed, 31 tests (`check-20261021T202046-88237.log`). The scanner saw I4 hosts' new files, and every list held.
  - Unverified: a cancel that lands while `apply` already runs lets that call finish, and the note is deleted after it. The scanner does not read code disabled by `#if` or aliases.
  - The contract now names the pack's budgets (14,000 tokens for a question and 30,000 for a brief) and the deadlines (60 s and 120 s), and lists the three Remora guards.
- **Batch F's map and the planner's answers** (20:44; `evidence/ink/f-map.md` in the evidence folder).
  - I4c, the edges, starts beside I4b. Most of the edges are already at target. Its work is the ended line, the record, the top banner stack, and the menu bar's list.
    - The menu bar's list takes the Dock's rule (DESIGN §19).
    - The banners are a pure mapper over the four existing slots.
    - The menu keeps the system's section headers, and alerts stay sheets on the window.
    - "Loom" waits for I7, and so does moving the failure "did not quit…" to `reportFailure`.
  - L3b, Remora's UI, starts after I4b. DESIGN §20 needs six things the model API lacks, and core's small slice L3a2 builds them first:
    - the last schedule decision with the wait's reason;
    - the stopped outcome;
    - the reading counts ("Reading 6 sessions and 3 project notes…");
    - the day's brief kept across a relaunch;
    - the brief language (the last question's unless set);
    - the fake provider's script seam through `CLAUDE_CONFIG_DIR`, with no change to the product's environment list.
  - ⌘K's Ask and the draft page's brief row become L3c, right after L3b.
  - Ink's evidence hooks for I4c and L3b come first, as one stub commit, so the two slices do not conflict in the command chain. It landed as 1162c7d, a fast-forward: two empty handlers in the chain and the snapshot. The build, the guards and `RemoraReachTests`, 9 tests, passed (`check-20261021T204447-3075.log`).
- **Core's C7, the Chat stream's cost** (b6e83a4, a fast-forward; DEVELOPMENT's and ARCHITECTURE's lines in f8c7fe0). It changes no look.
  - A streaming message's settled blocks are one Equatable view, so a flush that only grows the open block builds none of them.
  - The row's height is composed from the insets, the settled blocks' cached heights and the open block measured alone. Settled rows, other row kinds and an open code fence keep the whole-row measure.
  - The split into settled and open blocks is incremental: it scans only the new bytes.
  - Measured characters per rebuild, median and max:
    - at 3,000 characters, 1,560 and 3,000 before, against 119 and 238 after;
    - at 12,000, 6,040 and 12,000 before, against 116 and 241 after.
    The work no longer grows with the message. A flush with 16 settled blocks builds 2 block views instead of 34.
  - The composed height matches the whole-row measure over 684 cases with a gap of 0.000 pt. A 1 pt change of the insets fails that test.
  - The planner's call: test E pins the look after an appearance, tone or width change by pixels (within 0.2 %, against a fresh view) rather than by a body count, since a width change is layout.
  - Checks: nine chat suites, 98 tests, with Remora's guard and host suites, 31 tests (`check-20261021T204654-4209.log`), and the guard again on 1162c7d.
  - Unverified until the end batch: the visible CPU against tonight's four cells, the footprint, and whether the equatable head also saves layout.
- **Ink's I4b, Settings and About with §6's sheet family** (a50bf88, a fast-forward; DEVELOPMENT §5's row in d4a5901).
  - The window: the 52 pt band with underlined section tabs over a hairline, the close button at y = 26 from an empty toolbar, each section scrolling under the band at a 32 inset, labelled groups, raised cards and rows 48 high.
  - New shared controls: the segmented control, the switch, the stepper, the checkbox, and `SettingsPopup`, the one seam over the system's menu until the host serves Settings.
  - The sections: Theme's tiles paint their own casts; Usage has four cards; Sessions has a constant "Delete Sessions"; About has its head and its facts. Animated art waits for I5.
  - The sheet family is generic, a `SheetPresenter` with a sheet layer.
    - It is modal, and hides what lies behind it from accessibility.
    - Its keys come from the pure `SheetKeys`: Esc cancels, Return presses only a filled button, and Tab stays inside.
    - It holds focus itself when Cancel cannot, so Esc works with keyboard navigation off.
    - Full Access and Delete use it now. I6b moves the main window's sheets onto it, with the ⌘W and ⌘N hold.
  - The legacy settings, usage and about tokens are deleted. The two that the Changes tab's styles use stay.
  - Checks: 13 suites on 4b4ffbb, and after the rebase the build, the guards and 54 tests (`check-20261021T211034-19397.log`).
  - Unverified until the end batch, about 30 min of screen:
    - the pairs of the four sections and three new surfaces;
    - the sheets' focus, Esc, Tab and scrim by hand;
    - VoiceOver;
    - the close button's line;
    - the native popups, hover, Glass, the notice states, the About icon and the locale's text.
- **Ink's inset fix** (2702e6a, a fast-forward): the mode list's and the / and @ menus' pill sits 6 inside their edge, as DESIGN says and as the project menu already had it. `Highlight.inset` stays 8 for lists, cards and the palette. `HighlightTests` pins the 6 and fails on the old 8. Checks: the build, the guards and 63 tests, off screen (`check-20261021T211343-21017.log`).
- **Core's L3a2, Remora's model API for Home** (eef4938, cherry-picked from core 42053f2 onto 2702e6a; no shared file; ARCHITECTURE's, DEVELOPMENT's and the contract's lines in a7854b5). It covers what DESIGN §20 needs and the model lacked:
  - the last schedule decision, with the wait's reason;
  - the stopped outcome;
  - the reading counts, given once the pack is built;
  - the day's brief, kept in a file in Remora's folder (0600, atomic), read on first use and gone after the day's start;
  - the brief's language: the setting, or the last question's when it is unset, through `NLLanguageRecognizer`. It is one line at the end of the brief's request, and the stable prefix is unchanged;
  - the fake provider's script file, which answers with the pack's real session ids.
  - Review found a deletion race: a session deleted while a call runs could come back in the kept brief, the journal and the notes. The forgetter now records the id first, and keeping and applying drop it. Each rule failed first.
  - Checks: LoomRemoraTests 176 and RemoraModelTests 18 on the combined tree (`check-20261021T211035-19687.log`), and the guard and the model's suite after the rebase (`check-20261021T211424-21535.log`).
  - Unverified: the answer already on screen can name a session deleted mid-call until the next call, so L3b hides chips whose session is gone. The language rule was tried on two sentences. No real Claude.
  - L3b starts from a7854b5. Its Brief binds core's three needs: reload the kept brief each time Home shows, hide the chips of gone sessions, and add its sites to the guard's lists.
- **Ink's I4c, the edges** (982cc07, a fast-forward; DEVELOPMENT §5's row, DESIGN §19's and §7's lines and ARCHITECTURE's in b2793cb).
  - The ended line is 40 high on the canvas with a hairline under it; after a banner stack it gets 8 and a hairline above it. Show Details comes before Resume, and neither takes Return. "Resuming…" shows the spinner and disables both. The chat's read-only view has no Show Details.
  - The record has no title block. The notice comes first: the state's wash at 10 %, its edge at 30 % and the symbol in the state's text colour. Then "Not running", what Resume does and the buttons, then the facts card, raised 1, with a 150 label column and mono for the folder and the ID. Its column is at most 620, and its requests sit above its scroll, as DESIGN's callouts do.
  - One top banner stack. The pure `BannerItems` reads the model's four slots, the deletion records and, on the terminal and chat routes, the selected session's live issue, and orders them failure, attention, note.
    - One box shows and the rest wait behind "+N". × shows on errors and notes only, and progress shows the spinner.
    - The live issue left the content for the stack.
    - `BannerBox` is the chat's box, extracted, so the chat and the stack draw one box. Both take the tone's text colour for the symbol, and the contrast test gains the failure pair on raised 2.
  - The draft page's two notes are banners above the composer: attention for a draft that could not be saved, a note for a message too long.
  - The menu bar has a 7 pt row dot and Claude's mark on New Claude Session. It takes the Dock's rule, so a read failure leaves the menu as it leaves the badge; the new test fails with the rule taken out.
  - Evidence: `edge-banner`, `edge-banner-clear` and `edge-banner-peek`, through a public seam that raises each banner through the app's own slot.
  - Shared files, as granted: three lines in `menuBarEntries` (`CatalogModel+Navigation.swift`), its evidence file and the new seam. AppDelegate, `CatalogModel.swift`, C7's files, HighlightTests and `PinnedFixRoundTests` are untouched. The lock on `CatalogModel+Navigation.swift` is released.
  - The planner's calls on ink's three questions, and one more:
    - the open peek says "Show Fewer", as the reference does, in the stack and in the chat's box;
    - deletion rows have no ×, since a pending or failed deletion stays visible and retryable;
    - the reference's second card, whose edge peeks above a stack that holds more, is drawn in the stack and in the chat's box. It goes inside the gap above the box, so a second banner does not push the screen down again;
    - DESIGN's "newest first within a tone" becomes a fixed order by kind, since each slot holds only its newest message, and the chat's box already orders so.
    The word and the second card come in a small fix slice before the end batch.
  - Debt:
    - `menuBarEntries` repeats the Dock's rule rather than reading `attentionCandidates()`;
    - the old record and banner tokens wait for a slice that holds `LoomTheme.swift` and HighlightTests;
    - `deletion-retry` and `deletion-remove` repeat when two failed deletions are open.
  - Checks, off screen: the implementer's suites on 1162c7d, 17, 6, 57 and 146 tests, with the regression run against the old rule. After the rebase, ink's run on a7854b5 passed the build, the guards and 73 tests (`check-20261021T212056-24001.log`).
  - Unverified until the end batch, about 40 min of screen:
    - the two window tests it touched;
    - the pairs `ended-terminal` and `banners-stack` against the reference (12 images), and `banners-open`;
    - by hand, the stack, the ended line in both faces, the record per state, the draft's banners and the menu;
    - the evidence commands on a live app.
- **The end batch's runbook, settled** (21 Oct, night; core's runbook in its evidence folder, with a section of the planner's answers). About 7 h 5 min, so a night, or about 8 h 20 min with the optional step 11 (C8's tier 3 and the rest of C7's baseline). Step 7, ink's offscreen sweep, drops because the full gate runs the same night.
  - One package from the head of that time, core's, serves both tracks. Ink confirmed that its shot tools take the package and its fixtures folder. Its window tests build in its own clean worktree, moved to that head.
  - Step 0 adds a dry run of about 2 min of ink's two new shot options (`--hold` and `--app-arg`), which have only been compiled, so a tool bug shows before the 115 minutes of pairs.
  - The real-Claude set is 8 Haiku turns: a Chat start from the draft, Stop and a resume, the handover, an approval, Ask's refusal, and the side chat. Add Remora's probe, a cold brief and then a question. The 2 turns left under the cap of 10 are kept for one rerun.
  - The planner's calls:
    - the title is read off the catalog of the Chat start's run, with no extra turn. It must be Claude's own title, neither "Claude session" nor the first message, and the transcript must hold the same `ai-title`;
    - the probe runs on Sonnet, the model Remora ships with. A tiny core slice adds `LOOM_REAL_REMORA_MODEL`, defaulting to the product's model and effort. Each call must end inside the product's deadlines, 60 s and 120 s, by the probe's own timings;
    - C8's cells and the real runs pin Remora off from launch, so no brief adds work to a cell or goes out unplanned. After each real run, Remora's files must show no call. The switch is a seeded preference in the run's data root, Remora off with its brief on When I ask, merged into the file before launch: the app reads it before the model exists, and the brief's first check is Off. There is no launch argument, and L3b's command acts only after launch. Core wires one helper into every launcher.
- **Core's probe on Remora's shipped model** (113fce0, a fast-forward; DEVELOPMENT's lines in 4c5ebf4). Only the probe's file changes.
  - Both calls take the model and effort Remora ships with (Sonnet, low). `LOOM_REAL_REMORA_MODEL` names another model, with the product's effort. Each call's numbers also record the requested model and the effort.
  - A new test with no real call pins the default, a blank value and the cheap rerun.
  - DEVELOPMENT's fake-provider paragraph had said the probe used Haiku for one call and needed a variable it never read. It now points to the probe's item.
  - Checks: the build and LoomRemoraTests whole, 177 tests, with the probe skipped and the guard passing (`check-20261021T213643-29518.log`). No real call was made.
  - The runbook now carries the planner's five points. Its placeholder for pinning Remora off held step 0 before step 3 until the switch was named; it now is, so core wires it in.
- **Ink's banner fix, I4c's follow-up** (aea6886, cherry-picked from ink dab2e7c onto 4c5ebf4, since `v2` had moved with core's probe; UI-MAP's Banners entry in the commit; DESIGN §19 already had both rules). The commits between touch only the probe's test file and DEVELOPMENT, so ink's run stands for the combined tree.
  - The open peek says "Show Fewer", with the help tags "Show all" and "Show one". The box carries it, so the stack and the chat's box agree.
  - The second card's tab shows above the first box whenever the box carries a closed peek: 5 high, 10 in from each side, raised 1 with the strong hairline on its top and sides.
    - It draws outside the box's frame, inside the gap above it, so a second banner changes no height. The reference's 6 pt margin isn't copied, and the pair's offset is marked as accepted.
    - Its corners are 5: the reference's 7 on a 5 high tab, which CSS scales down to the tab's height.
  - The deletion buttons' ids carry the deletion's id, so two open failed deletions keep four distinct ids.
  - Checks: EdgesPure, EdgesView, PinnedInk and ThemeAppearance, 75 tests, off screen (`check-20261021T213817-30906.log`). Each new test fails without its change, and the stack's height pin holds.
  - Unverified until the end batch, in I4c's item: the tab in the stack and in the chat's box on screen, including whether it draws above the chat's AppKit stream; the words and the help; a second banner moving neither the terminal nor the composer; `banners-open` against its new reference.
- **Core's Remora-off seed for the batch's launchers** (69d0989, a fast-forward; DEVELOPMENT's and scripts/README's lines in 6ed3c04). Scripts only.
  - One helper, `perf_paths.seed_remora_off`, merges Remora off with its brief on When I ask into a run's preferences file, or creates it, through an atomic replace. It keeps every other key, including Remora's own others. It refuses `~/Documents`, the default dev and daily data roots, and a file that is not a JSON object, before writing anything.
  - Every launcher the batch uses calls it right before launch: the perf scripts, `scripts/cp5-d-measure.py`, and the real runs through `release_b_accept.py` and `claude_real.py`. The service smoke in core's evidence folder calls it too. So every C8 cell is covered with no change to the runner.
  - The side chat's real run needs none: its suite builds its own model and never installs a Remora host.
  - Core's finding: `cp5-d-measure.py` launches the app without fake providers, so after L3b a brief on Home could have run the real `claude` from a terminal cell. Its config folder is a fresh one in the run's data root, not `~/.claude`, so the brief is a real turn if the CLI still finds a login, and a failed brief otherwise. The seed closes that path in the batch.
  - A guard in the app follows after L3b, with core's Brief in its evidence folder. A development-flavour evidence launch with neither fake providers nor `--claude-config` holds Remora Off in memory, whatever its preferences file says. The file can't tell a seed from the app's own write of the default, since the app always writes `isOn`, so the planner chose no file exception. A run that wants Remora on uses fake providers or an isolated profile, and the real runs keep the seed. Locks: the model's Remora file, the evidence launch file and the model's Remora tests, granted once L3b releases them.
  - Checks, off screen: the guards, with every script's syntax, and the build (`check-20261021T214335-33070.log`); a dry run on temporary roots for the merge, a rerun that changes nothing, an empty root, a refused non-object file and the refused default roots. Nothing launched the app.
  - The runbook has no placeholder left. Step 0 checks that the helper is at the head, and step 3's pass reads the seeded file. Unverified: an app launch on a seeded root, first in step 3, whose after-run check confirms no call.
- **Ink's L3b Settings, Remora's tab and memory sheet** (ea0e5f8, cherry-picked from ink 5ae7c2f onto 6ed3c04, since `v2` had moved with core's seed; DEVELOPMENT §5's and DESIGN §20's lines in e3941fb). The commits between touch only scripts and docs, so ink's run stands for the combined tree.
  - The tab sits between Sessions and About.
    - The switch comes first, and Off dims the rest to 38 % and takes it out of reach.
    - Then Model and Effort, the brief's segment, its language, and one check per project.
    - Working memory has Show… and Clear…, and the note's path has Choose… and Open.
    - Then Proposals, today's use, the 5-hour stepper and DESIGN's last line.
    Every control goes through the model's Remora API, so Off and a new exclusion stop a call in flight as the guard pins.
  - The memory sheet is 560 wide, with three tabs: Journal, Project notes and `Remora.md`. Clear Working Memory… asks first. Done is unfilled and closes like Esc, and closing mid-edit writes the editor's text. The sheet reads and changes the memory only through the model's API.
  - Ink's review folded in two fixes:
    - a session deleted while the sheet is open leaves no line. The sheet reads again when a deletion ends, which is after Remora has forgotten the session, and the test fails with the old read;
    - a question that ends in its own mark gets no full stop after the quote.
  - Shared files, within the grant: the sheet family's width, and Done as its way out; the dimmed environment for Settings' rows, which also dims General's segment when it is disabled; the evidence file. No `CatalogModel` file and no guard list changed, since Settings adds no call.
  - The planner's calls:
    - the brief's language list stands: eleven languages after "Same as my last question", named in DESIGN §20;
    - a note shows and is edited in its file form, which keeps the cited sessions of the lines left unchanged; DESIGN §20 says so;
    - Open uses Obsidian only when the note sits in a vault, and otherwise the app that opens it. The default `Remora.md` lives in Remora's folder, outside any vault. A small ink fix follows;
    - the sheet's Undo reads the model's one `lastUndo`, so with two removals, or a "Remember this?", in flight it can restore the wrong note. Core's next model slice hands each removal its own token, and the sheet takes it;
    - the rows' inset went to the user. The reference draws the rows 32 in, because its `.scard` class is shared with the chat's session card, while settings.css says 16. The user chose the drawing (D-88). DESIGN's Settings rule states it (0ea48fb), and an ink fix brings every Settings section to it.
  - Core's next model slice comes after L3b Home. It adds the journal's folded weeks, the working memory's "updated" time, each note's "rewritten" time, and the per-removal token.
  - Checks: 110 and 9 tests, off screen (`check-20261021T221028-42659.log`). The deletion test fails with the old read (`check-20261021T221228-43701.log`).
  - Unverified until the end batch, about 20 min of screen (EQ item 13):
    - the `settings-remora` pair and the memory sheet's four app-only shots;
    - by hand: the popups, the segment, the chips, the stepper's ends, Off, Choose… and Open;
    - the sheet's keys, hover, Remove and Undo, and both Clear answers;
    - VoiceOver on the popups' row names;
    - a deletion with the sheet open.
- **Ink's Open fix for Remora's note** (28635fb, cherry-picked from ink 4c66fca onto 0ea48fb, past the planner's DESIGN commit for D-88; UI-MAP in the commit; DESIGN §20 already said it).
  - A pure function finds the vault a note sits in: the nearest folder above it that holds a `.obsidian` folder. Open goes to Obsidian only then, and only when Obsidian is installed; otherwise the app that opens the file opens it.
  - The memory sheet's button says "Open in Obsidian" only for a note in a vault, else "Open".
  - Checks: the Remora Settings and memory suites, 36 tests, off screen (`check-20261021T221915-44986.log`). The new test runs on a temporary tree, never a real vault.
  - Not covered: a folder with `.obsidian` that Obsidian never registered still gets Obsidian's link.
  - Unverified until the end batch, in EQ item 13: Open on screen, for a note chosen in a scratch folder. With a `.obsidian` folder there, only the label is checked, since a click would launch the user's own Obsidian.
- **Ink's Settings inset fix, D-88** (3d5573e, a fast-forward; UI-MAP in the commit; DESIGN already carried it).
  - Every card of rows pads them 5 at the top, 6 at the bottom, 16 on the leading side and 8 on the trailing side, and a row keeps its own 16. So a row's text starts 32 in, its control ends 24 from the trailing edge, and the rules run from 16 to 8. This covers General, Theme, Sessions, Remora (its project chips included) and About.
  - Usage's cards keep their own padding, as the reference draws them: its own card rule wins there.
  - Measured on 2x renders against the references: the rule, the first title and the segment's end match.
  - Checks: 113 tests in seven suites, and the render suites on the new base, off screen (`check-20261021T222427-46725.log`, `check-20261021T222531-47280.log`). The two new layout tests fail without the change.
  - Seen, not changed: General's first row, which has two help lines, is about 2 pt taller than the reference, so later rows drift by about 2 pt per two-line row. The card's top sits about 1.5 pt lower. Both come from I4b's vertical tokens. A small follow-up matches them where a token causes them, and accepts what the system font's metrics cause.
  - EQ items 11 and 13 are plain pairs again.
- **The pause for the plan's limit** (22:36). The 5-hour window was at 82 %, resetting at 00:30, and the weekly one at 24 %. The user asked for a checkpoint and a wait. The checkpoint is `v2` 8447550, with ink's vertical fix for Settings fast-forwarded into it.
  - The vertical fix: Settings' help lines sit on exact 17 pt lines, the glyphs dropped to the middle as CSS places them, and the group label sits on a 10.5 line. One spacing rule caused both drifts. General's and Sessions' rows and rules now land where the reference has them, and the label's capitals sit within half a point. 114 tests passed off screen (`check-20261021T223348-49875.log`).
  - The same rule still makes the rest of Settings' family text about 0.9 pt per line too tall: the sheets, the memory sheet, Theme's and Usage's fine print, Remora's last line and the notes. A mechanical follow-up comes after the pause. The chat's own copy of the rule waits for a look with core, because C7's measurer relies on it. L3b Home stops at a safe step in its own worktree, with a resume note. Core is idle.
- **opencode's first task, a cleanup** (e85d163, a fast-forward; no doc change, since UI-MAP already says the menu bar lists the Dock's set). Under D-89, opencode 2.1.2 ran DeepSeek V4.1 Flash Free in a worktree of its own, on the branch oc/cleanup from 8447550, from a Brief in `~/Library/Caches/loom-v2/evidence/oc/`. Its permissions allow reads, edits outside the docs, the scripts and the manifests, and in the shell only `scripts/check.sh` and git's read commands. The main session reviewed the diff and committed it.
  - What changed:
    - the 13 theme tokens I4c left with no user are gone: 11 in `LoomTheme.Space`, the banner's, the notices', the detail's, the facts' and the actions' spacings, and 2 in `LoomTheme.Layout`, `detailMaxWidth` and `providerIconDetail`. HighlightTests' four-point grid check drops only them;
    - `menuBarEntries()` builds from `attentionCandidates()`, so the rule that a read failure leaves the set, and the side-chat exclusion, live in one place. The entries, their fields and their order are the same, and MenuBarModelTests is unchanged.
  - Checks: 88 tests in 6 suites, off screen, on the first run (`check-20261021T230637-53241.log`).
  - Calibration:
    - the model kept to the Brief's files and rules;
    - a shell loop of searches was denied twice, and it used the search tool instead, with no way around the denial;
    - its report said no command was denied, so the review reads the run's log as well as the report.
  - Heat: the fresh scratch's first build ran about 2 min at full load, 44 s for the code and 84 s for the tests, and the user felt the Mac heat up. The scratch is warm now, so later builds there are incremental. A process started under `taskpolicy -b` keeps background priority in its children, so a build under it stays on the efficiency cores: slower, and cooler.
- **opencode's second task, Settings' family on exact lines** (74fa750, a fast-forward; UI-MAP in 142a710). It ran under `taskpolicy -b` on the user's word, from 23:21 to 23:29, in the same worktree on the branch oc/settings-lines. Its build was incremental, 56 s and 87 s on the efficiency cores.
  - What changed: the rest of Settings' family text moves onto the reference's line boxes, as ink's vertical fix did for the rows' help. That is the sheets' title, subject, facts and list items; the memory sheet's journal lines, note bodies and note-file text; `SettingsNote`; Remora's last line; a tone tile's detail; and Usage's fine print. Each is `.lineHeight(.exact)` on its line token and moves down by a drop token from `Settings.glyphDrop`, in place of its spacing token. The note editor keeps `.lineSpacing`, since a `TextEditor` on an exact line needs a look on screen. Two dead tokens went.
  - Checks: 116 tests in 11 suites, off screen (`check-20261021T232351-55941.log`). Two new layout tests pin a sheet's facts to whole exact lines, and the growth of the sheet's title, subject and list items and of `SettingsNote`'s text to one line token per line. The journal line, Remora's last line, Usage's fine print, the note views and the tone tile need a model or fixed text, so they have no test.
  - The main session rendered Settings off screen (`LOOM_SETTINGS_RENDER_DIR`, under `taskpolicy -b`). General, Sessions and About are byte for byte the same as ink's renders from the vertical fix; the sheets, Theme and Usage change. Measured in text bands at 2x against the reference's drawings:
    - the delete sheet's list items are 21 apart, as in the reference, where they were 17. Its title sits 26.5 above the subject (27 there), and the facts' lines are 19 apart (19 there);
    - the full-access sheet's title sits 31 above its facts (31.5 there), where it was 28.
  - Seen, not changed:
    - The sheet's list labels (Removed, Kept) still take the face's own line, about 13 for 10.5 pt, where the reference's is 10.5, as `SettingsLabel` did before the vertical fix. With the items exact, the first item now sits 21 below its label's top, where the reference has 19, and the meta line still sits 29 above the next label, where it has 27. A small follow-up puts the labels on the 10.5 line.
    - A two-line subject's lines measure 19 apart where the token says 18.2. The layout test holds 18.2, so the gap is in the drawing; the end batch looks at it.
    - The Remora.md card draws its text in the note body's face, where the theme's comment, and its `noteFileText` and `noteFileLine`, now unused, say mono 12 on 1.55. Ink judges which is right.
  - Calibration: the report was accurate and listed its three denied commands word for word: `rg`, a piped `grep` and a `sed` on the manifest. The model used the search and read tools instead.
  - Unverified until the end batch: the memory sheet, Remora's last line, the tone tiles and Usage's fine print against the reference, and the note editor beside the note it edits.
- **opencode's third task, the sheets' list labels** (88b627b, a fast-forward): the label sits on a 10.5 line, as `SettingsLabel` does, so the first item is no longer 2 pt low. 25 tests passed off screen (`check-20261021T234409-59607.log`). From here on, on the user's word (D-89), opencode gets whole slices with one Brief and one review. The next is I6b whole.
- **I6b on opencode** (0214e7a, a fast-forward; UI-MAP and DESIGN in 9f4bf75). The main window's Rename, Delete, Rewind Files and Discard Side Chat are sheets of the family, drawn by a window-level overlay from the model's own state, and the window's key commands hold back on key-down while one is open. The Changes list shows status letters and renames; its line numbers and hunk lines were already there. 104 tests passed off screen (`check-20261022T001308-63225.log`).
  - Unverified until the end batch: the keyboard moving into a sheet opened over a focused terminal (the rename field, Esc, no key reaching the terminal), and the sheets' look against the reference.
  - Left for a later cleanup: `DestructiveButtonStyle`, `LoomTheme.Rewind.sheetWidth` and `RewindSheetKeys` have no user now, and the delete sheet keeps its dry-run paragraph where DESIGN §6 lists Removed and Kept.
  - Its report said no command was denied; seven read-only shell commands were. Its permissions now allow `grep`, `wc`, `head` and `tail`.
- **The first holistic check** passed on `v2` 9a58b3c (I1, R0, R1, R2 and C3 together): every test target without the window tests, 2,502 tests (`check-20261021T030324-96193.log`).
