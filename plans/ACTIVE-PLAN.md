# Active Plan: Sphyrna 1.8.0

- **Target:** Sphyrna 1.8.0, the first strong stop: an app fit for daily use ([D-105](../DECISIONS.md)). Every harness
  first-class, the look moved to Ink v4 after Orca's design system, the known bugs closed, `send` between sessions and Remora on
  any harness.
- **The plan:** [plans/1.8.0/README.md](1.8.0/README.md) (goal, order, slice table, release gate, where each open item went),
  with [COMMON.md](1.8.0/COMMON.md) (the rules every brief shares), [DESIGN-V4.md](1.8.0/DESIGN-V4.md) (the record of the look's proposal;
  its approved rules are in `design/DESIGN.md` §0, D-106) and one brief per slice in [briefs/](1.8.0/briefs/).
- **Why:** [FEEDBACK-7](FEEDBACK-7.md) (round 7: the card, the design language, the project drag, the reading of Orca and T3
  Code) and the 1.8.0 parts of [FEEDBACK-6](FEEDBACK-6.md).
- **Integration branch:** `v2` in `~/Library/Caches/loom-v2/wt/v2` (local only, never pushed without `@user`). Slices run on
  `slice/r9-<id>` in `~/Library/Caches/loom-v2/wt/r9-<id>`. This checkout (`loom-dev`, on `swarm/1`) mirrors the docs.
- **Who:** `@user` starts each implementer with a brief. The planner reviews, integrates and keeps the docs (D-105).
- **The record before 1.8.0** (rounds 5 and 6, the rescue, the 1.6.0 slices, the End Batch Runbook):
  [archive/ACTIVE-PLAN-1.6.0-to-1.7.2.md](archive/ACTIVE-PLAN-1.6.0-to-1.7.2.md).

## Slice status

The order and the dependencies are in [the plan §3](1.8.0/README.md#3-the-slices). Status values: queued, ready,
running, in review, integrated (with the `v2` SHA), cut. The run tooling: `~/Library/Caches/loom-v2/evidence/r9/tools/README.md`.

| Wave | Slice | Status |
| --- | --- | --- |
| 0 | B0 the reference in Ink v4 | integrated `5ba94f1` (approved by `@user`, D-106, with the planner's fixes: Activity marks, the two pickers) |
| 0 | P0 Codex spike | queued: needs `@user`'s word on Q13 and a signed-in isolated Codex home |
| 0 | P1 opencode, agy, pi spike | queued: needs Q13 and isolated profiles |
| 1 | A1 project reorder | integrated `075cd7d` (after review: rows are direct list children again, `SidebarPagingTests`; the released gap holds until the order lands); a by-hand drag check waits for the gate |
| 1 | C1 harness catalogue | integrated `59e300e` (with the planner's fix: opencode has no doctor until P1) |
| 1 | B1 v4 tokens and controls | running (Haiku 5.5 implementer in the planner's session) |
| 1 | B0b the rest of the reference in v4 | integrated `e17c499` (two runs; the planner's fixes: the sheet's subject class, the Destructive note, Settings' Connections tab) |
| 2 | C2 catalogue consumers | running (Haiku 5.5 implementer in the planner's session) |
| 2 | C3 Connections · B2 sidebar and card · B3 status bar | queued |
| 3 | C4 neutral draft · B4 model and effort pickers · D1 Codex sessions · D2 Codex reader and deletion · B5a/b/c surfaces | queued |
| 4 | E1 opencode · E2 agy · E3 pi · F1 send · F2 Changes → session · G1 Remora backends · H1 usage · I1 names | queued |
| 5 | Z the gate, the optimizer, the release | planner |

## Founding goals (unchanged since 1.6.0, D-83)

1. **Light.** RAM, CPU, disk and energy never tire the user, while every function stays.
2. **Sessions, not harnesses.** Sphyrna is the one place that manages every session, whatever its harness.
3. **Cost out of sight.** Nothing enters a session's context or spends quota beyond what SPEC §12 allows.
