# Loom UI map

Inventory of every user-visible surface and state, with the source that draws it. Rules and values are in [DESIGN.md](DESIGN.md); this file says where things live. Verified by reading code (nothing here was seen on screen unless stated). Update it when you change a surface. Paths are relative to the repo root; `CUI` = `Sources/LoomCatalogUI`, `APP` = `Sources/loom-app`, `TERM` = `Sources/LoomTerminal`.

Shape of the product UI: one native macOS 27 window, dark only (`darkAqua` forced on the window and `.preferredColorScheme(.dark)` on the roots), a sidebar beside one large terminal panel that hosts the real CLI. No chat UI. Claude and Codex rows exist; Codex is not in the first production release (user decision 6 Oct 2026).

## Window chrome (`APP/AppDelegate.swift` `makeWindow`, `APP/MainSplitViewController.swift`)

- Style: titled, closable, miniaturizable, resizable, full-size content; transparent title bar, hidden title, `isOpaque = false`, clear background, automatic window tabbing off. 1220×780 initial, 780×500 minimum.
- Traffic lights are native and not repositioned. An empty `NSToolbar("loom-main")` with `.unified` style and no separator exists only so AppKit centers them 26 pt from the window top. There is no real toolbar: the "navbar" is the sidebar header row (52 pt) plus the detail header row (36 pt row in a 52 pt block).
- `NSSplitViewController`: sidebar item 220-520 (collapsible), detail minimum 480, thin divider. Width is restored on first layout and persisted 250 ms after a user divider drag only; collapse state is mirrored to the model.
- Full screen: the headers stop reserving space for traffic lights (`model.setFullScreen`).
- Window activity (`updateWindowActivity`): active = visible, not occluded, key, app active. It drives `model.windowIsActive`, viewed state and indicator animation.
- Close (red button, Cmd+W) only closes the window; the app and jobs keep running; Dock reopen re-presents it. Cmd+Q performs a verified shutdown; a failed shutdown shows an `NSAlert` (`quitAlert`). Errors use `NSAlert` sheets (`showError`); Add Project uses `NSOpenPanel`.
- Not implemented: Dock badge, menu-bar status item (deferred by the contract).

## Sidebar (`CUI/SidebarView.swift`, `CUI/SidebarBackground.swift`)

