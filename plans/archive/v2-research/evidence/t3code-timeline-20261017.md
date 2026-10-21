# Evidence: T3 Code chat timeline, for a native re-implementation (17 Oct 2026)

Final report of a read-only researcher (`explorer`) for [plans/V2-PLAN.md](../../V2-PLAN.md). It read the T3 Code clone (`~/Library/Caches/loom-v2-research/repos/t3code`, commit 5c8528f, MIT, Copyright 2026 T3 Tools Inc.) without running anything, plus public issues and PRs. Rules marked **[attribute]** need an attribution comment if ported closely. Section 0 corrects the earlier [chat UI anatomy study](chat-ui-anatomy-20261017.md).

---

# T3 Code chat timeline: report for the native Swift re-implementation

**Conventions.** `T3/` means `/Users/gencberke/Library/Caches/loom-v2-research/repos/t3code`. Line numbers come from that clone. Sizes S/M/L are for the Loom side. T3 is MIT, Copyright 2026 T3 Tools Inc. Rules marked **[attribute]** are specific enough that a close Swift port needs an attribution comment (the fold derivation, summary priority, scroll latch, live-thought extraction, and the citation scheme).

Facts come from reading the code. Inferences are marked "(inference)". Nothing was run, and nothing was written outside this reply.

## 0. Corrections to the earlier study

1. **T3 does not stream Claude assistant text.** `ClaudeAdapterV2.ts` emits text only from complete SDK `assistant` messages (`emitAssistantTextArtifacts` L5907, `streaming:false`). There is no `text_delta` handling (confirmed by grep). Only `thinking_delta` is streamed, through a 50 ms coalescer (L5544). Codex text does stream, with a 50 ms flush.
2. **The 20,000-character highlight limit is composer-only** (`composerCodeBlockHighlight.ts` L22). The timeline uses an LRU of 500 entries / 50 MB instead (`ChatMarkdown.tsx` L352-371).
3. **Cold open is not "75 rows / 1 MiB" for normal threads.** The real policy is 10 user turns (`threadHistoryPaging.ts`). The 75-item and 1 MiB budgets apply only to histories without turn starts.
4. **`ProviderSubagentBar` is not a timeline row.** It is a pill above the composer inside a read-only subagent thread.
5. `apps/swift-ios` is not in this clone. T3's SwiftUI issue #14695 (wrong ordering of tool calls versus text) cannot be traced to code here.

## 1. Timeline structure and turn folding

**Behaviour.** The server projects "turn items" (`user_message`, `assistant_message`, `reasoning`, `command_execution`, `file_change`, `web_search`, `dynamic_tool`, `subagent`, `compaction`, `error`, `run_interrupt_*`, `fork`, `handoff`) into a flat list. The web client turns them into `TimelineEntry` values (`session-logic.ts` L580+) and then into rows (`MessagesTimeline.logic.ts` L1316-1908).

`todo_list` and `checkpoint` items never become rows. Todos go to the composer Tasks badge. Checkpoints become the changed-files card.

**Row kinds** (L481-609): `worktree-setup`, `work`, `work-live`, `working`, `thinking`, `work-toggle`, `turn-fold`, `attempt-fold`, `context-compaction`, `message`, `assistant-meta`, `event`, `proposed-plan`, `html-render`, `mcp-app`. `getItemType` is `message:<role>` or the row kind, which gives the virtualizer recycle buckets.

**Folding** (`deriveTurnFolds`, L954-1139) **[attribute]**. Once a run settles, everything between the user prompt and the run's terminal assistant message collapses into one row. Commentary messages, tool groups, reasoning and subagent cards all fold. The terminal message is the last assistant message of the run.

- The fold row sits at the entry right after the prompt. The live "Working for Xs" header therefore turns into "Worked for Xs" in the same position.
- A run is NOT folded when any of these hold:
  - it is in `unfoldedRunIds` (the active or unsettled run, runs in the active visual response, or failed runs);
  - it contains `run_interrupt_request` or `run_interrupt_result`;
  - it is a runless failed key;
  - runless work is active;
  - it has a streaming message;
  - nothing foldable remains, or only compaction rows would be hidden.
- Some entries stay visible even inside a fold: persistent resource cards (`fork`, `thread_created`, `secret_request`), live subagent cards, complete superseded replies, and notifications.
- Entries after the terminal message are hidden only if they are neither in progress nor failed.
- Duration is `completedAt - startedAt` of the latest run when both exist. Otherwise it runs from the prompt's `createdAt` to the larger of the terminal message's `updatedAt` and the last entry's end.
- Labels:
  - "Worked for {d}", or "Worked" when the duration is unknown.
  - "You stopped after {d}" or "You stopped this response", only when the latest run is `interrupted` and has no interrupt items.
