# Loom visual contract and design rules

**Status:** The design and icons are accepted as fixed ([product contract](../LOOM-PRODUCT-CONTRACT.md) §3). This file is the canonical visual contract: references, the elements to keep, sizes and colors, and the status language. It states the *current* rule; where a rule comes from a user decision, the date follows in parentheses. For where each surface lives in code and how to verify it, see [UI-MAP.md](UI-MAP.md). The old Herdr Desktop behavior list moved to [LEGACY-INVENTORY.md](LEGACY-INVENTORY.md) (reference only). Brand identity: direction A · Night Fleece was chosen on 6 Oct 2026 ([D-22](../DECISIONS.md), [proposal](IDENTITY-PROPOSAL.md)); new work follows its identity rules, while the values in this file stay authoritative until stage I folds the tokens in. The legacy drawing code, terminal engine and architecture need not be reused as-is.

## 1. References

The primary target is the user's 27 Sep 2026 attachment `Herdr Desktop Appshot 2026-09-27T09-44-26.434Z.png`: activity list on the left, wide terminal on the right, dark glass window. The original file could not be found locally. The files below are not a substitute design; they are helper references kept from the previous app:

- [Window before removal](installed-before-removal.png): the same UI captured with sessions ended; it lacks the live terminal content of the original attachment.
- [Activity view reference](activity-view-reference.png) and [project view reference](project-view-reference.png): earlier local visual checks.
- Legacy sources for size and behavior reference only (not production code to port): [views](legacy-code/DesktopView.swift), [window/menus](legacy-code/App.swift), [working indicator](legacy-code/WorkingIndicator.swift), [terminal presentation](legacy-code/TerminalHost.swift).

## 2. Elements to keep

1. Native red/yellow/green window buttons; top-left sidebar toggle, folder (group by project) and clock (recent activity) view selection, and a three-dot menu. The top bar (navbar) layout is pending a separate discussion with the user (5 Oct 2026); nothing here changes it.
2. A dark sidebar and an opaque dark terminal panel; thin border, soft corners, dense layout. The sidebar glass is dark-tone dominant: it must not visibly leak wallpaper color (5 Oct 2026; tint 0.86, see section 3). The app is dark only.
3. Sidebar search field (always visible); day headings (Today, Yesterday, weekday, date) in the activity view.
4. Two-row conversation card. Top: small colored status indicator, title, relative time. Bottom: branch on the left; project name (activity view only) and the colored provider icon on the right. Selected card: light fill and thin border. The status label text is not drawn on the card.
5. Bottom left: a `+` menu (new Claude conversation, new Codex conversation while it exists in dev builds, Add Project); bottom right: Settings. The sidebar is resizable; most of the width goes to the terminal.
6. Above the terminal: colored provider icon, conversation title, status indicator and label, a Stop button when stoppable, and a three-dot actions menu. The terminal text is the real CLI; it is never replaced by a custom chat UI.
7. The existing ram icon is kept: [ICNS](../assets/Loom.icns), [PNG](../assets/Loom.png), [SVG](../assets/Loom.svg), [raw mark](../assets/Loom-mark.svg), [menu-bar mark](../assets/Loom-menubar.svg). Files were copied without redrawing. Provider icons are in [assets/harness](../assets/harness); originals and sources in [assets/brand](../assets/brand/README.md).
8. Accessibility: honor Reduce Transparency (opaque sidebar). Reduce Motion: the small working indicator keeps animating (see section 4); any other motion must follow Reduce Motion. Focus ring only with keyboard navigation (see UI-MAP).

## 3. Sizes and colors

All sizes are points, not Retina pixels. The code is the source of truth; constants live in `Sources/LoomCatalogUI/CatalogTheme.swift` unless noted.

