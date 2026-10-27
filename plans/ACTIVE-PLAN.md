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
- **Who:** the planner starts each implementer in its session (Haiku 5.5, max effort; at most two at once), reviews,
  integrates and keeps the docs (D-107).
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
| 1 | B1 v4 tokens and controls | integrated `fe6f102` + `a81e2c0` (tokens, six button roles at four sizes, the focus halo, three elevations); its rest is B1b |
| 1 | B1b shared controls and the last buttons | ready: starts after C2b (field, switch, segmented, badge, key chip; the last styles in the six roles; one focus ring; 36 for a sheet's main action; Label) |
| 1 | B0b the rest of the reference in v4 | integrated `bdaad69` (two runs; the planner's fixes: the sheet's subject class, the Destructive note, Settings' Connections tab); a consistency pass is open (below) |
| 2 | C2 catalogue consumers | integrated `608266d` (one probe outcome, limits from the probe, efforts on the entries, no Peek singleton) |
| 2 | C2b the catalogue reaches every list | running (C2's rest: no `ModelCatalog.shared`, availability wired, File/Dock/Home/sidebar/menu bar lists) |
| 2 | C3 Connections · B2 sidebar and card · B3 status bar | queued |
| 3 | C4 neutral draft · B4 model and effort pickers · D1 Codex sessions · D2 Codex reader and deletion · B5a/b/c surfaces | queued |
| 4 | E1 opencode · E2 agy · E3 pi · F1 send · F2 Changes → session · G1 Remora backends · H1 usage · I1 names | queued |
| 5 | Z the gate, the optimizer, the release | planner |

## Open notes for the planner

- **The reference needs a consistency pass** (`@user`, 28 Oct: windows that show part of the screen in one chapter must show
  the same part in the others). Found so far: the v4 chapter draws five windows with the sidebar but only three with the status
  bar; window heights and crops differ between chapters for the same kind of window; the edges' first launch repeats one note
  (H1, H2); About still says 1.6.0. Before B5 starts, set one frame rule (an app window always shows the title row, the sidebar
  or not by a stated reason, and the 26 pt status bar; a crop is labelled as a crop) and redraw the windows that break it.
  Small enough for the planner or one short slice after B1b.
- **The by-hand checks waiting for the gate:** A1's drag in the dev app (lift, slide, landing, Escape); the v4 look in
  evidence-mode screenshots after B1b (Home, a session with the inspector, Settings, a sheet; Ink and Paper).

## Founding goals (unchanged since 1.6.0, D-83)

1. **Light.** RAM, CPU, disk and energy never tire the user, while every function stays.
2. **Sessions, not harnesses.** Sphyrna is the one place that manages every session, whatever its harness.
3. **Cost out of sight.** Nothing enters a session's context or spends quota beyond what SPEC §12 allows.