- `formatDuration` (`packages/shared/src/orchestrationTiming.ts`): under 1 s is `Nms`, under 10 s is `x.y s`, under 60 s is `Ns`, otherwise `1h 2m 3s` parts.
- Expansion state (`MessagesTimeline.tsx` L765-790):
  - A run that goes running to interrupted is added to `expandedRunIds`.
  - When a new run starts, the previous run's manual expansion is dropped.
- User stop (`RunExecutionService.ts` L1490-1510) emits `run_interrupt_result` ("Run interrupted by user"). The fold is then skipped, the work stays visible, and a red divider "Run interrupted · message" is shown. So the "You stopped after Xs" path is rare (unverified how often).
- `run_interrupt_request` rows are always dropped (L1515-1520).
- Superseded attempts (steers) fold under an `attempt-fold` row, "Superseded attempt" / "Cut off by a steer".

**Live rendering of the active turn**

- A `working` row, "Working for {timer}", sits under the prompt. Special shimmered labels are "Setting up worktree…" and "Compacting…".
- The active tools are the trailing contiguous work entries of the active run (same attempt id). They collapse into ONE `work-live` row with the stable id `live-activity-row`.
  - It shows the latest running tool label, shimmered, built by `liveWorkEntryLabel`. For commands this is "Running/Ran/Failed/Declined/Stopped {program}", otherwise the display name.
  - Above it is an optional latest-thought line (`liveThoughtLine`, `line-clamp-4`).
  - Clicking expands the whole group.
- If the latest tool failed, a `thinking` row (shimmered "Thinking", brain icon) takes the slot.
- If there is no activity row but the thread is working, a `thinking` row is appended.
- Compaction takes the activity slot.
- The `continuesWorkLog` flag on rows is used for paddings only (`WorkLogBlock`: `pb-0` when continuing or header, `pb-1` for group content, `pb-2` standalone).

**Loom adaptation: M.** Loom already has a live stream and transcript JSONL. Build the same pipeline: a flat entry list, a pure `deriveRows(entries, runState)`, and a pure fold function with the "do not fold" conditions above. Keep the data layer free of AppKit so it is unit-testable. A Claude run maps to "from user prompt to the result message". Interrupt detection comes from `result` with `is_error`/subtype or the user's own Stop.

**User reaction.** #16449 (stuck "running" for about 8 h) and #15029 (working timers reset on every background wake) show that the active-run flag and the timer start must come from persisted timestamps, not from view-appearance time. #14695 (SwiftUI, wrong ordering of tool calls versus text) argues for one flat chronological list, not a work log per turn.

## 2. Work log

**Group summary** (`T3/packages/client-runtime/src/work-log/presentation.ts` L631-715) **[attribute]**.

- Each tool maps to an action class: read, edit, command, code-search, search, browser, device, thread-create, PR actions, other, update.
- `summaryActionPriority`: 0 for command, edit and orchestration verbs; 1 for read, search, browser and the rest; 2 for other and update.
- Pick the top 2 groups by (priority, first-appearance index), then re-sort by appearance.
- Any remainder becomes "Performed N other action(s)".
- Join with "A and b" or "A, b, and c", lower-casing later labels.
- Count labels:
  - "Read N file(s)"
  - "Changed N file(s)" (distinct files)
  - "Ran N command(s)"
  - "Searched code N time(s)"
  - "Searched the web N time(s)"
  - "Used N tool(s)"
  - "Received N update(s)"
- Reasoning alone gives "Thought" or "Thought (×N)".
- MCP and integration sources prepend "Used {names} integration(s)".
- One tool-like entry renders directly as a `work` row. Two or more become a `work-toggle` row.
- `hasFailure` comes from the latest tool-like entry.

**Failure detection.**

- Failure is any of: lifecycle `failed` or `declined`; `tone === error`; `exitCode !== 0`; `outputIndicatesFailure`.
- It also includes regexes in `toolOutputIndicatesFailure` (`T3/packages/shared/src/toolOutput.ts` L205-216) over the first 32,768 characters of command output.
- Lifecycle mapping (`session-logic.ts` L346-364): pending/running/waiting is inProgress; completed; idle; failed; cancelled/interrupted is stopped. "Declined" is legacy and barely reachable for Claude.
- `workEntryIsVisibleInGroup`: neutral-status entries are hidden unless they are in progress in an expanded active group, or stopped. Reasoning is shown only if it has text.

**Row anatomy** (`WorkLog.tsx`).

- Row height `min-h-6` (24 px). The layout is a 24 px icon cell, a truncated label in `text-secondary-label`, a hover-only timestamp, and a chevron.
- Icons are lucide (bot, brain, browser, check, circle-alert, code, eye, globe, hammer, message-circle, search, square-pen, terminal, pull-request, wrench, x, zap).
- A failed non-severe tool dims its icon to 40% and shows a trailing x. A severe failure (`itemType error`) uses a destructive style.
- Row text is `select-none` while detail bodies are `select-text` and stop click propagation.
- Detail body: text kind is `ms-7`, `max-h-96`, scrollable. Panel and media kinds have their own spacing.
- Live-edge pinning inside a detail uses a 4 px slack (`LIVE_EDGE_PX`).

