# Feedback round 4 on 0.4.2 (13 Oct 2026)

This file records the user's notes of 13 Oct on 0.4.2, the causes found, the choices and the plan. [FEEDBACK-3](FEEDBACK-3.md) was round 3.

The one design choice, where the subagent panel opens, was made on [design/feedback-4-preview.html](../design/feedback-4-preview.html) and recorded as [D-54](../DECISIONS.md).

The user asked for three things in this order:
1. The build.
2. Then the full suite ("sonrasında full suite testi koşabilirsin").
3. Later, an optimization run, when they ask. Code structure and resource use stay optimal throughout, especially for the release app.

The round shipped as 0.4.3 on 13 Oct ([D-41](../DECISIONS.md) numbering; [record](#release-043-13-oct)).

## Resume here

- **State.**
  - Slice A, the Stop flow, is done and reviewed: commits 543d0d0 (FB4-1, FB4-4, FB4-6) and 95bffc9 (FB4-3). See [Slice A as built](#slice-a-as-built).
  - Slice B, the Active section (FB4-2), is done and reviewed: da77473, plus the planner's fix 71d4093. See [Slice B as built](#slice-b-as-built).
  - Slice C, the subagent panel (FB4-5), is done and reviewed: a6cd400 and 1d4b7de. See [Slice C as built](#slice-c-as-built).
  - Full suite: run 3, on the round with the optimizer fixes (75852f6), passes. Run 2 had passed before the fixes; run 1 had failed one timing test, fixed in 9ade38d. Run 4, on the ended-screen fix, passed all but one Codex-only test, a teardown race outside the release ([verification](#verification)).
  - The optimizer review is done ([findings](#optimizer-review-13-oct)). The user asked for it on 13 Oct ("optimizer'ı max effort spawnlarsın"). It ran as `strict-reviewer` with the optimizer Brief on Opus 5.5 at max effort ([D-06](../DECISIONS.md) requires at least `xhigh`), and read only. Its one blocking finding, R1, is fixed in 81ae519. The user chose to apply U1 and I1 too ([D-55](../DECISIONS.md)): done in 27dd23c and 4390445. The full suite passes on the result ([verification](#verification)).
  - The on-screen pass is done. The user said the computer was idle and gave the go for 0.4.3 if it was positive (13 Oct: "pc boşta yapabilirsin istediğin testi. olumlu olursa 0.4.3'ü kurabilirsin"). Its first run found that the ended screen lost the first character of every row; that is fixed in 4d99e97. The second run passes 20 of 20 checks ([on-screen pass](#on-screen-pass-13-oct)).
  - **Release 0.4.3 is installed** (13 Oct) and is the daily app ([record](#release-043-13-oct)).
- **Open from this round:**
  - Seen in daily use with real Claude: a stopped fullscreen session's last screen, and the subagent panel during a real workflow.
  - Hover, pressed and focus states; Increase Contrast.
  - The optimizer review's open measurements: U1's rescan cost and a `stopFeed` signpost.
  - From the [optimizer review](#optimizer-review-13-oct): I3 (watch) and UA (classic mode keeps an old alternate screen; unverified risk).
  - `SessionLifecycleController.markActivity` has had no caller since FB4-1.
  - The evidence `answer:` command answers only the selected session; the round-4 driver did not select the session first.
- **Storage cleanup** (14 Oct, at the user's request): about 22 GB went to the Trash ([record](#storage-cleanup-14-oct)). The user empties the Trash.
- **Test leftovers** (14 Oct, at the user's request): tests no longer leave temporary folders or LaunchServices records behind ([record](#test-leftovers-14-oct)). Its Quit change ships in 0.4.4.
- **Public on GitHub** (14 Oct, [D-56](../DECISIONS.md)): 0.4.4 is promoted and pushed to [gencberke/loom](https://github.com/gencberke/loom) with the new README, pictures and MIT license ([record](#release-044-and-github-14-oct)). Still to do, when the user says the Mac is idle: build and install 0.4.4, then create the GitHub release with the zipped app. Until then the daily app is 0.4.3.
- **Still open from round 3** ([Resume here](FEEDBACK-3.md#resume-here)):
  - The header's hover, ⋯ menu and focus ring in daily use.
  - The subagent rows during a real workflow.
  - The Settings → General cards' secondary text at 4.0:1.
- **Still open from hardening round 1** ([Resume here](HARDENING-1.md#resume-here)):
  - Screen Time.
  - About one point of visible-stream CPU.

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
  - `EndedScreenView` is a read-only, selectable `NSTextView` that redraws only for a new capture, font size or backing scale.
  - Each character is one terminal cell wide (the advance snapped to the pixel grid, as the engine draws it), and the screen opens at its last row and first column. Both came from the on-screen pass (4d99e97).
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

## On-screen pass (13 Oct)

- **Setup.**
  - Package `Loom-Dev/packages/fb4-candidate`: build 107, `LoomRevision` 4d99e97.
  - Fake providers, through a wrapper that sets `LOOM_FAKE_ALT_SCREEN=1`, so sessions draw in the alternate screen like the user's fullscreen Claude.
  - A fresh data root, launched through LaunchServices. The window stayed on screen; the user said the computer was idle.
  - The scratch driver is `~/Library/Caches/loom-fb4/onscreen/fb4.py`. Runs: `run-232939` (first) and `run-234102` (after the fix), each with snapshots and screenshots in `evidence/`.
- **Found: the ended screen lost every row's first character.**
  - Cause: the engine snaps the cell width to the pixel grid (`computeFontDimensions`: 8.5 pt at 14 pt on a 2x screen). The text view laid the same characters out at the font's own advance: 8.654 pt for the system monospaced font, which stands in because `SFMono-Regular` is not installed. So a full row came out wider than the area, and `scrollToEndOfDocument` scrolled sideways to the end of the last row.
  - The capture was right: it held the full rows.
  - Fix 4d99e97:
    - Each character carries the kern that makes it one snapped cell wide, at the window's backing scale, and is laid out again when the scale changes.
    - Once the area has a size, the screen opens at its last row and first column.
  - The new test `aFullRowIsAsWideAsTheTerminalAndTheScreenOpensAtItsFirstColumn` failed without the fix on both counts.
- **Script fixes between the runs.**
  - The first run switched to the activity view before adding the projects. Adding a project shows the projects view, so its Active screenshots were in the project view and its activity-row checks compared empty lists. The second run switches after adding and checks the view mode before each part.
  - The first run read the closed panel's evidence `{viewed: null}` as open. Esc had closed the panel.
- **Second run: 20 of 20 checks pass.** Quit was clean.
  - **FB4-2, Active.**
    - A working session is in Active. Finished and unread, it stays there with the blue dot.
    - Selected and read, it is held. After the user moves on, it leaves, and its work has put it at the top of Today.
    - A session that needs approval is in Active, with the orange dot.
  - **FB4-5, panel.**
    - The fake subagent's transcript opens in place of the terminal (P1) and feeds while on screen.
    - Breadcrumb "Release notes draft › implementer · map the fake module", the Running pill, and the brief and entries.
    - Then "Finished 12s" with the tool rows and the error row in red.
    - Esc returns to the terminal.
  - **FB4-1, FB4-3, FB4-4, Stop and Resume.**
    - Stop closes the session's tab and shows the neighbour.
    - The card keeps its place through Stop and Resume; the activity rows held all three sessions.
    - No live terminal stays, and one ended screen is kept.
    - The ended screen shows full rows from the first column.
    - A resumed session is not in Active before a prompt.
  - **FB4-6, header.**
    - At 1220 pt the header shows `stable/conflict/bg/EDDP-19964` in full.
    - At 780 × 500 the title shortens and the branch drops, in the same order as before.
- **Notes.**
  - In evidence screenshots (`cacheDisplay`), a live terminal draws white with faint text. Round 3's and hardening round 1's evidence show the same, so this comes from the capture path, not the app.
  - The script's `answer:` step did nothing: the command answers only the selected session. The approval stayed open until Stop. This is outside this round.
- **Not seen:** hover and pressed states, a real Claude session's last screen, and a real workflow's subagent panel.

## Verification

| Check | Result |
| --- | --- |
| Slice A targeted suites | Passed (implementer, 13 Oct). Commit 1: SessionLifecycleTests, SessionCatalogV3Tests, SessionCatalogTests, ConversationControllerTests and two header tests, 43 tests (`check-20261013T212945-28402.log`). New tests failed on the old source (`check-20261013T213104-29168.log`). Commit 2: LoomTerminalTests, ConversationControllerTests, SessionNavigationRuleTests, EndedScreenViewTests, DeletionModelTests, ConversationTabsTests and CatalogModelTests, 56 + 115 tests (`check-20261013T214555-35239.log`). Guards passed. |
| Slice B targeted suites | Passed (implementer, 13 Oct): ActivePhaseTests and SessionEventHubTests (14), CatalogHotPathTests (25), SidebarRenderTests with CatalogHotPathTests (30), and the navigation, model, preferences, menu bar, open request and status suites (66 + 14). Logs: `check-20261013T215813-37695.log`, `-215847-38096.log`, `-215935-38903.log`, `-220005-39329.log`. Planner fix: ActivePhaseTests and SessionEventHubTests 15 passed (`check-20261013T220136-39799.log`); the new test failed without the fix (`check-20261013T220153-40291.log`). |
| Slice C targeted suites | Passed (implementer, 13 Oct). SubagentTranscriptTests, SubagentPanelTests, SubagentTests, SubagentTreeTests and the end-to-end controller test: 48 + 22 (`check-20261013T222513-48342.log`). CatalogModelTests, CatalogHotPathTests, SessionHeaderTests, ConversationTabsTests, SessionNavigationModelTests, SidebarRenderTests and SidebarStatusTests: 102 (`check-20261013T222417-47940.log`). With the two panel rules removed, SubagentPanelTests failed with 6 issues. |
| Full suite on the combined result | Run 1 at 3506a5a..6da3aed (`check-20261013T222646-48936.log`): the release build and the staged release tree passed. `swift test -c release` failed 1 of the 622 LoomCoreTests: `aBurstOfWritesIsCoalescedIntoFewReads`. Under load, its 20 writes spaced 10 ms apart took 3.3 s, so the feed rightly read them in 10 batches, one per 200 ms window, against a fixed bound of 4. The test is now bounded by the windows the writes spanned (9ade38d); SubagentTranscriptTests 26 passed (`check-20261013T223350-51854.log`). Run 2 on 3d4822f passed (`check-20261013T223520-52519.log`): the release build and the staged release tree, with no evidence code. `swift test -c release` covered every target and included the window tests: 58 tests (one known issue), 8, 622 and 446. |
| Full suite after the optimizer fixes | Run 3 on 75852f6 passed (`check-20261013T232017-59123.log`): the release build, the staged release tree (no evidence code), and `swift test -c release` on every target with the window tests: 58 (one known issue), 8, 623 and 457 tests |
| On-screen pass | Run 1, `run-232939`, on a package from before the fix (the product code of 75852f6): found the ended screen's first-column loss. Run 2, `run-234102`, on build 107 (4d99e97): 20 of 20 checks pass ([on-screen pass](#on-screen-pass-13-oct)) |
| Full suite on the fixed round | Run 4 on 4d99e97 (`check-20261013T234450-65522.log`). The release build and the staged release tree passed, with no evidence code. `swift test -c release` with the window tests: LoomTerminal 58 (one known issue) and 8, and LoomCatalogUI 458, all passed. LoomCore passed 622 of 623. `eachCodexConversationHasItsOwnServerAndStopClosesOnlyIt` failed once at line 1108, on a Codex-only teardown race; Codex is paused and not in the release, and the race is in the [Codex backlog](cp5/CODEX-BACKLOG.md). LoomCore had not changed since run 3's pass. Two release-config re-runs of LoomCoreTests passed 623 of 623 (`~/Library/Caches/loom-check-logs/fb4-codex-flake.out`); further Codex re-runs were stopped as not needed for this release |
| Ended-screen fix (4d99e97) | EndedScreenViewTests: 6 passed (`check-20261013T233755-63331.log`). The new test failed without the fix, on the row width and on the first column (`check-20261013T233809-63749.log`). EndedScreenViewTests, TerminalScreenSnapshotTests and ConversationControllerTests: 15 + 50 passed (`check-20261013T233833-64194.log`) |

## Release 0.4.3 (13 Oct)

0.4.3 adds feedback round 4 to 0.4.2:
- the Stop flow and the last screen;
- the Active section;
- the subagent panel;
- the longer branch;
- the optimizer fixes R1, U1 and I1;
- the ended-screen fix from the on-screen pass.

The user gave the go on 13 Oct, if the tests were positive ("pc boşta yapabilirsin istediğin testi. olumlu olursa 0.4.3'ü kurabilirsin").

- **Full suite.** Run 4 on 4d99e97 ([verification](#verification)). Everything passed except one Codex-only test, a teardown race outside the release. LoomCore was unchanged since run 3's full pass.
- **Package and on-screen pass.** Build 107 (4d99e97): 20 of 20 checks ([on-screen pass](#on-screen-pass-13-oct)).
- **Not run:**
  - A real Claude session: the last screen of a real fullscreen session, and a real workflow's subagent panel.
  - Hover, pressed and focus states.
  - Increase Contrast.
  - The measurements the optimizer review left open: U1's rescan cost and a `stopFeed` signpost.
- **Tag, promote, install.** Tag `release/0.4.3` → loom-dev 4bdda54; loom 5921991 / `v0.4.3` (281 files). The release products were built ahead in the loom tree. Loom was not running, and `build.sh` built and swapped `/Applications/Loom.app` at 23:56. Checked:
  - Deep-strict signature; version 0.4.3, `CFBundleVersion` 11, `LoomRevision` 5921991, the category.
  - LaunchServices holds one record, version 11.0.
  - The binary holds the round's types (`EndedScreenStore`, `EndedScreenContainerView`, `SubagentTranscriptFeed`, `SubagentTranscriptModel`, `ActivePhase`) and the ended-screen notice, and no evidence code.
  - The install did not touch the user's data: the catalog was last written at 21:08:30 and the UI preferences at 17:54:22, both before the install.

## Storage cleanup (14 Oct)

The user asked to move whatever the dev and prod builds had left behind without use to the Trash (14 Oct: "hem dev hem prod kurulumlarında gereksiz herhangi bir aşamada gereksiz dosyalar oluştuysa bunları ayıkla ve çöp kutusuna taşı"). Everything went through `/usr/bin/trash`; nothing was deleted for good. The user chose the second group from a list.

- **Moved, clearly unused** (about 17.6 GB):
  - `loom-dev/.build`, 11 GB: repo-local builds and scratch folders from 27 Sep to 6 Oct, before scratch paths moved out of `~/Documents`. Nothing in it was newer than 7 Oct.
  - The hardening round's agent scratch, `loom-h1/scratch-*`, about 6.5 GB.
  - Five test packages in `Loom-Dev/packages`, 114 MB: the 0.4.0 to 0.4.3 candidates and `ref-033`. Each can be rebuilt from its tag.
  - The session's temp files, and three older test folders in `/private/tmp`.
- **Moved, at the user's choice** (about 4.5 GB):
  - The 40 old worktrees of run 1 and hardening round 1, about 0.5 GB. Every HEAD was in `swarm/1`. 37 held uncommitted leftovers of their agents. `git worktree prune` dropped their records; the branches stay.
  - `Loom-Dev/probe/runs`, 746 MB: 264 run folders from 27 Sep to 12 Oct. Their results are in the plans. The `runs` folder stays for new evidence.
  - The build caches `loom-dev-build`, `loom-dev-build-release-tree`, `loom-dev-build-release-stage` and `loom-release-build`, about 3.2 GB. The next check and the next release build from scratch.
- **Test leftovers.**
  - 791 Loom test folders and SwiftPM lock files in `$TMPDIR`, 42 MB.
  - 1,568 LaunchServices records of Loom copies that no longer exist, mostly the tests' temporary `LoomRunHost.app`. Only the installed `Loom.app`, `Loom Dev.app` and their helpers stay registered, so "Loom Dev" cannot open an old copy.
- **Kept:**
  - The installed apps, the user's data and the default dev catalog with its documented backup.
  - The isolated profiles: `probe/claude-config` and `~/.loom-dev/codex-home`, 392 MB, the user's choice.
  - Small evidence and notes: `loom-run1` without its worktrees (142 MB of run-1 evidence, the run's notes and scripts, the 0.2.0 candidate and the build-slot lock), `loom-fb3`, `loom-fb4`, `loom-h1/onscreen`, `loom-check-logs` and `probe/evidence`.
  - Other sessions' files in `/private/tmp`.
- **Afterwards.**
  - References in older plans to the moved paths are historical.
  - Tests left temporary folders and LaunchServices records behind on every run; fixed the same day ([test leftovers](#test-leftovers-14-oct)).

## Test leftovers (14 Oct)

The user asked for the follow-up the storage cleanup had found: "Stop tests leaking temp folders and LaunchServices records". A counter outside the repo (`~/Library/Caches/loom-leaks/snap.sh`) listed the test folders in `$TMPDIR` and `/tmp` and the LaunchServices records of Loom bundles before and after one `scripts/check.sh --tests` run.

- **Before.** One run left 21 folders in `$TMPDIR`: 13 `loom-scope-*`, 5 `loom-cp4c-*`, and one each of `loom-scope-silent-*`, `loom-scope-foreign-*` and `loom-scope-fixtures`. It also left 22 LaunchServices records of `LoomRunHost.app` copies inside temporary folders.
- **Causes.**
  - Launching a run host through `open` registers its bundle with LaunchServices, and the record outlives the folder. The tests that assemble a host removed the folder at most, never the record.
  - `RunScopeTests` never removed its folders: a shared fixture folder and one per launcher.
  - A catalog backup still being copied when a test's runtime shut down wrote `backups/` and the journal into the test's data root after the test had removed it (the `loom-cp4c-*` folders of `ConversationDeletionTests`). In the app, Quit could end the process while such a copy was being written.
- **Fixes.**
  - 9c6cfb2: `RunScopeLauncher.removeOwnedBundle(in:)` unregisters the host from LaunchServices and removes its folder. `RunScopeTests` (a per-test scratch that cleans up when the test ends), `SessionRuntimeTests`, `AppShutdownCoordinatorTests` and `ConversationControllerTests` use it.
  - a5174f5: `SessionRuntime.shutdown` cancels a backup still waiting for its turn and waits for one being copied, and no backup starts once shutdown has begun; the next launch's daily backup covers a deletion that ends during Quit. The new test `quitWaitsForTheBackupBeingCopiedAndStartsNoOther` failed without the fix (`check-20261014T002648-83603.log`).
  - 0e268e0: the first full run after 9c6cfb2 failed one test, `aPlainStopLetsNothingMoreThroughAndClosesTheFilesSoon` (`check-20261014T001604-78261.log`). It checked that the stopped feed's descriptor numbers were closed, but under parallel tests another test gets the same number at once (POSIX hands out the lowest free one). Both stop tests now check that no open descriptor refers to the transcript file (device and inode). SubagentTranscriptTests: 27 passed (`check-20261014T002734-84121.log`).
- **After.** `scripts/check.sh --tests` on 0e268e0 passed, window tests skipped: LoomCore 624, LoomCatalogUI 456, LoomTerminal 56 (one known issue) and 8 (`check-20261014T002806-84703.log`). The counts before and after the run are identical, so nothing was left behind. LaunchServices holds only the installed `Loom.app`, `Loom Dev.app` and their run hosts.
- **Not in the daily app.** These commits come after 0.4.3. a5174f5 changes the product's Quit, so it ships with the next release.
- [DEVELOPMENT.md §2](../DEVELOPMENT.md#2-build-and-test) now states the rule: tests remove what they create, a run host through `removeOwnedBundle(in:)`.

## Release 0.4.4 and GitHub (14 Oct)

The user wants the clean loom tree on GitHub with release packages and a simple, playful README that shows the design previews (14 Oct: "prod projeyi github'a yüklemeyi düşünüyorum. release package fln ayarlarız clean durur. güzel bi readme koy …"). They had created the public repository `gencberke/loom` and chose, when asked: MIT; releases with the signed app as a zip; a public history that starts at 0.4.4; the push without a further review once the checks pass ([D-56](../DECISIONS.md)).

- **Privacy pass before publishing.** The design previews carry sample data from the user's real work: project names, a ticket number, branch names and Turkish session titles. The README pictures therefore come from four new pages in `design/readme/`, cut from the chosen designs (the whole window of look C with the D-53 header, the menu bar menu with the approval banner, the subagent panel P1, Settings → Usage U1 without the development-only Sessions section) with neutral names. Two code comments named a real project and a work branch; both now use neutral examples. The loom tree's older commits carried the user's gmail address and one of those comments, so they stay local (D-56). The signing certificate embeds no email (`CN=Loom Dev Code Signing` only), and the product has no network code to disclose.
- **Release scripts** (6867297): `promote.sh` fills `scripts/release/README.release.md` and copies `scripts/release/LICENSE`; it fails on a leftover placeholder or on a README picture the release lacks. The allowlist adds `assets/readme` (not bundled into the app). `build.sh` takes `CFBundleVersion` from `VERSION` (0.4.4 is 404), because a fresh history would have dropped the commit count from 11 to 1. `scripts/release/readme-shots.sh` renders the pictures with headless Chrome. Checks: `scripts/check.sh` passed (`check-20261014T111101-2885.log`). A promote into a scratch folder exported 288 files with the filled README, the pictures and LICENSE, and no real project names; `build.sh --check-only` there printed build 404.
- **Product change since 0.4.3:** a5174f5, Quit waits for a catalog backup being copied and starts no new one ([test leftovers](#test-leftovers-14-oct)). Its tests ran in the 14 Oct `--tests` run; the full release suite did not run for this patch.
- **Promote and publish.** Tag `release/0.4.4` → loom-dev 6867297; promoted into the loom tree as a93aff4. The public `main` is one root commit with the same tree, fe92020, authored with the GitHub noreply address, which the loom tree's git config now uses; `v0.4.4` points to it. The earlier promote commits and tags `v0.1.0` to `v0.4.3` stay local on the branch `history`. Pushed only `main` and `v0.4.4`; the remote holds exactly those. The repository has a description and the topics macos, swift, swiftui, appkit, claude-code and terminal. On github.com the README renders with all six pictures loaded, and GitHub recognizes the MIT license.
- **Not done yet:** the 0.4.4 build and install (heavy; waits for the user's word that the Mac is idle) and the GitHub release with `Loom-0.4.4.zip`. Unverified: whether the downloaded zip opens on another Mac after the quarantine flag is cleared, as the README says.
