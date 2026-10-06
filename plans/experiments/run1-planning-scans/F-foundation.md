# Stage F inventory (read-only; nothing built or run, every claim is from source)

## Summary

- **Codex switch:** use a runtime switch keyed on the bundle id. A new `BuildIdentity` in `LoomLaunchOptions` replaces the three duplicated `local.loom.desktop` checks and drives a `startableProviders` list. A compile-time define in the release manifest only would trip `promote.sh`'s manifest-drift check, and would ship a configuration the dev full suite never tests.
- **Quit:** `TerminalRunController` carries both the synthetic dev terminal (`newTerminal`) and the production quit state machine (`requestQuit`). Move quit into a new `AppShutdownCoordinator` and keep the synthetic run as a dev-only type.
- **Evidence/fixture code:** use `#if LOOM_EVIDENCE`, with the define only in the dev manifest. Move the evidence files to `Sources/loom-app/Evidence/` and exclude that directory in `promote.sh`. About 880 of `loom-app`'s 1,659 lines are evidence (`DevelopmentEvidence.swift` 351, `EvidenceResourcePool.swift` 281, `AppDelegate.swift` lines 697-946).
- **Large actors:** split them with move-only extension files. Rank: SessionCatalog (including `CatalogDatabase`), then SessionRuntime Codex/Claude parts, then ProcessSupervisor.
- **Check command:** add `scripts/check.sh` plus a perf wrapper and baseline comparer. Perf runners already exist in `scripts/perf/`.
- **Optimizer items:** TAKE S2 and F10, and F8 sequenced with CP4. DROP F6, F9 and S4. Hand S-C to stage I.
- **Order:** F1 (Codex switch) must land first, because I and U edit the same UI files.

## 1. Codex surfaces in a production build

**User-reachable entry points (verified):**

| Surface | Location |
| --- | --- |
| File menu "New Codex Conversation", Shift+Cmd+N | `Sources/loom-app/AppDelegate.swift:637-640` |
| `newCodexFromMenu` | `AppDelegate.swift:452-454` |
| Menu validation | `AppDelegate.swift:468-469` |
| Sidebar footer `+` menu | `Sources/LoomCatalogUI/SidebarView.swift:118`, via `NewConversationButtons` |
| Project "…" menu ("Here" suffix) | `SidebarView.swift:259` |
| Project row context menu | `SidebarView.swift:274` |
| Action list (shared by all three above) | `NewConversationAction.all`, `SidebarView.swift:384-391` |
| Empty-state button | `Sources/LoomCatalogUI/DetailView.swift:181-182` |

**Not user-reachable in production, but present:**
- `--codex-home` at `AppDelegate.swift:434-437`, and fake-provider `codex-home` at line 424. Both need `--evidence`.
- Evidence `start:codex` and `double-start` at `DevelopmentEvidence.swift:196-206`.
- Codex fields in `ConversationController.runtimeEvidence` (`ConversationController.swift:125-134`).
- Display of existing Codex rows: `SessionDisplay.swift:129`, `CatalogTheme.swift:40`.
- `harness-codex.png` is in the promote allowlist (`promote.sh:41`) and bundled by `build-loom.sh:~140`.

**Not present:** `SettingsView` has no Codex text. Nothing starts Codex at launch; toolchains resolve lazily (`SessionRuntime.swift:585`).

**Recommendation: a runtime identity switch, not a compile-time define.**
1. `promote.sh` requires every release target declaration to equal a dev declaration (`promote.sh:114`, the python normalizer). A `.define` only in the release manifest fails that check. Making it pass needs a normalizer edit.
2. The release suite (377 tests) would then test a configuration that is not the shipped one. A runtime pure function `BuildIdentity(bundleIdentifier:)` is unit-testable in both flavors.
3. The bundle id already selects data root and sockets (`AppDelegate.swift:113,234,402`), so "production" keeps one meaning.
4. Cost: Codex code stays in the production binary, paused and unreachable. That matches D-28 (frozen).

