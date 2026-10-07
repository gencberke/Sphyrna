# Loom architecture

Loom is a native macOS 27 app (Swift 6.2 tools, SwiftPM, SwiftUI + AppKit, vendored SwiftTerm) that hosts Claude Code
terminals in one window and tracks their conversations in a local catalog. Every provider process is started inside a
Loom-owned run scope, so Loom can stop exactly what it started, and nothing else, on stop, quit, or after a crash.
Read this before touching code; verify against the source when in doubt (the code wins).

- **Scope of the first production release (6 Oct 2026):** Claude only. Codex code stays in the tree but is **paused, not in
  first release** (see Section 8). The product renderer is Core Graphics; Metal is development-only (`--metal` with `--evidence`).
- Product decisions: `LOOM-PRODUCT-CONTRACT.md`. Visual contract: `design/DESIGN.md`, `design/UI-MAP.md`. Build, test, evidence method:
  `DEVELOPMENT.md`. Decision log: `DECISIONS.md`. Plan: `ROADMAP.md`. Current position: `STATUS.md`. Agent workflow: `AGENTS.md`.

## 1. Layers

```
loom-app (exe: NSApplication, AppDelegate, window, menus, dev evidence)
   |-- LoomCatalogUI  (SwiftUI sidebar/detail, CatalogModel, ConversationController)
   |       |-- LoomTerminal  (TerminalSurface over SwiftTerm, input queue wiring, quit state)
   |       |       |-- SwiftTerm (Vendor/SwiftTerm, local patches)
   |       `-------+-- LoomCore  (no UI: runtime, supervisor, catalog, ownership, hooks)
   |                       `-- CLoomPOSIX (C: PTY, process table, coalition reads, scope IO)
   `-- LoomLaunchOptions (pure CLI-flag rules, no dependencies)
