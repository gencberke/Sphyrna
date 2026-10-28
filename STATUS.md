# Status (Live Relay Board)

- **Updated:** 2026-10-28, 21:27 +03.
- **State:** `waiting for implementation`. @user resumed continuous iteration and declared the Mac idle for testing.
  The same C4 agent resumes `wt/r9-c4` at `b3d9828`; independent B5c runs from `4bebd8e`. The planner owns review,
  integration and the pooled idle gate. Two slices at most; all builds stay serialized.
  Window, visual, energy and pooled checks are authorized while idle; real non-Claude CLI turns still follow Q13/isolation.
- **Where we left off:** C4 checkpoint `b3d9828` on `slice/r9-c4` (WIP `ed11c72` plus restored functional wire code), clean.
  Last broad affected run: 116 Core + 1 Chat passed; 130 UI ran with one old-file fixture failure. That fixture was corrected
  but not rerun. V4 non-Claude wire routing was added later and is unverified. Never treat this checkpoint as PASS/integrated.
  Resume details: `~/Library/Caches/loom-v2/evidence/r9/c4/PAUSED.md`; the original Brief and logs remain beside it.
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
| B3 | integrated (`26acb6c`) | 26 pt full-window status bar, cached limits/popover, bounded working menu, shared awake setting and sidebar Settings/Help; 185 affected tests pass |

B3's integrated-tree check passes **185 tests** (7 core + 178 UI): `check-20261028T125618-89179.log`.
Its shared-root/popover actions, selected refresh, bounded menu and unrelated-hook redraw checks pass; native appearance,
VoiceOver and energy remain idle-gate work. Report: `~/Library/Caches/loom-v2/evidence/r9/b3/INTEGRATION.md`.
The clean slice worktree, patch-equivalent branch and 1.7 GB scratch were removed; evidence remains.

The rest is in [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md). The corrected off-screen `--tests` pool completed **3560 tests**
(`check-20261028T114138-69249.log`), with three failed tests: raw catalogue comparisons, the old Home setup-block expectation,
and a fixed-duration timer-test assumption under load. `8e6fbf7` moves mark/onboarding policies into descriptors, exercises the
new Home copy action, and measures the timer's real observation interval. The final affected **112 tests pass** (25 core + 87 UI):
`~/Library/Caches/loom-check-logs/check-20261028T120853-77355.log`. The full pool's original verdict stays FAIL; it was not repeated
after scoped fixes (D-90). No remaining failure from that pool is open.

B1b's earlier full attempt (`check-20261028T090651-12245.log`) remains recorded as interrupted, not passed. The corrected pool
above closes its pending off-screen run; the shown-window inspector/visual/VoiceOver/energy gates still need an idle Mac.
No real CLI/model turn, package, install or shown-window check ran in this round.

Reports: `~/Library/Caches/loom-v2/evidence/r9/b2/REPORT.md`, `c3/REPORT.md`, and `b2-c3/REPORT.md` (integration, pooled fixes,
asset-stage proof and cleanup). Reference frames/marks remain shared; project-head type now matches the 13 pt native token
(`fd700db`, 29-frame source guard PASS). The two slice worktrees/branches and 3.5 GB scratch were removed after clean/patch-equivalence
checks; evidence remains.