**Exact files:**
- New `Sources/LoomLaunchOptions/BuildIdentity.swift`: `isProduction`, `dataDirectoryName`, `socketDirectoryName`, `startableProviders` (`[.claude]` in production, `[.claude, .codex]` otherwise).
- `LaunchOptions.swift:53`: command-channel prefix; the identity file becomes the single owner.
- `AppDelegate.swift`: lines 113, 234, 402 use the identity; menu items at 637-640 and 468-469 become conditional.
- `CatalogModel.init` (`CatalogModel.swift:~187`): add a `startableProviders` parameter (default all, so existing tests pass).
- `SidebarView.swift`: `NewConversationAction.all` becomes filtered by `model.startableProviders`.
- `DetailView.swift:181`: conditional.
- `ConversationController.start` (`ConversationController.swift:~145`): one-line guard `startableProviders.contains(provider)`.
- Tests: `Tests/LoomLaunchOptionsTests` (identity), `Tests/LoomCatalogUITests/SidebarStatusTests.swift:57-62` (it asserts `NewConversationAction.all` equals both providers, so it must be updated), plus a `CatalogModelTests` case.

## 2. Quit path

**Current flow (verified):**
- `applicationShouldTerminate` (`AppDelegate.swift:128-141`):
  - If startup is not finished, it returns `.terminateLater`, awaits `startupTask`, and replies true if `controller == nil`, else calls `beginQuit`.
  - If startup is finished and `controller == nil`, it returns `.terminateNow`.
- `beginQuit` (`AppDelegate.swift:143-152`):
  - `conversations.quitStarted()` sets `model.quitting`, which blocks all actions (`CatalogModel.swift:754`).
  - Sets the status message.
  - Builds the evidence `quitRecorder`, then calls `controller.requestQuit(prepareReply:reply:)`.
- `requestQuit` (`TerminalRunController.swift:~110-130`):
  - Guards `quitState != running/finished`.
  - Runs `shutdown()` in a detached task, awaits `prepareReply` off the main actor, then delivers via `RunLoop.main.perform(.common)` and `MainActor.assumeIsolated`.
  - Sets `.finished` or `.failed`.
- `quitFinished` (`AppDelegate.swift:560-588`):
  - Writes `shutdown.json` to the run directory.
  - Replies true on success; otherwise replies false and shows the "Try Again / Keep Loom Open" sheet.
  - Try Again calls `NSApp.terminate` again.
- The shutdown closure is built at `AppDelegate.swift:368-380`. It counts attempts for `--fail-first-quit`, then calls `runtime.shutdown()` or `supervisor.shutdown()`.
- `controller` is created only if supervisor creation succeeded (`AppDelegate.swift:391`). Otherwise there is nothing to quit.

**Coverage today:**
- `Tests/LoomTerminalTests/TerminalRunControllerTests.swift` has 7 tests:
  - Quit-related, to be moved: lines 81 (scoped quit), 152 (quit during held launch), 186 (failed quit then retry), 220 (nested run-loop delivery with `prepareReply`, both evidence modes), 289 (reply inside a main-queue nested loop).
  - Synthetic-run tests, to be kept: lines 60 (one run at most) and 120 (failed launch retry).
- `loom-app` has no unit tests.
- End-to-end evidence: `scripts/cp5-c-acceptance.sh` section 3 (quit while an environment resolution is held, `--fake-toolchain-delay 4`), section 4 (`--fail-first-quit` then `quit-alert-try-again`, oracle at line 358 reads `quitState` and `quitAlert`), and `scripts/cp5-a-acceptance.sh:130`.
- The evidence keys `quitState`, `quitAlert`, `terminalState` and `terminalSurfaceExists` (`AppDelegate.swift:716-721`, `:794`) are read by `cp5-b/c-acceptance.sh`. Keep them or update the scripts.

