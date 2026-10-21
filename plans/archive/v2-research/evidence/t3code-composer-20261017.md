# Evidence: T3 Code composer, queue, approvals and plan mode, for a native re-implementation (17 Oct 2026)

Final report of a read-only researcher (`explorer`) for [plans/V2-PLAN.md](../../V2-PLAN.md). It read the T3 Code clone (`~/Library/Caches/loom-v2-research/repos/t3code`, commit 5c8528f, MIT, Copyright 2026 T3 Tools Inc.) without running anything, plus public issues. Rules marked **[ATTR]** need an attribution comment if ported closely. Section 0 corrects the earlier [chat UI anatomy study](chat-ui-anatomy-20261017.md). The planner's decisions on it are in [CHAT-SPEC](../../v2/CHAT-SPEC.md).

---

**Status:** Complete. All eight areas are covered, from code at 5c8528f. I ran nothing from the clone, and the only web use was TinyFish.

**Result:** the T3 Code composer, queue, approval and plan behaviour is mapped below, with `file:line` evidence and a Loom adaptation for each part. It corrects the earlier study in several places.

Path aliases:
- `T3` = `~/Library/Caches/loom-v2-research/repos/t3code`
- `W` = `T3/apps/web/src/components/chat`
- `S` = `T3/apps/server/src/orchestration-v2`
- `CA` = `S/Adapters/ClaudeAdapterV2.ts`
- `CC` = `W/ChatComposer.tsx`

T3 is MIT (© 2026 T3 Tools Inc.). Items tagged **[ATTR]** use thresholds, algorithms or scoring tables specific enough to port with attribution. Add them to a THIRD-PARTY notice.

## 0. Corrections to the earlier study

1. **Enter is queue by default, not steer.** `followUpBehavior` defaults to `"queue"` (`T3/packages/contracts/src/settings.ts:412`). `docs/user/composer.md` "Queued messages" still says Enter steers. That is a known doc bug, issue #19773 (https://github.com/pingdotgg/t3code/issues/19773).
2. **Cmd+Enter is not always "the opposite".** The default binding applies only while a turn runs (`packages/shared/src/keybindings.ts:155`). In a new-thread draft, Cmd+Enter means "start in background" (`:156-160`).
3. **The `@`/`/`/`$`/`#` menu is one flat list, not sections.** One `CommandGroup` (`W/ComposerCommandMenu.tsx:122`). Sections were Superset. Ordering is by item type and score only.
4. **Question dismiss does not exist for Claude.** The server refuses a dismiss on live Claude `AskUserQuestion`: "This question needs an answer. Answer it or stop the turn." (`S/Orchestrator.ts:7509-7515`). Dismiss is exposed only for message-mode requests (`T3/packages/client-runtime/src/state/threadRequests.ts:85`).
5. **Approvals have no keyboard handling at all.** There are no digit keys and no Enter/Esc accelerators. The earlier Loom item 4 is a Loom addition, not a T3 feature.
6. **The context meter is off by default.** `contextWindowMeterEnabled` defaults to `false` (`settings.ts:406`).
7. **#17467 (compact chip) was closed "not planned" with a wontfix label**, not fixed. The chip stays (https://github.com/pingdotgg/t3code/issues/17467).
8. **T3's Stop kills the Claude process.** It sends `interrupt`, then `close`, then waits up to 10 s (`CA:8510-8512`). It does not just cancel the turn.
9. **T3 does not attribute subagent approvals.** The SDK callback has `agentID`, but only the test kit reads it (`CA.testkit.ts:386`). The approval panel shows no agent name.

## 1. The editor

**What the user sees.** A Tiptap rich-text editor. Markdown markers stay in the text. Lists, quotes, task lists and fenced code blocks are live. Chips for files, skills, PRs, threads, images and terminal excerpts sit inline.

**Rules**
- **Enter** sends. **Shift+Enter** inserts a newline, or continues or leaves a list. **Tab** nests a list item and, in a code block, indents.
- `sendShortcut` has three values: `enter` (default), `mod-enter-multiline`, `mod-enter` (`composer-logic.ts:29-37`). In `mod-enter-multiline`, plain Enter sends only while the draft has no newline; once the draft has a newline, Cmd+Enter is required.
- `composerSubmissionIntentForKey` (`composer-logic.ts:39-71`) ignores IME composition (`isComposing`, `keyCode 229`) and key repeat. It also ignores Shift+Enter and Alt+Enter.
- Enter is claimed by the menu first when it is open, and only then by list continuation (`CC:4134-4244`).
- **Prompt history.** ArrowUp recalls the previous sent prompt only when all of these hold:
  - the composer is empty, or holds an unedited recall;
  - there are no attachments or contexts;
  - the caret is on the first visual line (ArrowDown needs the last line);
  - there is no Shift, Alt, Cmd or Ctrl modifier.

  Walking forward past the newest prompt clears the composer. Editing a recalled prompt makes it a normal draft. Recall is text only. It strips review comments, terminal blocks, chip references, the "Ultrathink:\n" prefix, and the plan-implementation prompt. Consecutive duplicates collapse to the newest message id. Position follows the entry id, with a text-match fallback (`W/composerPromptHistory.ts:79-165`, `CC:4094-4132`). **[ATTR]**
- **Large paste to attachment** (`T3/packages/client-runtime/src/textPaste.ts:1-37`). The paste becomes `pasted-text.txt` (then `pasted-text-2.txt`, …) when any of these hold:
  - it is at least 32 KiB, measured as UTF-16 length OR UTF-8 bytes;
  - it would push the prompt over 120,000 chars;
  - it is not bypassed with Cmd+Shift+V.

  If the attachment cannot be staged and the paste would exceed the limit, a toast reads "Pasted text is too large for this message" (`CC:5569-5640`). **[ATTR]**