**Expanded group.**

- It is a nested virtualized list of 24 px rows, `drawDistance` 240, with recycling.
- Max height is `min(18rem, 50dvh)` plus the extra height of expanded entries, with top and bottom scroll fades.
- Scroll anchor (rowId + offset) and expanded entries are remembered per thread (`workGroupViewState`).
- It follows appended entries only at the hard end (`shouldFollowWorkGroupAppend`, distance at most 1 px).

**Per-tool bodies** (`V2ItemInspector`).

- command: shell command block, output, and a red "exit N".
- file_change: relative path, `+N -N`, an "Open diff" button, and the failed `diffStr`.
- search: pattern plus `file:line:col` results with a preview.
- web search: links and snippets.
- dynamic tool (Read, Grep, Glob, Task, Agent, TodoWrite, MCP…): key/value args, JSON-highlighted.
- reasoning: italic markdown in a bordered box.
- A Read row shows only the path. A viewed image path shows an inline image (max 16rem).
- Expanded body class: `max-h-64`, mono font, scrolling.

**Claude tool mapping** (`ClaudeAdapterV2.ts` L1895-2040).

- Bash is a command.
- Edit, MultiEdit, NotebookEdit and Write are file changes. The +/- counts come from checkpoint diffs, not from the tool result.
- WebFetch and WebSearch are web searches.
- Everything else is a dynamic tool.
- Labels (`toolActivity.ts` L364-396): "Read {path}", "Searched {q} in {dir}", "Searched files {glob}", "Skill: {name}".
- `commandDisplayText` strips shell wrappers. It is a 1,436-line tokenizer, mostly aimed at Codex wrappers.

**Live command output** (`CommandOutputPanel`).

- `max-h-80`, follow slack 8 px, ANSI spans capped at 2,000.
- A server-side mini terminal model (`T3/packages/shared/src/terminalOutput.ts`) keeps a 64 KiB tail and 64 live lines for `\r` and cursor rewrites. SGR colours are kept, with a 2,048-run line cap.
- `CommandOutputHub.ts`: frame interval 100 ms, replace interval 500 ms, append cap 16 KiB, 64 live and 16 finished commands.
- Streaming opens only while the row is expanded.
- The Claude SDK sends no stdout until the result. T3 therefore polls a private task output file every 250 ms (256 KiB reads).

**Subagents** (`V2LifecycleRow.tsx`, `subagentDisplay.ts`).

- Card: 24 px avatar with a status dot, a title, and one detail line.
  - The detail line shows the result if settled, otherwise progress. Markdown is stripped and the preview is capped at 280 characters.
  - The generic "Child task ended with status" is suppressed.
  - Path-like details are middle-truncated.
- Elapsed time is computed from timestamps. Live cards use `Date.now()` with a 1 s DOM write.
- Status labels: Queued, Running, Waiting, "Idle · resumable", Completed, Failed, Stopped.
- Adjacent subagents of the same run and provider turn merge into a group row (`V2SubagentGroup` L3130). It shows up to 3 avatars plus "+N", "N subagents", a status summary such as "2 working · 1 done", and an aggregate elapsed time. It is collapsible.
- Live subagent cards never fold.
- A child thread is read-only. The header shows a "Subagent of" divider with "Open parent thread".

**Todos and tasks.** There are no timeline rows. They appear in `ComposerTasksBadge` (`MAX_TASK_SEGMENTS` 10). The proposed plan has its own card (see section 6).

**Changed files** (`ChangedFilesTree`, `DiffStatLabel`, `turnDiffTree.ts`).

- The card hangs off the terminal assistant message.
- Header "N changed file(s)" with inline `+a -d` and a sticky header. Buttons: "Collapse/Expand all folders" and "Open diff".
- Single-child directories are compacted. Sorting is numeric `localeCompare`.
- `formatCompactDiffCount` gives 1.2k / 1.2m.
- Expand state is persisted per thread and run.

**Loom adaptation: L overall, but splittable.**
- S: summary function. It is pure and a good unit-test target.
- S: failure detection.
- M: the inline expandable row with a body inspector, built as a native `NSTableView`/SwiftUI row with a custom detail view.
- M: nested scrolling group.
- M: subagent group.
- M: changed-files tree.
- Loom has an advantage T3 lacks for Claude: the CLI gives `tool_use` and `tool_result` as separate stream events, so Loom can fill in the Bash output when the result arrives. Do not build the 250 ms task-file polling in the first version.

