# Stage I — identity and UI system

Part of [multi-agent run 1](RUN-1.md). Roadmap row: [ROADMAP → I](../ROADMAP.md#i-identity-and-ui-system-proposed). Facts: [I scan](experiments/run1-planning-scans/I-identity.md), [identity proposal](../design/IDENTITY-PROPOSAL.md) (direction A chosen, D-22), [DESIGN](../design/DESIGN.md), [UI-MAP](../design/UI-MAP.md).

## Goal

Identity A · Night Fleece becomes one token source in code and an Identity section in `design/DESIGN.md`; every surface in UI-MAP is reviewed against it; the indicator's WindowServer cost (R-A) is measured; an accessibility pass closes the gaps that need no design-rule change. Open sub-decisions (O-12) use A's values; the navbar (O-03) stays the transparent header.

## Slices

| Slice | Delivers | Write area (summary) | Wave | Depends on | State |
| --- | --- | --- | --- | --- | --- |
| [I1](i/I1.md) | `LoomTheme` token source with today's values, all call sites migrated, dead constants removed (S-B), `ChromeButtonStyle` simplified (S-C), contrast test, literal guard | `Sources/LoomCatalogUI/*` views and theme files, `scripts/check-theme-literals.sh`, tests | 2 | F1 | accepted `2773b9d` |
| [I2](i/I2.md) | A's values and voice: `text.secondary` #828799, accent wired (default buttons, focus rings, tint), A's type sizes and 8 pt pips, copy per identity §2, dark appearance for alerts and panels | `LoomTheme.swift`, `SidebarView`, `DetailView`, copy sites, `AppDelegate` (appearance, strings) | 3 | I1, F3 | accepted (this commit) |
| [I3](i/I3.md) | Motion (≤200 ms, opacity-only above the terminal, Reduce Motion gated), Increase Contrast, header traits, `ProjectHeader` as a button, Cmd+F focus search and Esc clear, 24 pt hit targets, Return vs default-action check | views, `CatalogModel` (focus request), `AppDelegate` menus | 4 | I2, U4 (menus serialized) | planned |
| [I4](i/I4.md) | WindowServer cost of the working indicator measured; 10 fps frame-rate hint applied only if it matters; sidebar glass `followsWindowActiveState` evaluated | `scripts/perf/indicator_cost*.py`, `IndicatorView.swift` (hint), `SidebarBackground.swift` (only if measured better) | 3 | I1 | planned |

Docs (done with I2): the planner-reviewer folds the Identity section into `design/DESIGN.md` (rules from IDENTITY-PROPOSAL §2 plus column A of §3.1), updates `design/UI-MAP.md` token and surface lines, and marks IDENTITY-PROPOSAL as history once I2 lands. Settings window styling is owned by [U1](u/U1.md); I supplies tokens only.

## Decisions taken in planning (routine)

- A's token table is authoritative where today differs (D-22, "A's values apply"): `text.secondary` #828799, project attention dot 8 pt, card row gap 2 pt, day headings SF Pro 11 semibold secondary, status label 11 medium, empty-state title 20 semibold. These are identity values, not new rules.
- Native text-field and picker focus rings follow the system keyboard-focus color (no public override); Loom's own controls use the accent. Recorded as a known limit, not a user decision.
- Accent never carries light text (white on accent 3.0:1); prominent buttons use dark text on accent or a tinted style.
- Transitions above the terminal animate opacity only (height animation would resize the PTY every frame).

## Decision points (user)

- **DP-I1** Failure mark under "Differentiate without color" (O-12 item 3). Recommendation: draw B's diamond only when the system setting is on. Default: not built until decided (a design-rule question).
- **DP-I2** Sentence case for menu and button commands (identity §2 says sentence case; macOS convention is Title Case for menu items). Recommendation: Title Case for commands, sentence case for messages, labels and alerts. Default: that.
- **DP-I3** Loom mark at 48 pt in the empty catalog state (O-12 item 9). Recommendation: yes. Default: not built until decided (needs an asset in both packaging scripts).
- Others in IDENTITY-PROPOSAL §5 use A's values (unviewed blue, no status words on cards, proportional digits except tabular relative time if trivial, no weaving metaphor, Settings forced dark).

## Acceptance (stage)

- **I-A1** One token source: `scripts/check-theme-literals.sh` passes (no `Color(red:`, `Color.white`, `.system(size:`, `cornerRadius:` literals outside the theme file in `Sources/LoomCatalogUI`); `CatalogTheme.swift` gone; dead constants gone.
- **I-A2** Contrast test passes: `text.primary` ≥ 7:1, `text.secondary` ≥ 4.5:1, accent and status hues ≥ 4.5:1 on sidebar (opaque tint), selected card and panel; tertiary ≥ 2.5:1 and used only for placeholders/disabled/decorative.
- **I-A3** Evidence screenshots (fake providers, 1220×780 and 780×500, both list modes, sidebar open/collapsed, empty catalog, a failure and an attention row, rename sheet, Settings) match DESIGN + Identity; I1 before/after screenshots are pixel-equal except the documented A values applied in I2.
- **I-A4** Accessibility: keyboard reaches search (Cmd+F), cards, project headers and their menus; VoiceOver labels and header traits present; Reduce Motion disables every transition except the working chase (D-12); Increase Contrast raises hairline and secondary; Reduce Transparency unchanged.
- **I-A5** R-A recorded with noise bounds; indicator app CPU stays at baseline (≈0.003–0.013 %); render cost of the stage at baseline (matrix).
- **I-A6** The user's eye check on a package (hover, focus, glass, motion, menus) — collected at the end of the run, not blocking stage closure by the planner-reviewer.

## Evaluation and closure

Stage-end recipe in [RUN-1](RUN-1.md#stage-end-evaluation-recipe) (steps 1–4, 6–8). Optimizer before closing.

## Real-Claude turns

Planned 0. Used: 0.

## Results

- **I1** (`2773b9d`): `LoomTheme` (namespace `Typography` instead of `Type`, a Swift metatype name), `IndicatorView.swift`, `ProviderIcon.swift`; S-B and S-C closed; before/after screenshots pixel-identical for all required shots (the selected shot differs only in the minute of a "Last used" clock); `LoomCatalogUITests` 59/59 with the two expected `text.secondary` known issues for I2.
- **I2** (this commit): A's values and voice. `Text.secondary` #828799, `Text.tertiary`, `Accent.base`/`onAccent`; accent focus ring; `AccentButtonStyle` (filled: Resume/Reactivate, Approve, Save, Add Project; tinted: header Stop); `.tint` on sidebar, detail and rename sheet; day headings 11 semibold, status label 11 medium, empty-state title 20 semibold, project dot 8, card gap 2; copy per §6 voice (quit progress and failure, missing helper notice, sidebar hint, record heading); `CatalogModel.userMessage` maps errors to sentences (planner fix: no extra period after `…`, `?`, `!`, with a failing-first test); `NSApp.appearance = darkAqua` at launch. `LoomCatalogUITests` green on the combined tree. Identity folded into DESIGN §6 and §3, UI-MAP token and copy lines updated; IDENTITY-PROPOSAL is history. Unverified, on the user's eye-check list and the RC package: Approve and rename-sheet content, dark NSAlert/open panel, menu bar. The live terminal renders white in evidence screenshots because `cacheDisplay` does not draw the terminal layer's contents; a real window capture on the RC package confirms the panel colour.
