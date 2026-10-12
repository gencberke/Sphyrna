# Hardening round 1 after 0.3.3 (12 Oct 2026)

Goal: stability and daily-use polish from the 12 Oct review ([D-45](../DECISIONS.md)), project colours ([D-48](../DECISIONS.md)) and Loom as a first-class app on the user's Mac ([D-47](../DECISIONS.md)). The review was three read-only passes (core robustness, UI layer, project-colour touch points); the planner checked the decisive findings in the source. Their file:line evidence is restated in the slice Briefs below, so this file keeps only the outcome.

## Slices

| Slice | Content | Write area | State |
| --- | --- | --- | --- |
| H1-A Daily use | Ended run keeps its last screen (read-only); Quit asks while sessions work or wait for approval; Quit Anyway, never blocking a system logout or restart; jump to the next or previous session that needs the user (Cmd+J, Shift+Cmd+J); next or previous session (Option+Cmd+Down/Up); the sidebar follows the selection; Reveal in Finder, Copy Claude Session ID, Copy Resume Command; Dock badge; bugs: a transient catalog error unpins a tab, the bottom spinner can stay stuck | `LoomCatalogUI`, `loom-app`, `LoomTerminal`, UI-MAP | implemented and reviewed; applied to `swarm/1` uncommitted; combined checks passed (`scripts/check.sh --tests`, log `check-20261012T161645-8295.log`: LoomCoreTests 568, LoomCatalogUITests 311, LoomTerminalTests 42, LoomLaunchOptionsTests 8; the staged release tree built in `check-20261012T160621-4764.log`); waiting for the evening's on-screen check |
| H1-B Core hardening | `os.Logger` categories with privacy and rate limits; a bounded diagnostic journal; registry tolerance; capabilities no longer refuse a start; toolchain re-resolved when the executable changes; hook watchdog; runtime catalog write failures; crash residue (open runs, stale sockets, unreadable run folders); catalog backup with restore and start-fresh; diagnostics bundle API; usage and plan-limit failure fields; non-sticky clock ambiguity | `LoomCore`, `CLoomPOSIX`, `loom-hook`, ARCHITECTURE, DEVELOPMENT | implemented and reviewed; applied to `swarm/1` uncommitted; combined checks passed (see H1-A) |
| H1-C Wiring | UI for H1-B: <ul><li>Help menu and Settings → About: Collect Diagnostics… (reveals the export)</li><li>Catalog restore prompt at launch (Restore Backup / Start Fresh)</li><li>"Plan limits unavailable" and not-understood usage lines on the Usage page</li><li>The watchdog issue visible above a live terminal</li><li>`toolchainInvalidator` wired in AppDelegate</li><li>The export's `log show` limited to this app's processes, so test and dev runs that share the subsystem stay out</li><li>A permanent deletion also removes `catalog.damaged-*`</li></ul> | `LoomCatalogUI`, `loom-app`, small `LoomCore` | in implementation in worktree `loom-h1/wt/C`, on top of A and B (base tree `70e850a`) |
| H1-D Performance | See [Performance candidates](#performance-candidates) | `LoomCatalogUI`, `SessionCatalog+Paging`, `ClaudeUsageIndex` | waiting for user decision |
| H1-E Project colours | Per D-48, look chosen on [the preview](../design/project-colors-preview.html) | `LoomCore` (`projects.color`), `LoomCatalogUI`, DESIGN, UI-MAP | look chosen ([D-50](../DECISIONS.md)): C's stripe in the sidebar, T5's light tint on the tabs, the stripe and name in the detail header; starts after H1-C (shared files) |
| H1-F macOS integration | Per D-47 and [D-49](../DECISIONS.md): menu bar item (Loom mark, working chase, status dot, session menu), notifications for Needs approval, Open at Login setting, Screen Time visibility, numeric versions from tags | `loom-app`, `LoomCatalogUI`, `scripts/release` | waiting for planning (menu bar preview first; Screen Time cause under research) |

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
