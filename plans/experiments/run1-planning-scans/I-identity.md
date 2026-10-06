## Summary

- **Token state.** The visual tokens are 9 colors plus 4 geometry constants in `CatalogTheme.swift:7-30`, `SidebarBackground.swift:9` (tint 0.86) and `TerminalTheme.swift:13-14`. Besides those, about 30 `.system(size:)` calls, 12 `cornerRadius`es and about 26 padding/frame literals sit directly in `SidebarView.swift` and `DetailView.swift`. There are no animations, Increase Contrast or Differentiate Without Color handling, or `Color`/`NSColor` literals in `loom-app`. Only `AppDelegate.swift:174` forces `darkAqua`.
- **Colors vs A.** Every color already equals A's value except `text.secondary` (#757A8C, should be #828799) and the unwired accent (`CatalogTheme.swift:11`, dead code).
- **Migration.** The theme migration is mechanical: about 60 `CatalogTheme.` references plus about 25 literal sites.
- **Biggest findings:**
  - Accent wiring is the only part that may not be fully achievable (system focus rings, native default buttons).
  - `text.secondary` fails 4.5:1 today (see the section 4 table).
  - `ProjectHeader` is not keyboard- or VoiceOver-operable (`SidebarView.swift:272-275`).
  - There is no focus-search shortcut.
  - The Settings window is not dark.
  - A's transitions do not exist yet and must not animate layout above the terminal.
- **R-A.** `proc_pid_rusage` on WindowServer returns EPERM (verified here). `ps -o time=`, `top -pid` and the WindowServer coalition counters are readable (precedent below).
- **Navbar.** O-03 transparent is already what the code does; no change needed.

## 1. Token sources today (location → current value → identity A token)

Verified: the RGB literals in `CatalogTheme.swift` match A's hex values (#0B0E16, #E0DBEB, #8791CF, #FF9E0A, #5C8CFF, #F2615C) except secondary.

| Location | Current | A token |
| --- | --- | --- |
| `CatalogTheme.swift:8` sidebar | rgb(.043,.055,.086) = #0B0E16 | `Surface.sidebar` |
| `SidebarBackground.swift:9` | tint 0.86 | `Surface.sidebarTintOpacity` |
| `CatalogTheme.swift:10`, `TerminalTheme.swift:13` | panel = #1D1C22 (reads TerminalTheme) | `Surface.panel` (still reads TerminalTheme) |
| `DetailView.swift:21` | opaque sidebar color behind the panel | new `Surface.backdrop` |
| `CatalogTheme.swift:12` text | #E0DBEB | `Text.primary` |
| `CatalogTheme.swift:13` secondary | #757A8C | `Text.secondary` = #828799 (change) |
| none (placeholder and disabled use system/opacity) | n/a | `Text.tertiary` #5A5F70 (new, no user yet) |
| `CatalogTheme.swift:11` accent | #8791CF, dead | `Accent.base` |
| `CatalogTheme.swift:14,15` | white 0.10 / 0.07 | `Surface.hairline`, `Surface.selected` |
| `SidebarView.swift:108` | white 0.06 | `Surface.control` |
| `SidebarView.swift:426` | hover .09, pressed .14, selected .07 | `Surface.controlHover`, `controlPressed` (new) |
| `SidebarView.swift:433-435` | focus ring white 0.4, 1.5 pt | `Accent.base` (change) |
| `SidebarView.swift:437` | disabled opacity 0.4 | new `Opacity.disabled` |
| `CatalogTheme.swift:16-18` | attention / unviewed / failure | `Status.attention`, `.unviewed`, `.failure` |
| `DetailView.swift:324,350` | `status.opacity(0.10)` callout fills | new `Status.tintOpacity` |
| `CatalogTheme.swift:167` | chase `CatalogTheme.text` | `Status.working` = `Text.primary` |
| `SettingsView.swift:17,19` | system `.secondary`, `.red` | `Text.secondary`, `Status.failure` |
| Radius: `DetailView.swift:16-18` | 10 | `Radius.panel` |
| `SidebarView.swift:348-353` | 10 | `Radius.card` |
| `SidebarView.swift:431-436` | 6 | `Radius.control` |
| `SidebarView.swift:108` | 8 | `Radius.search` |
| `DetailView.swift:324,350` | 8 | new `Radius.callout` |
| Space: `SidebarView.swift:346` | card 10×8 | `Space.cardH/V` |
| `SidebarView.swift:148` | card gap 0 (A table says 2) | `Space.cardGap`; see decision 8 |
| `SidebarView.swift:321` | inner row gap 3 | new |
| `SidebarView.swift:19-20,154-155` | 12/8 and 6/8 | list insets |
| `DetailView.swift:19` | panel inset 8 | `Space.panelInset` |
| `ConversationController.swift:17-20` | terminal inset 6 (in LoomCatalogUI) | `Space.terminalInset` |
| `DetailView.swift:92,130-131,207,285,396-397`, `SettingsView.swift:22-23` | 14, 14/8, 24, 24, 20/420, 24/360 | `Space.*` or `Layout` |
| Geometry: `CatalogTheme.swift:24-29` | 52 / 36 / 76 / 66 | `Layout.headerHeight` etc. |
| `SidebarView.swift:107,139,407,124,266` | search 30, footer 38, chrome 26×24, footer 28×26, project menu 22×20 | `Layout.*` |
| `SidebarView.swift:113`, `CatalogTheme.swift:98,118,158` | indicator slot 12×16, chase 12, pip 8, inset 1.6, dot radius 1.45 | `Layout.indicator*` |
| `SidebarView.swift:248` | project dot 7 (A: pip 8) | `Status.pip` 8 (change) |
| Type: 11 (×7), 12 (×13), 12 medium (×2), 13, 13 semibold, 14, 15 semibold, 20 semibold, 28, 9 semibold | scattered | `Type.*`; A's table lacks 12 (the main body size), so add `Type.small` = 12 |
| `CatalogTheme.swift:83,128-131` | 10 fps, 8 dots, trail, rest | `Motion.chase*` |

