## UI SURFACE MAP: audit report

All of this comes from reading source and docs. Nothing was built or run, so every UI claim is "read in code" or "documented", not "seen on screen". Visual-only items, such as glass leakage and hover behaviour, are marked unverified.

### 0. Repo facts relevant to the docs plan

- **Git state**
  - `Sources/LoomCatalogUI/`, `Sources/LoomTerminal/`, `Sources/loom-app/`, `plans/cp5/`, `STATUS.md` and `DEVELOPMENT.md` are untracked (`??`) in `git status`. `design/DESIGN.md` is modified.
  - The whole UI surface has never been committed. Any doc that links it relies on an uncommitted tree.
- **Size of the UI code**

| Area | Files | Lines |
|---|---|---|
| `Sources/LoomCatalogUI` | 10 | 2,636 |
| `Sources/LoomTerminal` | 3 | 546 |
| `Sources/loom-app` | 5 | 1,659 |

  - The biggest files are `CatalogModel.swift` (828), `AppDelegate.swift` (946) and `SidebarView.swift` (444).
- **UI test counts**
  - `Tests/LoomCatalogUITests`: 53 `@Test` (matches UI.md "53/53").
  - `Tests/LoomTerminalTests`: 39 `@Test`.
- **Design docs**
  - `design/DESIGN.md` is 80 lines (Turkish). §1 holds references, §2 "keep" items, §3 sizes and colours, §4 a legacy Herdr behaviour inventory (explicitly "not a Loom requirement"), §5 the status language from the 5 Oct decision.
  - `design/` also holds 3 PNGs and `legacy-code/` with 4 Swift files.
    - `project-view-reference.png` (261 KB), `activity-view-reference.png` (271 KB), `installed-before-removal.png` (202 KB).
    - Legacy code: `App.swift`, `DesktopView.swift`, `TerminalHost.swift`, `WorkingIndicator.swift`.
  - `assets/brand/README.md` (14 lines) covers only third-party harness artwork: `claude.svg`, `codex.png`, `opencode.svg`, `antigravity.png`. UI-sized 128 px renders are in `assets/harness/`. The Loom app icon files `assets/Loom.*` are original, unchanged artwork.
- **UI sections of `LOOM-PRODUCT-CONTRACT.md`**
  - Little UI text lives there. L28 points to DESIGN.md. L47 sets the first-window scope.
    - Scope: Claude and Codex, project and no-project conversations, activity/project list, search, rename, status indicators, resume/stop, basic terminal.
    - Deferred: other providers, child-task view, Dock/menu-bar notifications, deletion.
  - L48 and L174 set window-close semantics. §10 (L261–278) sets performance constraints. L272 says the working animation must not re-render the whole UI tree, and must stop in a hidden or inactive window.
- **Detailed UI spec (outside the contract)**
  - The real first-window spec is `plans/CHECKPOINT-5-HISTORY.md` §4.1 (L61–70).
  - It is not linked from DESIGN.md.

### 1. Surface and state inventory (source files)

Where no file is named, the row is in `Sources/LoomCatalogUI/`.

**1.1 Window chrome** (`Sources/loom-app/AppDelegate.swift:155-203`, `MainSplitViewController.swift`)

- **NSWindow style**
  - `makeWindow` is at L155; the window setup is at L157–176.
  - Style mask: `.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView`.
  - `titlebarAppearsTransparent`, `titleVisibility = .hidden`, empty `NSToolbar("loom-main")` with `.unified` style, `titlebarSeparatorStyle = .none`.
  - `isOpaque = false`, `backgroundColor = .clear`, `appearance = darkAqua` (forced dark, there is no light mode), `NSWindow.allowsAutomaticWindowTabbing = false`.
  - Initial size 1220×780, `minSize` 780×500, `window.center()`.
  - The empty toolbar exists only so AppKit centres the traffic lights at 26 pt from the window top (x≈19–79).
- **Traffic lights**
  - They are native, not repositioned.
  - Evidence command `buttons:<label>` hit-tests them (`windowButtonsEvidence`, L836ff).
- **Split view**
  - `NSSplitViewController` with a thin divider.
  - Sidebar item: `sidebarWithViewController`, min 220, max 520, `canCollapse`.
  - Detail: min thickness 480. The `preferredThicknessFraction` of 0.25 is effectively overridden by restored preferences.
  - Hosting controllers use `sizingOptions = []`.
- **Sidebar width and collapse state**
  - Restored in `viewDidLayout`.
  - Width is persisted 250 ms after a user divider drag, not on window-squeeze.
  - Collapse state is mirrored to the model.
- **Full screen**
  - The `will/did Enter/Exit FullScreen` notifications feed `model.setFullScreen`. The sidebar header and detail header then stop reserving space for traffic lights.
- **Window activity**
  - `updateWindowActivity` (L~200) defines active as visible AND not occluded AND key AND app active.
  - It drives `model.windowIsActive`, viewed-state, and indicator animation.