helpers: loom-run-host (C, bundled LoomRunHost.app) -> CLoomPOSIX;  loom-hook -> LoomCore
dev/test only: loom-test-child, loom-fake-provider, loom-catalog-fixture, loom-probe
```

Rules: `LoomCore` imports no UI framework and keeps process/PTY/wait work off MainActor. Dependencies only point down the
diagram. AppKit appears only in `LoomTerminal`, `LoomCatalogUI` and `loom-app`.

## 2. Targets

Declared in `Package.swift`; all tests use swift-testing (`@Test`). Product bundle layout: `scripts/package-dev-app.sh`.

| Target | Responsibility | Key types / files | Tests |
|---|---|---|---|
| `CLoomPOSIX` (C) | PTY spawn, process table, `proc_pidinfo`/coalition reads (private XNU flavors), env marker reads (`KERN_PROCARGS2`), scope signalling, run-host frame IO | `CLoomPOSIX.c`, `RunScope.c`, `include/` | via `LoomCoreTests` |
| `CLoomTestSupport` (C) | Test-only helpers for `loom-test-child` | `CLoomTestSupport.c` | none |
| `LoomCore` | Everything non-UI: runtime, supervisor, catalog, ownership, hook server, provider setup, lifecycle, event hub | see below | `LoomCoreTests` |
| `LoomTerminal` | SwiftTerm wrapper: output bridge, bounded input queue wiring, limits, theme, A-slice synthetic-run state machine | `TerminalSurface.swift` (`TerminalSurface`, `TerminalOutputBridge`, `TerminalSurfaceLimits`, `LoomTerminalView`), `TerminalRunController.swift`, `TerminalTheme.swift` | `LoomTerminalTests` |
| `LoomCatalogUI` | Sidebar, detail pane, `@Observable` `CatalogModel`, `ConversationController` (runtime to terminals glue), status indicator, UI preferences, git branch read | `CatalogModel.swift`, `ConversationController.swift`, `SidebarView.swift`, `DetailView.swift`, `SessionDisplay.swift` (`SessionIndicator`), `LoomTheme.swift` (all visual tokens; guarded by `scripts/check-theme-literals.sh`), `IndicatorView.swift` (`IndicatorView`, `ChaseDots`, `IndicatorEvidence`), `ProviderIcon.swift`, `UIPreferences.swift`, `GitBranch.swift`, `BranchCache.swift`, `SettingsView.swift` | `LoomCatalogUITests` |
| `LoomLaunchOptions` | Pure launch rules: data root resolution, `--evidence`, command-channel name | `LaunchOptions.swift` | `LoomLaunchOptionsTests` |
| `loom-app` (exe) | `AppDelegate` (one window, menus, runtime wiring, Quit), `MainSplitViewController`, dev evidence tooling | `AppDelegate.swift`, `MainSplitViewController.swift`, `DevelopmentEvidence.swift`, `EvidenceResourcePool.swift` | none (acceptance scripts in `scripts/`) |
| `loom-run-host` (C exe) | Bundled `Contents/Helpers/LoomRunHost.app`; one instance per run scope; spawns PTY children, reports exits | `main.c` | `RunScopeTests` (assembles a real bundle) |
| `loom-hook` | Claude hook command: reads stdin, sends an authenticated envelope to the hook socket | `main.swift` | `ClaudeHookTests` |
| `loom-test-child` | Synthetic process fixture and the dev "terminal" | `main.swift` | used by many tests |
| `loom-fake-provider` | Provider-shaped Claude/Codex fixture for tests and `--fake-providers`. Never bundled | `main.swift`, `CodexFixture.swift` | n/a |
| `loom-catalog-fixture` | Writes an isolated catalog for acceptance. Never bundled | `main.swift` | n/a |
| `loom-probe` | Experiment/measurement CLI (Q1 experiments, Codex observer) | `main.swift` + 10 files | none |

`LoomCore` groups (all under `Sources/LoomCore/`):

| Group | Files |
|---|---|
| Ownership and process | `ProcessSupervisor` (core plus `+Stop`, `+Shutdown`, `+Sampling`, `+Scopes`, `+EnvironmentJobs`, `+CatalogCommits`), `OwnershipLedger`, `ProcessTable`, `PTYProcess`, `EventDrivenPTYProcess`, `RunScope`, `PreviousRunRecovery`, `ShutdownReport`, `AppShutdownCoordinator` |
| Runtime and lifecycle | `SessionRuntime` (core plus `+Claude`, `+Codex`), `ConversationDeletion` (`SessionRuntime` deletion flow, `ConversationForgetting`), `SessionLifecycleController` (also defines `ProviderWorkState`), `ManagedSession`, `SessionEventHub`, `ProviderSessionAdapters` |
| Persistence | `SessionCatalog` (core plus `+Sessions`, `+Runs`, `+Projects`, `+Titles`, `+Paging`), `CatalogDatabase` (schema, migration, SQLite helpers) |
| Terminal I/O | `TerminalEndpoint` (also `TerminalOutputSink`), `TerminalInputQueue`, `TerminalInputGate` |
| Provider setup | `LaunchEnvironment`, `EnvironmentResolutionJob`, `ProviderToolchain`, `ProviderLaunchProfile`, `ProviderResume` |
| Claude | `ClaudeHook` (server, client, `ClaudeHookStateTracker`), `ClaudeRegistry`, `ClaudeDataInventory` (planner and safe deleter of a session's files), `ClaudeProfileLayout`, `ClaudeUsageIndex` |
| Codex (paused) | `CodexAppServer`, `CodexAppServerManager`, `CodexSessionCoordinator`, `CodexSessionState`, `CodexWireDiagnostics`, `CodexRoutingDiagnostics` |

Roles: `SessionRuntime` is the one application runtime (UI sends intents only). `ProcessSupervisor` (actor) owns runs, scopes,
ledger, stop/shutdown and catalog commits. `SessionCatalog` (actor) is the durable store. `SessionEventHub` (actor) publishes
sequenced frames to subscribers.

## 3. Runtime flows

**App launch to catalog** (`AppDelegate.applicationDidFinishLaunching`)
`LaunchOptions.resolveDataRoot` -> `SessionCatalog(url: catalog.sqlite3)` -> `CatalogModel(events: hub, preferences:
ui-preferences.json)` -> window shown at once (`makeWindow`, `MainSplitViewController`) -> `startupTask` runs `model.start()`
(first page) and `startRuntime` concurrently (ledger + `runs/<uuid>/`, `ProcessSupervisor.restoring`, the app's own
`ProcessTable.record(pid:)` for `owner.json`, `SessionRuntime.start`, `ConversationController.begin`, background
`PreviousRunRecovery`) and waits for both before `startupFinished` (Quit waits for the same task). The sidebar needs only the
catalog and the hub; a runtime that attaches after the first page makes `CatalogModel.intents` count the selection as viewed
then. Opening the app starts no provider, PTY or terminal. Signposts (`LoomSignposts`, subsystem `local.loom.desktop`, category
PointsOfInterest) mark `LaunchToFirstPage`, `CatalogOpen`, `WindowShown`, `RuntimeStart`, `FirstPage` and `SelectToTerminal`;
read them with `/usr/bin/log show --last 2m --signpost --predicate 'subsystem == "local.loom.desktop"'` or
`scripts/perf/launch_paint.py` (before/after medians in `plans/experiments/run1-F5-launch.json`).

**Sidebar branches and refreshes** `CatalogModel` never reads Git on the main actor: `BranchCache` (actor, one `GitBranch.read`
per folder) is asked for the folders of a page before that page is published, so a card shows its branch with the first
paint; turn completion and window activation refresh known folders in the background and publish only changed values.
`branches` keeps only folders a loaded card, the selection or a tab shows. A reload writes an observed property only when the
value differs (`projects`, `sessionCounts`, list rows, `branches`); `now` moves forward at most every 10 s, or when a row is
newer than it.

**Start a Claude conversation to indicator**
```
CatalogModel.startConversation -> ConversationController.start (creates TerminalSurface)
 -> SessionRuntime.startConversation: working dir, ProviderToolchain (user shell env), ensureHooks
    (ClaudeHookServer on <socketDir>/h-<8>.sock + token), launch profile (--session-id, per-session --settings)
 -> ProcessSupervisor.createSession (catalog insert) -> launch -> openScope (RunScopeLauncher: `open -n -g -j LoomRunHost.app`,
    fresh coalition, owner-verified handshake; scope registered and ledger persisted) -> spawnInScope (host spawns the PTY child)
 -> Claude runs loom-hook per event (LOOM_HOOK_SOCKET/TOKEN, LOOM_MANAGED_RUN_ID)
 -> ClaudeHookServer -> ClaudeHookIngress (bounded 1,024, ordered) -> SessionRuntime.deliver -> ClaudeSessionAdapter.receive
 -> ClaudeHookStateTracker -> ProcessSupervisor.updateProviderWorkState (adoptConversation on /clear, fork, resume)
 -> SessionEventHub frame -> CatalogModel.apply (sequence fast path, full reconcile on a gap) -> SessionRowModel.live
 -> SessionIndicator(record:live:) -> IndicatorView / ChaseDots in sidebar row and detail header