**Not theme (leave):**
- Window sizes (`AppDelegate`).
- `UIPreferences` ranges.
- Terminal font 11-20 (`UIPreferences.swift:11-14`, `TerminalSurface.swift:311`).
- ANSI palette.

## 2. Migration plan

- **File split.** `CatalogTheme.swift` also holds `ProviderImages`/`ProviderIcon` (:32-67), `IndicatorView` (:78-120), `ChaseDots` (:126-205), `labelColor`/`ProjectAttention.color` (:207-226) and `IndicatorEvidence` (:229-238). Create `LoomTheme.swift` with tokens only. Move the rest to `IndicatorView.swift` (including `ChaseDots` and the evidence helper) and `ProviderIcon.swift`. `AppDelegate.swift:725` uses `IndicatorEvidence` and is unaffected. `docs/ARCHITECTURE.md:40` names `CatalogTheme.swift` and needs a doc update.
- **Call sites.** About 23 lines in `SidebarView.swift`, 37 in `DetailView.swift`, 2 in `SidebarBackground.swift`, 8 in indicator code, and `SettingsView.swift`.
- **Dead code (S-B).** `CatalogTheme.accent` has no use. `CatalogTheme.sidebarWidthRange` (:20) is dead; the live one is `UIPreferences.sidebarWidthRange`, used by `UIPreferences.swift:53` and `MainSplitViewController.swift:24-25`.
- **Visibility.** No test references `CatalogTheme` (grep verified). Keep `LoomTheme` internal; `loom-app` does not need it.
- **Cannot move.**
  - `TerminalTheme` stays in `LoomTerminal`. `Package.swift:31` makes LoomCatalogUI depend on LoomTerminal, not the reverse. `Surface.panel` keeps `Color(nsColor: TerminalTheme.background)`.
  - A's `terminal foreground` #E8E6EE ≠ `text.primary` #E0DBEB, so it stays in TerminalTheme (`TerminalTheme.swift:14`).
  - The `ChaseDots` CGColor is resolved once at init (`CatalogTheme.swift:167`), so any dynamic (Increase Contrast) token needs re-resolution.
- **Contrast test.**
  - Put it in `LoomCatalogUITests`; that target already depends on LoomTerminal (`Package.swift:63`).
  - Store tokens as RGB data (not only `Color`) so ratios can be computed; the test builds the tint composites itself.
  - Assert text.primary ≥ 7 and text.secondary ≥ 4.5 on sidebar, selected card and panel.
  - Assert accent and each status hue ≥ 4.5 on the same surfaces, and tertiary ≥ 2.5 (placeholder-only).
