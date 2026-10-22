# Status (Live Relay Board)

- **Updated:** 2026-10-22, 10:20
- **Stage:** Run toward **Sphyrna 1.6.0** (the first stable release, [D-83](DECISIONS.md)). Releases A, B, and C are closed (`cc54a17`); `0.4.4` remains the daily-use app and latest public GitHub release ([gencberke/loom](https://github.com/gencberke/loom), [D-56](DECISIONS.md)) until `@user` authorizes 1.6.0's tag, promote, install, and release.
- **State:** **waiting for implementation** — overnight round: wave 1, `L3a3`, pool #1 (2 test fixes, `946fa73`), the `L3b` follow-ups (`a16fdc9`), `L3c core` (`2701819`), a cleanup (`906f136`) all of `L3c` (⌘K `55ad1ac`, the Draft Brief row `08d852f`, the palette's busy fix), and wave 3 (the `I5` spike `e15ebc4`, `I7` `cbedff8`, the README `c5eadc3`, the `I5` surfaces `7e12db7`) are on `v2`: every 1.6.0 slice is in. Next: the RC pool, whose on-screen and heavy parts wait for `@user`'s word that the Mac is idle ([`plans/ACTIVE-PLAN.md` §3.3](plans/ACTIVE-PLAN.md#33-order-to-160-and-the-test-pool-d-90)).
- **Blocker:** none.

---

## 1. Current Operational Mode

- **Planner:** the session "Sphyrna 1.6.0 release planlama" is `@planner` from 22 Oct 02:20 (`@user`'s word). The earlier planner session and the track sessions `sphyrna-ink` / `sphyrna-core` are idle; implementers run as the planner's own subagents and slices integrate straight onto `v2` (the `ink` and `core` track branches are not used).
- **Day mode (22 Oct, `@user`):** off-screen work goes on; the RC pool's on-screen part runs only on `@user`'s word. The night's authority (D-91) is spent. `I7` waited on one approval prompt from 04:03 to 08:50 (a probe with `rm -rf` on a variable path): Briefs now tell implementers to avoid commands that ask for approval.
- **Test cadence ([D-90](DECISIONS.md), [DEVELOPMENT.md §3.1](DEVELOPMENT.md#31-test-cadence-slices-one-pooled-batch-fixes-scoped-re-checks-d-90-22-oct-2026)):** narrow off-screen checks per slice; the pool runs when enough has collected; fixes get scoped re-checks.
- **Quota:** 5-hour window 5 % at 09:17 (resets 13:50), weekly 31 %.

---

## 2. Worktrees, Branches & HEAD Commits

| Role / Slice | Worktree Path | Branch | HEAD SHA | Working Tree Status |
| --- | --- | --- | --- | --- |
| Main repo (`loom-dev`) | `/Users/gencberke/Documents/github/loom-dev` | `swarm/1` | this board's commit | Planner docs |
| Integration branch | `~/Library/Caches/loom-v2/wt/v2` | `v2` | this board's commit (after `55ad1ac`) | Clean; local only, never pushed |
| Pool runner | `~/Library/Caches/loom-v2/wt/ink-idle` | detached | `a3f950d` (pool #1 fixes) | Clean; pool #1 done (`evidence/pool1/`) |
| Free (README done) | `~/Library/Caches/loom-v2/wt/core-devguard` | `slice/i7c-readme` | `c5eadc3`'s slice | Clean (scratch `build/core-devguard`) |
| Free (`I5` done) | `~/Library/Caches/loom-v2/wt/ink-remora-home` | `slice/i5-surfaces` | `7e12db7`'s slice | Clean (scratch `build/ink-remora-home`) |
| Planner checks (free) | `~/Library/Caches/loom-v2/wt/oc-cleanup` | detached | `cbedff8` (`slice/i7-identity`) | Clean (scratch `build/oc`) |
| Track branches (inactive) | `wt/ink`, `wt/core` | `ink`, `core` | `8447550`, `e3941fb` | Clean, behind `v2` |

---

## 3. Last Completed Tasks & Active File Locks

### Last Completed Tasks (on `v2`, 22 Oct night)
1. **Docs:** reorganization (`3d4aa37`), the test cadence D-90 (`30897a0`), the overnight authority D-91 (`037fc21`).
2. **`devguard`** (`d3d7b9a`): a plain `--evidence` launch without `--fake-providers` / `--claude-config` holds Remora Off in memory (`holdRemoraOff`).
3. **`L3a3`** (`c50fa1b`): folded weeks read, note `rewrittenAt`, working-memory updated time, `removeRemoraNoteWithUndo` (the old `removeRemoraNote(project:)` goes when the sheet switches).
4. **`L3b Home`** (`10ab0c5`): Remora on Home; guard lists `HomeRemoraCalls.swift: 3`, `EvidenceRemoraCommands.swift: 2`.
5. **`I6b` part 2** (`82b01d8`): the Agents tab in Ink (556 transcript width wired), Changes' empty states, Delete's Removed/Kept lists, dead symbols removed.
6. **Pool #1** (`check.sh --full --idle --windows` on `82b01d8`, `check-20261022T024827-80012.log`): release build and release tree pass; ~3,160 tests, 2 failures, both stale tests (a clock limit under load; the back control's resize under D-78's widths), fixed in `946fa73` and re-checked in scope (31 passed, `check-20261022T032147-90511.log`).
7. **`L3b` follow-ups** (`a16fdc9`): Home's Memory… door (with a two-line loom-app seam) and the memory sheet on `L3a3`'s weeks, times and per-removal Undo.
8. **`L3c core`** (`2701819`): `draftRemoraBrief(project:) async` and `remora.draft` (a question-kind call marked `isDraft`; same stable prefix as a project question; usage `drafts`; journal `for=draft`).
9. **Cleanup** (`906f136`): the old `removeRemoraNote(project:)` and five unused theme tokens.
10. **⌘K's Ask Remora** (`55ad1ac`, `L3c` part A): the question rule, the scopes, ↵ / ⌘↵ / Esc, the answer in the palette with Home's chips; guard `PaletteRemora.swift: 1`.
11. **Docs:** the wave 2 pass (ARCHITECTURE §11 and the Remora bullets, SPEC §10, DEVELOPMENT §5's devguard and palette rows, the plan's statuses).
12. **The Draft Brief row** (`08d852f`, `L3c` part B): offer, reading with Stop, drafted with the call's time and Draft Again, copied, failed, stopped, busy; Put in Draft's rule for the new-session composer; guard `draftRemoraBrief(`: the row 1, evidence 1.
13. **The palette's busy fix** (planner): Ask Remora is busy while a draft reads; both doors' suites pass together (163 tests, `check-20261022T035758-4751.log`).
14. **`I5` spike** (`e15ebc4`): the art's engine, clock and layer drawing in new files; off-screen proxies chose the layer and Home's loop live (`evidence/ink/i5/spike.md`).
15. **`I7` A and B** (`cbedff8`): the app is named Sphyrna wherever the user reads it (Loom stays for ids, folders, file names, the `loom` command); the wording guard fails on "Loom" in literals; Rising (`assets/icon/`, `scripts/make-app-icon.sh`) and Front; integrated check `check-20261022T092038-18996.log`.
16. **README** (`c5eadc3`, `I7` part C): six Ink pictures built from the reference's documents with neutral names; README.release.md for 1.6.0 with a part for 0.4.4 users.
17. **`I5` surfaces** (`7e12db7`): the sharks on every place of DESIGN §17 (`ArtPlace`), Remora's arrival, Settings → Theme's Animated art.

### Active File Locks
- None: every slice is integrated. **`@planner`:** canonical docs.

---

## 4. Next Actions by Role (`@role` Handoff Queue)

- **`@planner` (main session):** on `@user`'s idle word, the RC pool on `H` (End Batch runbook steps 0–10, `evidence/ink/evening-queue.md` items 1–18, the full gate with windows, C8, real Claude 9a–9d); then fixes with scoped re-checks and the closing `@optimizer` review.
- **`@implementer-ink` / `@implementer-core`:** idle until the pool turns up fixes.
- **`@optimizer` (Claude Opus 5.5 `max` / `gpt-6-astra` `xhigh`):** stand by for the 1.6.0 release candidate.
- **`@user`:** in the morning, read the night's summary. Pending decisions in [`DECISIONS.md` §3](DECISIONS.md#open): `O-01`, `O-09`, Remora's public-build default, the 1.6.0 eye checks and release word, and the disk cleanup.
