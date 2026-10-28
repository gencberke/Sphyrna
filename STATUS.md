# Status (Live Relay Board)

- **Updated:** 2026-10-28, night.
- **State:** `in progress`, between slices. 1.8.0's waves 0–1 and C2 are in ([plans/1.8.0](plans/1.8.0/README.md)); no
  implementer is running. `v2` is the one integration line, clean, and its full `--tests` passes (see §1).
- **Where we left off:** the 28 Oct cleanup ([D-107](DECISIONS.md)) is done. The next slice is B1b; beside it, the planner's
  pass over the reference (§3).
- **Installed:** Sphyrna 1.7.2 (build 10702) in `/Applications/Loom.app`. The CLIs on this Mac: Claude Code 2.1.311,
  Codex 0.164.0, opencode 2.1.4, agy 1.4.5, pi 0.85.1.
- **Public:** `0.4.4` is still the latest GitHub release. The tags `v1.6.0` to `v1.7.2` are local in the loom tree; their push
  and the GitHub release wait for `@user` (D-16, D-83).
- **The record before 1.8.0:** [plans/archive/STATUS-to-1.7.2.md](plans/archive/STATUS-to-1.7.2.md). Each slice's own record
  is its `~/Library/Caches/loom-v2/evidence/r9/<id>/REPORT.md`.

## 1. Where 1.8.0 stands

| Slice | State on `v2` | What it gave |
| --- | --- | --- |
| B0, B0b | integrated (`5ba94f1`, `bdaad69`) | The reference in Ink v4 only, approved (D-106); 11 chapters, no art |
| C1 | integrated (`59e300e`) | The harness catalogue: five descriptors, On / Off / Not found |
| A1 | integrated (`075cd7d`) | The project reorder by a live drag; the sidebar's rows stay lazy |
| B1 | integrated (`fe6f102`, `a81e2c0`) | Ink v4 tokens, six button roles at four sizes, the focus halo, three elevations |
| C2, C2b | integrated (`608266d`, `175f653`) | One probe outcome; limits from the probe; efforts on the models; the catalogue on `CatalogModel`; every new-session list follows the switch and the CLI |

The table with the rest of 1.8.0 is in [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md). Checks on the combined `v2`:
`--tests` PASS with A1 (365 + 1902), with A1, C2 and B1 (365 + 1908), and with C2b (365 + 1912).

**The 28 Oct cleanup (D-107):** 83 branches whose work is in `v2` deleted (C2b's included), 8 worktrees and 17 GB of build scratch removed,
the opencode setup and the prompt files moved to the Trash; the branch tips and 8 superseded branches' patches are in
`~/Library/Caches/loom-v2/evidence/cleanup-20261028/`. `plans/` keeps only what is active; `Package.resolved` is committed
as every check used it (swift-png 4.5.2).

## 2. Worktrees and branches

| Worktree | Branch | State |
| --- | --- | --- |
| `~/Library/Caches/loom-v2/wt/v2` | `v2` | The one integration line; clean |
| `~/Documents/github/loom-dev` | `swarm/1` | The docs mirror (its changes are `v2`'s docs copied over, by design); never build or commit here |
| `~/Documents/github/loom` | `main` | The public release tree, a separate repository |

Branches in `loom-dev`'s repository: `main`, `v2`, `swarm/1`. A running slice adds `slice/r9-<id>` in `wt/r9-<id>`; both go
the day it is integrated. Build scratch: `build/v2`, plus `build/r9-<id>` while a slice runs. Long checks:
`~/Library/Caches/loom-v2/tools/` (COMMON §4).

## 3. File locks

- **`@planner`:** canonical docs (`AGENTS.md`, `STATUS.md`, `DECISIONS.md`, `plans/`) and, for the consistency pass,
  `design/reference-src/**`.
- **1.8.0:** each brief's write set. Shared by region: `CatalogModel.swift` (C4, D1, F1); `SidebarView.swift` (B2, B3);
  Settings files (C3, B5c, G1). `Package.swift` belongs to I1 alone.

## 4. Next actions by role

- **`@planner`:**
  1. Start B1b ([brief](plans/1.8.0/briefs/B1b.md)) as one implementer (AGENTS §3.1's models, or the one `@user` names for
     the session).
  2. Beside it, the reference's consistency pass (ACTIVE-PLAN "Open notes"): one frame rule for every app window, then redraw
     the windows that break it.
  3. After B1b: B2 and C3 side by side (disjoint), then B3; C4 after them; the rest in the plan's order, two at most at once.
- **`@user`:**
  1. Q7–Q13 of [FEEDBACK-7](plans/FEEDBACK-7.md#decisions-open). Q7 (the status bar) is needed before B3; Q13 and the
     isolated sign-ins before P0 and P1.
  2. Optional: object to the small calls taken at review (B1 and C2b's "Decisions taken" in their reports), such as hiding,
     not disabling, the sidebar's New session row when Claude cannot start.
  3. Still open from before: the push of `v1.6.0`–`v1.7.2` and the GitHub release; the Trash folders of 22, 25, 26 and 28 Oct.
- **Implementers:** none running.
- **`@optimizer`:** at the 1.8.0 gate (plans/1.8.0/README.md §4).
