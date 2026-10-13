# Feedback round 4 on 0.4.2 (13 Oct 2026)

This file records the user's notes of 13 Oct on 0.4.2, the causes found, the choices and the plan. [FEEDBACK-3](FEEDBACK-3.md) was round 3.

The one design choice, where the subagent panel opens, was made on [design/feedback-4-preview.html](../design/feedback-4-preview.html) and recorded as [D-54](../DECISIONS.md).

The user asked for three things in this order:
1. The build.
2. Then the full suite ("sonrasında full suite testi koşabilirsin").
3. Later, an optimization run, when they ask. Code structure and resource use stay optimal throughout, especially for the release app.

The round ships as 0.4.3 ([D-41](../DECISIONS.md) numbering) when the user says so.

## Resume here

- **State.**
  - Slice A, the Stop flow, is done and reviewed: commits 543d0d0 (FB4-1, FB4-4, FB4-6) and 95bffc9 (FB4-3). See [Slice A as built](#slice-a-as-built).
  - Slice B, FB4-2 (the Active section), is with an implementer.
  - Slice C, FB4-5 (the subagent panel), follows. Builds run one at a time.
- **Next.**
  1. Review B.
  2. Brief and review C.
  3. Run the full suite on the combined result (`scripts/check.sh --full --idle`). The user allowed it on 13 Oct.
  4. The on-screen pass, after the user says the computer is idle ([D-13](../DECISIONS.md)).
  5. Release 0.4.3, when the user says.
- **Later.** The optimization run, when the user asks. Candidates noted so far:
  - `SessionLifecycleController.markActivity` has had no caller since FB4-1.
- **Still open from round 3** ([Resume here](FEEDBACK-3.md#resume-here)):
  - The header's hover, ⋯ menu and focus ring in daily use.
  - The subagent rows during a real workflow.
  - The Settings → General cards' secondary text at 4.0:1.
- **Still open from hardening round 1** ([Resume here](HARDENING-1.md#resume-here)):
  - Screen Time.
  - DEVELOPMENT §5 rows for the H1-F evidence commands.
  - About one point of visible-stream CPU.
  - The old worktrees, once the user says OK.

## Items

| # | User note | Cause or finding | Change | State |
| --- | --- | --- | --- | --- |
| FB4-1 | A stopped session jumps up in the activity view. Only a prompt and the work it starts should move it | The user's Stop stamps the activity time: `ConversationController.stop` → `markUserStopped` → `markActivity`. Resume stamps it too: `reactivate` → `markUsed(reactivate: true)` | Stop no longer stamps. Resume reactivates the lifecycle without moving the activity time | slice A |
| FB4-2 | An Active section in the activity view, besides Today. Sessions stay there while they work, until the task is done. Once read, they drop to Today | New | [Active section](#fb4-2-active-section) | slice B |
| FB4-3 | A stopped session does not show its last terminal screen, only "Resume this session with: claude --resume …". A stopped session must use no resources | [Cause](#fb4-3-cause) | A static snapshot of the screen replaces the kept live terminal ([below](#fb4-3-ended-screen)) | slice A |
| FB4-4 | A stopped session's tab should close | Stop leaves the tab alone | A verified Stop closes the tab like its close button ([below](#fb4-1-and-fb4-4-stop-and-resume)) | slice A |
| FB4-5 | A click on a subagent row in the sidebar should open its live transcript, as in Claude | A row's click selects the parent session (`SubagentTree`) | P1, as drawn ([below](#fb4-5-subagent-panel-p1)) | slice C |
| FB4-6 | Longer branch names in the header | `LoomTheme.Header.branchMaxWidth` is 180 pt | 320 pt. The order in which the header gives way is unchanged | slice A |

## FB4-3: cause

- **Fullscreen renderer.** The user's Claude runs with `"tui": "fullscreen"` (`~/.claude/settings.json`, read only). That renderer draws in the terminal's alternate screen.
- **Exit sequence.** Claude exits on SIGHUP from Loom's Stop (`ProcessSupervisor+Stop.swift` sends SIGHUP, SIGTERM, SIGKILL) or on `/exit`. In the 2.1.293 binary, its shutdown leaves the alternate screen (`CSI ?1049l`) and then prints the resume hint to the main screen (`cleanupTerminalModes`, then `printResumeHint`).
- **SwiftTerm.** SwiftTerm clears the alternate buffer when it switches back (`Terminal.activateNormalBuffer(clearAlt:)`). That buffer has no scrollback.
- **Result.** H1-A keeps the whole live surface while the session is selected or pinned, so it holds only the hint. That is what the user's screenshot shows.
- **Test gap.** The fake provider never uses the alternate screen, so the H1-A tests could not catch this.
- **Not verified.** Whether Claude clears the alternate screen before leaving it on SIGHUP. The capture at the user's Stop does not depend on it.

## Planner decisions (routine, reversible)

### FB4-1 and FB4-4: Stop and Resume

- **What moves the activity time.**
  - Moves it: a new session, a prompt, a finished turn, and an in-terminal `/clear` or `/resume` to another session.
  - Does not move it: Stop, Resume, viewing.
- **Resume** keeps its lifecycle effects: active, the stale mark cleared, and the use time that retention reads.
- **Closing the tab.** A verified Stop closes the session's tab, pinned or transient, like the tab's close button. The right neighbour shows, else the left, else nothing.
- **When the tab stays.** The stop is not verified or fails, a resume started meanwhile, or the run ends on its own (`/exit`, a crash).
- **Last screen.** The stopped session's last screen stays reachable from the sidebar ([FB4-3](#fb4-3-ended-screen)).

### FB4-3: ended screen

- **Capture.**
  1. At the user's Stop, before any signal: the visible rows of the active buffer, which is what the user saw.
  2. For `/exit`: a vendored SwiftTerm hook (patch 14) copies the alternate screen right before it is cleared.
  3. At any other run end, in this order: the active alternate screen (a crash); else the copy from step 2; else the main screen with a bounded tail of its scrollback (classic mode).
- **Keep.**
  - Snapshots go in a memory-only LRU by session, with a count cap and a byte cap. It does not depend on selection or tabs.
  - A snapshot is dropped on resume, delete, Show Details and quit. It is never persisted (contract §8).
  - No terminal view, engine or frame driver is kept for an ended run. Today's kept live surfaces (H1-A, up to 8) go away.
- **Show.**
  - With a snapshot: the existing notice ("This session is not running.", Resume, Show Details) above a static, selectable rendering in the terminal's font and colours. No timer, display link or engine runs.
  - Without a snapshot (after a relaunch): the record view, as today.

### FB4-2: Active section

- **Where membership lives.** The event hub keeps it per live run, beside its unviewed-completion state. The indicator logic stays the one place where card states are derived.
- **In.**
  - From the start of a turn: working, an approval, a question during the turn, and background work after the turn.
  - Until the user has read the end. A turn that finished or failed while the user was not looking stays in Active until the session is viewed or marked read.
  - An open-session approval ([D-40](../DECISIONS.md)) counts as an approval.
- **Out.**
  - Ready, Idle, Stale, and a stopped or ended run.
  - A just-resumed session, until a prompt.
  - The "Waiting for you" that Claude sends about a minute after a turn the user already read.
- **Known cases.**
  - A session whose cron or `/loop` tasks keep it Working stays in Active, as its card says Working.
  - An Esc interrupt while the user watches leaves "Waiting for you" in Active until a prompt or Mark as Read. Claude sends no `Stop` hook for an interrupt.
- **Reading.** Reading means the session is selected while the window is active (the hub's `setViewed`). The selected card stays in Active until the user selects another session, so it does not jump under the cursor.
- **Order.** The list's activity order, newest first. A state change alone does not move a card.
- **Drawing.**
  - The heading is "Active" with the count, in the day heading's style, above Today.
  - The section is not drawn when it is empty or while searching.
  - The day sections leave Active rows out.
  - The project view does not change.
  - Next and Previous Session and reveal follow the drawn order. Paging still triggers from the last drawn row.
- **Cost.**
  - One O(1) membership check per live frame.
  - One regroup only when a row's membership flips.
  - No new timers.
  - Render-probe tests pin card evaluations and groupings.
- **Limit.** Active draws loaded rows. A working session's prompt gives it the newest activity, so it is on the first page. An unread finished session that falls past the loaded pages appears when it is paged in.

### FB4-5: subagent panel (P1)

- **Opening.** A click on a subagent row, running or finished, selects its session if needed and shows the subagent's transcript in place of the terminal.
  - The header reads "session › agent type · description", with the state pill (Running, Finished, Failed) and a Session control. Esc also goes back.
  - The requests list and the issue notice stay.
  - A pending approval shows a notice that it is answered in the session's terminal.
- **Content.**
  - Shown: the brief (clipped), the agent's text, each tool call with its main argument, a one-line result (errors in red), and "Thought for Ns".
  - Not shown: the thinking text (not on disk) and attachments.
  - Text is plain. No markdown is rendered and no links are opened.
- **Back to the terminal.** The panel closes on any of:
  - Esc or the Session control;
  - a click on the parent card;
  - selecting another session;
  - the subagent record dropping out at the next prompt;
  - the run ending.
  
  It is not persisted.
- **Resources.**
  - One vnode source watches the file, only while the panel is on screen and the window is visible.
  - Only appended bytes are read: whole lines, with a line cap, reset when the file shrinks or is replaced. They are parsed off the main thread behind a byte gate.
  - Updates are coalesced to about 5 per second at most.
  - The panel keeps the last ~400 entries, each clipped.
  - The terminal keeps running behind the panel and is not resized.
- **Safety.**
  - Agent ids are validated.
  - The path shape is fixed and must resolve, through `realpath`, inside the profile's projects folder.
  - The file is opened read-only with `O_NOFOLLOW`.
- **Scope.** Read-only. This round has no stop control for a subagent.

## Slices

One build at a time. Each slice commits its own work. The planner reviews each one and runs the combined checks.

| Slice | Items | Owner | State |
| --- | --- | --- | --- |
| A | FB4-1, FB4-4, FB4-6 (543d0d0); FB4-3 (95bffc9) | implementer | done, reviewed |
| B | FB4-2 | implementer, after A | running |
| C | FB4-5 | implementer, after B | waiting |

## Slice A as built

- **FB4-1.** `SessionCatalog.markUsed` takes `movesActivity`. The lifecycle controller's resume paths pass false: the lifecycle becomes active, the stale mark is cleared and the use time moves, but not the activity time. The Stop stamp (`SessionRuntime.markUserStopped`) is gone. Claude's `SessionStart` on Loom's own resume never reaches `transitionRun`, because `adoptConversation` returns early for the same conversation. An end-to-end test covers it.
- **FB4-4.** `ConversationController.stop` closes the tab after a verified stop. It skips that when the session has a new run since the stop.
- **FB4-6.** `LoomTheme.Header.branchMaxWidth` is 320. The order in which `HeaderFlowPlan` gives way did not need a change, and a long-branch test pins it.
- **FB4-3, capture.**
  - SwiftTerm patch 14 (`patches/swiftterm-alt-screen-capture.patch`) adds an opt-in `Terminal.onAlternateBufferLeaving` hook, called under the terminal lock just before `?1047l`/`?1049l` clears the alternate buffer. It also adds `copyRows` and `BufferRowsCopy`.
  - `TerminalSurface` keeps the latest non-blank screen that was left. It captures:
    - at Stop, `captureVisibleScreen()`, synchronously before any signal;
    - at run end, `captureEndedScreen()`: the active alternate screen, else the one that was left, else the main buffer plus a scrollback tail.
  - `TerminalScreenSnapshot` holds RGB runs with styles; dim and inverse are applied.
- **FB4-3, keep and show.**
  - `EndedScreenStore` replaces `EndedScreenPolicy`. It is an LRU of 16 snapshots and 4 MiB, with each snapshot capped at 400 rows and 1 MiB.
  - Measured sizes: a 164×52 fullscreen screen is about 16.5 KB; a 399-line classic screen is about 93 KB.
  - `EndedScreenView` is a read-only, selectable `NSTextView` that redraws only for a new capture or a new font size.
  - The fake provider gained an alternate-screen mode (`LOOM_FAKE_ALT_SCREEN=1` or `clear`).
- **Planner review.**
  - The capture runs on the feeding thread under the lock, only when the alternate screen is left, which is rare. Copied cells carry their own grapheme scalars, so a copy read after the lock is released is safe.
  - The controller is not observed, so `EndedScreenStore.use` in a view body does not invalidate anything.
  - Tests exercise the hook through `TerminalSurface` and `view.feed`.
- **Unverified.**
  - A real Claude run.
  - The on-screen look of `EndedScreenView`, including wide and CJK glyph alignment.
  - Whether Claude erases the alternate screen before leaving it on SIGHUP. The capture at Stop covers this either way.

## Verification

| Check | Result |
| --- | --- |
| Slice A targeted suites | Passed (implementer, 13 Oct). Commit 1: SessionLifecycleTests, SessionCatalogV3Tests, SessionCatalogTests, ConversationControllerTests and two header tests, 43 tests (`check-20261013T212945-28402.log`). New tests failed on the old source (`check-20261013T213104-29168.log`). Commit 2: LoomTerminalTests, ConversationControllerTests, SessionNavigationRuleTests, EndedScreenViewTests, DeletionModelTests, ConversationTabsTests and CatalogModelTests, 56 + 115 tests (`check-20261013T214555-35239.log`). Guards passed. |
| Slice B targeted suites | — |
| Slice C targeted suites | — |
| Full suite on the combined result | — |
| On-screen pass | — |
