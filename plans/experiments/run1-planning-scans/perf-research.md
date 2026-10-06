# Report: performance and prior-art research for multi-agent run 1 (F/I/U/CP4)

## Summary

- The claude.ai post (Sep 23, 2026) is mostly web-specific. Four of its ideas port cleanly to Loom:
  1. Hold non-critical data until after first paint.
  2. Prefetch on hover or intent.
  3. Cut sidebar re-renders.
  4. Measure with deterministic counters, not wall clock.
- Loom has no signposts. grep for `os_signpost`, `OSSignposter` and `preferredFrameRateRange` over `Sources/` finds nothing. Cold-start and switch latency have never been measured, only render CPU and latency (CP5 PERF).
- Verified in source, as facts:
  - First paint waits on a synchronous SQLite open including `PRAGMA quick_check`, on MainActor (`AppDelegate.swift:63`, `SessionCatalog.swift:1033`). The window is shown only afterwards (`:89`).
  - The first sidebar page (`model.start()`, `AppDelegate.swift:100`) is serialized after the whole runtime start (`:99`). That start includes loading every catalog session (`ProcessSupervisor.swift:1467-1475`) and a full process-table snapshot (`AppDelegate.swift:319`).
  - `CatalogModel` does synchronous git file reads on MainActor for every row on every list reload (`CatalogModel.swift:380`). It also sets `now = Date()` on every reload (`:352`). Every visible sidebar card reads `model.now`, `model.branches` and `model.projects`, so one refresh probably re-evaluates all of them. This is an inference until Instruments confirms it.
  - Conversation switching already keeps terminal views alive (`ConversationController.entries`, `:49`). The swap is a SwiftUI `NSViewRepresentable` re-attach (`DetailView.swift:166`, `.id(ObjectIdentifier(terminal))`). Tabs can reuse this model.
- Biggest value for the least effort: add signposts and a baseline first, decouple first-page load from runtime start, remove the git and `now` invalidation storm, and build tabs on the existing keep-alive entries. The usage view should be an incremental local-JSONL reader with dedup. I confirmed duplicate lines in the isolated test profile.

## Blog techniques table

