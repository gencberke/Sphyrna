**Code architecture map: Loom at `/Users/gencberke/Documents/github/loom`**

Everything below is observed in the files unless it is labelled "inference".

## 0. Repo state (facts)

- Git has 11 commits; the last is "close CP2". The tree has 48 modified files, 1 deleted (`Sources/LoomCore/CoalitionCapability.swift`) and 141 untracked paths.
- The untracked paths include all CP5 work: `Sources/LoomTerminal`, `LoomCatalogUI`, `loom-app`, `LoomLaunchOptions`, `loom-run-host`, `loom-fake-provider`, `loom-catalog-fixture`, `Vendor/`, `patches/`, `plans/cp5/`, `scripts/` and about 20 Core files. `Sources/` + `Tests/` hold 111 files, of which only 48 are tracked.
- There is no `.github/` and no CI.
- Only a dev packaging script exists (`scripts/package-dev-app.sh`). The `Info.plist` files are inline heredocs with version `0.5.0` hard-coded.
- No release, notarization or production packaging exists. The bundle id `local.loom.desktop` is only compared against in code, and nothing builds it.
- `Package.swift` declares `swift-tools-version: 6.2` and `.macOS("27.0")`. `DEVELOPMENT.md:43` says Swift 6.4. Vendored SwiftTerm is about 66,962 lines (`Vendor/SwiftTerm`).
- Size: `Sources/` is about 22.0k lines (LoomCore 11,597, LoomCatalogUI 2,636, loom-app 1,659, loom-probe 2,448, CLoomPOSIX 958, loom-fake-provider 1,034). `Tests/` is about 12.9k lines. `scripts/` is 3,809 lines.

## 1. Module table

Dependencies come from `Package.swift`. Test counts are `@Test` (swift-testing), with no XCTest.

| Target | Responsibility | Key files (lines) | Depends on | Tests |
|---|---|---|---|---|
| CLoomPOSIX (C) | PTY spawn, process table, resource usage, private-XNU coalition and lineage reads, scope signalling, frame IO for the run host | `CLoomPOSIX.c` 416, `RunScope.c` 371, header 171 | none (links `bsm`) | via LoomCoreTests |
| CLoomTestSupport (C) | Test-only helpers | 147 | none | n/a |
| **LoomCore** | The whole non-UI core: process ownership, run scopes, SQLite catalog, runtime, Claude hook and Codex app-server integrations, lifecycle, event hub (30 files) | see section 4 | CLoomPOSIX, sqlite3 | LoomCoreTests: 24 files, 9,757 lines, 280 tests |
| LoomTerminal | SwiftTerm wrapper: `TerminalSurface`, run/quit state, theme, limits | `TerminalSurface.swift` 369, `TerminalRunController.swift` 154, `TerminalTheme.swift` 23 | LoomCore, SwiftTerm (vendored) | LoomTerminalTests: 8 files, 1,583 lines, 39 tests |
| LoomCatalogUI | SwiftUI sidebar and detail pane, `@Observable` `CatalogModel`, `ConversationController` that glues the runtime to terminals, status indicators, UI preferences | `CatalogModel.swift` 828, `SidebarView.swift` 444, `DetailView.swift` 404, `ConversationController.swift` 302, `CatalogTheme.swift` 238, `SessionDisplay.swift` 203, `UIPreferences.swift` 106 | LoomCore, LoomTerminal | LoomCatalogUITests: 5 files, 1,504 lines, 53 tests |
| LoomLaunchOptions | Pure CLI-flag rules: data root, `--evidence`, command-channel name | `LaunchOptions.swift` 64 | none | LoomLaunchOptionsTests: 45 lines, 5 tests |
| loom-app (exe) | `NSApplication` entry, `AppDelegate` (one window, menus, runtime wiring, Quit), `MainSplitViewController`, dev-evidence tooling | `AppDelegate.swift` 946, `DevelopmentEvidence.swift` 351, `EvidenceResourcePool.swift` 281, `MainSplitViewController.swift` 73 | Core, Terminal, CatalogUI, LaunchOptions | none (only evidence scripts) |
| loom-run-host (C exe) | Bundled as `Contents/Helpers/LoomRunHost.app`; one instance per run scope, launched by LaunchServices so it gets a fresh coalition; spawns PTY children and reports exits | `main.c` 334 | CLoomPOSIX, Security, CoreFoundation | via RunScopeTests (assembles a real bundle) |
| loom-hook | Claude hook command helper: reads stdin, sends an authenticated envelope to the Unix socket | `main.swift` 43 | LoomCore | `ClaudeHookTests` |
| loom-probe | Experiment and measurement CLI (Q1 experiments, Codex observer, env) | 11 files, 2,448 lines; `main.swift` 609 | LoomCore | none |
| loom-test-child | Synthetic process fixture, also the "dev terminal" executable | `main.swift` 414 | CLoomTestSupport | n/a |
| loom-fake-provider | Provider-shaped Claude/Codex fixture for tests and `--fake-providers` | `CodexFixture.swift` 751, `main.swift` 283 | none | n/a |
| loom-catalog-fixture | Writes an isolated catalog (dev and acceptance only) | 144 | LoomCore | n/a |

