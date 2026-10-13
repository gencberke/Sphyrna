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
| `LoomTerminal` | SwiftTerm wrapper: output bridge, bounded input queue wiring, limits, theme, input rules (image paste, dropped paths, Option as the layout's character layer before Meta), A-slice synthetic-run state machine | `TerminalSurface.swift` (`TerminalSurface`, `TerminalOutputBridge`, `TerminalSurfaceLimits`, `LoomTerminalView`), `TerminalRunController.swift`, `TerminalTheme.swift` (colours as `TerminalRGB`, the 256-colour palette), `TerminalScreenSnapshot.swift` (FB4-3: the kept last screen) | `LoomTerminalTests` |
| `LoomCatalogUI` | Sidebar, detail pane, `@Observable` `CatalogModel`, `ConversationController` (runtime to terminals glue), status indicator, UI preferences, git branch read | `CatalogModel.swift`, `ConversationController.swift`, `SidebarView.swift`, `DetailView.swift`, `SessionDisplay.swift` (`SessionIndicator`), `LoomTheme.swift` (all visual tokens; guarded by `scripts/check-theme-literals.sh`), `IndicatorView.swift` (`IndicatorView`, `ChaseDots`, `IndicatorEvidence`), `ProviderIcon.swift`, `UIPreferences.swift`, `GitBranch.swift`, `BranchCache.swift`, `SettingsView.swift`, `SessionNavigation.swift` (D-45: `AttentionOrder`, `QuitConfirmation`, `SessionShortcut`, `DockBadge`, `SessionCommandText`), `MenuBarState.swift` (H1-F: `MenuBarSummary`, `MenuBarState`, `MenuBarMenu`, derived beside the Dock count), `MenuBarMark.swift` (the mark's path data, `SVGPathParser`, `MenuBarArt` drawing), `MenuBarFace.swift` (status button image and the chase layers), `MenuBarRowText.swift`, `ApprovalNotifications.swift` (`ApprovalNotificationPlanner`, `SettingsNotice`, `SystemIntegration`), `CatalogModel+Navigation.swift` (jumps, next/previous session, Dock badge count, sidebar reveal), `CatalogModel+Subagents.swift` / `SubagentTranscriptModel.swift` / `SubagentTranscriptView.swift` / `SubagentPanelViews.swift` (FB4-5: the subagent panel), `EndedScreens.swift` (`EndedScreenPolicy`), `SessionMenuItems.swift` (Reveal in Finder, Copy Claude Session ID, Copy Resume Command) | `LoomCatalogUITests` |
| `LoomLaunchOptions` | Pure launch rules: data root resolution, `--evidence`, command-channel name | `LaunchOptions.swift` | `LoomLaunchOptionsTests` |
| `loom-app` (exe) | `AppDelegate` (one window, menus, runtime wiring, Quit), `MainSplitViewController`, the menu bar item, needs-approval banners and the login item (H1-F: `MenuBarController`, `ApprovalNotifier`, `SystemServices` behind `NotificationService` / `LoginItemService` protocols, `AppDelegate+System`), dev evidence tooling | `AppDelegate.swift`, `MainSplitViewController.swift`, `MenuBarController.swift`, `ApprovalNotifier.swift`, `SystemServices.swift`, `DevelopmentEvidence.swift`, `EvidenceResourcePool.swift` | none (acceptance scripts in `scripts/`) |
| `loom-run-host` (C exe) | Bundled `Contents/Helpers/LoomRunHost.app`; one instance per run scope; spawns PTY children, reports exits | `main.c` | `RunScopeTests` (assembles a real bundle) |
| `loom-hook` | Claude hook command: reads stdin, sends an authenticated envelope to the hook socket. With arguments it is the agent command `"$LOOM_CLI" open ...` (`OpenSessionCommand` in LoomCore; D-40) | `main.swift` | `ClaudeHookTests`, `OpenSessionCommandTests` |
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
| Logs and diagnostics | `LoomLog` (os.Logger categories, rate limit), `DiagnosticJournal`, `DiagnosticsExport` (bundle, `HookDiagnostics`, `PlanLimitsFailure`), `SessionRuntime+Diagnostics` (launch/quit summary, `collectDiagnostics`), `CatalogBackups` (`CatalogBackupStore`, `CatalogRecovery`), `CrashResidue` (`StaleSocketSweep`), `SessionCatalog+Diagnostics` |
| Provider setup | `LaunchEnvironment`, `EnvironmentResolutionJob`, `ProviderToolchain`, `ProviderLaunchProfile`, `ProviderResume` |
| Claude | `ClaudeHook` (server, client, `ClaudeHookStateTracker`), `OpenSessionProtocol`/`OpenSessionCoordinator`/`OpenSessionCommand`/`LocalSocket` (a session asks Loom to open another one, D-40), `SubagentLedger` (the run's subagent list from `SubagentStart`/`SubagentStop`, `Stop.background_tasks` and each subagent's `meta.json`; D-39; a record also carries the transcript path beside the meta file), `SubagentTranscriptLocation` / `SubagentTranscriptParser` / `SubagentTranscriptTail` / `SubagentTranscriptFeed` (FB4-5: a subagent's live transcript, read-only), `ClaudeRegistry`, `ClaudeDataInventory` (planner and safe deleter of a session's files), `ClaudeProfileLayout`, `ClaudeUsageIndex`, `UsageTranscriptWatcher` (FSEvents over `<profile>/projects`), `ClaudePlanLimitsFetcher` (headless `get_usage` through the Claude CLI) |
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

**Sidebar events, search and redraws** (H1-D2) A frame about one session a visible list already shows (run start/end/detach,
lifecycle, identity, an announced activity stamp) is not a full refresh: after the same 100 ms wait the row is read once
(`SessionCatalog.listedSession`, which skips a session being deleted) and patched (`CatalogModel+Patching`): in place in the
project view (creation order never moves), moved by `last_activity_at` in the activity view (to the top when newest; out of
the loaded range when it now sorts past the list's cursor, the next page delivers it), hidden lists marked stale. Only a
contiguous frame is patched, and the catalog-revision step an activity stamp announces is then covered; a batch (aging), a
skipped frame, a deletion, a session no visible list shows, an open search, a running refresh or a failed read keeps the full
`scheduleRefresh`. A settled search is one `SessionCatalog.searchSessions` read (`CatalogModel+Search`): activity order is the
whole catalog's first page, creation order is a window query (`ROW_NUMBER() OVER (PARTITION BY project_id)`) holding each
project's first page and its cursor, capped at `maxSearchResultRows`; the task's cancellation stops the read. Cards read their own
`SessionRowModel.isSelected` (a selection change evaluates two cards), the relative time sits in `CardTimeLabel` (the minute tick
evaluates only those), and the activity view's day sections are memoised per list, `CatalogModel.today` and `CatalogModel.activeRevision`. The Active
section (FB4-2) takes its membership from `SessionViewState.activePhase`, which `SessionEventHub.publish` derives beside
`unviewedCompletion`; `CatalogModel.updateActive` (`CatalogModel+Active.swift`) keeps the displayed set (`activeIDs`, not
observed) with one O(1) check per live frame and bumps the observed `activeRevision` only when the set changes, so a flip
regroups once and moves one card. The counters are
`CatalogModelStatistics` (`pageQueries`, `listReloads`, `rowPatches`, `searchQueries`) and `SidebarRenderProbe` (card and time
label body evaluations, off unless a test switches it on); tests: `CatalogHotPathTests`, `SidebarRenderTests`,
`SessionCatalogSearchTests`.

**Start a Claude conversation to indicator**
```
CatalogModel.startConversation -> ConversationController.start (creates TerminalSurface)
 -> SessionRuntime.startConversation: working dir, ProviderToolchain (user shell env), ensureHooks
    (ClaudeHookServer on <socketDir>/h-<8>.sock + token), launch profile (--session-id, per-session --settings)
 -> ProcessSupervisor.createSession (catalog insert) -> launch -> openScope (RunScopeLauncher: `open -n -g -j LoomRunHost.app`,
    fresh coalition, owner-verified handshake; scope registered and ledger persisted) -> spawnInScope (host spawns the PTY child)
 -> Claude runs loom-hook per event (LOOM_HOOK_SOCKET/TOKEN, LOOM_MANAGED_RUN_ID)
 -> ClaudeHookServer -> ClaudeHookIngress (bounded 1,024, ordered) -> SessionRuntime.deliver -> ClaudeSessionAdapter.receive
 -> ClaudeHookStateTracker -> ProcessSupervisor.updateProviderWorkState (adoptConversation on /clear, fork, resume;
    SessionStart = at prompt ("Ready"); a late SessionStart of the run's own conversation keeps the turn; informational
    Notification types keep the state; dropped events are logged under subsystem local.loom.desktop, category ClaudeHooks)
    Resume passes the transcript's last recorded effort back as --effort (ClaudeTranscriptEffort; Claude keeps /effort per process)
    Subagents (D-39): SubagentStart/SubagentStop of the run's own conversation feed the tracker's `SubagentLedger` (never the
    status; a subagent's own permission prompt, PermissionRequest or a permission_prompt Notification, shows Needs approval until
    the registry's next "idle" or "busy" sample returns the state from before it (FB2-6); other events with an agent_id stay
    dropped as .childAgent); the adapter reads `meta.json` off the hook path (bounded
    retry after a start, one try at the stop; a workflow's agents keep it in subagents/workflows/<run>/ and count as background) and publishes `.subagents` to the hub; `SessionViewState.subagents` is cleared by a
    new run, a detach and the run's end, and a later update is ignored; SessionListEntry draws `SubagentTreeView` under the card
    Subagent panel (FB4-5): `SubagentMeta.read` also gives the transcript path (the meta file's sibling `agent-<id>.jsonl`, in the run folder for a
    workflow's agent), which the ledger stores on the `SubagentRecord`. A click on a subagent row calls `CatalogModel.openSubagent`; the panel's
    `SubagentTranscriptModel` asks `ConversationIntents.subagentTranscript` (the controller, with `SessionRuntime.claudeProjectsDirectory()`)
    for the file: `SubagentTranscriptLocation.resolve` accepts only `…/subagents/agent-<id>.jsonl` or `…/subagents/workflows/<run>/agent-<id>.jsonl`
    whose `realpath` lies inside the profile's `projects` folder, and the open is read-only with `O_NOFOLLOW` on a regular file of this user.
    `SubagentTranscriptFeed` (one vnode source, started only while the panel is on screen and the window visible, stopped on hide) reads with
    `SubagentTranscriptTail` (only new bytes and only whole lines, a partial last line held back, lines over 128 KiB skipped, a cold open reads the
    last 512 KiB from a line start plus the first line, a shrink or a replaced inode starts over), parses with `SubagentTranscriptParser`
    (a `memmem` gate drops attachment lines, a narrow Decodable never decodes `toolUseResult` and the other bulky duplicates, strings clip at 4 KiB)
    on a utility queue, coalesces writes to at most 5 reads a second and delivers `SubagentTranscriptBatch`es on an AsyncStream; the model keeps the
    last 400 entries and applies one batch as one update. The panel closes with any selection, the subagent's record dropping out and the run's end
 -> SessionEventHub frame -> CatalogModel.apply (sequence fast path, full reconcile on a gap) -> SessionRowModel.live
 -> SessionIndicator(record:live:) -> IndicatorView / ChaseDots in sidebar row and detail header
```

**Hook silence and CLI drift (D-45)**
- *Unknown registry values.* `ClaudeRegistry` no longer requires the registry file's `cwd` to equal the run's folder (identity is pid, process birth, `startedAt` and the session id; a Claude that changes folder, or a case/symlink difference, would otherwise make the read unavailable for good); a non-absolute `cwd` is still refused. An unknown `status` becomes a snapshot the tracker ignores; `ClaudeRegistryDiagnostics` reports each unknown value once (log notice plus a `cli_compat_warning` journal event).
- *Launch profile.* A required option (`--settings`, `--session-id`, `--name`) missing from `claude --help` no longer refuses the start: `ProviderLaunchProfile.missingRequiredClaudeOptions` names it, `SessionRuntime.reportCompatibility` logs and journals it once per run of the app, and Loom starts Claude anyway.
- *Toolchain freshness.* `ExecutableStamp` (inode, mtime, size) is taken before each probe. `SystemProviderToolchains` and the runtime's cache re-resolve when the executable is gone or its stamp changed, and the runtime invalidates the cached toolchain after a launch failure that is not a Loom refusal (`SessionRuntimeConfiguration.toolchainInvalidator`, which `AppDelegate.runtimeConfiguration` points at `SystemProviderToolchains.invalidate`, makes the app's resolver forget its cache too, so the plan-limits ask shares the same fresh answer).
- *Watchdog.* The registry reports "busy" for a run and no hook has reached the adapter since the run started: after `hookSilenceGrace` (3 s) the adapter publishes `ClaudeSessionAdapter.hookSilenceIssue` as the session's `.issue` and journals `hook_silence`. The first hook event for the run clears it. A live terminal shows the issue's text in `SessionIssueNotice` above it (the card alone only says "Problem"; the text otherwise shows on the record view). "Idle" is deliberately not a signal: a Claude at a folder-trust or first-run question runs no hooks. Hook server counters (`HookDiagnostics`: received, applied, wrong token, malformed, lost to overflow, dropped by reason) feed the export. A wrong token gets a one-byte NAK (`ClaudeHookTransportError.rejected` in the client; `loom-hook` logs under category HookClient). A step back of the hook clock clears the ambiguous-clock input state at the next hook with a sane timestamp.
- *Runtime catalog failures.* `markProviderUsed` failing logs (rate-limited) and never blocks the state update; `ProcessSupervisor.queueCatalogFinish` retries `finishRun` three times (120 ms, 350 ms backoff) before leaving it to the next launch's abandoned-run close; `SessionLifecycleController.timerFired` logs a catalog error and reschedules after 30 s.

**A session opens a session (D-40)**
```
Discovery (D-42): SessionRuntime.ensureHooks writes ClaudeLoomPlugin (one skill, loom:open-session) into
    SessionRuntimeConfiguration.claudePluginDirectory (<data root>/claude-plugin; files rewritten only when they differ) when the
    control socket exists; ProviderLaunchProfile adds `--plugin-dir <folder>` when Claude's help lists it. Claude keeps the skill's
    description in context and reads its instructions (the command, its options and result lines) when it uses it.
Claude session runs  "$LOOM_CLI" open --title ... [--ticket K] [--project P] (--message-file F | --message -)   (loom-hook, OpenSessionCommand)
 -> validates the input (OpenSessionInput: title 1-160, ticket 1-40 of [A-Za-z0-9-_.], message <= 64 KiB UTF-8), then connects to
    LOOM_CONTROL_SOCKET (<socketDir>/c-<8>.sock, next to the hook socket; same directory/mode/path-limit rules, LocalSocket) and sends
    one JSON request with LOOM_HOOK_TOKEN + LOOM_SESSION_ID + LOOM_MANAGED_RUN_ID, then waits (up to 90 s, no retry)
 -> OpenSessionControlServer (token check; one connection held per request) -> OpenSessionCoordinator.submit
    authorize (SessionRuntime: supervisor.runContext(run) live, launch card == LOOM_SESSION_ID; the requester is the run's active card),
    validate, resolve the project (the requester's, or --project by exact name/path; never created),
    ticket lookup (SessionCatalog.session(projectID:ticket:): sessions.ticket_key, else a title starting with the key + end/space;
    folded like the catalog search) -> found: reply `exists` at once and publish an "exists" notice, nothing starts
    else one pending request per requesting session (kept in memory only) -> published through SessionRuntime.openRequestUpdates()
 -> UI: approveOpenRequest(id, rows, columns, outputSink) / denyOpenRequest / dismissOpenRequest (the only way anything starts)
    approve re-checks the ticket, then SessionRuntime.startConversation(opening:) -> claudeProfile -> `-n <title> ... -- <message>`
    (prompt after every option, incl. the toolchain's extras), createSession with title (automatic), ticket_key, opened_by
 -> the waiting client is answered on its own connection: started <id> / exists / denied / error; after 85 s it gets `pending` and the
    request stays, so a later approval still starts it; a failed start marks the request failed (never retried)
```
Quit answers every waiting client `unavailable` and drops all requests (memory only). Exit codes of the command: 0 started/exists/pending, 1 denied or approved-but-not-started, 2 usage or validation error, 3 Loom unreachable or not inside a live Loom session.

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
(4 MiB, ordered) -> `TerminalEndpoint.write`; `TerminalInputGate` closes a run's input atomically on automatic idle stop (off in the app: `SessionIdlePolicy.stopsIdleRuns = false`, D-38).
Engine limits live in `TerminalSurfaceLimits` (scrollback 2,000 lines, OSC 1 MiB, Kitty 8 MiB and inline images 8 MiB /
1,024 per screen).

**Ended run's screen (D-45, FB4-3)** A run that ends leaves a snapshot, not a surface: `ConversationController.reconcile` takes `TerminalSurface.captureEndedScreen()` (a `TerminalScreenSnapshot`: grid size and rows of styled text runs, colours resolved to RGB from `TerminalTheme`, bold/italic/underline/strikethrough as styles, dim and inverse applied) and then releases the surface like any ended run, so no `TerminalView`, engine or frame driver stays for an ended session. What is captured, in this order: what the user saw when they pressed Stop (`captureVisibleScreen()`, taken synchronously in `stop()` before any signal), else the alternate screen if the program died inside it, else the latest alternate screen the program left (SwiftTerm patch 14, `onAlternateBufferLeaving`: `?1047l`/`?1049l` clears the alternate buffer, so a copy is taken just before), else the main buffer's visible rows with a tail of scrollback; bounded to 400 rows and 1 MiB per snapshot. Snapshots live in `EndedScreenStore` (`CUI/EndedScreens.swift`): memory-only, least recently used out first, at most 16 and 4 MiB together, independent of the selection and the tabs (a stopped session whose tab closed still shows its screen when selected). `DetailContent` shows `EndedScreenNotice` (Resume, Show Details) above `EndedScreenView` (`CUI/EndedScreenView.swift`: a selectable, read-only `NSTextView` in the terminal's font and background, vertical scroll, no timer or engine). Resume, Show Details, delete (`CatalogModel.forget`) and quit drop the snapshot; nothing is persisted, so a relaunch shows the record view (contract §8).

**Terminal ownership per frame (H1-D1)** `ConversationController.reconcile(_:)` compares each live terminal with the frame's `SessionEventFrame.sessions`: an entry whose owner's `runID` is its run needs nothing; only an entry the frame does not show is confirmed with the supervisor (`ownerLookup`, one `activeSessionID` call) and then handled as before (run ended: kept ended screen or `runEnded()`; owner moved: `tabOwnerMoved`). This holds because `ProcessSupervisor` changes `activeSessionID` before it publishes `runStarted`/`runDetached`, removes the run before `runEnded`, and the hub keeps the newest frame with full states; the adoption path (`adopt`, a failed start) reconciles against a fresh `SessionEventHub.snapshot()`.

**Finished turn and usage (H1-D1)** `UsageModel.refresh(reason: .turnComplete)` asks for a full transcript walk only when `setTranscriptWatcherRunning(false)` (the stream failed to start or the profile has no `projects` folder, set in `AppDelegate+Usage`). With the watcher running, the turn's own transcript write arrives through `UsageTranscriptWatcher` -> `transcriptsChanged` and `refreshChanged` reads just those files; the full walk stays for launch, activation after being stale, the watcher's `needsFullScan`, a day change, the Settings page opening and the manual refresh.

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
`ProcessSupervisor.shutdown` -> `ShutdownReport`). A user-initiated quit with a session Working or Needing approval first asks "Quit Loom and stop N working sessions?" (`QuitConfirmation`; Cancel is the default; never for a system-initiated quit, read from `keyAEQuitReason`, nor in evidence runs). Unverified shutdown keeps the app open with Try Again, Keep Loom Open and Quit Anyway (the next quit returns `.terminateNow` without a verified shutdown; processes Loom could not stop may keep running); a system-initiated quit is never held up by an unverified shutdown (the report is still written). Cmd+W only
closes the window; the runtime keeps running. `SessionRuntime.shutdown` journals a `quit` summary (counts of processes signalled, errors and whether it succeeded; no process records) and cancels a backup in progress.

**Previous-run recovery**
`PreviousRunRecovery.recover(runsDirectory:current:)` (background, never starts anything): for each other `runs/<uuid>/` whose
`owner.json` process is not alive, read `ledger.json`, drain this-boot coalitions (kill only forked members), delete the
directory when every scope is shown empty; leftovers surface as `CatalogModel.ownershipNotice`, keep their directory and get a `recovery-error.txt`. A run directory whose ledger cannot be read is reported once (`Report.quarantinedDirectories`) and moved to `runs/quarantine/<name>` (newest 10 kept, skipped by later passes). The recovery report is journaled (`recovery`) only when something happened.

**Crash residue at runtime start** (`SessionRuntime.start`, before the first hook server is made)
`StaleSocketSweep` unlinks `h-*.sock`/`c-*.sock` in the socket directory only when the file is a socket owned by the user and `connect()` is refused (nothing listens); the current run's own prefix is skipped. `SessionCatalog.closeAbandonedRuns` ends runs still open in the catalog whose leader is not alive (birth identity checked) with the existing end reason `applicationQuit` and no exit status; a run whose leader is alive stays open. Both journal `recovery_sockets` / `recovery_runs_closed` with counts.

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
| `SessionCatalog` | `<data root>/catalog.sqlite3` | SQLite via system `sqlite3`; WAL; `quick_check`; `secure_delete = ON` per connection; schema v3 (`SessionCatalog.schemaVersion`): `sessions` (+ `stale_since`; `last_activity_at`, `ticket_key`, `opened_by` are added on open without a version bump so 0.2.1/0.3.0 still open the catalog: `ensureActivityColumn`, `ensureOriginColumns`), `runs`, `run_sessions`, `provider_identity_changes`, `projects` (+ nullable `color`, D-48, added on open the same way by `ensureProjectColors`: a `ProjectTone` name, `none`, or NULL, which gets the least-used tone, oldest project first, on every open and on `addProject`; an unknown value is kept and shows neutral; `setProjectTone`), `deletions`, `app_state`. Refuses newer or foreign schemas; surfaces the failure in the UI instead of starting a runtime |
| UI preferences | `<data root>/ui-preferences.json` | `UIPreferencesStore` (`UIPreferences.swift`); an unreadable file is renamed to `ui-preferences.unreadable-<ts>.json` |
| Run directories | `<data root>/runs/<run uuid>/` | `ledger.json`, `owner.json`, `ownership-guarantee.txt`, created 0700 per app run; removed by `PreviousRunRecovery` once scopes are shown empty |
| Diagnostic journal | `<data root>/diagnostics/journal.jsonl`, `journal.1.jsonl` | `DiagnosticJournal.forDataRoot`: one JSON object per line, rare events only (`launch`, `claude_cli`, `quit`, `recovery*`, `cli_compat_warning`, `hook_silence`, `catalog_backup`, `catalog_restore`, `diagnostics_export`), no session content; at 512 KB the file becomes `journal.1.jsonl` and anything older is pruned on the write; files 0600 in a 0700 folder |
| Diagnostics exports | `<data root>/diagnostics/exports/loom-diagnostics-<stamp>/` | `DiagnosticsExport.collect(to:)`: `summary.json`, the journal files, `log.ndjson` (last 24 h of subsystem `local.loom.desktop` limited to processes whose image lives inside the running app's bundle (`processImagePath BEGINSWITH "<bundle>/"`, so `swift test` runs and the other flavor are left out), 5 MB cap, 30 s timeout); at most 3 kept (only folders carrying the export marker are pruned) |
| Catalog backups | `<data root>/backups/catalog-<yyyyMMdd-HHmmss-SSS>.sqlite3` | `CatalogBackupStore`: `VACUUM INTO` (second connection, off the main thread, `quick_check` before the rename) at most once per 24 h, 3 newest kept; deleting a session removes all backups and takes a fresh one (no backup keeps a permanently deleted session) |
| Damaged catalog | `<data root>/catalog.damaged-<stamp>.sqlite3` (+ `-wal`, `-shm`) | Set aside by `CatalogRecovery.restore` / `startFresh`; never read again. Every permanent deletion removes them (each copy and its `-wal`, `-shm`: `CatalogBackupStore.purgeDamagedCopies`, called beside `purgeAll` in `SessionCatalog.finishDeletion` and `deleteSessionRows`, so a deletion that resumes after a crash does too), because a damaged copy can still hold the deleted session (contract §8); until then the launch prompt says it is kept |
| Quarantined run directories | `<data root>/runs/quarantine/` | Run directories with an unreadable ledger, newest 10 |
| Hook socket | `<socket dir>/h-<8 hex of run id>.sock` | `SessionRuntime.ensureHooks`, token-authenticated, removed by `ClaudeHookServer.stop` at shutdown |
| Control socket | `<socket dir>/c-<8 hex of run id>.sock` | `SessionRuntime.ensureHooks`, same token, request/response for `loom-hook open` (D-40); removed by `OpenSessionControlServer.stop` at shutdown |

**Backup and restore.** `SessionCatalog.backupStore` (derived from the catalog's folder) backs up through `scheduleCatalogBackup` 10 s after runtime start (`SessionRuntimeConfiguration.catalogBackupDelay`) and forced after a deletion. A generation counter discards a copy that was being written when a deletion finished. When opening the catalog fails with `SessionCatalogError.isDamaged` (corrupt or not a database), the launch prompt (`AppDelegate.offerCatalogRecovery` in `AppDelegate+Diagnostics.swift`, an `NSAlert` run before the window or the runtime exist; what it says and which buttons it has come from `CatalogRecoveryPrompt.make(backups:)`, a pure function) lists `CatalogRecovery.backups(forCatalogAt:)` and offers "Restore Backup" (only when a backup exists; the newest, named by date), "Start Fresh" (`startFresh(catalogAt:)`) and "Quit"; after a restore or a fresh start the launch goes on with the reopened catalog, a failed recovery falls back to the usual catalog-error screen, and any other open error (newer schema, busy, foreign) gets no offer. Restore copies the backup to `catalog.sqlite3.restoring`, verifies it, sets `-wal`, `-shm` and the main file aside as `catalog.damaged-<stamp>.sqlite3` (the sidecars first, so a stray WAL is never replayed into another main file) and renames the copy into place; `SessionCatalog.init` finishes an interrupted restore from the files left on disk.

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
- **Current patches (14):** inline-image-quota, buffer-diagnostics, frame-signal-coalescing, ascii-text-presentation-guard,
  direct-glyph-runs, direct-glyph-blank-skip, direct-run-continuation, partial-row-invalidation, suspended-signal-retention,
  identical-row-skip, open-keydown, alt-screen-capture (FB4-3). Tests in `LoomTerminalTests` (`FrameDriverTests` in `TerminalFrameDriverTests.swift`, `TerminalPartialDrawTests`,
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
- UI-layer coupling: `ConversationController` (live terminals plus up to 8 kept ended screens) and `CatalogModel` hold `SessionRuntime`/`ProcessSupervisor` directly;
  `CatalogModel` (828 lines) mixes paging, search, selection, projects, rename, event consumption and branch reads;
  `CatalogModel` imports AppKit and `ConversationIntents.terminalView` returns `NSView`.
- Launch measurements (F5, release package, 5 runs each, `scripts/perf/launch_paint.py`): window creation (`WindowShown`,
  ~125-136 ms) dominates app delegate to first page; catalog open including `PRAGMA quick_check` is 0.7 / 1.5 / 8 ms at 0 /
  1,000 / 10,000 rows, so it stays on the main thread. Git branch reads are off the main actor (`BranchCache`).
  `CatalogModel.scheduleRefresh` still reloads every loaded row of every visible list on run/lifecycle frames (a row-level
  refresh is a follow-up).
- Logging and diagnostics (D-45): `LoomLog` categories under subsystem `local.loom.desktop` (Lifecycle, Catalog, ClaudeHooks, Registry, Toolchain, Scope, Usage, Recovery, Quit, Diagnostics, HookClient for the `loom-hook` process). Notice and error levels are for transitions and failures; per-event detail is `debug`; ids, counts, durations and error categories are public, user paths private; a repeating error is rate-limited to once a minute per key (`LogRateLimiter`). Loom writes no log files of its own; the only files are the journal and exports above. Cost: a logger call without a listener is a cheap level check, a journal write is one `O_APPEND` line on a rare event, a backup is at most one `VACUUM INTO` a day off the main thread. Entry points: Help > Collect Diagnostics… and Settings > About > Collect Diagnostics… share one `DiagnosticsCollection` (LoomCatalogUI; one export at a time, both disabled while it runs and before the runtime exists) that `AppDelegate+Diagnostics.swift` points at `SessionRuntime.collectDiagnostics(to: DiagnosticsExport.defaultFolder(dataRoot:), usage:, planLimitsFailure:)` (the facts come from `UsageModel.diagnosticsSnapshot()`), then reveals the folder in Finder; a failure shows a modal alert with the error category only. The Usage page shows the same two facts: "Plan limits unavailable" with a short reason while the last ask failed (`UsageModel.limitsFailure`, cleared by a success; an earlier answer stays with "could not refresh"), and one line "N usage records could not be understood, so totals may be low" (`UsageModel.linesNotUnderstood`). Known limits: the usage scan's not-understood line total and `PlanLimitsFailure` are per app run; the journal records the Claude CLI version/capabilities at the first toolchain resolution (`claude_cli`), not at launch.
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
