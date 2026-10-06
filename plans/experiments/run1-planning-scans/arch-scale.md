# Loom architecture and scalability baseline (read-only, source-verified, nothing built or run)

## Summary

**Facts**
- The core already has good scaling properties. The event map holds live activity only (`SessionEventHub.swift:35`), and paging is keyset-based with a 100-row cap (`SessionCatalog.swift:76,725`). State events update one row (`CatalogModel.apply`, test `CatalogModelTests.swift:366`). Indicator animation runs in the render server (`CatalogTheme.swift:123`).
- The risks are in startup order and the main thread, in what each lifecycle event re-reads, and in a few long-lived maps.
- Several daily-use gaps are visible directly in code. None is a crash risk.
- Crash points in non-test code are rare. The only force-unwraps are `Bundle.main.executableURL!` at `AppDelegate.swift:364,401`. The only preconditions are `PTYProcess.swift:83`, `TerminalEndpoint.swift:20`, `TerminalInputQueue.swift:46` and paused-Codex `CodexAppServer.swift:915`.
- Production targets contain no logging at all (no `Logger`, `os_log` or `NSLog`).

**Biggest levers**
1. `GitBranch.read` runs synchronously on MainActor for every loaded row on every list reload.
2. The first sidebar paint waits behind the full runtime build.
3. A bad row, or a failed catalog open, is a dead end.
4. Relative times never tick.
5. Prune and delete cross-cuts are needed before CP4.

## 1. Startup path

**1.1 First list paint is serialized behind the runtime build (stage F)**
- Location: `AppDelegate.swift:98-102`. `startupTask` runs `await startRuntime(...)` and only then `await model.start()`.
- Problem: `startRuntime` (`:296-395`) does the following before the model reads its first page:
  - creates the run dir and the supervisor;
  - reads **all** catalog rows (`ProcessSupervisor.swift:1467`, F8);
  - snapshots the process table at `:319`;
  - writes `owner.json` and `ownership-guarantee.txt`;
  - starts the runtime and lifecycle (2 queries);
  - runs `conversations.begin()`.
- `model.start()` depends only on the catalog and the hub, which both exist before `startupTask` runs (`:56-71`).
- Impact: sidebar shows a spinner (`isReady == false`) for the sum of these steps. The metric in `statistics.startMilliseconds` (`CatalogModel.swift:215-228`) excludes them.
- Change: start `model.start()` concurrently with `startRuntime`. Keep Quit waiting on both (`applicationShouldTerminate` already awaits `startupTask`).
- Risk: low. Subscription ordering is safe because the model snapshots `catalogRevision` first (`:219`).
- Verify: an evidence-mode timeline from process start to "list visible" with a 10k fixture, before and after.

**1.2 Synchronous IO on MainActor during launch (stage F)**
- `SessionCatalog(url:)` is opened on the main thread at `AppDelegate.swift:63`. It runs `createDirectory`, `PRAGMA quick_check` (`SessionCatalog.swift:1033`, O(DB size) every launch), schema validation, and a migration if needed.
- `ProcessTable.snapshot()` at `AppDelegate.swift:319` runs on MainActor. It is a full `sysctl(KERN_PROC_ALL)` plus a `getsid` per process (`CLoomPOSIX.c:161-190`), used only to find this process's own identity. `ProcessTable.record(pid:)` (`ProcessTable.swift:77`) already exists for that.
- Change:
  - Use `record(pid: getpid())`.
  - Open the catalog off MainActor (`Task.detached`, then hand the actor to the model).
  - Run `quick_check` after first paint, or only when the previous shutdown was not clean (marker file).
- Risk: low to medium for `quick_check` deferral. Corruption detection is delayed, so the check should block any write until it has finished.

**1.3 First start or resume pays an unbounded, invisible toolchain cost (stage U/F, needs a decision)**
- Location: `SessionRuntime.swift:585-594`, `ProviderToolchain.swift:107-125`, `LaunchEnvironment.swift:122` (30 s timeout).
- Problem: the login-shell environment capture plus `claude --version` and `claude --help` happen lazily on the first New or Resume. Results are cached for the app lifetime (stale after a `claude` update until restart).
- For Claude the card appears only after the launch returns: `launchClaude` never calls `onTerminalReady`, so `busy == .starting` and the "Starting…" text (`DetailView.swift:50`) never show. Only `isStarting` disables the menu items.
- Change: a visible "Preparing…" state. Optionally prefetch the toolchain after first paint.
- Prefetch is a policy question: contract says opening starts no provider or PTY; a shell capture is neither, but it is a user decision.
- Verify: first-start latency with a heavy `.zshrc`, and the missing-CLI path.

**1.3b Environment resolution supports only `/bin/zsh`** (`LaunchEnvironment.swift:147`, `unsupportedShell`). This is a first-run risk for a non-zsh login shell.

## 2. Catalog scaling

**2.1 `quick_check` at every open:** see 1.2. It is unmeasured; `CatalogScaleTests` never times `SessionCatalog.init`.

**2.2 Search is a full scan with a Swift UDF (stage F)**
- Location: `SessionCatalog.swift:739-742`. Each term runs `loom_fold(provider|title|p.name) LIKE %term%`. The UDF (`:1022-1030`) does `String(cString:).folding` per row, per column, per term. `LIKE '%x%'` cannot use an index.
- Impact (inference): O(rows × columns × terms) of String work on the catalog actor. That actor is synchronous SQLite, so it also blocks lifecycle reschedule, `markUsed`, and run commits during a scan.
- A debounce (120 ms, `CatalogModel.swift:419`) bounds frequency only.
- The test prints the search median but asserts only the first page (`CatalogScaleTests.swift`, `#expect(median(pageTimes) < .milliseconds(300))`).
- Change: measure first. If slow, store a folded `search_text` column (migration v3) and use plain `LIKE` or FTS5. Alternatively cap search to title and project with a precomputed folded column.
- Risk: schema migration. Verify: search latency at 1k, 10k and 100k rows.

**2.3 One undecodable row takes down the list and the runtime start (stage F)**
- Location: `decodeSession` throws `invalidRow` (`SessionCatalog.swift:872-878`) for an unknown provider, lifecycle or UUID. `sessionPage` and `sessions()` propagate it.
- Impact: the list shows only "Conversations could not be read". `restoreCatalogSessions` throws, so `startRuntime` hits `catch` (`:392`), shows an alert, and actions stay disabled.
- Change: skip and record undecodable rows (count shown in info text) instead of throwing. Distinguish forward-compat providers.
- Risk: low. Verify: a seeded bad row test.

**2.4 Corrupt or unreadable catalog is a dead end (stage F, relevant to CP4)**
- `DetailView.swift` shows "Loom could not open its catalog… left untouched". There is no backup, no Reveal in Finder, no repair.
- Change: a rotating pre-migration or daily `VACUUM INTO` backup. CP4 permanent deletion makes this more important.

**2.5 Schema prerequisites for CP4 deletion (stage CP4)**
- `runs.initial_session_id`, `run_sessions.session_id` and `provider_identity_changes.session_id` are FKs to `sessions(id)` (`SessionCatalog.swift:1082-1112`) with `foreign_keys=ON` and no cascade.
- They have no child-side index; `run_sessions`' PK starts with `run_id`. Only the `sessions` and `projects` indexes exist (`:1143-1147`).
- A session delete must remove child rows first. SQLite scans the child tables for FK checks without an index. The cost is trivial now but grows with runs.
- `runs`, `run_sessions` and `provider_identity_changes` grow on every start or resume and are read only by tests and the fixture tool (`grep` over Sources).
- Migration chain: `configure()` hard-codes `version == 1 → migrateToVersion2` (`:1044`). A v3 needs a chain.
- Change: v3 adds the three child indexes (or `ON DELETE CASCADE` on rebuilt tables) and a retention rule for old runs.