Source: [claude.dev "How we made claude.ai 3x faster in two weeks"](https://claude.dev/blog/how-we-made-claude-ai-faster/). WebFetch returns a model-summarized page, so treat the exact numbers as "as reported". Items 1, 2, 4 and 5 were re-queried and matched.

| Technique (reported effect) | Loom applicability | Concrete place | Expected effect | Effort |
|---|---|---|---|---|
| Static composer baked into HTML so typing works during startup (3,085→550 ms) | Analog: show the real window and sidebar skeleton before any I/O. Loom already shows the window "at once" (`AppDelegate.swift:86-91`) but only after catalog open. | Move `SessionCatalog(url:)` (`:63`) off MainActor, or show the window first. Move `quick_check` (`SessionCatalog.swift:1033`) off the launch path or run it after first paint. | Cold launch to first paint no longer scales with DB size. Unmeasured today. | M |
| V8 code cache (6.3→3.3 s cold start) | No direct analog. Swift is AOT. The nearest levers are fewer launch-time dylibs and static initializers, and Mergeable Libraries (Apple's [launch guidance](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)). Loom's SwiftPM targets are mostly static. | Check launch-time work with Instruments App Launch. | Probably small. Measure before acting. | S (measure) |
| Keep the composer mounted across conversations | Already true for terminals: one live view per run, never rebuilt. | `ConversationController.entries` (`:49`, `:255-258`). Gap: the detail pane re-creates the NSViewRepresentable each switch (`DetailView.swift:166`), and each re-attach redoes `viewDidMoveToWindow` setup (focus, blink and mouse timers, frame driver bind; `MacTerminalView.swift:971-1000`). | Tabs should hold all tab terminals in one persistent container and toggle visibility instead of removing and adding. This is an inference. Needs a switch-latency measurement first. | M |
| Session prefetch on hover (1,557→646 ms) | Partial. Loom switching is already instant for live terminals. Prefetch applies to non-live rows: `ensureSelectedRow` (`CatalogModel.swift:445`) does an async point lookup. | Hover handler on `SessionCardView` could warm `rowModels`. Rows are already loaded, so the gain is small. Better target: tab-switch warm-up (surface already alive). | Low for sidebar rows. Skip unless measurement shows a gap. | S |
| Sidebar re-renders -90% | Directly applicable. `SessionCardView` reads `model.now`, `model.branches[...]`, `model.projects` (through `title(of:)` and `projectName`), and `model.selectedSessionID` (`SidebarView.swift:312-333`). `reload` writes `now`, `row(for:)` writes `branches[path]` for every row, and `refreshProjects` writes `projects` (`CatalogModel.swift:352, 380, 405`). | See Top 8 #3. | Fewer sidebar invalidations on every lifecycle frame. Magnitude unmeasured. | S-M |
| Instruction-count benchmarks (Valgrind) | Analog: deterministic counters rather than wall clock. Loom already has `CatalogModelStatistics` (`CatalogModel.swift:63-72`: `pageQueries`, `framesApplied`, `fastPathFrames`, `fullReconciles`, `startMilliseconds`) and terminal frame/render counters. Missing: view-body evaluation counts and signposts. | Add `OSSignposter` intervals around launch phases, `model.start`, switch, `reload`. Use Instruments SwiftUI template for body counts. | Makes the stage F "perf baseline holds" check reproducible. | S |
| Message-tree assembly: resolve IDs once (4.6x) | Analog: `ActivityList` recomputes `DayGrouping.sections(list.rows, now:)` in `body` (`SidebarView.swift:169`). `CatalogModel.attention(forProject:)` loops all `liveStates` per project header (`:278-287`). | Cache the grouping, or compute it in the list model on `replace`/`append`. | Small at current row counts. Becomes relevant with paging. | S |
| Cheap first-char check before regex (1.8x) | Analog: skip the work when nothing changed. `GitBranch.read` always walks up and reads files. Add a cheap guard, or cache by mtime of `.git/HEAD`. | `GitBranch.swift:19-45`. | Removes N×(stat plus 2 reads) per reload. | S |
| Layout-instability telemetry, hold sidebar data until after first paint | Analog: the sidebar "pops" if the first page lands late. Loom's `isReady`/`EmptyListHint` (`SidebarView.swift:280`) already shows a progress placeholder. | Keep the skeleton stable. Land the first page in one commit. `reloadVisibleLists` publishes each list separately. | Visual stability. Check with a first-launch screenshot. | S |
| Hook and store subscription reduction (typing path) | Analog: SwiftUI observation granularity in `CatalogModel`, one object with ~25 observed properties. The terminal typing path is AppKit and unaffected. | Split high-churn state (`now`, `branches`, `liveRevision`, `terminalRevision`) from list state, or give rows their own observable. | Fewer invalidations. | M |
| `:root:has()`, hidden reloads, idle IndexedDB clones (idle CPU waste) | Analog: idle work. CP5 already closed F2, F3, F5 and hidden-terminal feeds (F4). Open optimizer items: F6, F8-F10, S2, S4 and the git re-read (CLOSURE.md ~167-196). | `ProcessSupervisor` ownership sampling, `persistLedger`, startup sessions load. | Already tracked in stage F. | S-M |
| Streaming: memoize finished blocks, worker offload, incremental table reveal (120 fps) | Largely done in SwiftTerm patches: partial-row invalidation, identical-row skip and direct glyph runs (ARCHITECTURE §6). Loom does not render markdown. | None new. | None. | n/a |
| 120 Hz deterministic frame benchmarking | Loom p95 is about 20 ms with CPU40 passed. A frame-budget oracle is a nice-to-have. | `scripts/perf/`. | Low. | M |
| Feature flags, staged rollout, drift tests, field shift monitoring | Single power user. A kill switch for a risky change (for example a persistent tab container) is cheap. Rollout stages and telemetry do not apply. | Launch-option flags already exist in `LoomLaunchOptions`. | Low. | S |

## Prior art for tabs / usage / settings

**Tabs and terminal surfaces**
- **cmux** ([manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)):
  - It is a Swift/AppKit app on libghostty.
  - Workspaces are vertical tabs in a sidebar showing branch, PR, cwd, ports and the latest notification text.
  - Each workspace holds horizontal "surfaces" and splits.
  - Agent attention shows as a blue ring on the pane plus a highlighted sidebar tab and unread badge, with a keyboard jump to the latest unread (⌘⇧U).
  - It restores layout, cwd and scrollback on relaunch. Optional tmux-backed live reattach exists.
  - Takeaway: attention state belongs on the tab chip, not only in the sidebar. Loom already has `SessionIndicator`/`IndicatorView`, so reuse the same indicator on each tab.
- **Ghostty** ([source mirror](https://git.uoc.run.place/Applied-Software/ghostty)): macOS tabs are native NSWindow tabbing, one window and surface per tab, with `tabbingIdentifier` grouping. Known limit: tabs look like separate windows to tiling window managers. Not adoptable. Loom is one window and sets `allowsAutomaticWindowTabbing = false` (`AppDelegate.swift:42`).
- **Conductor** ([conductor.build](https://www.conductor.build/workflows/run-parallel-claude-codes)): the unit is a workspace (a git worktree with its own terminal, diff, checks and PR path). Different problem. Worktree isolation is out of scope here.
- **Claude Squad** ([summary](https://www.sourcepulse.org/projects/2338008)): tmux sessions plus worktrees with a TUI list. It keeps sessions alive by tmux detach, with no tab strip. The point matches Loom: sessions outlive the view.
- **Nimbalyst/Crystal** ([Nimbalyst summary](https://rywalker.com/research/nimbalyst)): kanban of sessions, searchable and persistent. Not tab-based. I could not verify details of Crystal's tab UI.
- **Warp** and **T3 Code tab internals**: not researched in depth. I only have the T3 usage screenshot in the repo. T3 Code itself is an Electron/web app ([search summary](https://ardalis.com/how-to-set-up-t3-code-and-tailscale-on-windows-and-phone/)), so its switching tricks do not transfer.
- Keep-alive versus re-create: the only evidence found is cmux restoring surfaces on relaunch and Ghostty one surface per tab. Loom's own keep-alive is already implemented and cheap (SwiftTerm detaches rendering when `window == nil`: `MacTerminalView.swift:971-984`).

**Compact usage displays**
- **CodexBar** ([steipete/CodexBar](https://github.com/steipete/CodexBar)): menu-bar meter with session and weekly limits. Claude data comes from an OAuth API, browser cookies or a CLI PTY fallback, with adaptive or fixed refresh (1 to 30 min) and caching. Those sources are provider polling, which D-32 forbids. Reuse only the UI idea: a tiny meter, dimmed when stale.
- **ClaudeBar** ([kiminmonaco/ClaudeBar](https://github.com/kiminmonaco/ClaudeBar)): session, weekly and per-model quota percentages. Same caveat on data source.
- **ccusage** ([ryoppippi/ccusage](https://github.com/ryoppippi/ccusage)): daily, monthly, per-session and 5-hour block reports. It reads local JSONL and computes cost from per-model rates (LiteLLM pricing, cacheable offline). It dedups by `(message.id, requestId)` ([secondary description](https://pypi.org/project/ccupp/)). This is the right model for Loom: local, incremental, no provider calls.
- **T3 Code usage page**: from `design/references/t3-code-usage-reference.png`. Top segmented controls: Cost / Tokens / Limits and Past 24h / 7 / 30 / 90 days, plus a refresh button. Big total labelled "API estimate", per-provider split, daily area chart, Totals row (processed, cached, uncached, output, cache savings), cost-by-type and by-speed bars, and a Model/Day breakdown table. For Loom's "lightweight, usage-first" version, take only: the range control, the labelled estimate, the total with a sparkline, and the per-model table.

**Usage data source, observed in the isolated test profile only**
- `…/Loom-Dev/probe/claude-config/projects/<cwd-slug>/<sessionId>.jsonl`.
- Assistant lines carry `message.usage` (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `cache_creation.ephemeral_{5m,1h}`, `service_tier`, `speed`), `message.model`, `message.id`, `requestId`, `timestamp` and `sessionId`.
- Dedup is mandatory: in the test profile 117 usage lines collapsed to 59 distinct `(message.id, requestId)` pairs, with up to 3 lines per pair.
- Do not assume the last duplicate wins. Verify with a fixture and keep the pair-keyed max or last-wins rule explicit.
- Cost needs a rate table. Pricing must ship as a versioned local table labelled "estimate", with no network fetch.
- Format drift risk: the schema is undocumented, so parsing must be tolerant and the per-file byte offset must be persisted. Rotation or truncation must reset the offset.

**Settings pages**
- Today's `SettingsView.swift` is a 25-line `Form` with only a font-size picker, hosted in a separate window (`AppDelegate.settingsWindow`).
- I did not find a reliable survey of native mac dev-tool settings pages. Conservative recommendation: a standard sidebar-less `Settings` layout of grouped sections (Appearance, Terminal, Usage) with the usage view as the main section.

## macOS perf practices

- **@Observable granularity.** SwiftUI records property reads per view body and invalidates only readers of mutated properties ([Inside SwiftUI Observation](https://hackernoon.com/lite/inside-swiftuis-observation-framework)). Assigning a non-Equatable value always counts as a mutation; Equatable values compare first and skip when equal ([Nil Coalescing](https://www.nilcoalescing.com/blog/EquatablePropertiesInObservableClasses)).
  - Loom's `SessionViewState`, `CatalogProject` and `CatalogSession` are Equatable. `SessionRowModel.apply` already guards (`CatalogModel.swift:88-89`).
  - Unguarded: `now = Date()` (always changes), the `projects` array write (Equatable, so a no-op if unchanged), and the `branches[path] = …` subscript writes.
  - Unverified inference: dictionary subscript writes go through `_modify` and may notify even when equal. Confirm with the Instruments SwiftUI template before relying on it.
  - Fix pattern: compare before assign, or move per-row values (relative time text, branch) into `SessionRowModel` so only that row invalidates.
- **List vs LazyVStack.** Loom uses `ScrollView` + `LazyVStack` (`SidebarView.swift:147-148`). One review reports macOS `List` instantiating all rows eagerly ([Apple forum](https://developer.apple.com/forums/thread/718929), [STRV comparison](https://strv.com/blog/swiftui-list-vs-lazyvstack)). That favours the current choice. Another says `LazyVStack` keeps views alive after scroll (memory) and reports a larger scroll-to-bottom hang count. The advice from both: measure first, use stable IDs, keep row work out of `body`. Do not switch containers on speculation.
- **Launch.** Apple's guidance ([Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)):
  - Do only the work the first display needs in the app delegate.
  - Initialize persistent storage on first use.
  - Mark extra startup activities with `os_signpost` in the Points of Interest category.
  - Profile with the Instruments App Launch template, under warm and cold conditions.
  - A figure of about 400 ms to first frame appeared in a secondary summary, not in the Apple page. Treat it as an unverified rule of thumb.
  - Loom's `applicationDidFinishLaunching` already follows the first rule for the runtime but not for the catalog open.
  - Headless measurement: `xctrace` can drive the App Launch template from a script, and signposts can be read from `log`. I did not verify exact `xctrace` flags.
- **Frame rate.** `preferredFrameRateRange` exists on `CAAnimation` since macOS 12 ([CAFrameRateRange](https://developer.apple.com/documentation/quartzcore/caframeraterange/default)). The indicator's `CAKeyframeAnimation` (`CatalogTheme.swift:~185-196`) is discrete at 10 fps (`framesPerSecond = 10`) and does not set it. The CP5 optimizer R-A item (WindowServer cost unmeasured) is open. Stage I should measure WindowServer CPU with a spinning versus still indicator first, then add a range like 10-10 only if the delta is real. I found no source quantifying the saving.
- **Glass and compositing.**
  - Both are facts from source: `NSVisualEffectView` with `.behindWindow` and `.state = .active` (`SidebarBackground.swift:25-30`), and `window.isOpaque = false` with a clear background (`AppDelegate.swift:175-176`).
  - Blur behind the window is rendered by WindowServer ([Cocoa-dev archive](https://lists.apple.com/archives/Cocoa-dev/2008/Aug/msg02096.html)). A non-opaque window forces blending of the whole window.
  - `.state = .active` keeps the material live when the window is inactive. `.followsWindowActiveState` would let it go static. This is an inference, and the saving is unmeasured.
  - Reduce Transparency already falls back to a solid color (`SidebarBackground.swift:16`).
  - Do not trust a generic claim of GPU cost. Measure WindowServer plus GPU with the existing `scripts/perf/indicator_cost.py` and `cp5-gpu-*` tools.
- **Instruments workflow.**
  - Use the SwiftUI template for body counts and the Time Profiler.
  - Release build only.
  - Capture a script of: cold launch, switch 20 times, trigger 10 lifecycle frames.

## Top 8 recommended actions (value/effort order)

1. **Signposts and a launch/switch baseline** (owner **F**, S).
   - Add `OSSignposter` intervals: process start, catalog open, window shown, `model.start` done, first page painted, tab or conversation switch.
   - Record cold and warm numbers before changing anything.
   - Every later perf claim in the run depends on this.
2. **Decouple first-page load from runtime start, and take the catalog open off the first-paint path** (owner **F**, M).
   - `model.start()` needs only the catalog and hub.
   - Remove `restoreCatalogSessions` loading all sessions (`ProcessSupervisor.swift:1467`; the open optimizer item F8).
   - Move `quick_check` to a post-first-paint check, or bound it.
   - Keep the shutdown wait on `startupTask` (`AppDelegate.swift:129-136`) correct. Do not weaken the catalog-refusal and quit-ordering behavior.
3. **Stop the sidebar invalidation storm** (owner **F**, S-M).
   - Read git branch off MainActor.
   - Cache it per cwd with a `.git/HEAD` mtime check, or refresh only at turn end and window activation.
   - Do not write `now` or `branches` unless the value changed.
   - Move per-row relative time and branch into `SessionRowModel`.
   - Verify body counts before and after with the Instruments SwiftUI template. Keep a regression test on the observable behavior only if it is stable.
4. **Tabs on top of the existing keep-alive terminals** (owner **U**, M).
   - The tab model references live `ConversationController.entries`. A tab is a pinned `SessionRowModel` id and holds no terminal itself.
   - Measure the current switch latency (signposts from #1) before deciding between swap and a persistent container with visibility toggling.
   - Reuse `SessionIndicator` on each tab chip.
   - Closing a tab must never stop a run. This matches the contract rule that viewing, running and closing are separate (`LOOM-PRODUCT-CONTRACT.md:15`).
   - Persist the tab list in `ui-preferences.json`. This is a small schema extension through `UIPreferencesStore`.
5. **Local, incremental usage reader** (owner **U**, M).
   - Track a per-file byte offset. Parse with a tolerant JSON reader. Dedup by `(message.id, requestId)`.
   - Aggregate per day and per model. Persist the aggregate and offsets in a small file or a new catalog table (an O-schema decision for the main session).
   - Cost comes from a local versioned rate table, labelled "estimate".
   - Reading happens on a background actor with a bounded budget.
   - Run it only when the window is visible, or on-demand with a refresh button as in the T3 reference.
   - Fixture-test against `loom-fake-provider` output.
   - Cross-check totals against Claude's own records on test data, as the roadmap asks.
6. **Measure WindowServer cost of the indicator and sidebar glass, then decide** (owner **I**, S then optional S).
   - Measure the indicator-spinning versus still delta. If it is meaningful, apply `preferredFrameRateRange` on the keyframe animation.
   - Evaluate `NSVisualEffectView.state = .followsWindowActiveState`. Keep it only if the visual and cost result is better.
   - Use the existing GPU and CPU measurement scripts.
7. **Compact sidebar footer usage chip + settings page** (owner **U**, S-M).
   - Footer: plus button, a small usage meter, and the gear (`SidebarFooter`, `SidebarView.swift:112-141`).
   - Settings: replace the 25-line `SettingsView` with grouped sections plus a usage section (range control, total, sparkline, per-model table).
   - Both read the #5 aggregate from one `@Observable` so they do not re-evaluate on unrelated model changes.
8. **Retention/deletion must not regress paging** (owner **CP4**, input only).
   - Deletion and cleanup should publish through the same hub frames (`catalogRevision`) so `CatalogModel.apply` triggers one coalesced refresh (`scheduleRefresh`, 100 ms).
   - Do not add per-row git reads or a full list reload on delete.
   - Late events for a deleted id should hit the `lookUpLiveRecord` path (`CatalogModel.swift:291`) and must not resurrect a row.

## What NOT to adopt and why

- **Provider polling** (CodexBar's OAuth, cookies, PTY `/usage`, ClaudeBar quota calls). It violates D-32 (no extra CLI processes, no provider polling). Local JSONL only. Limit and reset percentages are out unless found locally.
- **Ghostty-style native NSWindow tabs.** One window per tab conflicts with the one-window design and the disabled automatic tabbing (`AppDelegate.swift:42`).
- **tmux-backed persistence (cmux `local-tmux`, Claude Squad).** It would add a process layer outside Loom's run-scope ownership model (ARCHITECTURE §4).
- **Worktree workspaces (Conductor, Crystal).** A separate product axis, not in this run's scope.
- **Switching `LazyVStack` to `List` or a rewrite to AppKit** without measurements. The sources conflict. Fix invalidation first (#3).
- **Hover-prefetch of terminals or sessions.** Terminals are already alive. Prefetching catalog rows adds queries for little gain.
- **V8 cache, web workers, static HTML, layout-shift telemetry.** Web-only.
- **Feature-flag infrastructure and 1% rollouts.** There is one power user. One launch-option kill switch per risky change is enough.
- **Metal or GPU renderer work.** Deferred by decision (ARCHITECTURE header; O-07). The Core Graphics path with partial invalidation is the product renderer.
- **Real-user data for any of this.** All measurement and usage fixtures must stay on the isolated test profile or synthetic data. Never read the real `~/.claude`, or the installed apps' data.

Unverified or open:
- The `branches` dictionary and `now` over-invalidation is an inference. Confirm with Instruments.
- Startup cost of `quick_check` and `restoreCatalogSessions` on a large catalog is unmeasured.
- I could not read the Warp tab internals or the T3 Code tab UI. The tab recommendations rest on cmux, Ghostty and the repo's `layout-guidance.jpg` (a plain tab strip above the main content).
- Blog numbers are model-summarized.

Files:
- `/Users/gencberke/Documents/github/loom-dev/Sources/loom-app/AppDelegate.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/CatalogModel.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/SidebarView.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/DetailView.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/ConversationController.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/GitBranch.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/SidebarBackground.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/CatalogTheme.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/SettingsView.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/SessionCatalog.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/ProcessSupervisor.swift`
- `/Users/gencberke/Documents/github/loom-dev/Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift`