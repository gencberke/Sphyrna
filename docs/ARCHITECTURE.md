# Loom architecture

Loom is a native macOS 27 app (Swift 6.2 tools, SwiftPM, SwiftUI + AppKit, vendored SwiftTerm) that hosts Claude Code
terminals in one window and tracks their conversations in a local catalog. Every provider process is started inside a
Loom-owned run scope, so Loom can stop exactly what it started, and nothing else, on stop, quit, or after a crash.
The exceptions are a few short-lived helpers that run outside a scope; Section 4 lists them.
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
LoomChat (v2 chat engine: stream-json protocol, TurnModel, TranscriptLens, TranscriptGrowthFeed, the Chat-face driver; no UI, spawns nothing) -> LoomCore; LoomCatalogUI links it (the Chat view, V13)
helpers: loom-run-host (C, bundled LoomRunHost.app) -> CLoomPOSIX;  loom-hook -> LoomCore
dev/test only: loom-test-child, loom-fake-provider, loom-catalog-fixture, loom-probe
```

Rules: `LoomCore` imports no UI framework and keeps process/PTY/wait work off MainActor. Dependencies only point down the
diagram. AppKit appears only in `LoomTerminal`, `LoomCatalogUI` and `loom-app`. `LoomChat` imports `LoomCore` and no UI
framework (`LoomCatalogUI` imports `LoomChat`, never the other way round); starting and stopping the `claude` process stays in `LoomCore`'s supervisor (pipe children, Section 4).

## 2. Targets

Declared in `Package.swift`; all tests use swift-testing (`@Test`). Product bundle layout: `scripts/package-dev-app.sh`.

| Target | Responsibility | Key types / files | Tests |
|---|---|---|---|
| `CLoomPOSIX` (C) | PTY spawn, process table, `proc_pidinfo`/coalition reads (private XNU flavors), env marker reads (`KERN_PROCARGS2`), scope signalling, run-host frame IO | `CLoomPOSIX.c`, `RunScope.c`, `include/` | via `LoomCoreTests` |
| `CLoomTestSupport` (C) | Test-only helpers for `loom-test-child` | `CLoomTestSupport.c` | none |
| `LoomCore` | Everything non-UI: runtime, supervisor, catalog, ownership, hook server, provider setup, lifecycle, event hub | see below | `LoomCoreTests` |
| `LoomTerminal` | SwiftTerm wrapper: output bridge, bounded input queue wiring, limits, theme, input rules (image paste, dropped paths, Option as the layout's character layer before Meta), A-slice synthetic-run state machine | `TerminalSurface.swift` (`TerminalSurface`, `TerminalOutputBridge`, `TerminalSurfaceLimits`, `LoomTerminalView`), `TerminalRunController.swift`, `TerminalTheme.swift` (colours as `TerminalRGB`, the 256-colour palette), `TerminalScreenSnapshot.swift` (FB4-3: the kept last screen) | `LoomTerminalTests` |
| `LoomCatalogUI` | Sidebar, detail pane, `@Observable` `CatalogModel`, `ConversationController` (runtime to terminals glue), status indicator, UI preferences, git branch read | `CatalogModel.swift`, `ConversationController.swift`, `SidebarView.swift`, `DetailView.swift`, `SessionDisplay.swift` (`SessionIndicator`), `LoomTheme.swift` (all visual tokens; guarded by `scripts/check-theme-literals.sh`), `IndicatorView.swift` (`IndicatorView`, `ChaseDots`, `IndicatorEvidence`), `ProviderIcon.swift`, `UIPreferences.swift` (incl. `searchSessionText`, default on, read by the palette's text search), `GitBranch.swift`, `BranchCache.swift`, `SettingsView.swift`, `SessionNavigation.swift` (D-45: `AttentionOrder`, `QuitConfirmation`, `SessionShortcut`, `DockBadge`, `SessionCommandText`), `MenuBarState.swift` (H1-F: `MenuBarSummary`, `MenuBarState`, `MenuBarMenu`, derived beside the Dock count), `MenuBarMark.swift` (the mark's path data, `SVGPathParser`, `MenuBarArt` drawing), `MenuBarFace.swift` (status button image and the chase layers), `MenuBarRowText.swift`, `ApprovalNotifications.swift` (`ApprovalNotificationPlanner`, `SettingsNotice`, `SystemIntegration`), `CatalogModel+Navigation.swift` (jumps, next/previous session, Dock badge count, sidebar reveal), `CatalogModel+Subagents.swift` / `SubagentTranscriptModel.swift` / `SubagentTranscriptView.swift` / `SubagentPanelViews.swift` (FB4-5: the subagent panel), `EndedScreens.swift` (`EndedScreenStore`, FB4-3), `EndedScreenView.swift` (the static last screen), `SessionMenuItems.swift` (Reveal in Finder, Copy Claude Session ID, Copy Resume Command). **Shell menu:** `ShellMenu.swift` (`ShellMenuTarget`, the target of the View-menu `ShellCommand` items, moved here from `loom-app`). **Sidebar v2 (V04):** `HomeRow` and `SessionReasonLine.swift` (the Active card's reason line, from `SessionRowModel.reason` and `inActiveSection`), `SidebarDraftRows.swift` (`DraftRows` over `visibleDrafts`), `ChromeButtonStyle.swift`, `RowButtonStyle.swift`, `KeyboardNavigation.swift`, `LoomTheme+Sidebar.swift`. **Command palette (V06):** `PaletteView.swift`, `PaletteRanking.swift`, `PaletteSources.swift`, `PaletteItem.swift` (with `PaletteFoldCache`), `PaletteAction.swift`, `PaletteTranscriptSearch.swift` and `PaletteState` in `CatalogModel+Palette.swift`. **New session (V07):** `CatalogModel+NewSession` (`NewSessionState`: draft slots, presets, last used, launched choices; `NewSessionIntents`), `NewSession*.swift` (store, defaults, ticket pattern, composer, text view), `DraftSessionView`; `LoomCore`: `NewSessionLaunch`, `ClaudeLaunchChoices`, `GitWorkspace`. **Inspector and Agents (V09):** `InspectorContainer.swift` (the column, tabs, header toggle), `InspectorState.swift`, `InspectorOverview.swift`, `InspectorAgents.swift`, `InspectorParts.swift`, `LoomTheme+Inspector.swift`. **Home (V05):** `HomeView.swift` (`HomeLayout`, the route), `HomeStartBox.swift`, `HomeSections.swift` (cards, Needs you, Finished, plan limits, Today, Continue), `HomeEmptyStates.swift`, and `HomeState`, `HomeBoard` and `refreshHome` in `CatalogModel+Home.swift`. **Project page (V08):** `ProjectPageView.swift`, `ProjectSessionViews.swift`, `ProjectBranchViews.swift` (with the Instructions tab), `ProjectLastLine.swift`, `ProjectInstructions.swift`, `ProjectGitRefs.swift`, `LoomTheme+ProjectPage.swift`, and `ProjectPageState` in `CatalogModel+ProjectPage.swift`. **Chat (V13):** the `Chat/` folder (below) | `LoomCatalogUITests` |
| `LoomCatalogUI/Chat/` (V13) | The read-only chat stream view of a Claude session: the transcript read as chat. Entry `ChatTranscriptView` (public; the session id, the profile's config directory, the working directory, whether the session works, a subagent callback and a fallback view for a session whose transcript does not resolve). `ChatTranscriptModel` finds the file (`ClaudeTranscriptLocator`), cold-opens the newest turns through LoomChat's `TranscriptLens` into a `TurnModel`, derives rows with `ChatRowBuilder` (stable row ids; turn folds, group summaries, the live row, the changed-files card) and follows the file with `TranscriptGrowthFeed` only while the view is on screen and the window visible; `ChatStreamController` is a view-based `NSTableView` in Loom's own scroll view (virtualized rows, cached heights, `ChatScrollLatch`). Markdown is a small block parser plus `AttributedString(markdown:)`; tokens in `LoomTheme+Chat.swift`. The `.chat` route mounts it through `SessionChatView` (outside this module, `LoomCatalogUI/SessionChatView.swift`): its fallback is the kept screen, else the record; a pending approval stays answerable above it and a stopped session gets a "not running" notice with Resume; `ChatRouteKey` re-keys the view while it shows the fallback and the run or status changes; `CatalogModel.claudeConfigDirectory` (set by the app) says where transcripts are; `SessionFaces.readOnlyChatEnabled` is on by default and is the kill switch. **Live view (V16):** a session with a pipe run mounts `LiveChatView` (`LiveChatFeed`, one per driver, owns the session's `ChatPresentation`) instead of `ChatTranscriptView`; the model's side is `CatalogModel+LiveChat.swift` (see "Chat driver and live view (V16)" in Section 3). Rules: `design/DESIGN.md` §7 | `Chat/*.swift` (`ChatTranscriptView`, `ChatTranscriptModel`, `ChatRowBuilder`, `ChatStreamController`, `ChatScrollLatch`, `ChatMarkdown*`, `ChatWork*`, `LiveChatFeed`, `LiveChatView`) | `LoomCatalogUITests` (`Chat*Tests`) |
| `LoomChat` | v2 chat engine, four layers, no UI and no process spawning (it spawns nothing; `LoomCatalogUI` links it for the Chat view). **Protocol/**: `StreamJSONDecoder` (NDJSON framing of Claude's stdout in chunks of any size, a bounded memory per line, an oversized or malformed line becomes a frame instead of an error), `StreamMessage`/`StreamTypes` (unknown types are kept as `unknown`, never fatal), `OutgoingUserMessage`, `ControlChannel` (control requests and responses by request id: timeout, cancel, closed, capability check against `system/init`) and `ControlMessages`. **Model/**: `TurnModel` (a value type: one chronological list of `ChatEntry` rows and their turns, fed by `apply(_:)` for live `StreamMessage`s and `apply(record:)` for transcript lines; every change returns a `ModelDelta`; ids are stable across live and transcript, so one renderer serves both), `ClippedText`, `ThoughtLine`. **Lens/**: `TranscriptLens` (an actor that fills a `TurnModel` from a transcript file: the newest turns first, older ones on demand, growth when the owner calls `readGrowth()`; stopped sessions, terminal sessions and subagent transcripts) and `TranscriptGrowthFeed` (follows one transcript file for a view that shows it: a vnode source, nothing exists before `start()` or after `stop()`; a burst of writes is read once, 50 ms after the first, and each read is `TranscriptLens.readGrowth()`; a watch that cannot be made, such as a replaced file that does not exist yet, is retried after 0.25 s and then at doubling intervals up to 5 s). **Driver/** (V16): `ChatSessionDriver` (an actor: the Chat-face run's stdin and stdout, its `TurnModel`, queue and waiting requests), `ChatSessionHost` (the app's registry of drivers), `ChatPipeSink` (the run's `PipeOutputSink`), `ChatQueue` (the "After this turn" queue and its file store), `ChatBackgroundTasks`, `ChatDriverTypes`; `Model/LiveHistoryJoin.swift` joins the transcript's history with the live model | `Protocol/`, `Model/`, `Lens/`, `Driver/` | `LoomChatTests` |
| `LoomLaunchOptions` | Pure launch rules: data root resolution, `--evidence`, command-channel name | `LaunchOptions.swift` | `LoomLaunchOptionsTests` |
| `loom-app` (exe) | `AppDelegate` (one window, menus, runtime wiring, Quit), `MainSplitViewController`, the menu bar item, needs-approval banners and the login item (H1-F: `MenuBarController`, `ApprovalNotifier`, `SystemServices` behind `NotificationService` / `LoginItemService` protocols, `AppDelegate+System`), dev evidence tooling | `AppDelegate.swift`, `MainSplitViewController.swift`, `MenuBarController.swift`, `ApprovalNotifier.swift`, `SystemServices.swift`, `DevelopmentEvidence.swift`, `EvidenceResourcePool.swift` | none (acceptance scripts in `scripts/`) |
| `loom-run-host` (C exe) | Bundled `Contents/Helpers/LoomRunHost.app`; one instance per run scope; spawns PTY children, reports exits | `main.c` | `RunScopeTests` (assembles a real bundle) |
| `loom-hook` | Claude hook command: reads stdin, sends an authenticated envelope to the hook socket. With arguments it is the agent command `"$LOOM_CLI" open ...` (`OpenSessionCommand` in LoomCore; D-40) | `main.swift` | `ClaudeHookTests`, `OpenSessionCommandTests` |
| `loom-test-child` | Synthetic process fixture and the dev "terminal"; its `pipe-*` modes are the pipe protocol fixtures | `main.swift` | used by many tests |
| `loom-fake-provider` | Provider-shaped Claude/Codex fixture for tests and `--fake-providers`; its chat mode is a scripted stream-json engine for LoomChat. Never bundled | `main.swift`, `CodexFixture.swift`, `ChatEngine.swift`, `ChatScenarios.swift`, `ChatWire.swift` | `FakeProviderChatTests` (in `LoomCoreTests`) |
| `loom-catalog-fixture` | Writes an isolated catalog for acceptance. Never bundled | `main.swift` | n/a |
| `loom-probe` | Experiment/measurement CLI (Q1 experiments, Codex observer) | `main.swift` + 10 files | none |

`LoomCore` groups (all under `Sources/LoomCore/`):

| Group | Files |
|---|---|
| Ownership and process | `ProcessSupervisor` (core plus `+Stop`, `+Shutdown`, `+Sampling`, `+Scopes`, `+EnvironmentJobs`, `+CatalogCommits`), `OwnershipLedger`, `ProcessTable`, `PTYProcess`, `EventDrivenPTYProcess`, `RunScope`, `PreviousRunRecovery`, `ShutdownReport`, `AppShutdownCoordinator` |
| Runtime and lifecycle | `SessionRuntime` (core plus `+Claude`, `+Codex`, `+Chat` (V16: starts and resumes a pipe run and hands it to its driver), `+OpenRequests`: the approval API for a session's request to open another one, D-40), `ConversationDeletion` (`SessionRuntime` deletion flow, `ConversationForgetting`), `SessionLifecycleController` (also defines `ProviderWorkState`), `ManagedSession`, `SessionEventHub`, `ProviderSessionAdapters` |
| Persistence | `SessionCatalog` (core plus `+Sessions`, `+Runs`, `+Projects`, `+Titles`, `+Paging`, `+Deletions`: the deletion API and its state machine, `+Home`: the Continue, today-count and last-used-project reads), `CatalogDatabase` (schema, migration, SQLite helpers), `ProjectTone` (the project colour palette's names, D-48) |
| Retention | `CleanupPlanner` (`CleanupPolicy`, the cleanup arithmetic of DP-CP4-2, and which stale sessions are eligible), `CleanupCoordinator` (worktree protection, DP-CP4-3, and the rows of the cleanup review); the review (CP4-G) stays in development builds until DP-CP4-2 |
| Terminal I/O | `TerminalEndpoint` (also `TerminalOutputSink`), `TerminalInputQueue`, `TerminalInputGate` |
| Pipe children | `StdioProcess` (stdin/stdout/stderr pipes of one child: bounded stdin queue, both outputs always drained, `PipeOutputSink`), `PipeEndpoint` (the run-scoped IO capability beside `TerminalEndpoint`; also `RunEndpoint`, the supervisor's `terminal` or `pipe` case) |
| Transcripts | `ClaudeTranscriptFile` (`ClaudeTranscriptLocator`: `<profile>/projects/<folder>/<session id>.jsonl`, checked right before it is opened; `openOwnRegularFile`, shared with the subagent tail), `ClaudeTranscriptReader` (a main or subagent transcript read backward in bounded pages and forward for growth; a line over the cap is reported by offset and length, not read), `TranscriptLineSplitter` (whole lines from file bytes, shared with `SubagentTranscriptTail`), `JSONValueAccess` (nil-on-mismatch access to `JSONValue`) |
| Logs and diagnostics | `LoomLog` (os.Logger categories, rate limit), `LoomSignposts` (launch and sidebar signposts), `DiagnosticJournal`, `DiagnosticsExport` (bundle, `HookDiagnostics`, `PlanLimitsFailure`), `SessionRuntime+Diagnostics` (launch/quit summary, `collectDiagnostics`), `CatalogBackups` (`CatalogBackupStore`, `CatalogRecovery`), `CrashResidue` (`StaleSocketSweep`), `SessionCatalog+Diagnostics` |
| Provider setup | `LaunchEnvironment`, `EnvironmentResolutionJob`, `ProviderToolchain`, `ProviderLaunchProfile`, `ProviderResume` |
| New session (V07) | `NewSessionLaunch` (the first send of a draft: message, optional title and ticket, `ClaudeLaunchChoices` for `--permission-mode` and `--model`, `SessionWorkspace`), `GitWorkspace` (creates the branch or worktree a draft asked for, through a short `git` child, Section 4) |
| Claude | `ClaudeHook` (server, client, `ClaudeHookStateTracker`), `OpenSessionProtocol`/`OpenSessionCoordinator`/`OpenSessionCommand`/`LocalSocket` (a session asks Loom to open another one, D-40), `SubagentLedger` (the run's subagent list from `SubagentStart`/`SubagentStop`, `Stop.background_tasks` and each subagent's `meta.json`; D-39; a record also carries the transcript path beside the meta file), `SubagentTranscriptLocation` / `SubagentTranscriptParser` / `SubagentTranscriptTail` / `SubagentTranscriptFeed` (FB4-5: a subagent's live transcript, read-only), `ClaudeRegistry`, `ClaudeDataInventory` (planner and safe deleter of a session's files), `ClaudeProfileLayout`, `ClaudeUsageIndex` (with `ClaudeUsageParser`, `UsageSnapshot` and `UsagePricing`, the models' list prices for the cost estimate; it also answers the latest main-thread message of a session, `SessionContext`, for the context ring), `UsageTranscriptWatcher` (FSEvents over `<profile>/projects`), `ClaudePlanLimitsFetcher` (headless `get_usage` with `skip_behaviors:true` through the Claude CLI, and `PlanPace`, the pace of a window against its elapsed time) |
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
regroups once and moves one card. "Not read" is one rule on every surface: `activePhase` makes a new failure `endedUnread` (also when no turn was seen under way before it) unless the user is looking, and `CatalogModel.attentionCandidates` (`CatalogModel+Navigation.swift`) drops a failed session that is not `endedUnread`, so a viewed failure leaves Active, Home's lists, the Dock badge and the jump set together while its card keeps the red dot. The counters are
`CatalogModelStatistics` (`pageQueries`, `listReloads`, `rowPatches`, `searchQueries`) and `SidebarRenderProbe` (card and time
label body evaluations, off unless a test switches it on); tests: `CatalogHotPathTests`, `SidebarRenderTests`,
`SessionCatalogSearchTests`.

**Detail pane layout** `detailInspector(model:)` (`InspectorContainer.swift`) reads the pane's width once and asks the pure `InspectorPlacement.of(open:detailWidth:)` for closed, column or overlay (overlay below `LoomTheme.Inspector.minimumContent`, 480 pt, beside the 328 pt inspector). The content is one view in every placement, given its width explicitly in the same pass, so crossing the threshold changes that width once and an overlay resizes nothing. The chat's `ChatScrollView.tile()` refits the table's one column to the stream's visible width on every layout pass (`ChatStreamController.fitColumnToView`); the table otherwise keeps a wider column after the pane shrinks and cuts rows at the right edge. Dates and times become text only through `LoomDateFormat` (system locale, one cached formatter per kind, locale, calendar and zone); the pure helpers that format them (`DayGrouping.title`, `CatalogRecoveryPrompt.date`, `UsageText`, `ChatTime`) take a locale so tests pin one.

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
    status; a subagent's own PermissionRequest (its Notification carries no agent_id) shows Needs approval until
    the registry's next "idle" or "busy" sample returns the state from before it (FB2-6); other events with an agent_id stay
    dropped as .childAgent); the adapter reads `meta.json` off the hook path (bounded
    retry after a start, one try at the stop; a workflow's agents keep it in subagents/workflows/<run>/ and count as background) and publishes `.subagents` to the hub; `SessionViewState.subagents` is cleared by a
    new run, a detach and the run's end, and a later update is ignored; SessionListEntry draws `SubagentTreeView` under the card
    Subagent panel (FB4-5): `SubagentMeta.read` also gives the transcript path (the meta file's sibling `agent-<id>.jsonl`, in the run folder for a
    workflow's agent), which the ledger stores on the `SubagentRecord`. A click on a subagent row calls `CatalogModel.openSubagent`, which selects the session, opens its inspector on the Agents tab (V09) and builds the panel's model; `InspectorAgents` shows it beside the terminal, which stays mounted. The panel's
    `SubagentTranscriptModel` asks `ConversationIntents.subagentTranscript` (the controller, with `SessionRuntime.claudeProjectsDirectory()`)
    for the file: `SubagentTranscriptLocation.resolve` accepts only `…/subagents/agent-<id>.jsonl` or `…/subagents/workflows/<run>/agent-<id>.jsonl`
    whose `realpath` lies inside the profile's `projects` folder, and the open is read-only with `O_NOFOLLOW` on a regular file of this user.
    `SubagentTranscriptFeed` (one vnode source, started only while the panel is on screen and the window visible, stopped on hide; `stop()` returns at once and tears down on the feed's queue, so the model's consumer drops any batch that arrives after a close) reads with
    `SubagentTranscriptTail` (only new bytes and only whole lines, a partial last line held back, lines over 128 KiB skipped, a cold open reads the
    last 512 KiB from a line start plus the first line, a shrink or a replaced inode starts over), parses with `SubagentTranscriptParser`
    (a `memmem` gate drops attachment lines, a narrow Decodable never decodes `toolUseResult` and the other bulky duplicates, strings clip at 4 KiB)
    on a utility queue, coalesces writes to at most 5 reads a second and delivers `SubagentTranscriptBatch`es on an AsyncStream; the model keeps the
    last 400 entries and applies one batch as one update. The panel closes with the inspector closing, a tab other than Agents, any selection, the subagent's record dropping out and the run's end
    Reason and status truth (V03, S0 recordings, Claude 2.1.300): the tracker also keeps a `StatusReason` (`StatusReason.swift`;
    memory only, never logged, redacted when interpolated): the tool and command or path of an approval (`PermissionRequest`),
    a question's header, "plan ready" (`ExitPlanMode`), the first line of `Stop.last_assistant_message` with what still runs
    (`BackgroundWork`: running `shell`, `subagent` and other tasks from `Stop.background_tasks`, plus crons; a task Claude lists
    as completed or killed is not work), a failure's category and first line, or an automatic turn's summary. The adapter publishes
    `.reason` to the hub before the `.status` it explains, so the frame that first says Needs approval already says what for;
    the hub drops an equal reason silently and clears it with a new run. A detach or the run's end keeps only a finished or failed
    turn's line (`.turnDone`, `.failure`) for the card nobody has read yet; an approval cannot be answered once the run is gone.
    A reason is dropped when it no longer holds for the activity (`StatusReason.holds`).
    - *Needs you* comes from `PermissionRequest` (immediate). `Notification(permission_prompt)` arrives about 6 s later, or never
      when the dialog is answered first, so it changes nothing, with one exception: it is the backup for a lost PermissionRequest
      (the state is Working and no PermissionRequest was seen since the prompt), and then shows Needs approval with no reason. The
      registry's "waiting" sample over Working is the second backup. Real Claude stamps "waiting" a few ms before the hook.
    - *`idle_prompt`* (60 s after a Stop) is a reminder, not a state: it applies at rest (finished turn, at prompt, waiting,
      unknown), never over an approval, a failure (sticky until the next prompt) or an ended session, and over Working only when
      it is later than the last hook by more than the reorder window, for a turn whose idle sample was lost as stale.
    - *Esc on a dialog or an interrupt fires no hook* (no Stop, no idle_prompt either, recorded). The registry is the second signal:
      its "idle" sample (about 80 ms after the key) moves the activity to waiting for input and the reason that described the
      dialog goes with it. The transcript's tool result would need a file read for the same answer.
    - *Automatic turns*: a `UserPromptSubmit` whose prompt starts with `<task-notification` (a finished background task) or
      `<agent-message` is Claude's own: reason `.automaticTurn`, not the user's use (no `lastUsedAt`, no use stamp), and it does not
      clear the finished subagents. A `SubagentStop` with no start and an empty `agent_type` (the prompt-suggestion agent) is
      ignored by `SubagentLedger`. The registry also reports `status: "shell"` while only a background shell runs (unknown to
      `knownStatuses` today, so ignored).
 -> SessionEventHub frame -> CatalogModel.apply (sequence fast path, full reconcile on a gap) -> SessionRowModel.live
 -> SessionIndicator(record:live:) -> IndicatorView / ChaseDots in sidebar row and detail header
```

**Draft send (V07)**
`sendDraft` -> ticket re-check -> `NewSessionIntents.startSession` -> `startConversation(draft:)` -> `claudeProfile` (`--permission-mode`, `--model`, `-n` for a ticket, `-- <message>`) -> `GitWorkspace.begin` -> `createSession` -> launch (a failure after `begin` runs `GitWorkspace.undo`).
A draft is `CatalogModel+NewSession` state (`NewSessionState`); `sendDraft` clears its slot only once the card exists (`NewSessionOutcome.started`), so a refused start keeps every word. `ConversationController` is the `NewSessionIntents` implementation and calls `SessionRuntime.startConversation(draft:)`, which validates the launch profile first, refuses a first message over `NewSessionLaunch.maxFirstMessageBytes` (128 KiB; it is one process argument) before any git step, makes the branch or worktree right before the card (`GitWorkspace.begin`, only when the user picked one), then goes the normal start path above. When the start fails after that git step, the runtime puts it back with `GitWorkspace.undo`: a new branch is left (switch back to the branch or detached commit that was checked out) and deleted, a new worktree is removed (`worktree remove --force`) and its branch deleted, and the folders it created under `.claude/worktrees/` go too when empty. The same undo runs when the git call that makes the change outlives its deadline (the switch may have happened before a hung `post-checkout` hook), and the undo calls run with `core.hooksPath=/dev/null` so they do not wait for that hook. What could not be undone is named in the error the banner shows ("Not undone: ..."); the user's own branches and files are never deleted. The mode, model and effort of a started session are kept in the catalog's `sessions` row (V16, below), so a resume in either face passes them again.

**Chat view (V13)**
`ChatTranscriptView` -> `ChatTranscriptModel` -> `ClaudeTranscriptLocator.locate` -> `TranscriptLens` (cold open: the newest turns into a `TurnModel`; older turns on demand) -> `ChatRowBuilder` rows -> `ChatStreamController` (table). While the view is on screen and the window visible, `TranscriptGrowthFeed` watches the file (50 ms coalescing); a hidden window or a closed view has no watcher and no timer.
- The stream derives rows incrementally: `ChatRowStore` keeps rows per turn and returns a full list or patches; `ChatStreamController.apply(patches:)` patches the table (a reader action that changes the length of an earlier stretch, such as opening an old fold, rebuilds the row index). `ChatRowBuilder.rows` is the from-scratch reference.
- `ChatPresentation` (per session) holds the model copy, the reader's state and the store; a view attaches and detaches. `ChatTranscriptModel` is the transcript source adapter.
- Sources emit `ModelChange` (`.replaced`, `.older`, `.growth`) with consecutive sequence numbers (`ModelChangeSource`). `TranscriptGrowthFeed(delivery: .changes)` yields one change at a time and waits for `acknowledge()`, so a slow main thread gets one merged change; it always delivers its first read after a start, and an empty change carries the source's current sequence, so a receiver behind it asks for a snapshot. An `.older` change reuses rows only when it is the next in sequence. A status with no entry is a change (`activityChanged`).
- The receiver's copy of the model carries entries, turns, `activity` and the unknown-record count; it does not update `tasks`, `latestInit`, `contextUsage`, `rateLimit` or `sessionState` after a snapshot.
- A live source (V16) must name every mutation in the `ModelDelta` it returns and set `activityChanged` when `activity` changes.

**Chat driver and live view (V16)**
`SessionRuntime.startChatConversation` / `resumeChatConversation` start a `claude` stream-json child with pipes inside the run scope and hand its `PipeEndpoint` to a `ChatSessionDriver`. `ChatSessionHost` (LoomChat, MainActor) owns the drivers in a lock-protected registry and re-keys one when its run moves to a new card (`/clear`); the app creates the host (`CatalogModel.installChatSessions`), and `CatalogModel+LiveChat.swift` holds the model's side. `SessionFaces.liveChatEnabled` (off until V19) gates starting a driver; a run that already is a pipe run needs no flag.
- *Launch choices and face.* Permission mode, model, effort and the owning run endpoint live in the catalog's `sessions` table (`SessionCatalog+Launch.swift`; the columns are added on open by `ensureLaunchColumns`, like the origin columns). The runtime writes the choices when it starts a session and after a live change in the Chat face succeeds (`recordLaunchChoices`); every spawn in either face reads them. The endpoint is written when a run starts, and a run that moves card carries both to the new card (`carryLaunchState`). The UI's older `launched` list (`new-session.json`) is copied into rows with no choices stored (`importLaunchChoices`, from `ConversationController.begin()`).
- *State.* `SessionViewState.runEndpoint` (terminal or pipe) says how the live run is driven; `SessionViewState.waitingRequests` lists both providers' waiting requests (`ProviderPendingRequest`: the Chat face's `pendingRequests`, Codex's answerable `userRequests`). "Running" means a run, never a terminal view (`CatalogModel.runEndpoint(of:)`, `isRunning(_:)`).
- *Work state.* The driver is the only source of a pipe run's work state (`ClaudeSessionAdapter.handOverWorkState`). Hooks still keep identity, use times, subagents and the reason line; their activity is not published, and a run with a driver has no registry watch (`sdk-cli` entries are ignored: `ClaudeRegistrySnapshot.isStreamChild`).
- *Stop.* `ManagedRunStopHooks.leave(ManagedRunLeave)` interrupts a running turn or a waiting request and waits for the `result`, within the input-close grace, before stdin closes; Stop, Quit and a face switch all go through it. It is not called when the leader already exited (`processExited`). `moved(card)` tells a run's owner that the run changed card. Quit waits for pipe stops already under way. Nothing in the driver sends a signal.
- *Bounds.* `ControlChannel`'s outgoing queue holds 256 lines (a full queue refuses the line with `outputFull`; the driver reports `inputFull`); the stdout a driver has not taken is bounded at 16 MiB (`ChatPipeSink`: the read waits, nothing is dropped); stdin keeps `PipeEndpoint`'s 1 MiB limit.
- *Queue.* `<data root>/chat-queues/<session id>.json` (`ChatQueueStore`): at most 100 items and 1 MiB of text. An item leaves the queue only once it is written; an unreadable file is set aside as `<id>.unreadable-<epoch>.json`, never overwritten; deleting a session deletes its queue (`ChatSessionHost.forget`), and a launch removes queues of sessions the catalog no longer has.
- *Live view.* The driver's `modelChanges()` is a `ModelChangeSource`: a snapshot first, then growth with consecutive numbers, a snapshot after `/clear`; `snapshotChange()` answers a reader that missed one. `LiveHistoryJoin` joins the transcript's history with the newest run's live model: it cuts the history at its first entry of that run (the same id, a uuid Read now re-sent a prompt under (`sentAliases`), or a prompt with one of the run's prompt texts written since `RunStart.time`), renames history ids that clash, and carries the earlier runs' Loom-only rows (markers, failure notices, answered cards) into the history by time. `RunStart` holds the run's counts, launch time and `generation` (one more per launch, kept across `/clear`, published in `ChatLiveState`). `LiveChatFeed` (one per driver, held through `ChatSessionHost.attachment(for:make:)`) owns the session's `ChatPresentation`, asks the driver for a snapshot after a gap, reads the history again when the generation changes, follows `/clear` with a new presentation, and uses the transcript only for the cold open, older turns and "Show all"; no `TranscriptGrowthFeed` runs for a session a driver owns. The host keeps a feed while a view shows it or its run lives (`ChatDriverAttachment.isInUse`; the feed counts its views and calls `onUnused`), otherwise among the four last used (`attachmentLimit`). One stream shows a feed at a time; the last view to attach takes it over. `LiveChatView` shows it.

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

**Ended run's screen (D-45, FB4-3)** A run that ends leaves a snapshot, not a surface: `ConversationController.reconcile` takes `TerminalSurface.captureEndedScreen()` (a `TerminalScreenSnapshot`: grid size and rows of styled text runs, colours resolved to RGB from `TerminalTheme`, bold/italic/underline/strikethrough as styles, dim and inverse applied) and then releases the surface like any ended run, so no `TerminalView`, engine or frame driver stays for an ended session. What is captured, in this order: what the user saw when they pressed Stop (`captureVisibleScreen()`, taken synchronously in `stop()` before any signal), else the alternate screen if the program died inside it, else the latest alternate screen the program left (SwiftTerm patch 14, `onAlternateBufferLeaving`: `?1047l`/`?1049l` clears the alternate buffer, so a copy is taken just before), else the main buffer's visible rows with a tail of scrollback; bounded to 400 rows and 1 MiB per snapshot. Snapshots live in `EndedScreenStore` (`CUI/EndedScreens.swift`): memory-only, least recently used out first, at most 16 and 4 MiB together, independent of the selection and the tabs (a stopped session whose tab closed still shows its screen when selected). `DetailContent` shows `EndedScreenNotice` (Resume, Show Details) above `EndedScreenView` (`CUI/EndedScreenView.swift`: a selectable, read-only `NSTextView` in the terminal's font and background, each character kerned to the engine's pixel-snapped cell width so a full row is as wide as the terminal was; rows do not wrap, it scrolls both ways and opens at the last row's first column; no timer or engine). Resume, Show Details, delete (`CatalogModel.forget`) and quit drop the snapshot; nothing is persisted, so a relaunch shows the record view (contract §8).

**Terminal ownership per frame (H1-D1)** `ConversationController.reconcile(_:)` compares each live terminal with the frame's `SessionEventFrame.sessions`: an entry whose owner's `runID` is its run needs nothing; only an entry the frame does not show is confirmed with the supervisor (`ownerLookup`, one `activeSessionID` call) and then handled as before (run ended: kept ended screen or `runEnded()`; owner moved: `tabOwnerMoved`). This holds because `ProcessSupervisor` changes `activeSessionID` before it publishes `runStarted`/`runDetached`, removes the run before `runEnded`, and the hub keeps the newest frame with full states; the adoption path (`adopt`, a failed start) reconciles against a fresh `SessionEventHub.snapshot()`.

**Finished turn and usage (H1-D1)** `UsageModel.refresh(reason: .turnComplete)` asks for a full transcript walk only when `setTranscriptWatcherRunning(false)` (the stream failed to start or the profile has no `projects` folder, set in `AppDelegate+Usage`). With the watcher running, the turn's own transcript write arrives through `UsageTranscriptWatcher` -> `transcriptsChanged` and `refreshChanged` reads just those files. While no Loom window or Usage page shows, the model only collects the watcher's changed paths (and a `needsFullScan` flag); the next activation reads just those files, inside the 10 s cooldown too, walks everything only after a watcher overflow or when the local day is not the day last read, and reads nothing when nothing changed. Without a running watcher (or before the launch scan finished) a change while hidden only marks the numbers stale and the next activation walks everything. The full walk also stays for launch, the Settings page opening and the manual refresh.

**Context ring and plan pace (V10)** The ring's tokens come from `ClaudeUsageIndex.latestMainMessages(sessions:)`: one seek per session on `msg_session_main` (a partial index over non-sidechain rows, created on open when a file predates it), so no transcript is opened and nothing is scanned. The context figure is the last main-thread message's input plus both cache classes (output left out, as Claude Code's own figure does); subagent messages never count. `UsageModel.trackContext(sessions:)` names the sessions to follow and reads them once, then again after each refresh (no timer); `UsageModel.contexts` holds `ContextUsage`, which has a share only after `setContextWindow(_:forModel:)` told the model's window (from the Chat wire's `modelUsage.<model>.contextWindow`, keyed by canonical model id). `PlanLimits.paces(at:)` and `UsageModel.paces(at:)` compare each window's used share with the share of its fixed length (5 h, 7 d) that has passed, from the last `get_usage` answer: no ask, no process. `get_usage` carries `skip_behaviors:true`; without it the CLI reads every transcript of the last seven days on each ask. The views are `ContextRing` and `PlanPaceLine` (tokens in `LoomTheme+ContextPace.swift`); where they are placed belongs to the surfaces that show them.

**Home and the project page (V05, V08)** Both read when they open and hold what they read; neither polls or watches. Home: `CatalogModel.refreshHome` (a task keyed by `HomeReadKey`: readiness, the day, the session count and the runtime's runs-recovered signal; the end of a usage refresh runs a second task, `refreshHomeToday`, that re-reads only `sessionCount(activeSince:)`, so the Continue scan does not run after every finished turn) runs three small `SessionCatalog+Home` queries, `sessionsEndedByQuit(since:limit:)`, `sessionCount(activeSince:)` and `lastUsedProjectID()`, into `HomeState`. Continue is the sessions whose latest run ended with `applicationQuit` (a run an earlier Loom left open is closed that way at the next launch, so a crash counts too) and that have no later run, dated by the session's last use capped at the run's recorded end (a crash is closed only at the next launch), over the last 7 days and at most 30 sessions (`HomeLimits`); the card shows 5 and "Show N More". Needs you and Finished are a split of the Dock badge's own set (`AttentionOrder`), so their sizes add up to the badge. `SessionRuntimeConfiguration.runsRecovered` is called after `closeAbandonedRuns` and drives `CatalogModel.runsWereRecovered()`, so the first read after a crash sees the runs it left. Today's split by kind is `UsageModel.todayUsage`, from the same `days(1)` read as the chip. The plan-limits block is `UsageModel.paces(at:)` and a missing Claude CLI is read from the plan-limits ask's `noToolchain` failure, so Home starts no process. The project page: `openProjectPage` (the view's task; closing the page cancels it and `end()` drops what it held) reads the project's sessions from the catalog in pages while they are still inside the week (8 days of slack, at most 500 rows), then the week's usage, the repository's branches and the project's CLAUDE.md. The first page is read again when the project's session count changes, and a failed read shows as such rather than as an empty project. A row's last line comes from the transcript's end only once the row is drawn and only when Loom holds no reason line for it (`ProjectLastLine`: the last 64 KiB, two pages at most, one session at a time, only in the working directory's transcript folder; a read whose row was cancelled or whose page closed (`ProjectPageGeneration`) reads nothing). `UsageIndexing.projectUsage(sessions:range:now:timeZone:)` is a per-project query on the usage index: one indexed seek per session (`ClaudeUsageIndex.sessionAggregates`, the `msg_session` index; no transcript opened, nothing scanned), at most 500 sessions (`maxProjectUsageSessions`), subagent messages included; a usage index that cannot answer is `ProjectPageState.usageFailed`, not "no usage". The branch list (`ProjectGitRefs`) is read from `.git` files with no git process and capped: 300 branches, 2,000 directory entries under `refs/heads`, 1 MiB of `packed-refs`, 50 linked worktrees; past a cap the list says it is partial. CLAUDE.md (`CLAUDE.md`, else `.claude/CLAUDE.md`, a regular file or a link to one) is read up to 32 KiB.

**Stop**
`ConversationController.stop` -> `SessionRuntime.stopConversation` -> `ProcessSupervisor.stop`: provider prepare-stop hooks,
freeze then kill forked scope members (launchd-spawned members are never signalled), ownership resample, `SessionStopReport`.
A pipe child (Section 4) is first asked to leave by closing its stdin; only what is still alive after the input-close grace gets signals.
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
closure; `LoomCore`, state `idle/running/finished/failed`) -> `SessionRuntime.shutdown` (refuse new work, cancel Codex setup and reserved launches, stop lifecycle evaluation, end pending open requests, stop the control and hook servers, tear down Codex servers,
cancel a backup still waiting for its turn, `ProcessSupervisor.shutdown` -> `ShutdownReport`, journal it, reconcile ended runs, wait for a backup being copied). A user-initiated quit with a session Working or Needing approval first asks "Quit Loom and stop N working sessions?" (`QuitConfirmation`; Cancel is the default; never for a system-initiated quit, read from `keyAEQuitReason`, nor in evidence runs). Unverified shutdown keeps the app open with Try Again, Keep Loom Open and Quit Anyway (the next quit returns `.terminateNow` without a verified shutdown; processes Loom could not stop may keep running); a system-initiated quit is never held up by an unverified shutdown (the report is still written). Cmd+W only
closes the window; the runtime keeps running. `SessionRuntime.shutdown` journals a `quit` summary (counts of processes signalled, errors and whether it succeeded; no process records). No backup starts once shutdown has begun, so nothing of the runtime writes to the data root after it returns.

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
  Tests assemble a host bundle with `RunScopeLauncher.assembleOwnedBundle(executable:in:)` and remove it with `removeOwnedBundle(in:)`,
  which also unregisters it from LaunchServices (launching through `open` registers the bundle, and the record outlives the folder).
- **Short-lived helpers outside a run scope.** Three things run as plain children of Loom, not in a scope, and end within
  seconds: `GitWorkspace` (V07; `/usr/bin/git` as a short-lived child, run only on a draft's first send when its strip asked for a new branch or worktree, and again to put the change back when the start then fails: a `Foundation.Process` that runs `rev-parse`, `check-ref-format` and `show-ref`, then `switch -c` or `worktree add`. Each call waits on a thread of its own (`loom.git`), never on the cooperative pool. One 30 s deadline covers the whole call, output included and capped at 64 KiB: the output is read with `poll` against that deadline and stops at end-of-file, at the deadline, or when git has exited and the pipe stays quiet, so a hook that leaves a background job holding the pipe (`post-checkout` with `sleep 600 &`) cannot hang the start; the read ends are closed and git is terminated at the deadline. The new worktrees live under `<repo>/.claude/worktrees/`, a folder the repository does not ignore, so `git status` lists it as untracked until the user ignores it; Loom does not edit `.gitignore` or `.git/info/exclude`), the plan-limits child (`ClaudePlanLimitsFetcher`, a `Foundation.Process` of `claude -p` that gets one `get_usage`
  request, is asked to leave by closing its stdin, then `SIGTERM` and `SIGKILL` by pid, after a timeout or on cancel) and the
  `log show` read of the diagnostics export (`DiagnosticsExport.runLogShow`, bounded in size and time). The helper
  spawner is a fourth path: `HelperSpawner.scoped` puts an environment shell or a `--version`/`--help` probe in a scope
  when a `scopeLauncher` is configured (the app always has one), while `HelperSpawner.local`, the default, starts it as
  Loom's own child in its own process group, used when no scope launcher exists (tests and the probe) and killed by group on
  abort. Every long-lived provider process still starts in a scope.
- **Pipe children.** A run's child is either a PTY child (`SPAWN_PTY`: `launch`, `TerminalEndpoint`) or a pipe child
  (`SPAWN_STDIO`: `launchPipes`, `PipeEndpoint`). For a pipe child the host receives three descriptors (stdin, stdout, stderr)
  instead of a PTY master, and the child is otherwise the same: same scope, ledger, markers and same-session guard. The run
  keeps a `RunEndpoint` (`Runtime.endpoint`, formerly `Runtime.terminal`), so the shared stop path asks it, not a terminal.
  The stdout and stderr pipes are drained whatever the consumer does (`PipeOutputSink` must bound its own storage); stdin
  has a bounded queue, so a child that does not read stalls its writers instead of growing memory. A pipe run alone in its
  scope is watched through the scope's members (`exclusiveScopeMembers`), not the whole process table.
- **Stop order.** A PTY child: `SIGHUP`, `SIGTERM`, `SIGKILL`, each after its grace period. A pipe child is asked to leave the
  way its protocol says: stdin is closed first, the run gets its own input-close grace to exit on its own
  (`inputCloseGraceSeconds`, default 2 s; the real CLI exits about 0.7 s after end-of-file), and only then `SIGTERM` and
  `SIGKILL` after the signal grace (no `SIGHUP`: it means nothing without a terminal). Before stdin closes, the run's owner may
  end the work under way through its `leave` stop hook, bounded by that same grace (the Chat driver, see "Chat driver and live
  view (V16)"). Quit does the same on its one
  app-wide clock: stdin of every pipe child closes, one shared input-close wait, then the signals (`SIGHUP` goes to terminal
  runs only, never to a pipe run); a pipe run's stop takes longer by design, so Quit waits for pipe stops already under way
  up to a longer deadline. A pipe child that exits before Loom reads its identity still delivers its output and
  exit status.
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
  (`Loom Dev.app`, `local.loom.desktop.dev`, built by `scripts/package-dev-app.sh`; the production `Loom.app` is built by the clean loom tree's `build.sh`, [DEVELOPMENT.md §10](../DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).

| | Development (bundle id != `local.loom.desktop`) | Production |
|---|---|---|
| Data root | `~/Library/Application Support/Loom-Dev` | `~/Library/Application Support/Loom` |
| Hook socket dir | `~/.loom-dev` | `~/.loom` |
| Scope socket dir | `~/.loom-dev/scopes` | `~/.loom/scopes` |
| Evidence data root | `--data-root` or `<evidence dir>/data`; never the default root | not applicable |

## 5. Persistence

| Store | Location | Notes |
|---|---|---|
| `SessionCatalog` | `<data root>/catalog.sqlite3` | SQLite via system `sqlite3`; WAL; `quick_check`; `secure_delete = ON` per connection; schema v3 (`SessionCatalog.schemaVersion`): `sessions` (+ `stale_since`; `last_activity_at`, `ticket_key`, `opened_by` are added on open without a version bump so 0.2.1/0.3.0 still open the catalog: `ensureActivityColumn`, `ensureOriginColumns`; the same way `permission_mode`, `model`, `effort` and `run_endpoint` (V16, `ensureLaunchColumns`, read and written by `SessionCatalog+Launch.swift`)), `runs`, `run_sessions`, `provider_identity_changes`, `projects` (+ nullable `color`, D-48, added on open the same way by `ensureProjectColors`: a `ProjectTone` name, `none`, or NULL, which gets the least-used tone, oldest project first, on every open and on `addProject`; an unknown value is kept and shows neutral; `setProjectTone`), `deletions`, `app_state`. Refuses newer or foreign schemas; surfaces the failure in the UI instead of starting a runtime |
| UI preferences | `<data root>/ui-preferences.json` | `UIPreferencesStore` (`UIPreferences.swift`); an unreadable file is renamed to `ui-preferences.unreadable-<ts>.json` |
| Run directories | `<data root>/runs/<run uuid>/` | `ledger.json`, `owner.json`, `ownership-guarantee.txt`, created 0700 per app run; removed by `PreviousRunRecovery` once scopes are shown empty |
| Diagnostic journal | `<data root>/diagnostics/journal.jsonl`, `journal.1.jsonl` | `DiagnosticJournal.forDataRoot`: one JSON object per line, rare events only (`launch`, `claude_cli`, `quit`, `recovery*`, `cli_compat_warning`, `hook_silence`, `catalog_backup`, `catalog_restore`, `diagnostics_export`), no session content; at 512 KB the file becomes `journal.1.jsonl` and anything older is pruned on the write; files 0600 in a 0700 folder |
| Diagnostics exports | `<data root>/diagnostics/exports/loom-diagnostics-<stamp>/` | `DiagnosticsExport.collect(to:)`: `summary.json`, the journal files, `log.ndjson` (last 24 h of subsystem `local.loom.desktop` limited to processes whose image lives inside the running app's bundle (`processImagePath BEGINSWITH "<bundle>/"`, so `swift test` runs and the other flavor are left out), 5 MB cap, 30 s timeout); at most 3 kept (only folders carrying the export marker are pruned) |
| Catalog backups | `<data root>/backups/catalog-<yyyyMMdd-HHmmss-SSS>.sqlite3` | `CatalogBackupStore`: `VACUUM INTO` (second connection, off the main thread, `quick_check` before the rename) at most once per 24 h, 3 newest kept; deleting a session removes all backups and takes a fresh one (no backup keeps a permanently deleted session) |
| Damaged catalog | `<data root>/catalog.damaged-<stamp>.sqlite3` (+ `-wal`, `-shm`) | Set aside by `CatalogRecovery.restore` / `startFresh`; never read again. Every permanent deletion removes them (each copy and its `-wal`, `-shm`: `CatalogBackupStore.purgeDamagedCopies`, called beside `purgeAll` in `SessionCatalog.finishDeletion` and `deleteSessionRows`, so a deletion that resumes after a crash does too), because a damaged copy can still hold the deleted session (contract §8); until then the launch prompt says it is kept |
| Quarantined run directories | `<data root>/runs/quarantine/` | Run directories with an unreadable ledger, newest 10 |
| New session | `<data root>/new-session.json` | `NewSessionStore` (V07): drafts with text, last used per project, presets, defaults, launched modes and models (newest 300; the catalog's `sessions` row is the source of truth for spawns since V16, this list only feeds its one-time import); atomic, debounced 300 ms (and on a send, a blur and Quit); an unreadable file is moved to `new-session.unreadable-<epoch>.json` and reads as empty; the drafts' saved form is built when the write is due, not per keystroke; a failed write and an unreadable file are shown under the composer text |
| Chat queues | `<data root>/chat-queues/<session id>.json` | `ChatQueueStore` (V16): the "After this turn" queue of a Chat session, owner-only (0600 in a 0700 folder), written whole and atomically on every change; limits and rules: Section 3, "Chat driver and live view (V16)" |
| Hook socket | `<socket dir>/h-<8 hex of run id>.sock` | `SessionRuntime.ensureHooks`, token-authenticated, removed by `ClaudeHookServer.stop` at shutdown |
| Control socket | `<socket dir>/c-<8 hex of run id>.sock` | `SessionRuntime.ensureHooks`, same token, request/response for `loom-hook open` (D-40); removed by `OpenSessionControlServer.stop` at shutdown |

**Backup and restore.** `SessionCatalog.backupStore` (derived from the catalog's folder) backs up through `scheduleCatalogBackup` 10 s after runtime start (`SessionRuntimeConfiguration.catalogBackupDelay`) and forced after a deletion; none is scheduled once shutdown has begun (the next launch's daily backup covers a deletion that ends during Quit), and Quit waits for a copy being written. A generation counter discards a copy that was being written when a deletion finished. When opening the catalog fails with `SessionCatalogError.isDamaged` (corrupt or not a database), the launch prompt (`AppDelegate.offerCatalogRecovery` in `AppDelegate+Diagnostics.swift`, an `NSAlert` run before the window or the runtime exist; what it says and which buttons it has come from `CatalogRecoveryPrompt.make(backups:)`, a pure function) lists `CatalogRecovery.backups(forCatalogAt:)` and offers "Restore Backup" (only when a backup exists; the newest, named by date), "Start Fresh" (`startFresh(catalogAt:)`) and "Quit"; after a restore or a fresh start the launch goes on with the reopened catalog, a failed recovery falls back to the usual catalog-error screen, and any other open error (newer schema, busy, foreign) gets no offer. Restore copies the backup to `catalog.sqlite3.restoring`, verifies it, sets `-wal`, `-shm` and the main file aside as `catalog.damaged-<stamp>.sqlite3` (the sidecars first, so a stray WAL is never replayed into another main file) and renames the copy into place; `SessionCatalog.init` finishes an interrupted restore from the files left on disk.

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
- **Current patches (12):** inline-image-quota, buffer-diagnostics, frame-signal-coalescing, ascii-text-presentation-guard,
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
  `--fake-providers`, `--fake-toolchain-delay`, `--claude-config`, `--codex-home`, `--fail-first-quit`, `LOOM_FORCE_SCOPE_FAILURE`, `LOOM_FAKE_NO_CLAUDE`, `LOOM_FAKE_USAGE*`,
  and the synthetic terminal (menu item, controller). Inert library-side seams remain in both flavors: `TerminalPresentationLog`,
  `ConversationController.terminalEvidence`/`typeForEvidence`/`runtimeEvidence`, `IndicatorEvidence`.
- A normal launch never subscribes to the command channel and cannot substitute fixture providers. Command list:
  [DEVELOPMENT.md §5](../DEVELOPMENT.md#5-evidence-mode) and the `case`s of the command switches in `Evidence/` (`DevelopmentEvidence.swift`
  hands each command to its `Evidence*Commands.swift` extension); scripts and method: `DEVELOPMENT.md` and `scripts/` (`cp5-*.sh|py`, `dev-paths.sh`).

## 8. Codex: paused, not in first release

Code is kept and tested but receives no new development. Locations: `Sources/LoomCore/Codex*.swift` (6 files),
`CodexSessionAdapter` in `ProviderSessionAdapters.swift`, `CodexEventStateTracker` in `CodexSessionState.swift`, the nested `CodexServer` class and Codex
setup/teardown in `SessionRuntime+Codex.swift`, `Sources/loom-fake-provider/CodexFixture.swift`, Codex tests in `LoomCoreTests`
(`CodexAppServer*`, `CodexWireDiagnosticsTests`, `SessionRuntimeCodex*`), `loom-probe` Codex files. UI entry points ("New Codex Session" in `SidebarView.swift` and `DetailView.swift`, `AppDelegate.newCodexFromMenu`) exist only in development builds: `BuildIdentity` (`Sources/LoomLaunchOptions/BuildIdentity.swift`) gives `startableProviders = [claude]` for the production identity `local.loom.desktop`, `CatalogModel.startableProviders` filters every new-conversation surface, and `ConversationController.start` refuses a provider outside that set. Resume follows the same rule: `CatalogModel.canResume` requires a startable provider (Resume, "Reactivate and Resume", Cmd+R and the menus all go through it), `resumeConversation` and `ConversationController.resume` refuse a record of any other provider, and the record view says "Codex sessions can't be resumed in this version." (`resumeUnavailableReason`); a Codex record in the production catalog stays readable and listed.
Design fact: one `codex app-server` per Codex session (contract §3).

## 9. Hotspots and scaling notes (facts, no redesign)

- Large actors, split by responsibility into extension files (the stored state stays in the core file, so access is internal
  rather than private): `ProcessSupervisor` (core: ~35 mutable fields, registry, launch, adopt; `+Stop`, `+Shutdown`,
  `+Sampling`, `+Scopes`, `+EnvironmentJobs`, `+CatalogCommits`), `SessionRuntime` (core; `+Codex` ~550 lines, `+Claude`),
  `SessionCatalog` (core; `+Sessions`, `+Runs`, `+Projects`, `+Titles`, `+Paging`; `CatalogDatabase`; synchronous sqlite on
  an actor).
- Codex share of `LoomCore`: ~2,700 lines in `Codex*.swift` plus adapter and `SessionRuntime` parts, roughly a sixth of the target's ~21,000 lines.
- UI-layer coupling: `ConversationController` (live terminals plus the ended runs' snapshots, at most 16 and 4 MiB) and `CatalogModel` hold `SessionRuntime`/`ProcessSupervisor` directly;
  `CatalogModel` (1,705 lines in `CatalogModel.swift`, plus extensions) mixes paging, search, selection, projects, rename, event consumption and branch reads;
  `CatalogModel` imports AppKit and `ConversationIntents.terminalView` returns `NSView`.
- Launch measurements (F5, release package, 5 runs each, `scripts/perf/launch_paint.py`): window creation (`WindowShown`,
  ~125-136 ms) dominates app delegate to first page; catalog open including `PRAGMA quick_check` is 0.7 / 1.5 / 8 ms at 0 /
  1,000 / 10,000 rows, so it stays on the main thread. Git branch reads are off the main actor (`BranchCache`).
  A run, lifecycle, identity or activity frame patches its one row (`CatalogModel+Patching.swift`, H1-D2) when no frame was
  missed before it and the row is loaded; otherwise, and for batched catalog changes such as aging, `CatalogModel.scheduleRefresh`
  reloads every loaded row of every visible list.
- Logging and diagnostics (D-45): `LoomLog` categories under subsystem `local.loom.desktop` (Lifecycle, Catalog, ClaudeHooks, Registry, Toolchain, Scope, Usage, Recovery, Quit, Diagnostics, HookClient for the `loom-hook` process). Notice and error levels are for transitions and failures; per-event detail is `debug`; ids, counts, durations and error categories are public, user paths private; a repeating error is rate-limited to once a minute per key (`LogRateLimiter`). Loom writes no log files of its own; the only files are the journal and exports above. Cost: a logger call without a listener is a cheap level check, a journal write is one `O_APPEND` line on a rare event, a backup is at most one `VACUUM INTO` a day off the main thread. Entry points: Help > Collect Diagnostics… and Settings > About > Collect Diagnostics… share one `DiagnosticsCollection` (LoomCatalogUI; one export at a time, both disabled while it runs and before the runtime exists) that `AppDelegate+Diagnostics.swift` points at `SessionRuntime.collectDiagnostics(to: DiagnosticsExport.defaultFolder(dataRoot:), usage:, planLimitsFailure:)` (the facts come from `UsageModel.diagnosticsSnapshot()`), then reveals the folder in Finder; a failure shows a modal alert with the error category only. The Usage page shows the same two facts: "Plan limits unavailable" with a short reason while the last ask failed (`UsageModel.limitsFailure`, cleared by a success; an earlier answer stays with "could not refresh"), and one line "N usage records could not be understood, so totals may be low" (`UsageModel.linesNotUnderstood`). Known limits: the usage scan's not-understood line total and `PlanLimitsFailure` are per app run; the journal records the Claude CLI version/capabilities at the first toolchain resolution (`claude_cli`), not at launch.
- Quit path: `AppShutdownCoordinator` (`LoomCore`) owns the quit state machine; `AppDelegate.startRuntime` builds it with the
  shutdown closure when the supervisor exists, and with no coordinator quit returns `.terminateNow`. `TerminalRunController`
  now carries only the evidence-only synthetic dev terminal.
- Identity: `BuildIdentity` (LoomLaunchOptions) is the one Swift owner of production vs development names (data and
  socket directories, command-channel prefix, startable providers); the Python runners share one channel helper
  (`scripts/perf/perf_paths.py`); `scripts/dev-paths.sh` keeps its own copy for the zsh scripts.
- Evidence code compiles only into the development flavor (§7); `scripts/check.sh --release-tree` fails when the release
  binary carries any of it.
- Ownership sampling in `ProcessSupervisor` scans the process table; `persistLedger` rewrites the ledger JSON.
- No `.github/` and no CI. Packaging: `scripts/package-dev-app.sh` for development packages and the clean loom tree's
  `build.sh` (`scripts/release/build-loom.sh`) for `Loom.app`, both signed with the stable local identity; notarization is not
  used ([D-47](../DECISIONS.md), [D-56](../DECISIONS.md)). `CFBundleVersion` is loom-dev's commit count for a development package and
  major × 10000 + minor × 100 + patch of `VERSION` for `Loom.app`. `loom-app` has no unit tests; `AppDelegate`/`MainSplitViewController` and the views are
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
