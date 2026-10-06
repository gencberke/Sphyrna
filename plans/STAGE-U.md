# Stage U — daily-use UI features

Part of [multi-agent run 1](RUN-1.md). Roadmap row: [ROADMAP → U](../ROADMAP.md#u-daily-use-ui-features-proposed). Decisions: [D-32](../DECISIONS.md) (usage and cost view, Settings page, footer bar), [D-33](../DECISIONS.md) (conversation tabs), [D-34](../DECISIONS.md) (no left rail, no right sidebar). Facts: [U integration scan](experiments/run1-planning-scans/U-integration.md), [usage data scan](experiments/run1-planning-scans/U-usage-data.md), [performance research](experiments/run1-planning-scans/perf-research.md). References: [T3 usage page](../design/references/t3-code-usage-reference.png), [layout guidance](../design/references/layout-guidance.jpg).

## Goal

Three daily-use surfaces in identity A, designed first as an HTML preview, then built: a compact sidebar footer bar (new conversation, compact Claude usage, Settings), a real Settings page with a lightweight usage-first view and a labelled cost estimate, and conversation tabs above the terminal for quick switching between a few threads. Usage data costs nothing visible on Claude's side.

## Slices

| Slice | Delivers | Write area (summary) | Wave | Depends on | State |
| --- | --- | --- | --- | --- | --- |
| [UD](u/UD.md) | HTML preview of the footer bar, Settings (General, Usage, About) and the tab strip, in identity A tokens | `design/run1-surfaces-preview.html` | 1 | — | planned |
| [U0](u/U0.md) | Claude usage index: incremental, bounded, deduplicated reader of local transcripts; aggregates; static price table; `ClaudeProfileLayout` | new `Sources/LoomCore/ClaudeUsage*.swift`, `ClaudeProfileLayout.swift`, `UsagePricing.swift`, tests | 1 | — | planned |
| [U1](u/U1.md) | `UsageModel`; a real Settings window (forced dark) with General, Usage and About; refresh triggers; Settings evidence commands | new `Sources/loom-app/SettingsWindowController.swift`, `Sources/LoomCatalogUI/UsageModel.swift`, `SettingsView.swift` rewrite, one-line hooks in `AppDelegate`/`CatalogModel`, evidence file | 3 | U0, I1, F3, UD | planned |
| [U2](u/U2.md) | Sidebar footer bar: `+` menu, compact usage chip (opens Settings at Usage), gear | new `Sources/LoomCatalogUI/SidebarFooter.swift`, mount line in `SidebarView.swift` | 3 | U1, I1, UD | planned |
| [U3](u/U3.md) | Tab state: `ConversationTabs` (pinned + one transient), persisted `openTabs`, row retention, follow `/clear`, forget hook | `UIPreferences.swift`, new `ConversationTabs.swift`, `CatalogModel.swift`, `ConversationController.swift`, tests | 2 | F1 | planned |
| [U4](u/U4.md) | Tab strip view, shortcuts, menu items, tab evidence commands and snapshot fields; switch-latency measurement | new `ConversationTabStrip.swift`, mount in `DetailView.swift`, `AppDelegate.installMenus`, evidence file | 4 | U3, I1, UD, F5 (signposts) | planned |
| [U5](u/U5.md) | Daily-use polish: relative times and day headings tick while the window is active; window frame persisted; visible "Preparing…" on a first start | `CatalogModel.swift`, `SidebarView.swift`/`SessionDisplay.swift`, `AppDelegate.makeWindow`, `ConversationController.swift` | 4 | F5, U3 | planned |

## Decisions taken in planning (routine)

- **Settings stays an `NSWindow` + `NSHostingController`** (the app is a pure AppKit lifecycle; no SwiftUI `Settings` scene), moved into its own controller file; forced dark (identity proposal §5 item 8, A's value).
- **Usage index is its own disposable SQLite file** (`usage-index.sqlite3` in the data root), not the catalog: rebuildable, versioned, never blocks the catalog actor.
- **Refresh triggers only:** Claude `Stop`/`StopFailure` hook (the turn-complete frame `CatalogModel.apply` already sees, plus the hook's `transcript_path` for a one-file tail read), Settings opened, app activation, launch after first paint. No timers, no work while hidden, no extra processes, no network.
- **Cost** is computed at query time from a static, dated price table (`as of` shown in the UI), labelled an API-equivalent estimate; unknown models show tokens and "—".
- **Tabs** live in their own row inside the detail panel between the header and the terminal, hidden when fewer than two tabs exist; terminals stay in `ConversationController.entries` (already kept alive per live run), so a tab switch is a view swap, never a new terminal (contract §10).
- **Forget hooks:** U3 (tabs) and U0 (usage index) each expose `forget(sessionID:)` / `forgetSession(providerIDs:)` used by CP4 deletion.

## Decision points (user)

DP-U1 tab model, DP-U2 tab shortcuts, DP-U3 usage scope, DP-U4 plan limits, DP-U5 price table — see [RUN-1](RUN-1.md#decision-points-for-the-user). Defaults are built so the user can review a working surface.

## Acceptance (stage)

- **U-A1** Footer: same new-conversation and Add Project actions as today's `+` menu; usage chip shows today's Claude tokens (and est. cost secondary) from the index, truncates at the 220 pt sidebar minimum with the full text in tooltip and accessibility label, opens Settings at Usage; gear opens Settings.
- **U-A2** Settings: Cmd+, opens one reused, dark window; terminal font size applies live as today; Usage section shows periods (24 h, 7 d, 30 d, 90 d), totals by token type, per-day bars, per-model table with share and est. cost, a labelled local 5-hour activity window, "as of" and price-table date; About shows version and data location. Evidence screenshot of the Settings window from its own views.
- **U-A3** Usage numbers: on synthetic transcript fixtures (duplicates, partial lines, sidechains, rewrites, unknown models), token totals equal the fixture's deduplicated truth exactly; cost equals hand-computed values; on the isolated real profile, tokens equal a transcript recount (ccusage-style dedupe) and cost is within a stated tolerance of Claude's own `cost-state` for sessions without auxiliary calls (2 real turns budgeted).
- **U-A4** No visible load: no new processes (process count before/after a refresh), no timers while hidden (idle wakeups unchanged in the indicator/idle cells), a warm refresh with no new bytes reads no file content; cold scan of a generated 1 GB corpus bounded in time and memory (recorded).
- **U-A5** Tabs: pin/unpin, transient tab replaced on sidebar selection, close never stops a run and selects the neighbor, persisted across relaunch, follows `/clear` and `/new` ownership moves, stale/ended tabs show their record without starting anything, shortcuts work, switch latency measured (signposts) and no worse than sidebar switching.
- **U-A6** Idle and render costs at baseline (matrix + indicator cells); screenshots of all new surfaces match the preview and identity A; the user's review of the surfaces at the end of the run.

## Evaluation and closure

Stage-end recipe in [RUN-1](RUN-1.md#stage-end-evaluation-recipe) (all steps). Optimizer before closing.

## Real-Claude turns

Planned 2 (U-A3). Used: 0.

## Results

None yet.