- **Limits** (`contracts/src/chatAttachment.ts:13-21`):
  - 120,000 prompt chars
  - 100 attachments
  - 10 MiB per image
  - 80 MiB of images in total
  - 50 MiB per file
  - images are compressed to a 2000 px edge with WebP quality steps 0.92, 0.85, 0.78, 0.68
  - HEIC is converted (`imageCompression.ts`)
- **Length validation.** The check runs on submit, not while typing. It uses `max(trimmed length, length after citation expansion)`. The message is "Prompt is N characters over the 120,000-character limit. Shorten or split it before sending." It shows as a red `role=alert` line under the editor and clears when the draft is fixed (`composerSubmission.ts:12-23`, `ComposerPromptLengthValidation.tsx`, `CC:3274`). Send stays enabled.
- **Image thumbnails.** An image gets a thumbnail shelf above the text plus an inline chip. Removing a thumbnail still mentioned in the text asks first. Deleting only the chip leaves the thumbnail.
- **Code blocks.** A triple backtick plus Enter opens a block. A closing fence plus Enter, or two blank lines, leaves it. Backspace at the start unwraps it. The language picker is in the corner. Blocks over 20,000 chars are not syntax-highlighted (`composerCodeBlockHighlight.ts:22`).
- **Type-to-focus.** A printable key or paste with no editable target goes to the composer. Floating layers and secret-request cards are excluded (`composerFocusRedirect.ts:50-75`).
- **Drafts.** The key is `t3code:composer-drafts:v1`, version 9, written to the client's `localStorage` per thread. Writes are debounced 300 ms and flushed on `beforeunload` (`composerDraftStore.ts:93-134`). The draft carries prompt, attachments, contexts, runtime mode, interaction mode and model selection. Drafts are not synced to the server or across devices. Only the queue is server-side.
- **Stash.** Cmd+S saves the current prompt, attachments and chips. On an empty composer, Cmd+S restores a single stash or opens a menu when there are several.
  - Key `t3code:prompt-stash:v2`. It is global across threads, not per thread.
  - It holds at most 20 entries and evicts the oldest.
  - Images are budgeted at 2.7M chars of data URL.
  - It is written immediately, not debounced.
  - Uploaded files expire after 24 h and restore as "needs re-attach" (`promptStashStore.ts:11-22,147-170`, `CC:4246-4620`).
- **Typing guard.** A new approval or question that arrives while the composer is focused and the user typed within 1500 ms is held back. It is released on idle, blur or send, and never re-held. This stops a stray Enter from answering a card (`composerTypingGuard.ts:1-51`, `CC:1995-2010`). **[ATTR]**