**Proposed replacement:** `AppShutdownCoordinator`, `@MainActor`, Foundation-only, in `Sources/LoomCore` so its tests need no window.
- It has the same state enum as `QuitState` (idle/running/finished/failed), the same duplicate-request guard, and the same `Task.detached` plus `prepareReply` plus `RunLoop.perform(.common)` delivery.
- `attach(shutdown:)` is called by `startRuntime`; unattached means `.terminateNow`.
- It takes over the `startupTask` wait. A method `terminate(awaiting: startup, onStart:, prepareReply:, reply:)` returns the `NSApplication.TerminateReply`.
- AppKit stays in `AppDelegate` (`NSApp.reply`, the alert, `shutdown.json`). The `--fail-first-quit` wrapper and `quitRecorder` stay evidence-side.
- `TerminalRunController` loses `requestQuit`, `QuitState` and `shutdown`. The synthetic run (`newTerminal`, `State`, `syntheticLaunch`) stays in `LoomTerminal` as the dev-only `SyntheticTerminalRun`. It has tests, and `cp5-a/b`, `cp5-own-native` and `cp5-remaining-native` still use `--fixture`/`new-terminal`. It is instantiated only from the evidence seam.
- Preserve: the evidence key names, `controller?.terminalFontSize` (`AppDelegate.swift:83`), and `presentMainWindow`'s use of `controller?.surface` (`AppDelegate.swift:252`).

## 3. Evidence and fixture code in production paths

**Inventory (verified):**
- `AppDelegate.swift`:
  - Transparency override: lines 72-78.
  - Creating `DevelopmentEvidence`: lines 93-95.
  - `--fixture` first terminal: lines 103-105.
  - Quit recorder: line 148.
  - `LOOM_FORCE_SCOPE_FAILURE`: lines 229-233.
  - `--fail-first-quit` and the synthetic controller: lines 355-391.
  - Fake providers, `--fake-toolchain-delay`, `--claude-config`, `--codex-home`: lines 405-440.
  - Synthetic terminal menu item: lines 648-654. `newTerminal` and `show` with `--metal`: lines 486-520.
  - Resource-pool bridge: lines 522-556.
  - Evidence tail: lines 697-946.
  - `recordVisibility` and `traceWindowCall`: lines 263-292, partly evidence-only.
- `DevelopmentEvidence.swift` (351 lines), `EvidenceResourcePool.swift` (281 lines).
- Libraries, small, read-only and inert; leave in place:
  - `TerminalPresentationLog` (`TerminalSurface.swift:108`), `resourceObjectsForEvidence` (`TerminalSurface.swift:220`).
  - `ConversationController.terminalEvidence`, `typeForEvidence`, `runtimeEvidence` (`ConversationController.swift:85-135`).
  - `IndicatorEvidence` (`CatalogTheme.swift:229`).
  - `DevTerminal`/`showsDevTerminal` in `CatalogModel` and `DetailView`.
- `LoomCore` internal test seams:
  - `setOwnershipSamplingFailpointForTesting` (`ProcessSupervisor.swift:65`), `observeCodexSetupForTesting` (`SessionRuntime.swift:231`), `RunScope.dropConnectionForTesting` (`RunScope.swift:538`), the `SessionCatalog` failpoint inits.
  - The narrowed mode `scopeLauncher == nil` in `ProcessSupervisor`, which is a test/probe ledger path. Recommend leaving all of these: they are internal, inert, and heavily tested.
- `LaunchOptions` rules (`--evidence`, `--data-root`) are pure and fine to ship.

**Proposed separation:** `#if LOOM_EVIDENCE`, defined only in the dev manifest on the `loom-app` target (`swiftSettings: [.define("LOOM_EVIDENCE")]`).
1. Move `DevelopmentEvidence.swift`, `EvidenceResourcePool.swift` and the `AppDelegate` evidence tail (as `extension AppDelegate`) to `Sources/loom-app/Evidence/`. A few `private` members in `AppDelegate` become internal.
2. Replace the scattered `options.isEvidence` sites with calls to one small seam (setup, shutdown wrapper, scope-host override, toolchain override). `Sources/loom-app/DevelopmentSeams.swift` holds no-op stubs under `#if !LOOM_EVIDENCE`.
3. `promote.sh`: add `':(exclude)Sources/loom-app/Evidence'` to the `git archive` call at line 74. Extend the `unexpected` find pattern at line 152 with `-path '*/Evidence/*'`. In the python drift check, strip `,swiftSettings:[.define("LOOM_EVIDENCE")]` from the normalized dev text before comparing.
4. `Package.release.swift` stays as is (no define).
5. `scripts/package-dev-app.sh` is unchanged: it builds `loom-app` from the dev manifest, which now carries the define.