**2.6 Viewing counts as use (decision for CP4 arithmetic)**
- `setWindowActive` and `select` → `updateViewing` (`CatalogModel.swift:499-507`) → `viewed` → `lifecycle.markViewed` → `catalog.markUsed` (`SessionLifecycleController.swift:350`). That is a DB write on every selection and every window activation.
- It bumps `last_used_at`, so merely looking at a stale row resets its age and its sort position. Lifecycle stays stale, but the "15 days stale" retention clock is `last_used_at`-based.
- Decide whether view counts as use for cleanup eligibility. Likely add a separate `last_prompt_at`, or exclude views.

**2.7 WAL and checkpointing**
- Single long-lived connection, WAL, `synchronous=NORMAL`, `busy_timeout=2000` (`:1021,1058-1062`). No `wal_autocheckpoint` tuning, no `PRAGMA optimize`, and no VACUUM after deletes.
- Inference: fine at this scale, and the file will not shrink after CP4 deletes. Add `PRAGMA optimize` at quit and a size report.

**2.8 `CatalogScaleTests` coverage**
- Covers 1k and 10k first page and search timing (printed), restore as one full read, event publish cost, decoded-rows-per-event, and aging.
- Gaps: open and `quick_check` time, project-mode multi-list reload, the UI model path (including GitBranch), the 100k tier, and search latency assertion.

## 3. UI scaling

**3.1 Synchronous git reads on MainActor, proportional to loaded rows (stage F, top item)**
- Location: `row(for:)` calls `GitBranch.read` for every record on every reload (`CatalogModel.swift:377-380`). Also `setWindowActive` re-reads every known path (`:467-472`), and `apply` re-reads at turn completion (`:684-690`).
- `GitBranch.read` (`GitBranch.swift:17-46`) is a `fileExists` walk up the path plus up to two small file reads. `branches` is never pruned.
- Impact: O(loaded rows) of filesystem IO on the main thread per refresh, plus an O(known paths) pass at every Cmd-Tab back. A hung network or removed volume path can beachball (inference, unmeasured).
- Change: a background `BranchCache` actor keyed by path with a short TTL, refreshed on turn completion and window activation. Cards read from it. Stop writing `branches` per row.
- Verify: main-thread time per reload with 1,000 loaded rows (Instruments or `statistics`).

**3.2 Every run or lifecycle event re-reads all loaded rows of all visible lists (stage F)**
- Location: `scheduleRefresh` (`CatalogModel.swift:731-748`) runs `refreshProjects()`, `markAllStale()` and `reloadVisibleLists()`. `reload` re-fetches as many rows as were loaded (`wanted = max(list.rows.count, 1)`, `:341`), in sequential 100-row page awaits.
- Triggers: `runStarted`, `runEnded`, `runDetached`, `lifecycle` and `conversationIdentity` frames for a known row (`:696-702`), plus any `catalogRevision` change. Search, expand, collapse and project edits also call it.
- Impact: 1,000 scrolled rows mean 10 sequential catalog hops plus 1,000 row-model joins plus git reads per run start, debounced to ≥100 ms. State events correctly cause no requery.
- Change: refresh only the changed row via `catalog.session(id:)` or `sessions(ids:)` when order and membership cannot change. Do a head-only reload (first page) when `last_used_at` order can change.
- Risk: medium; the dirty-loop semantics are tested (`aChangeLandingDuringARefreshReadIsNotLost`).

**3.3 Observation granularity (facts, mostly good)**
- Per-row: `SessionRowModel.live` and `record` are guarded by equality (`:96-97`), so a state event invalidates only that card.
- Shared reads by every realized card (`SidebarView.swift:314-333`): `model.selectedSessionID`, `model.now`, `model.branches`, and `model.projects` (via `projectName`, a linear `first {}` per card).
- A selection change or a reload invalidates all realized cards. Project headers read `liveRevision` (`CatalogModel.swift:278-290`), so every live change reruns an O(live) `attention` scan per header. That is cheap at 50.
- Unverified: whether equal-value writes to `branches` notify. Check with a body-evaluation counter before assuming.

