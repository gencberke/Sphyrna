# Stage U — daily-use UI features

Part of [multi-agent run 1](RUN-1.md). Roadmap row: [ROADMAP → U](../ROADMAP.md#u-daily-use-ui-features-proposed). Decisions: [D-32](../DECISIONS.md) (usage and cost view, Settings page, footer bar), [D-33](../DECISIONS.md) (conversation tabs), [D-34](../DECISIONS.md) (no left rail, no right sidebar). Facts: [U integration scan](experiments/run1-planning-scans/U-integration.md), [usage data scan](experiments/run1-planning-scans/U-usage-data.md), [performance research](experiments/run1-planning-scans/perf-research.md). References: [T3 usage page](../design/references/t3-code-usage-reference.png), [layout guidance](../design/references/layout-guidance.jpg).

## Goal

Three daily-use surfaces in identity A, designed first as an HTML preview, then built: a compact sidebar footer bar (new conversation, compact Claude usage, Settings), a real Settings page with a lightweight usage-first view and a labelled cost estimate, and conversation tabs above the terminal for quick switching between a few threads. Usage data costs nothing visible on Claude's side.

## Slices

| Slice | Delivers | Write area (summary) | Wave | Depends on | State |
| --- | --- | --- | --- | --- | --- |
| [UD](u/UD.md) | HTML preview of the footer bar, Settings (General, Usage, About) and the tab strip, in identity A tokens | `design/run1-surfaces-preview.html` | 1 | — | accepted (see Results) |
| [U0](u/U0.md) | Claude usage index: incremental, bounded, deduplicated reader of local transcripts; aggregates; static price table; `ClaudeProfileLayout` | new `Sources/LoomCore/ClaudeUsage*.swift`, `ClaudeProfileLayout.swift`, `UsagePricing.swift`, tests | 1 | — | accepted (see Results) |
| [U1](u/U1.md) | `UsageModel`; a real Settings window (forced dark) with General, Usage and About; refresh triggers; Settings evidence commands | new `Sources/loom-app/SettingsWindowController.swift`, `Sources/LoomCatalogUI/UsageModel.swift`, `SettingsView.swift` rewrite, one-line hooks in `AppDelegate`/`CatalogModel`, evidence file | 3 | U0, I1, F3, UD | accepted with U2 as slice U12 (this commit) |
| [U2](u/U2.md) | Sidebar footer bar: `+` menu, compact usage chip (opens Settings at Usage), gear | new `Sources/LoomCatalogUI/SidebarFooter.swift`, mount line in `SidebarView.swift` | 3 | U1, I1, UD | accepted with U1 as slice U12 (this commit) |
| [U3](u/U3.md) | Tab state: `ConversationTabs` (pinned + one transient), persisted `openTabs`, row retention, follow `/clear`, forget hook | `UIPreferences.swift`, new `ConversationTabs.swift`, `CatalogModel.swift`, `ConversationController.swift`, tests | 2 | F1 | accepted `45ecbc2` |
| [U4](u/U4.md) | Tab strip view, shortcuts, menu items, tab evidence commands and snapshot fields; switch-latency measurement | new `ConversationTabStrip.swift`, mount in `DetailView.swift`, `AppDelegate.installMenus`, evidence file | 4 | U3, I1, UD, F5 (signposts) | planned |
| [U5](u/U5.md) | Daily-use polish: relative times and day headings tick while the window is active; window frame persisted; visible "Preparing…" on a first start | `CatalogModel.swift`, `SidebarView.swift`/`SessionDisplay.swift`, `AppDelegate.makeWindow`, `ConversationController.swift` | 4 | F5, U3 | planned |

## Decisions taken in planning (routine)

- **Settings stays an `NSWindow` + `NSHostingController`** (the app is a pure AppKit lifecycle; no SwiftUI `Settings` scene), moved into its own controller file; forced dark (identity proposal §5 item 8, A's value).
- **Usage index is its own disposable SQLite file** (`usage-index.sqlite3` in the data root), not the catalog: rebuildable, versioned, never blocks the catalog actor.
- **Refresh triggers only:** Claude `Stop`/`StopFailure` hook (the turn-complete frame `CatalogModel.apply` already sees, plus the hook's `transcript_path` for a one-file tail read), Settings opened, app activation, launch after first paint. No timers, no work while hidden, no extra processes, no network.
- **Cost** is computed at query time from a static, dated price table (`as of` shown in the UI), labelled an API-equivalent estimate; unknown models show tokens and "—".
- **Tabs** live in their own row inside the detail panel between the header and the terminal, hidden when fewer than two tabs exist; terminals stay in `ConversationController.entries` (already kept alive per live run), so a tab switch is a view swap, never a new terminal (contract §10).
- **Forget hooks:** U3 (tabs) and U0 (usage index) each expose `forget(sessionID:)` / `forgetSession(providerIDs:)` used by CP4 deletion.

## Design picks from the UD preview (planner, within the identity; the user reviews the built surfaces at the end)

- **Footer chip:** variant (a), text: `Today 1.2M tok · ~$3.10`. Tokens first; the cost drops out whole when it does not fit (never a cut number). Number format: below 1,000 plain; then `K`, `M`, `B` with three significant digits at most (`940K`, `12.4M`, `1.28B`); cost `~$3.10`, whole dollars from $1,000 (`~$12,846`). States: `Indexing…`, `No usage yet`. Full figures in the tooltip and accessibility label.
- **Footer buttons** keep today's 28×26 pt (UI-MAP), not the preview's 26×24.
- **Settings:** top section switcher General · Usage · About; fixed 680×520 window; the Usage body scrolls. About shows version, data folder and the Claude profile in use (read-only).
- **Usage view:** neutral bars (past days `text.secondary`, today `text.primary`); the 5-hour block is five hourly cells in white-alpha intensity, no accent, labelled "approximate" and "not your plan limit".
- **Tabs:** the transient tab has an italic title and is pinned by double click, "Open in Tab", or starting/resuming its conversation; close button on hover and on the selected tab (only the selected tab reserves its slot), its fill is the `press` white alpha; tabs shrink to 112 pt, then the strip scrolls and a 28 pt chevron lists every tab with a dot for the highest-priority off-screen status.
- **Focus ring:** the accent ring from I2 (`Surface.focusRing`), only under keyboard navigation.

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

- **UD** (accepted with this wave's commit): `design/run1-surfaces-preview.html`; planner fixes on accept: consistent 5-hour mock (0.9M, 9 AM–2 PM at "Updated 14:02"), `1.28B` long-value format, `Indexing…` at 220 pt, close-button fill from the `press` token, overflow arithmetic including the chevron. Picks above.
- **U0** (accepted with this wave's commit): `ClaudeUsageIndex` (actor, own `usage-index.sqlite3`), `ClaudeUsageParser`, `UsagePricing` (official page, as of 2026-10-07), `ClaudeProfileLayout`, `UsageSnapshot`; 49 tests incl. eight mutation checks; 1 GiB synthetic corpus: cold 4.25 s, ~14 MB extra RSS, warm no-change refresh 2 ms, 1.4 MiB append 26 ms (warm page cache, upper bound). Accepted deviation: messages are keyed by `message.id` alone (a sidechain replay under a new `requestId` still counts once). Known limits, follow-ups: raw rows are not pruned (~106 bytes per message; a 15-minute roll-up with pruning is the recommended later step), a file reset can undercount a duplicate owned by another file until that file changes, a corruption during `forget` loses the forgotten list.
- **U12 = U1 + U2** (this commit): `UsageModel` (refresh on launch after the first page, activation outside a 10 s cooldown, Settings open, a finished Claude turn debounced 2 s, manual; coalesced; no timers; index work on the index's own queue), `SettingsWindowController` (one reused, dark, fixed 680×520 window; General · Usage · About), the Usage view (24 h / 7 d / 30 d / 90 d, totals, bars, model table, five-hour cells, estimate label, "Updated" and "Prices as of"), `SidebarFooter` with the usage chip (variant a). Profile rule: evidence runs use `<data-root>/claude-config`; otherwise `CLAUDE_CONFIG_DIR` from Loom's own environment, else `~/.claude`; no login shell. Package run: 26/26 checks, 7 d totals equal the deduplicated fixture truth (18,909,305 tokens, $28.634375). Planner fixes: an activation during a running refresh adds no run (failing-first test), warm refreshes keep "Updated …", the indexing tooltip promises only what exists. Settings is fixed-size, not "resizable within limits" as U1.md said (the picks decided fixed). Open: the index is not partitioned per Claude profile (one profile per app run today); U-A3's real-Claude cross-check runs at the stage end.
- **U3** (`45ecbc2`): `ConversationTabs` and `CatalogModel` tab API (`tabs`, `visibleTabIDs`, `openTab`, `closeTab`, `forget(sessionID:)`, `tabOwnerMoved`); preference writes debounced 300 ms and flushed at stop/quit; 82 `LoomCatalogUITests` pass. Tests were shown to fail by a six-bug mutation run rather than test-first.