```

**Terminal output to pixels**
```
PTY master fd -> EventDrivenPTYProcess (DispatchSourceRead, own queue) -> TerminalOutputSink = TerminalOutputBridge
 -> TerminalFeedSender.feed (off MainActor) -> SwiftTerm FrameDriver (FrameDriverSignal; coalesced, cadence tick)
 -> TerminalView draw on main (Core Graphics): changed-row snapshot diff
```
Render behaviors are SwiftTerm patches (Section 6): partial row invalidation (only rows whose snapshot content changed, plus
one row margin; whole view on layout/style/selection/image change), identical-row skip (`BufferLine.snapshotRendersLike`),
direct glyph runs, and hidden-window suspension (`TerminalSurface` sets `suspendsRenderingWhenNotVisible = true`; hidden
feeds are retained and exactly one frame draws on return). Input path: `TerminalViewDelegate.send` -> `TerminalInputQueue`
(4 MiB, ordered) -> `TerminalEndpoint.write`; `TerminalInputGate` closes a run's input atomically on automatic idle stop.
Engine limits live in `TerminalSurfaceLimits` (scrollback 2,000 lines, OSC 1 MiB, Kitty 8 MiB and inline images 8 MiB /
1,024 per screen).

**Stop**
`ConversationController.stop` -> `SessionRuntime.stopConversation` -> `ProcessSupervisor.stop`: provider prepare-stop hooks,
freeze then kill forked scope members (launchd-spawned members are never signalled), ownership resample, `SessionStopReport`.
A failed stop stays visible (`SessionViewState.stopFailure`, "Stop it again to retry") and is retried by stopping again.

**Delete a conversation** (CP4-C, `ConversationDeletion.swift`; Claude only, Codex and synthetic rows are refused, D-28)
```
SessionRuntime.deletionPreview(id:)   dry run for the confirm dialog: file count, bytes, config dir, not removed, unreachable
SessionRuntime.deleteConversation(id:) / retryDeletion(id:) / pendingDeletions()
 request:  refuse Codex/synthetic, a start in progress, an id shared with another (non-deleting) conversation, an unsafe config dir;
           SessionRuntime.claudeConfigDirectory() (ClaudeProfileLayout from the explicit profile, else the resolved toolchain's when one
           exists, else Loom's own CLAUDE_CONFIG_DIR, else ~/.claude; never runs the Claude CLI; a folder that is missing or on an
           unmounted volume is a readable refusal) -> ClaudeDataInventory.plan (live process ignored: the stop follows) -> beginDeletion
 requested -> stopping      close the run's input (TerminalInputGate), stopConversation, report.succeeded required (a run that moved
                            to another card by /clear needs no stop)
           -> provider_data plan again WITH the live check, ClaudeDataDeleter.execute; any failed item, refusal or unreachable folder stays here;
                            a config folder counts as gone only when lstat says ENOENT and its parent exists, else `config_unavailable`
           -> catalog       deleteSessionRows (+ WAL truncate)
           -> verifying     no catalog row or reappeared provider id, supervisor.discardSession (+ deletedProviderIDs fence),
                            ClaudeSessionAdapter.forget, ClaudeDataDeleter.verify finds nothing (leftovers found here are planned again with the
                            live check, removed and verified once more in the same step; a live process fails it as `live_session`
                            and a retry resumes here), every ConversationForgetting hook
                            ran (usage index registers one in AppDelegate+Usage), SessionEventHub.forget, finishDeletion,
                            frame `.conversationDeleted`
