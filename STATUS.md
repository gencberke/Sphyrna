# Status (Live Relay Board)

- **Updated:** 2026-10-22, 01:50
- **Stage:** Run toward **Sphyrna 1.6.0** (the first stable release, [D-83](DECISIONS.md)). Releases A, B, and C are closed (`cc54a17`); `0.4.4` remains the daily-use app and latest public GitHub release ([gencberke/loom](https://github.com/gencberke/loom), [D-56](DECISIONS.md)) until `@user` authorizes 1.6.0's tag, promote, install, and release.
- **State:** **waiting for implementation (5h window reset at 00:30 passed; ready to resume `L3b Home` or run `@opencode` ([D-89](DECISIONS.md)))**.
- **Blocker:** none.

---

## 1. Current Operational Mode & Why Tracks Were Paused

- **Previous pause resolved:** At 22:36 on 21 Oct, the Claude subscription's 5-hour window reached **82 %** (reset at **00:30**; weekly window at **24 %**), and `@user` asked to pause the Claude tracks (`sphyrna-ink` and `sphyrna-core`) until reset while running bounded slices via `@opencode`. The 00:30 reset has now passed.
- **No running builds:** Both Claude tracks are paused at clean boundaries with no running processes; `~/Library/Caches/loom-run1/build-slot.lock` has no holder.
- **`@opencode` mode ([D-89](DECISIONS.md)):** Bounded non-overlapping slices and cleanups run via `opencode` 2.1.2 (`DeepSeek V4.1 Flash Free`) in `~/Library/Caches/loom-v2/wt/oc-cleanup` from Briefs in `~/Library/Caches/loom-v2/evidence/oc/`, always launched under **`taskpolicy -b`** (background priority on efficiency cores) so the Mac stays cool. `@planner` reviews the diff and `~/Library/Caches/loom-v2/evidence/oc/run-*.log` once and integrates onto `v2`.
- **Canonical docs unified (22 Oct):** Repository documentation was restructured into the clean hierarchy (`AGENTS.md`, `STATUS.md`, `DECISIONS.md`, `SPEC.md`, `docs/ARCHITECTURE.md` including the UI Surface-to-Code Index that replaces `design/UI-MAP.md`, `design/DESIGN.md`, `DEVELOPMENT.md`, `plans/ACTIVE-PLAN.md`, and `plans/archive/`) across both `loom-dev` and `wt/v2`.

---

## 2. Worktrees, Branches & HEAD Commits

| Role / Track | Worktree Path | Branch | HEAD SHA | Working Tree Status |
| --- | --- | --- | --- | --- |
| Main repo (`loom-dev`) | `/Users/gencberke/Documents/github/loom-dev` | `swarm/1` | `1747adb` (+ unified docs) | Unified docs ready |
| Integration branch | `~/Library/Caches/loom-v2/wt/v2` | `v2` | `9f4bf75` (+ unified docs) | Local only, never pushed |
| Track `sphyrna-ink` | `~/Library/Caches/loom-v2/wt/ink` | `ink` | `8447550` | Clean |
| Track `sphyrna-core` | `~/Library/Caches/loom-v2/wt/core` | `core` | `e3941fb` | Clean |
| `L3b Home` slice (paused) | `~/Library/Caches/loom-v2/wt/ink-remora-home` | detached | `a7854b5` | **22 uncommitted files** (5 modified, 17 untracked); resume note at `~/Library/Caches/loom-v2/evidence/ink/l3b-home-resume.md` |
| `@opencode` runner | `~/Library/Caches/loom-v2/wt/oc-cleanup` | `oc/i6b` | `0214e7a` | Clean |
| Ink window-test runner | `~/Library/Caches/loom-v2/wt/ink-idle` | detached | `2e2b66b` (moves to `H` at end batch) | Clean |
| Merge-base (14 Oct) | `~/Library/Caches/loom-v2/wt/base` | detached | `24d8cfb` | Clean |

---

## 3. Last Completed Tasks & Active File Locks

### Last Completed Tasks (Integrated on `v2` at `9f4bf75`)
1. **`@opencode` Task 1 — Theme & menu bar cleanup (`e85d163`):** Removed 13 dead tokens left by `I4c` and unified `menuBarEntries()` with `attentionCandidates()` (88 tests in 6 suites, `check-20261021T230637-53241.log`).
2. **`@opencode` Task 2 — Settings family exact lines (`74fa750`, `142a710`):** Moved sheet title/subject/facts/list items, memory sheet journal/notes, `SettingsNote`, Remora's last line, tone tile detail, and Usage fine print onto `.lineHeight(.exact)` with `Settings.glyphDrop` (116 tests in 11 suites, `check-20261021T232351-55941.log`).
3. **`@opencode` Task 3 — Sheet list labels (`88b627b`):** Put sheet list labels (`Removed`, `Kept`) on the exact `10.5` line (`SettingsLabel`), fixing the 2 pt offset (25 tests, `check-20261021T234409-59607.log`).
4. **`@opencode` Task 4 — Slice `I6b` sheets & Changes status letters (`0214e7a`, `9f4bf75`):** Moved the main window's 4 sheets (Rename, Delete, Rewind Files, Discard Side Chat) onto `InkSheet` / `SheetPresenter` / `sheetLayer` with window key-down hold-backs (`presenter.isOpen`), and added status letters (`M`, `A`, `D`, `R`) and `old → new` renames to the Changes list (104 tests in 14 suites, `check-20261022T001308-63225.log`).

### Active File Locks (Held by Paused `L3b Home` in `wt/ink-remora-home`)
Until `L3b Home` is integrated onto `v2` and `@planner` releases these locks, no other agent may edit:
- `Tests/LoomRemoraTests/RemoraReachTests.swift`
- `Sources/loom-app/Evidence/EvidenceRemoraCommands.swift`
- `Sources/loom-app/Evidence/EvidenceHomeCommands.swift`
- `Sources/LoomCatalogUI/CatalogModel+RemoraDraft.swift`
- `Sources/LoomCatalogUI/NetworkReach.swift`
- `Sources/LoomCatalogUI/CatalogModel+Home.swift` (and `HomeBand.swift`, `HomeView.swift`)

---

## 4. Next Actions by Role (`@role` Handoff Queue)

- **`@planner` (main session):**
  0. **Commit the unified canonical docs on local `v2` (`wt/v2`) first:** The 22 Oct canonical documentation reorganization is staged/modified in both `loom-dev` and `~/Library/Caches/loom-v2/wt/v2`. Before cherry-picking or rebasing any slice onto `v2`, commit the doc reorganization on local `v2` in `~/Library/Caches/loom-v2/wt/v2` so `wt/v2` is clean and every rebased track/slice worktree inherits the new canonical doc hierarchy.
  1. **Resume `L3b Home`:** Now that the 5-hour window has reset, resume `@implementer-ink` (agent `ae2c6e88ec983c327` in `~/Library/Caches/loom-v2/wt/ink-remora-home`) per `~/Library/Caches/loom-v2/evidence/ink/l3b-home-resume.md`, review its final checks, integrate onto `v2` (note: `design/UI-MAP.md` was retired into [`docs/ARCHITECTURE.md` §11](docs/ARCHITECTURE.md#11-ui-surface-to-code--evidence-index), where `L3b Home`'s entries are already indexed), and release `L3b Home`'s file locks.
  2. **Dispatch queued Core slices:** Once `L3b Home` releases `RemoraReachTests.swift`, instruct `@implementer-core` (or `@opencode`) to run `~/Library/Caches/loom-v2/evidence/core/devguard-brief.md` (plain evidence launch holds Remora Off in memory) followed by `~/Library/Caches/loom-v2/evidence/core/l3a3-brief.md` (folded journal weeks read, `updated`/`rewritten` mtimes, and `removeRemoraNoteWithUndo`), and integrate both onto `v2`.
  3. **Sequence remaining Ink / `@opencode` slices:** See [`plans/ACTIVE-PLAN.md` §3](plans/ACTIVE-PLAN.md#3-track--slice-status-tables-toward-160):
     - Wire `openRemoraMemory` from Home (`⋯ → Memory…` and footer `Memory…`) and switch `RemoraMemorySheet` onto `L3a3`'s weeks, times, and per-removal undo token.
     - **`L3c`:** `⌘K` Command Palette "Ask Remora" + Draft page `Draft Brief` row under presets.
     - **Remaining `I6b` & cleanup items:** Inspector `Agents` tab in Ink (cards without accent badge, 556 pt subagent transcript in two voices with `"Result"` / `"Waiting for you"`), Delete sheet `Removed`/`Kept` lists, and removing dead symbols (`DestructiveButtonStyle`, `LoomTheme.Rewind.sheetWidth`, `RewindSheetKeys`).
     - **`I7`:** Sphyrna user-facing rename, `Rising` app icon, `Front` 20 pt menu bar mark, and Ink README renders.
     - **`I5`:** Native ASCII shark renderer spike, `Animated art` switch in Settings → Theme, and placing sharks on [`design/DESIGN.md` §17](design/DESIGN.md#17-the-school) surfaces.
  4. **End Batch & Optimizer:** When `@user` opens the overnight idle window ([D-87](DECISIONS.md)), execute [`plans/ACTIVE-PLAN.md` §4 (End Batch Runbook)](plans/ACTIVE-PLAN.md#4-complete-end-batch-runbook-d-87) and run `@optimizer` ([D-06](DECISIONS.md)).

- **`@implementer-ink` (`sphyrna-ink` track in `wt/ink` / `wt/ink-remora-home`):**
  - Complete steps 1–6 of `~/Library/Caches/loom-v2/evidence/ink/l3b-home-resume.md`: rebase onto `v2` HEAD (dropping the `design/UI-MAP.md` hunk since `UI-MAP.md` is now in `docs/ARCHITECTURE.md` §11), run `RemoraReachTests`, `RemoraHomeStateTests`, `RemoraModelTests`, `HomeBandTests`, and `HomeRenderTests` with thermal-wait and 90 s gaps, verify the regression guard fails on old code, and report Ready to `@planner`.
  - Then proceed to `openRemoraMemory` + `L3a3` sheet wiring, `L3c`, `I7`, `I5`, and end-batch steps 0, 2, and 5.

- **`@implementer-core` (`sphyrna-core` track in `wt/core`):**
  - Wait for `@planner` to confirm `L3b Home` integration and lock release.
  - Cut `~/Library/Caches/loom-v2/wt/core-devguard` at the new `v2` HEAD (scratch `~/Library/Caches/loom-v2/build/core-devguard`), execute `devguard-brief.md` (Ready 1) and `l3a3-brief.md` (Ready 2), and during the end batch run steps 1, 3, 4, 6, and 10.

- **`@opencode` (`wt/oc-cleanup` under `taskpolicy -b`):**
  - Stand by for bounded whole-slice Briefs from `@planner` (`~/Library/Caches/loom-v2/evidence/oc/`) touching only `Sources/` and `Tests/` outside active locks.

- **`@optimizer` (Claude Opus 5.5 `max` / `gpt-6-astra` `xhigh`):**
  - Stand by for the mandatory 1.6.0 closing review once slices land.

- **`@user`:**
  - Review Pending Decisions in [`DECISIONS.md` §3](DECISIONS.md#open) (`O-01`, `O-07`, `O-09`, Remora public-build default, 1.6.0 eye checks, and disk cleanup approval).