**User reaction.** Discussion #6682 (https://github.com/pingdotgg/t3code/discussions/6682, 25 thumbs-up) asks to "view output from tool calls". Collapsed-by-default is accepted only if output stays reachable.

## 3. Streaming and thinking

**Rules and constants.**

- No paced text reveal. New markdown blocks fade in with CSS: opacity 0 to 1, 600 ms ease-out, gated on `data-streaming`, disabled for reduced motion (`T3/apps/web/src/index.css` about L2022).
- The 50 ms coalescing window appears in the live event coalescer (`ThreadLiveEventCoalescer.ts`) and in the provider text coalescer. Plan text uses 400 ms.
- Client-side stability: `replaceStreamingMessageRows` swaps only the changed message in place. `computeStableMessagesTimelineRows` and `isRowUnchanged` (L2106-2242) keep row identity stable so that unchanged rows are not re-rendered.
- Incremental markdown parsing (`markdown-incremental.ts`) runs only while streaming and only if the text contains a fence.
  - A closed top-level fence followed by a blank line is a parse boundary, and the prefix is cached.
  - Any `\r`, BOM or reference definition forces a full re-parse.
- Incremental highlighting (`lib/incrementalHighlighting.ts`) keeps the grammar state per completed line and keeps line views mounted.

**Working timer.**

- `WorkingTimer` (`MessagesTimeline.tsx` L3311) writes `textContent` every 1,000 ms without a re-render.
- `formatWorkingTimer`: under 60 s is `Ns`, otherwise `formatDuration`.
- The start comes from `deriveActiveWorkStartedAt` = `latestRun.startedAt ?? requestedAt ?? sendStartedAt`. This keeps the timer continuous across spin-up.

**Live thought line** (`liveThoughtLine`) **[attribute]**. Take the first `**bold**` heading line, otherwise the first sentence. Strip links, heading marks and list markers. Show at most 4 lines.

**Shimmer.** `live-tool-shine` / `live-activity-focus`: 2.2 s `steps(30)` infinite, a 4.5rem-wide highlight. It runs only while the element is on screen (an IntersectionObserver via `observeVisibleAnimation`, plus a `visibilitychange` pause) and is off for reduced motion.

**Claude 5.1+ hazard.** For these models, text written before a tool call arrives as a THINKING block (`claudeWritesUpdatesAsThinking`, `ClaudeAdapterV2.ts` L1268-1277, L6644-6665). T3 promotes the second of two thinking blocks that precede a `tool_use` to assistant text.

- Evidence: issue #18355 (closed, fixed by #18364) and #18674 (closed wontfix; a user wants collapsible Thought rows kept).
- Loom drives the same CLI, so it will see the same block shape in `stream_event` `content_block_*` with `thinking` blocks. Define the promotion rule deliberately instead of discovering it from a bug report.

**Loom adaptation: S to M.**
- Loom has `--include-partial-messages`, so it can stream Claude text, which T3 does not do. A simple per-frame (about 50 ms) coalesce of deltas into the model is enough.
- The working timer should be a single `Timer`/`CADisplayLink`-free label updated every second, from the persisted run start.
- The shimmer can be a `CAGradientLayer` mask animation. It is optional and cheap to defer.
- The promotion rule for pre-tool thinking is S but needs a decision.

**User reaction.** #18674 (https://github.com/pingdotgg/t3code/issues/18674) and #18355 (https://github.com/pingdotgg/t3code/issues/18355).

## 4. Content rendering

**Markdown** (`T3/apps/web/src/components/ChatMarkdown.tsx`, 3,338 lines).

- GFM, GitHub alerts (Note/Tip/Important/Warning/Caution), task lists, `<details>`.
- File links become chips (workspace-relative, opening in the editor, a panel or Finder). External links get favicons.
- Tables have a wrap/expand toggle and "Copy as Markdown / CSV".
- `shouldPreserveAssistantLineBreaks` is true for Claude's "★ Insight ───" formatting.

**Code blocks.**

- Header with a fence title or language icon. Toolbar: wrap toggle, copy ("Copied" for 1.2 s), and "Run in terminal".
- "Run in terminal" appears only for shell languages, only for closed fences ending in `\n`, with no control or bidi characters, and not while streaming.
- Highlighting uses Shiki with the Oniguruma WASM engine only. The JS regex engine can backtrack catastrophically.
- Cache: LRU, 500 entries or 50 MB, size estimate `max(html*2, code*3)`. Results are cached only when not streaming.

**Mermaid.**

- Lazy import, `securityLevel strict`, `htmlLabels false`, DOMPurify with remote-URL stripping.
- A serialized render queue, a cache of 64, retry on chunk-load errors.
- Show-code toggle, click to expand into a blob SVG.
- Rendered only after streaming ends.

**Images.** They expand into a gallery dialog. `ZoomableImage` has `MAX_ZOOM` 8. Left/right arrows wrap.