**Why not a separate library target now:** I and U both edit `loom-app` (the Settings window at `AppDelegate.swift:604-616`, menus, split view). Moving `AppDelegate` into a library with `package` access plus a hooks protocol is a larger refactor that would conflict with them. It remains a later option.

**Gap to cover:** the release flavor (no define) would otherwise be compiled only at promote/build time. `check.sh --full` should build a staged release tree (see 5).

## 4. Large actors

**`ProcessSupervisor.swift` (1,476 lines):**
- State (lines 25-62): about 30 mutable fields.
- Ranges:
  - session registry and accessors: 101-240
  - environment/helper jobs (`runOwnedJob`): 241-345
  - launch: 347-500
  - `adoptConversation` (conversation transitions): 502-625
  - scope work and sampling APIs: 638-668
  - stop APIs and shutdown: 669-905 (`performShutdown` 722-858)
  - `sample(runID:)` ownership selection: 927-1003
  - stop pipeline: 1011-1209
  - `terminate` signal escalation: 1210-1272
  - `sampleOwnership`, `ownershipGuarantee`, `releaseIdleScopes`: 1273-1340
  - scope management: 1342-1420
  - ledger, leader exit, catalog finish, restore: 1422-1476

**`SessionRuntime.swift` (1,305 lines):**
- Types and state: 110-240, including the private `CodexServer` class (202-227).
- Queries: 277-322.
- `start/resume`: 330-446.
- Stop and respond: 448-514.
- `shutdown`: 520-559.
- Launch helpers: 563-690 (Claude 596-690).
- Codex launch: 690-835.
- Codex plumbing: 855-1150.
- Idle companion: 1152-1182.
- Observing runs: 1184-1270.
- Codex-specific total: about 570 lines.

**`SessionCatalog.swift` (1,266 lines):**
- Public types: 1-148.
- Actor: 151-991:
  - sessions 180-345
  - runs 347-516
  - projects 517-655
  - titles 656-720
  - paged queries 721-830
  - private helpers 830-991
- `CatalogDatabase` (schema, migration, SQLite helpers): 992-1266.
- There is no session delete today; the only `DELETE` is for projects (line 583).

**Splits, ranked by value over risk. All are move-only and need `private` to internal relaxations, because stored properties cannot live in extensions:**
1. **SessionCatalog.** Extract `CatalogDatabase.swift` (lines 992-1266), then extension files per domain (`+Sessions`, `+Runs`, `+Projects`, `+Titles`, `+Paging`). Very low risk, covered by `SessionCatalogTests`/`V2`/`ScaleTests`. CP4 needs schema v3 (deletion records) and a transactional delete: those land in `CatalogDatabase` plus a new `SessionCatalog+Deletion.swift`.
2. **SessionRuntime.** Move Codex (private class, 690-1150, queries, `respond`) into `SessionRuntime+Codex.swift` and the Claude launch helpers into `+Claude.swift`; leave `start`/`resume`/`stop`/`shutdown` in the main file. This isolates the frozen 570 lines. Medium-low risk: `CodexServer` and the codex state fields become internal.
3. **ProcessSupervisor.** Extension files `+Shutdown`, `+Scopes`, `+Sampling`, `+EnvironmentJobs`, `+CatalogCommits`. Optionally pull the marker/ancestry selection (`sample(runID:)`) and its two marker fields into a value type. It is ownership-critical, so no logic change; run the `ProcessSupervisorTests`, `OwnershipBoundaryTests` and `RunScopeTests` suites.

**Seams for CP4 and U (additive; inference, not yet in code):**
- CP4:
  - `ConversationDeletion` orchestrator: stop, write a recovery record, delete provider files, delete catalog rows, forget the session.
  - `SessionCatalog.deleteSession` plus a deletion table.
  - `ProcessSupervisor.removeSession` (the `sessions` and `lastStopReports` entries).
  - `SessionEventHub.forget(sessionID:)` already exists (`SessionEventHub.swift:210`).
  - Per-owner forget hooks in `SessionLifecycleController` (baselines, generations, observed states), `ClaudeSessionAdapter` trackers, and `CatalogModel` caches.