```
The record's state is the step in progress and is persisted before the step runs; a failed step records `step_failed`-style
category plus file name on the same state (`PendingConversationDeletion.lastFailure`), publishes `.deletionIncomplete` and waits for
a manual retry. `SessionRuntime.start` runs `recoverDeletions` in the background (no run of this process exists yet, so `stopping` resolves;
`PreviousRunRecovery` runs concurrently in the app, so a process a crashed Loom left behind may still hold the files: it shows
up as `live_session` and the record stays pending until a manual retry). Fences: `resumeConversation`, `ProcessSupervisor.launch` and the catalog (`markUsed`,
`startRun`, `transitionRun`) refuse a pending id; `adoptConversation` refuses any provider id in `deletedProviderIDs` or in a
`deletions` row (a late `SessionStart(resume)` gets `.staleRun`, no row is created); late hooks of the deleted run already get
`.staleRun` because the run context is gone. Forget hooks are registered in `ConversationForgetters` (`SessionRuntimeConfiguration.forgetters`,
default `.shared`); the tab and `CatalogModel` caches follow the `.conversationDeleted` frame (wired in CP4-D).

**Quit**
`applicationShouldTerminate` -> waits for `startupTask` -> `beginQuit` -> `AppShutdownCoordinator.requestQuit` (shutdown
closure; `LoomCore`, state `idle/running/finished/failed`) -> `SessionRuntime.shutdown` (cancel Codex setup, stop lifecycle evaluation + hook server, tear down Codex servers,
`ProcessSupervisor.shutdown` -> `ShutdownReport`). Unverified shutdown keeps the app open with a Try Again alert. Cmd+W only
closes the window; the runtime keeps running.

**Previous-run recovery**
`PreviousRunRecovery.recover(runsDirectory:current:)` (background, never starts anything): for each other `runs/<uuid>/` whose
`owner.json` process is not alive, read `ledger.json`, drain this-boot coalitions (kill only forked members), delete the
directory when every scope is shown empty; leftovers surface as `CatalogModel.ownershipNotice`, keep their directory and get a `recovery-error.txt`.

## 4. Process ownership model

- **Run host per scope.** `RunScopeLauncher.launch` starts `Contents/Helpers/LoomRunHost.app` through LaunchServices, so
  it is the only member of a fresh resource coalition; everything it spawns, including `setsid`/double-fork escapees, stays
  in that coalition. App and host talk over a short-lived Unix socket (`<home>/.loom[-dev]/scopes/h-<12>.sock`) with a token;
  the host serves only its owner (`LoomOwnerRequirement` in the host Info.plist, checked by the host's `peer_is_owner` in `Sources/loom-run-host/main.c`; the app side, `RunScopeLauncher.verify`, checks peer UID, LaunchServices lineage and the exclusive coalition).
  If Loom disappears without an orderly EXIT frame, the host kills forked members itself and exits. The host is its own
  TCC-responsible app: packages, fixtures and build scratch must live outside `~/Documents` (`scripts/dev-paths.sh`); the source checkout may stay there.
- **Scope and members.** `RunScope`/`RunScopeTable` track members via `CLoomPOSIX` reads. `RunScopeMember.launchdSpawned`
  separates launchd-spawned members (never signalled) from forked work (frozen, re-verified, killed). The app's own
  coalition is never an ownership seed.
- **Ledger.** `OwnershipLedger` (Codable: `runID`, `sessionLeaders`, `descendants`, `scopes`) is persisted to
  `runs/<uuid>/ledger.json` before any spawn. Scope records carry the boot-session UUID; coalition IDs from another boot
  are ignored.
- **Birth identity.** A process is identified by `ProcessIdentity` (pid + start time seconds/microseconds from
  `ProcessTable`); signalling goes through `loom_signal_if_matches`, so a reused pid is never signalled.
- **Markers.** Launched processes carry `LOOM_RUN_ID`, `LOOM_SESSION_ID`, `LOOM_MANAGED_RUN_ID` in their environment
  (read back through `KERN_PROCARGS2`, works for non-Apple binaries); launch refuses if they do not match.
- **"Owned" means**: a member of a scope Loom opened in this run (or recorded by an earlier Loom in this boot), identified by
  birth identity, and for forked members re-verified before a signal. Scoped processes of another UID are reported as
  unverified, never as success. Without a `scopeLauncher` (tests/probe only) ownership narrows to session leaders and
  descendants; the app refuses to start runs when the bundled host is missing.
- **Identities are separate:** catalog session id, provider conversation id, run id. `run_sessions` and
  `provider_identity_changes` record `/clear`, `/new`, fork and resume transitions.
- **Dev vs prod identity.** Production bundle id is `local.loom.desktop`; anything else is development
  (`Loom Dev.app`, `local.loom.desktop.dev`, built by `scripts/package-dev-app.sh`; no production packaging exists yet).

| | Development (bundle id != `local.loom.desktop`) | Production |
|---|---|---|
| Data root | `~/Library/Application Support/Loom-Dev` | `~/Library/Application Support/Loom` |
| Hook socket dir | `~/.loom-dev` | `~/.loom` |
| Scope socket dir | `~/.loom-dev/scopes` | `~/.loom/scopes` |
| Evidence data root | `--data-root` or `<evidence dir>/data`; never the default root | not applicable |

## 5. Persistence

| Store | Location | Notes |
|---|---|---|
| `SessionCatalog` | `<data root>/catalog.sqlite3` | SQLite via system `sqlite3`; WAL; `quick_check`; `secure_delete = ON` per connection; schema v3 (`SessionCatalog.schemaVersion`): `sessions` (+ `stale_since`), `runs`, `run_sessions`, `provider_identity_changes`, `projects`, `deletions`, `app_state`. Refuses newer or foreign schemas; surfaces the failure in the UI instead of starting a runtime |
| UI preferences | `<data root>/ui-preferences.json` | `UIPreferencesStore` (`UIPreferences.swift`); an unreadable file is renamed to `ui-preferences.unreadable-<ts>.json` |
| Run directories | `<data root>/runs/<run uuid>/` | `ledger.json`, `owner.json`, `ownership-guarantee.txt`, created 0700 per app run; removed by `PreviousRunRecovery` once scopes are shown empty |
| Hook socket | `<socket dir>/h-<8 hex of run id>.sock` | `SessionRuntime.ensureHooks`, token-authenticated, removed by `ClaudeHookServer.stop` at shutdown |

Catalog schema v3 (CP4-B; `CatalogDatabase.swift` holds schema, migration and SQLite helpers, `SessionCatalog+Deletions.swift` the deletion API):
- **Migration.** `migrate(from:)` runs the chain v1 to v2 to v3 in one transaction (`BEGIN IMMEDIATE`, `user_version` set last, test failpoint after each version's DDL); an interrupted migration leaves the old file untouched. v3 adds `deletions`, `sessions.stale_since`, `app_state` (`last_cleanup_at`, `last_launch_at`) and the child indexes `run_sessions(session_id)`, `runs(initial_session_id)`, `provider_identity_changes(session_id)`.
- **No downgrade (DP-CP4-4).** Loom 0.1.0 (schema v2) refuses a v3 catalog through the existing `user_version > schemaVersion` guard (`unsupportedSchema`) and does not modify the file; there is no v3 to v2 path. Users who go back to 0.1.0 keep their catalog but cannot open it with that build.
- **Deletion record.** `deletions(session_id, provider, provider_ids JSON, config_dir, working_directory, state, requested_at, updated_at, attempts, last_error)`, state one of `requested`, `stopping`, `provider_data`, `catalog`, `verifying`. No foreign key and no title or content; `last_error` is a category plus a file basename (`CatalogDeletionFailure`). API: `beginDeletion` (refuses a second record), `advanceDeletion` (same state records a retry, never backwards), `pendingDeletions`, `finishDeletion`. `deleteSessionRows` deletes identity changes and links of the conversation, repoints each run that started from it to its earliest remaining linked conversation (deleting the run when none remains), deletes the `sessions` row in the same transaction, then `wal_checkpoint(TRUNCATE)`; with `secure_delete = ON` no title bytes remain in `catalog.sqlite3` or `-wal` (trace test).
- **Fences.** A conversation with a `deletions` row is excluded from `sessions()`, `sessionPage`, `sessionCounts`, `classifyStale` and `oldestStaleCandidate`, and `markUsed`, `startRun` and `transitionRun(toExistingSessionID:)` throw `deletionPending`. Direct lookups (`session(id:)`, `sessions(ids:)`) stay unfenced because the deleter needs the row.
- **Deletion orchestration (CP4-C).** `isProviderIDShared` ignores a conversation that has its own `deletions` row (its data is going away too); `isProviderIDPendingDeletion(id)` answers whether any record lists the provider id (used by the late-event fence). `ClaudeDataInventory.plan` also returns `unreachable` (a link or other-device folder the scan cannot enter) so a deletion is never reported complete while one exists, and takes `ignoringLiveSessions` for the dry run; the deleter still refuses a live session. `sessions/<pid>.json` is parsed by the same helpers as the registry reader (`ClaudeRegistryFields`; a boolean `pid` is not a pid). Failure categories stored in `last_error`: `config_unavailable`, `stop_failed`, `stop_unverified`, `live_session`, `unsafe_directory`, `partial_failure: <file>`, `unreachable_folder: <folder>`, `leftover_files: <file>`, `provider_id_reappeared`, `forget_hook_failed`, `still_running`, `step_failed`.
- **Undecodable rows.** `sessions()`, `sessions(ids:)` and `sessionPage` skip and count a row with an unknown provider or malformed identity instead of failing the list (`SessionCatalog.skippedRowCount`, `CatalogPage.skippedRowCount`); such rows are never written or deleted.

## 6. Vendored SwiftTerm

- `Vendor/SwiftTerm` is a path dependency pinned to upstream commit `fe4fb45d5888ce33ff3788d6873870a73894a41b`; the choice
  is recorded in `plans/CHECKPOINT-5-HISTORY.md` §3.1. `Vendor/SwiftTerm/LOOM-VENDOR.md` is the authority for what was copied
  and what changed.
- **Policy:** never edit upstream sources in place without a patch. Every local source change exists as
  `patches/swiftterm-*.patch` (repo root) and is listed in `LOOM-VENDOR.md`. The only non-patch changes are the reduced
  `Vendor/SwiftTerm/Package.swift` and the build-info plugin/generator pins (items 2-3 in `LOOM-VENDOR.md`).
- **Current patches (10):** inline-image-quota, buffer-diagnostics, frame-signal-coalescing, ascii-text-presentation-guard,
  direct-glyph-runs, direct-glyph-blank-skip, direct-run-continuation, partial-row-invalidation, suspended-signal-retention,
  identical-row-skip. Tests in `LoomTerminalTests` (`FrameDriverTests` in `TerminalFrameDriverTests.swift`, `TerminalPartialDrawTests`,
  `TerminalDirectGlyphTests`, `TerminalImageLimitTests`) guard them.
- **To update:** check out the new upstream commit, copy the same paths, re-apply the patches in the order listed under
  "Updating" in `LOOM-VENDOR.md`, update the commit in `LOOM-VENDOR.md` and in the build-info plugin, run the full suite.
  To add a change: new patch file, new numbered entry in `LOOM-VENDOR.md`, add it to the "Updating" list.

## 7. Dev and evidence code in the app target

- Compiled only in the development flavor: `Package.swift` gives `loom-app` `swiftSettings: [.define("LOOM_EVIDENCE")]`, and
  everything evidence-only lives in `Sources/loom-app/Evidence/` (each file wrapped in `#if LOOM_EVIDENCE`).
  `Sources/loom-app/DevelopmentSeams.swift` holds the call seams `AppDelegate` uses, as no-op stubs under `#if !LOOM_EVIDENCE`.
  The release flavor (the clean loom tree) excludes the `Evidence/` directory and the define, so a release binary has no
  command channel, fixture providers or resource pool, and `--evidence` does nothing there beyond the data-root rule in
  `LoomLaunchOptions` (`--data-root` is valid only together with it; a malformed flag refuses the catalog instead of falling
  back to the default root). `scripts/check.sh --release-tree` builds the exported release tree and checks the binary.