**HTML visual replies.** They depend on T3's own `html_render` MCP tool, rendered in a sandboxed iframe. The dialog zooms from 0.5 to 2 in 0.25 steps and is 92vw wide. This is T3-specific (`docs/user/html-renders.md`).

**Thread links.** `t3-thread://v1/<id>` links resolve to the live thread title plus the project favicon (`MarkdownThreadLink.tsx`).

**Selection copy.** `markdown-clipboard.ts` re-serializes the DOM selection to markdown plus HTML.

**Citations** (`T3/docs/internals/assistant-citations.md`, `T3/packages/shared/src/assistantCitations.ts`) **[attribute]**.

- Selecting text inside one assistant message shows a floating "Cite" button (glass, Quote icon, "Shorten selection" when too long). Limits: 8,000 characters of text and 8,000 of comment.
- It is stored as ordinary message text: `[Assistant quote](t3-citation://v1/<env>/<thread>/<msg>?text&start&end&prefix&suffix[&comment])`.
- Selectors are UTF-16 offsets over whitespace-normalized rendered text, with prefix and suffix for disambiguation.
- The chip label is the comment or a quote preview, truncated to 64 characters.
- For the provider, the link is expanded into an `<assistant_citations>` JSON block with `<`, `>`, `&` escaped.
- Clicking the chip navigates back: fetch, unfold and mount the row, then highlight with a CSS custom highlight.

**Loom adaptation.**
- M: markdown through `AttributedString`/`swift-markdown` into an attributed view, with code blocks as separate views. Cache the parsed result per message id plus content hash. Streaming re-parse of the tail block only is the cheap equivalent of T3's incremental parser.
- M: syntax highlighting. The cheapest native route is a bounded tree-sitter or regex highlighter. Use the same LRU idea (size-bounded cache, skip while streaming).
- S: copy button, wrap toggle, and the "Copied" confirmation.
- L: Mermaid. Defer it, or show it as a code block with an "open in browser" action.
- Not worth building: HTML visual replies.
- L, later: citations. The storage scheme is attractive because it needs no new schema (it is plain text in the message), but it needs a selection overlay and range mapping in a native text view.

## 5. Message actions

**User message** (`UserTimelineRow` L2064).

- Right-aligned bubble, `max-w-[80%]`, `rounded-2xl bg-message`.
- Collapsed when visible text is over 600 characters or over 8 lines (`MessagesTimeline.logic.ts` L2244-2269). Collapsed state is `max-h-44` with a 1.75rem fade mask and a "Show full message" / "Show less" button. Quotes and links are measured by their label.
- Attribution lines: "Sent by automation", "Sent by T3 Code", "Sent by another agent". Intent markers: "From queue", "Steer".
- Hover actions: day-aware timestamp, "Edit from here", "Copy message", "Copy prompt link".
- Timestamp rules (`timestampFormat.ts` L127-176): today shows the time only. Yesterday shows "yesterday at {time}". Older shows a numeric date plus time, with the year only if it differs from the current year. Day difference is rounded, so DST days still count as whole days. The tooltip is `{time}, {day}{ordinal} {Month} {year}`.
- "Edit from here" is disabled while working or reverting. It needs `supportsConversationRollback`. It rewinds the conversation and, in worktree threads, optionally the files (`docs/user/composer.md`).

**Assistant message.**

- No bubble, plain markdown, with an sr-only "T3 Code" heading.
- `assistant-meta` (copy, "Fork from this response", timestamp) is shown only on the terminal assistant message of a run and only once the response is no longer in progress.
  - It shows on hover, or always when moved after a trailing tool group (`attachTrailingToolGroupsToAssistant`, L1141-1232), and always on touch.
- Fork availability comes from `canForkProjectedAssistantItem`.

**Loom adaptation.**
- S: copy actions.
- S: the collapse rule for long user messages (600 characters / 8 lines).
- S: the day-aware timestamp (a `DateFormatter` wrapper).
- M: fork and edit-from-here. Both depend on what the Claude CLI session model allows. Loom would need to start a new session with truncated history, so that is a product decision and not only UI. Hover-only meta needs an `NSTrackingArea`.

## 6. Markers and errors

**Dividers** (`TimelineSystemDivider.tsx`): hairline, centered pill, `text-2xs`, icon, label, `· detail`, optional action button, danger tone. Instances:

- "Context compacted {before} → {after} tokens", "Compacting context" (shimmered), failed, stopped (`contextCompactionLabel`). The compaction row stays visible outside folds.
- "Run interrupted · message" (red), "Conversation fork" / "Forked from conversation", "Context handoff".

**Errors.**