- CP4 and U both need Claude profile paths: the config directory is resolved inline at `SessionRuntime.swift:637-651` and `:680-683`, and `ClaudeRegistry.swift` reads `sessions/`. A pure `ClaudeProfileLayout` (profile dir, `projects/<encoded cwd>/<id>.jsonl`) shared by deletion and the usage reader should have one owner. Assign it to F or to whichever lands first.

## 5. One local check command

**Today:**
- `scripts/dev-paths.sh` provides `loom_refuse_documents` (exit 2), `loom_scratch_path` (default `~/Library/Caches/loom-dev-build`), and `loom_send_command`.
- DEVELOPMENT.md §2-§3 describes the routine by hand: scratch path, `swift build`, `git diff --check`, narrow `swift test --filter`, the full release suite, and `zsh -n`/`py_compile`.
- No script wraps any of it.
- Tests that open windows: `SidebarStatusTests`, `TerminalPartialDrawTests`, `TerminalImageLimitTests`. All three open windows or `NSWindow`/`NSHostingView`, per the grep.

**Proposed `scripts/check.sh`:**
- Source `dev-paths.sh`; use `loom_scratch_path`, which refuses `~/Documents`.
- Take a lock so only one build runs (D-13), for example a `mkdir` lock beside the scratch directory.
- **Default, no window tests, no heat beyond a debug build:**
  - `zsh -n` on all scripts.
  - `python3 -m py_compile` with `PYTHONPYCACHEPREFIX` pointed at a temp directory.
  - `clang -Wall -Wextra -Werror -fsyntax-only` on the C sources (required by DEVELOPMENT.md §1).
  - `git diff --check`, `git diff --cached --check`, and a trailing-whitespace check on untracked files.
  - `swift build --scratch-path`.
  - `swift test` on `LoomCoreTests` and `LoomLaunchOptionsTests`, skipping the three window suites.
- `--windows` adds the window suites. `--filter` passes through.
- **`--full` (requires an explicit `--idle` flag):**
  - `swift build -c release` and `swift test -c release` (377 tests).
  - A staged release-tree build: export the promote allowlist from `HEAD` with `scripts/release/Package.release.swift` as `Package.swift`, then `swift build -c release`. Share the allowlist with `promote.sh` (for example `scripts/release/allowlist.txt`). This is what compiles the no-define flavor.
  - Optional macro-plugin flag via an environment variable (DEVELOPMENT.md §1).

**Perf scripts that already exist:** `perf/run-final-matrix.py` (stream1 ×3, spinner1 ×3, hidden ×1, latency ×2, wrapping `scripts/cp5-d-measure.py`), `perf/indicator_cost.py`, `perf/claude_real.py`, and the `perf_paths.py` helpers. The baseline is `plans/experiments/cp5-final-matrix-I-20261006.json`.

**Missing:**
- A baseline comparer that reads a matrix `result.json` set and checks it against that baseline (CPU40, stream1 total about 25.5%, hidden 3.5%, p95 about 20 ms), exiting nonzero on regression.
- A wrapper `perf/run-all.sh --app <pkg>`: matrix, then indicator, then real-Claude (D-04 turns), then compare. The 90 s cooldowns stay in the runners.
- One shared command-channel helper. The prefix and hash are duplicated in `LaunchOptions.swift:53`, `scripts/dev-paths.sh:32`, `scripts/cp5-d-measure.py:273` and `scripts/perf/indicator_cost_lib.py:22`.

## 6. Deferred optimizer items