- Evidence-only (development flavor, active only with `--evidence <dir>`): `DevelopmentEvidence` (command channel via
  distributed notification `local.loom.desktop.dev.command.<16 hex of SHA-256(realpath(dir))>`, state snapshots, screenshots),
  `EvidenceResourcePool`, the `AppDelegate` evidence extensions (`AppDelegate+Evidence*.swift`), `--metal`, `--fixture`,
  `--fake-providers`, `--fake-toolchain-delay`, `--claude-config`, `--codex-home`, `--fail-first-quit`, `LOOM_FORCE_SCOPE_FAILURE`,
  and the synthetic terminal (menu item, controller). Inert library-side seams remain in both flavors: `TerminalPresentationLog`,
  `ConversationController.terminalEvidence`/`typeForEvidence`/`runtimeEvidence`, `IndicatorEvidence`.
- A normal launch never subscribes to the command channel and cannot substitute fixture providers. Command list: doc comment
  at the top of `Evidence/DevelopmentEvidence.swift` plus the `case`s of its command switch and of
  `Evidence/EvidenceCatalogCommands.swift` (the header omits `buttons:`, `toggle-fullscreen`, `feed`, `double-start` and `resource:`);
  scripts and method: `DEVELOPMENT.md` and `scripts/` (`cp5-*.sh|py`, `dev-paths.sh`).

