# Hardening round 1 after 0.3.3 (12 Oct 2026)

Goal: stability and daily-use polish from the 12 Oct review ([D-45](../DECISIONS.md)), project colours ([D-48](../DECISIONS.md)) and Loom as a first-class app on the user's Mac ([D-47](../DECISIONS.md)). The review was three read-only passes (core robustness, UI layer, project-colour touch points); the planner checked the decisive findings in the source. Their file:line evidence is restated in the slice Briefs below, so this file keeps only the outcome.

## Resume here

State when the user shut the Mac down on 12 Oct (evening):

- **Committed on `swarm/1`.**
  - `2bbebf3` A and B.
  - `37b155f` C.
  - The next commit: E and D1 with the records.
- **Waiting in worktree `~/Library/Caches/loom-h1/wt/D2`: H1-D2**, done by its implementer and checked there, not reviewed by the planner yet.
  - Review it: `git -C <wt/D2> add -A && git -C <wt/D2> diff --cached 73dac855ac5620b6defb25785be963c910d3e9a2`.
  - Its report covers:
    - Patching one row for run, lifecycle, identity and activity frames.
    - One windowed search query, capped per group plus 5,000 rows overall.
    - A per-row selected flag, `CardTimeLabel` for the minute tick, cached tooltips and memoised day sections.
    - New `SidebarRenderProbe` and `afterSearchRead` test seams.
    - Counts: run frame 5 → 1 queries; search 7 → 1; selection 30 → 2 card bodies; minute tick 30 → 0.
  - Then apply the diff to `swarm/1`, run `scripts/check.sh --tests` and commit (the user's answer "okeyim", 12 Oct, to committing each reviewed slice of this round, no push).
- **Next after D2: H1-F**, on the user's go only. It covers the menu bar per D-52, notifications, Open at login, Screen Time fixes (category, numeric build numbers) and the open Screen Time question.
- **Old worktrees** `loom-h1/wt/A`, `B`, `C`, `E`, `D1` are merged and can be removed with the user's OK.
- **On the user's word only:** the full release suite and the on-screen checks listed in the slice notes.

## Slices

| Slice | Content | Write area | State |
| --- | --- | --- | --- |
| H1-A Daily use | Ended run keeps its last screen (read-only); Quit asks while sessions work or wait for approval; Quit Anyway, never blocking a system logout or restart; jump to the next or previous session that needs the user (Cmd+J, Shift+Cmd+J); next or previous session (Option+Cmd+Down/Up); the sidebar follows the selection; Reveal in Finder, Copy Claude Session ID, Copy Resume Command; Dock badge; bugs: a transient catalog error unpins a tab, the bottom spinner can stay stuck | `LoomCatalogUI`, `loom-app`, `LoomTerminal`, UI-MAP | implemented and reviewed; applied to `swarm/1` uncommitted; combined checks passed (`scripts/check.sh --tests`, log `check-20261012T161645-8295.log`: LoomCoreTests 568, LoomCatalogUITests 311, LoomTerminalTests 42, LoomLaunchOptionsTests 8; the staged release tree built in `check-20261012T160621-4764.log`); waiting for the evening's on-screen check |
| H1-B Core hardening | `os.Logger` categories with privacy and rate limits; a bounded diagnostic journal; registry tolerance; capabilities no longer refuse a start; toolchain re-resolved when the executable changes; hook watchdog; runtime catalog write failures; crash residue (open runs, stale sockets, unreadable run folders); catalog backup with restore and start-fresh; diagnostics bundle API; usage and plan-limit failure fields; non-sticky clock ambiguity | `LoomCore`, `CLoomPOSIX`, `loom-hook`, ARCHITECTURE, DEVELOPMENT | implemented and reviewed; applied to `swarm/1` uncommitted; combined checks passed (see H1-A) |
| H1-C Wiring | UI for H1-B: <ul><li>Help menu and Settings → About: Collect Diagnostics… (reveals the export)</li><li>Catalog restore prompt at launch (Restore Backup / Start Fresh)</li><li>"Plan limits unavailable" and not-understood usage lines on the Usage page</li><li>The watchdog issue visible above a live terminal</li><li>`toolchainInvalidator` wired in AppDelegate</li><li>The export's `log show` limited to this app's processes, so test and dev runs that share the subsystem stay out</li><li>A permanent deletion also removes `catalog.damaged-*`</li></ul> | `LoomCatalogUI`, `loom-app`, small `LoomCore` | implemented and reviewed; applied to `swarm/1` uncommitted. The implementer's `--tests` passed on the same code in worktree C (log `check-20261012T163441-15572.log`: LoomCoreTests 572, the other targets 324); after the planner's two changes the touched suites passed (log `check-20261012T163917-18365.log`, 36 tests) |
| H1-D1 Performance, part 1 | Candidates 1 (usage after a finished turn) and 5 (terminal reconcile), [D-51](../DECISIONS.md) | `UsageModel`, `UsageTranscriptWatcher`, `ConversationController` | done and committed with H1-E; combined checks passed (see H1-E) |
| H1-D2 Performance, part 2 | Candidates 2 (list patches), 3 (one search query) and 4 (card invalidation) | `LoomCatalogUI` lists and cards, `SessionCatalog+Paging` | implemented in worktree `loom-h1/wt/D2` (base tree `73dac85` = E and D1 applied); the implementer's `--tests` passed there (log `check-20261012T172610-53598.log`: 583 and 360 tests). **Not yet reviewed or merged by the planner** (see [Resume here](#resume-here)) |
| H1-E Project colours | Per D-48, look chosen on [the preview](../design/project-colors-preview.html) | `LoomCore` (`projects.color`), `LoomCatalogUI`, DESIGN, UI-MAP | look chosen ([D-50](../DECISIONS.md)): C's stripe in the sidebar, T5's light tint on the tabs (the user approved the drawing, 12 Oct), the stripe and name in the detail header; done and committed with H1-D1 (the planner's contrast change included); combined checks passed (`scripts/check.sh --tests`, log `check-20261012T170029-40693.log`: LoomCoreTests 578, LoomCatalogUITests 344, LoomTerminalTests 42, LoomLaunchOptionsTests 8) |
| H1-F macOS integration | Per D-47 and [D-49](../DECISIONS.md): menu bar item (Loom mark, working chase, status dot, session menu), notifications for Needs approval, Open at Login setting, Screen Time visibility, numeric versions from tags | `loom-app`, `LoomCatalogUI`, `scripts/release` | preview approved ([D-52](../DECISIONS.md)): option A, the mark with a chase badge. Planner decisions: light-bar status values `#B05A00`, `#2A5FD6`, `#C9332E`; the chase keeps moving under Reduce Motion (DESIGN §4); Settings defaults on, on, off. Screen Time waits for the user's answer (does Screen Time list any other app?). Not started: the user said to wait (12 Oct). |

A and B run in parallel in detached worktrees with disjoint write areas; B keeps every API that A uses source-compatible. The planner applies both diffs to `swarm/1` and runs the combined checks.

## Planner decisions (routine, reversible)

- **Ended terminal.** It is kept while its session is selected or pinned as a tab, with at most 8 kept. It is released on deselect (unless pinned), when its tab closes, on resume, delete or quit.
- **Quit confirmation.** It counts only Working and Needs approval sessions. Cancel is the default. A system-initiated quit gets no alert, and when its verified shutdown fails it still lets the logout or restart proceed.
- **Badge and jump set.** Both use `SessionIndicator.needsAttention`, plus the open-request rule CatalogModel already applies. Jump order: failure class, needs approval, waiting for you, finished unviewed; within a class, the newest activity first.
- **Logging.**
  - Unified logging under `local.loom.desktop` carries the stream. The system keeps and purges it, so Loom keeps no log files for it.
  - Notice and error levels are used only for transitions and failures; per-event detail stays at debug. No session content is logged.
  - Loom-owned files: `diagnostics/journal.jsonl` (2 × 512 KB, rare events only) and at most 3 diagnostics exports.
- **Catalog backup.**
  - `VACUUM INTO` at most once per 24 h, keeping 3 backups.
  - After a permanent deletion all backups are removed and a fresh one is taken, so no backup holds a deleted session (contract §8).
- **Hook watchdog.** It uses a definitive signal (the registry shows the run alive while no hook ever arrived), never a plain timer. Claude runs no hooks while its folder-trust question is open.

### H1-A notes from the review

- **Kept screen after Stop.** The user's own Stop on the selected session now also keeps the frozen screen with its notice ("This session is not running.", Resume, Show Details) instead of the record view. Accepted, since it follows the rule; the user confirmed it (12 Oct).
- **Keyboard and menus.**
  - AppKit fires either J menu item for Cmd+J or Shift+Cmd+J, so the action reads Shift itself and a hidden uppercase twin catches Shift+Cmd+J.
  - The same quirk may let Shift+Cmd+N reach "New Claude Session" in development builds. Codex items exist only there, so this is not a production issue.
- **Quit.** If the system quits while the quit question is open, the sheet ends and the user's earlier quit is answered "no" before the system quit proceeds. This is unverified and only reachable if AppKit dispatches the system quit event during the pending terminate.
- **Not run yet.** Visible-window checks: notice look, alerts, Dock badge, scroll, Reveal in Finder, shortcuts with a real Claude terminal and a Turkish layout. (`--release-tree`, for the new `evidenceSkipsQuitQuestion` seam, passed in the combined run.)

### H1-B notes from the review

- **Watchdog.** It fires only when the registry says busy and no hook has reached Loom since the run started, so a long turn without hooks never trips it. "Idle" is not a signal, because of folder-trust questions.
- **Registry cwd.** A changed registry `cwd` no longer makes the read unavailable. Identity comes from pid, process birth, `startedAt` and the session id.
- **Abandoned runs.** They close with the existing `applicationQuit` end reason; a new case would break exhaustive switches in the UI.
- **Planner decision on damaged catalogs.** A permanent deletion also removes `catalog.damaged-*` (contract §8: nothing Loom keeps may hold a deleted session). The restore prompt says a damaged copy is kept until then. Built in H1-C.
- **Planner check of `log show`.** `/usr/bin/log show --last 10m --predicate 'subsystem == "local.loom.desktop"' --style ndjson` works on this Mac, but it also returned `swift test` processes logging under the same subsystem. Hence the H1-C item that limits the export to this app's processes.
- **Unverified.**
  - Real Claude's registry status vocabulary and folder-trust timing.
  - Journal and unified-log cost under real use.

### H1-C notes from the review

- **Planner changes.**
  - The issue notice above a live terminal uses the failure colour, like the record view's notice and the "Problem" state on the card; the implementer had chosen the attention colour.
  - A test now checks that the real usage index answers with its own scan report through `UsageIndexing`, not the protocol's empty default.
- **Implementer's choices, accepted.**
  - When an earlier plan-limits answer exists, it stays and its header adds "· could not refresh".
  - The notice shortens the terminal by one line, so the PTY gets one resize when the issue appears and one when it clears.
  - After Start Fresh, the damaged file stays as `catalog.damaged-*` until the next permanent deletion, as the alert says.
- **Not run yet.**
  - On screen: the damaged-catalog alert (button order, Return), the Help menu, the About row, the issue notice and the Usage lines.
  - A launch with a real damaged catalog, and Quit from that alert early in launch.

### H1-E notes from the review

- **Contrast (planner change).** The drawn strengths broke the theme's text tiers on the washed tabs:
  - Primary text on the open tab measured 6.5–7.4:1 against the 7:1 tier, under it for Lemon, Aqua, Mint and Sage.
  - Plain secondary text on a resting tab measured 3.7–4.0:1 against the 4.5:1 tier, and no wash keeps it there.
  - The fix keeps the look: the open tab's wash is 15 % instead of 18 % (the strongest that keeps 7:1 on every tone), and a washed tab's secondary title and close glyph use `Text.secondaryOnTint` `#9297A8` (at least 4.6:1, and 3:1 for the glyph). D-50 and DESIGN §6 say so.
- **Implementer's choices, accepted.**
  - The Increase Contrast stroke is 75 %.
  - A project set to None still names itself in the tab tooltip, the accessibility label and the header.
  - The tab label adds ", project X" without the provider.
- **Not run yet.** Everything on screen: the stripes as one rail, the tab washes, the header mark, the Color menu's swatches (an `NSImage` in a SwiftUI menu may render as a template), Increase Contrast and the Settings row.

### H1-D1 notes from the review

- **Usage.**
  - While the transcript watcher runs, a finished turn reads only the files the watcher reported. Counter: 200 transcript files, one turn, files examined 200 → 1.
  - Without a watcher (the stream failed, or no `projects` folder at launch), a turn still walks everything. If the folder appears after launch, that lasts until the next launch.
  - A transcript event that arrives after the turn's debounce still moves the numbers. The cost is up to about 1 s of watcher latency plus a 2 s debounce.
- **Terminals.**
  - Each frame is compared with the terminal entries locally. Only an entry whose owner no longer shows its run is asked of the supervisor.
  - Counter: 3 terminals, 16 quiet frames, supervisor calls 48 → 0. Run end and owner move are still handled, and only their run is asked.
  - The planner checked the hub path in the code: a run end publishes `runEnded`, a move publishes `runDetached` then `runStarted`, and both come after the supervisor's change.
- **Load failures seen in the slices' full runs.** None was reproduced alone.
  - In H1-D1: `RunScopeTests` failed with `EAGAIN` on process spawns.
  - In H1-E:
    - `SessionRuntimeCodexRecoveryTests` failed on a different test each run.
    - `OpenSessionTests` hit "Claude hook timed out during read", which also failed twice at 09:33, before this round.
  - The planner checked that B's stale-socket sweep cannot touch other tests: each test runtime has its own socket folder, and the sweep removes only sockets that refuse a connection.

### Combined checks (12 Oct)

The first combined run failed two LoomCore tests that passed in B's own run. Both are load races in the tests, not product faults:

- **`anUnverifiedStopKeepsTheRowAndTheFilesUntilARetryVerifiesIt`** (also failed once on 8 Oct). The event hub's subscription keeps only the newest frame (`bufferingNewest(1)`), so under load a later frame replaced `.deletionIncomplete` before the test's reader saw it. Tests now subscribe unbounded through an internal `SessionEventHub.subscribe(bufferingPolicy:)`; the app's subscription is unchanged.
- **`idleStopClosesInputAtomicallyAndPendingBytesBlockIt`**. `turnComplete` arrives before the Stop hook's helper process exits, and a live helper blocks the idle stop by itself. The test now waits until the leader is alone, as `childExitRearmsAutomaticIdleWithoutAnotherProviderEvent` already did, and names the blockers if it fails.

The rerun passed. One run does not prove the races are gone; the evening's full suite repeats them.

## Performance candidates

These are proposals for H1-D. They are inferred from the code and not measured; each is measured with `CatalogHotPathTests` counters or signposts before and after.

1. **Usage after a finished turn.** Refresh only the changed transcripts: the paths the FSEvents watcher reports and the Stop hook's `transcript_path`. The full tree walk stays only for launch, a stale window coming back, an FSEvents overflow, a day change and the refresh button. Today `UsageModel.refresh(.turnComplete)` sets `wantsFullScan`, and the walk stats every transcript file.
2. **Lists on run and lifecycle frames.**
   - Patch the one changed row instead of reloading every loaded row of every visible list.
   - Project view: patch in place, since creation order never changes.
   - Activity view: move the row to its new position by `last_activity_at`.
   - A full reload stays the fallback for a sequence gap.
3. **Search.** One cancellable query over all sessions, grouped into projects in memory, with a result cap. Today each project list reloads with its own `LIKE` scan on every debounced keystroke, collapsed projects included.
4. **Card invalidation.**
   - A per-row `isSelected`, so a selection change redraws two cards.
   - The relative time in a small subview that alone reads the minute tick.
   - Cached tooltip dates.
   - Day sections memoised per list generation and day.
5. **Terminal reconcile.** Compare the controller's entries against the frame's run ids locally, and ask the supervisor only for a missing or changed run. Today there is one actor hop per live terminal on every frame.

## Facts

- **Claude's copy.** Claude's own copy works inside Loom (user, 12 Oct), so OSC 52 clipboard access stays off.
- **The walk after a finished turn reads no conversations.** It stats every transcript file and looks each one up in the usage index. It reads only the new bytes of files that changed, and spends no model tokens. The cost is disk and CPU time that grows with the number of transcript files (item 1 above).

- **Screen Time** (user, 12 Oct: Loom does not appear there at all). The installed app shows four candidate causes; which one matters is still unknown:
  - `TeamIdentifier=not set`, from the self-signed local identity.
  - No `LSApplicationCategoryType`.
  - `CFBundleVersion` is a git hash (`611bc29`), which LaunchServices reads as 611.0.
  - A second LaunchServices record with the production bundle id `local.loom.desktop`: the run-1 release-candidate package `~/Library/Application Support/Loom-Dev/packages/run1-rc/Loom.app` (version read as 91.0). Removed on 12 Oct with the old packages (housekeeping below); `/Applications/Loom.app` is now the only record for that id.
  - Web research (12 Oct) found no documented signing, Team ID or notarization requirement for Screen Time.
    - A non-App-Store Mac app is reported as recorded but filed under "Others" until it declares `LSApplicationCategoryType`.
    - Apple documents `CFBundleVersion` as one to three period-separated integers.
    - First checks:
      - Whether Screen Time records any app at all, and whether Loom hides under Others or the grey bucket.
      - Then add the category and numeric build numbers.
  - The user could not find an "Others" entry either (12 Oct).

## Checks

- **Each slice.** Targeted `scripts/check.sh --suite` runs in its own worktree and scratch.
- **Planner.** `scripts/check.sh --tests` on the merged tree.
- **On the user's word.** The full release suite (`--full --idle`) and the on-screen checks. Not soon: the user says when (12 Oct), so the planner does not ask.

## Housekeeping (12 Oct)

- **Moved to the Trash** (about 40 GB; it is freed when the user empties the Trash): 59 stale SwiftPM scratch folders.
  - Everything under `~/Library/Caches/loom-run1/scratch-*`, except the three small evidence and tool folders `scratch-CP4-C-evidence`, `scratch-OPT-core` and `scratch-U5-probe`.
  - `loom-dev-build-{codex,p1c,render,sync,ui-b}`, `loom-fb2-impl`, `loom-fb2-planner`, `loom-flake-impl`, `loom-p3s-build`, `loom-r3-build` and `loom-build`.
- **Moved to the Trash, second pass:** the 37 old dev packages under `~/Library/Application Support/Loom-Dev/packages` (525 MB) and the seven older app folders `Loom-Dev/app-*` (about 104 MB; only finished CP5 experiment records name them), each unregistered from LaunchServices first. The empty `packages` folder stays for new packages.
- **Kept:**
  - The installed `Loom-Dev/app/Loom Dev.app` and the default dev catalog.
  - Three `Loom Dev.app` copies registered from the loom repo's `.build` folder (not this repo's to touch) and three inside September evidence runs under `Loom-Dev/probe/runs` (evidence stays).
  - The active scratch folders: `loom-dev-build`, `-release-tree`, `-release-stage` and `loom-release-build`.
  - `loom-check-logs`, the build-slot lock, and the run-1 notes, evidence, patches and `rc`.
  - The 32 run-1 and FB1 worktrees under `loom-run1/wt` (396 MB). Most still hold uncommitted changes, so they are archived and removed only with the user.