| Item | Value | Where |
| --- | --- | --- |
| Window | initial 1220×780, minimum 780×500 | `AppDelegate.makeWindow` |
| Sidebar width | default 300, range 220-520; persisted | `UIPreferences.sidebarWidthRange`, `defaultSidebarWidth` |
| Detail pane minimum | 480 | `MainSplitViewController` |
| Header row | 52 (sidebar `CatalogTheme.headerHeight`); detail row 36 + 16 bottom padding = 52 (`detailRowHeight`) | `CatalogTheme` |
| Title bar centerline | 26 from the window top; native buttons, sidebar toggle and detail row share it. An empty unified `NSToolbar` makes AppKit center the buttons there | `AppDelegate.makeWindow` |
| Button clearance | 76 (sidebar header), 66 (detail header, only when the sidebar is collapsed and not full screen) | `sidebarButtonsGap`, `detailButtonsGap` |
| Panel | 8 outer inset, 10 corner radius, 1 hairline; terminal inset 6 | `DetailView`, `TerminalContainerView` |
| Cards / controls | card radius 10; search 30 high, radius 8; footer 38 high; chrome button 26×24 (radius 6) | `SidebarView.swift` |
| Sidebar tint | 0.86 dark tone over the behind-window sidebar material | `SidebarBackground.tintOpacity` |

| Color | Value |
| --- | --- |
| Sidebar | RGB (0.043, 0.055, 0.086) |
| Terminal panel | `TerminalTheme.background` sRGB (29, 28, 34) = (0.114, 0.110, 0.133) |
| Text / secondary text | (0.88, 0.86, 0.92) / (0.46, 0.48, 0.55) |
| Attention (orange) | (1.0, 0.62, 0.04) |
| Unviewed (blue) | (0.36, 0.55, 1.0) |
| Failure (red) | (0.95, 0.38, 0.36) |
| Hairline / selection | white 0.10 / white 0.07 |

`CatalogTheme.accent` (0.53, 0.57, 0.81) from the old contract is defined but unused; default-action buttons currently take the system accent. Material, background and opacity change the final look, so these values alone do not guarantee a screenshot color.

Visual acceptance: compare against the reference at the same window size and scale; check sidebar, typography, icons, glass and terminal geometry. Glass leakage, hover and focus states cannot be seen in evidence screenshots; they need the user's eyes (see UI-MAP).

## 4. Status language

(User decisions 5 Oct 2026, UI feedback package G, [UI plan](../plans/cp5/UI.md); 6 Oct 2026 for Reduce Motion and Codex.)

- Indicators follow the Unpeel style: small and colored. The same language is used in the sidebar, the detail header and every other status surface.
- **Working** = small dots chasing around a rectangle (8 dots on a rounded rectangle, 12 pt, 10 steps per second). It is a render-server layer animation (`CAKeyframeAnimation`), so it costs the app no wakeups. It is static when the window is hidden or inactive, and in the sidebar when the sidebar is collapsed ([contract §10](../LOOM-PRODUCT-CONTRACT.md#10-resource-and-performance-acceptance)). By user decision (6 Oct 2026) it keeps animating when macOS Reduce Motion is on, like the system's own small progress indicators; other motion follows Reduce Motion.
- **Needs approval / Waiting for you** = orange dot. **Finished** (nobody looked yet) = blue dot. **Failed / Stop not verified / Problem** = red dot. **Idle, Ready, Stale, ended** = no indicator (Stale also dims the title). **State unknown** = hollow gray ring; **Identity unclear** = hollow orange ring. Exact mapping and derivation order: [UI-MAP.md](UI-MAP.md#status-to-visual-mapping).
- Project rows show no conversation count. A colored dot (red, then orange, then blue by priority) appears when a conversation in the project fails, needs attention or finished unviewed.
- In the project view a conversation card does not repeat the project name; the activity view shows it.
- A project row's right-click menu starts a new Claude conversation, and a new Codex conversation while Codex exists in dev builds. Codex is not part of the first production release (user decision 6 Oct 2026); its start path is exposed but no new Codex behavior is written (5 Oct 2026).
- The navbar (top bar) layout is pending a separate discussion; none of the above changes it.

## 5. Open design items

- Navbar "more solid" layout (user feedback item 6, 5 Oct 2026): undecided.
- Brand identity and tone: direction A · Night Fleece chosen (6 Oct 2026, [D-22](../DECISIONS.md)); see [IDENTITY-PROPOSAL.md](IDENTITY-PROPOSAL.md). Its tokens and rules are folded into this file in roadmap stage I; until then the values above stay authoritative.
- Other open items and the user eye-check list: [UI-MAP.md](UI-MAP.md#open-ui-items-and-pending-decisions).