- A provider error is a work row with a destructive style, plus a Retry button for workspace-preparation failures.
- Usage limit: "Usage limit reached. Retry after {time}." in warning style.
- Retry rows (`providerErrorPresentation`, `session-logic.ts` L385-419): "Retrying provider (a/b)" with "Retrying in Ns", "Provider recovered", "Provider error after a/b retries".
- `ThreadErrorBanner`: a glass banner pinned at the top of the pane, text `line-clamp-3` with a tooltip, dismissible. Dismissal is keyed by (thread, error) for the session. A warning variant exists for `usage_limit`. Placement is at `ChatView.tsx` L8055-8085.
- `UsageLimitRecoveryBanner` (`ChatView.tsx` L5433): "Usage limit reached — Resets {date}". Actions: "Resume at reset" (toggles to "Cancel auto-resume") and "Snooze until reset". Offered only if the reset time is later than the stop time.
- Banner stack priority (`ComposerBannerStack.tsx`): activity 0, urgent/error/warning 1, notice 2. It shows the first banner plus a peek.
- `ThreadStatusLine` (L5317) covers snoozed, settled and woke states.

**Plan card** (`ProposedPlanCard`): collapsible when over 900 characters or over 20 lines (10-line preview). Menu: copy, download, save to workspace. Question rows show "Answered questions" with an answer preview.

**Loom adaptation.**
- S: dividers (one reusable view, a handful of cases).
- S: error banner with dismiss keyed by (session, error).
- M: usage-limit banner with a reset time and optional auto-resume. This needs a scheduler and the CLI's rate-limit event shape to be confirmed (unverified for the CLI's stream-json).
- S: plan card collapse rule.

## 7. Scrolling, paging, performance

**Follow state machine** (`MessagesTimeline.logic.ts` L310-340, `ChatView.tsx` L4079-4592, `timelineScrollAnchoring.ts`, `T3/packages/shared/src/chatList.ts`) **[attribute]**.

- Three modes: `following-end`, `anchoring-new-turn`, `free-scrolling`.
- Follow re-arms only when `contentLength - scroll - scrollLength <= 40` (`TIMELINE_FOLLOW_REARM_THRESHOLD_PX`). The composer inset cancels out. The library's `isAtEnd` and `isNearEnd` are deliberately not trusted.
- Manual navigation cancels follow (`cancelTimelineLiveFollowForUserNavigation`, L4105):
  - wheel up, but only if the content overflows;
  - touchmove leaving the end band;
  - pointerdown on the scrollbar or away from the end;
  - PageUp/Home/ArrowUp always;
  - PageDown/End/ArrowDown only when away from the end.
  - The cancel path also cancels queued imperative scrolls and freezes smooth scrolling.
- On send, the new user message is anchored near the top (offset 24 in the timeline, 16 in the shared list helper) using an "anchored end space".
  - The scroll animates, with a 750 ms fallback timer or the `scrollend` event.
  - The anchor is released to follow-end when the first tool or work activity for the running turn appears (`shouldReleaseTimelineAnchorForToolActivity`, `ChatView.logic.ts` L238), or when the user scrolls back to the end.
- `maintainScrollAtEnd` is off while any of these hold: citation positioning, restoring a position, anchored end space, follow disabled, a fullscreen app, or a disclosure settling. It is animated only while working and not reduced-motion.
- Disclosure toggles suspend end-maintenance and pin to the end across 2 animation frames (`scheduleDisclosureSettle`).
- The "Scroll to end" pill (glass button, ChevronDown) appears after a 150 ms debounce when not at the end and not following. It hides immediately on return and sits above the composer. `scrollToEnd(true)` releases the anchor first.
- Virtualizer settings: `estimatedItemSize` 90, `maintainScrollAtEndThreshold` 1, `maintainVisibleContentPosition` for data and size.
- Position memory per thread: up to 100 entries in an LRU map. It stores rowId, offsetWithinRow, scrollOffset, atEnd and the disclosure state. Restore waits for two stable layout frames. A thread switch holds the old timeline until the new one is ready.
- Minimap (`timelineMinimapItems.ts`, `MessagesTimeline.tsx` L1572+): one 6 px by 2 px strip per user message, spacing 8 px, max height `calc(100vh - 18rem)`. It shows with a fine pointer and only when the side gutter is at least 48 px. Hover gives a preview card (user text plus final assistant text). Click scrolls with offset 24, and arrow keys navigate. It needs at least 2 items.
- Page scroll via the composer (`pageScrollController.ts`): 150 ms animation, 400 ms acceleration window, 2x max multiplier, 36 px alignment offset, 1 px boundary epsilon.
- Find in thread is server-side search that auto-unfolds folds and attempts containing a match (`threadFind.ts`).

**History and performance** (`docs/internals/performance-regressions.md`, `threadHistoryPaging.ts`).