## 8. Codex: paused, not in first release

Code is kept and tested but receives no new development. Locations: `Sources/LoomCore/Codex*.swift` (6 files),
`CodexSessionAdapter` in `ProviderSessionAdapters.swift`, `CodexEventStateTracker` in `CodexSessionState.swift`, the nested `CodexServer` class and Codex
setup/teardown in `SessionRuntime+Codex.swift`, `Sources/loom-fake-provider/CodexFixture.swift`, Codex tests in `LoomCoreTests`
(`CodexAppServer*`, `CodexWireDiagnosticsTests`, `SessionRuntimeCodex*`), `loom-probe` Codex files. UI entry points ("New Codex Conversation" in `SidebarView.swift` and `DetailView.swift`, `AppDelegate.newCodexFromMenu`) exist only in development builds: `BuildIdentity` (`Sources/LoomLaunchOptions/BuildIdentity.swift`) gives `startableProviders = [claude]` for the production identity `local.loom.desktop`, `CatalogModel.startableProviders` filters every new-conversation surface, and `ConversationController.start` refuses a provider outside that set. Resume follows the same rule: `CatalogModel.canResume` requires a startable provider (Resume, "Reactivate and Resume", Cmd+R and the menus all go through it), `resumeConversation` and `ConversationController.resume` refuse a record of any other provider, and the record view says "Codex conversations can't be resumed in this version." (`resumeUnavailableReason`); a Codex record in the production catalog stays readable and listed.
Design fact: one `codex app-server` per Codex session (contract §3).

