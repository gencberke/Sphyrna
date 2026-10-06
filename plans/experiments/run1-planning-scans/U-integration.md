# Stage U code-integration analysis (daily-use UI features, read-only)

## Summary

**Facts**
- The app is a pure AppKit lifecycle (`Sources/loom-app/main.swift:4-8`). A SwiftUI `Settings` scene is not available, so Settings stays an `NSWindow` with an `NSHostingController`.
- Every live Claude run already has its own `TerminalSurface` plus `TerminalContainerView` in `ConversationController.entries`. Terminals are created only at start or resume, never on selection.
- Switching is cheap. `DetailContent` swaps one `NSView` (`DetailView.swift:163-167`), and the surface keeps ingesting PTY output while detached.
- Per-switch work is: one preference write (`CatalogModel.swift:439`), `updateViewing` (`:499-508`), and one runtime `markViewed` call. The `markViewed` call then triggers a `catalog.session(id:)` read in `refreshRow` (`:662-678`). Whether `markViewed` also writes the catalog is inferred, not read.
- The Settings window is not forced dark. The main window forces `darkAqua` (`AppDelegate.swift:174`); Settings sets no appearance (`:604-616`).
- Usage data: Claude's own transcripts hold per-message token usage but no cost field.
  - The probe profile has 117 assistant lines but only 59 unique `message.id` + `requestId` pairs, so duplicates must be removed.
  - Usage fields: `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, and `cache_creation.ephemeral_{5m,1h}`.
  - Also present: `model`, `speed`, `service_tier`, and `<synthetic>` model lines.
  - `costUSD` is absent in 0 of 117 lines, so cost is a price-table estimate.
- The refresh trigger already exists. `CatalogModel.apply` sees `.status(turnComplete)` frames (`CatalogModel.swift:687`), driven by the Claude `Stop` hook.

**Recommendations (details below)**
- Tabs: a "pinned tabs plus transient selected tab" model, rendered in its own strip row inside the detail panel.
- Usage: a bounded incremental reader in LoomCore, fed into an `@Observable UsageModel`.
- Refresh: on turn-complete frames, window activation, and opening Settings. No timers and no provider polling.
- Parallelism: the usage reader (U0) and the tab state model (U3) have no UI dependencies and can run in parallel. U0 and U3 touch disjoint files.

## 1. Footer, Settings, preferences

**Footer**
- `SidebarFooter` is at `SidebarView.swift:112-141`: a 38 pt HStack with a `plus` Menu on the left and a `gearshape` Button on the right, using `ChromeButtonStyle(size: 28×26)`.
- The `plus` Menu contains `NewConversationButtons(model:projectID: model.contextProjectID)`, a Divider, and "Add Project…".
- `NewConversationButtons` is at `:371-382` and iterates `NewConversationAction.all` (`:388-391`, Claude and Codex).
  - The same component feeds `ProjectHeader`'s menu (`:259`) and its context menu (`:274`).
  - Stage F will edit `NewConversationAction.all`, in the same file as the footer.
- `contextProjectID` is `selectedRow?.record.projectID` (`CatalogModel.swift:757`). It is also used by the File menu items (`AppDelegate.swift:450,452,467,469`). Tabs do not change it, because selection still defines the context.
- The gear calls `model.onShowSettings?()` (`:129`), wired at `AppDelegate.swift:80`.
- A collapsed sidebar hides the footer. That is the same as today; Cmd+, and Cmd+N still work.

**Settings**
- `showSettings` (`AppDelegate.swift:604-616`) creates a lazy `NSWindow`, 360×150, `[.titled, .closable]`, with `NSHostingController(SettingsView(model:))`, and reuses it.
- Cmd+, is bound at `:622`.
- `SettingsView.swift` (25 lines) holds one font Picker (11…20), `setTerminalFontSize` (`CatalogModel.swift:487-491`), a caption, and a red `errorMessage`.
- Font application goes through `onTerminalFontSizeChange` (`AppDelegate.swift:81-84`) to `ConversationController.setTerminalFontSize` (`:78-80`).

**Preferences**
- `UIPreferences` fields: `viewMode`, `selectedSessionID`, `sidebarWidth`, `sidebarCollapsed`, `terminalFontSize` (`UIPreferences.swift:16-20`).
- Decoding is tolerant: each key uses `try?` with a default (`:32-44`). Values are clamped in `init` and again in `update` (`:90-95`).
- `UIPreferencesStore.update` writes atomically and only when the value changed. It writes at 0700 permissions to `<data-root>/ui-preferences.json`. An unreadable file is moved aside (`:67-85`).
- `UIPreferences.init` has default parameters, so adding a field does not break existing call sites.
- Existing tests that cover these:
  - `DisplayAndPreferencesTests.swift:88-138` (round trip, clamp, aside, write failure).
  - `ProductPreferencesTests.swift:8` (font).

## 2. Selection and terminal attachment

- `CatalogModel` holds `selectedSessionID` and `selectedRow` (`:129-130`).
  - `select(id)` (`:434-443`) sets `showsDevTerminal = false`, updates both, persists, and calls `ensureSelectedRow` when the row is not loaded.
  - It always calls `updateViewing()`.
  - Only `selectedRow` is exempt from pruning (`pruneRowModels`, `:390-400`: it keeps the rows in loaded lists plus the selection). Rows for other tab IDs would be dropped unless added to the keep set.
- Callers of `select`:
  - The sidebar card button (`SidebarView.swift:317`).
  - `ConversationController.start` (`:164,169`) and `resume` (`:192`).
  - `reconcile` (`:291`): when a terminal changes owner after `/clear` or `/new`, selection follows to the new card.
  - The evidence `select:` command (`DevelopmentEvidence.swift:179`).
- `ConversationController.adopt` (`:246-268`) creates `Entry{runID, surface, container, owner}` (`:40-45`).
  - The surface is built before launch at `:148` and `:182`.
  - `terminalView(sessionID:)` returns the container of the entry whose `owner == sessionID` (`:240-242`).
  - Entries are removed only when the run ends (`reconcile`, `:277-284`).
- `DetailContent` (`DetailView.swift:152-192`) shows `RequestList` plus `TerminalHost(panel:).id(ObjectIdentifier(terminal))` when a terminal exists.
  - Otherwise it shows `ConversationDetail`, a history record that launches nothing.
  - `model.terminalView(for:)` reads `terminalRevision`, so the pane re-evaluates when terminals appear or end.
- `TerminalContainerView` (`ConversationController.swift:8-32`) re-focuses the terminal asynchronously on `viewDidMoveToWindow`.
- The vendored terminal view stops its loops when its window becomes nil (`MacTerminalView.swift:971-998`) and marks itself dirty when re-attached. `suspendsRenderingWhenNotVisible = true` (`TerminalSurface.swift:158`).
- **Inference:** tab switching costs one view swap, one redraw, and the per-switch work listed in the Summary. No new terminals are needed.
  - The preference write on every switch could be debounced.
  - CP5 recorded a P3 scenario "stale row after switching during a stream" (`plans/cp5/CLOSURE.md:180`). It is a regression target for the tab evidence.

## 3. Tabs design

**Where the strip fits**
- `DetailView.body` is a VStack of `DetailHeader` (36 pt row plus 16 pt padding = 52 pt, centered on the traffic-light line), `Banners`, and `DetailContent` (`DetailView.swift:11-15`).
- The header carries the title, indicator, status label, Stop, and the ellipsis menu. The `controlHitTests` sweep (`AppDelegate.swift:895-936`) assumes that geometry.
- **Recommended:** a separate `ConversationTabStrip` row (about 30 pt) between `Banners` and `DetailContent`, inside the panel. This is the reference layout (`design/references/layout-guidance.jpg`: tabs above main content).
  - It does not touch the traffic-light centerline or the header hit tests.
  - It is independent of the pending navbar decision O-03.
  - Stage I may later fold the header and tabs together. The strip is a standalone view, so that is a mount-point change only.
- **Hide when empty:** show the strip only when there are two or more tabs. With a single conversation the window looks exactly as it does today.

**State model (recommended)**
- Persist only an ordered `openTabs: [UUID]` of pinned tabs in `UIPreferences`. Cap it at about 8, decode tolerantly, and de-duplicate in `update`.
- The strip shows `pinned + (selected is not pinned ? [selected] : [])`. The selected-but-unpinned entry is a transient (preview) tab; selecting another sidebar row replaces it.
- Pin events:
  - Explicit "Open in Tab" from the card context menu or by double-clicking a card.
  - Automatically when a conversation is started or resumed (`ConversationController.swift:164,169,192`). Those are the conversations the user actually works in.
- Over the cap, evict the oldest pinned tab that is not live and not in an attention state.
- **Rejected alternatives:**
  - Every selected row becomes a tab: tabs grow unbounded and persist browsing noise.
  - Explicit pin only: the selected conversation would have no visible place, and a stale or ended row would be unreachable from the strip.
- Implementation shape: a small `@MainActor @Observable ConversationTabs` in a new file, owned by `CatalogModel` and persisting through the existing `persist` closure.
  - Add the tab IDs to the `pruneRowModels` keep set.
  - Run `ensureRow` for each tab in `start()` (`:222-223`). That is at most 8 point lookups.
  - Tab titles and indicators then come from `SessionRowModel` (`title(of:)`, `indicator`). Rename (`refreshRow`) and live state updates reach the tabs for free once their rows are retained.
- Edge cases the plan must name:
  - `/clear` or `/new` ownership change (`reconcile`, `:285-292`): if the old owner was pinned, the tab should follow the terminal to the new card (a `replace(old, new)`). Test target: `ConversationControllerTests.swift:348,447`.
  - Closing a tab never stops a run. The terminal stays in `entries` and the sidebar card is unchanged. This is a user-visible semantic; flag it for the user.
  - Closing the selected tab selects the right neighbor, else the left, else `select(nil)`.
  - Stale, ended, and problem rows keep their normal indicators. A stale row's title is dimmed as on the card.
  - Selecting any tab only shows it. It never starts a provider, PTY, or terminal (contract §10; `select` doc comment `:433`). Idle and stale tabs show `ConversationDetail`.
  - Future CP4 delete: expose one `tabs.remove(sessionID)` hook that delete calls alongside `select(nil)`.
  - `ensureSelectedRow` already clears selection of a missing row (`:450-453`). Do the same for missing tab IDs.

**Keyboard**
- Taken (`AppDelegate.swift:618-689`): Cmd+, Cmd+H Cmd+Q Cmd+O Cmd+N Shift+Cmd+N Cmd+R Cmd+. Cmd+W Opt+Cmd+N (evidence builds) Cmd+C Cmd+V Cmd+A Ctrl+Cmd+S Cmd+1 Cmd+2 Cmd+M.
- Free for tabs: Ctrl+Tab and Ctrl+Shift+Tab; Shift+Cmd+] and Shift+Cmd+[ (the standard macOS next and previous tab shortcuts); Cmd+3…9; Opt+Cmd+W for Close Tab.
- Cmd+W must keep closing the window.
- Menu key equivalents win over the terminal's `keyDown`, so avoid common terminal and TUI keys.
- Recommended set: Shift+Cmd+]/[ for next/previous tab, plus Ctrl+Tab and Ctrl+Shift+Tab. Close Tab gets a File menu item. Decide the exact bindings with the user.

**Evidence and verification**
- Commands exist for `select:`, `start:`, `resume:`, `stop:`, `begin-rename:` and others (`DevelopmentEvidence.swift:173-239`). Nothing exists for tabs.
- Snapshot fields to add: `tabs.ids`, `tabs.pinned`, `tabs.selected`, `tabs.transientID`, and `preferences.openTabs` in the preferences dict at `AppDelegate.swift:776-781`.

## 4. Footer and Settings architecture

**Settings window**
- Keep the `NSWindow` plus `NSHostingController` approach.
- Move creation out of `AppDelegate` into a new `Sources/loom-app/SettingsWindowController.swift`. This isolates it from stage F's edits to `AppDelegate`; `showSettings` becomes one call.
- Set `appearance = .darkAqua` and `.preferredColorScheme(.dark)`. IDENTITY-PROPOSAL §5 item 8 says every direction assumes yes.
- Resizable, with a sensible default (about 640×520).
- Sections: General (terminal font size), Usage (summary, per-model and per-day breakdown), Providers (install status, which is specified but not built per UI-MAP), About (version).
- `onShowSettings` should carry an optional section so the footer usage chip can open Settings at Usage.
- Keep showing `model.errorMessage`, but in theme tokens rather than system red.

**Usage data flow**
- `UsageReader` (non-UI) in LoomCore. It scans `<config>/projects/**/*.jsonl` for the Claude config directory.
  - **Config directory resolution matches the registry reader:** the profile's `CLAUDE_CONFIG_DIR`, else `~/.claude` (`SessionRuntime.swift:681-682`; `ProviderToolchain.swift:5-6`; production `profileDirectory == nil`).
  - The reader must be given the directory by `AppDelegate`.
  - Evidence plus `--fake-providers` uses `<data-root>/claude-config` (`AppDelegate.swift:423-425`). Evidence with real providers uses `--claude-config` (`:433`).
  - Tests use temp fixtures only; the real `~/.claude` is never test material.
- Reader constraints (the "no visible load" rule of D-32):
  - Incremental. Keep a per-file byte offset and fingerprint. Read only appended bytes and never advance past the last newline.
  - Reset the offset if the file shrank.
  - Cheap prefilter: parse a line only if it contains `"type":"assistant"`.
  - Keep only `model`, `usage`, `timestamp`, `message.id`, `requestId`; never retain conversation text.
  - Dedupe on `(message.id, requestId)`; skip `<synthetic>` lines.
  - Bounded first scan: files modified within the last N days (propose 30), run at utility QoS off the main actor in chunks.
  - Persist aggregates and offsets in a per-bundle cache in the data root, so a restart does not rescan.
  - Aggregates are per day and per model: input, output, cache read, cache creation (5m and 1h separate), plus an estimated cost.
- Cost is an estimate from a maintained price table. Label it "estimate" (it is hypothetical for flat-rate users).
  - An unknown model shows tokens and no cost.
  - **Open input:** the price table values are not in the repo and must be verified by the user or from official pricing, not from memory.
- `@MainActor @Observable UsageModel` in LoomCatalogUI holds the latest snapshot and loading, error, and "as of" state. It is owned by `AppDelegate` and attached as `model.usage` (optional). `SidebarView(model:)` and `SettingsView(model:)` keep their init signatures, so `SidebarStatusTests.swift:236` still compiles.

**Zero-cost refresh triggers**
- Turn complete: `CatalogModel.apply` already tests `.status(turnComplete)` (`CatalogModel.swift:687-691`). Add a debounced `usage?.noteTurnComplete()` of about 2 s, because the transcript flush may trail the `Stop` hook.
  - Origin of the frame: Claude `Stop` hook → `ClaudeSessionAdapter.receive` (`ProviderSessionAdapters.swift:~110-134`) → `supervisor.updateProviderWorkState` → `events.publish(.status)` (`ProcessSupervisor.swift:220`) → `SessionEventHub.publish` (`SessionEventHub.swift:136-186`).
- Window becomes active: `setWindowActive(true)` (`CatalogModel.swift:467-475`).
- Settings opens: `showSettings`.
- Launch: after `model.start()`.
- No timers. The hook already carries `transcript_path` (`ClaudeHook.swift:365,395`), but it is not forwarded through the hub. Passing it would allow tail-reading only that file; it is an optional optimization.
- **Limits:** local transcripts contain no plan or rate-limit data. A "Limits" view like the T3 reference (`design/references/t3-code-usage-reference.png`, "Limits" tab) has no local source I found. A `statusLine` command would be an extra process per update, which D-32 forbids. The footer chip should therefore show usage figures (for example today's tokens and estimated cost), not "percent of limit".
  - Whether Claude exposes limit data locally is unverified.
- Scope question: usage covers everything under that Claude config directory, which includes sessions started outside Loom. The alternative, Loom's own sessions only, needs a catalog join on `providerConversationID`. See the decision points.

**Footer**
- New file `Sources/LoomCatalogUI/SidebarFooter.swift` (move `SidebarFooter` out of `SidebarView.swift`; replace it there with the one `SidebarFooter(model:)` mount line).
- Layout: `+` menu on the left, a compact usage chip in the middle (hidden when there is no data), and the gear on the right. The chip is a Button that opens Settings at Usage.
- Width budget: at the 220 pt minimum sidebar there are about 130 pt for the chip after padding and the two 28 pt buttons. The chip must truncate and carry the full text in a tooltip and accessibility label.
- Height 38 pt today; the new bar can be a little taller if needed.
- DESIGN.md §2 item 5 (the kept bottom `+` and Settings) and UI-MAP's Settings text need updates, authorized by D-32.

## 5. Evidence and test tooling

- `saveScreenshot` renders only `window.contentView` and its frame view (`AppDelegate.swift:845-857`). Settings, sheets, and menus are not captured (UI-MAP "Verifying UI safely"). The `screenshot` command is skipped for real providers (`DevelopmentEvidence.swift:231`).
- The footer and the tab strip are inside the main window, so the existing `screenshot:` covers them. Settings does not.
- Minimal command additions:
  - `open-settings[:section]`, `close-settings`.
  - `screenshot-settings:<label>`, rendering `settingsWindow.contentView` with the same `writePNG` helper.
  - `font-size:<n>` (the picker has no command today).
  - `pin:<id>`, `unpin:<id>`, `tab-select:<id|next|prev>`, `tab-close:<id>`.
  - `usage-refresh` (force a read, and ack after it finishes).
- Snapshot additions (`evidenceState`): `settings{visible, appearance, contentSize, section}`, `usage{state, asOf, totals, estimated}`, `footer{usageText}`, and `tabs{...}` as above. Add `selectedHasTerminalView`-style evidence per tab.
- Fixtures: usage numbers verify against jsonl fixtures dropped in `<data-root>/claude-config/projects/...` in a fake-provider evidence run.
- Evidence code files (`DevelopmentEvidence.swift`, `AppDelegate.swift`) are hot and under F's evidence-separation work. Put the new command logic in new files (`Sources/loom-app/Evidence+Surfaces.swift` or similar) with one dispatch line in `handleCatalogCommand`.

## 6. Tests

- Existing suites to extend:
  - `DisplayAndPreferencesTests` (round trip and clamp of `openTabs`).
  - `ProductPreferencesTests` (font from Settings).
  - `CatalogModelTests` (restore at `:68`, removed selection at `:97`, keeping tab rows through pruning).
  - `ConversationControllerTests` (the `/clear` tab-follow case at `:348` and `:447`, and start auto-pin).
  - `SidebarStatusTests` (the footer chip logic).
- New suites: usage reader tests in `Tests/LoomCoreTests/ClaudeUsageTests.swift`, and tab state tests.
- Window-opening tests that exist: `SidebarStatusTests.swift:197-212` (a borderless window with `orderFrontRegardless`) and `:214-257` (a real `SidebarView` hosted in a window). Per DEVELOPMENT.md §2-§3 these are screen-flashing tests that run only when idle (this run counts the Mac as idle), and they fail with a locked screen.
- The other `LoomCatalogUITests` files (`CatalogModelTests`, `DisplayAndPreferencesTests`, `ProductPreferencesTests`) show no `NSWindow` or hosting use in grep.
- Not verified: whether `ConversationControllerTests` opens windows.

## Proposed U slices

| Slice | Goal | Write area | Acceptance | Checks | Risk | Deps |
| --- | --- | --- | --- | --- | --- | --- |
| **U0** Usage reader (non-UI) | Bounded, incremental Claude usage aggregates with a cost estimate. | New `Sources/LoomCore/ClaudeUsage*.swift` and pricing; `Tests/LoomCoreTests/ClaudeUsageTests.swift` (fixtures only). | Duplicates removed; synthetic skipped; partial last line ignored; shrunk file resets; unknown model has no cost; cold scan bounded to N days; cache round trip; no content retained. | `swift build` plus `--filter ClaudeUsageTests`. | Price table accuracy; first-scan cost on a large real history. | None. Defines the `UsageSnapshot` interface up front. |
| **U1** UsageModel and Settings page | Real Settings window (General, Usage, Providers, About), forced dark. | New `Sources/loom-app/SettingsWindowController.swift`; new `LoomCatalogUI/UsageModel.swift`; rewrite `SettingsView.swift`; one edit in `AppDelegate.showSettings` plus `onShowSettings` signature and `model.usage` wiring. | Cmd+, opens one reused window; font setting still applies live; usage matches fixtures; refresh on open. | Build; the `ProductPreferencesTests` font test; window checks only when idle; Settings screenshot via U5. | Appearance and sizing; hot-file edit in `AppDelegate`. | Interface from U0 (a stub is enough). Stage I tokens. |
| **U2** Footer bar | Compact footer: `+`, usage chip, gear. | New `LoomCatalogUI/SidebarFooter.swift`; the move-out edit in `SidebarView.swift`; the call site only. | Same menu actions as today; chip opens Settings at Usage; truncates at 220 pt; accessible label. | Build; `NewConversationAction` test at `SidebarStatusTests.swift:48`; screenshot. | Merge with F's `NewConversationAction` edits in the same file. | UsageModel type (can be stubbed). |
| **U3** Tab state (non-UI) | `ConversationTabs` plus `openTabs` persistence and model integration. | `UIPreferences.swift`; new `LoomCatalogUI/ConversationTabs.swift`; `CatalogModel.swift` (prune keep set, ensure rows, pin on start and resume, remove hook); new `ConversationTabsTests.swift`. | Persist and restore; cap and de-dupe; transient replaced on select; close selects neighbor; follows `/clear`; missing IDs dropped; no terminal created for idle or stale rows. | Narrow suites (no windows). | Edit in the large `CatalogModel.swift`; `/clear` edge case. | None. |
| **U4** Tab strip UI, shortcuts, evidence | Strip view, menu items, tab commands and snapshot fields. | New `LoomCatalogUI/ConversationTabStrip.swift`; one mount line in `DetailView.swift`; `AppDelegate.installMenus` items; new evidence file plus one dispatch line. | Click selects; close does not stop; a single tab hides the strip; indicators and rename update; shortcuts work. | Build; evidence run with fixtures; window tests only when idle. | Menu shortcut conflicts; hot files. | U3. Stage I tokens preferred. |
| **U5** Evidence surfaces and docs | Settings screenshot, footer and usage snapshot fields, doc impact. | New evidence extension file; doc-impact notes for UI-MAP and DESIGN (main session writes them). | Settings screenshot produced from its own view; fixture usage numbers appear in the snapshot. | Fixture-based evidence run. | Touches F's evidence separation. | U1, U2. |

U0 and U3 can run in parallel with each other and with stage I's theme work. U1, U2, and U4 depend on the interfaces above and on stage I tokens.

## Conflicts with stage I token migration and stage F

**Stage I**
- `CatalogTheme.swift` is replaced by `LoomTheme.swift` (IDENTITY-PROPOSAL §6). New U views should use only existing token names (`text`, `secondary`, `hairline`, `selection`, `panel`, `sidebar`, `attention`, `failure`) so the rename is mechanical.
- Better: land the I theme file first and build U UI slices on it.
- I wires in `accent` for focus rings and default buttons; the tab strip selection and the footer chip should use it.
- I decides the navbar (O-03), which interacts with the strip placement.
- The footer replaces a DESIGN §2 item, and the Settings forced-dark decision (item 8) is shared with I.

**Stage F**
- `AppDelegate.swift` and `DevelopmentEvidence.swift`: F separates evidence code and removes the `TerminalRunController` quit route. U's edits there are kept to one-line hooks plus new files.
- `SidebarView.swift`: F edits `NewConversationAction.all` and Codex surfaces; U moves the footer to its own file to avoid collisions.
- `CatalogModel.swift` is 828 lines and under F's split-large-files goal. U's tab state is in a separate file; the `CatalogModel` edits are small.
- The promote step (`DEVELOPMENT.md:103`) allowlists whole target directories and fails if the release manifest's target declarations differ from `Package.swift`. New files inside `LoomCore` and `LoomCatalogUI` are safe. A new target would need `scripts/release/Package.release.swift` updated, so avoid one.

## Decision points for the user

1. **Tab model.** Recommend pinned tabs plus a transient selected tab, auto-pin on start and resume, with explicit "Open in Tab". Alternatives: tab per selection, or explicit pin only.
2. **Strip placement.** Recommend its own row under the header (decoupled from O-03). Alternative: fold tabs into the 52 pt header row.
3. **Closing a tab.** Recommend it never stops a run. Confirm.
4. **Tab shortcuts.** Recommend Shift+Cmd+]/[ and Ctrl+Tab, with a menu-only Close Tab.
5. **Usage scope.** Recommend all Claude Code usage in the config directory, labelled so. The alternative is Loom-hosted sessions only.
6. **Cost.** An estimate from a maintained price table, labelled "estimate", with a bounded window (propose the last 30 days on first scan). The user or official pricing must supply the price values.
7. **Limits and rate-limit percent.** Not offered, since no local source was found and D-32 forbids extra processes. Confirm that "compact usage" means tokens and estimated cost.
8. **Settings sections.** Recommend General, Usage, Providers, About. Providers status is specified but not built; confirm it is in scope.
9. **Settings forced dark.** Recommend yes (identity item 8).
10. **Stage ordering.** Recommend I's theme file lands before U's UI slices, with U0 and U3 starting immediately.

Relevant files (absolute):
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/SidebarView.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/CatalogModel.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/DetailView.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/ConversationController.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/UIPreferences.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCatalogUI/SettingsView.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/loom-app/AppDelegate.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/loom-app/DevelopmentEvidence.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/SessionEventHub.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/ProviderSessionAdapters.swift`
- `/Users/gencberke/Documents/github/loom-dev/Sources/LoomCore/SessionRuntime.swift`