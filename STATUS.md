# Status (Live Relay Board)

- **Updated:** 2026-10-28, 11:53 +03.
- **State:** `waiting for review`. B2 (`497a962`, `6601d5c`) and C3 (`365b2d2`, `175f0e2`) are integrated. Their slice
  worktrees/branches and 3.5 GB scratch are removed after clean/patch-equivalence checks. No implementer is running.
- **Where we left off:** B1b closes the shared v4 controls and focus-ring migration; the reference now reuses complete window
  parts. The corrected off-screen pool is running (`check-20261028T114138-69249.log`). Its core source guard caught raw
  harness comparisons in C3's icons/onboarding; after the batch, move those policies to descriptors and recheck their scope.
- **Installed:** Sphyrna 1.7.2 (build 10702) in `/Applications/Loom.app`. The CLIs on this Mac: Claude Code 2.1.311,
  Codex 0.164.0, opencode 2.1.4, agy 1.4.5, pi 0.85.1.
- **Public:** `0.4.4` is still the latest GitHub release. The tags `v1.6.0` to `v1.7.2` are local in the loom tree; their push
  and the GitHub release wait for `@user` (D-16, D-83).
- **The record before 1.8.0:** [plans/archive/STATUS-to-1.7.2.md](plans/archive/STATUS-to-1.7.2.md). Each slice's own record
  is its `~/Library/Caches/loom-v2/evidence/r9/<id>/REPORT.md`.

## 1. Where 1.8.0 stands

| Slice | State on `v2` | What it gave |
| --- | --- | --- |
| B0, B0b | integrated (`5ba94f1`, `bdaad69`); consistency `fca9e2a`, `2d10f93` | Ink v4 only; shared complete window parts and harness marks, explicit crops, real Connections content; 11 chapters, no art |
| C1 | integrated (`59e300e`) | The harness catalogue: five descriptors, On / Off / Not found |
| A1 | integrated (`075cd7d`) | The project reorder by a live drag; the sidebar's rows stay lazy |
| B1 | integrated (`fe6f102`, `a81e2c0`) | Ink v4 tokens, six button roles at four sizes, the focus halo, three elevations |
| B1b | integrated (`d2f3305`, `5c1f073`) | Five shared controls, remaining styles and Label, 36 pt main actions, 32 pt stepper; invisible focus overlays no longer enlarge accessibility frames |
| C2, C2b | integrated (`608266d`, `175f653`) | One probe outcome; limits from the probe; efforts on the models; the catalogue on `CatalogModel`; every new-session list follows the switch and the CLI |
| B2 | integrated (`497a962`, `6601d5c`) | v4 cards/search/headings, neutral selection, mark-aligned subagents, viewport-gated working time; scoped off-screen checks pass |
| C3 | integrated (`365b2d2`, `175f0e2`) | five Connections rows, Home actions, all-id preferences/assets, fresh PATH and serialized health recheck, pending guard and blocked reasons; scoped checks pass |

The table with the rest of 1.8.0 is in [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md). Before B1b, `--tests` passed with C2b
(365 + 1912). After integration, the planner's 7 affected suites pass **63 tests**:
`~/Library/Caches/loom-check-logs/check-20261028T094326-36149.log`.

B1b's full attempt (`check-20261028T090651-12245.log`) was stopped after discovering that the checker skipped individual
window tests but not the serialized `WindowEventTests` namespace. Its harness-availability timeout passes in the scoped
retry; its inspector failure led to a confirmed, fixed off-screen halo regression. The full run is **incomplete**.
`bb8889b` fixes the window gate, with a failing-before/passing-after recording-Swift routing test. The full corrected run and
the shown-window inspector check stay in the pool; no shown-window test runs without idle authorization.

Reports: `~/Library/Caches/loom-v2/evidence/r9/b1b/REPORT.md` and `r9/reference-consistency/REPORT.md`. The reference's
29 declared frames, 34 app appearances and both generated pages pass their checks; 36 frame screenshots are recorded.

**The 28 Oct cleanup (D-107):** 83 branches whose work is in `v2` deleted (C2b's included), 8 worktrees and 17 GB of build scratch removed,
the opencode setup and the prompt files moved to the Trash; the branch tips and 8 superseded branches' patches are in
`~/Library/Caches/loom-v2/evidence/cleanup-20261028/`. `plans/` keeps only what is active; `Package.resolved` is committed
as every check used it (swift-png 4.5.2).

## 2. Worktrees and branches

| Worktree | Branch | State |
| --- | --- | --- |
| `~/Library/Caches/loom-v2/wt/v2` | `v2` | Code checkpoint `175f0e2`; corrected off-screen pool running; source-guard fix pending |
| `~/Documents/github/loom-dev` | `swarm/1` | The docs mirror (its changes are `v2`'s docs copied over, by design); never build or commit here |
| `~/Documents/github/loom` | `main` | The public release tree, a separate repository |

Branches in `loom-dev`'s repository: `main`, `v2`, `swarm/1`. A running slice adds `slice/r9-<id>` in `wt/r9-<id>`; both go
the day it is integrated. Build scratch: `build/v2`, plus `build/r9-<id>` while a slice runs. Long checks:
`~/Library/Caches/loom-v2/tools/` (COMMON §4).

## 3. File locks

- **`@planner`:** canonical records and the pending descriptor-routing fix (HarnessDescriptor/Catalogue, ProviderIcon,
  HomeConnect, affected tests). B2/C3 implementation locks are released; no implementer owns files. SidebarFooter stays for B3.
- **1.8.0:** each brief's write set. Shared by region: `CatalogModel.swift` (C4, D1, F1); `SidebarView.swift` (B2, B3);
  Settings files (C3, B5c, G1). `Package.swift` belongs to I1 alone.

## 4. Next actions by role

- **`@planner`:**
  1. Finish the corrected off-screen pool, fix C3's raw-comparison guard through descriptor metadata, and rerun only its
     affected scope. Then B3, followed by C4; two slices at most at once.
  2. Carry B1b's layout-bound control migrations to B5 (its report); do not reopen the shared family to change a surface layout.
  3. At the pooled gate, use the corrected checker; rerun the full off-screen set and, in the authorized idle window, the
     inspector handle test and the native visual/keyboard/VoiceOver checks. Do not call B1b's interrupted full run a pass.
- **`@user`:**
  1. Q7–Q13 of [FEEDBACK-7](plans/FEEDBACK-7.md#decisions-open). Q7 (the status bar) is needed before B3; Q13 and the
     isolated sign-ins before P0 and P1.
  2. Optional: object to the small calls taken at review (B1 and C2b's "Decisions taken" in their reports), such as hiding,
     not disabling, the sidebar's New session row when Claude cannot start.
  3. Still open from before: the push of `v1.6.0`–`v1.7.2` and the GitHub release; the Trash folders of 22, 25, 26 and 28 Oct.
- **Implementers:** B2 and C3 complete; reports/patches are in `evidence/r9/b2/` and `c3/`. No worktree remains.
- **`@optimizer`:** at the 1.8.0 gate (plans/1.8.0/README.md §4).