## 9. Hotspots and scaling notes (facts, no redesign)

- Large actors, split by responsibility into extension files (the stored state stays in the core file, so access is internal
  rather than private): `ProcessSupervisor` (core: ~35 mutable fields, registry, launch, adopt; `+Stop`, `+Shutdown`,
  `+Sampling`, `+Scopes`, `+EnvironmentJobs`, `+CatalogCommits`), `SessionRuntime` (core; `+Codex` ~550 lines, `+Claude`),
  `SessionCatalog` (core; `+Sessions`, `+Runs`, `+Projects`, `+Titles`, `+Paging`; `CatalogDatabase`; synchronous sqlite on
  an actor).
- Codex share of `LoomCore`: ~2,700 lines in `Codex*.swift` plus adapter and `SessionRuntime` parts, roughly 30% of the target.
- UI-layer coupling: `ConversationController` and `CatalogModel` hold `SessionRuntime`/`ProcessSupervisor` directly;
  `CatalogModel` (828 lines) mixes paging, search, selection, projects, rename, event consumption and branch reads;
  `CatalogModel` imports AppKit and `ConversationIntents.terminalView` returns `NSView`.
- Launch measurements (F5, release package, 5 runs each, `scripts/perf/launch_paint.py`): window creation (`WindowShown`,
  ~125-136 ms) dominates app delegate to first page; catalog open including `PRAGMA quick_check` is 0.7 / 1.5 / 8 ms at 0 /
  1,000 / 10,000 rows, so it stays on the main thread. Git branch reads are off the main actor (`BranchCache`).
  `CatalogModel.scheduleRefresh` still reloads every loaded row of every visible list on run/lifecycle frames (a row-level
  refresh is a follow-up).