**Voice:** the stash and paste behaviour have no specific praise or complaints that I found. The send-shortcut docs are wrong (#19773).

**Loom adaptation**
- Use `NSTextView` (TextKit 2) with `NSTextAttachment` chips. A full Tiptap-style markdown WYSIWYG is the expensive part. Cut it to plain text with chips and optional code-fence handling. **M**, or **L** with rich text.
- Enter and Shift+Enter, IME guard (`hasMarkedText`), ignore repeat: **S**.
- ArrowUp history from the session JSONL user messages, with the strip rules: **S**.
- Large paste to a chip plus a temp file: **S**. In the stream-json message, send an `@path` (or file reference) rather than an inline blob.
- Per-session draft in Loom state, saved on a 300 ms debounce and on quit. The stash is **M** (a global list with a restore menu).
- Typing guard: **S**. Loom has a clean place for it, since `can_use_tool` requests arrive asynchronously.

## 2. Menus (`ComposerCommandMenu`)

**Triggers** (`composer-logic.ts:259-300`). The token under the caret, split on whitespace, decides the menu:
- `/` opens the slash menu.
- `#` plus an optional alphanumeric query opens PRs.
- Any currency symbol (`\p{Sc}`, so `$`, `€`, `₺`) opens skills.
- `@` opens files, folders and threads.

**Item types:** `path`, `slash-command`, `provider-slash-command`, `skill`, `pull-request`, `thread`.

**Contents and ranking**
- **`@`:**
  - Thread matches come first: same environment, not archived, not the current thread, title substring match, newest first, at most 5 (`packages/client-runtime/src/composerThreadItems.ts:3-47`).
  - Then workspace files and folders: 80 results, 120 ms debounce (`state/queries.ts:35-36`).
  - The empty state reads "No matching files or folders."
- **`/`:**
  - Built-ins: `/model`, `/plan`, `/default` (the last two only if plan mode is enabled).
  - Then the provider slash commands from the CLI init.
  - Then skills, labelled `/skill:name` with a source badge (App, Repo, Project, Personal, System).
  - `/compact` appears only when the draft is empty (`CC:2531-2545`, `CC:2604-2700`).
  - **Provider commands are offered only when the slash is at offset 0 of the prompt**, because the CLI expands them only there (`composerSlashCommandSearch.ts:15-28`). Built-ins and skills work on any line.
  - Skills with `enabled=false` or `userInvocable=false` are hidden, and duplicates are removed by name. A setting, "Show skills in slash menu", turns skills off (`providerSkills.ts:25-56`).
- **`$`:** skills only, by the same filter.
- **`#`:**
  - The query is split into a number branch and a text branch.
  - The PR list limit is 99 and the result limit is 12 (`CC:429-431`).
  - There is a 180 ms debounce.
  - Linked PRs sort first.
  - An exact PR number is looked up directly even when older than the recent list.
- **Ranking** is `scoreQueryMatch` in `packages/shared/src/searchRanking.ts`. It uses fixed bands: exact 0, prefix +2, boundary +4, includes +6, fuzzy +100, each plus a length penalty up to 64. For commands the description gets bands 20 to 26. For skills the bands run name 0 to 6, label 1 to 7, short description 20 to 26, description 30 to 36 and scope 40 to 44. Skill ties break by label then name. The score is a minimum over fields. An empty query keeps source order (`providerSkillSearch.ts:14-110`). **[ATTR]**
- **Keys:** ArrowUp and ArrowDown move the highlight and wrap. Enter or Tab inserts. Escape closes the menu and dismisses that trigger. Highlight survives re-render only for the same search key (`composerMenuHighlight.ts`).

**Insertion**
- Path: `[basename](/encoded/path) `. This is a markdown link rendered as a chip. The model sees the markdown, not file contents (`packages/shared/src/composerTrigger.ts:34-37`).
- Provider command: `/name ` as text.
- Skill: `$name ` as text. The Claude adapter rewrites it before sending: it splits `[leading text, "/name trailing text"]` because Claude expands a skill only from the last text block starting with `/` (`CA:1545-1574`).
- PR and thread: a context chip plus a record stored in the draft.
- `/model` opens the model picker. `/plan` and `/default` flip the mode.
- Typing `/plan` or `/default` as the whole message and sending flips the mode (`ChatView.tsx:6347-6355`).

**Voice:** a user asked for slash support as a core gap (https://github.com/pingdotgg/t3code/discussions/6766). T3 later added provider commands from the CLI init. No specific praise found.

**Loom adaptation**
- **Triggers on a Turkish Q Mac keyboard: `@`, `#` and `$` need Option (AltGr).** Only `/` (Shift+7) does not. Offer a "+" button and a shortcut that opens each menu so users never type the trigger character. **S**
- Command list: `slash_commands` and `skills` from the CLI `system/init` message. **S**
- Menu as an `NSPanel` or popover anchored to the caret. **M**
- Port the scoring tables. **S** **[ATTR]**
- Insertion: send the same `@path` and `/name` text the CLI already understands. A chip is display only. Use `/name rest` as the last text block for skills.

## 3. Send, steer, queue, interrupt

**What the user sees:** one round button in the composer footer.

| State | Button |
|---|---|
| Idle, nothing to send | Arrow-up, disabled (opacity 64%) |
| Idle, content | Filled arrow-up circle, label "Submit message" |
| Running, no content | Red circle with a 12 px white rounded square. `aria-label` "Stop generation", tooltip "Interrupt" |
| Running, content, default Queue | `ListPlus` icon, "Queue message" |
| Running, content, default Steer | `CornerUpRight` icon, "Steer message" |
| Cmd or Ctrl held | Icon morphs to the opposite live |
| Compacting | Queue always (`canSteer=false`) |
| Editing a queued row | Check icon, "Update queued message" |
| Interrupted run or held queue, empty composer | Play icon, "Resume thread" |
| Plan follow-up | "Refine" with text; split "Implement" plus chevron menu with no text |
| Pending question | "Next question" or "Submit answer(s)" plus "Previous"; Stop stays on the left |

Source: `W/ComposerPrimaryActions.tsx:117-125,131-156,208-262,264-341`. The tooltip reads "Click to queue, Ctrl/⌘-click or ⌘↵ to steer", or the reverse, composed from the setting.

**Dispatch rule** (`T3/packages/client-runtime/src/state/composerDispatch.ts:4-16`). **[ATTR]**
- Idle sends "auto" (starts a turn).
- Running with `canSteer === false` queues, even with the modifier.
- Running otherwise uses the default action, or the opposite when Cmd or Ctrl is held. The mapping is Queue to Steer and Steer to Queue.

**What the server does**
- **Steer.**
  - The adapter sends a user message with `priority: "now"` (`CA:8641`). Its own comment says this cancels the root turn's running tool calls.
  - Before sending, it moves foreground subagents to the background with `query.backgroundTasks(toolUseId)` and a 5 s join timeout (`CA:8556-8620`).
  - If the turn ended in the meantime, the steer fails and the orchestrator starts a normal follow-up turn instead (`CA:8631-8640`).
  - The timeline marks the message "Steer" with a Redo icon and the tooltip "Steered the active turn". A steer does not start a new response group (`MessagesTimeline.tsx:2400-2445`, `MessagesTimeline.logic.ts:876-881`).
- **Queue.**
  - T3 holds the message as a "queued run" in its own database. It does not use the CLI's `priority: "later"`. It starts a normal turn when the active run ends (`S/Orchestrator.ts:1264-1345`).
  - Starting is skipped when the thread is archived, a blocking run exists, the queue is held, or a usage limit has blocked the thread.
  - After a non-validation failure from the same provider, a missing worktree, or a disabled provider, all queued runs are marked held rather than fired (`:1306-1340`).
  - There is no queue length limit.
- **Capability fallback** (`S/CommandPolicy.ts:160-190`): steer if the provider supports it, else queue, else interrupt-and-restart. Claude declares `supportsActiveSteering: true` and `supportsQueuedMessages: true` (`CA:280-283`).
- **Queue UI** (`W/QueuedRunsControl.tsx`):
  - A "Queued" banner with a count and a collapse toggle, above the composer.
  - The list scrolls at `max-h-32`.
  - Each row: a grip (drag, or ArrowUp and ArrowDown on the grip), a 16 px image thumbnail, one truncated line with a tooltip, then pencil, "Steer" and X buttons.
  - Reorder sends `beforeRunId`; the server renumbers `queuePosition` (`S/Orchestrator.ts:7662-7757`).
  - Cmd+Shift+Enter steers the first row. Alt+Up, with the caret at the start of the composer, edits the last row.
  - **Edit** retargets the composer to a per-run edit draft. The row is highlighted and shows Cancel. The check button saves in place. The user's own draft comes back afterwards (`useQueuedRunEdit.ts`, `queuedMessageEdit.ts`).
  - If the queued run starts or is removed meanwhile, the edit ends. Changed content moves into an empty composer, otherwise it is discarded.
  - **Promote to steer** cancels the queued run and steers the same message into the active run (`S/Orchestrator.ts:7529-7660`). It is refused for automatic completion deliveries.
  - A message the client has not yet confirmed shows a clock icon.
- **Pause after interrupt.**
  - The Stop button sends `run.interrupt` with `holdQueue: true` (`client-runtime/src/operations/commands.ts:769-831`).
  - Every queued run gets `queueHeld: true` (`S/Orchestrator.ts:8796-8805`). A message queued while any run is held is born held (`:5015-5022`).
  - A server restart also holds every queued run (`S/ProviderRuntimeRecoveryService.ts:326-335`).
  - The Play button calls `queue.resume`, which clears `queueHeld` on all queued runs (`S/Orchestrator.ts:10780-10870`).
  - When the last run was interrupted (or hit a usage limit), "Resume thread" sends "Continue where you left off." with `manualContinuationOfRunId` (`ChatView.tsx:1488-1497,5962-6030`).
  - Stop also stops delegated child tasks.
- **Interrupt mechanics.**
  - `existing.query.interrupt`, then `query.close`, then a 10 s wait. After a timeout it finalizes the turn as "interrupted" (`CA:8510-8540`).
  - The next message reopens the query with `resume` and `resumeSessionAt`.
  - There is no default shortcut. `thread.stop` is unbound, and Escape does not interrupt.
- **"You stopped after…"** is the fold header of the latest interrupted turn: "You stopped after 12s", or "You stopped this response" without a duration. Other turns read "Worked for 12s" (`MessagesTimeline.logic.ts:1118-1128`). A hidden "Interrupt requested" item is also recorded.
- **Activity status.** `ComposerActivityStatus` is only a sync row, "Loading messages…" or "Syncing messages…". It shows after 400 ms and stays at least 400 ms (`delayedStatus.ts:3-4`, `threadSync.ts`). **[ATTR]** This pattern is reusable for any transient status.
- **Persistence:** queue and holds are server state (SQLite). The composer draft is local.

**Voice**
- Strong demand: issue #231 "Steer and Queue" has about 77 reactions (https://github.com/pingdotgg/t3code/issues/231). A maintainer answered "yes it's all steer now. we'll add queuing!".
- Reviewer praise: Flavio Copes notes that the queue lives on the server, survives restarts, and can be edited, reordered or steered (paraphrased) (https://flaviocopes.com/t3-code/).
- Complaint: the docs reverse the shortcut mapping (#19773). A search snippet mentions a bug in promoting a queued subagent follow-up (#19351); I read only the snippet.

**Loom adaptation**
- Steer: send the user JSON with `"priority":"now"`. T3 also moves foreground subagents to the background first, via a control request. Whether Loom's wire has that request is **unverified**; test it before copying.
- Queue: keep it **client-side**, in Loom state and persisted. Edit, reorder, promote and hold need it. Release the next item when the session is idle (the `result` event). Do not use `priority:"later"` for user-visible queue items, because the CLI queue cannot be edited or reordered. Optionally mark an in-flight item with `priority:"next"`. T3 never uses `next` or `later`, so their semantics need a Loom-side test.
- Stop: send `interrupt{cancel_queued}` and keep the process alive. This is better than T3's kill-and-resume. Hold Loom's own queue after Stop, with a Resume affordance. **M**
- Port the dispatch rule and the button states. **S** Queue strip with drag reorder and the edit mode: **L**.
- Fold label "You stopped after X": **S**.

## 4. Pending approvals

**What the user sees.** One "top drawer" above the editor, in warning style (shield icon, spacious density). It is mutually exclusive with questions and the plan banner, with priority approval, then question, then plan (`CC:6386-6460`).
- Left: a warning-colored label (e.g. "Command approval"), then the app name (MCP elicitations only), then `1/N` at the right when N > 1.
- Below: the detail, scrollable at `max-h-20`, monospace and non-wrapping for commands, proportional and wrapping for MCP text.
- Right: `[Decline]` (outline) `[Approve]` (filled) `[…]`.
- The "…" menu holds "Cancel" and "Always allow this session".
- The editor is disabled with the placeholder "Resolve this approval request to continue."
- If the provider process is gone, the detail reads "Provider process is gone — interrupt or restart the run to respond." and the buttons are disabled.

Source: `W/ComposerPendingApprovalPanel.tsx:16-66`, `W/ComposerPendingApprovalActions.tsx:25-115`. Provider-supplied options can carry a warning, shown with a triangle icon and tooltip.

**Labels by kind:** "Command approval", "File read approval", "File change approval", "App permission approval", "App access approval".

**Mapping to the CLI** (`CA:2496-2528`)
- Approve: `allow` with `updatedInput` = original input, classification `user_temporary`.
- Always allow this session: `allow` plus `updatedPermissions` = the CLI's own suggestions with `destination:"session"`. If there are none, it adds `{addRules, rules:[{toolName}], behavior:"allow", destination:"session"}`. Classification `user_permanent`.
- Decline: `deny` with message "User declined tool execution."
- Cancel: `deny` with message "User cancelled tool execution." and `interrupt:true`. This ends the turn.
- Detail text is `title ?? description ?? decisionReason ?? summary`, where the summary is `Tool: command|path` truncated to 400 chars (`CA:2267-2280`).
- The approval request is created for every tool use when the mode needs approval (`CA:7850-7925`).

**Keyboard:** none. **Counter:** `1/N` appears only when N > 1.

**After the answer.** The drawer disappears. The timeline keeps a generic work-log row, "Approval requested", with the prompt text (`session-logic.ts:538-543`). I found no code that renders the decision (allowed or denied) in that row, although the runtime request record stores it. This is a gap Loom can fill.

**Subagent attribution:** none in T3, as noted in section 0.

**Hard lesson (issue #15503):** with Auto plus Plan, T3 returned `allow` for Edit and Bash requests that the CLI routes through `canUseTool` in plan mode, so writes ran with no prompt (https://github.com/pingdotgg/t3code/issues/15503, open). In plan mode, never auto-allow.

**Loom adaptation**
- `can_use_tool` handler with the four decisions above, one dock with a stepper, scroll area, and monospace command: **M**.
- Add what T3 lacks: ⌘Y or Return approve, Esc never denies, and the agent name from the request's `agent_id` field (unverified field name on Loom's wire): **S**.
- After an answer, collapse to a one-line record ("Allowed", "Allowed for session", "Denied"): **S**.
- Typing guard: **S** (section 1).
- In plan mode, always ask: **S**, and a must.

## 5. Pending user input and questions

**What the user sees.** A collapsible drawer above the editor.
- Header row: the question's `header` chip, an `i/N` counter when N > 1, a chevron to collapse, and (non-Claude only) an X to dismiss.
- Collapsed: header plus the question text truncated to one line.
- Expanded: the question as markdown, "Select one or more options." for multi-select, and option rows (label, optional description, a numeric badge for options 1 to 9, a check when selected).

**Rules** (`W/ComposerPendingUserInputPanel.tsx`)
- Digits 1 to 9 pick the option. The listener is on `document`. It is ignored with Cmd, Ctrl or Alt held, and when the target is an input, textarea or contenteditable. The composer editor is contenteditable, so digits type normally while the composer has focus (`:149-174`).
- **Single-select** auto-advances 200 ms after a pick. The timer is cleared when the question changes, the panel is disabled, or a new pick arrives. The pick shows optimistically until the draft confirms it. Tests assert there is no skipped question after a manual advance and no stale timer after "Previous" (`:130-145`, `ComposerPendingUserInputPanel.navigation.browser.test.tsx:105-132`).
- **Multi-select** toggles, with no auto-advance. Advance with the primary button.
- **"Other":** the main editor becomes the answer field (`pendingUserInput.ts:56-143`).
  - Placeholder: "Type your own answer, or leave this blank to use the selected option."
  - Typing clears selected options. Picking an option clears the custom text.
  - If the question goes away, the displaced custom text is carried into the prompt after a blank line.
  - With `allowCustomAnswer === false`, the editor is disabled and says "Choose an option above."
  - Custom answers can carry file attachments.
- **Submit** needs every question answered.
- **Dismiss:** see section 0, item 4.
- **To Claude** (`CA:7765-7829`): `AskUserQuestion` becomes `allow` with `updatedInput:{questions, answers:{<question text>: "label1, label2"}}`. Multi-select answers are joined with ", ". An aborted turn returns `deny` "User cancelled tool execution."
- **Resume-compaction question:** T3 reuses `AskUserQuestion` internally for its own "Compact and continue / Keep full history / never ask again" prompt (`CA:7955-8020`).

**Voice:** none found specifically; the digit-key and optimistic-pick tests suggest earlier bugs.

**Loom adaptation**
- Parse `questions[].{question,header,options,multiSelect}` from the `can_use_tool` input. Answer through `updatedInput.answers` keyed by question text: **M**.
- Digit keys only when focus is not in the editor. A collapsed one-line state. A "Answer in Terminal" fallback: **S**.
- Keep the 200 ms auto-advance and cancel logic: **S** **[ATTR]**.

## 6. Plan mode

**What the user sees**
- Mode switching (`CC:4144-4149`, `CompactComposerControlsMenu.tsx:62-77`): a "Plan"/"Build" pill, Shift+Tab, `/plan` and `/default`, or the "Mode" radio (Chat, Plan) in the "…" menu. This is separate from the four-level Access control.
- When Claude proposes a plan, the timeline shows a plan card:
  - A "Plan" badge, the title (first heading), and a "Plan actions" menu: Copy to clipboard, Download as markdown, Save to workspace.
  - The card collapses over 900 chars or 20 lines to a 10-line preview with a gradient and an "Expand plan" button.
- Above the editor a banner reads "Plan ready" plus the title. The placeholder reads "Add feedback to refine the plan, or leave this blank to implement it."
- The footer button becomes **Refine** when there is text, otherwise **Implement** with a chevron menu holding "Implement in a new thread".
- The drawer appears only when all of these hold: no pending question, mode is plan, the latest run has settled, an actionable plan exists, and the draft has no attachments (`ChatView.logic.ts:907-921`).

**Mapping to the provider**
- Mode `plan` sets CLI `permissionMode: "plan"`, which overrides the access mode (`CA:1754-1760`).
- **`ExitPlanMode` is denied** by the host with "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn." The plan text (`input.plan`) becomes the card (`CA:7831-7849`).
- Refine: send the user text in plan mode. Implement: send `"PLEASE IMPLEMENT THIS PLAN:\n" + plan` with the thread mode set to default, and link `sourceProposedPlan` (`proposedPlan.ts:54-76`, `ChatView.tsx:6262-6330`). The mode after Implement is default.
- Implement in a new thread: create a thread titled `Implement <plan title>`, same project and worktree, default mode, send the prompt, navigate (`ChatView.tsx:7364-7470`).
- If the CLI stays in plan mode after the denial, the adapter restores the thread's mode before the next prompt (`CA:8089-8095`).
- Mode changes are stored in the draft and take effect on the next send. They are not applied to a running turn.

**Voice:** the Auto plus Plan bug (#15503).

**Loom adaptation**
- Two options for `ExitPlanMode`:
  - **T3 style:** deny with a message, show the plan card, send a new implement turn. It gives a clean, durable plan artifact and works even when the user wants to refine.
  - **CLI-native (hypothesis, untested on Loom's wire):** `allow` with `updatedPermissions:[{setMode …}]`, so the same turn continues in the new mode with no extra turn.
- Loom's `set_permission_mode` can change mode live, so it should apply mid-turn rather than wait for the next send. This is better than T3.
- Plan card, banner and split button: **M**. Shift+Tab already toggles modes in the CLI, so the shortcut will feel familiar.

## 7. Controls

**Model picker** (`W/ModelPickerContent.tsx`, `modelPickerSearch.ts`, `modelPickerKeys.ts`)
- A popup with a provider sidebar (including a Favorites entry), a "Search models…" field, a star per model to favorite, and a lock that limits providers once a thread has started.
- Keys:
  - Left in an empty search, or Shift+Tab, moves to the sidebar. Up and Down move. Right returns.
  - Cmd+Shift+Up and Cmd+Shift+Down switch providers.
  - Cmd+1 to Cmd+9 picks the nth model while open.
- Search: space-separated tokens, each scored against name, short name, sub-provider, driver and provider name. The exact name scores −1000. Favorites get a −24 boost. Fuzzy matching only for tokens of 3 or more chars. **[ATTR]**
- `/model` in the slash menu opens the picker.

**Effort and traits** (`TraitsPicker.tsx`, `T3/apps/server/src/provider/model-manifest.json`)
- Each model declares option descriptors. Claude's "Reasoning" select has Low, Medium, High, Extra High, Max, Ultracode and Ultrathink. Ultrathink is a prompt prefix ("Ultrathink:\n"). Ultracode maps to xhigh effort plus a multi-agent flag. Opus models add a "Fast Mode" boolean. The default level differs per model.
- **Live apply:** the adapter calls `setModel`, then `applyFlagSettings({effortLevel, fastMode, ultracode})` when the thinking setting is unchanged and the effort stays defined (`CA:1038-1056`). Otherwise it reopens the query. It refuses to reopen while background work runs (`ClaudeBackgroundWorkBlocksQueryReplacementError`, `CA:8095-8110`). This matches Loom's `set_model` and `apply_flag_settings` wire.
- Shortcuts: Cmd+Shift+E opens effort. `composer.increaseEffort` and `composer.decreaseEffort` are unbound but wrap.
- Narrow widths: `CompactComposerControlsMenu` takes over the hidden controls (traits, Mode, Access) into one "More composer controls" menu. A resting-controls measurement decides which blocks stay inline (`restingComposerControlsMeasurement.ts`).

**Permission mode** (`runtimeModeConfig.ts`)
- Four modes: Supervised ("Ask before commands and file changes."), Auto-accept edits, Auto, Full access ("Allow commands and edits without prompts.").
- **The initial default is Full access** (`providerPolicy.ts:31`, `docs/user/permission-modes.md`).
- Mapping to the CLI: default, acceptEdits, auto, bypassPermissions (`CA:1754-1800`).
- Cmd+Shift+A opens the Access menu.

**Context meter** (`W/ContextWindowMeter.tsx`, `.logic.ts`, `lib/contextWindow.ts`)
- **Formula for Claude** (`CA:200-222`, `CA:6855-6885`):
  - `used = input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` of the latest root assistant message.
  - Messages with a `parent_tool_use_id` (subagents) or `model "<synthetic>"` are skipped.
  - `max` comes from a bundled model catalog (fixed 1,000,000 for the listed models).
  - `percent = min(100, used / max × 100)`. After a `compact_boundary` event, `used = post_tokens`.
- **Look:** a 20 px ring (radius 9.75 on a 24 viewBox, stroke 3), turning red above 90% (`normalized > 90`). Percent shows one decimal under 10 (`4.5%`), otherwise whole. Tokens format as `850`, `4.5k`, `120k`, `1.2m`.
- **Popover** (hover delay 150 ms; close delay 150 ms when Compact exists):
  - Title "Context Window", then "NN% · 120k/1m", then a 6 px progress bar.
  - "Total processed" and "Cost" rows only when the provider reports them (Claude does not).
  - The note "Context for <Model> compacts automatically when needed."
  - A "Compact context" button (outline). Disabled reasons include "Compaction is unavailable for this provider" and "Compacting is unavailable right now".
  - Compact is disabled while a turn runs, while approvals or questions are pending, or while a plan is ready (`ChatView.tsx:5352-5376`).
- **Compact-before-send chip** (Claude only, `ContextWindowMeter.logic.ts:12-14,64-85`): shown when `used ≥ 100,000` and the thread has been idle at least the prompt-cache TTL. TTL is 1 h if the usage reports 1 h cache creation, 5 min for 5 min, and 70 min when unknown. While on, Enter first sends `/compact`, then queues the message. This caused #17467.

**ComposerUsageLimits.** An on-demand "Usage limits" banner opened by the `/usage-limits` command: per-account limit windows, reset credits, and a "Manage usage" link. It is dismissible and low priority ("notice").

**Usage-limit recovery.** A "Usage limit reached" warning banner with "Resume at reset" and "Snooze until reset" (`UsageLimitRecoveryBanner.tsx`).

**ComposerTasksBadge** (`W/ComposerTasksBadge.tsx`)
- Row: "Tasks", the current step, `done/total`, and a segmented bar of up to 10 segments (shown only for 2 to 10 steps).
- It expands into a list with a check, dot or circle per step and a per-step duration ("now" for the running one).
- Source: Claude's `TodoWrite` todos (`CA:3219+`).
- Placement: a "shoulder tab" above the composer when nothing else shows, otherwise an activity banner in the stack.

**ComposerBannerStack** (`W/ComposerBannerStack.tsx:33-41,49-117`)
- Priority 0 "activity", 1 "urgent/error/warning", 2 "notice". The front banner wins. The others sit behind a "peek" cap that opens on hover, focus or click. Escape collapses the stack.
- Dismiss runs a 220 ms exit transition, then calls `onDismiss`.
- **Banners that exist** (list order is the tiebreak; `ChatView.tsx:5448-5514`):
  1. Feedback (Codex only).
  2. Usage-limit recovery (urgent).
  3. Usage-limits report (notice).
  4. Project clone.
  5. Environment offline or reconnecting (warning, error).
  6. Server update available, running, failed.
  7. Child-thread input (activity).
  8. Goal, with Resume and Clear (activity).
  9. Background work, with Stop (activity).
  10. Branch changed, with Restore branch (notice, dismissible, session-only).

**ComposerServerUpdateStatus** is about T3's own server version and does nothing for Loom. **ComposerFeedback** is Codex-only (`/feedback`).

**Voice:** the compact-chip backlash is #17467: "borderline unusable", and one user said it cost real work. No specific praise found for the pickers. The Full-access default is T3's own documented choice.

**Loom adaptation**
- Model picker: Claude only, so a flat searchable list with favorites. **S**, or **M** with live apply.
- Effort: `apply_flag_settings{effortLevel}` plus `set_model`. Reasoning options come from the CLI's model list. **S**
- Permission mode: `set_permission_mode` live, not next-send. **S**
- Context ring: **S**, using usage from `assistant` messages, with the same exclusions and formula. Window size from the model list. Show tokens first and percent only when the window is known. Do not let it change what Enter does.
- Tasks badge: **S** (TodoWrite is in the stream).
- Banner stack: **M**. One front banner plus a peek cap. Cut the server-update, feedback and branch banners.
- Usage limits: Loom already sees rate-limit events. A popover is **M**.

## 8. Keyboard shortcuts (defaults from `packages/shared/src/keybindings.ts:123-210`; `mod` = Cmd on macOS)

**Composer and send**
- `Enter` send; `Shift+Enter` newline or list continue; `Tab` and `Shift+Tab` list or code-block indent.
- `Mod+Enter` opposite follow-up (running) / start in background (draft route); `Mod+Alt+Enter` send in background (draft) or send and start a new thread.
- `Mod+Shift+Enter` steer first queued message; `Alt+ArrowUp` edit last queued (caret at start).
- `ArrowUp`/`ArrowDown` history; `Tab`/`Enter` accept menu item; `Esc` close menu.
- `Mod+S` stash or restore; `Mod+Shift+V` paste without attachment folding.
- `Shift+Tab` toggle plan or build (not configurable).
- `Mod+Shift+M` model; `Mod+Shift+E` effort; `Mod+Shift+A` access mode.
- `1`–`9` pick a question option; `Mod+1`–`9` pick a model while the picker is open.
- `Mod+Shift+ArrowUp`/`ArrowDown` switch provider (picker open).
- Unbound by default: `thread.stop`, `composer.increaseEffort`, `composer.decreaseEffort`, `composer.cycleHost`.

**Chat and navigation**
- `Mod+F` find; `Mod+N`/`Mod+Shift+O` new chat; `Mod+Shift+N` new local; `Mod+Alt+N` new without project.
- `Mod+B` sidebar; `Mod+[`/`Mod+]` back and forward; `Mod+Shift+[`/`]` previous and next thread.
- `Mod+1`–`9` jump to thread (when the model picker is closed and on desktop).
- `Mod+Z` undo (outside text fields); `Mod+Shift+C` copy thread ref; `Mod+Shift+S` settle; `Mod+Shift+P` pin.
- `Mod+O` open in editor; `Mod+K` palette; `Mod+P` file picker; `Mod+Shift+F` project search; `Mod+U` usage.

**Panels and other**
- `Mod+J` terminal; `Mod+D` diff; `Mod+Shift+J` preview; `Mod+Alt+B` right panel; `Mod+Shift+B` thread panel.
- `Mod+W` close; `Mod+T` new panel tab; `Mod+Shift+T` reopen; `Mod+Alt+A` theme; `Mod+Alt+Shift+A`/`T` appearance and theme editor.
- Host, workspace, branch and worktree pickers: `Mod+Shift+H`/`X`/`G`/`L`.
- On the usage page: `C`, `T`, `L`, and `Mod+Shift+1`–`4`.

**Design points to inherit**
- Keys are matched by event, with physical-key fallback for non-ASCII letters and punctuation (`shortcutKeyFromEvent`, `keybindings.ts:60-82`).
- Each rule has `when` clauses (`composerFocus`, `turnRunning`, `terminalFocus`, `modelPickerOpen`, …). The last matching rule wins.
- Chat shortcuts run in the capture phase (`useChatShortcuts.ts`).

## Closing lists

### Inherit (ranked)

| # | Item | Tier | Size |
|---|---|---|---|
| 1 | Send / steer / queue model: Enter = queue by setting, modifier = opposite, button icon morphs, idle → Stop when empty | must | M |
| 2 | Client-side editable queue with hold-after-Stop and Resume | must | L |
| 3 | Approval dock: one at a time, `1/N`, Decline/Approve plus "…", in-place, full scrollable command | must | M |
| 4 | Plan mode never auto-allows writes (#15503) and plan follow-up with Refine / Implement | must | M |
| 5 | Question card: digits, 200 ms auto-advance, multi-select, "Other" in the main editor | must | M |
| 6 | Typing guard: hold new cards for 1500 ms after the last keystroke | should | S |
| 7 | Context ring with exact formula, 90% red, hover popover | should | S |
| 8 | Flat ranked menu, provider commands only at offset 0, scoring tables | should | M |
| 9 | Large paste to attachment at 32 KiB (bytes or chars) plus Cmd+Shift+V bypass | should | S |
| 10 | Prompt history with ArrowUp rules | should | S |
| 11 | "You stopped after X" fold label | should | S |
| 12 | Banner stack with three priorities and a peek cap | should | M |
| 13 | Stash (global, 20 entries) | later | M |
| 14 | Tasks badge from TodoWrite | later | S |
| 15 | Composer collapses to one line while scrolling (threshold 24 px, gesture reset 120 ms) | later | M |

### Do not inherit
- **Default "Full access".** It is dangerous. Keep the CLI's default mode.
- **Default-on compact-before-send chip that changes Enter.** Show cache-cold info and offer an explicit button. Never change what Enter does (#17467).
- **Stop that kills the process** (interrupt then close). Loom's `interrupt{cancel_queued}` is gentler and keeps context and background work.
- **Next-send-only mode changes.** Loom can apply `set_permission_mode` live.
- **No approval keyboard handling and no agent attribution.** Add both.
- **Approval outcome invisible in the timeline.** Show it.
- **Server-update and Codex feedback banners, multi-provider locks, host and workspace pickers.** Not relevant.
- **Doc/behaviour mismatch on Enter.** State the default in the UI.
- **Rich-text WYSIWYG in the composer as a first goal.** Large, and not what makes T3's composer good.

### Keyboard collisions and Turkish Q issues

**Typed characters that need Option (AltGr-style) on a Turkish Q keyboard.** I believe this holds on macOS as on Windows, but I did not verify the exact combinations on a device.
- `@`, `#`, `$`, and the brackets `[`, `]`, `{`, `}`. Only `/` (Shift+7) is direct. Provide menu buttons and shortcuts so users are not forced to type triggers.
- Shortcuts defined as a character: `Mod+[`, `Mod+]`, `Mod+Shift+[`, `Mod+Shift+]`, `Mod+=`, `Mod++`, `Mod+-`. Match by physical key code in Swift, not by character.
- Any binding with Option held (`Alt+ArrowUp`, `Mod+Alt+…`) needs Option on every keyboard. `Option+letter` produces characters on TR-Q, so avoid `Option+letter` without Cmd.

**Collisions with macOS defaults** (check against Loom's menu bar)
- `Mod+S` (Save), `Mod+F` (Find), `Mod+N`, `Mod+W`, `Mod+Q`, `Mod+T`, `Mod+Shift+T`, `Mod+O`, `Mod+P`.
- `Mod+B` (bold), `Mod+U` (underline), `Mod+K`, `Mod+J`, `Mod+L`, `Mod+R`, `Mod+Z`, `Mod+D`.
- `Mod+1`–`9`, `Mod+0`, `Mod+=`, `Mod+-`, `Mod+[`, `Mod+]`.
- `Mod+Shift+3`/`4`/`5` (screenshots, so `Mod+Shift+3` and `4` never reach the app on the usage page).
- `Mod+Shift+C` (Show Colors), `Mod+Shift+V` (paste variants), `Mod+Shift+S`, `Mod+Shift+G`, `Mod+Shift+N`, `Mod+Shift+H`, `Mod+Shift+A`.
- `Alt+ArrowUp` (move to paragraph start in text views), `Alt+Left`/`Right` word movement.
- `Shift+Tab` is reverse focus traversal outside text, which is acceptable inside the editor.

**Evidence:** `T3/docs/user/{composer,keybindings,permission-modes}.md`, `T3/packages/shared/src/keybindings.ts`, `T3/packages/client-runtime/src/state/composerDispatch.ts`, `T3/packages/client-runtime/src/textPaste.ts`, `W/ComposerPrimaryActions.tsx`, `W/QueuedRunsControl.tsx`, `W/ComposerPendingApprovalActions.tsx`, `W/ComposerPendingUserInputPanel.tsx`, `W/ContextWindowMeter.tsx`, `W/ComposerBannerStack.tsx`, `CC`, `CA`, `S/Orchestrator.ts`, plus the issue URLs above (#231, #15503, #17467, #19773, discussion #6766) and https://flaviocopes.com/t3-code/.

**Unverified**
- Loom wire semantics of `priority:"next"` versus `"now"` and of `cancel_queued`. T3 uses only `"now"` for steer.
- Whether a Loom control request exists to move foreground subagents to the background.
- Whether `allow` plus `updatedPermissions setMode` on `ExitPlanMode` works on Loom's wire.
- Exact Option combinations on a Turkish Q Mac.
- That T3 never renders the approval outcome (I read the timeline code but did not find a renderer).

**Needs:** your decisions on (a) the default follow-up action for Enter while the agent runs (queue or steer), (b) which `ExitPlanMode` handling Loom uses, and (c) whether Loom's queue lives client-side, as recommended.

**Doc impact:** none expected.