Largest 15 files in `Sources/`, by lines:

| # | File | Lines |
|---|---|---|
| 1 | `LoomCore/ProcessSupervisor.swift` | 1476 |
| 2 | `LoomCore/SessionRuntime.swift` | 1305 |
| 3 | `LoomCore/SessionCatalog.swift` | 1266 |
| 4 | `LoomCore/CodexAppServer.swift` | 1166 |
| 5 | `loom-app/AppDelegate.swift` | 946 |
| 6 | `LoomCatalogUI/CatalogModel.swift` | 828 |
| 7 | `loom-fake-provider/CodexFixture.swift` | 751 |
| 8 | `LoomCore/CodexSessionCoordinator.swift` | 672 |
| 9 | `LoomCore/ClaudeHook.swift` | 659 |
| 10 | `loom-probe/main.swift` | 609 |
| 11 | `LoomCore/RunScope.swift` | 604 |
| 12 | `LoomCore/SessionLifecycleController.swift` | 510 |
| 13 | `LoomCore/LaunchEnvironment.swift` | 462 |
| 14 | `LoomCore/CodexSessionState.swift` | 458 |
| 15 | `LoomCatalogUI/SidebarView.swift` | 444 |

The largest test files are `SessionRuntimeCodexTests` 1548, `ProcessSupervisorTests` 1335, `SessionRuntimeTests` 1053, `SessionLifecycleTests` 771 and `CodexAppServerTests` 690.

- **Dependency graph:** `loom-app` imports CatalogUI, Terminal, Core and LaunchOptions. CatalogUI imports Terminal and Core. Terminal imports Core and SwiftTerm. Core imports CLoomPOSIX only. LaunchOptions is standalone.
- **Layering note:** `ConversationController` and `CatalogModel` are in the UI target but hold `SessionRuntime` and `ProcessSupervisor` directly. `CatalogModel` is AppKit-aware: it imports AppKit, and `ConversationIntents.terminalView` returns `NSView`.
- **Test coverage gaps:**
  - `loom-app` has no unit tests.
  - `MainSplitViewController` and `AppDelegate` are covered only by the `scripts/cp5-*` acceptance scripts (evidence mode).
  - `LoomCatalogUITests` has no view-rendering tests (SidebarView, DetailView).
  - The scripts are mostly Python and zsh and are run manually (not in CI).

LoomCore groups, from the filenames:

- **Ownership and process:** `ProcessSupervisor`, `OwnershipLedger`, `ProcessTable`, `PTYProcess`, `EventDrivenPTYProcess`, `RunScope`, `PreviousRunRecovery`, `ShutdownReport`.
- **Runtime and lifecycle:** `SessionRuntime`, `SessionLifecycleController`, `ManagedSession`, `SessionEventHub`, `ProviderSessionAdapters`.
- **Persistence:** `SessionCatalog`.
- **Terminal I/O:** `TerminalEndpoint`, `TerminalInputQueue`, `TerminalInputGate`.
- **Provider setup:** `LaunchEnvironment`, `EnvironmentResolutionJob`, `ProviderToolchain`, `ProviderLaunchProfile`, `ProviderResume`.
- **Claude:** `ClaudeHook` (server, client, state tracker), `ClaudeRegistry`.
- **Codex:** `CodexAppServer`, `CodexAppServerManager`, `CodexSessionCoordinator`, `CodexSessionState`, `CodexWireDiagnostics`, `CodexRoutingDiagnostics`.

## 2. Main runtime flows

**App launch to catalog**
1. `main.swift` runs `AppDelegate.applicationDidFinishLaunching`.
2. It resolves the data root (`LaunchOptions.resolveDataRoot`; `~/Library/Application Support/Loom[-Dev]`).
3. It opens `SessionCatalog(catalog.sqlite3)` and builds `CatalogModel(events: hub, preferences: ui-preferences.json)`.
4. The window shows immediately (`makeWindow` builds `MainSplitViewController` with the SwiftUI Sidebar and Detail).
5. `startupTask` then runs `startRuntime`, which builds the ledger and `runs/<uuid>/` dir, `ProcessSupervisor.restoring`, and `SessionRuntime` (`start()`).
6. It creates `ConversationController.begin()` (subscribes to the hub), `PreviousRunRecovery` (a background scope check), and `model.start()` (first pages loaded).
7. Opening the app starts no provider or PTY.

**Start Claude session to sidebar indicator**
1. UI: `CatalogModel.startConversation` calls `ConversationIntents.start` (`ConversationController`), which makes a `TerminalSurface` and calls `SessionRuntime.startConversation`.
2. Runtime: it resolves the working directory and `ProviderToolchain` (user shell env via `LaunchEnvironment` and `EnvironmentResolutionJob`), then `ensureHooks`, which starts `ClaudeHookServer` on `~/.loom-dev/h-<id>.sock` with a token.
3. It builds the profile (`--session-id`, per-session `--settings`), then `supervisor.createSession` (catalog insert) and `supervisor.launch`.
4. Launch: `openScope()` runs `RunScopeLauncher.launch`, which does `open -n -g -j LoomRunHost.app`. The host gives a fresh coalition and the app does a handshake with the owner-requirement check.
5. `spawnInScope` has the host spawn the PTY child. `PTYProcess(adoptingPID)` and `TerminalEndpoint` / `EventDrivenPTYProcess` are created, and the ledger is persisted.
6. `ClaudeRegistryReader` watches Claude's registry.
7. Hooks: Claude runs `loom-hook` per event with `LOOM_HOOK_SOCKET`, `LOOM_HOOK_TOKEN` and `LOOM_MANAGED_RUN_ID`. The hook sends an envelope to the `ClaudeHookServer`, then through the bounded `ClaudeHookIngress` (1,024 buffer) to `SessionRuntime.deliver` and `ClaudeSessionAdapter.receive`. The adapter runs `ClaudeHookStateTracker`, which may call `supervisor.adoptConversation` for `SessionStart(clear/fork/resume)`.
8. State: `supervisor.updateProviderWorkState` publishes `SessionEventHub` frames (`.status`, `.runStarted`, ...).
9. UI: `CatalogModel.apply(frame)` uses a sequence fast-path with full-reconcile on gaps. `setLive` updates `SessionRowModel.live`, and `SessionIndicator(record:live:)` plus `IndicatorView` / `ChaseDots` (layer animation) render the status. Run-level changes trigger `scheduleRefresh` (100 ms debounce).