| Item | Where it is now | Still present | Cost / benefit | Verdict |
| --- | --- | --- | --- | --- |
| F6 procargs scan | `ProcessSupervisor.sample(runID:)` (`ProcessSupervisor.swift:951-969`) reads `ProcessTable.managedRunID` for every unseen process, plus a confirmation snapshot | Yes | In scoped mode the result is intersected with the scope's forked members (`:984-990`), so markers only matter for runs sharing a scope (Codex). The scan is one-off per process. Touches the ownership oracle. | **DROP** (revisit only if a profile shows it) |
| F8 all sessions at startup | `restoreCatalogSessions` (`ProcessSupervisor.swift:1467-1476`) decodes every catalog row into `sessions` before `model.start()` | Yes | O(N) at launch; `CatalogScaleTests` prints restore time at 1k/10k rows but asserts no budget (I did not run it). Lazy loading from the catalog makes the catalog the single source of truth, which helps CP4 ("late events never bring a deleted conversation back"). Ripples across about 35 `sessions[...]` uses. | **TAKE**, sequenced before or inside CP4's supervisor changes |
| F9 per-session accumulation | `lastStopReports` (`:906`), hub `states` (`SessionEventHub.swift:112`), lifecycle `generations` (`SessionLifecycleController.swift:100`) | Yes, but bounded by sessions touched in one app run, small values | Negligible. Per-run state is already pruned in `releaseFinalizedRun` (`:1183`). | **DROP**; CP4 adds forget hooks anyway |
| F10 empty env host | `runOwnedJob(scope: .environment)` keeps `environmentScope` until Quit (`ProcessSupervisor.swift:299-345`) | Yes | One idle background run-host process after the first conversation start. Fix: release the scope when it has no forked members after the job (about 10 lines plus a test). Low risk. | **TAKE** (low priority) |
| S2 full table for one PID | `AppDelegate.swift:319`, `EnvironmentResolutionJob.swift:28`, `ProcessSupervisor.swift:427-433` (scoped mode only needs the leader), `SessionRuntime.swift:997` | Yes. `ProcessTable.record(pid:)` already exists (`ProcessTable.swift:~80`, test at `ClaudeRegistryTests.swift:293`). | Tiny, mechanical, safe. | **TAKE** (bundle with F10) |
| S4 manual async lock | 1 ms `Task.sleep` polling on `transitioningRuns`: `ProcessSupervisor.swift:509,1022` (plus shutdown waits at 706/736), `ProviderSessionAdapters.swift:46,122` | Yes | Spins only when contended, which is rare. Changing it risks shutdown and stop deadline semantics that the tests pin down. | **DROP** (reuse the pattern if CP4 needs a wait) |
| S-C `ChromeButtonStyle` | `SidebarView.swift:~405-444`: per-instance `@State` and a `didBecomeKey` subscription | Yes | Trivial runtime cost. Same file and region as stage I's restyle. | **DROP from F, hand to I** |

## 7. Duplicated identity checks

- `Bundle.main.bundleIdentifier == "local.loom.desktop"` is evaluated at `AppDelegate.swift:113`, `:234` and `:402`.
- `LaunchEnvironment.origin` also receives the bundle id (`AppDelegate.swift:430`).
- Data directory names, `.loom` vs `.loom-dev`, and the command-channel prefix are spread over `AppDelegate`, `LaunchOptions.swift:53`, `dev-paths.sh`, `cp5-d-measure.py`, `indicator_cost_lib.py`, `perf_paths.py`, `build-loom.sh`, and `package-dev-app.sh`.
- Consolidate Swift-side into `BuildIdentity` (item 1). On the script side:
  - `perf_paths.py` and `dev-paths.sh` each get one `command_channel` implementation.
  - `cp5-d-measure.py` and `indicator_cost_lib.py` import it.
  - The bundle ids in the two `Info.plist` blocks stay duplicated by design. Add a comment linking the two scripts.

## Proposed F slices

