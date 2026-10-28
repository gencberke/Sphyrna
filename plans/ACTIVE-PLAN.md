# Active Plan: Sphyrna 1.8.0

- **Target:** Sphyrna 1.8.0, the first strong stop: an app fit for daily use ([D-105](../DECISIONS.md)). Every harness
  first-class, the look moved to Ink v4 after Orca's design system, the known bugs closed, `send` between sessions and Remora on
  any harness.
- **The plan:** [plans/1.8.0/README.md](1.8.0/README.md) (goal, order, slice table, release gate, where each open item went),
  with [COMMON.md](1.8.0/COMMON.md) (the rules every brief shares), [DESIGN-V4.md](1.8.0/DESIGN-V4.md) (the record of the look's proposal;
  its approved rules are in `design/DESIGN.md` §0, D-106) and one brief per slice in [briefs/](1.8.0/briefs/).
- **Why:** [FEEDBACK-7](FEEDBACK-7.md) (round 7: the card, the design language, the project drag, the reading of Orca and T3
  Code) and the 1.8.0 parts of [FEEDBACK-6](FEEDBACK-6.md).
- **Integration branch:** `v2` in `~/Library/Caches/loom-v2/wt/v2`, the one line (local only, never pushed without `@user`).
  A running slice has `slice/r9-<id>` in `~/Library/Caches/loom-v2/wt/r9-<id>`, removed the day it is integrated (D-107). This
  checkout (`loom-dev`, on `swarm/1`) mirrors the docs; `~/Documents/github/loom` is the public release tree.
- **Who:** the planner starts each implementer (Claude Opus 5.5 / `medium` or `gpt-6.1-terra` / `max`, AGENTS §3.1; at most
  two at once), reviews, integrates and keeps the docs (D-107).
- **The record before 1.8.0** (rounds 5 and 6, the rescue, the 1.6.0 slices, the End Batch Runbook):
  [archive/ACTIVE-PLAN-1.6.0-to-1.7.2.md](archive/ACTIVE-PLAN-1.6.0-to-1.7.2.md).

## Slice status

The order and the dependencies are in [the plan §3](1.8.0/README.md#3-the-slices). Status values: queued, ready,
running, in review, integrated (with the `v2` SHA), cut. Long checks: `~/Library/Caches/loom-v2/tools/` (COMMON §4).

| Wave | Slice | Status |
| --- | --- | --- |
| 0 | B0 the reference in Ink v4 | integrated `5ba94f1` (approved by `@user`, D-106, with the planner's fixes: Activity marks, the two pickers) |
| 0 | P0 Codex spike | queued: needs `@user`'s word on Q13 and a signed-in isolated Codex home |
| 0 | P1 opencode, agy, pi spike | queued: needs Q13 and isolated profiles |
| 1 | A1 project reorder | integrated `075cd7d` (after review: rows are direct list children again, `SidebarPagingTests`; the released gap holds until the order lands); a by-hand drag check waits for the gate |
| 1 | C1 harness catalogue | integrated `59e300e` (with the planner's fix: opencode has no doctor until P1) |
| 1 | B1 v4 tokens and controls | integrated `fe6f102` + `a81e2c0` (tokens, six button roles at four sizes, the focus halo, three elevations); its rest is closed by B1b |
| 1 | B1b shared controls and the last buttons | integrated `d2f3305` + `5c1f073`; five controls, remaining roles, Label, 36 pt main actions and 32 pt stepper; focus/AX regression fixed; planner's 7 affected suites PASS (63). Full attempt interrupted; pooled checks below |
| 1 | B0b the rest of the reference in v4 | integrated `bdaad69`; consistency pass closed by `fca9e2a` + `2d10f93` (shared complete parts, frame/crop rule, Connections and About) |
| 2 | C2 catalogue consumers | integrated `608266d` (one probe outcome, limits from the probe, efforts on the entries, no Peek singleton) |
| 2 | C2b the catalogue reaches every list | integrated `175f653` (no `ModelCatalog.shared`; availability on `CatalogModel`; one startable rule; File, Dock, Home, sidebar and menu bar follow the switch and the CLI); its follow-ups are in C3's brief |
| 2 | B2 sidebar and card | integrated `497a962` + `6601d5c`; off-screen layout/selection, viewport clock, rest render and accessibility checks pass |
| 2 | C3 Connections and Home connect cards | integrated `365b2d2` + `175f0e2`, parent seams `425878a`, `c84572b`, `1d4326d`; 9 core + 76 UI scoped tests pass; pooled guard/expectation fixes closed by `8e6fbf7` (112 affected tests PASS) |
| 2 | B3 status bar | integrated `26acb6c`; full-width 26 pt bar, cached limits/popover, bounded working menu, shared awake setting and sidebar utilities; 185 affected tests PASS; Q7's documented Yes default applied |
| 3 | C4 neutral draft · B4 model and effort pickers · D1 Codex sessions · D2 Codex reader and deletion · B5a/b/c surfaces | queued |
| 4 | E1 opencode · E2 agy · E3 pi · F1 send · F2 Changes → session · G1 Remora backends · H1 usage · I1 names | queued |
| 5 | Z the gate, the optimizer, the release | planner |

## Open notes for the planner

- **B3 closed (28 Oct):** integrated-tree check passes **185 tests** (7 core + 178 UI), including the shared offscreen root/popover, limit freshness, menu bounds/actions and unrelated-hook redraw regression: `check-20261028T125618-89179.log`. Report: `~/Library/Caches/loom-v2/evidence/r9/b3/INTEGRATION.md`. Worktree/patch-equivalent branch and 1.7 GB scratch removed; evidence retained. No new whole-pool run or shown-window/real-CLI check (D-90). Next: C4's per-harness draft/store/open choices, then B4's model/effort controls and B5's surface migrations.

- **Reference consistency is closed** (28 Oct): shared session chrome and harness marks, terminal, Overview, Connections, Settings tabs and
  About; one complete-app frame rule and labelled crops (DESIGN §1). Source guard, Ink/Paper geometry and browser flows pass;
  evidence is in `~/Library/Caches/loom-v2/evidence/r9/reference-consistency/REPORT.md`.
- **Corrected off-screen pool (28 Oct):** completed at `175f0e2` in
  `~/Library/Caches/loom-check-logs/check-20261028T114138-69249.log`: 3560 tests, three failed tests (raw catalogue comparisons,
  old Home setup-block expectation, fixed-duration elapsed-test bound). `8e6fbf7` closes them; the affected check passes
  **112 tests** at `check-20261028T120853-77355.log`. The original full verdict remains FAIL; only scope was rerun (D-90).
  B1b's earlier interrupted full run is historical, never a pass. Native window/visual/VoiceOver/energy gates remain pending.
- **C3's later seams:** agy's verified install command waits for P1; starting opencode/agy/pi waits for E1–E3. Connections
  records availability/preferences now, and deliberately makes no unsupported-engine or sign-in claim.
- **The by-hand checks waiting for the gate:** A1's drag in the dev app (lift, slide, landing, Escape); the v4 look in
  evidence-mode screenshots after B1b (Home, a session with the inspector, Settings, a sheet; Ink and Paper).

## Founding goals (unchanged since 1.6.0, D-83)

1. **Light.** RAM, CPU, disk and energy never tire the user, while every function stays.
2. **Sessions, not harnesses.** Sphyrna is the one place that manages every session, whatever its harness.
3. **Cost out of sight.** Nothing enters a session's context or spends quota beyond what SPEC §12 allows.