**Terminal output to render**
1. The PTY master fd is read by `EventDrivenPTYProcess`'s `DispatchSourceRead` on its own IO queue.
2. The data goes to the `TerminalOutputSink`, which in the UI is `TerminalOutputBridge` (`TerminalSurface.swift:43`). It feeds SwiftTerm via `TerminalFeedSender.feed` and records counters and a latency histogram.
3. SwiftTerm's frame driver coalesces and draws in `LoomTerminalView` (vendored with 10 local patches).
4. Input path: `TerminalViewDelegate.send` calls `TerminalInputQueue` (4 MiB, ordered) and then `TerminalEndpoint.write`. `TerminalInputGate` lets an automatic idle stop close a run's input atomically.
5. Limits are in `TerminalSurfaceLimits`: scrollback 2,000 lines, OSC 1 MiB, Kitty 8 MiB per screen, inline images 8 MiB / 1,024 per screen.

**Stop and Quit**
- *Stop:* `ConversationController.stop` calls `SessionRuntime.stopConversation` and then `ProcessSupervisor.stop`. The sequence is provider prepare hooks, then freeze and kill of forked scope members, then an ownership resample and a `SessionStopReport`. Codex also runs its companion teardown. A failed stop leaves `stopFailure` visible, and "Stop it again to retry" is shown.
- *Quit:* `applicationShouldTerminate` waits for the startup task, then `beginQuit`. `TerminalRunController.requestQuit` runs a detached `SessionRuntime.shutdown`:
  1. Cancel Codex setup.
  2. Stop lifecycle evaluation and the hook server.
  3. Tear down Codex servers.
  4. `supervisor.shutdown()` (`performShutdown`), which returns a `ShutdownReport`.
  5. The reply is delivered via `RunLoop.main.perform`. On failure the app stays open.
- *Cmd+W:* it only closes the window.

## 3. Process and ownership model