- **Grep guard.**
  - A unit test reading sources is fragile because the clean loom tree omits Tests (`promote.sh:45`). Prefer a script, e.g. `scripts/check-theme-literals.sh`, wired into stage F's one required-checks command.
  - It should fail on `Color(red:|Color\.white|\.system\(size:|cornerRadius:` anywhere in `Sources/LoomCatalogUI` except `LoomTheme.swift`.
  - Today the matches are 12 `Color(red:`/`Color.white` hits (3 in SidebarView, 9 in CatalogTheme).

## 3. Surface review vs A

- **Window chrome.** No deviation. Transparent titlebar (`AppDelegate.swift:164-176`).
- **Settings window (`AppDelegate.swift:604-614`, `SettingsView.swift`).**
  - No `appearance` and no `.preferredColorScheme`, so it follows the system.
  - It uses system `.caption`/`.secondary`/`.red`, a system Picker and a 360×150 window.
  - NSAlert via `runModal` (`:596`) and NSOpenPanel also follow the system (inference). Forcing `NSApp.appearance = darkAqua` once would cover them, but the menu-bar effect is unverified.
- **Accent not wired.**
  - Default buttons use the system accent: Resume/Reactivate (`DetailView.swift:274`), Approve (`:320`), Save (`:393`), Add Project (`:178`).
  - The Stop button is system `.bordered` (`:71`).
  - The chrome focus ring is white 0.4.
  - Plan: `.tint(Accent.base)` on all roots, sheets and the Settings host, plus a themed `ProminentButtonStyle`.
  - Native text-field and Picker focus rings follow `NSColor.keyboardFocusIndicatorColor`. No public API overrides it, and there is no `NSAccentColorName` in either Info.plist (`package-dev-app.sh:114-120`, `build-loom.sh:148-154`). It needs a spike; it may stay the system color for native controls.
- **Sidebar.**
  - Section day headings are 12 medium (`SidebarView.swift:171`); A says 11 semibold secondary.
  - Footer glyphs are 14 (`:136`); A says 13.
  - The project attention dot is 7 (`:248`); A says 8.
  - The search placeholder is the system placeholder color, not tertiary (inference).
  - The search field draws no focus indicator (plain style, inference).
  - Cards have no hover fill (`.plain`, `:355`).
  - The project menu hit area is 22×20.
- **Detail header.** Status label is 11 regular (`DetailView.swift:61,64`); A says 11 medium. Title 13 semibold is correct.
- **Empty and Message.** `Message` title is 15 semibold (`:202`); A says 20 semibold. Detail-record title is 20 (`:231`), which is fine.
- **Copy (§2).**
  - "Add a project folder to get started." (`SidebarView.swift:293`); A says "…to begin." and joins the two sentences.
  - "Conversations cannot start: Loom's run-scope helper is missing, so Loom could not guarantee…" (`AppDelegate.swift:244`) mixes tense and gives no user action.
  - "Stopping owned processes…" (`:146`) is jargon.
  - "Quit could not verify that owned processes stopped." (`:573`).
  - `report()` yields "The project could not be added: <raw error>" (`CatalogModel.swift:820-821`), which has no "what you can do".
  - "Working…" (`DetailView.swift:265`) is the heading when `canResume` is false and can contradict the indicator.
  - Title Case menu and button items ("Add Project…", "New Claude Conversation", "Remove Empty Project"). §2 says sentence case. See decision 5.
  - There are no exclamation marks, emoji or "Oops". Provider names are exact.
- **Transitions.**
  - No `.animation`, `withAnimation` or `.transition` exists anywhere in `Sources/LoomCatalogUI` or `AppDelegate`.
  - A's 120 ms selection fill (`SidebarView.swift:349`) and 200 ms banner/request transition (`DetailView.swift:109-131`) are new, and need `accessibilityReduceMotion` gating (instant or cross-fade).
  - **Constraint:** `RequestList` and `Banners` sit above `TerminalHost` in a VStack (`:164-166`), so animating their height resizes the PTY each frame. Use opacity-only transitions.
- **Terminal.** The 6 pt inset and palette match A. Selection and caret colors are not themed (`TerminalSurface.swift` sets only background, foreground and ANSI; engine default, unverified).
- **Menus.** Edit has only Copy, Paste and Select All (`AppDelegate.swift:661-663`); there is no Find and no Help menu.

## 4. Accessibility