**3.4 Relative time and day grouping never tick (stage U/I)**
- Location: `now` changes only in `reload` (`CatalogModel.swift:352`) and `setWindowActive(true)` (`:471`). There is no timer anywhere in LoomCatalogUI (`grep Timer|TimelineView` finds none).
- Impact: "5m" stays "5m" while the user watches, and "Today" and "Yesterday" headers stay wrong across midnight until an unrelated reload.
- Change: a minute-aligned tick of `now`, only while the window is active and visible. Cost is one observed property, with all realized cards re-evaluating once a minute.

**3.5 List implementation (stage F/I)**
- `ScrollView` plus `LazyVStack` (`SidebarView.swift:148`), with `DayGrouping.sections` recomputed in every `ActivityList` body (`:169`, O(rows)).
- Inference (unverified): `LazyVStack` retains realized views, so scrolling 10k rows keeps 10k card views alive. Row models are retained for every list ever loaded, including collapsed ones (`pruneRowModels` keeps all lists' rows, `:390-397`).
- Project mode: `visibleListKeys` (`:255-262`) loads 100 rows for every expanded project at start. Many projects means P×100 rows, P queries and P×100 git reads before the first list.
- Change: a smaller initial page per project (design decision), `NSTableView` or `List` only if measurements demand it, and cache day sections per list generation.

## 4. Runtime scaling

**4.1 Never-pruned per-session maps (F9; stage F, with CP4 cross-cut)**
- `SessionEventHub.states` entries are removed only by `forget`, called only for Codex internal sessions (`CodexAppServerManager.swift:140,227`). Every conversation touched in this process stays, and `yield` copies the whole map into each frame (`SessionEventHub.swift:~205`).
- `SessionLifecycleController.handle` recomputes `mapValues` and a set-union per frame. `ConversationController.reconcile` runs one actor hop per live entry per frame (`:275-295`).
- Other per-session maps that are never pruned: `ProcessSupervisor.sessions` (all history, F8), `lastStopReports` (cleared only for internal sessions, `:138`), `ClaudeSessionAdapter.lastStatuses`, `CatalogModel.branches`.
- Impact: bounded by sessions touched per process run, so low until thousands. This is a real CP4 hazard: a deleted conversation must be removed from all of these (see 4.7).
- Change: prune entries that are default (no run, no stop failure, no unviewed, no issue, no requests) and publish a revision. Lazy-load `ProcessSupervisor.sessions` on demand. The latter is invasive because of many synchronous `session(id:)` callers; defer it.

**4.2 Process-table scans on the supervisor actor (F6/S2, stage F)**
- `sample(sessionID:)` and `sample(runID:)` (`ProcessSupervisor.swift:657,927-969`) are synchronous on the actor. Each takes a full `ProcessTable.snapshot()`, then `ProcessTable.managedRunID(pid:)` for every not-yet-inspected PID. That is `KERN_PROCARGS2` with a `KERN_ARGMAX`-sized malloc per PID (`CLoomPOSIX.c:~345-356`).
- It runs per due session in idle evaluation (`SessionLifecycleController.swift:evaluateIdle`) and again with the descendant-recheck backoff (5 s doubling to 300 s).
- Impact (inference): 50 sessions going idle together means 50 sequential full-table scans that block all other supervisor operations.
- Change: take one snapshot per timer tick and share it across the due sessions. Seed scans from scope members, not all PIDs. Verify with an idle-burst test at 50 synthetic sessions.

**4.3 Lifecycle reschedule per state change**
- Each changed frame runs `catalog.sessions(ids: running)` plus `oldestStaleCandidate` (`SessionLifecycleController.swift:reschedule`). It is index-supported and guarded by tests (decoded rows ≤ events).
- Cost at 50 chatty sessions is unmeasured.

**4.4 Hook ingress (low risk)**
- Only 7 events are hooked (`ProviderLaunchProfile.swift:119-122`), not per-tool. One serial receive queue, listen backlog 16, 0.5 s client timeout, ingress bounded to 1,024 (`SessionRuntime.swift:110-127`).
- Loss makes that run's state `unknown` with the message "Stop and resume this conversation" (`ProviderSessionAdapters.swift`, `publishHookLoss`). That is a heavy recovery for a rare loss; consider auto-resync from the registry.
- `transitioningRuns` is a hand-rolled spin lock with 1 ms sleeps (`:44-48`, S4); the cost is proportional to contention.

**4.5 Registry watches**
- Per run: one serial queue plus up to 4 vnode FDs (`ClaudeRegistry.swift:~120-150`).
- All watchers share the `sessions/` directory, so one registry write wakes every watcher. A fingerprint check prevents reads. That is O(N) cheap wakeups per write (inference); 50 sessions means at most about 200 FDs.

**4.6 Memory per live terminal**
- SwiftTerm scrollback is 2,000 lines (`TerminalSurface.swift:11`). The `TerminalScrollback` byte ring (4 MiB) exists only when no sink is attached (`TerminalEndpoint.swift:62-66`), so it is not duplicated in the UI path.
- The matrix measured empty synthetic terminals only: 10 terminals at 126.6 MiB peak, 50 at 397.5 MiB peak (`plans/cp5/RESOURCE-BUDGET-PROPOSAL.md`). A scrollback-full real Claude session is larger. That is unmeasured.

**4.7 Long-term growth**
- `runs/<uuid>/`: `quitFinished` leaves `shutdown.json` and the dir; the next launch's `PreviousRunRecovery` removes it. This is bounded to about one dir (`PreviousRunRecovery.swift`).
- The ledger is rewritten only on scope register or remove in scoped mode (`ProcessSupervisor.swift:1353,1378`).
- Catalog tables grow (2.5). There are no log files (none written).
- CP4 deletion cross-cut list, as facts: catalog row and children, `ProcessSupervisor.sessions`, `lastStopReports`, hub `states` (`forget`), `ClaudeSessionAdapter.lastStatuses` and trackers, `CatalogModel` (`rowModels`, `liveStates`, `liveRecords`, `branches`, `selectedSessionID` in `ui-preferences.json`), `TerminalInputGate`, and late `viewed` writes (`markUsed` throws on a missing row; swallowed by `try?`).

## 5. Stability risks

**5.1 Terminal vanishes on run end (stage U/F)**
- `ConversationController.reconcile` removes the entry when the run ends (`:275-285`), so the detail pane switches to the "Not running" record page. Final output, an error message, or a crash text is lost. Only quick-resume exits are diagnosed (`diagnoseQuickResumeExit`).
- Change: keep a frozen terminal snapshot until the user leaves the card or resumes.

**5.2** Bad-row and corrupt-catalog dead ends: see 2.3 and 2.4.

**5.3 Raw error interpolation (stage U)**
- `report` builds `"\(context): \(error)"` (`CatalogModel.swift:~812`). Errors without `CustomStringConvertible`, such as Foundation and Cocoa errors, appear as dumps.
- Change: a single `userMessage(for:)` mapper.

**5.4** `RunScope.spawnBlocking` waits on a semaphore with no timeout (`RunScope.swift:393-404`). Connection loss resolves pending replies, but a hung host would not. It runs on an environment-job thread, not the actor, so impact is low.

**5.5** The preferences store writes JSON atomically and synchronously on MainActor on every selection change (`UIPreferences.swift:update`). The file is small, so the cost is low.

**5.6** Evidence and dev code ships in production (known, F).

## 6. Daily-use rough edges

- **No shortcut for focus search.** The menu (`AppDelegate.swift:620-686`) has no Find, no Edit > Find item, and no `Esc` to clear search. There is no next or previous conversation shortcut and no sidebar arrow-key navigation (cards are `Button`s in a `LazyVStack`). There is no Help menu.
- **Window frame is not persisted.** `window.center()` plus a fixed 1220×780 (`AppDelegate.swift:179-183`). No `setFrameAutosaveName`. Only sidebar width and collapse persist.
- **First-run is reactive.** There is no CLI detection at launch. A missing `claude` appears only after clicking New, as a banner: "claude was not found on the PATH of your terminal environment (N folders searched)" (`ProviderToolchain.swift:45`). There is no onboarding or install hint.
- **Codex surfaces remain in menus** while frozen (`AppDelegate.swift:637`, `NewConversationAction.all` in `SidebarView.swift`, the empty-state button in `DetailView.swift`).
- **Quit** has no confirmation when sessions are live (`applicationShouldTerminate` goes straight to `beginQuit`). Only a status line appears. This is a product question, not a defect.
- **Idle auto-stop at 1 h** removes the terminal view (design). Consider a card hint on resume.
- **Empty states exist** ("Add a project to begin", "No matching conversations").
- **Zero production logging** hampers field diagnosis.

## Top 10 (value over risk)

1. **3.1 Background git branch cache** (F). High value, low risk.
2. **1.1 Parallelize `model.start()` with `startRuntime`, plus 1.2 off-main catalog open and the PID-self lookup** (F). High value, low risk.
3. **3.4 Minute tick for relative time and day headers** (U/I). Visible correctness, low risk.
4. **2.3 Skip undecodable rows** (F). Removes a total-failure mode, low risk.
5. **3.2 Row-level refresh in place of reload-all** (F). Medium risk, high value at scale.
6. **1.3 Visible "Preparing…" and optional toolchain prefetch** (U/F). First-start perception; the prefetch needs a decision.
7. **5.1 Keep the final terminal output after a run ends** (U/F). Daily-use pain.
8. **4.1 plus the CP4 cross-cut list (F9)**: prune hub, supervisor and adapter maps and add one "forget conversation" path. This is a CP4 prerequisite.
9. **2.5 plus 2.4: schema v3 (child indexes) and a catalog backup before deletion** (CP4).
10. **6 Shortcuts: focus search, Esc, next/previous conversation, window frame persistence; remove Codex menu items** (U/I/F).

Also consider 2.2 search measurement (likely a top-10 candidate after measuring), 4.2 shared process snapshot, and 2.6 the view-equals-use decision.

## Measurements worth adding to the perf matrix

- Launch to first list visible (process start to rows painted) at 0, 1k, 10k and 100k catalog rows. Split out catalog open plus `quick_check`, supervisor restore, `runtime.start`, and `model.start` (the existing B5 number covers only the last).
- Main-thread blocked time per reload at 100, 1,000 and 10,000 loaded rows (git reads, row joins).
- Search latency at 1k, 10k and 100k rows, with 1, 2 and 3 terms and Turkish casing. Also catalog actor queue delay during a scan.
- Selection switch latency (click to terminal visible) with 1, 10 and 50 live terminals, and during heavy output.
- Run-event burst cost: 50 sessions starting or stopping inside one second (refresh count, queries, MainActor time).
- Idle burst: 50 sessions hitting the 1 h idle deadline together (full-table scans, supervisor actor stall).
- Memory per terminal with scrollback full (2,000 lines of real-looking output) at 10 and 50 sessions, compared with the empty-terminal matrix.
- Registry and hook ingress under 50 live runs (FD count, wakeups).
- Long-run RSS and map sizes (hub states, supervisor sessions) over a 24 h synthetic session churn.
- First New and Resume latency with a heavy shell startup file and a missing-CLI path.
- Time for `PRAGMA quick_check` on 10k and 100k row catalogs.

## Areas not inspected

- SwiftTerm and the `TerminalSurface`/`TerminalFrameDriver` render path in depth. I read only the scrollback and endpoint constants.
- `CodexAppServer`, `CodexSessionCoordinator` and `CodexAppServerManager` (frozen).
- `RunScope`, `loom-run-host`, `OwnershipLedger` correctness and `PreviousRunRecovery` beyond the lines cited.
- The real Claude profile and `.claude` formats (deletion data contract for CP4). I did not read the probe profile.
- `DevelopmentEvidence`, `EvidenceResourcePool`, `scripts/`, packaging, signing.
- Measured values (none taken). All "inference" labels above are unmeasured.
- Observation-framework behavior for equal-value writes to `branches`, and `LazyVStack` view retention. Both are unverified assumptions.