- **Close behaviour**
  - Cmd+W / red button only closes the window.
  - `applicationShouldTerminateAfterLastWindowClosed` returns false. Dock reopen re-presents the same window.
  - Cmd+Q does a verified shutdown. A failed shutdown shows an `NSAlert` sheet (`quitAlert`).
- **Not implemented**
  - Dock badge and menu-bar status item: grep found nothing (contract defers them).
  - Toolbar items: the toolbar is intentionally empty.
  - This is where the "navbar" topic lands: the "navbar" is really the 52 pt sidebar header row plus the 36 pt detail header row, with no actual toolbar.

**1.2 Sidebar** (`SidebarView.swift`, `SidebarBackground.swift`)

- **Container**
  - `SidebarView` (L5) stacks Header, SearchField, SidebarList, Footer.
  - Background is `SidebarBackground`: `NSVisualEffectView(.sidebar, behindWindow, active)` overlaid with `CatalogTheme.sidebar` at 0.86 opacity.
  - Reduce Transparency, or the evidence override, swaps this for an opaque `CatalogTheme.sidebar`.
  - Forced `.preferredColorScheme(.dark)`.
- **Header (52 pt)**
  - From left: a 76 pt gap clearing the traffic lights (skipped in full screen), the `sidebar.left` toggle, a spacer, then two mode buttons: `folder` (Group by project, ⌘2 in help) and `clock` (Recent activity, ⌘1 in help). Last is an `ellipsis` menu with Add Project…, Group by Project, Recent Activity.
  - The selected mode gets `.isSelected` and a 0.07 white fill.
  - The toggle's `.help` text claims ⌃⌘S.
- **Search field**
  - Always visible. It is 30 pt high with an 8 pt radius and a 0.06 white fill.
  - It has a clear (xmark) button.
  - Placeholder "Search conversations".
  - Search covers title, provider and project only (the empty-state hint says so).
- **Footer (38 pt)**
  - Left is a `plus` menu: New Claude / New Codex Conversation (disabled while a start is in flight) plus Add Project….
  - Right is a `gearshape` button, which opens the Settings window.
- **Activity view** (`ActivityList`)
  - Day section headers: Today / Yesterday / weekday / "MMM d" / "MMM d, yyyy" (`DayGrouping`, `SessionDisplay.swift:165`, locale `en_US`).
  - Cards show the project name (`showsProject: true`).
  - Paginated: `loadMore` fires when the last row appears, with a spinner while `hasMore`.
- **Project view** (`ProjectList`)
  - Project header: folder icon, name, optional attention dot, collapse chevron, `ellipsis` menu, and a tooltip with the path.
  - The ellipsis menu has Move Up / Move Down, "New Claude/Codex Conversation Here", and Remove Empty Project (disabled when count > 0).
  - Tap toggles collapse.
  - Right-click shows "New Claude/Codex Conversation", via the shared `NewConversationButtons` component.
  - Cards omit the project name.
  - A collapsed project is auto-expanded when a conversation is started in it.
  - When searching, projects with no matches are hidden and collapsed projects are forced open.
  - "No conversations" appears under an empty loaded project.
  - An unassigned section titled "Sessions" (tray icon) shows no-project conversations.
- **Project attention dot**
  - A 7 pt circle, priority failure > attention > unviewed.
  - It has an accessibility label ("A conversation failed/needs you/finished").
  - It shows even when collapsed.
  - There is no chat count (removed, UI.md item 8).
- **Conversation card** (`SessionCardView`)
  - Row 1: `IndicatorView` (12×16 slot), title (13 pt, medium, semibold when selected, dimmed to secondary if `.stale`), relative time ("now/5m/3h/2d/3w/1y"; the `.help` tooltip gives the absolute date).
  - Row 2: a branch label with the `arrow.triangle.branch` icon, a spacer, the project name (activity view only), and a 14 pt `ProviderIcon`.
  - Selected: 0.07 white fill plus a 0.10 white 1 pt stroke, 10 pt radius.
  - Context menu: Rename…, Resume, Stop (the last two disabled by `canResume` / `canStop`).
  - A11y: combined label "title, Provider, status label", with the selected trait.
  - The status label text is NOT drawn on the card. It appears only in the detail header and in the a11y label.
- **Default titles** (`CatalogSession.displayTitle`, `SessionDisplay.swift:138`)
  - "Claude · Project" in activity view.
  - "Claude conversation" in project view.
  - "Claude · No project" when unassigned.
- **Empty and loading states** (`EmptyListHint`)
  - A spinner while loading.
  - "No matching conversations / Search covers title, provider and project."
  - "No conversations yet / Add a project folder to get started."

**1.3 Status language** (`SessionDisplay.swift:7-94`, indicator drawing `CatalogTheme.swift:78-120`, colours L208ff)

