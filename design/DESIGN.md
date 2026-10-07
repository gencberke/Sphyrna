# Loom visual contract and design rules

**Status:** The design and icons are accepted as fixed ([product contract](../LOOM-PRODUCT-CONTRACT.md) §3). This file is the canonical visual contract: references, the elements to keep, sizes and colors, and the status language. It states the *current* rule; where a rule comes from a user decision, the date follows in parentheses. For where each surface lives in code and how to verify it, see [UI-MAP.md](UI-MAP.md). The old Herdr Desktop behavior list moved to [LEGACY-INVENTORY.md](LEGACY-INVENTORY.md) (reference only). Brand identity: direction A · Night Fleece (6 Oct 2026, [D-22](../DECISIONS.md)); its rules and tokens are folded into [§6](#6-identity-a--night-fleece) and §3 (stage I, 7 Oct 2026). The [proposal](IDENTITY-PROPOSAL.md) is history. The legacy drawing code, terminal engine and architecture need not be reused as-is.

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
5. Footer bar (D-32, 7 Oct 2026), 38 pt inside the sidebar: left a `+` menu (new Claude conversation, new Codex conversation while it exists in dev builds, new Claude session without a project while a session is selected, Add Project); in the middle a compact Claude usage chip (`1.2M today · 5h 62% left`: today's tokens first, then the plan window that runs out first when the Claude CLI reports plan limits, no money; when narrow the limit alone, then the tokens cut with an ellipsis; states `Indexing…` and `No usage yet`; hidden when there is no usage index; the token split and both plan windows in the tooltip, the tokens and the bottleneck window in the accessibility label; click opens Settings at Usage); right a gear that opens Settings. Buttons keep 28×26. Settings is one dark 680×520 window with a top switcher General · Usage · About (Usage scrolls; About shows version, data folder and the Claude profile in use, read only). The sidebar is resizable; most of the width goes to the terminal.
6. Above the terminal: colored provider icon, conversation title, status indicator and label, a Stop button when stoppable, and a three-dot actions menu. The terminal text is the real CLI; it is never replaced by a custom chat UI.
7. The existing ram icon is kept: [ICNS](../assets/Loom.icns), [PNG](../assets/Loom.png), [SVG](../assets/Loom.svg), [raw mark](../assets/Loom-mark.svg), [menu-bar mark](../assets/Loom-menubar.svg). Files were copied without redrawing. Provider icons are in [assets/harness](../assets/harness); originals and sources in [assets/brand](../assets/brand/README.md).
8. Accessibility: honor Reduce Transparency (opaque sidebar). Reduce Motion: the small working indicator keeps animating (see section 4); any other motion must follow Reduce Motion. Focus ring only with keyboard navigation (see UI-MAP).

## 3. Sizes and colors

All sizes are points, not Retina pixels. The code is the source of truth; tokens live in `Sources/LoomCatalogUI/LoomTheme.swift` (terminal colours in `Sources/LoomTerminal/TerminalTheme.swift`) unless noted. `scripts/check-theme-literals.sh` keeps colour, font-size and radius literals out of the other `LoomCatalogUI` files, and `LoomThemeTests` checks the contrast tiers.

| Item | Value | Where |
| --- | --- | --- |
| Window | initial 1220×780, minimum 780×500 | `AppDelegate.makeWindow` |
| Sidebar width | default 300, range 220-520; persisted | `UIPreferences.sidebarWidthRange`, `defaultSidebarWidth` |
| Detail pane minimum | 480 | `MainSplitViewController` |
| Header row | 52 (sidebar `Layout.headerHeight`); detail row 36 + 16 bottom padding = 52 (`Layout.detailRowHeight`); with the tab strip shown the 16 is dropped and the strip (32) follows the row directly | `LoomTheme` |
| Title bar centerline | 26 from the window top; native buttons, sidebar toggle and detail row share it. An empty unified `NSToolbar` makes AppKit center the buttons there | `AppDelegate.makeWindow` |
| Button clearance | 76 (sidebar header), 66 (detail header, only when the sidebar is collapsed and not full screen) | `sidebarButtonsGap`, `detailButtonsGap` |
| Panel | 8 outer inset, 10 corner radius, 1 hairline; terminal inset 6 | `DetailView`, `TerminalContainerView` |
| Cards / controls | card radius 10, padding 10×8, 2 between cards; search 30 high, radius 8; footer 38 high; chrome button 26×24 (radius 6); status pip and project dot 8 | `LoomTheme` |
| Sidebar tint | 0.86 dark tone over the behind-window sidebar material | `Surface.sidebarTintOpacity` |

| Color | Value |
| --- | --- |
| Sidebar | RGB (0.043, 0.055, 0.086) |
| Terminal panel | `TerminalTheme.background` sRGB (29, 28, 34) = (0.114, 0.110, 0.133) |
| Text primary / secondary / tertiary | `#E0DBEB` / `#828799` / `#5A5F70` (tertiary only for placeholders, disabled items and decorative marks) |
| Accent | `#8791CF`: default-action buttons (filled, dark `#0B0E16` text; light text on the accent is 3.0:1 and not allowed), the tinted header Stop, control tint, and Loom's own keyboard focus ring. Native text-field and picker focus rings stay the system colour (no public override) |
| Attention (orange) | (1.0, 0.62, 0.04) |
| Unviewed (blue) | (0.36, 0.55, 1.0) |
| Failure (red) | (0.95, 0.38, 0.36) |
| Hairline / selection | white 0.10 / white 0.07 |

Material, background and opacity change the final look, so these values alone do not guarantee a screenshot color. AppKit panels (alerts, open panels) follow `NSApp.appearance = darkAqua`, set at launch.

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
- Identity sub-decisions still open (O-12): failure mark under "Differentiate without color" (DP-I1), command capitalisation (DP-I2; default Title Case for menu and button commands, sentence case for messages, labels and alerts), Loom mark in the empty catalog state (DP-I3). See [RUN-1](../plans/RUN-1.md#decision-points-for-the-user).
- Other open items and the user eye-check list: [UI-MAP.md](UI-MAP.md#open-ui-items-and-pending-decisions).

## 6. Identity (A · Night Fleece)

(Chosen 6 Oct 2026, [D-22](../DECISIONS.md); folded in stage I, 7 Oct 2026. Sub-decisions in §5.)

| Area | Rule |
| --- | --- |
| Personality | A quiet night workbench for one power user running many agents. Competent and calm. Never cheerful at the user's expense. |
| Voice and copy | Sentence case for messages, labels and alerts; no exclamation marks, no emoji, no "Oops". Say what happened, what Loom did or did not do, and what the user can do. Exact provider names ("Claude", "Codex"). No metaphor, including empty states. |
| Colour | Dark only. Two surfaces (sidebar glass, panel = terminal background). Three text tiers. One accent (`#8791CF`). Three status hues. White-alpha fills for controls (hover 9 %, pressed 14 %, control 6 %, selected 7 % with a 1 pt white 10 % stroke). No provider colour tokens: a provider's colour lives only in its official mark. |
| Contrast | `text.primary` ≥ 7:1 and `text.secondary` ≥ 4.5:1 on sidebar tint, selected card and panel; accent and status hues ≥ 4.5:1 on each; `text.tertiary` ≥ 2.5:1 and only for placeholders, disabled items and decorative marks (`LoomThemeTests`). |
| Typography | SF Pro for UI, SF Mono 14 for the terminal (11–20). Fixed sizes; weight carries hierarchy before size. Card title 13 medium (selected semibold); card meta 11 regular; day headings 11 semibold secondary; header title 13 semibold; status label 11 medium; empty-state title 20 semibold. |
| Iconography | SF Symbols, monochrome, regular, 13 pt in chrome; never palette-coloured. Provider marks are official art at 14/16/34 pt and never tinted. The Loom mark is the app icon, menu bar template and About mark. |
| Shape and spacing | 4 pt grid. Concentric radii: panel 10 ≥ card 10 ≥ search 8 ≥ control 6. Geometry from §3: 52 pt header, 26 pt centre line, 8 pt panel inset, 6 pt terminal inset. |
| Materials | Only the sidebar is glass (`.sidebar` behind-window material under the `#0B0E16` tint at 0.86); panel and terminal are opaque; Reduce Transparency swaps in the opaque tint. No wallpaper colour reads through. |
| Header | Transparent: panel colour, no divider, no band (O-03 default; the navbar layout is still an open item). |
| Motion | Persistent motion only as gated render-server layer animations (§4). One-shot transitions ≤ 200 ms ease-out (selection 120 ms, banners 200 ms), opacity only above the terminal (a height change would resize the PTY every frame). No glow, pulse or breathing; nothing animates inside the terminal panel. Appearances fade in (opacity only); dismissals are instant. Under Reduce Motion transitions become instant; the working chase keeps running (6 Oct 2026). |
| Status language | §4, through `IndicatorView` on every surface. No status words on cards (accessibility label only). Unviewed stays blue `#5C8CFF`. |
| Terminal framing | Panel colour = terminal background, so the CLI sits edge to edge; the header lives outside the terminal. ANSI 16 = VS Code Dark+, xterm 256 cube, steady block cursor. |
| Accessibility | Increase Contrast raises the hairline to white 30 %, secondary text to `#A9AEBF` (≥ 7:1) and the focus ring to 2.5 pt (`LoomTheme.ContrastStyle`, partly wired: chrome and row buttons, panel and selection strokes, headings, banners, messages). Clickable controls answer over at least 24×24 pt even when drawn smaller. Headings carry the header trait; project headers are buttons with an expanded/collapsed value. Return never approves a request while a live terminal is shown below it (Approve stays one click away). |
| Sound | None. |

Every new surface is checked against this section before review: theme tokens only, status through `IndicatorView`, copy in this voice, persistent animation only as a gated layer animation, Reduce Transparency handled, text at the contrast tier for its role.