- Background: `NSVisualEffectView(.sidebar, behindWindow, active)` with `LoomTheme.Surface.sidebar` at 0.86 over it; opaque `Surface.sidebar` when Reduce Transparency is on or the evidence override says opaque.
- Header (52 pt, `SidebarHeader`): 76 pt gap for traffic lights (skipped in full screen), `sidebar.left` toggle ("Hide sidebar"), spacer, mode buttons folder (Group by project, Cmd+2) and clock (Recent activity, Cmd+1) with the selected one filled, and an `ellipsis` menu (Add Project..., Group by Project, Recent Activity).
- Search (`SearchField`): always visible, 30 pt, placeholder "Search conversations", clear button. Searches title, provider and project only (not transcripts).
- Footer (38 pt, `SidebarFooter` in `CUI/SidebarFooter.swift`): `plus` menu (New Claude Conversation, New Codex Conversation, Add Project...; new conversations go to the selected conversation's project via `contextProjectID`), the usage chip (`UsageChip`, 24 pt, reads only `UsageModel.chip`; text `Today 1.2M tok · ~$3.10`, cost dropped whole, then tokens ellipsized; `Indexing…` / `No usage yet`; hidden without an index; tooltip and accessibility label carry the full figures; click opens Settings at Usage) and a `gearshape` button for Settings. Both buttons 28×26.
- Activity view (`ActivityList`): day headings Today / Yesterday / weekday / "MMM d" / "MMM d, yyyy" (`DayGrouping`, `CUI/SessionDisplay.swift`, locale `en_US`); cards show the project name; pages load as the last row appears.
- Project view (`ProjectList`, `ProjectHeader`): folder icon, name, optional attention dot, collapse chevron, `ellipsis` menu, tooltip with the path. Tap toggles collapse. Right-click shows New Claude / New Codex Conversation; the ellipsis menu adds Move Up/Down, "... Here" start items and Remove Empty Project (disabled when the project has conversations). All new-conversation entries come from one component (`NewConversationButtons`). Starting in a collapsed project expands it; searching hides empty projects and forces projects open. "No conversations" under an empty loaded project; a "Sessions" section (tray icon) holds no-project conversations. Cards omit the project name.
- Project attention dot: 7 pt, priority failure > attention > unviewed (`ProjectAttention`), visible when collapsed, accessibility label such as "A conversation needs you". No conversation count.
- Conversation card (`SessionCardView`): 12×16 indicator slot, title (13 pt, semibold when selected, secondary color when Stale), relative time (now/5m/3h/2d/3w/1y; tooltip has the absolute date); second row: branch (`arrow.triangle.branch`), project name (activity view only), 14 pt provider icon. Selected: selection fill + hairline stroke, radius 10. Context menu: Rename..., Resume, Stop (disabled by `canResume`/`canStop`). Default titles: "Claude · Project" (activity), "Claude conversation" (project view), "Claude · No project" (unassigned). Accessibility label: "title, Provider, status label".
- List states (`EmptyListHint`): spinner while loading; "No matching conversations / Search covers title, provider and project."; "No conversations yet. Add a project folder to begin." with a filled accent Add Project button

## Status to visual mapping

Source: `SessionIndicator` (`CUI/SessionDisplay.swift`), drawing `IndicatorView`/`ChaseDots` (`CUI/IndicatorView.swift`). Derivation order: stop failure > issue > ambiguous identity > live activity (a turn complete with pending provider work counts as Working) > an unviewed finish after the run ended > lifecycle.

| State | Label | Visual |
| --- | --- | --- |
| Working | Working | 8 dots chasing a rounded rectangle, 12 pt, text color, trail opacity 1 / 0.8 / 0.55 / 0.35, rest 0.16, 10 steps/s |
| waitingForApproval | Needs approval | 8 pt orange dot |
| waitingForInput | Waiting for you | 8 pt orange dot |
| unknown | State unknown | hollow gray ring (1.5 pt) |
| failed / stopUnverified / problem | Failed / Stop not verified / Problem | 8 pt red dot |
| identityUnclear | Identity unclear | hollow orange ring |
| unviewedCompletion | Finished | 8 pt blue dot |
| ready / idle | Ready / Idle | none |
| stale | Stale | none; title dimmed |
| ended | no label | none |

Red, orange and blue dots differ by color only. The label text is shown in the detail header and accessibility label, not on the card. Animation gate: `indicatorsAnimate` (default false). Sidebar rows: window active and sidebar not collapsed (`SidebarView.indicatorsAnimate`); detail header: window active. No Reduce Motion code exists; the chase runs under Reduce Motion by user decision (6 Oct 2026). Viewed means the conversation is selected while the window is active.

## Detail pane (`CUI/DetailView.swift`)

- Panel: 10 pt radius, 1 pt hairline, 8 pt inset, terminal-colored fill over a sidebar-colored backdrop.
- Header (`DetailHeader`, row center 26 pt from window top): 66 pt gap only when the sidebar is collapsed and not full screen; `sidebar.left` "Show sidebar" button only while collapsed; 16 pt provider icon, title (semibold, one line), indicator, then "Starting — complete any prompts in the terminal" while starting, else the colored 11 pt status label. Right side: system `.bordered` small "Stop" button when `canStop` (not `ChromeButtonStyle`), and an `ellipsis` "Conversation actions" menu (Rename..., Resume, Stop). Dev-only variant: "Synthetic terminal (development)".
- Banners (`Banners`, `BannerRow`): ownership notice (orange), status message (secondary), dismissible error (red) and info (secondary).
- Provider requests (`RequestList`): orange-tinted box, hand icon, summary, failure text; Deny / Approve (default action) only when `isAnswerable`. Shown above the terminal and above the history view.
- Content (`DetailContent`, priority order): catalog startup error ("Loom could not open its catalog ..."); dev terminal (evidence only); selected row with a live terminal (`TerminalHost` in `TerminalContainerView`, 6 pt inset, focus pushed to the terminal on window entry); selected row without a terminal (`ConversationDetail`: 34 pt icon, 20 pt title, notices for stop unverified / problem / identity unclear / failed / "Finished while you were away", facts grid Status, Project, Working directory, Provider conversation, Created, Last used, "Not running" text with Resume or "Reactivate and Resume" / Stop / Rename..., busy line "Resuming... / Starting... / Stopping...", max width 640); empty catalog ("Add a project to begin" with Add Project... Cmd+O, New Claude, New Codex buttons); else "No conversation selected".
- Rename sheet (`RenameSheet`, 420 pt): counter against 160 characters, failure text, Cancel / Save; hint "Longer titles are shortened. An empty title returns to the automatic one."

## Terminal surface (`TERM/TerminalSurface.swift`, `TERM/TerminalTheme.swift`)

- Palette (`TerminalTheme`): background sRGB (29, 28, 34), foreground (232, 230, 238), 16 ANSI colors from VS Code Dark+, 256-color strategy `.xterm` (the engine default washed colors out, UI item 7). `COLORTERM=truecolor` is set in the provider environment (`Sources/LoomCore/LaunchEnvironment.swift`).
- Font: `SFMono-Regular`, falling back to the system monospaced font; 11-20 pt, default 14. Steady block cursor, `xterm-256color`, scrollback 2,000 lines, Kitty/inline image stores 8 MiB per screen (1,024 images max), OSC cap 1 MiB, Sixel parsed but not advertised, clipboard read/write disabled, rendering suspended when not visible, accessibility label "Terminal".
- Input: dropped files are inserted as quoted paths without Enter; HTTP(S) and existing local file links open, other schemes do not; an image-only clipboard is forwarded as Ctrl+V.

## Settings (`CUI/SettingsView.swift`, `CUI/UsageSettingsView.swift`, `SettingsWindowController`)

One reused, dark (forced `darkAqua`, `.tint(Accent.base)`), fixed 680×520 window with a transparent title bar (Cmd+, the gear, the usage chip; the chip opens it at Usage). A top switcher General · Usage · About sits on the 26 pt centerline. General: terminal font size (11-20 pt, applies live) and the model's error message. Usage (`UsageModel`, from `ClaudeUsageIndex`): scope line, periods 24 h / 7 d / 30 d / 90 d, token headline with an estimated cost line, an approximate five-hourly-cell activity block labelled "not your plan limit", totals by token type and cache share, neutral per-day (per-hour for 24 h) bars, a per-model table with share and estimated cost, and a footer with "Updated", "Prices as of" and a refresh button; states "Reading Claude's usage" and "No Claude usage yet". About: version, data folder (Reveal) and the Claude profile in use (read only). Provider install status and re-check are specified (`plans/CHECKPOINT-5-HISTORY.md` section 4.1) but not built. Usage refreshes only on launch (after the first catalog load), window activation, Settings opening, a finished Claude turn (debounced 2 s) and the refresh button; the profile is `CLAUDE_CONFIG_DIR` from Loom's own environment, else `~/.claude` (never a login shell).

## Keyboard shortcuts (`AppDelegate.installMenus`)

App: Settings Cmd+, ; Hide Cmd+H ; Quit Cmd+Q. File: Add Project Cmd+O; New Claude Conversation Cmd+N; New Codex Conversation Shift+Cmd+N; Resume Cmd+R; Stop Cmd+. ; Close Window Cmd+W (evidence builds add New Synthetic Terminal Opt+Cmd+N). Edit: Copy, Paste, Select All only (no Cut, Undo or Find). View: Toggle Sidebar Ctrl+Cmd+S; Recent Activity Cmd+1; Group by Project Cmd+2. Window: Minimize Cmd+M, a "Loom" item. In views: default action is bound to Approve, Resume, Reactivate and Rename Save; cancel action to Rename Cancel. Missing: a shortcut to focus search, a Help menu.

## Accessibility

Present: labels on chrome buttons, search, mode buttons (selected trait), cards, project attention dot; indicators are hidden from accessibility (the card label carries the status); Reduce Transparency swaps the sidebar to opaque. Focus ring: `ChromeButtonStyle` draws a 1.5 pt accent (`Surface.focusRing`) ring only when the button is focused and Full Keyboard Access is on (one shared `KeyboardNavigation` flag, refreshed on `didBecomeKey`); `.focusEffectDisabled()` suppresses the system effect. Reduce Motion: see the status mapping above. Absent: Differentiate Without Color and Increase Contrast handling, Dynamic Type (all sizes fixed). No full audit is claimed.

## Design tokens in code

`CUI/LoomTheme.swift` is the one source of visual values (no `CatalogTheme` any more); views carry no `Color(red:)`, `Color.white`, `.system(size:)` or literal corner radius, enforced by `scripts/check-theme-literals.sh`. Namespaces: `Surface` (sidebar, backdrop, panel = `TerminalTheme.background`, `sidebarTintOpacity` 0.86, hairline white 0.10, selected 0.07, control 0.06 / hover 0.09 / pressed 0.14, focus ring = accent), `Text` (primary `#E0DBEB`, secondary `#828799`, tertiary `#5A5F70`), `Accent` (`base` `#8791CF`, `onAccent` = sidebar tone for text on accent fills), `Status` (attention, unviewed, failure, working = primary, `tintOpacity` 0.10), `Opacity` (disabled 0.4), `Radius` (panel 10, card 10, control 6, search 8, callout 8), `Line`, `Typography` (fixed-size fonts by role; named so because `Type` cannot be a nested type name), `Space` (paddings and gaps by role, terminal inset 6), `Layout` (`headerHeight` 52, `detailRowHeight` 36, `sidebarButtonsGap` 76, `detailButtonsGap` 66, search 30, footer 38, chrome button 26×24, footer buttons 28×26, project menu 22×20, indicator slot 12×16, pip 8, project dot 8, chase geometry), `Motion` (chase 10 fps, 8 dots, trail, rest). Colors are also kept as `RGB` data so `LoomThemeTests` can compute contrast. `AccentButtonStyle` (`CUI/DetailView.swift`): `filled` (accent fill, dark text) for Resume/Reactivate, Approve, Save and Add Project; `tinted` for the header Stop. Rules: DESIGN.md §6. `CUI/IndicatorView.swift` holds `IndicatorView`, `ChaseDots`, status label colors and `IndicatorEvidence`; `CUI/ProviderIcon.swift` the provider icons. `CUI/UIPreferences.swift`: sidebar default 300 / range 220-520, terminal font default 14 / range 11-20; stored per bundle in `ui-preferences.json` inside the data root (viewMode, selectedSessionID, sidebarWidth, sidebarCollapsed, terminalFontSize; bad values fall back to defaults, an unreadable file is moved aside). Values and rationale: DESIGN.md section 3.

## Open UI items and pending decisions

- **Navbar** (feedback item 6, 5 Oct 2026): undecided, user conversation pending; a full `WindowChrome` abstraction was deferred to it. Neither it nor Settings was reviewed by the optimizer.
- **User eye-check** (cannot be proven by screenshot): no blue fill on the sidebar button (focus-effect hypothesis, `ChromeButtonStyle` + `.focusEffectDisabled`), no blue glow over the glass (tint 0.55 to 0.86), traffic-light hover/click and header buttons, no project name on project-view cards, attention dot and indicators, real Claude terminal colors. Source: `plans/cp5/UI.md`, `plans/cp5/PERF.md`.
- Generic "more solid / high-end feel" (item 9): covered only qualitatively, no explicit acceptance.
- Missing against the spec: provider install status in Settings, search focus shortcut, Dock/menu bar, history/child-task view, delete, light appearance.
- Unmeasured: WindowServer CPU of the chase indicator (app-side cost about 0.005 %).
- Inferred risks, untested: colour-only status differences, fixed font sizes, 22×20 project menu hit target, the `sparkles` fallback icon if a provider image is missing.

## Verifying UI safely

Details: [DEVELOPMENT.md](../DEVELOPMENT.md) (isolation and evidence rules). Commands live in `APP/DevelopmentEvidence.swift`; launch flags in `Sources/LoomLaunchOptions/LaunchOptions.swift`.

- Launch a separate app copy with `--evidence <dir> --data-root <isolated dir> --fake-providers <fixtures>`. Evidence mode never uses the default catalog; `--data-root` without `--evidence` is refused. Without `--fake-providers`, titles, request text and terminal content are redacted and `screenshot` writes nothing. Seed data with `loom-catalog-fixture seed <data-root> <N> [projects]` (refuses an existing catalog). `scripts/cp5-b-acceptance.sh` is the template for a UI pass.
- Send commands with `loom_send_command <dir> <command>` from `scripts/dev-paths.sh` (a per-directory distributed notification). UI commands: `select:`, `search:`, `view-mode:<activity|projects>`, `toggle-sidebar`, `sidebar-width:`, `resize:<w>x<h>`, `toggle-fullscreen`, `toggle-project:`, `start:<claude|codex>:<project|none>`, `resume:`, `stop:`, `answer:`, `begin-rename:`, `rename-text:`, `rename-commit`, `open-settings[:section]`, `close-settings`, `screenshot-settings:<label>`, `usage-select:<period>`, `usage-refresh[:<label>]`.
- Outputs land in `<dir>`: `screenshot:<label>` writes `screenshot-<label>.png` (content) and `.window.png` (with title bar and traffic lights) from the app's own views, no screen-recording permission; `snapshot:<label>` writes `state-<label>.json` (sidebar width, material, running chase indicators, selected indicator, terminal/runtime state); `buttons:<label>` writes `buttons-<label>.json` (traffic-light hit tests and the 26 pt centerline sweep).
- Screenshots cannot show behind-window glass, animations, hover/focus, menus, sheets or tooltips (the evidence channel renders the Settings window itself: `screenshot-settings:<label>`); those need computer-use or the user.
- Never touch the user's installed Loom Dev app, its default catalog or `ui-preferences.json` under `~/Library/Application Support/Loom-Dev`, or `~/.claude` / `~/.codex`. The `.sh` acceptance scripts refuse to run while any Loom Dev instance is open; the Python runners only check their own package (see `scripts/README.md`). Packaging does a heavy release build; reuse an existing packaged app.