- Cold open: `{maxUserTurns: 10, maxItems: 75, maxEncodedBytes: 1,048,576}`. The item and byte budgets apply only to histories without turn starts. `THREAD_HISTORY_MAX_RAW_TURNS` is 150.
- Older pages fetch 20 user turns, doubled when jumping to an entry. A "Load earlier turns" / "Loading earlier turns…" button sits in the list header. It is explicit, and no auto-trigger was found.
- Raw command output, dynamic-tool result bodies and inline file-change bodies are omitted on the wire and fetched on expand (`turnItemNeedsDetailFetch`).
- Resume catch-up is capped at 128 events / 1 MiB. `docs/internals/web-ui.md` has guidance on handler-closure retention.

**Loom adaptation: L, the highest-risk area.**
- Use `NSScrollView` with a single follow latch. Loom owns the scroll view, so it can compute "distance from the true content bottom" directly and skip the library trust problem that caused T3's bugs.
- Port the three modes and the 40 px re-arm rule, with the cancel inputs mapped to `scrollWheel`, key events and scroller tracking.
- Stopped sessions come from transcript JSONL, so page by user turn. Keep tool bodies lazy (load on expand), as T3 does.
- Variable-height rows are the other risk. `NSTableView` with `usesAutomaticRowHeights` or a custom layout with cached heights are the options. Cache measured heights by (row id, width, expansion state).
- Minimap: S/M, optional, and a nice differentiator.
- Defer position memory beyond a per-session scroll offset and at-end flag, but do keep that.

**User reaction.**
- #4668 (https://github.com/pingdotgg/t3code/issues/4668): closed by PR #5566 ("streaming no longer forces scroll back to the bottom"). A user threatened to move to cmux.
- #3925 (https://github.com/pingdotgg/t3code/issues/3925): same family.
- PR #5566 (https://github.com/pingdotgg/t3code/pull/5566): the latch design. The library's `isNearEnd` was true half a viewport above the bottom.
- PR #6519: after scrolling back down, an anchored end space stayed installed, so output ran off screen.
- #17056 and #17463: scrolling over or inside an inline HTML render snaps or jumps.
- #16650 (https://github.com/pingdotgg/t3code/issues/16650, open): transcript text overlaps while scrolling up with variable-height virtualization. It recovers after switching threads away and back.

## 8. Empty and new-thread states

- "Send a message to start the conversation." (muted, centered) shows only when there are no rows, nothing is working, and there is no parent link, history control or footer. `hideEmptyPlaceholder` is set in the draft hero or while loading.
- The draft hero is a headline and project picker above a vertically centered composer. On the first foreground send, the composer animates to the bottom with a FLIP translate (`draftHeroTransition.ts`, easing `cubic-bezier(0.4,0,0.2,1)`). The duration variable was not located.
- Layout (`chatCanvasLayout.ts`, `ChatCanvas.tsx`): chat lane max 768 px, min 640 px, padding 48 px. The lane reflows around a floating preview mini player.
- The composer overlays the timeline in an absolute overlay. The timeline has a footer inset of the composer height plus 12 to 16 px, which is why the scroll math must cancel the inset.

**Loom adaptation: S.** Use a bottom content inset equal to the composer height on the scroll view. The FLIP animation is a `CABasicAnimation` on the composer's position, so it is cheap if Loom wants the hero.

## 9. Ranked "inherit" list

| # | Item | Priority | Size |
|---|---|---|---|
| 1 | Single scroll follow latch, 40 px re-arm from the true content bottom, manual-navigation cancel, "Scroll to end" pill with 150 ms debounce | must | L |
| 2 | Flat chronological entry list, with pure row derivation separate from views | must | M |
| 3 | Turn fold at settle ("Worked for Xs"), with the do-not-fold conditions (interrupt, failure, streaming) | must | M |
| 4 | One live activity row with a stable id: latest tool label plus working timer from persisted timestamps | must | M |
| 5 | Tool-group summary (top 2 by priority, count labels, failure from the latest tool) | must | S |
| 6 | Tool rows expandable inline, with per-tool bodies, output loaded lazily on expand | must | M |
| 7 | Handle Claude 5.1+ text-in-thinking blocks with an explicit promotion rule | must | S |
| 8 | Markdown with code-block chrome (copy, wrap) and a bounded highlight cache that skips while streaming | must | M |
| 9 | Stable row identity during streaming (only the changed row updates) | should | S |
| 10 | Error banner with (session, error) dismissal, dividers for compaction/interrupt | should | S |
| 11 | Collapse long user messages (600 characters / 8 lines) | should | S |
| 12 | Subagent card and group with elapsed time from timestamps | should | M |
| 13 | Changed-files card on the final message (compacted tree, +/- counts) | should | M |
| 14 | Per-session position memory (row id plus offset, at-end flag, disclosures) | should | M |
| 15 | Day-aware timestamps, hover meta on the terminal assistant message only | should | S |
| 16 | Paging by user turn for stopped sessions, with an explicit "Load earlier turns" | later | M |
| 17 | Timeline minimap | later | M |
| 18 | Citations through plain-text links | later | L |
| 19 | Usage-limit banner with resume at reset | later | M |

