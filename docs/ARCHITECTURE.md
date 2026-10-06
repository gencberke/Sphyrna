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
| `LoomTerminal` | SwiftTerm wrapper: output bridge, bounded input queue wiring, limits, theme, A-slice run/quit state machine | `TerminalSurface.swift` (`TerminalSurface`, `TerminalOutputBridge`, `TerminalSurfaceLimits`, `LoomTerminalView`), `TerminalRunController.swift`, `TerminalTheme.swift` | `LoomTerminalTests` |
| `LoomCatalogUI` | Sidebar, detail pane, `@Observable` `CatalogModel`, `ConversationController` (runtime to terminals glue), status indicator, UI preferences, git branch read | `CatalogModel.swift`, `ConversationController.swift`, `SidebarView.swift`, `DetailView.swift`, `SessionDisplay.swift` (`SessionIndicator`), `LoomTheme.swift` (all visual tokens; guarded by `scripts/check-theme-literals.sh`), `IndicatorView.swift` (`IndicatorView`, `ChaseDots`, `IndicatorEvidence`), `ProviderIcon.swift`, `UIPreferences.swift`, `GitBranch.swift`, `SettingsView.swift` | `LoomCatalogUITests` |
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
| Ownership and process | `ProcessSupervisor`, `OwnershipLedger`, `ProcessTable`, `PTYProcess`, `EventDrivenPTYProcess`, `RunScope`, `PreviousRunRecovery`, `ShutdownReport` |
| Runtime and lifecycle | `SessionRuntime`, `SessionLifecycleController` (also defines `ProviderWorkState`), `ManagedSession`, `SessionEventHub`, `ProviderSessionAdapters` |
| Persistence | `SessionCatalog` |
| Terminal I/O | `TerminalEndpoint` (also `TerminalOutputSink`), `TerminalInputQueue`, `TerminalInputGate` |
| Provider setup | `LaunchEnvironment`, `EnvironmentResolutionJob`, `ProviderToolchain`, `ProviderLaunchProfile`, `ProviderResume` |
| Claude | `ClaudeHook` (server, client, `ClaudeHookStateTracker`), `ClaudeRegistry` |
| Codex (paused) | `CodexAppServer`, `CodexAppServerManager`, `CodexSessionCoordinator`, `CodexSessionState`, `CodexWireDiagnostics`, `CodexRoutingDiagnostics` |

Roles: `SessionRuntime` is the one application runtime (UI sends intents only). `ProcessSupervisor` (actor) owns runs, scopes,
ledger, stop/shutdown and catalog commits. `SessionCatalog` (actor) is the durable store. `SessionEventHub` (actor) publishes
sequenced frames to subscribers.

## 3. Runtime flows

**App launch to catalog** (`AppDelegate.applicationDidFinishLaunching`)
`LaunchOptions.resolveDataRoot` -> `SessionCatalog(url: catalog.sqlite3)` -> `CatalogModel(events: hub, preferences:
ui-preferences.json)` -> window shown at once (`makeWindow`, `MainSplitViewController`) -> `startupTask`: `startRuntime`
(ledger + `runs/<uuid>/`, `ProcessSupervisor.restoring`, `SessionRuntime.start`, `ConversationController.begin`,
background `PreviousRunRecovery`) -> `model.start()` (first page). Opening the app starts no provider, PTY or terminal.

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