| Id | Goal | Write area | Acceptance | Checks | Risk | Depends on | Size |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | `BuildIdentity` plus Codex hidden in production | `Sources/LoomLaunchOptions`, `AppDelegate.swift` (sites in items 1 and 7 only), `SidebarView.swift` (`NewConversationAction`), `DetailView.swift:181`, `CatalogModel.init`, `ConversationController.start`, the three test suites named in item 1 | Production identity lists only Claude in menus, context menus, footer and empty state, and cannot start Codex; dev identity is unchanged | narrow tests; evidence screenshot on a dev package | low | none | S |
| F2 | `AppShutdownCoordinator`; strip quit from `TerminalRunController` | new `Sources/LoomCore/AppShutdownCoordinator.swift`; `AppDelegate.swift` lines 128-152, 296-395, 560-588; `Sources/LoomTerminal/TerminalRunController.swift` and its tests; new `Tests/LoomCoreTests` quit tests | every behavior in item 2 preserved; the evidence keys unchanged | the moved quit tests; `cp5-c-acceptance.sh` sections 3-4 | medium | none (not concurrent with F3 on `AppDelegate`) | M |
| F3 | Evidence separation | `Package.swift` (define), `Sources/loom-app/Evidence/`, `DevelopmentSeams.swift`, `AppDelegate.swift`, `scripts/release/promote.sh`, `Package.release.swift` (unchanged), `DEVELOPMENT.md` | dev package behaves as before; staged release flavor builds with no evidence symbols and no `Evidence/` files | dev build; release-tree build; evidence acceptance on a package | medium | F2 | M |
| F4a | SessionCatalog split | `Sources/LoomCore/SessionCatalog*.swift` | file-level move only; same tests green | `SessionCatalog*`, `CatalogScaleTests` | very low | none | S |
| F4b | SessionRuntime split | `Sources/LoomCore/SessionRuntime*.swift` | Codex and Claude helpers in extension files | `SessionRuntime*Tests` | low | none | S-M |
| F4c | ProcessSupervisor split | `Sources/LoomCore/ProcessSupervisor*.swift` | extension files only | `ProcessSupervisorTests`, `OwnershipBoundaryTests`, `RunScopeTests` | low-medium | none | M |
| F5 | `check.sh`, perf wrapper, baseline comparer, shared channel helper | `scripts/` (`check.sh`, `perf/`, `dev-paths.sh`, `README.md`), `DEVELOPMENT.md` | one command does the default and `--full` flows; comparer exits nonzero on regression | `zsh -n`, `py_compile`; one real `--full` run when idle | low | F3 (staged release build) | M |
| F6 | Optimizer items F10, S2, F8 | `ProcessSupervisor.swift`, `EnvironmentResolutionJob.swift`, `AppDelegate.swift:319`, `SessionRuntime.swift:997` | scoped env host released when empty; no behavior change | supervisor and ownership tests; F8 measured with `CatalogScaleTests` | medium (F8) | F4c (same file) | S-M |
| F7 | Docs | `docs/ARCHITECTURE.md` (the Hotspots section, the `LoomTerminal` row, the Quit section), `DEVELOPMENT.md`, `scripts/README.md` | docs match the code | link check | none | all | S |

## Conflicts with I, U and CP4 write areas

- **I:** `SidebarView.swift`, `DetailView.swift` and `CatalogModel` overlap with F1. F1 is small and should merge first. S-C belongs to I, not F.
- **U:** footer bar and Settings window.
  - The footer replaces `SidebarFooter` (`SidebarView.swift:112`) and reuses `NewConversationButtons`, so F1 must land before U.
  - `AppDelegate.showSettings` (`:604-616`) and `installMenus` (`:618-689`) overlap F2/F3. Keep F2/F3 out of those line ranges, and have U put the Settings window host in a new `LoomCatalogUI` file.
  - Conversation tabs touch `DetailView` and `MainSplitViewController`.
- **CP4:** `SessionCatalog`, `ProcessSupervisor`, `SessionRuntime`, `SessionEventHub`, `ConversationController`, `CatalogModel` and the sidebar context menu overlap F4a-c and F6. Land F4 before CP4 edits those files, or restrict CP4 to new files plus small additions.
- **Only one agent should hold `AppDelegate.swift` and the `Package.swift` edits per round.** `AGENTS.md` already gives `Package.swift` one owner per round.

## Open questions

1. A release binary launched with `--evidence`: ignore the flag (data root silently isolated) or refuse? Today `resolveDataRoot` isolates it. Behavior is unchanged until F3 removes the evidence code.
2. Keep the synthetic terminal in `LoomTerminal` (testable, ships inert) or move it into `Evidence/` and lose its unit tests? Recommend keeping it.
3. Should `check.sh --full` stage the release tree through promote's allowlist or through a separate `promote.sh --stage-only <dir>` mode? The stage-only mode is cleaner but touches promote.
4. Does the user want the Codex code physically out of the release binary? That means a separate Codex target and conflicts with the D-28 freeze, so it is not in F.
5. Who owns the shared `ClaudeProfileLayout`: F or the first of U/CP4?
6. Is it acceptable that `scopeLauncher == nil` narrowed mode and the other test seams remain in production code? Recommended yes.