| Indicator | Label | Visual |
|---|---|---|
| working | "Working" | 8 dots chasing around a rounded rect. A `CAKeyframeAnimation` per dot, 10 fps, discrete, in the render server. White-ish (`CatalogTheme.text`) with trail opacities 1/0.8/0.55/0.35 and rest 0.16. |
| waitingForApproval | "Needs approval" | 8 pt orange dot |
| waitingForInput | "Waiting for you" | 8 pt orange dot |
| unknown | "State unknown" | hollow grey ring (1.5 pt) |
| failed / stopUnverified / problem | "Failed" / "Stop not verified" / "Problem" | 8 pt red dot |
| identityUnclear | "Identity unclear" | hollow orange ring |
| unviewedCompletion | "Finished" | 8 pt blue dot |
| ready | "Ready" | nothing |
| idle | "Idle" | nothing |
| stale | "Stale" | nothing; title dimmed |
| ended | no label | nothing |

- **Derivation**
  - Order: stopFailure > issue > ambiguous identity > live activity (a turnComplete with pending provider work counts as working) > an unviewed finish after the run ended > lifecycle.
  - Source: `SessionIndicator.init(record:live:)`.
- **Animation gating**
  - `indicatorsAnimate` is an `@Entry` environment value, static false by default.
  - Sidebar rows: the window is active AND the sidebar is not collapsed (`SidebarView.indicatorsAnimate`).
  - Detail header: window active only.
  - Reduce Motion is deliberately ignored (user decision 6 Oct, DESIGN §5 L75).

**1.4 Detail pane** (`DetailView.swift`)

- **Panel**
  - Panel with a 10 pt radius, 1 pt hairline, 8 pt outer inset, `CatalogTheme.panel` fill (= terminal background).
  - Behind it is the sidebar colour, ignoring the safe area.
  - Dark scheme forced.
- **Header**
  - A 36 pt row plus 16 pt bottom padding, so the total is 52 pt. The row centre is at 26 pt from the window top.
  - A 66 pt gap clears the traffic lights only while the sidebar is collapsed AND not in full screen.
  - Contents:
    - A `sidebar.left` "Show sidebar" button, only while collapsed.
    - A 16 pt provider icon, the title (semibold, one line), the `IndicatorView`, then either "Starting — complete any prompts in the terminal" or the coloured status label (11 pt).
    - A spacer.
    - A bordered small "Stop" button, when `canStop`. This is the system `.bordered` style, not `ChromeButtonStyle`.
    - A "Conversation actions" `ellipsis` menu: Rename…, Resume, Stop.
  - A dev-only variant reads "Synthetic terminal (development)".
- **Banners** (`Banners`, `BannerRow`)
  - Ownership notice (orange).
  - Status message (secondary).
  - Dismissible error banner (red) and info banner (secondary).
- **Provider approval requests** (`RequestList`)
  - Orange-tinted rounded box (0.10 opacity), hand icon, summary, optional failure text.
  - Deny and Approve buttons (Approve is the default action) when the request `isAnswerable`.
  - Shown above the terminal and above the history view.
- **Content states** (`DetailContent`, in priority order)
  - Catalog startup error: "Loom could not open its catalog …".
  - Dev terminal (evidence only).
  - Selected row with a live terminal: `TerminalHost` inside `TerminalContainerView` (6 pt inset on all sides, focus pushed to the terminal on window entry).
  - Selected row without a terminal (`ConversationDetail`):
    - 34 pt provider icon and 20 pt title.
    - Notices for stop unverified, problem, identity unclear, failed, and "Finished while you were away".
    - A facts grid: Status, Project, Working directory, Provider conversation, Created, Last used.
    - A "Not running" explanation and Resume (or "Reactivate and Resume" for stale) / Stop / Rename… buttons, plus a busy line "Resuming… / Starting… / Stopping…".
    - Content maxes out at 640 pt wide.
  - Empty catalog: "Add a project to begin" with Add Project… (⌘O), New Claude Conversation, New Codex Conversation.
  - Otherwise: "No conversation selected".
- **Rename sheet** (`RenameSheet`)
  - 420 pt wide, a character counter against `SessionCatalog.maxTitleLength` (160), failure text, Cancel / Save.
  - Hint: "Longer titles are shortened. An empty title returns to the automatic one."
- **Other native surfaces**
  - `NSOpenPanel` for Add Project (a sheet when the window is visible).
  - `NSAlert` for the quit-failure alert and for `showError`.

**1.5 Terminal surface** (`Sources/LoomTerminal/TerminalSurface.swift`, `TerminalTheme.swift`, `TerminalRunController.swift`)

