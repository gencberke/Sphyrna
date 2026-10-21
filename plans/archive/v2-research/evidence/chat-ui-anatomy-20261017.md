# Evidence: chat UI anatomy of the leading agent apps (17 Oct 2026)

Final report of a read-only research subagent for the [v2 concept](../V2-CONCEPT.md). It read the shallow clones in `~/Library/Caches/loom-v2-research/repos/` (nothing run) plus public docs, changelogs and issue threads. Note: the subagent assumed the chat would be a read-only lens over the PTY and JSONL; the concept instead gives the Chat face its own structured-mode process, which adds token streaming and documented input, approvals and questions. The UX findings apply either way.

---

**Status:** Complete. All 10 areas are covered, plus the top-15 and avoid lists. This was read-only, and I ran no code from the clones.

**Result:** the three patterns most worth copying are:
- Fold finished work into one line.
- Pin interactive cards above the composer.
- Put ambient state in a pill rail instead of stacked cards.

Every Loom recommendation below assumes your Direction B: the chat is a lens over the real PTY and JSONL, with hooks for approvals. That has two consequences:
- JSONL gives complete blocks, not tokens, so "streaming" means block-level updates.
- The CLI stays the fallback for any dialog Loom does not model.

Path aliases used below:
- `T3` = `~/Library/Caches/loom-v2-research/repos/t3code/apps/web/src/components/chat`
- `T3docs` = `.../repos/t3code/docs`
- `PAS` = `.../repos/paseo/packages/app/src`
- `ZED` = `.../repos/zed/crates/agent_ui/src/conversation_view/thread_view.rs`
- `OC` = `.../repos/openchamber/packages/ui/src/components/chat`
- `HAP` = `.../repos/happy/packages/happy-app/sources`
- `VK` = `.../repos/vibe-kanban/packages/web-core/src`
- `SUP` = `.../repos/superset`
- `GX` = `.../repos/ghostex`
- `CDX` = `.../repos/codex/codex-rs/tui/src`

---

## 1. Turn structure and folding

**What the leaders do**
- **T3 Code**
  - A finished turn folds into a divider-style row, "Worked for 22s", with the duration measured from the run's start and end times.
  - Code: `deriveTurnFolds` in `T3/MessagesTimeline.logic.ts` L954-1139.
  - It does not fold when:
    - the turn has a streaming message,
    - the run was interrupted,
    - the run failed,
    - a live subagent card is attached,
    - a persistent resource card is attached.
  - Tool groups get a one-line summary from `summarizeToolGroup` (`packages/client-runtime/src/work-log/presentation.ts` L631). Example: "Read 4 files, ran 2 commands".
  - A summary shows at most 2 action categories plus "Performed N other actions". Commands and edits outrank reads.
  - Docs: `T3docs/user/activity-log.md`.
- **Happy**
  - Same pattern: flat while streaming, then one `AgentWorkGroupHeader` above the final answer once the turn completes.
  - `hooks/useGroupedMessages.ts` says grouping is "single-level on purpose".
  - An expanded group renders a second "Hide" header at its bottom. The list is inverted, so growth would otherwise push the tapped header off-screen.
- **Superset**
  - It has a `WorkingFor` row and a `ToolRunRow`.
  - Path: `apps/desktop/.../ChatSession/components/Transcript/components/TurnGroupSection/`.
- **OpenChamber**
  - Docs: `OC/message/parts/DOCUMENTATION.md`.
  - It removed its "Sorted" mode, which folded work above the answer. It now keeps one order, plus an optional collapsed "Activity" header.
  - The active turn shows only the latest 7 rows, with "+N more".
  - The header reports five categories: changed files, exploration, commands, web research, subagents.
  - Narrow columns show only file changes.
  - Static one-line rows are used only for navigation tools (read, grep, webfetch). Everything else is expandable.
- **Claude Desktop** (code.claude.com/docs/en/desktop, "Switch view modes")
  - Three modes, cycled with Ctrl+O.
  - Normal: tool calls collapsed into summaries.
  - Thinking: adds Claude's thinking.
  - Verbose: every tool call and step.
