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
  - Slice B, the Active section (FB4-2), is done and reviewed: da77473, plus the planner's fix 71d4093. See [Slice B as built](#slice-b-as-built).
  - Slice C, the subagent panel (FB4-5), is done and reviewed: a6cd400 and 1d4b7de. See [Slice C as built](#slice-c-as-built).
  - Full suite: the second run on 3d4822f passes ([verification](#verification)). The first run had failed one timing test, fixed in 9ade38d.
  - The optimizer review is done ([findings](#optimizer-review-13-oct)). The user asked for it on 13 Oct ("optimizer'ı max effort spawnlarsın"). It ran as `strict-reviewer` with the optimizer Brief on Opus 5.5 at max effort ([D-06](../DECISIONS.md) requires at least `xhigh`), and read only. Its one blocking finding, R1, is fixed in 81ae519. The user chose to apply U1 and I1 too ([D-55](../DECISIONS.md)): done in 27dd23c and 4390445. The full suite runs again on the result.
- **Next.**
  1. The full suite on the combined result (`scripts/check.sh --full --idle`). The user allowed it on 13 Oct.
  2. The on-screen pass, after the user says the computer is idle ([D-13](../DECISIONS.md)).
  3. Release 0.4.3, when the user says.
- **Optimization.** The optimizer's findings are verified and prioritized here; the user decides what is built. Candidates noted so far:
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
| FB4-1 | A stopped session jumps up in the activity view. Only a prompt and the work it starts should move it | The user's Stop stamps the activity time: `ConversationController.stop` → `markUserStopped` → `markActivity`. Resume stamps it too: `reactivate` → `markUsed(reactivate: true)` | Stop no longer stamps. Resume reactivates the lifecycle without moving the activity time | done (slice A) |
| FB4-2 | An Active section in the activity view, besides Today. Sessions stay there while they work, until the task is done. Once read, they drop to Today | New | [Active section](#fb4-2-active-section) | done (slice B) |
| FB4-3 | A stopped session does not show its last terminal screen, only "Resume this session with: claude --resume …". A stopped session must use no resources | [Cause](#fb4-3-cause) | A static snapshot of the screen replaces the kept live terminal ([below](#fb4-3-ended-screen)) | done (slice A) |
| FB4-4 | A stopped session's tab should close | Stop leaves the tab alone | A verified Stop closes the tab like its close button ([below](#fb4-1-and-fb4-4-stop-and-resume)) | done (slice A) |
| FB4-5 | A click on a subagent row in the sidebar should open its live transcript, as in Claude | A row's click selects the parent session (`SubagentTree`) | P1, as drawn ([below](#fb4-5-subagent-panel-p1)) | done (slice C) |
| FB4-6 | Longer branch names in the header | `LoomTheme.Header.branchMaxWidth` is 180 pt | 320 pt. The order in which the header gives way is unchanged | done (slice A) |

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
| B | FB4-2 (da77473, planner fix 71d4093) | implementer | done, reviewed |
| C | FB4-5 (a6cd400, 1d4b7de) | implementer | done, reviewed |

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

## Slice B as built

- **Hub.**
  - `SessionViewState.activePhase` is `inactive`, `underWay` or `endedUnread`. `SessionEventHub.publish` applies the transitions in [FB4-2](#fb4-2-active-section).
  - Viewing (`.unviewedCompletion(false)`) and Mark as Read end an unread end. `setViewed` also publishes for a failed turn.
  - Planner fix 71d4093: background work after the turn that ends while nobody looks also sets the unviewed completion, so the card says Finished in Active, not Ready. Its regression test failed without the fix.
- **Model** (`CatalogModel+Active.swift`).
  - `activeIDs` is not observed. `activeRevision` is observed and moves only when the set changes.
  - `updateActive` is one O(1) check per live frame. It runs from `setLive`, from `setOpenRequests` (on the diff) and from `select` (`moveActiveHold`).
  - A held selection is released when its run ends.
- **Layout.**
  - `activityLayout()` returns the Active rows, then the day sections without them, and no Active section while searching.
  - Navigation and reveal use the same layout.
  - Paging starts from the last row drawn.
  - The evidence snapshot gains `catalog.activeSessionIDs`.
- **Measured** (render probe, 30 hosted cards):

  | Event | Moved card | Other cards | Regroups |
  | --- | --- | --- | --- |
  | Flip into or out of Active | 1 evaluation | 0 | 1 |
  | Frame with no flip | its own card only | 0 | 0 |

- **Known edges.**
  - Active draws loaded rows only. The page holds 100.
  - `SidebarAccessibilityTests`, which reads day headings through a window, has not run. It will run with the full suite.

## Slice C as built

**Core** (a6cd400):
- `SubagentRecord.transcriptPath` is the sibling `.jsonl` of the meta file. It is set when the meta is read.
- `SubagentTranscriptLocation` checks:
  - the id;
  - one of the two path shapes;
  - after `realpath`, a path inside the profile's `projects` folder;
  - when opening: read-only, `O_NOFOLLOW`, a regular file owned by this user.
- `SubagentTranscriptParser` decodes a narrow wire type behind a `memmem` gate for attachments. It clips strings at 4 KiB.
- `SubagentTranscriptTail` reads only new whole lines:
  - lines over 128 KiB are skipped;
  - a shrink or an inode change resets it;
  - a cold open reads the last 512 KiB from a line start, plus the first line, the brief.
- `SubagentTranscriptFeed` runs one vnode source and a one-shot 200 ms coalescing read on a utility queue. Batches arrive through an `AsyncStream`. `stop()` is synchronous and idempotent, and closes both descriptors.
- The fake provider gained `/subagent <ms>`. It writes in the isolated profile only.

**UI** (1d4b7de):
- `CatalogModel.viewedSubagent` and `SubagentTranscriptModel`:
  - The model holds a ring of 400 entries.
  - The feed runs only while the panel is on screen and the window is visible.
  - Each batch is one update.
- Any `select()` closes the panel. So do the record leaving the live list and the run ending.
- `DetailContent` swaps `TerminalHost` for the transcript. The header shows "session › agent type · description", Running or Finished, and Session with Esc.
- A row's tap is `.openSubagent`.
- Evidence gained `open-subagent:<sessionID>:<agentID>`, `close-subagent` and the snapshot field `subagentPanel`.

**Decisions made in the slice:**
- There is no Failed state, because Claude reports no subagent failure.
- The projects root is checked in the controller against the runtime's real profile.
- A batch carries at most 1,000 entries.
- A tool with no known main argument shows its alphabetically first short string field.

**Measured** (debug build):
- Parsing takes about 15 µs a line.
- A cold open of a 5.9 MB file read 540,673 bytes and delivered 230 lines.

**Planner review:**
- Nothing runs while the file is idle.
- `stop()` waits only for the cancel handlers, and runs on the main actor, never on the feed's queue.
- `deinit` cannot overlap a queue block, because every block holds the feed strongly while it runs.

**Unverified:**
- Everything on screen: scroll-follow, the header, Esc with real focus, selection across lazy rows.
- A real Claude subagent.

## Optimizer review (13 Oct)

**Scope:**
- the round's diff (`5a2deca..HEAD`) in depth;
- the release app's steady state.

It was read-only: nothing was built or measured. The planner verified R1 and U1 in the code.

| # | Finding | Priority | State |
| --- | --- | --- | --- |
| R1 | Clicking the subagent that is already open replaced its panel model while the view stayed, because it was keyed by the agent id. The new model never went on screen and the panel read nothing until Esc | blocking | fixed in 81ae519: the click is a no-op and the view is keyed by its model. The hosted test failed at both points without the fix |
| U1 | Every activation of the Loom window rescans every transcript and rebuilds the 7-day report, including when nothing changed and the last refresh is over 10 s old. While the window is not active, the watcher's changed paths are dropped and only `stale` is set (`UsageModel.refresh(.activation)`, `transcriptsChanged`, `scheduleDebounced`). This predates the round and contradicts ARCHITECTURE §usage and HARDENING-1's candidate 1 | should fix | done in 27dd23c (D-55). Plan as built: keep collecting changed paths and the full-scan flag while hidden. On activation, read only those, or nothing. Do a full scan only for a watcher overflow, a new day, launch, Settings, the refresh button, or no watcher |
| I1 | `SubagentTranscriptFeed.stop()` waits on the main actor for an in-flight read (up to the 512 KiB cold window) and for the cancel handlers, at utility QoS | improvement | done in 4390445 (D-55): the feed stops asynchronously like `ClaudeRegistryWatch.stop()`, keeping a waiting form for the descriptor tests |
| I2 | Quit captures every run's last screen right after dropping the store | improvement | not taken. It costs a few ms once per quit. Skipping it would lose the last screens after a quit that fails |
| I3 | Per-frame main-actor scans grow with the sessions touched since launch: `updateAttentionCount`, project headers | watch | no change. Frames come from hooks, not terminal output |
| UA | In classic mode, a run that once showed an alternate-screen program (an editor) and later ends on its own keeps that old screen | unverified risk | recorded. The user runs fullscreen, and the capture at Stop is unaffected. A fix needs a rule that tells the resume hint after `?1049l` apart from a live main screen |

**Structure:** no findings beyond R1's cause and I1. The transcript tail and feed differ from the usage index's reader and the registry watch on purpose.

**Docs:** stale lines in docs/ARCHITECTURE.md:
- `EndedScreenPolicy`;
- "up to 8 kept ended screens";
- `CatalogModel.swift`'s line count.

**As built:**
- **U1.** While the watcher runs and the launch scan is done, hidden changes are collected rather than marked stale. A hidden finished turn needs nothing. On coming back:
  - a pending overflow, `stale` or a new local day gives one full scan;
  - otherwise only the changed files are read, inside the cooldown too;
  - otherwise nothing is read.

  With no watcher, the old behavior holds.

  Nine `UsageFreshnessTests` were added. Seven failed on the old source with 9 issues (`check-20261013T231812-58033.log`). The other two guard behavior that did not change: the page filling when it opens, and no-watcher mode. UsageFreshnessTests and UsageModelTests pass, 50 tests (`check-20261013T231754-57575.log`).
- **I1.** `stop()` is `queue.async { teardown() }`, and tests use `stopAndWait()`. The model's consumer also checks its feed generation, so a batch that was buffered before the teardown cannot reach a closed or replaced panel. SubagentTranscriptTests 27 and SubagentPanelTests 13 pass (`check-20261013T231913-58532.log`).
- **Left as is.**
  - A Usage page that opens after a chip-only read still runs a full scan, as before; a report-only rebuild would be a separate small change.
  - A new day gives a full scan, though the chip's summary alone would do.

**Measurements**, when the user says the computer is idle:
- U1's rescan cost on synthetic profiles of 1k, 5k and 20k transcripts, before and after the change;
- a signpost around `stopFeed()` during a cold read.

## Verification

| Check | Result |
| --- | --- |
| Slice A targeted suites | Passed (implementer, 13 Oct). Commit 1: SessionLifecycleTests, SessionCatalogV3Tests, SessionCatalogTests, ConversationControllerTests and two header tests, 43 tests (`check-20261013T212945-28402.log`). New tests failed on the old source (`check-20261013T213104-29168.log`). Commit 2: LoomTerminalTests, ConversationControllerTests, SessionNavigationRuleTests, EndedScreenViewTests, DeletionModelTests, ConversationTabsTests and CatalogModelTests, 56 + 115 tests (`check-20261013T214555-35239.log`). Guards passed. |
| Slice B targeted suites | Passed (implementer, 13 Oct): ActivePhaseTests and SessionEventHubTests (14), CatalogHotPathTests (25), SidebarRenderTests with CatalogHotPathTests (30), and the navigation, model, preferences, menu bar, open request and status suites (66 + 14). Logs: `check-20261013T215813-37695.log`, `-215847-38096.log`, `-215935-38903.log`, `-220005-39329.log`. Planner fix: ActivePhaseTests and SessionEventHubTests 15 passed (`check-20261013T220136-39799.log`); the new test failed without the fix (`check-20261013T220153-40291.log`). |
| Slice C targeted suites | Passed (implementer, 13 Oct). SubagentTranscriptTests, SubagentPanelTests, SubagentTests, SubagentTreeTests and the end-to-end controller test: 48 + 22 (`check-20261013T222513-48342.log`). CatalogModelTests, CatalogHotPathTests, SessionHeaderTests, ConversationTabsTests, SessionNavigationModelTests, SidebarRenderTests and SidebarStatusTests: 102 (`check-20261013T222417-47940.log`). With the two panel rules removed, SubagentPanelTests failed with 6 issues. |
| Full suite on the combined result | Run 1 at 3506a5a..6da3aed (`check-20261013T222646-48936.log`): the release build and the staged release tree passed. `swift test -c release` failed 1 of the 622 LoomCoreTests: `aBurstOfWritesIsCoalescedIntoFewReads`. Under load, its 20 writes spaced 10 ms apart took 3.3 s, so the feed rightly read them in 10 batches, one per 200 ms window, against a fixed bound of 4. The test is now bounded by the windows the writes spanned (9ade38d); SubagentTranscriptTests 26 passed (`check-20261013T223350-51854.log`). Run 2 on 3d4822f passed (`check-20261013T223520-52519.log`): the release build and the staged release tree, with no evidence code. `swift test -c release` covered every target and included the window tests: 58 tests (one known issue), 8, 622 and 446. |
| On-screen pass | — |
