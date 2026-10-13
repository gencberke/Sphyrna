# Hardening round 1 after 0.3.3 (12 Oct 2026)

Goal: stability and daily-use polish from the 12 Oct review ([D-45](../DECISIONS.md)), project colours ([D-48](../DECISIONS.md)) and Loom as a first-class app on the user's Mac ([D-47](../DECISIONS.md)). The review was three read-only passes (core robustness, UI layer, project-colour touch points); the planner checked the decisive findings in the source. Their file:line evidence is restated in the slice Briefs below, so this file keeps only the outcome.

## Resume here

The next round is [feedback round 3](FEEDBACK-3.md) (13 Oct). The open items below stay here.

State on 12 Oct (late evening):

- **Release 0.4.0** ships H1-A to H1-E and the bundle keys (numeric build number, `LoomRevision`, app category). Its checks are in [Release 0.4.0](#release-040-12-oct-evening). The tag, promote and install are recorded there.
- **Committed on `swarm/1`.** `2bbebf3` A and B; `37b155f` C; `037810c` E and D1; `07fafb6` D2; `c677ae1` the bundle keys.
- **Release 0.4.1** adds H1-F (the user's go, 12 Oct late evening: "şimdi başlayabilirsin"; test scope: the new features only). Checks are in [Release 0.4.1](#release-041-12-oct-late-evening).
- **Screen Time:** the question stays open; the user can look for Loom again (category and numeric build since 0.4.0).
- **Old worktrees** `loom-h1/wt/A`, `B`, `C`, `E`, `D1`, `D2`, `F` and `ref-033` are merged or done and can be removed with the user's OK.

## Slices

| Slice | Content | Write area | State |
| --- | --- | --- | --- |
| H1-A Daily use | Ended run keeps its last screen (read-only); Quit asks while sessions work or wait for approval; Quit Anyway, never blocking a system logout or restart; jump to the next or previous session that needs the user (Cmd+J, Shift+Cmd+J); next or previous session (Option+Cmd+Down/Up); the sidebar follows the selection; Reveal in Finder, Copy Claude Session ID, Copy Resume Command; Dock badge; bugs: a transient catalog error unpins a tab, the bottom spinner can stay stuck | `LoomCatalogUI`, `loom-app`, `LoomTerminal`, UI-MAP | committed in `2bbebf3`, in 0.4.0; combined checks passed (`scripts/check.sh --tests`, log `check-20261012T161645-8295.log`: LoomCoreTests 568, LoomCatalogUITests 311, LoomTerminalTests 42, LoomLaunchOptionsTests 8; the staged release tree built in `check-20261012T160621-4764.log`) |
| H1-B Core hardening | `os.Logger` categories with privacy and rate limits; a bounded diagnostic journal; registry tolerance; capabilities no longer refuse a start; toolchain re-resolved when the executable changes; hook watchdog; runtime catalog write failures; crash residue (open runs, stale sockets, unreadable run folders); catalog backup with restore and start-fresh; diagnostics bundle API; usage and plan-limit failure fields; non-sticky clock ambiguity | `LoomCore`, `CLoomPOSIX`, `loom-hook`, ARCHITECTURE, DEVELOPMENT | committed in `2bbebf3`, in 0.4.0; combined checks passed (see H1-A) |
| H1-C Wiring | UI for H1-B: <ul><li>Help menu and Settings → About: Collect Diagnostics… (reveals the export)</li><li>Catalog restore prompt at launch (Restore Backup / Start Fresh)</li><li>"Plan limits unavailable" and not-understood usage lines on the Usage page</li><li>The watchdog issue visible above a live terminal</li><li>`toolchainInvalidator` wired in AppDelegate</li><li>The export's `log show` limited to this app's processes, so test and dev runs that share the subsystem stay out</li><li>A permanent deletion also removes `catalog.damaged-*`</li></ul> | `LoomCatalogUI`, `loom-app`, small `LoomCore` | committed in `37b155f`, in 0.4.0. The implementer's `--tests` passed on the same code in worktree C (log `check-20261012T163441-15572.log`: LoomCoreTests 572, the other targets 324); after the planner's two changes the touched suites passed (log `check-20261012T163917-18365.log`, 36 tests) |
| H1-D1 Performance, part 1 | Candidates 1 (usage after a finished turn) and 5 (terminal reconcile), [D-51](../DECISIONS.md) | `UsageModel`, `UsageTranscriptWatcher`, `ConversationController` | committed with H1-E in `037810c`, in 0.4.0; combined checks passed (see H1-E) |
| H1-D2 Performance, part 2 | Candidates 2 (list patches), 3 (one search query) and 4 (card invalidation) | `LoomCatalogUI` lists and cards, `SessionCatalog+Paging` | reviewed by the planner and committed in `07fafb6`, in 0.4.0; combined checks passed on `swarm/1` (`scripts/check.sh --tests`, log `check-20261012T215200-56637.log`: 583 and 360 tests) |
| H1-E Project colours | Per D-48, look chosen on [the preview](../design/project-colors-preview.html) | `LoomCore` (`projects.color`), `LoomCatalogUI`, DESIGN, UI-MAP | look chosen ([D-50](../DECISIONS.md)): C's stripe in the sidebar, T5's light tint on the tabs (the user approved the drawing, 12 Oct), the stripe and name in the detail header; done and committed with H1-D1 (the planner's contrast change included); combined checks passed (`scripts/check.sh --tests`, log `check-20261012T170029-40693.log`: LoomCoreTests 578, LoomCatalogUITests 344, LoomTerminalTests 42, LoomLaunchOptionsTests 8) |
| H1-F macOS integration | Per D-47 and [D-49](../DECISIONS.md): menu bar item (Loom mark, working chase, status dot, session menu), notifications for Needs approval, Open at Login setting, Screen Time visibility, numeric versions from tags | `loom-app`, `LoomCatalogUI`, `scripts/release` | implemented in worktree `loom-h1/wt/F` and reviewed and merged by the planner. Targeted checks passed on `swarm/1` (`scripts/check.sh --release-tree --suite MenuBarTests MenuBarModelTests …`, log `check-20261012T234100-75401.log`: 53 tests, the staged release tree built without evidence code). The bundle keys (numeric build number, app category) shipped early, in 0.4.0. Screen Time waits for the user's look after 0.4.0 |

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

### H1-D2 notes from the review

- **When a row is patched.** One frame about one session reads that row once and patches it into the lists, only when the frame follows the last one seen (no frame missed), a visible list shows the session, no search is open and no refresh is running. Everything else keeps the full refresh, which drops pending patches.
- **Planner checks in the source.**
  - Only `publishCatalogLifecycle`, `publishActivity` and `publishDeletion` move `catalogRevision`, each by one with its own frame. So a contiguous `activityRecorded` frame accounts for exactly one step, and a run or lifecycle frame for none.
  - A patch does not re-read projects or counts. Neither depends on a session's lifecycle or activity: projects sort by `sort_order`, and counts leave out only deletions.
  - The search query's per-project cursors use the same keyset (`created_at`, `id`, newest first) as each list's "load more".
- **Implementer's notes, accepted.**
  - "Load more" after a search still reads per list.
  - A patched row that now sorts past a list's cursor leaves the loaded rows until the next page brings it.
  - A search result holds at most 5,000 rows.
  - The tooltip cache is keyed on the activity time and the time zone, not the locale.
- **Not run yet.** On screen: scrolling, the selection highlight, a search over many projects, the minute tick.

### H1-F notes from the review

- **Shape.**
  - `MenuBarSummary` (badge, counts, the approval set) is derived in `updateAttentionCount()` beside the Dock badge and fires `onMenuBarChange` only on a change. The menu is built from `menuBarState()` when it opens.
  - The chase is `ChaseDots.LayerView` over the status button: a render-server animation gated only by `wantsAnimation && window != nil`, so it moves while Loom is in the background. There is no timer.
  - `ApprovalNotificationPlanner` is pure. `ApprovalNotifier` posts and removes through a `NotificationService`, and removes everything at launch and quit.
  - `SMAppService.mainApp` and `UNUserNotificationCenter` are touched only by the live services. Under `--evidence` both are recording fakes, so test runs raise no system prompt and register no login item.
- **Implementer's choices, accepted.**
  - The mark is 18 pt wide and 16.6 pt high (the preview's 408 × 376 symbol box) in a 20 pt canvas, so the badge can reach past its corner.
  - A warning row keeps its detail and adds the orange line under it, with the button left of the switch.
  - Open at login shows on while the status is enabled or requires approval. A failed `register()` is only logged; the switch then shows the system's status.
  - The banner title is the activity-view card title.
  - The status item sets `autosaveName` and `isVisible`, so an earlier Command-drag out of the bar cannot hide an item whose switch is on.
- **Unverified at merge.** The item on a real menu bar (the badged image, the chase layers over `NSStatusBarButton`, appearance flips); the menu's look; real banners, the permission prompt and the deep links; real `SMAppService`.

### Combined checks (12 Oct)

The first combined run failed two LoomCore tests that passed in B's own run. Both are load races in the tests, not product faults:

- **`anUnverifiedStopKeepsTheRowAndTheFilesUntilARetryVerifiesIt`** (also failed once on 8 Oct). The event hub's subscription keeps only the newest frame (`bufferingNewest(1)`), so under load a later frame replaced `.deletionIncomplete` before the test's reader saw it. Tests now subscribe unbounded through an internal `SessionEventHub.subscribe(bufferingPolicy:)`; the app's subscription is unchanged.
- **`idleStopClosesInputAtomicallyAndPendingBytesBlockIt`**. `turnComplete` arrives before the Stop hook's helper process exits, and a live helper blocks the idle stop by itself. The test now waits until the leader is alone, as `childExitRearmsAutomaticIdleWithoutAnotherProviderEvent` already did, and names the blockers if it fails.

The rerun passed. One run does not prove the races are gone; the evening's full suite repeats them.

## Release 0.4.1 (12 Oct, late evening)

0.4.1 adds H1-F to 0.4.0: the menu bar item, the needs-approval banner and the three Settings rows. The user set the test scope: test the new features only, not everything again.

- **Targeted checks.** Log `check-20261012T234100-75401.log`: the debug build, the staged release tree without evidence code, and 53 tests in the menu bar suites and the suites H1-F touched (`MenuBarTests`, `MenuBarModelTests`, `MotionAccessibilityTests`, `DisplayAndPreferencesTests`, `ProductPreferencesTests`, `SettingsRoutingTests`, `LoomThemeTests`).
- **Package.** `Loom-Dev/packages/r041-07610a6`, build 77.
- **H1-F pass on the package.** Fake providers, a fresh data root, launched through LaunchServices; a scratch driver outside the repo. All 16 checks passed:
  - Idle: the item shows, no badge, label "Loom", and leftover banners are removed at launch. The empty menu is one disabled line, then the actions.
  - Working: the chase badge runs, with the label "Loom, 1 session working" and a Working section.
  - Show in menu bar off removes the item; on brings it back with the chase running.
  - Needs approval while Loom is inactive: one banner, "alpha · Claude is waiting for your approval.". The dot wins over the chase, with the label "Loom, 1 session needs you, 1 working". The menu lists Needs you, then Working.
  - Answering the approval removes the banner and posts no second one. A failure shows the red dot and posts no banner.
  - A menu row selects its session. The Open at login switch registers through the service. Quit is clean.
- **Badge cost.** Loom inactive (Finder in front), one session working, 60 s each:
  - Menu bar on, chase running: app 0.017 % CPU, 0 idle wakeups/s.
  - Menu bar off: 0.54 %, 0.08/s.
  - The chase costs the app nothing measurable. The higher off value comes from other work in that window. WindowServer's share was not measured.
- **Look.**
  - The item's drawing for idle, working, attention and failure on a dark and a light bar (a contact sheet of `screenshot-menubar`): the badge sits in the cut-away corner, and the light bar takes the darker values.
  - Settings → General: the second card with three switches, and both notices with their buttons.
- **Tag, promote, install.** Tag `release/0.4.1` → loom-dev `b7f2672`; loom `2caaa5c` / `v0.4.1` (268 files). The user quit the daily Loom, and `build.sh` built and swapped `/Applications/Loom.app`. Checked:
  - Deep-strict signature; version 0.4.1, `CFBundleVersion` 9, `LoomRevision` `2caaa5c`, the category.
  - LaunchServices holds one record, version 9.0.
  - The binary has no evidence code or fakes, and holds the H1-F strings.
  - The user's data was not touched by the install.
  - No isolated launch this time: the release flavor's `--evidence` isolates only the data root, so the live notification service would have shown the real permission prompt for the user's app during a test. The live services first run when the user opens 0.4.1.
- **Not run.** The item in the real menu bar (the user looks); the opened menu's look; real banners, the permission prompt and the deep links; real `SMAppService`; Increase Contrast; the full suite (the user's scope).

## Release 0.4.0 (12 Oct, evening)

The user handed the Mac over for the evening ("pc'm senin kontrolünde … bu akşam stabil versiyona çıkalım", 12 Oct). 0.4.0 ships H1-A to H1-E and the bundle keys. H1-F waits for the user's go, so the release stays small.

- **Full release suite.** `scripts/check.sh --full --idle` passed on the tree of `c677ae1` (log `check-20261012T215601-59397.log`). It covers the release build, the staged release tree without evidence code, and `swift test -c release` over every target with the window tests (583 and 362 tests).
- **Package.** `Loom-Dev/packages/r040-c677ae1`: `CFBundleVersion` 74, `LoomRevision` `c677ae1`, `LSApplicationCategoryType` developer tools, deep-strict signature.
- **On screen, fake providers.** Fresh data root, launched through LaunchServices, three projects and four sessions, driven by a scratch script outside the repo.
  - The three projects took three tones (Rose, Orchid, Aqua). The stripes form one rail per project in the project view and mark each row in the activity view. The tabs carry the light tint, the open one with its stroke. The detail header shows the mark and the name.
  - Search "beta" returned the one matching session.
  - Stop on the selected session kept its last screen with "This session is not running.", Resume and Show Details. Its row moved to the top (the activity stamp, patched in place).
  - Settings: General shows Project colors. About shows "Version 0.5.0 (build 74, c677ae1)" (0.5.0 is the dev flavor's label) and Collect Diagnostics…. Quit was clean.
  - The evidence captures (`cacheDisplay`) show the terminal area transparent. SwiftTerm paints its background as the layer's colour, which that capture skips. This is not a product issue.
- **Real Claude** (`perf/claude_real.py`, run `claude-real-20261012T220557`, 2 model turns). All 11 checks passed: reply, Working and Finished indicators, approval card, truecolor, background job in the run scope, Stop empties the scope, no Stop failure, clean Quit, outsider untouched. The idle observer with one Claude cost 0.045 % CPU (baseline 0.044).
- **Performance.** `perf/run-final-matrix.py` against the Oct 6 baseline alone failed one gate (run `matrix-20261012T220749`): the visible stream1 app median was 26.64 % against the baseline max + 1.5 = 25.52 %. The rerun alternated with a 0.3.3 reference package (`ref-033-87487b5`, run `matrix-20261012T223130`) and passed every gate. Visible stream1 app median: 0.4.0 26.86 % (26.86, 26.57, 26.87), 0.3.3 25.50 % (25.50, 25.08, 26.72); the gate is the reference median + 1.5 = 27.00 %. So most of the drift from the Oct 6 baseline was already in 0.3.3, and 0.4.0 adds about one point (pairs +1.4, +1.5, +0.2), inside the gate. Spinner 11.90 %, hidden stream1 3.50 %, input-to-draw p95 19.25 ms, total CPU at most 28.38 % (CPU40 passes). Open: where the extra point comes from, for a 5-run comparison in the next performance pass.
- **Tag, promote, install.** Tag `release/0.4.0` → loom-dev `ce290a2`; loom `84365e0` / `v0.4.0` (259 files). `build.sh` built and swapped `/Applications/Loom.app` (Loom was not running). Checked:
  - Deep-strict signature; version 0.4.0, `CFBundleVersion` 8, `LoomRevision` `84365e0`, `LSApplicationCategoryType` developer tools. LaunchServices holds one record for `local.loom.desktop`, version 8.0, with the category.
  - No development evidence strings in the binary; `Contents/MacOS` holds only `Loom` and `loom-hook`.
  - An isolated launch (`open -n -a /Applications/Loom.app --args --evidence <tmp>`) made its own data root, journaled `loomVersion` 0.4.0, `loomBuild` 8 and `loomRevision` `84365e0`, and quit cleanly. The user's data in `~/Library/Application Support/Loom` kept its modification times and sizes.
- **Not run.** The Help menu; the damaged-catalog alert; the issue notice above a live terminal; Usage lines with real data; the Color menu's swatches (the image is drawn with `isTemplate = false`); Increase Contrast; the Dock badge; keyboard shortcuts with a Turkish layout.

## Performance candidates

These are proposals for H1-D. They are inferred from the code and not measured; each is measured with `CatalogHotPathTests` counters or signposts before and after.

1. **Usage after a finished turn.** (The return-to-window part is done in FEEDBACK-4 U1, 27dd23c: hidden changes are collected and only those files are read.) Refresh only the changed transcripts: the paths the FSEvents watcher reports and the Stop hook's `transcript_path`. The full tree walk stays only for launch, a stale window coming back, an FSEvents overflow, a day change and the refresh button. Today `UsageModel.refresh(.turnComplete)` sets `wantsFullScan`, and the walk stats every transcript file.
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
- **On the user's word.** The full release suite (`--full --idle`) and the on-screen checks. They ran for 0.4.0 on the evening of 12 Oct, when the user handed the Mac over.

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