- **Cursor**
  - Changelog 3.4 (cursor.com/changelog/3-4) added Compact, Balanced and Detailed tool-call density.
  - A forum reply says read, search and explore steps always fold into "Explored N tools", even at Detailed.
  - Source: forum.cursor.com/t/…/165292.
- **Codex TUI**
  - Read, List and Search commands group under "Exploring" and "Explored" (`CDX/exec_cell/render.rs` L329-399).
  - Other commands show "Running" and "Ran".

**Pitfalls (user complaints)**
- Claude Code issue #46110: all tool calls collapsed immediately into one summary line, so users could not watch steps live.
- Cursor forum: users say Detailed "isn't honored" and that hiding Explored steps costs them control.
- Claude Desktop issue #61280: Edit and Write diffs are collapsed by default, and users must click each one when reviewing.
- Reddit r/ClaudeCode "Hidden Thinking Sucks": hidden thinking means users cannot catch drift early.

**Loom**
1. Fold only a settled turn (no tool still running, no approval waiting), never a live one. Keep the user message, the final prose and anything needing action always visible.
2. Never auto-fold a failed or interrupted turn, or one with a pending approval. Use a header like "Worked for 22s · Read 4 files, ran 2 commands".
3. Offer three density levels honored everywhere: Normal, Thinking, Verbose. Add one expand-all key (Ctrl+O, matching the CLI).
4. Keep expand state per turn for the session.
5. The summary needs only the tool_use names, so it is cheap to compute from JSONL.

## 2. Tool rendering per type

**Shared model**
- Map tools to about 8 kinds, as `SUP/packages/chat-runtime/src/harness/claude/mapToolUse/mapToolUse.ts` does. Its kinds include edit, execute, search and fetch, with verb phrases like "Creating {path}".
- Render each as a one-line row: icon, verb phrase, subject, trailing status. Expand on click.
- Zed uses card layout only for confirmations, edits and terminal. Everything else is flat (`ZED` L8889 onward, `use_card_layout`).

**Per tool**
- **Read, Grep, Glob, WebFetch, WebSearch**
  - Static one-line rows with no body (OpenChamber `isStaticTool`).
  - Grouped as "Explored" in Codex and Cursor, and "Read N files" in T3.
  - Recommendation: one line each (path, pattern, URL). Click opens the file, or the result in a popover.