- **Run host (`loom-run-host`):**
  - One instance per run scope (a Codex run's app-server shares its scope).
  - It is launched by LaunchServices into a fresh single-member resource coalition.
  - The app and host talk over a short-lived Unix socket (`~/.loom[-dev]/scopes`) with a token, and the host only serves its owner. `LoomOwnerRequirement` is sealed into the host `Info.plist` and verified in the handshake (`RunScope.verify`).
  - If the Loom connection drops without an orderly EXIT, the host kills its forked members and exits. `PreviousRunRecovery` verifies this next launch.
- **Scope:**
  - `RunScope` (`RunScope.swift`) tracks members through private XNU `proc_pidinfo` flavors read in `CLoomPOSIX`.
  - `RunScopeMember.launchdSpawned` (via the `p_orig_ppidversion` field) separates launchd-spawned members, which are never signalled, from forked work, which is frozen, re-verified and killed.
  - Coalition IDs are recorded with the boot-session UUID. The app's own coalition is never used as a seed.
- **Ledger (`OwnershipLedger`):**
  - It is a Codable struct with `runID`, session leaders, descendants and `scopes: [RunScopeRecord]`. It is persisted to `runs/<uuid>/ledger.json` before any spawn.
  - Processes are marked with environment variables `LOOM_RUN_ID`, `LOOM_SESSION_ID` and `LOOM_MANAGED_RUN_ID`, which are read via `KERN_PROCARGS2` (this works only for non-Apple binaries).
  - Launch refuses if the markers do not match.
- **Identities:** the catalog session id, provider conversation id and run id are kept separate. `run_sessions` and `provider_identity_changes` tables record `/clear`, `/new` and resume transitions. The schema is v2 (`SessionCatalog.schemaVersion`), with tables `sessions`, `runs`, `run_sessions`, `provider_identity_changes` and `projects`; it uses WAL, `quick_check` and a refusal to open newer or foreign schemas.
- **No scope (tests only):** if `scopeLauncher == nil`, ownership is narrowed to session and descendants; a bundled host is required in the app.
- **Crash and Force Quit:** the host stops its scope. Next launch recovers (`PreviousRunRecovery`) and starts nothing.

## 4. Architectural hotspots (facts only)

1. **Large central classes.**
   - `ProcessSupervisor` (1,476 lines, actor) holds about 35 mutable state fields (runtimes, scopes, ledger, stop phases, catalog write tasks, work states, environment jobs) and mixes launch, stop, shutdown, catalog commits and environment capture.
   - `SessionRuntime` (1,305) is one actor that holds Claude hook ingress, a nested `CodexServer` class, Codex setup, teardown and request routing, and run reconciliation. About 570 lines (lines 690 to 1260) are Codex-specific.
   - `SessionCatalog` (1,266) is an actor with a synchronous sqlite3 `CatalogDatabase` and about 29 public API functions.
2. **Paused Codex code is still large and live.**
   - Codex-named LoomCore files total 2,714 lines. They are `CodexAppServer` 1,166, `CodexSessionCoordinator` 672, `CodexSessionState` 458, `CodexAppServerManager` 252, `CodexWireDiagnostics` 105 and `CodexRoutingDiagnostics` 61.
   - `CodexSessionAdapter` is about 150 lines inside `ProviderSessionAdapters.swift`.
   - Adding the 570 Codex lines in `SessionRuntime`, that is about 3,400 lines, roughly 30 percent of LoomCore (inference on the percentage).
   - There are 2,774 lines of Codex-named tests in 5 files (`SessionRuntimeCodexTests`, `CodexAppServerTests`, `...ManagerTests`, `...OptOutTests`, `...RecoveryTests`, `CodexWireDiagnosticsTests`), plus `CodexFixture.swift` (751 lines).
   - The UI still exposes Codex: `SidebarView.swift:390` and `DetailView.swift:181` ("New Codex Conversation"), `AppDelegate.newCodexFromMenu` (line 452) and the `--codex-home` flag. `plans/cp5/UI.md` records a decision to keep it available.
   - `loom-probe` has 137 Codex lines.
3. **Dev and evidence code ships inside the production app target.**
   - About 880 of `loom-app`'s 1,659 lines are evidence tooling: `AppDelegate.swift` lines 697 to 946 (about 250), `DevelopmentEvidence.swift` 351 and `EvidenceResourcePool.swift` 281.
   - These are gated by `--evidence`.
   - The `--fake-providers`, `--fake-toolchain-delay`, `--fail-first-quit` and `LOOM_FORCE_SCOPE_FAILURE` branches also sit in `AppDelegate.runtimeConfiguration` and `startRuntime`.
4. **Quit depends on the dev-terminal controller.**
   - The shutdown closure that calls `SessionRuntime.shutdown` is passed into `TerminalRunController`, which is the CP5-A synthetic terminal state machine (`AppDelegate.swift:128-152, 380`).
   - `applicationShouldTerminate` returns `.terminateNow` if `controller == nil`.
   - So the production quit path is routed through a class whose comments describe it as an A-slice synthetic fixture.
5. **Dev vs production identity logic is duplicated.**
   - `Bundle.main.bundleIdentifier != "local.loom.desktop"` is evaluated in three places (`AppDelegate.swift` lines 113, 234, 402) to choose data dir, socket dir (`.loom-dev` vs `.loom`) and scope dir.
   - The notification prefix `local.loom.desktop.dev.command.` is hard-coded in `LaunchOptions.swift:53`, `scripts/dev-paths.sh:32` and `cp5-d-measure.py:273`.
6. **UI layer coupling.**
   - `CatalogModel` (828 lines) mixes lists and paging, search, selection, projects, rename, event consumption, branch reads and conversation busy state.
   - `ConversationController` talks directly to `SessionRuntime` and `ProcessSupervisor`.
   - `CatalogModel.apply` calls `GitBranch.read` (synchronous file reads) on the MainActor at turn completion (`CatalogModel.swift:688-690`).
7. **Parallel provider structure.**
   - Claude and Codex each have an adapter, tracker and status type (`ClaudeSessionAdapter` / `CodexSessionAdapter`, `ClaudeHookStateTracker` / `CodexEventStateTracker`, `ClaudeSessionStatus` / `CodexSessionStatus`).
   - They feed one generic `ProviderWorkState`. Provider switches such as `startConversation` / `resumeConversation` are explicit in `SessionRuntime`.
8. **Resource and scale facts to measure.**
   - The ownership sample (`sampleOwnership`) scans the process table.
   - The ledger JSON is rewritten via `persistLedger`.
   - Each live Codex session runs its own app-server (the 2 Oct decision, about 110 MiB per CP1).
   - Per-run `runs/<uuid>/` directories are retained when a scope is not shown empty.
   - Catalog paging is tested at 10,000 rows (`CatalogScaleTests`).
9. **Vendored engine.** SwiftTerm is pinned at commit `fe4fb45d…` with 10 patches in `patches/`, and the vendor tree is untracked.
10. **Repo location constraint.** Packages, scratch and fixtures must live outside `~/Documents` (TCC consent prompts for run hosts), and the repo itself is under `~/Documents/github/loom`. This is enforced by `scripts/dev-paths.sh` (`loom_refuse_documents`).

## 5. What is documented where

Documented:
- **Process model and product decisions:** `LOOM-PRODUCT-CONTRACT.md` §3, §6 (run-scope design), §9 (provider integration principles), §10 (resource budgets) and §11 (checkpoints). It is in Turkish. The decision narrative is thorough but is mixed with status.
- **UI contract:** `design/DESIGN.md` §2 to §5 (dimensions, colours, status language), plus the behaviour inventory in §4.
- **Workflow and roles:** `AGENTS.md` (46 lines) and `agents/*` (70 lines).
- **Dev method:** `DEVELOPMENT.md` (43 lines: checks, isolation, signing, measurement).
- **Signing and ownership evidence:** `DEVELOPMENT.md`, `plans/cp5/OWN.md`.
- **SwiftTerm patches:** `Vendor/SwiftTerm/LOOM-VENDOR.md` is good and detailed (12 items).
- **Historical architecture:** `plans/CHECKPOINT-2.md` §18 (the CP2 core, 10 lines). It is partly stale (see below).
- **Evidence-mode command list:** only in the doc comment at the top of `DevelopmentEvidence.swift`.

NOT documented in any repo doc (the code is the only source):
- Target and module map, dependency graph and test layout. The mentions of `LoomCatalogUI`, `LoomTerminal` and `CatalogModel` are scattered across `plans/` history files (for example `C.md` 8 / 5 / 3 hits), and `AGENTS.md`, `DEVELOPMENT.md`, the contract, `STATUS.md` and `CHECKPOINT-5.md` have 0 hits for `SessionRuntime`, `SessionEventHub`, `ProcessSupervisor`, `TerminalSurface`, `LoomCatalogUI`, `CatalogModel`, `ConversationController`, `LoomLaunchOptions`, `loom-run-host` (apart from the `DEVELOPMENT.md` packaging mention), `CLoomPOSIX` and `loom-fake-provider`.
- Runtime flows: launch, start, hook to indicator, output to render, stop and Quit.
- The `SessionRuntime` / `ProcessSupervisor` / `SessionCatalog` / `SessionEventHub` responsibilities and their invariants, for example single ordered hook ingress, run barrier against stale events, MainActor-free rule, event-frame semantics and catalog schema v2.
- How to build, run, test and package: there is no command quick-reference (build, test filter, `scripts/package-dev-app.sh`, acceptance script catalogue, `--evidence` flags, fake providers). `DEVELOPMENT.md` has only `swift test` for the macro plugin and the signing note, and the 17 scripts in `scripts/` have no index.
- Data directories and file layout (`Loom[-Dev]/`, `runs/<id>/`, `catalog.sqlite3`, `ui-preferences.json`, `~/.loom-dev/*.sock`, `~/.loom-dev/codex-home`), dev vs prod bundle ids, and the helper bundle layout of `Loom Dev.app`.
- Test strategy (fixtures, `RuntimeFixture`, what the acceptance scripts cover), CI (none) and release path (none).
- Codex-paused map: which files and UI entries are dormant.

Stale or misleading items (counts):
- `LOOM-PRODUCT-CONTRACT.md:3-4`: "Güncelleme: 2 Ekim 2026" and "uygulama ... henüz tamamlanmadı", while `STATUS.md` is dated 6 Oct and CP5 is nearly closed (1 header block). The §11 status line stops at 28 September.
- `plans/CHECKPOINT-2.md:226` (§18): "İlk Codex lease'inde tek Loom app-server'ı başlar" describes a single shared server. The code and contract §3 (2 Oct) use one app-server per Codex session (1 item). `CHECKPOINT-2.md` is 487 lines and still reads like a current spec.
- `CHECKPOINT-5.md` open-work rows (A and PERF) lag `STATUS.md` (for example PERF "fixture düzeltmesi ve P3 sırada (duraklatıldı)" vs STATUS "Paket I"). The checkpoint file is 69 lines but delegates to the 728-line `CHECKPOINT-5-HISTORY.md` by anchors.
- `DEVELOPMENT.md:43` says Swift 6.4 while `Package.swift` says tools 6.2 (not necessarily wrong).
- `plans/DEVELOPMENT-STARTUP-ISOLATION.md` says "planlandı; uygulanmadı" and its premise (shared app coalition) is superseded by run scopes (1 file, 32 lines; inference that it is obsolete).
- `design/DESIGN.md` §1 and §4 mention the legacy Herdr app and `legacy-code/` as references; §5 overrides §2 in places (the doc itself says so).
- `plans/cp5/C.md` is 875 lines of chronological review rounds. Architecture facts for the runtime exist only inside these rounds.

## 6. Proposed outline for `ARCHITECTURE.md` (at most about 250 lines)

1. **Purpose and status pointer**: one paragraph and a link to `STATUS.md`; how to keep this file current (update when a target, flow or invariant changes).
2. **Repository and target map**: the table of targets (responsibility, key files, dependencies, test target).
3. **Layering rules**: who may import whom; what stays off MainActor; where AppKit is allowed; known exceptions.
4. **Data and file layout**: data roots for dev and prod, `catalog.sqlite3` (schema v2 tables), `runs/<id>/`, sockets, bundle layout and bundle ids.
5. **Process and ownership model**: run host, coalition scope, ledger, markers, stop, Quit, crash recovery; link to contract §6 and `plans/cp5/OWN.md`.
6. **Core runtime**: `SessionRuntime`, `ProcessSupervisor`, `SessionCatalog`, `SessionLifecycleController` and `SessionEventHub`; invariants (identity separation, run barrier, bounded queues, no auto-start).
7. **Provider integrations**: Claude (hook, registry, profile) and Codex (app-server, paused status, dormant file list).
8. **Terminal engine**: output and input paths, limits, SwiftTerm vendoring and patches (link to `LOOM-VENDOR.md`).
9. **UI architecture**: `CatalogModel`, `ConversationController`, views, status indicator derivation, window and quit behaviour; link to `design/DESIGN.md`.
10. **Key flows**: the four arrow flows from section 2 above.
11. **Build, test, package, evidence**: commands, `scripts/` index, `--evidence` flags and fake providers, signing; link to `DEVELOPMENT.md`.
12. **Test map**: per-target coverage, fixtures, and what only the acceptance scripts cover.
13. **Hotspots and known debt**: the list from section 4, with file and line anchors (facts only).
14. **Where decisions live**: contract sections, checkpoint and slice plans, experiments; which source wins on conflict.
15. **Doc maintenance protocol**: which doc each type of change must update.

## Unverified

- I did not build or run anything, so claims about test results and runtime behaviour come from reading code only.
- I did not read `CodexAppServer.swift`, `CodexSessionCoordinator.swift`, `SessionLifecycleController.swift` (past its header) or the vendored SwiftTerm internals in depth. The Codex line shares are line-count estimates.