## 10. Do not inherit

- **Assistant text arriving only as complete messages.** That is a limitation of T3's adapter. Loom has partial messages and should stream.
- **Task-output-file polling (250 ms)** for Bash output. Loom gets `tool_result` from the CLI. Revisit only if long commands show nothing until finish.
- **Server-side mini terminal model.** Overbuilt for a first version. Render the final output with basic ANSI.
- **The 1,436-line shell-wrapper tokenizer.** It targets Codex. Show the Bash command as written, trimmed.
- **HTML visual replies** (`html_render` tool). It needs T3's own MCP tool and a sandboxed web view, which Loom does not have.
- **Mermaid in-timeline rendering** for now (cost versus value).
- **Library-level `isAtEnd` trust.** This is the source of T3's scroll bugs (#4668, PR #5566).
- **Explicit-only history paging with no auto-load** is a choice, not a virtue. Loom can load from a local file cheaply.
- **Anchored end space** for new turns. PR #6519 shows it leaving stale state. If Loom wants the new prompt near the top, make it a transient scroll animation, not an installed spacer.
- **Dual state of folds** (`unfoldedRunIds` plus `expandedRunIds` plus attempts). Keep one disclosure set.

## 11. Web or React capabilities that are costly natively

| T3 relies on | Native cost | Cheapest native equivalent |
|---|---|---|
| `@legendapp/list` recycling, variable heights, `maintainVisibleContentPosition` | high | `NSTableView` with cached row heights keyed by (id, width, expansion), and a manual anchor correction on height change |
| CSS `@starting-style` block fade-in | low | `CATransition` or an alpha animation on new block views, only while streaming |
| Shimmer via CSS mask animation | low | `CAGradientLayer` mask animation, paused when the view is off-screen |
| Shiki (Oniguruma WASM) highlighting | high | A small regex or tree-sitter highlighter limited to common languages, cached in an LRU |
| DOM selection to markdown re-serialization | high | Copy the source markdown of the whole message, or of whole blocks |
| CSS custom highlight for citation jump | medium | Temporary background attribute on an `NSTextView` range |
| Mermaid, DOMPurify | high | Skip, or show source with "open in browser" |
| Sandboxed iframe | high | Skip |
| `line-clamp`, truncation with tooltips | low | `NSTextField` `lineBreakMode` and `maximumNumberOfLines` |
| IntersectionObserver for animations | low | Pause on `viewDidMoveToWindow` and visible-rect checks |
| Direct DOM `textContent` writes for the timer | low | A single `NSTextField` updated by a 1 s timer |

## 12. Unverified points

- How often a user stop produces "You stopped after Xs" versus the "Run interrupted" divider in practice.
- Whether any auto-load of older history happens on scroll (none found).
- The FLIP animation duration for the draft hero (variable not located).
- The 90 s MCP timeout carried over from the earlier study.
- Whether the Claude CLI exposes an "updates/highlights" thinking display flag in stream-json mode (#18355 mentions it).
- The CLI's rate-limit event shape needed for a usage-limit banner.
- The upstream `apps/swift-ios` code, which is not in the clone.

## Final block

- **Status:** complete. All 8 areas covered from the clone's source. Web used only for issue and PR evidence.
- **Result:** timeline is a flat entry list, derived into rows by pure functions, with a settle-time fold and one live activity row. The scroll latch (40 px from the true bottom) is the highest-value and highest-risk piece. T3 does not stream Claude text, but Loom can. The Claude 5.1+ pre-tool text-in-thinking block must be handled.
- **Evidence:**
  - `T3/apps/web/src/components/chat/MessagesTimeline.logic.ts`
  - `T3/apps/web/src/components/chat/MessagesTimeline.tsx`
  - `T3/apps/web/src/components/ChatView.tsx`
  - `T3/packages/client-runtime/src/work-log/presentation.ts`
  - `T3/apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts`
  - `T3/apps/web/src/components/chat/WorkLog.tsx`
  - `T3/apps/web/src/timestampFormat.ts`
  - `T3/docs/internals/performance-regressions.md`
  - `T3/docs/internals/assistant-citations.md`
  - Issues and PRs: #4668, #3925, PR #5566, PR #6519, #16650, #17056, #17463, #18355, #18674, discussion #6682.
- **Unverified:** the seven items in section 12.
- **Needs:** a product decision on fork / edit-from-here semantics with the Claude CLI session model, and on the promotion rule for pre-tool thinking blocks.
- **Doc impact:** none expected. The earlier study (`/Users/gencberke/Documents/github/loom-dev/plans/v2-research/evidence/chat-ui-anatomy-20261017.md`) should get the section 0 corrections if the main session chooses to fold them in.