**Quit**
`applicationShouldTerminate` -> waits for `startupTask` -> `beginQuit` -> `TerminalRunController.requestQuit` (shutdown
closure) -> `SessionRuntime.shutdown` (cancel Codex setup, stop lifecycle evaluation + hook server, tear down Codex servers,
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
| `SessionCatalog` | `<data root>/catalog.sqlite3` | SQLite via system `sqlite3`; WAL; `quick_check`; schema v2 (`SessionCatalog.schemaVersion`): `sessions`, `runs`, `run_sessions`, `provider_identity_changes`, `projects`. Refuses newer or foreign schemas; surfaces the failure in the UI instead of starting a runtime |
| UI preferences | `<data root>/ui-preferences.json` | `UIPreferencesStore` (`UIPreferences.swift`); an unreadable file is renamed to `ui-preferences.unreadable-<ts>.json` |
| Run directories | `<data root>/runs/<run uuid>/` | `ledger.json`, `owner.json`, `ownership-guarantee.txt`, created 0700 per app run; removed by `PreviousRunRecovery` once scopes are shown empty |
| Hook socket | `<socket dir>/h-<8 hex of run id>.sock` | `SessionRuntime.ensureHooks`, token-authenticated, removed by `ClaudeHookServer.stop` at shutdown |

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

- Gating lives in `LoomLaunchOptions`: `--evidence <dir>` enables everything below; `--data-root` is valid only together
  with it; a malformed flag refuses the catalog instead of falling back to the default root.
- Evidence-only: `DevelopmentEvidence` (command channel via distributed notification
  `local.loom.desktop.dev.command.<16 hex of SHA-256(realpath(dir))>`, state snapshots, screenshots), `EvidenceResourcePool`,
  the evidence members at the end of `AppDelegate`, `--metal`, `--fixture`, `--fake-providers`, `--fake-toolchain-delay`,
  `--claude-config`, `--codex-home`, `--fail-first-quit`, `LOOM_FORCE_SCOPE_FAILURE`.
- A normal launch never subscribes to the command channel and cannot substitute fixture providers. Command list: doc comment
  at the top of `DevelopmentEvidence.swift` plus the `case`s of its command switch (the header omits `buttons:`, `toggle-fullscreen`, `feed`, `double-start` and `resource:`); scripts and method: `DEVELOPMENT.md` and `scripts/` (`cp5-*.sh|py`, `dev-paths.sh`).

## 8. Codex: paused, not in first release

Code is kept and tested but receives no new development. Locations: `Sources/LoomCore/Codex*.swift` (6 files),
`CodexSessionAdapter` in `ProviderSessionAdapters.swift`, `CodexEventStateTracker` in `CodexSessionState.swift`, the nested `CodexServer` class and Codex
setup/teardown in `SessionRuntime.swift`, `Sources/loom-fake-provider/CodexFixture.swift`, Codex tests in `LoomCoreTests`
(`CodexAppServer*`, `CodexWireDiagnosticsTests`, `SessionRuntimeCodex*`), `loom-probe` Codex files. UI entry points still
exist: "New Codex Conversation" in `SidebarView.swift` and `DetailView.swift`, `AppDelegate.newCodexFromMenu`.
Design fact: one `codex app-server` per Codex session (contract §3).

## 9. Hotspots and scaling notes (facts, no redesign)

- Large actors: `ProcessSupervisor.swift` (1,476 lines, ~35 mutable fields: launch, stop, shutdown, catalog commits, env jobs),
  `SessionRuntime.swift` (1,305; ~570 lines Codex-specific), `SessionCatalog.swift` (1,266; synchronous sqlite on an actor).
- Codex share of `LoomCore`: ~2,700 lines in `Codex*.swift` plus adapter and `SessionRuntime` parts, roughly 30% of the target.
- UI-layer coupling: `ConversationController` and `CatalogModel` hold `SessionRuntime`/`ProcessSupervisor` directly;
  `CatalogModel` (828 lines) mixes paging, search, selection, projects, rename, event consumption and branch reads;
  `CatalogModel` imports AppKit and `ConversationIntents.terminalView` returns `NSView`.
- MainActor git reads: `CatalogModel.apply` calls `GitBranch.read` (synchronous file reads) at turn completion
  (`CatalogModel.swift`, also at selection and refresh).
- Quit path: the production shutdown closure is carried by `TerminalRunController` (`AppDelegate.startRuntime`), a class
  documented as an A-slice synthetic-terminal state machine; with no controller, quit returns `.terminateNow`.
- Duplicated identity checks: `Bundle.main.bundleIdentifier != "local.loom.desktop"` is evaluated in `AppDelegate.dataRoot`,
  `runScopeLauncher` and `runtimeConfiguration`; the notification prefix is repeated in `LaunchOptions.swift`,
  `scripts/dev-paths.sh`, `scripts/cp5-d-measure.py`.
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
