# B1b: the shared controls, the Label type and the last buttons in v4

**Goal.** Finish B1's Done-when. B1 (integrated on `v2`) set the v4 tokens, the six button roles at four sizes, the focus halo
and the three elevations. Its Approach 4 and 6 and part of 2 and 3 are left; they are this slice.

**Starts after** B1 (integrated). It runs beside C2b; C3, B2 and B5 wait for it.

**Read.**
- `plans/1.8.0/briefs/B1.md` and B1's report: `~/Library/Caches/loom-v2/evidence/r9/b1/REPORT.md` ("Not done", "Decisions to
  confirm", "Needs").
- `design/DESIGN.md` §0.3 and §0.4 (the heights, the switch, the segmented control, the field, the badge, the key chip),
  §0.2 (Label and Caption) and §3.
- `Sources/LoomCatalogUI/ControlButtonStyles.swift`, `LoomTheme+Shell.swift` (`LoomTheme.Control`, `ControlFocusRing`),
  `LoomTheme+Depth.swift` (`Elevation`), `RowHighlight.swift`, `SheetFamily.swift`, `SettingsControls.swift`.

**Write set.**
- New `InkField.swift`, `InkSwitch.swift`, `InkSegmented.swift`, `InkBadge.swift`, `KeyChip.swift`, and their theme tokens.
- The call sites that switch to them as a drop-in change; `SidebarKeyCap` and `PaletteRemoraKeyCap` (replaced by `KeyChip`).
- `ControlButtonStyles.swift` and the remaining button styles named below; `RowHighlight.swift` and the focus-ring sites below;
  `SheetFamily.swift` (the main action's size).
- The section-label call sites (mono → Label).
- Their tests; `design/DESIGN.md` §3 and the §6 lines that still describe v3's controls.

Not yours: the sidebar's structure and its section heading, and the sidebar's default fill in `UIPreferences.swift` (B2);
the status bar (B3); any surface's layout (B5: a call site that needs more than a drop-in change is listed, not changed);
the Paper card's hairline edge (B5).

**Approach.**
1. **The shared controls** of DESIGN §0.4, each one view with its tokens:
   - `InkSwitch`: 32 × 18, a capsule; off is the muted track with a white thumb, on is the accent track. The two switches that
     draw 28 × 16 today take it.
   - `InkSegmented`: 32 high, the muted track, the chosen segment at elevation 2 (canvas in Ink, white in Paper).
   - `InkField`: 32 high, the input fill and input edge; focus draws the accent edge and the 3 pt halo (`ControlFocusRing`).
   - `InkBadge`: 18 high, the muted fill, Caption type.
   - `KeyChip`: SF Mono 11 in a 4-radius cap; one component for every shortcut. `SidebarKeyCap` and `PaletteRemoraKeyCap` go.
2. **The last buttons in the six roles,** where the change is a drop-in: `SettingsButtonStyle`, `PopupButtonStyle`,
   `StepButtonStyle`, the neutral `PinnedButtonStyle`, `RemoveButtonStyle`, and the Changes tab's `SegmentButtonStyle` (to
   `InkSegmented` if it is one). Tabs, chips and rows keep their own styles. List the system-style buttons (`.plain`,
   `.borderless`, `.bordered`) by file, and move each one that is a text button in a page or sheet to a role.
3. **One focus ring:** `RowHighlight`'s focus and the hand-drawn 2 pt rings (`ViewTabs`, `SidebarFooter`,
   `InspectorContainer`, `SettingsView`, `SessionHeaderViews`, `ComposerBar`, `ProjectMenuView`) take `ControlFocusRing`;
   `Line.focusRing` goes when nothing reads it.
4. **Sizes from DESIGN §0.3:** a sheet's main action and an empty state's main action are 36 (`large`); B1 left them at 32.
5. **Type:** switch the section-label call sites from mono to Label (SF Pro 11 semibold capitals, tracking 5 %); DESIGN lists
   them (§0.2, §6's labels: Session, Worktree, Plan limits and the rest).
6. **DESIGN:** §3 and §6's Controls, Sheets and Rows lines say what v4 draws (the neutral default, the six roles, 24/28/32/36,
   the Destructive fill, the halo), with no v3 heights left.

**Done when.**
- The five shared controls exist and every drop-in call site uses them; the rest are listed by file for B5.
- Every text button in a page, sheet or popover renders in one of the six roles; the exceptions are listed with why.
- One focus ring in the app's own controls.
- A sheet's and an empty state's main action are 36.
- Section labels are Label, not mono.
- `--tests` passes.

**Checks.** `--suite ControlFamilyTests ThemeAppearanceTests LoomThemeTests HighlightTests` and the suites of the touched call
sites; new tests for each shared control's sizes, states and tokens; then `--tests` once. Screenshots are the planner's, from
evidence mode after this slice (DEVELOPMENT §5); list them as unverified.
