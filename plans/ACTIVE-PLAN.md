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
- **Current round (D-118):** Claude continues as planner-reviewer and optimizer on `v2` (`evidence/r9/claude-continuation-20261029/REPORT.md`). The daily-use 1.8.0 target remains incomplete; no release/install approval. [Acceptance matrix](1.8.0/ACCEPTANCE.md) governs completion. Pi is deferred (D-113).
- **The record before 1.8.0** (rounds 5 and 6, the rescue, the 1.6.0 slices, the End Batch Runbook):
  [archive/ACTIVE-PLAN-1.6.0-to-1.7.2.md](archive/ACTIVE-PLAN-1.6.0-to-1.7.2.md).

## Slice status

The order and the dependencies are in [the plan §3](1.8.0/README.md#3-the-slices). Status values: queued, ready,
running, in review, integrated (with the `v2` SHA), cut. Long checks: `~/Library/Caches/loom-v2/tools/` (COMMON §4).

| Wave | Slice | Status |
| --- | --- | --- |
| 0 | B0 the reference in Ink v4 | integrated `5ba94f1` (approved by `@user`, D-106, with the planner's fixes: Activity marks, the two pickers) |
| 0 | P0 Codex spike | investigation complete; real-input and auxiliary accounting lives in `evidence/r9/REAL-TURN-BUDGET.md`, not duplicated here |
| 0 | P1 opencode/agy spike | D-112 cheap short turns as needed; official-source preparation complete, native isolation proof before execution; user signs in when needed. Pi deferredD-113 |
| 1 | A1 project reorder | integrated `075cd7d` (after review: rows are direct list children again, `SidebarPagingTests`; the released gap holds until the order lands); a by-hand drag check waits for the gate |
| 3 | A1b project draft row overlap | integrated `f8adc58`,50 connected tests +actual Ink/Paper row/selection PASS; recovery evidence retained, slice tree/scratch removed |
| 1 | C1 harness catalogue | integrated `59e300e` (with the planner's fix: opencode has no doctor until P1) |
| 1 | B1 v4 tokens and controls | integrated `fe6f102` + `a81e2c0` (tokens, six button roles at four sizes, the focus halo, three elevations); its rest is closed by B1b |
| 1 | B1b shared controls and the last buttons | integrated `d2f3305` + `5c1f073`; five controls, remaining roles, Label, 36 pt main actions and 32 pt stepper; focus/AX regression fixed; planner's 7 affected suites PASS (63). Full attempt interrupted; pooled checks below |
| 1 | B0b the rest of the reference in v4 | integrated `bdaad69`; consistency pass closed by `fca9e2a` + `2d10f93` (shared complete parts, frame/crop rule, Connections and About) |
| 2 | C2 catalogue consumers | integrated `608266d` (one probe outcome, limits from the probe, efforts on the entries, no Peek singleton) |
| 2 | C2b the catalogue reaches every list | integrated `175f653` (no `ModelCatalog.shared`; availability on `CatalogModel`; one startable rule; File, Dock, Home, sidebar and menu bar follow the switch and the CLI); its follow-ups are in C3's brief |
| 2 | B2 sidebar and card | integrated `497a962` + `6601d5c`; off-screen layout/selection, viewport clock, rest render and accessibility checks pass |
| 2 | C3 Connections and Home connect cards | integrated `365b2d2` + `175f0e2`, parent seams `425878a`, `c84572b`, `1d4326d`; 9 core + 76 UI scoped tests pass; pooled guard/expectation fixes closed by `8e6fbf7` (112 affected tests PASS) |
| 2 | B3 status bar | integrated `26acb6c`; full-width 26 pt bar, cached limits/popover, bounded working menu, shared awake setting and sidebar utilities; 185 affected tests PASS; Q7's documented Yes default applied |
| 3 | B3b one bottom bar | integrated `f3d4f01` +Help AX fixf0d9117;93 slice +29 integrated scoped/window +14 fix tests PASS; actual Ink/Paper, repeated Help open/Escape, collapsed sidebar/fullscreen return PASS; source-equivalence/recovery cleanup complete |
| 3 | C4 neutral draft | integrated `049a95c`; 329 affected tests PASS on v2 (193 Core + 1 Chat + 135 UI); compatible choices/files and v1/v4, supported effort retained per DESIGN |
| 3 | B4 model and effort pickers | integrated `d727e87`; 140 offscreen tests PASS. Native fix `0c8a0b2` passes 47 affected tests and actual signed-app/keyboard gate. D-109 header stays read-only |
| 3 | D1 Codex sessions · D2 Codex reader and deletion | D1 integrated75f717f after actual T14 native first-message/approval/settings/Stop→same-ID zero-input Resume/VT/Quit PASS (5tests); independent owned cleanup verified. D2 reader be3e17a/ecfce1e,19connected+3revision checks PASS. Combined D1/H1:153/155Core and84UI PASS; one stale legacy window expectation caused the combined FAIL, then scoped24PASS072804-11792 closes it. Deletion remains separate |
| 3 | B5a Home/project/draft · B5b session surfaces | B5a integrated `e618124`, connected 9 Core +108 UI tests PASS (slice 345 UI run FAIL test-state collision, affected serialized 12 PASS); B5b integrated `339929d`, connected156 tests PASS; first-screen RSS/timing limits and native gates remain named |
| 3 | B5c Settings, sheets, palette, menus and About | integrated `7f77000`; 97 affected tests PASS (one corpus measurement skipped), six controlled theme renders; native/window/energy remain pooled |
| 3 | X1 reference/sidebar parity | integrated26088a1 (c3adafb +26088a1);65 parent scoped tests PASS, failing-first raster/AX evidence; native parity pooled; clean source-equivalent tree/branch/scratch removed with recovery bundle |
| 4 | F0 cross-harness child contract/foundation | integratedc7fc0ab/0c9b2a8;24 fake-host tests pass including typed host-resolved native input proof. Durable stable relationship/fresh rounds, explicit results/attention, bounded task grant, wait/check/interrupt and lifecycle fences. F1 wires existing owner/CLI/UI |
| 4 | F1 runtime/CLI and managed agent UI | source integrated through `fe442f5` plus `14eff70`: managed Claude/Codex children, user permission cards and Take Over. Production Claude controller/runtime same-child three-round fake flow and 48 UI checks pass `143028-70167`. The opening crash window is settled by `1e88c0a` (admission rule 1, `notAdmitted`; 73 task tests PASS `175922-13190`); the intermittent Claude interrupt remains open; native cross-harness multi-round acceptance is pending |
| 4 | H1 usage | source8980957 plus parentc32e35f trigger: authenticated hook/prompt/profile/run binding, event-driven bounded queued-write wait, source/deletion/scheduler fences and default-off no-read preflight;14Core+11UI PASS081625, final7Core PASS082920. Actual OS/native notification/resource acceptance pending |
| 4 | E1 opencode / E2 agy | E1 primitives and native product-path server/feed/empty session work; plugin-policy acceptance fails `143028-70167`. Ordinary and managed E1 runtime pending. E2 ordinary runtime is integrated `f31d53d`; managed AGY and native model/TUI acceptance remain pending |
| — | E3 pi | deferred from1.8.0 byD-113; no probe/integration in current goal |
| 4 | F2 Changes to session | pending; current frozen Chat send path is insufficient |
| 4 | G1 Remora backends | local fake OpenCode no-tools wire proved; actual offered-backend no-tools acceptance pending |
| 4 | I1 names and migration | pending; package identity/version/name audit is not complete |
| 4 | Optimizer resource fixes | transcript and Changes cache fixes integrated `4e492d7`; 37 Core + 27 UI scoped tests pass `143930-72609`. Actual process metrics remain separate |
| 5 | Z holistic gate and continuation | the continuation (`ca1a71e`…`92d6129`) fixed the actual AX crash, the menu AX regression, two real UI regressions, the opening window, a D-94 slip, two product blockers of the cooperative pool (found by an in-process stack probe), test fixtures that held the pool, a process-wide UI state shared by parallel tests, and stale expectations and test oracles. The full gate on `16a9158` had 6 issues in 2 tests (69, then 48, before), both fixed since; the window tests now run apart and are not yet re-run. No daily-use-ready claim |

## Current open work

- D-118 final evidence is `evidence/r9/final-wrap-20261029/` (exact files linked from `STATUS.md`). Read the full69-issue verdict, actual AX crash reproductions, positive scoped/deletion/metric evidence and the rejected Menu differential before continuing in existing Claude with permission/effort unchanged.
- Next:
  - The full gate on `92d6129` when the Mac is idle, the first one with the window tests in their own run.
  - Move the three remaining bounded `Task.detached` waits off the pool.
  - The test infrastructure review, read-only in its own session, then the user's decision on it.
  - Then the open slices.
- The opening-before-associated-ledger gap from `evidence/r9/optimizer/STALLED-FLOWS-ADVICE.md` is settled in `1e88c0a` with the advisory's provider-admission idea in its minimal form: the rule version and owner identity on the `opening` record, a `notAdmitted` disposition at store open and on live failures, and journaled (never claimed) host cleanup. Its optional host-side enrollment receipt and the bounded provisioning journal are not built. The interrupted durable Stop and never-started deletion corrections have scoped proof. The intermittent Claude interrupt has a passing controlled diagnostic and no established root cause.
- Preserve evidence limits: old whole pool `3560` tests failed three; later scoped fixes do not convert it to PASS. B5b first paint/RSS equivalence, native UI/VoiceOver/energy, native deletion, complete managed harness coverage and actual OS notification acceptance remain distinct gates.
- Historical progress details were moved out of this relay to [the dated snapshot](archive/ACTIVE-PLAN-1.8.0-20261029-progress.md). Founding product goals live in `SPEC.md` §1 and D-83.