- **Edit, MultiEdit, Write**
  - T3 shows the file and a changed-files card per turn with "Open diff". Raw bodies are not shipped over the wire.
  - Vibe-kanban shows +/- counts in the collapsed header (`VK/shared/components/NormalizedConversation/EditDiffRenderer.tsx`) and defaults to collapsed.
  - Zed defaults to an expanded diff preview (`expand_edit_card: true`, `assets/settings/default.json` L1378).
  - Cursor offers a "Last Agent Turn" diff scope.
  - Recommendation:
    - Row: `Edited Foo.swift +12 −3`.
    - Collapsed by default, with a user setting for expanded-by-default (the #61280 ask).
    - Inline unified diff with a hard cap of about 200 lines, then "Open in Changes".
    - Side-by-side belongs in the Changes view, not the stream.
  - NotebookEdit: no leader has a special renderer. Happy and Superset treat it as an ordinary edit row with the path and mode (replace, insert, delete). Do the same.
- **Bash**
  - Codex TUI caps output at 5 lines (`TOOL_CALL_MAX_LINES`) and 50 for user shell. It shows head and tail with "… +N lines (⌃t to view transcript)". Live output keeps head and tail (`exec_cell/live_output.rs`).
  - T3 command rows expand to `max-h-64` and scroll. The server streams live output only while the row is expanded (`T3docs/internals/performance-regressions.md`).
  - Zed expands terminal cards by default.
  - Happy's compact view hides output.
  - Recommendation:
    - Row: `$ command` (use the description field if present, truncated).
    - Failure shows the exit code in a subdued error tone. T3's failed icon is `text-tool-error-icon/40`.
    - Body is the last ~12 lines of output with a "Show all" action. Cap stored text.
- **Task and subagents**
  - Linked, not nested.
  - T3: a card with model, status and duration; live subagents are never folded; the subagent thread is read-only with a bar linking to the parent (`T3/ProviderSubagentBar.tsx`).
  - OpenChamber: an ordinary row with a live duration, an open action and a stop action. The row never reads the child's messages.
  - Happy: shows the last 3 child tool rows plus "N more".
  - Zed: a subagent card, and subagent permission requests surface in the parent's activity bar.
  - Cursor: a subagent's question appears in the parent as "Question from <name>".
  - Recommendation: a one-line card (type, description, duration, status) that opens the existing subagent panel. Surface a child's pending approval on the parent.
- **MCP**
  - T3 and OpenChamber use a generic expandable row with raw input and output behind a disclosure. OpenChamber supports presentation rules per tool.
  - Zed has "View Raw Input".
  - Recommendation: `server · tool` with the server icon, collapsed JSON, no special UI.
- **TodoWrite**
  - Zed: a "Plan" strip in the activity bar with "Current: …" and "N left" (`ZED` L4387).
  - Paseo: a pill "2/7 tasks" that opens a panel. It once carried the active task, but that was truncated first on phones (`PAS/composer/task-list/index.tsx`).
  - Happy and Vibe-kanban render an inline checklist.
  - Recommendation: a pill plus popover, with the latest state taken from the newest TodoWrite call. In the stream, a single quiet row such as "Updated tasks 3/7", not a repeated checklist.
- **States**
  - Running: spinner or shimmer.
  - Success: nothing, or a muted check.
  - Failed: red, subdued, expanded.
  - Denied: a "Denied" label (Superset says "Denied", "Allowed for session").
  - Zed's states are Pending, InProgress, WaitingForConfirmation, Completed, Failed, Rejected and Canceled.
  - Recommendation: show running and failed loudly. Show success silently.

## 3. Interactive cards

**What the leaders do**
- **T3**
  - Approval, question and plan prompts use one pinned strip above the composer (`T3/ChatComposer.tsx` L6390-6440).
  - The approval row shows the detail (`max-h-20` scrollable), a "1/N" counter and Decline/Approve. Other choices ("Always allow this session", "Cancel") sit in a "…" menu (`ComposerPendingApprovalActions.tsx`).
  - Questions (`ComposerPendingUserInputPanel.tsx`):
    - Digit keys 1-9 pick an option.
    - A single-select answer auto-advances after 200 ms.
    - A "Dismiss question without answering" action.
    - The card can be collapsed to one line.
  - When a plan is ready, the composer's primary button becomes Refine / Implement / "Implement in a new thread" (`ComposerPrimaryActions.tsx`).
- **OpenChamber**
  - `PermissionDock.tsx` pins approvals above the composer. One dot per request, answered one at a time.
  - Actions are Allow once / Always / Reject.
- **Paseo**
  - Permission cards sit inline at the stream tail (`PAS/agent-stream/view.tsx` L143).
  - Plan cards have the outcomes pending, approved, rejected, canceled (`components/plan-card.tsx`).
  - Questions support multiSelect, allowOther and per-option preview.
  - Comment at `composer/index.tsx` L1588: queueing behind a permission prompt "would strand the message", so the send behavior is overridden while one is pending.
- **Zed**
  - Cmd-Y allow once, Cmd-Alt-Y allow always, Cmd-Alt-Z reject once, Cmd-Alt-A permission dropdown (`assets/keymaps/default-macos.json` L296-299).
  - A granularity dropdown offers "Always for selected commands".
  - Pending approvals live in the activity bar above the composer.
- **Codex**
  - Options are numbered with letter hotkeys: "1. Yes, proceed (y)", "2. No, and tell Codex what to do differently (esc)".
  - A clipping test checks that a clipped command can open in full (`CDX/bottom_pane/approval_overlay/clipping_tests.rs`).
  - The app uses Enter to approve and Esc to decline.
- **Cursor**
  - Cards say why they appear: "This edits a file outside your workspace".
  - Escape cannot dismiss them by accident (3.24).
  - The Questions tray collapses into a pill with a count.
- **Superset**
  - Resolved approvals shrink to a one-line record: "Allowed", "Allowed for session", "Denied" (`ApprovalRow.tsx`).
- **Ghostex** (PTY and JSONL, the closest to Loom)
  - It models `approval` and `question` prompts with `toolUseId` so the card retires only on that call's own event (`GX/packages/shared/session-chat-transcript.ts` L128-168).
  - It also handles a blocking-dialog notice per agent.

**Pitfalls**
- Cards inline in the stream scroll away while the agent is blocked.
- A permission prompt that queued messages can strand them.
- Open T3 bug #15503: Auto plus Plan silently approves plan-mode writes.

**Loom**
1. Pin one "needs you" dock above the composer, shown one at a time with a 1/N stepper. It is not inline.
2. Always show the full command or a diff summary, with a scroll area.
3. Offer: Allow once, Allow for session (only if hooks can deliver it), Deny, Deny with note, and a permanent "Answer in Terminal".
4. Support number keys, Return for the primary action, and Esc that never auto-denies.
5. After answering, collapse to a one-line record.
6. AskUserQuestion: digit selection, free-text "Other", a collapsible card.
7. Plan card: a titled preview with a "Show full plan" action. The approve step belongs in the dock, not as a stream card.
8. Retire a card only on its matching `tool_use_id`.

## 4. Thinking, streaming, working indicator, interrupt

**What the leaders do**
- **Zed**
  - `ThinkingBlockDisplay` has four values:
    - Auto (default): expand while streaming, collapse when done.
    - Preview: height-capped.
    - AlwaysExpanded.
    - AlwaysCollapsed.
  - Source: `crates/settings_content/src/agent.rs` L85.
  - `show_turn_stats` is off by default. When on, it shows elapsed time only past 30 s and tokens only past 250 (`conversation_view.rs` L108-109).
  - It has an "Awaiting Confirmation" state.
- **T3**
  - A "Thinking" row with a shimmer. `liveThoughtLine` shows the first bold heading or sentence as a one-line label.
  - "Working for 1m 12s" uses a timer written straight to the DOM every second, with no re-render (`WorkingTimer`, `MessagesTimeline.tsx` L3311).
  - Special labels: "Compacting…" and "Setting up worktree…".
  - Stop is labeled "Interrupt" and appears when the draft is empty. Typing text swaps it for a steer arrow (`T3docs/user/composer.md`).
  - An interrupted turn can read "You stopped after 1m 4s".
- **OpenChamber**
  - A floating "working" chip above the composer morphs into the scroll-to-bottom pill when the user is away from the live edge (`OC/StatusRow.tsx`).
- **Paseo**
  - Paced text reveal: backlog drains over ~150 ms so lumpy deltas look smooth (`PAS/agent-stream/text-reveal.ts`).
- **Claude Desktop**
  - Esc stops. Enter sends a correction without stopping the running action.
  - Settings can show thinking summaries.

**Pitfalls**
- Codex #53478: a long chat's one-line activity summary goes stale, so users cannot tell working from stuck.
- T3 #16449: a thread stuck "running" for about 8 hours after a provider error.
- T3 #15854: Stop before init bricks the thread.
- T3 #15029: working timers reset on every background wake.
- VS Code extension: re-parsing the whole thinking text on each update slowed it (Claude Code changelog).

**Loom**
1. Status comes from hooks and JSONL: Working, Needs you, Idle, Stopped. Render "Working · 1m 12s" from a start timestamp, with one lightweight timer visible only while on screen.
2. If no signal has arrived for N seconds, say "no activity for 40s" rather than keep an old label.
3. Thinking: a single muted "Thinking" line with the first heading as a label. Full text only in Thinking or Verbose mode. Default is Zed-style Auto where the data allows.
4. Update text per complete block, as the resource rules already say. Do not fake token streaming.
5. Esc on the composer interrupts only after a visible Stop affordance, and it goes through the real PTY.

## 5. Session chrome

**What the leaders do**
- **Header**
  - T3 is minimal: breadcrumb of project and thread title, click to rename (`T3/ChatHeader.tsx`).
  - Claude Desktop puts the session title in the toolbar, with a ⋮ menu for Background tasks.
- **Context meter and cost**
  - T3 `ContextWindowMeter.tsx`: a 20 px ring in the composer footer. On hover it shows tokens, total processed, cost and a Compact action. The ring turns red above 90%.
  - Zed has a similar ring with a cost tooltip.
  - Claude Desktop has a usage ring next to the model picker. Cursor shows a usage ring past a threshold.
- **Controls**
  - Claude Desktop: model, effort and permission mode in the prompt area, with Cmd+Shift+I, E and M menus.
  - Conductor: "loadouts" are presets of model, effort and mode.
- **Todo/plan panel, changed-files summary**
  - Zed's activity bar stacks permission, plan, edits summary and queue.
  - Paseo's pill rail shows tasks, subagents and diff stat.
  - Claude Desktop shows a "+12 −1" indicator that opens the diff viewer.
  - Cursor puts Goal, Queued, Changes, Agents and Terminals pills above the prompt (3.24).
- **Right panels**
  - Claude Desktop has chat, diff, browser, terminal and file panes, plus side chat (Cmd+;).
  - T3 has diff, browser and tasks.

**Pitfalls**
- Paseo replaced stacked tracker cards with one pill rail because each card pushed the composer down (`PAS/composer/tracks.tsx` L1-35).
- Cursor user complaint on forum thread 171672: coarse notification handling (low-confidence).
- T3's preview browser leaked GPU memory (#14730, #13610). Keep heavy panels out of the chat.

**Loom**
1. Header: title, project/branch, one state pill, and the Chat/Terminal segment. Nothing else.
2. Footer: model, effort, permission mode, plus a context ring with detail on hover. Show tokens first, and percent only where the window is known.
3. One pill rail above the composer: tasks 3/7, subagents 2, queue 1, changes +N −M. Each opens a popover.
4. Cost belongs in the ring popover and the Usage view, not on every turn.
5. Collapse footer controls into a "…" menu when narrow (T3 `CompactComposerControlsMenu`).

## 6. Composer

**What the leaders do**
- **Editing and Enter**
  - T3: Tiptap composer, Enter sends, Shift+Enter continues lists, large pastes of 32 KiB or more become attachments, ArrowUp in an empty composer recalls prompts, Cmd+S stashes a draft (`T3docs/user/composer.md`).
  - Zed: `use_modifier_to_send` setting and `message_editor_min_lines`.
  - Claude Desktop: Enter sends, `@` mentions files, `+` for attachments and skills, and a gray suggested next prompt accepted with Tab or Right arrow.
  - Codex: the same Tab idea; it never auto-sends.
- **@ and /**
  - T3 menu item types: path, slash-command, provider-slash-command, skill, pull-request, thread (`T3/ComposerCommandMenu.tsx`). Provider slash commands are offered only at the start of the prompt.
  - Dragging a thread onto the composer attaches only an ID.
  - Superset `MentionMenu` shows sections.
  - Cursor: `@` references past chats, `#` references PRs.
- **Queue**
  - T3: Enter steers or queues per a setting, Cmd+Enter does the opposite. The queue sits above the composer with edit, reorder by drag, promote to steer, remove. It persists across restarts. Option+Up edits the latest queued message.
  - Zed: `MessageQueue` with `steer`, Paused and AbsorbingCancel states (`conversation_view/message_queue.rs`).
  - Superset: "Queue paused because you interrupted" with Clear all and Resume (`QueuePausedBar.tsx`).
  - Conductor removed its queue in 0.86 in favor of steering. A message waiting for a long command shows lighter.
  - Ghostex queue states are queued, sending, failed. Draining stops at a failed head row and the text is never discarded (`GX/packages/shared/session-chat-queue.ts`). Drafts sync on blur, not per keystroke, and never clobber.
- **Drafts**
  - T3 composer drafts and stash; Zed `draft_prompt_store.rs`; Warp per-session drafts.

**Pitfalls**
- T3 #17467: a default-on "Compact" chip made Enter run /compact first on stale Claude threads (14 reactions). Smart defaults that change what Enter does are resented.
- Codex #31128: queued follow-ups silently vanished.
- T3 #231 (77 reactions): users want both steer and queue.

**Loom**
1. Loom's send path is draft-first and never retried. Delivery states: queued, pasted, delivered, outcome unknown.
2. Queue strip above the composer: memory-only, editable, reorderable, cancellable, with a failed state that keeps the text and a pause after interrupt. Warn at Quit.
3. Enter always means send. Cmd+Enter means the opposite follow-up mode.
4. One typed trigger menu: `@` for files, folders, sessions; `/` for skills and commands (only valid at the start); ranked sections.
5. ArrowUp history, per-session draft, and large-paste-to-attachment chip.
6. Dialogs Loom cannot model get the "Answer in Terminal" fallback.

## 7. Message actions

**What the leaders do**
- **T3**
  - Hover actions: copy, fork, "Edit from here".
  - Edit from here rewinds the conversation. "Revert files too" is offered only for worktree threads, and refused if another thread uses the same directory.
  - Text citation: "Cite in composer".
- **Zed**
  - A "Restore Checkpoint" row between turns with a tooltip about files (`ZED` L6891).
  - Context menu: "Copy This Agent Response", "Copy as Markdown", "Scroll to Bottom".
  - Recoverable submissions show "Message failed to send" with Copy (`ZED` L1617).
- **Conductor**
  - A revert icon on hover. Docs warn it permanently deletes the later messages and code changes.
- **Paseo**
  - Fork menu in the turn footer (`PAS/agent-stream/turn-footer.tsx`).
  - Fork of an in-flight turn includes the partial text.
- **Vibe-kanban**
  - Inline retry editor (`RetryEditorInline.tsx`).
- **OpenChamber**
  - Whole-turn copy copies all assistant text parts, excluding tool output and thinking (DOCUMENTATION.md).

**Pitfalls**
- Rewind is destructive; the labels must say so.
- A fork seed that omits live text loses what the user is watching.

**Loom**
1. Show actions only on hover or focus: copy, copy turn, fork from here, "Rewind (files too)" gated on what the CLI supports, and "Open in Terminal".
2. Open in Terminal is Loom's own differentiator.
3. Edit and resend should load the old text into the composer rather than mutate history.

## 8. Errors, retries, rate limits, markers

**What the leaders do**
- **Zed**
  - Callouts with actions: "Context Too Large" with Retry, New Thread, Upgrade (`ZED` L12196).
  - "Thread reaching the token limit soon" suggests `/compact` or a new thread @-mentioning this one (L12777).
  - "Retrying. Next attempt in 5 seconds (Attempt 2 of 4)" (L3535).
  - Compaction states: "Compacting Context…", "Context Compacted", "Compaction Failed" (L4564).
  - "Resumed Session" notice.
- **T3**
  - `ThreadErrorBanner`: error text clamped to 3 lines, full text in a tooltip, dismissible, with a warning style for usage limits.
  - `UsageLimitRecoveryBanner`: "Usage limit reached. Resets <time>", with Resume at reset and Snooze.
  - `TimelineSystemDivider`: a hairline with a centered pill for markers.
- **Ghostex**
  - A notice taxonomy (`GX/server/src/session_chat_notice/types.rs`): loginExpired, trustPrompt, usageLimit, streamError, updatePrompt, agentExited, queuedInput, deliveryFailed, apiRefusal, and an "input blocked" notice when a TUI dialog replaces the composer.
  - Past-event notices are not retired by a clean screen.
  - The refusal notice is detected from the transcript, not the screen.
- **Cursor**
  - A "New Messages" divider and pill marks where unread starts.

**Pitfalls**
- Dismissing a stale error banner and having it return, or never clearing it.
- Raw JSON error text in the stream.

**Loom**
1. Use hairline dividers for compaction, resume, interruption ("You stopped after 1m 4s") and model change.
2. Use banners above the composer for blockers: login expired, usage limit with reset time, input blocked by a dialog.
3. Every error banner needs an action (Retry, Open Terminal, Copy details) and a session-level dismiss.
4. Unknown records appear as collapsed raw rows plus a drift notice.

## 9. Scrolling and performance

**What the leaders do**
- **Stick to bottom**
  - T3: follow re-arms within 40 px of the bottom, because strict `isAtEnd` flickers while streaming (`TIMELINE_FOLLOW_REARM_THRESHOLD_PX`, `T3/MessagesTimeline.logic.ts` L323). It uses `@legendapp/list` with `maintainScrollAtEnd`.
  - Vibe-kanban: `NEAR_BOTTOM_THRESHOLD_PX = 64` and declarative scroll intents (initial-bottom, follow-bottom, preserve-anchor, jump-to-bottom, jump-to-index) in `VK/features/workspace-chat/model/conversation-scroll-commands.ts`.
  - OpenChamber: a floating pill doubles as "Jump to latest". An expansion never calls scroll-to-bottom.
- **Navigation**
  - T3 timeline minimap by user message; Paseo `chat-outline`; Cursor Cmd+Up/Down between your messages.
- **Windowing and limits**
  - T3 cold open: 75 rows or about 1 MiB; older rows page in; raw command output never goes over the wire; live output only while a row is expanded.
  - Paseo caps a rendered assistant message at 32,000 characters.
  - T3 does not highlight code blocks above 20,000 characters.
  - T3 caches highlighted code in an LRU of 500 entries or 50 MB.
  - Codex markdown streaming commits only at newline boundaries (`CDX/markdown_stream.rs`).
  - Ghostex fetches raw "detail" pages only for an expanded work section.
- **Reports of slowness**
  - Codex #11984: the renderer reached 4-5 GB on long sessions.
  - T3 #20329: a 32 GB Mac under memory pressure from concurrent runs.

**Loom**
1. Bounded backward paging (cold window about 1.5 MiB), prepend with an anchor held, and no whole-file parse.
2. Virtualize rows. Cap and elide large tool output, and cap markdown rendering.
3. Skip syntax highlighting past a size limit and cache highlights.
4. Parse markdown per completed block. Mount no hidden bodies. Hold no timers or watchers while hidden.
5. Provide a Jump to latest pill, and a user-message outline or minimap.

## 10. Empty, first-run, idle, and avoiding overwhelm

**What the leaders do**
- **Empty states**
  - OpenChamber: a faint logo and one line.
  - T3: "Pick a thread to continue" with one sentence.
  - T3 draft: a hero headline, and the composer docks after the first send.
  - T3 hides Git controls once the thread starts, unless the "Composer context" setting is on.
  - Codex has an `empty_state_animation`.
- **Progressive disclosure and density**
  - Claude Desktop: three view modes.
  - Cursor: Compact, Balanced, Detailed.
  - OpenChamber: the Activity default, Collapsed or Expanded.
  - Zed: `expand_edit_card`, `expand_terminal_card`, `thinking_display`, `show_turn_stats` and `max_content_width`.
  - Conductor: "Garry mode" (Ctrl+O) expands all tool calls.
  - Paseo: one pill rail instead of cards.
  - T3: panel animations default to 0 ms.
- **Idle and hints**
  - Suggested next prompt as ghost text (Claude Desktop, Codex, Cursor).
  - Unread dot and "New Messages" divider.
- **First run**
  - T3 welcome wizard checks the agents and offers a terminal command to fix them. It does not replace unreadable settings with defaults.

**Pitfalls**
- Heavy onboarding or a tour.
- Defaults that hide information from power users (the Cursor and Claude Code complaints above).

**Loom**
1. The empty state is one line plus the composer. For a stopped session, show the transcript and a Resume action.
2. Defaults are calm: folded settled work, collapsed diffs, thinking as one line, no cost on turns.
3. Each default has a settings switch and one global expand-all key.
4. Let the composer suggest the next prompt as ghost text accepted by Tab. Never send it.

---

## Top 15 patterns for "complete yet calm"

1. Fold settled work into one "Worked for 22s · Read 4 files, ran 2 commands" row. Keep live work visible and never fold failures or pending approvals.
2. One-line tool rows (icon, verb, subject, status), expandable on click. Success is silent, failure is loud.
3. A three-level density control that is honored everywhere, plus one expand-all key.
4. Edit rows with filename and +N −M. Diffs collapsed by default with a setting, and a per-turn changed-files card that opens a diff.
5. A pinned "needs you" dock above the composer for approvals, questions and plans, one at a time with a stepper.
6. Numeric hotkeys in cards, Esc that never silently denies, and a resolved card collapsing to one line.
7. A pill rail above the composer (tasks, subagents, queue, changes), each pill opening a popover. No stacked cards.
8. A minimal composer footer: model, effort, mode, and a context ring with detail on hover.
9. An honest working indicator: timer, "no activity for Ns" when quiet, and a clear Stop.
10. A queue strip above the composer: edit, reorder, cancel, a failed state that keeps the text, and a pause on interrupt.
11. Stick-to-bottom with a 40-64 px re-arm threshold, a Jump to latest pill, and anchor-preserving history paging.
12. Thinking as a single line (latest heading), expandable, with a mode that shows the full text.
13. Hairline dividers for compaction, resume and interruption, and actionable banners for blockers (login, usage limit, dialog).
14. Hover-only message actions: copy, fork, rewind with an explicit files choice, and Open in Terminal.
15. One `@` and `/` menu with ranked sections, ArrowUp prompt history, and per-session drafts that never overwrite.

## Patterns to avoid

- Folding a turn while it is still running.
- Density settings that do not do what they say.
- Hiding thinking or diffs with no setting to show them.
- A smart default that changes what Enter does.
- A queue that can drop a message silently, or one that keeps firing after an interrupt.
- Stacked cards above the composer that push the input down.
- Inline-only approvals that scroll out of view.
- Always-on per-turn cost or token counters.
- A stale one-line activity summary that looks alive.
- Reordering work above the answer (OpenChamber removed this).
- Per-token markdown reparsing and unbounded hidden bodies.
- Embedded browser or preview panes in the chat.
- Optimistic "sent" claims Loom cannot prove.
- Destructive rewind with vague wording.
- Raw error text instead of a typed notice with an action.

---

**Evidence:** all in the clones and URLs cited inline. The user-complaint sources are:
- github.com/anthropics/claude-code/issues/46110 and /61280
- github.com/openai/codex/issues/31128, /11984 and /53478
- forum.cursor.com/t/…/165292
- reddit r/ClaudeCode "Hidden Thinking Sucks"
- T3 issues cited from `plans/v2-research/products/t3code.md`

**Unverified**
- Claude Desktop, Cursor and the Codex app are closed source. Their claims rest on docs, changelogs, forum posts and the earlier product notes. I did not re-verify the Codex app UI (docs moved to learn.chatgpt.com).
- The Cursor forum reply that explains what Detailed covers appears to come from staff, but I could not confirm that.
- I did not exercise T3's fold logic. The interrupted-turn label path looks contradictory in `deriveTurnFolds`.
- Whether the JSONL and hooks expose each signal Loom would need (api_retry, usage-limit reset time, partial thinking, tool progress) is open. It belongs to the Phase 0 spikes.
- I only skimmed Orca, Emdash, Warp, cmux and herdr, which are terminal-first and not chat references.

**Needs:** nothing blocking. A decision on density defaults and on whether thinking shows by default would shape the first design pass.

**Doc impact:** none expected.