**The 28 Oct cleanup (D-107):** 83 branches whose work is in `v2` deleted (C2b's included), 8 worktrees and 17 GB of build scratch removed,
the opencode setup and the prompt files moved to the Trash; the branch tips and 8 superseded branches' patches are in
`~/Library/Caches/loom-v2/evidence/cleanup-20261028/`. `plans/` keeps only what is active; `Package.resolved` is committed
as every check used it (swift-png 4.5.2).

## 2. Worktrees and branches

| Worktree | Branch | State |
| --- | --- | --- |
| `~/Library/Caches/loom-v2/wt/v2` | `v2` | Code checkpoint `26acb6c`; B3 integrated; 185 affected tests pass |
| `~/Library/Caches/loom-v2/wt/r9-c4` | `slice/r9-c4` | resumed at `b3d9828` from `2440fa1`; final wire/legacy checks in flight; NOT integrated |
| `~/Library/Caches/loom-v2/wt/r9-b5c` | `slice/r9-b5c` | B5c from `4bebd8e`; scratch `build/r9-b5c`; Settings/sheets/palette/menu look only |
| `~/Documents/github/loom-dev` | `swarm/1` | The docs mirror (its changes are `v2`'s docs copied over, by design); never build or commit here |
| `~/Documents/github/loom` | `main` | The public release tree, a separate repository |

Branches in `loom-dev`'s repository: `main`, `v2`, `swarm/1`. A running slice adds `slice/r9-<id>` in `wt/r9-<id>`; both go
the day it is integrated. Build scratch: `build/v2`, plus `build/r9-<id>` while a slice runs. Long checks:
`~/Library/Caches/loom-v2/tools/` (COMMON §4).

## 3. File locks

- **`@planner`:** canonical records; no implementer edits docs.
- **C4 (active writer):** per-harness launch-choice/mode/descriptor types, draft/default/preset/store region, `CatalogModel` draft region,
  `open` command/wire/coordinator and approval display; minimal Claude/runtime adapters, cached AppDelegate callbacks
  and their tests. No new engine,
  capability/startability, Chat behavior, probe cadence or visual-panel change. The exact write set is in
  `~/Library/Caches/loom-v2/evidence/r9/c4/BRIEF.md`. B3's locks are released.
- **B5c (active writer):** Settings except Connections, sheets, palette and menu presentation, own Settings/Sheets/Palette/
  RemoraSettings theme tokens and narrow UI tests. No shared-control, Core, draft/header/model-picker, OpenRequestView,
  Connections, InkOpenState or runtime changes. Exact write set: `evidence/r9/b5c/BRIEF.md`.
- **1.8.0:** each brief's write set. Shared by region: `CatalogModel.swift` (C4, D1, F1); `SidebarView.swift` (B2, B3);
  Settings files (C3, B5c, G1). `Package.swift` belongs to I1 alone.

## 4. Next actions by role

- **`@planner`:**
  1. Review the resumed C4 slice in existing `wt/r9-c4` / `slice/r9-c4`; do not recreate it.
     The same `c4_core` agent is running from its BRIEF.md and PAUSED.md. First obtain failing-first v4 wire
     evidence, restore the functional code, rerun the corrected legacy fixture and affected combined suites including
     v2/v3 control routing. Then review the diff/evidence before integration; B4 waits for accepted C4. No full-pool repeat.
     P0/P1 still need explicit real-CLI permission and isolated sign-ins.
  2. Carry B1b's layout-bound control migrations to B5 (its report); do not reopen the shared family to change a surface layout.
  3. Use the newly authorized idle window for the accumulated native visual/keyboard/VoiceOver, inspector/working-indicator
     and energy checks at a worthwhile pooled point. All builds remain serialized. The earlier corrected off-screen pool
     is done; do not repeat it merely because a scoped fix landed. No install/release authority was added.
- **`@user`:**
  1. Optional answers/objections to Q8–Q12 of [FEEDBACK-7](plans/FEEDBACK-7.md#decisions-open); silent items take their
     documented defaults at slice start. Q13 needs actual real-CLI permission and isolated sign-ins before P0/P1.
  2. Optional: object to the small calls taken at review (B1 and C2b's "Decisions taken" in their reports), such as hiding,
     not disabling, the sidebar's New session row when Claude cannot start.
  3. Still open from before: the push of `v1.6.0`–`v1.7.2` and the GitHub release; the Trash folders of 22, 25, 26 and 28 Oct.
- **`@implementer-core` C4:** resumed at `b3d9828`; finish PAUSED.md's v4 and corrected-fixture checks, then final
  REPORT.md/DIFF.patch. Narrow off-screen checks only; the planner handles the idle pool and integration.
- **`@implementer-ink` B5c (warm `c3_ink` agent):** implement Settings/sheets/palette/menus from `evidence/r9/b5c/BRIEF.md`;
  narrow off-screen checks/render probes, native screenshots and interaction go to the planner's pooled gate.
- **B4:** starts after accepted C4; B5a/b retain their separate surface/control migrations.
- **`@optimizer`:** at the 1.8.0 gate (plans/1.8.0/README.md §4).