- **Surface settings**
  - Terminal font is "SFMono-Regular", falling back to the system monospaced font. Size is clamped to 11–20 pt, default 14.
  - Cursor is a steady block, `termName xterm-256color`, scrollback 2,000 lines.
  - Kitty graphics and inline image stores are 8 MiB each per screen (main and alternate), at most 1,024 images.
  - OSC is capped at 1 MiB.
  - Sixel is parsed but not advertised.
  - Clipboard read/write is disabled (`clipboardCopy` is a no-op, `clipboardRead` returns nil).
  - `suspendsRenderingWhenNotVisible` is on. Accessibility label is "Terminal".
- **Palette** (`TerminalTheme`)
  - Background sRGB (29,28,34), foreground (232,230,238).
  - 16 ANSI colours are the VS Code Dark+ set.
  - 256-colour strategy `.xterm`.
  - `COLORTERM=truecolor` is set in the provider environment (LoomCore).
- **Input**
  - Drag and drop quotes file paths and inserts them without Enter. HTTP(S) links and existing local files open; any other scheme does not.
  - An image-only clipboard is forwarded as Ctrl+V.

**1.6 Settings** (`SettingsView.swift`, window created in `AppDelegate.showSettings` L605)

- **Contents**
  - Contains only a Form with a terminal-font Picker (11–20 pt) and "Applies to existing and new terminals.", plus `model.errorMessage` in system `.red`.
  - Opens via Cmd+, or the sidebar gear.
  - The window is a 360×150 titled and closable NSWindow.
- **Gaps**
  - There is no `preferredColorScheme` or appearance override, so this window follows the system appearance. Unlike the main window, it is not forced dark (inference from missing code).
  - The 360×150 window versus a 360-wide form with 24 pt padding is unverified.
  - `CHECKPOINT-5-HISTORY.md` §4.1 L70 and DESIGN §4 require "local CLI availability status + re-check" in Settings. That is not implemented.

**1.7 Menus and keyboard shortcuts** (`AppDelegate.installMenus` L618–688)

- **App menu**: Settings… ⌘, ; Hide ⌘H ; Quit ⌘Q.
- **File menu**
  - Add Project… ⌘O.
  - New Claude Conversation ⌘N, new Codex Conversation ⇧⌘N.
  - Resume ⌘R, Stop ⌘. .
  - Close Window ⌘W.
  - The evidence build adds New Synthetic Terminal ⌥⌘N.
- **Edit menu**: Copy, Paste, Select All only. There is no Cut, Undo or Find, which matters for the rename text field (inference).
- **View menu**: Toggle Sidebar ⌃⌘S, Recent Activity ⌘1, Group by Project ⌘2.
- **Window menu**: Minimize ⌘M and a "Loom" item.
- **In-view shortcuts**: `.defaultAction` is bound to Approve, Resume, Rename Save and Reactivate; `.cancelAction` to Rename Cancel.
- **Missing**
  - No shortcut focuses the search field.
  - No Help menu.
  - No explicit Enter Full Screen item (AppKit may auto-add one; unverified).

**1.8 Accessibility**

- **Present**
  - Accessibility labels on every chrome button, the search field, mode buttons (selected trait), cards, and the project attention dot.
  - Indicators are hidden from accessibility; their meaning is carried by the card label.
  - Reduce Transparency is honoured: `@Environment(\.accessibilityReduceTransparency)` swaps to opaque, with an evidence override.
  - Focus ring: `ChromeButtonStyle` draws a 1.5 pt, 0.4-white ring only when focused AND Full Keyboard Access is on (`isFullKeyboardAccessEnabled`, refreshed on `didBecomeKey`). `.focusEffectDisabled()` suppresses the system effect, which is the suspected cause of the blue-fill report.
- **Reduce Motion**
  - The code has no Reduce Motion handling anywhere (grep: only an evidence snapshot field `systemReduceMotion`).
  - The only motion is the chase indicator, which spins regardless (decision 6 Oct).
  - DESIGN §2.8 still says "Hareketi Azalt uyum sürer", with the exception recorded in §5.
- **Absent**
  - Differentiate-Without-Colour and Increase-Contrast handling: grep found none. Status relies on dot colour plus a few ring shapes.
  - Dynamic Type: all sizes are fixed `.system(size:)`.
  - DESIGN §4 L66 itself says no full audit was claimed.

### 2. Tokens in code vs DESIGN.md

**Tokens in code** (`CatalogTheme.swift:6-30`, `UIPreferences.swift`, `SidebarBackground.swift`)