- Quit path: `AppShutdownCoordinator` (`LoomCore`) owns the quit state machine; `AppDelegate.startRuntime` builds it with the
  shutdown closure when the supervisor exists, and with no coordinator quit returns `.terminateNow`. `TerminalRunController`
  now carries only the evidence-only synthetic dev terminal.
- Identity: `BuildIdentity` (LoomLaunchOptions) is the one Swift owner of production vs development names (data and
  socket directories, command-channel prefix, startable providers); the Python runners share one channel helper
  (`scripts/perf/perf_paths.py`); `scripts/dev-paths.sh` keeps its own copy for the zsh scripts.
- Evidence code (~880 of `loom-app`'s ~1,660 lines: `DevelopmentEvidence`, `EvidenceResourcePool`, tail of `AppDelegate`)
  ships in the production executable, gated by `--evidence`.
- Ownership sampling in `ProcessSupervisor` scans the process table; `persistLedger` rewrites the ledger JSON.
- No `.github/`, no CI, no release packaging or notarization; only `scripts/package-dev-app.sh` (dev signing, version
  hard-coded in inline Info.plists). `loom-app` has no unit tests; `AppDelegate`/`MainSplitViewController` and the views are
  covered only by manual acceptance scripts.

## 10. Keeping this file true

Update in the same change as the code:

| Change | Update |
|---|---|
| New, removed or renamed target; changed dependency direction | Sections 1-2, `Package.swift` comment if needed |
| Responsibility moved between files or actors; new flow step; new hook/event path | Sections 2-3, hotspots (9) |
| New process type, helper bundle, socket, or ownership rule | Sections 3-4 and the data table in 4 |
| New persisted file, catalog schema bump, new data directory | Section 5 and 4's table |
| New or removed `patches/*.patch`, SwiftTerm commit change | Section 6 and `Vendor/SwiftTerm/LOOM-VENDOR.md` |
| New evidence flag or dev-only code path in the app | Section 7 (details in `DEVELOPMENT.md`) |
| Codex pause lifted or Codex code removed | Sections 8-9 and the header |
| Product-level decision | `DECISIONS.md` and `LOOM-PRODUCT-CONTRACT.md`, not here |

Facts that change often (line counts, test counts) are deliberately approximate; do not "correct" them in unrelated
changes. Every path and type name here must exist in the tree.