**WCAG ratios** (computed from sRGB; "opaque tint" is #0B0E16, selected card is white 7% over it = #1C1F26, panel is #1D1C22):

| Color | Sidebar | Selected card | Panel |
| --- | --- | --- | --- |
| text.primary #E0DBEB | 14.2 | 12.2 | 12.5 |
| secondary today #757A8C | 4.52 | **3.86** | **3.96** |
| secondary A #828799 | 5.40 | 4.61 | 4.73 |
| tertiary #5A5F70 | 3.04 | 2.60 | 2.66 |
| accent #8791CF | 6.41 | 5.48 | 5.62 |
| attention #FF9E0A | 9.3 | 8.0 | 8.2 |
| unviewed #5C8CFF | 6.1 | 5.2 | 5.4 |
| failure #F2615C | 6.1 | 5.2 | 5.4 |

- The proposal's 3.86 figure is confirmed.
- ANSI normal red is 3.29:1 and blue 3.48:1 on the panel; bright variants are ≥ 4.7.
- Search placeholder (tertiary on the control fill) is 2.68:1, acceptable only as placeholder.
- Notice titles on their 10% tint: attention 6.84, failure 4.72, unviewed 4.69. Secondary on a tint is 3.96-4.18 (not currently used that way).
- Chase tail: opacity 0.35 gives 2.66:1 and the rest dots 1.45:1, which is decorative.
- Disabled (secondary at 0.4 opacity) is 1.8:1, which is conventional.
- Glass is unmeasurable. Bound check, if the material passed pure white through: secondary A would be 3.7:1 and failure 4.18:1. A real dark `.sidebar` material is far darker, so treat this as a worst-case bound only.
- The 1 pt hairline is 1.27-1.35:1 (non-text 3:1 is not met by design; it is decorative separation). The selected-card stroke is 1.09:1. Selection is therefore signaled by fill and weight only; VoiceOver exposes the `.isSelected` trait.
- Focus ring: white 0.4 is 3.8:1; accent would be 5.5-6.4:1.
- White text on an accent fill is 3.0:1 and text.primary on accent is 2.2:1. Do not put light text on `Accent.base`; use dark text (#0B0E16 on accent is 6.4:1) or a tinted rather than filled style.

**Keyboard:**
- No focus-search shortcut (no `FocusState` and no menu item). ⌘F is safe: the app never sets `shouldSendCommandKeyToTerminal`, so ⌘ keys go to the menu.
- Cards are tabbable `Button`s only under Full Keyboard Access, with no arrow-key list navigation.
- `ProjectHeader` collapse is `onTapGesture` only (`SidebarView.swift:273`), with no focus, button trait or accessibility action. It is neither keyboard- nor VoiceOver-operable.
- `.focusEffectDisabled()` is applied on headers and footers. The custom ring shows only under Full Keyboard Access (`:410,423`).

**VoiceOver:**
- Chrome buttons, cards and the attention dot are labeled. Indicators are hidden (`CatalogTheme.swift:114`); the card label carries state.
- Missing: no `.isHeader` trait on day headings (`:170`), `SectionTitle` or `ProjectHeader`. The chevron has no collapsed/expanded value. The `Message` image has no hidden flag, and `Message` and `Notice` are not grouped.
- The detail header's status text is a plain `Text` (acceptable).

**Motion and transparency:**
- Reduce Transparency is handled for the sidebar only (`SidebarView.swift:7,24`).
- The chase intentionally ignores Reduce Motion (D-12; `IndicatorView.isAnimating` at `CatalogTheme.swift:89`).
- There is no other motion yet. New transitions must be gated.

**Increase Contrast:**
- No handling. Fix: read `\.colorSchemeContrast` or `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` inside the tokens. When on, hairline → about 0.30, secondary lifts, and the focus ring thickens.
- This is additive and needs no rule change.

**Differentiate Without Color:**
- Attention, unviewed and failure differ by hue only (confirmed in `UI-MAP`).
- A non-rule-changing option is to read `\.accessibilityDifferentiateWithoutColor` and draw failure as a diamond only when it is on.
- It is also needed for `ProjectAttention` (the 7 pt dot at `:248`).

**Fixed sizes:** all sizes are fixed (`.system(size:)`). macOS has no general Dynamic Type; A keeps fixed sizes, so no action.

**Fixable without a design-rule change:**
- `text.secondary`.
- Header traits and a `ProjectHeader` button.
- The search shortcut.
- Increase Contrast.
- Accent focus ring and tint where achievable.
- Settings forced dark.
- Reduce Motion gating.
- A 24 pt minimum hit target for the project menu.

**Risk noted outside Stage I scope:** Approve and Resume use `keyboardShortcut(.defaultAction)` (`DetailView.swift:274,320`). With a live terminal focused, Return may trigger Approve instead of reaching the CLI. This is unverified. Check it before restyling the default button.

## 5. R-A: WindowServer cost of the chase

**Code:**
- `ChaseDots.LayerView.apply()` (`CatalogTheme.swift:186-203`) is a `CAKeyframeAnimation` on `opacity` with `.discrete`, 8 values and `keyTimes` 0..1.
- Duration is `8 / IndicatorView.framesPerSecond` = 0.8 s.
- It repeats forever and is installed on each of the 8 dot layers. It is removed when not animating or when there is no window.
- It runs only for a working conversation in an active window, per row. Several rows may run at once.

**Measurement feasibility:**
- `proc_pid_rusage` on WindowServer (pid 606, `_windowserver`) fails with EPERM in flavors 0, 2 and 4; all three were run here and succeeded on self. The earlier matrix recorded `windowServerCPUPercentOfOneCore: null` (`plans/experiments/cp5-final-runscope-resource.json`).
- `indicator_cost_lib.usage()` is therefore app-only (`scripts/perf/indicator_cost_lib.py:15-21`).
- Feasible without sudo:
  - `ps -o time= -p <pid>` (10 ms resolution; verified).
  - `top -l 2 -s 1 -pid <pid> -stats pid,command,cpu,time,idlew,power` (verified; 0.1% resolution plus IDLEW and POWER).
  - The resource-coalition read already used by `scripts/cp5-gpu-attribution.py:62-120`. It gets the coalition via `proc_pidinfo(pid, 20)` and reads `coalition_info_resource_usage`. The result struct has `cpu_time`, `interrupt_wakeups`, `platform_idle_wakeups` and `gpu_time`. The existing script uses only `gpu_time`, and `final-runscope-gpu.json` shows the WindowServer coalition readable (pids 606 and 1147).
- `powermetrics` needs root. Not feasible.
- The WindowServer coalition is shared with all clients, so measurements are noisy.

**Method:**
1. Extend `indicator_cost_lib.py` with a `ws_sample()` using `ps` TIME deltas plus the coalition `cpu_time`/wakeup/`gpu_time` deltas.
2. Alternate cells with identical clients: chase running (window active, sidebar open, N working = 1, 3) versus chase static (window inactive via Finder, which `indicator_cost.py:56-58` already does, or sidebar collapsed).
3. Run at least 5 interleaved 60 s pairs on an idle desktop with other windows closed.
4. Report the median WindowServer CPU and GPU delta per condition and the app-side cost beside it.
5. Record `NSScreen.maximumFramesPerSecond` (60 Hz vs ProMotion). On fixed-refresh panels the hint may be a no-op.

**Hint placement:**
- In `apply()` right after `animation.repeatCount` (`CatalogTheme.swift:196`), add `animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 10, preferred: 10)`.
- Source the number from `Motion.chaseFramesPerSecond`.
- Whether it changes render-server cost for a discrete animation on macOS is unverified. Compare two sequential packages (hint off/on), since parallel builds are not allowed.
- Apply the hint only if the delta exceeds noise.

## 6. Navbar

- **What "transparent" means in code.**
  - `titlebarAppearsTransparent = true`, hidden title, `titlebarSeparatorStyle = .none`, and an empty unified `NSToolbar` solely to center the traffic lights at 26 pt (`AppDelegate.swift:164-176`).
  - The "navbar" is the sidebar header (52 pt, `SidebarView.swift:63`) plus the detail header row (36 + 16 padding = 52, `DetailView.swift:96-97`).
  - It has no background or divider and sits inside the panel.
- **Result.** No code change for A. Only the header geometry constants move into `LoomTheme.Layout`. C's band would need a header background and a status chip (new work).

## Proposed I slices

All depend on stage F's required-checks command; I-2 onward depend on I-1.

- **I-1 Theme foundation (no visual change).**
  - Goal: introduce `LoomTheme` with today's values and migrate every call site.
  - Write area: new `Sources/LoomCatalogUI/LoomTheme.swift`, `IndicatorView.swift`, `ProviderIcon.swift`; delete `CatalogTheme.swift`; edit `SidebarView.swift`, `DetailView.swift`, `SidebarBackground.swift`, `SettingsView.swift`; new `Tests/LoomCatalogUITests/LoomThemeTests.swift` and `scripts/check-theme-literals.sh`.
  - Acceptance: the guard passes, dead constants are gone, and before/after evidence screenshots are pixel-equal.
  - Checks: `swift test` for LoomCatalogUITests, the evidence screenshot flow (`DEVELOPMENT.md` §2-§4).
  - Risk: low. Conflicts with U touching the same files (below).
- **I-2 Identity A values and accent.**
  - Goal: apply the section 3 deviations (secondary #828799, type, 8 pt pips, copy) and wire the accent.
  - Write area: `LoomTheme.swift`, `SidebarView.swift`, `DetailView.swift`, `SettingsView.swift`, `Sources/loom-app/AppDelegate.swift` (Settings dark and menu strings), plus copy in `CatalogModel.swift` and `ConversationController.swift`.
  - Acceptance: tint and focus ring in accent where achievable (spike result recorded), Settings dark, copy per §2, contrast test green.
  - Checks: unit tests, screenshots of sidebar, detail, rename sheet and settings (settings and sheets need computer-use or the user).
  - Risk: medium (native control accents).
- **I-3 Motion and accessibility.**
  - Goal: transitions (120/200 ms ease-out, Reduce Motion gated and opacity-only above the terminal), Increase Contrast, Differentiate Without Color, headers and traits, `ProjectHeader` as a button, ⌘F focus-search.
  - Write area: `SidebarView.swift`, `DetailView.swift`, `LoomTheme.swift`, `CatalogModel.swift` (focus request), `AppDelegate.swift` (View menu).
  - Acceptance: VoiceOver and keyboard walk-through on a package.
  - Checks: unit tests for token resolution, evidence screenshots.
  - Risk: low-medium.
- **I-4 R-A measurement and the 10 fps hint.**
  - Write area: `scripts/perf/indicator_cost_lib.py`, `scripts/perf/indicator_cost.py`, `IndicatorView.swift` (hint).
  - Acceptance: a recorded A/B result with noise bounds.
  - Checks: the perf script on an idle Mac; baseline indicator test unchanged.
  - Risk: noisy result.
- **I-5 Docs.** Fold the Identity section into `design/DESIGN.md`, update `design/UI-MAP.md`, and fix `docs/ARCHITECTURE.md:40`; the main session handles roadmap/decision records.

## Decision points for the user

1. Unviewed colour: keep blue #5C8CFF (recommended).
2. Failure mark: keep the dot and add the diamond only under Differentiate Without Color (recommended), or the diamond always.
3. Navbar: transparent, confirmed.
4. Status words on cards: none (recommended).
5. Sentence case for menu items: keep Title Case for menu and button commands (system convention), and apply sentence case to messages and labels.
6. Metadata digits: tabular SF Pro on the relative time (recommended).
7. Weaving metaphor: no. Settings forced dark: yes. Mark in the empty state: it needs a resource copy added to both packaging scripts (`package-dev-app.sh:103`, `build-loom.sh:138`).
8. Card gap: A's table says 2, today is 0. Treat 2 as the new value, or fix the table.
9. Accent focus ring: accept the system ring on native controls if the spike shows no override.

## Conflicts with U

- **Sidebar footer bar.** The `SidebarFooter` (`SidebarView.swift:112-141`, 38 pt) is rewritten by U; I-1/I-2 also touch it (tokens, 13 pt glyphs). I-1 must land first.
- **Settings page.** U replaces `SettingsView.swift` and `showSettings` (`AppDelegate.swift:604`). I-2 should only force dark and tint in a way that carries over (window appearance in AppDelegate, tokens in the new view).
- **Conversation tabs.**
  - They sit in the `DetailView` header and `DetailContent` (`:30-99`, `:152-192`), which I restyles.
  - ⌘1/⌘2 are already used for view modes (`AppDelegate.swift:675-677`), so tab shortcuts must pick another binding.
  - Tab banners and requests also share the VStack above the terminal.
- **Stage F.** F's menu and AppDelegate splitting may collide with I-3's menu edit; order F first.