| Token | Value |
|---|---|
| sidebar | (0.043, 0.055, 0.086) |
| panel | `TerminalTheme.background` = (29,28,34)/255 = (0.114, 0.110, 0.133) |
| text | (0.88, 0.86, 0.92) |
| secondary | (0.46, 0.48, 0.55) |
| accent | (0.53, 0.57, 0.81), **unused (dead)** |
| attention | (1.0, 0.62, 0.04) |
| unviewed | (0.36, 0.55, 1.0) |
| failure | (0.95, 0.38, 0.36) |
| hairline | white 0.10 |
| selection | white 0.07 |
| sidebar tint | 0.86 |
| `sidebarWidthRange` | 220…520, **dead duplicate** of `UIPreferences.sidebarWidthRange` |
| headerHeight | 52 |
| detailRowHeight | 36 |
| sidebarButtonsGap | 76 |
| detailButtonsGap | 66 |
| Panel inset / radius | 8 / 10 |
| Card radius | 10 |
| Chrome button | 26×24, 6 pt radius; bg 0.07 selected, 0.09 hover, 0.14 pressed; ring 0.4 |
| Footer buttons | 28×26 |
| Project menu button | 22×20 |
| Search | 30 pt tall, 8 pt radius, white 0.06 |
| Terminal container inset | 6 |
| Sidebar prefs | default 300, range 220–520 |
| Terminal font | default 14, range 11–20 |

- **Matches DESIGN §3**
  - Sidebar, panel, text and secondary colours.
  - Window sizes 1220×780 and 780×500, sidebar 300 in 220–520, terminal minimum 480, 52 pt bar, 8 pt inset, 10 pt radius.
  - Rows 1–3 and 6–7 of §2 are met in spirit. The icons exist at `assets/harness/` and `assets/Loom.*`.

**Mismatches and gaps** (facts unless marked inference)

1. **Accent is dead.** DESIGN §3 lists an accent colour that the code defines but never uses. Buttons that rely on `.defaultAction`, `.bordered` or `ProgressView` (Approve, Resume, Save, Stop) take the user's system accent colour, not the Loom accent (inference).
2. **Undocumented colours.** Attention orange, unviewed blue, failure red and every white-opacity value above are absent from DESIGN. §5 names the colours "orange/blue/red" but gives no values. The failure red is not the same as the terminal ANSI red (205,49,49) nor SwiftUI `.red`; Settings uses `.red`.
3. **Undocumented geometry.** DESIGN §3 omits the 26 pt title centre line, the 36 pt detail row, the 76 / 66 pt gaps, and the 6 pt terminal inset. These live only in code comments (`CatalogTheme.swift:21-29`, `DetailView.swift:93-95`) and in UI.md results. UI.md contains superseded intermediate numbers: U-A says "34 pt" and U-B says "34 pt, left 22 pt" before UB-2/UA-3 settled on 26 pt.
4. **"Yarı saydam sidebar"** (§2.2) versus a 0.86 dark tint over the material. §5 L79 already says the dark tone dominates, so §2.2 is half-stale.
5. **Terminal palette and font are not in DESIGN at all.** The VS Code Dark+ palette, `.xterm` 256 strategy, foreground (232,230,238), SFMono, 14 pt default and steady-block cursor live only in `TerminalTheme.swift`, `TerminalSurface.swift` and UI.md.
6. **Stale rows in DESIGN §4** (legacy Herdr inventory, which it labels non-binding)
   - L45: "search box visible only above 8 conversations". The code and spec §4.1 L66 say always visible.
   - L65: "sidebar width resets to 300 pt on reopen". It is now persisted (`UIPreferences.sidebarWidth`).
   - L65 / spec §4.1 L70: Settings shows provider install status, which is not built.
   - L67: the Performance menu belongs to the removed app.
   - L52: the Dock/menu-bar attention list is deferred.
   - L53–61: child tasks, delete, etc. are out of v1.
   - Shortcut list L69 is incomplete (see §1.7).
7. **§2 text vs implementation**
   - §2.4 says the card shows status "on top". The code puts a status dot at left and no status label on the card.
   - §2.5 says "left bottom: add project". The code has a `+` menu holding New Claude / New Codex Conversation and Add Project.
   - §2.6 says "right: three dots". The code adds a bordered Stop button, a different style from `ChromeButtonStyle`.
   - Add Project and the view-mode choice appear twice in the sidebar header (icons and the ellipsis menu).
