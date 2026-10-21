# Status (Live Relay Board)

- **Updated:** 2026-10-22, 02:55
- **Stage:** Run toward **Sphyrna 1.6.0** (the first stable release, [D-83](DECISIONS.md)). Releases A, B, and C are closed (`cc54a17`); `0.4.4` remains the daily-use app and latest public GitHub release ([gencberke/loom](https://github.com/gencberke/loom), [D-56](DECISIONS.md)) until `@user` authorizes 1.6.0's tag, promote, install, and release.
- **State:** **waiting for implementation + pool #1 running** — overnight round: wave 1 and `L3a3` are on `v2` (`82b01d8`); pool #1 (the full gate with window tests) runs on that head; wave 2 runs (`L3c core`, `L3b` follow-ups) ([`plans/ACTIVE-PLAN.md` §3.3](plans/ACTIVE-PLAN.md#33-order-to-160-and-the-test-pool-d-90)).
- **Blocker:** none.

---

## 1. Current Operational Mode

- **Planner:** the session "Sphyrna 1.6.0 release planlama" is `@planner` from 22 Oct 02:20 (`@user`'s word). The earlier planner session and the track sessions `sphyrna-ink` / `sphyrna-core` are idle; implementers run as the planner's own subagents and slices integrate straight onto `v2` (the `ink` and `core` track branches are not used).
- **Overnight run authority ([D-91](DECISIONS.md)):** work until morning, Claude implementers only (no `@opencode`), the pooled batch in the idle window, real-Claude test turns where a check needs them; a light eye on usage. Tag, promote, install, push and release wait for `@user`.
- **Test cadence ([D-90](DECISIONS.md), [DEVELOPMENT.md §3.1](DEVELOPMENT.md#31-test-cadence-slices-one-pooled-batch-fixes-scoped-re-checks-d-90-22-oct-2026)):** narrow off-screen checks per slice; the pool runs when enough has collected; fixes get scoped re-checks.
- **Idle window:** `@user` is asleep; `caffeinate -dims` (pid 69498) holds the display and system awake until ~11:40.
- **Quota:** 5-hour window 15 % at 02:49 (resets 07:10), weekly 27 %. At most two implementers at once until the reset; `I5` and `I7` start after it.

---

## 2. Worktrees, Branches & HEAD Commits

| Role / Slice | Worktree Path | Branch | HEAD SHA | Working Tree Status |
| --- | --- | --- | --- | --- |
| Main repo (`loom-dev`) | `/Users/gencberke/Documents/github/loom-dev` | `swarm/1` | `9f2988e` (+ this board) | Planner docs |
| Integration branch | `~/Library/Caches/loom-v2/wt/v2` | `v2` | `82b01d8` | Clean; local only, never pushed |
| Pool #1 runner | `~/Library/Caches/loom-v2/wt/ink-idle` | detached | `82b01d8` | `check.sh --full --idle --windows` running (scratch `build/ink-idle`; output `evidence/pool1/full-gate.out`) |
| `L3c core` (core) | `~/Library/Caches/loom-v2/wt/core-devguard` | detached | `88a7dcc` (= `L3a3`; `slice/devguard`, `slice/l3a3`) | Implementer running |
| `L3b` follow-ups (ink) | `~/Library/Caches/loom-v2/wt/ink-remora-home` | detached | `10ab0c5` (`slice/l3b-home` `15aab82`; backup `slice/l3b-home-wip`) | Implementer running |
| `I6b` part 2 (done) | `~/Library/Caches/loom-v2/wt/oc-cleanup` | `slice/i6b-rest` | `250f733` | Clean; idle |
| Track branches (inactive) | `wt/ink`, `wt/core` | `ink`, `core` | `8447550`, `e3941fb` | Clean, behind `v2` |

---

## 3. Last Completed Tasks & Active File Locks

### Last Completed Tasks (on `v2`, 22 Oct night)
1. **Docs:** reorganization (`3d4aa37`), the test cadence D-90 (`30897a0`), the overnight authority D-91 (`037fc21`).
2. **`devguard`** (`d3d7b9a`): a plain `--evidence` launch without `--fake-providers` / `--claude-config` holds Remora Off in memory (`holdRemoraOff`).
3. **`L3a3`** (`c50fa1b`): folded weeks read, note `rewrittenAt`, working-memory updated time, `removeRemoraNoteWithUndo` (the old `removeRemoraNote(project:)` goes when the sheet switches).
4. **`L3b Home`** (`10ab0c5`): Remora on Home; guard lists `HomeRemoraCalls.swift: 3`, `EvidenceRemoraCommands.swift: 2`.
5. **`I6b` part 2** (`82b01d8`): the Agents tab in Ink (556 transcript width wired), Changes' empty states, Delete's Removed/Kept lists, dead symbols removed.

### Active File Locks (wave 2)
- **`L3c core`** (`wt/core-devguard`): `Sources/LoomRemora/**`, `CatalogModel+Remora.swift`, `Tests/LoomRemoraTests/**` except `RemoraReachTests.swift`, additions to `RemoraModelTests.swift`.
- **`L3b` follow-ups** (`wt/ink-remora-home`): `HomeRemora*.swift`, `HomeView.swift`, `RemoraMemoryModel.swift`, `RemoraMemoryText.swift`, `RemoraMemorySheet.swift`, `SettingsRemora*.swift`, `LoomTheme+Remora.swift`, `LoomTheme+Settings.swift` (new tokens only), their tests.
- **`@planner`:** canonical docs; `HighlightTests.swift` cleanup and the old `removeRemoraNote(project:)` removal are planner fix-ups after wave 2.

---

## 4. Next Actions by Role (`@role` Handoff Queue)

- **`@planner` (main session):**
  1. Read pool #1's result when it ends (`evidence/pool1/full-gate.out` and its check log); turn each failure into a fix slice with a scoped re-check (D-90).
  2. Review and integrate `L3c core` and the `L3b` follow-ups; then give `L3c` UI part A (palette) to the ink implementer and part B (Draft Brief row) after `L3c core` lands (`evidence/ink/briefs/l3c-ui.md`).
  3. After the 07:10 reset: `I7` and the `I5` renderer spike (wave 3); then the RC pool (End Batch runbook) and the closing `@optimizer` review.
  4. Doc pass at the end of wave 2: `docs/ARCHITECTURE.md` §11 (Agents, Changes, Delete, Home Remora, memory sheet rows), `DEVELOPMENT.md` §5 (Remora evidence commands, the devguard rule; the current row's `LOOM_DEV_REMORA` sentence is wrong), `SPEC.md` §10 ("nothing calls it until L3b"), `design/DESIGN.md` notes that the code now settles.
- **`@implementer-ink`:** `L3b` follow-ups running (memory door + sheet switch); `L3c` UI next.
- **`@implementer-core`:** `L3c core` running (Draft Brief call and model API).
- **`@optimizer` (Claude Opus 5.5 `max` / `gpt-6-astra` `xhigh`):** stand by for the 1.6.0 release candidate.
- **`@user`:** in the morning, read the night's summary. Pending decisions in [`DECISIONS.md` §3](DECISIONS.md#open): `O-01`, `O-09`, Remora's public-build default, the 1.6.0 eye checks and release word, and the disk cleanup.
