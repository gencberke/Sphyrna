# Status (Live Relay Board)

- **Updated:** 2026-10-29, 01:52 +03.
- **State:** `waiting for review`. B3b source is integrated;93 affected offscreen and29 integrated scoped/window tests pass. Actual Settings/Help popup and Ink/Paper proof are next. D1's combined affected check is running; P1 preparation is held. A1b is accepted and its tree/scratch removed. T3/Orca multi-round source comparison is complete; F0's existing Sphyrna seam map is in progress.
  @user requested continuous iteration and an idle test window. Power changed to Battery Power80%; after being told the AC rule, @user explicitly replied "devam et sorun yok" for this continuation. Thermal checks/cooldowns and the single build slot still apply. No pause is active.
- **Where we left off:** all B4/B5 presentation code is integrated. Native B5 screenshots found two project drafts overlapping; A1b `f8adc58` fixes per-row geometry while retaining lazy list/typing boundaries. B4 actual picker/keyboard gate passes. B5a117 and B5b156 connected tests pass; B5b's strict first-screen equivalence/RSS tradeoff remains explicitly open.
  P0 is a completed bounded report:7 submitted Codex user inputs plus1 auxiliary held conservatively,7 turns still available. Owned remote identity/status/approval/queue/resume and scoped deletion are evidenced; strict Codex no-tools is blocked. The shared budget ledger and P0 SPIKE.md are authoritative.

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
| A1b | integrated (`f8adc58`), native after-check PASS | per-draft reorder parts prevent overlapping rows;50 connected tests and actual Ink/Paper selection checks pass |
| B1 | integrated (`fe6f102`, `a81e2c0`) | Ink v4 tokens, six button roles at four sizes, the focus halo, three elevations |
| B1b | integrated (`d2f3305`, `5c1f073`) | Five shared controls, remaining styles and Label, 36 pt main actions, 32 pt stepper; invisible focus overlays no longer enlarge accessibility frames |
| C2, C2b | integrated (`608266d`, `175f653`) | One probe outcome; limits from the probe; efforts on the models; the catalogue on `CatalogModel`; every new-session list follows the switch and the CLI |
| B2 | integrated (`497a962`, `6601d5c`) | v4 cards/search/headings, neutral selection, mark-aligned subagents, viewport-gated working time; scoped off-screen checks pass |
| C3 | integrated (`365b2d2`, `175f0e2`) | five Connections rows, Home actions, all-id preferences/assets, fresh PATH and serialized health recheck, pending guard and blocked reasons; scoped checks pass |
| C4 | integrated (`049a95c`) | neutral draft/preset/open choices, compatible files, per-harness memory, cached validation and safe v1/v4 routing; 329 affected tests pass |
| B4 | integrated (`d727e87`, native fix `0c8a0b2`) | separate cached pickers and keyboard navigation; 140 original +47 fix tests pass; actual guarded window/keyboard gate passes |
| B5a | integrated (`e618124`) | shared Home/project/draft controls and typography; connected 9 Core +108 UI tests pass |
| B5b | integrated (`339929d`) | header/tabs/cards, cached tool groups and activity-gated Changes clock/spinners; 156 connected tests pass; native/performance limits in report |
| B5c | integrated (`7f77000`) | palette activity/scope and outline Clear Memory; existing v4 Settings/menu controls verified; 97 affected tests pass |
| B3 | integrated (`26acb6c`) | 26 pt full-window status bar, cached limits/popover, bounded working menu, shared awake setting and sidebar Settings/Help; 185 affected tests pass |
| B3b | integrated (`f3d4f01`), actual popup/appearance pending | Settings/Help move into the single global bar; separate sidebar footer removed;93 slice +29 integrated scoped/window tests pass |

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
Those daytime slices ran no real CLI/model turn, package, install or shown-window check. This resumed continuation has submitted seven isolated Codex user inputs. T5/T6 verify exact-action approval/resolution and queued delivery on the owned remote route. One auxiliary turn is conservatively held for T4's unmeasured ephemeral activity. The vendor delete leaves shared history and a zero-byte capability file; D2 must respect that boundary. The budget ledger is authoritative.

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
| `~/Library/Caches/loom-v2/wt/r9-d1` | `slice/r9-d1` | Active Codex launch/runtime fromfcb6cc5; build/r9-d1 |
| `~/Library/Caches/loom-v2/wt/r9-b3b` | `slice/r9-b3b` | Cleanf3d4f01, fast-forward integrated; retain until actual utility popup/appearance check |
| `~/Library/Caches/loom-v2/wt/v2` | `v2` | Code checkpoint `f3d4f01`; B3b actual utility popup/appearance, then D1 review |
| `~/Documents/github/loom-dev` | `swarm/1` | The docs mirror (its changes are `v2`'s docs copied over, by design); never build or commit here |
| `~/Documents/github/loom` | `main` | The public release tree, a separate repository |

Branches in `loom-dev`'s repository: `main`, `v2`, `swarm/1`. A running slice adds `slice/r9-<id>` in `wt/r9-<id>`; both go
the day it is integrated. Build scratch: `build/v2`, plus `build/r9-<id>` while a slice runs. Long checks:
`~/Library/Caches/loom-v2/tools/` (COMMON §4).

## 3. File locks

- **`@planner`:** canonical records; no implementer edits docs.
- **D1 (warm c4_core):** exact `evidence/r9/d1/BRIEF.md`, Codex/neutral launch/runtime, narrow UI start gates and approved LaunchOptions/catalog/fallback seams. No footer/sidebar/coordination-framework edits.
- **B3b (warm b3_ink):** source integrated; no further writes unless parent finds a concrete native gap. Parent owns native proof and reference/docs. No overlap with D1 UI gates.
- **Reference/F0/P1 research:** multi-round reference report complete/source-only; warm orca_cross_agents maps existing F0 command/auth/result/lifecycle seams read-only. P1 preparation stopped without running providers or login; native agy and complete Pi/OpenCode isolation remain unproved. No model turn reserved.
- **P0:** no active process/spending.7 user inputs +1 auxiliary held; no further real turn without parent reservation. Native queue/report: `evidence/r9/idle-pool-20261028/`. B5 driver closed exit0 with sampled app/run-host/fake PIDs absent and default metadata unchanged; A1b is its scoped visual fix. The earlier CUA unflagged relaunch/default Dev WAL incident remains unverified and is preserved in the report.
- **1.8.0:** each brief's write set. Shared by region: `CatalogModel.swift` (C4, D1, F1); `SidebarView.swift` (B2, B3);
  Settings files (C3, B5c, G1). `Package.swift` belongs to I1 alone.

## 4. Next actions by role

- **`@planner`:**
  1. Package the integrated B3b and verify actual Settings/Help actions and Ink/Paper/collapsed-sidebar appearance in the guarded isolated package; retain the earlier default Dev WAL incident's unverified contents claim. Then review D1's diff, combined fake checks and the separate unexplained Quit observation before reserving real acceptance inputs. T3/Orca multi-round source anchors are checked; settle F0 wire/authority against the current seam map and D1/D2 interfaces. Named energy cells remain open. Never attach to/stop a pre-existing daemon.
     Review/integrate each slice and keep builds serialized; no repeated all-target pool for a scoped change.
  2. Carry B1b's layout-bound control migrations to B5 (its report); do not reopen the shared family to change a surface layout.
  3. Use the newly authorized idle window for the accumulated native visual/keyboard/VoiceOver, inspector/working-indicator
     and energy checks at a worthwhile pooled point. All builds remain serialized. The earlier corrected off-screen pool
     is done; do not repeat it merely because a scoped fix landed. No install/release authority was added.
- **`@user`:**
  1. Optional answers/objections to Q8–Q12 of [FEEDBACK-7](plans/FEEDBACK-7.md#decisions-open); silent items take their
     documented defaults at slice start. Q13 is authorized by D-108; isolated sign-ins remain user-owned when needed.
  2. Optional: object to the small calls taken at review (B1 and C2b's "Decisions taken" in their reports), such as hiding,
     not disabling, the sidebar's New session row when Claude cannot start.
  3. Still open from before: the push of `v1.6.0`–`v1.7.2` and the GitHub release; the Trash folders of 22, 25, 26 and 28 Oct.
- **`@researcher` warm `orca_cross_agents`:** bounded read-only F0 seam map, `evidence/r9/f0/seam-map/REPORT.md`; no source/canonical writes, builds or provider calls. P1 remains held.
- **`@implementer-core` warm `c4_core`:** finish D1 combined affected check/report; no real-provider turn. Parent reviews launch identity, safe effective permissions, start outcomes and owned cleanup before the production gate is accepted.
- **`@implementer-ink` warm `b3_ink`:** B3b source integrated; no further edits until parent native recheck.
- **`@implementer-ink` warm `c3_ink`:** B5b is integrated and its worktree removed; no further edits. Parent owns the actual native/performance checks. Unknown duration stays omitted.
- **`@optimizer`:** at the 1.8.0 gate (plans/1.8.0/README.md §4).