8. **§5 lacks states.** Unknown (ring), identity-unclear (ring), stop-unverified, stale (dimmed title) and "unviewed after run ended" are in code but not in §5. §5 says "idle = no indicator" and does not define Ready vs Idle. UI.md also notes: ready no longer draws an indicator, failure is a red dot (no shape), so colour is the only differentiator among attention, unviewed and failure.
9. **Light/dark.** The app is dark-only (forced darkAqua, `.preferredColorScheme(.dark)` on both roots and the rename sheet). The Settings window is the only unforced surface. No doc states "dark only".
10. **Provider icons.** The code uses `harness-claude/codex.png` at 14 / 16 / 34 pt; the fallback is the SF Symbol `sparkles` (a visible mismatch with the contract's real-icon rule if a bundle resource is missing). `synthetic` uses `terminal`.

### 3. Open UI/UX items and pending decisions

**User feedback of 5 Oct (`plans/cp5/UI.md` L9–18, results L46–72)**

| # | Item | Status |
|---|---|---|
| 1 | Sidebar button icon looks like a blue fill | Source-accepted. The cause is hypothesised as the macOS 27 focus effect on a plain button; the fix is `ChromeButtonStyle` plus `.focusEffectDisabled`. Not confirmed in a real window. **User eye-check pending.** |
| 2 | Terminal UI collides with the traffic lights when the sidebar is collapsed | Done (the detail header reserves 66 pt). UB-2 removed a positioner after the buttons became unclickable. Real hover/click is a **user eye-check item**. |
| 3 | Project-row right-click → new Claude/Codex | Done. A single shared component feeds footer, project menu and context menu. |
| 4 | Remove the project name on cards in project view | Done (`showsProject: false`). UI.md notes the user's package-G screenshot still showed it, so it is re-checked by eye in the final package. |
| 5 | Unpeel-style status indicators | Done (chase dots, dots, rings). |
| 6 | Top navbar should be "more solid" | **Deferred, undecided.** DESIGN §5 L80 and STATUS.md L11 list it as an open user decision. The optimizer round 2 S3 also deferred a full `WindowChrome` abstraction to this conversation. The optimizer reviewed neither the navbar nor Settings (CLOSURE L210). |
| 7 | Terminal colours washed out | Done (palette and `.xterm` 256 strategy, regression test). Real Claude colour check is in the final test list. |
| 8 | Remove the conversation count, show a dot for attention | Done. |
| 9 | General "more solid/high-end feel" | Only covered qualitatively through the items above. No explicit acceptance. |
| 10 | Blue glow on the sidebar glass | Tint raised 0.55 → 0.86. **Not verifiable by screenshot**, so user eye-check pending. |

**Other pending items (from `STATUS.md`, `CLOSURE.md` L196-210, `PERF.md` L129)**

- Navbar discussion (above).
- Reduce Motion for the chase indicator is decided (spins; DESIGN §5 updated). The `reduce-motion:` evidence override was removed in UA-6.
- **Deferred code cleanups**
  - S-B: the dead `CatalogTheme.accent` and `.sidebarWidthRange`.
  - S-C: `ChromeButtonStyle` holds a per-instance `@State` and notification subscription.
  - Both were deferred until after the stable release.
- **Measurement gap (R-A)**
  - Not measured: WindowServer CPU for the chase indicator, run when the machine is idle. App-side cost is about 0.005 %.
  - Proposed follow-up if it matters: `preferredFrameRateRange` at 10 fps.
- **User real-window checklist** (`PERF.md` L129)
  - Sidebar button has no blue fill.
  - No blue glow over glass.
  - Traffic-light hover/click and header buttons work.
  - No project name on project-view cards.
  - Attention dot, status indicators, terminal colours.
- **Open user decisions** (STATUS.md L11): other numeric budgets, closing CP5 with the deferred Codex items, navbar. Finder drop/link and obscured GPU4 deferred.
- **Missing UI features versus the spec** (facts)
  - CLI install status and re-check in Settings.
  - Search focus shortcut.
  - Dock/menu bar.
  - History/child-task view.
  - Delete.
  - Settings window theming.
  - A light appearance.
- **Inferred a11y/UX risks, not tested**
  - Colour-only differentiation.
  - Fixed font sizes.
  - Hit target 22×20 for the project menu button.
  - Provider-request Approve/Deny only appear when `isAnswerable`.
  - Fallback icon.
  - Whether Settings looks wrong in light system appearance.

### 4. UI verification tooling and safe use

**Entry points**

- **Command channel**
  - `Sources/loom-app/DevelopmentEvidence.swift` is active only with `--evidence <dir>`.
  - Commands are distributed notifications named `local.loom.desktop.dev.command.<first 16 hex chars of SHA-256(realpath(dir))>`.
  - `scripts/dev-paths.sh` has `loom_command_channel` and `loom_send_command <dir> <cmd>`, which sends via `osascript`.
- **Launch flags** (`Sources/LoomLaunchOptions/LaunchOptions.swift`)
  - `--evidence <dir>`: always forces an isolated data root.
  - `--data-root <dir>`: requires `--evidence`. Otherwise (alone or valueless) the catalog is refused with a visible startup error and the default root is never used.
  - `--fake-providers <dir>`, `--evidence-transparency glass|opaque`, `--metal`, `--fixture`, `--evidence-tokens`.
  - Without `--fake-providers`, real-provider content is redacted: titles and request text are blanked, and `screenshot` is a no-op.
- **UI commands**
  - Navigation and state: `select:<id|none>`, `search:`, `view-mode:<activity|projects>`, `toggle-sidebar`, `sidebar-width:<pt>`, `resize:<w>x<h>`, `toggle-fullscreen`, `toggle-project:<id>`.
  - Project and dialog actions: `add-project:`, `remove-project:`, `move-project:`, `open-add-project-panel`, `panel-choose:`, `close-panel`, `begin-rename:`, `rename-text:`, `rename-commit`, `rename:`.
  - Conversation intents: `start:<claude|codex>:<project|none>`, `resume:`, `stop:`, `answer:<id>:<accept|deny>`, `type:<id>:<text>`.
  - Evidence outputs: `screenshot:<label>`, `snapshot:<label>`, `buttons:<label>`, `feed:<path>` (for dev terminal colour samples).
- **Screenshots** (`AppDelegate.saveScreenshot`)
  - `screenshot:<label>` waits for `model.settle()` plus 300 ms, then writes `screenshot-<label>.png` (content view) and `screenshot-<label>.window.png` (frame view, which includes the titlebar and traffic lights).
  - It uses `cacheDisplay` on the app's own views, so no screen-recording permission is needed.
  - What it cannot show (inference): the behind-window blur/wallpaper (so glass leakage), CALayer animations, hover or focus states, menus, context menus, the Settings window (not a main-window child), and open panels.
  - The `.help` tooltips cannot be captured.
  - The B script itself says native visual acceptance needs CUA capture (`scripts/cp5-b-acceptance.sh` L310).
- **Snapshots** (`snapshot:<label>` → `state-<label>.json`)
  - Window state: sidebar width, content and frame size, key/active/occlusion.
  - Material: `sidebarMaterial` (glass/opaque), `effectiveReduceTransparency`, `transparencyOverride`.
  - Indicators: `chaseIndicators` {total, running, presentedOpacities}, `systemReduceMotion`.
  - Selection: `selectedIndicator` (label), `selectedProvider`, `selectedStopFailure`.
  - Catalog: projects, counts, `activityRowDetails` (first 12), preferences, `windowCount`.
  - Terminal and runtime: `terminal`, `conversationTerminals` (with a redactable screen tail), `runtime`.
- **`buttons:<label>`** writes `buttons-<label>.json`.
  - Frames of the three window buttons.
  - A hit test at centre, top and bottom of each.
  - Controls hit-test per header control, plus a 4 pt-step sweep along the 26 pt centre line from x=84, flagging any x that is not in a SwiftUI hosting view or is in a toolbar view.
- **Fixtures**
  - `loom-catalog-fixture seed <data-root> <N> [projects]` and `seed-v1 <data-root>`. They refuse an existing catalog.
  - `loom-fake-provider` is the fake provider.
  - Existing artefacts: `~/Library/Application Support/Loom-Dev/probe/runs/ui-a/{before,after}/ev/` (screenshots at 1220×780 and 780×500 for activity/projects/collapsed, `buttons-*.json`), `ui-b/…/main/real-*.png`, and several packaged apps named `app-ui-a`, `app-ui-b`, `app-p3s`, `app-r3` (directory names only; contents not inspected).
  - Design baselines are in `design/*.png`.
- **Scripts**
  - `scripts/cp5-b-acceptance.sh` is the best template for a UI pass: `open -a "$app" --args --evidence "$dir" --data-root "$data" --fake-providers …`, then `snap`, `cmd`, `finish`.
  - A and C scripts cover terminal behaviour and a real provider.
  - `scripts/package-dev-app.sh` builds and signs the app.

**How an agent should use it without touching the user's install**

- **Never touch**
  - The installed app (`~/Library/Application Support/Loom-Dev/app/Loom Dev.app`).
  - The default catalog `~/Library/Application Support/Loom-Dev/catalog.sqlite3`, `ui-preferences.json` and the `probe/` tree.
  - `~/.claude`, `~/.codex`.
- **The scripts refuse to run when any Loom Dev is already running**
  - `cp5-*-acceptance.sh` runs `pgrep -f "Loom Dev.app/Contents/MacOS/Loom Dev"` and exits 2 ("quit it first").
  - `package-dev-app.sh` exits 3 if anything runs from the target path.
  - An agent therefore cannot run these while the user's app is open.
  - Evidence mode itself is isolated (own data root, per-dir command channel). The "one instance" refusal is a script rule, not a technical limit (inference).
- **Use a separate bundle**
  - Run `package-dev-app.sh <other dir>`; it refuses `~/Documents` and uses `~/Library/Caches/loom-dev-build` as scratch.
  - It does a release build, which is heavy on the user's laptop (user said not to run it). Reuse an already-built `app-*` directory where possible.
  - Then launch with evidence mode and a fresh `--data-root` seeded by `loom-catalog-fixture`.
  - Always pass `--fake-providers` for UI work so titles and screenshots are not redacted.
- **Cost and constraints**
  - Launching shows a real window and takes focus. `indicatorsAnimate` requires an active, visible, key window, so the working indicator animation can only be assessed with a visible window.
  - Screenshots work from `cacheDisplay` regardless, but the glass and animation require real window and screen capture.
  - UI evaluation that needs hover/focus/menus/glass needs computer-use or the user's eyes, which is why UI.md defers it to the user checklist.
- **Missing evidence commands (gaps to fill)**
  - Open the Settings window or set the font size.
  - Hover or focus a control.
  - Capture a menu or context menu.
  - Set Reduce Transparency or Increase Contrast (only the glass/opaque override exists).
  - Screenshot a sheet or `NSOpenPanel`.
  - Screenshot the quit alert.
  - A no-seeded-provider "starting" state.

### 5. Proposed outline: `design/UI-MAP.md` (≤200 lines)

1. **Purpose, scope, how to update** (≈8 lines). Who reads it; "update when you change a surface"; link to DESIGN, contract, the UI.md decisions, and spec §4.1.
2. **Product-level UI summary** (≈8). Dark-only native macOS 27 window, a sidebar plus one large terminal panel, a real CLI terminal (no chat UI), single window, Claude focus (Codex paused).
3. **Window and layout geometry** (≈15). One table: window sizes, sidebar 220–520 (300 default), detail ≥480, 52 / 36 pt headers, the 26 pt centre line, 76 / 66 pt gaps, 8 pt panel inset, 10 pt radius, 6 pt terminal inset; the toolbar trick; full-screen behaviour.
4. **Design tokens** (≈25). Colours with values, opacities, materials, fonts, icon sizes; mark which are in DESIGN versus code-only, and the dead accent.
5. **Status language** (≈20). The §1.3 table; the derivation order; the animation gating rules (window-active, sidebar-open) and the Reduce-Motion decision.
6. **Surface inventory** (≈40). One short entry per surface (sidebar header/search/lists/footer, cards, project rows, detail header, banners, requests, history view, empty states, rename sheet, Settings, panels, alerts, menus) with file and symbol.
7. **Interaction map** (≈15). Keyboard shortcuts, context menus, double-click/tap behaviours, drag-and-drop, selection and viewed rules.
8. **Accessibility status** (≈10). What exists, what is missing (Differentiate Without Color, Increase Contrast, Dynamic Type, search shortcut), focus ring rule.
9. **Terminal surface** (≈10). Palette, font, limits, input rules, link policy.
10. **Persistence** (≈5). `ui-preferences.json` keys, defaults and fallbacks.
11. **Open UI/UX questions and decisions** (≈15). Navbar, light appearance, Settings content, status label on cards, user eye-check list, deferred cleanups S-B/S-C, with decision owner and date.
12. **Verification recipe** (≈20). Commands, flags, outputs, what screenshots can't prove, safe-use rules (§4 above), where the sample runs and baselines are.
13. **Known doc debt** (≈5). A list of the stale DESIGN items.

**Suggested companion actions** (not done, read-only task)

- Split DESIGN.md: keep §2/§3/§5 as the contract; move §4 (legacy Herdr inventory) to an appendix or `legacy/` file, and prune its stale rows.
- Add the missing tokens to a single table, and fix §2.4/§2.5/§2.6.
- Add a short pointer from DESIGN.md to the spec at `CHECKPOINT-5-HISTORY.md` §4.1 (L61–70).
- Normalise UI.md's superseded numbers (34 pt vs 26 pt) with a "superseded" note.
- Keep the UI map as a map (symbols and files), with a pointer to `CatalogTheme.swift` for values instead of copying them where possible.

**Key files**

- `/Users/gencberke/Documents/github/loom/design/DESIGN.md`
- `/Users/gencberke/Documents/github/loom/plans/cp5/UI.md`
- `/Users/gencberke/Documents/github/loom/plans/CHECKPOINT-5-HISTORY.md` (§4.1, L61–70)
- `/Users/gencberke/Documents/github/loom/plans/cp5/CLOSURE.md` (L182–210)
- `/Users/gencberke/Documents/github/loom/plans/cp5/PERF.md` (L119–131)
- `/Users/gencberke/Documents/github/loom/STATUS.md`
- `/Users/gencberke/Documents/github/loom/Sources/LoomCatalogUI/CatalogTheme.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomCatalogUI/SessionDisplay.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomCatalogUI/SidebarView.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomCatalogUI/DetailView.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomCatalogUI/SettingsView.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomCatalogUI/UIPreferences.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomCatalogUI/SidebarBackground.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomTerminal/TerminalTheme.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomTerminal/TerminalSurface.swift`
- `/Users/gencberke/Documents/github/loom/Sources/loom-app/AppDelegate.swift`
- `/Users/gencberke/Documents/github/loom/Sources/loom-app/MainSplitViewController.swift`
- `/Users/gencberke/Documents/github/loom/Sources/loom-app/DevelopmentEvidence.swift`
- `/Users/gencberke/Documents/github/loom/Sources/LoomLaunchOptions/LaunchOptions.swift`
- `/Users/gencberke/Documents/github/loom/scripts/dev-paths.sh`
- `/Users/gencberke/Documents/github/loom/scripts/cp5-b-acceptance.sh`
- `/Users/gencberke/Documents/github/loom/scripts/package-dev-app.sh`