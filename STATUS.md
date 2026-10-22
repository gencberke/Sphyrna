# Status (Live Relay Board)

- **Updated:** 2026-10-22, 23:05
- **Stage:** Run toward **Sphyrna 1.6.0** (the first stable release, [D-83](DECISIONS.md)). Releases A, B, and C are closed (`cc54a17`); `0.4.4` remains the daily-use app and latest public GitHub release ([gencberke/loom](https://github.com/gencberke/loom), [D-56](DECISIONS.md)) until `@user` authorizes 1.6.0's tag, promote, install, and release.
- **State:** **waiting for `@user`** — the RC pool is done and its fixes are re-checked (`ab1d0c9`, `0461a54`). `@user` chose to ship 1.6.0 with the measured numbers as its budgets and to study Chat's streaming cost after 1.6.0 with feedback from use ([D-92](DECISIONS.md), resolves `O-01`). `@user` is looking at the dev build (`rc2`) on a fake-data world; then the promote decision.
- **Blocker:** `@user`'s word on promote (with acceptance 6's closing `@optimizer` review before the public release).

---

## 1. Current Operational Mode

- **Planner:** the session "Sphyrna 1.6.0 release planlama" is `@planner` from 22 Oct 02:20 (`@user`'s word). The earlier planner session and the track sessions `sphyrna-ink` / `sphyrna-core` are idle; implementers run as the planner's own subagents and slices integrate straight onto `v2` (the `ink` and `core` track branches are not used).
- **Evening idle window (22 Oct, `@user`):** tests and development at the planner's judgment, with screen time kept short. The screen work ended at 22:19. The night's authority (D-91) is spent. Briefs tell implementers to avoid commands that ask for approval, and to wait on `evidence/tools/wait-measurements.sh` before any build while C8 measures.
- **Test cadence ([D-90](DECISIONS.md), [DEVELOPMENT.md §3.1](DEVELOPMENT.md#31-test-cadence-slices-one-pooled-batch-fixes-scoped-re-checks-d-90-22-oct-2026)):** narrow off-screen checks per slice; the pool runs when enough has collected; fixes get scoped re-checks.
- **Quota:** 5-hour window 30 % at 22:20 (resets 23:50), weekly 45 %.

---

## 2. Worktrees, Branches & HEAD Commits

| Role / Slice | Worktree Path | Branch | HEAD SHA | Working Tree Status |
| --- | --- | --- | --- | --- |
| Main repo (`loom-dev`) | `/Users/gencberke/Documents/github/loom-dev` | `swarm/1` | this board's commit | Planner docs |
| Integration branch | `~/Library/Caches/loom-v2/wt/v2` | `v2` | this board's commit (after `0461a54`) | Clean; local only, never pushed |
| RC package | `wt/rc2-candidate` | detached | `0461a54` | Clean; package `rc2-*` under `Loom-Dev/packages/` |
| Package worktree | `wt/core` | `core` | `e3941fb` | Clean; `build-c8.sh` adds its worktrees from here |
| Old worktrees | 35 under `wt/` (Release A–C era) | detached | various | Uncommitted changes, left for `@user` (`evidence/cleanup-20261022.md`) |
| Track branches (inactive) | — (worktrees removed) | `ink`, `core` | `8447550`, `e3941fb` | Branches kept, behind `v2` |

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
18. **The RC pool on `H` = `c5b5dd3`** (`evidence/end-batch-c5b5dd3/`, the runbook's "trimmed window"): window tests, the C8 runner smoke, the full gate (`check-20261022T171127-67168.log`, 364 + 1,709 tests) and real Claude 9a–9d pass (9a after its script's fix; Haiku 9 of 10 turns); ink's pairs 2–18, with the by-hand rest listed for `@user`. Most differences were the tools' or the seeds' (the dev build offers Codex; no presets or transcripts seeded; a 1280×880 reference window); `ended-terminal` caught Chat because a stopped Claude session shows Chat under the Chat switch (SPEC §6.1).
19. **C8, trimmed** (`evidence/core/budgets/BUDGETS-c5b5dd3.md`): idle CPU ≤ 0.3 % everywhere; the empty app 65 MiB (proposal ≤ 40); 100 open/close cycles leave nothing; launch to the first page 179–213 ms; Chat over 600 s +24 MiB, then flat. **Acceptance 3 fails:** Chat 23.3 % vs the terminal's 6.1 % at 600 chars/s (3.8×), 48.9 % vs 19.6 % at 6,000 (2.5×), Chat's peak 391 MiB vs 115. A profile (`evidence/core/c7/`, tonight's samples) puts half of the busy time in the display cycle: SwiftUI's focus bridge rebuilding the key-view loop (22 %), `.textSelection` (14 %), the measurer; memory is the one tall row per message (about 4 KB of backing store per character of the open message). The art costs 3–4.3 % CPU while visible, 0 hidden or off.
20. **Fixes #2:** `ab1d0c9` (while a brief is written Home shows three empty frames, DESIGN §9; tests that draw the answer card for a field question and none for a model-only one); `0461a54` (Settings' scrim and sheet measured from the window's top; full screen auto-hides the empty toolbar with the menu bar, with a Dock option AppKit accepts; Solid | Glass; `--fork-session` in the evidence toolchain).
21. **The re-check on `rc2` = `0461a54`** (`evidence/ink/recheck-queue.md`): the staged release tree builds with no evidence code (`check-20261022T222057-41042.log`); window tests 40 passed; the service smoke 12 of 12; the working indicator ≤ 0.02 % CPU in every row; the reading frames, the ended screen, Solid | Glass and both sheets pair; full screen leaves Home's date line and the session header uncovered. Left for a person: the menu bar's reveal over Home in full screen, and Cancel's focus ring with keyboard navigation on. The ended line over the read-only chat's kept-screen fallback has no Show Details (an edge case: a transcript normally shows there).
22. **[D-92](DECISIONS.md)** (`@user`, 22:50): 1.6.0's budgets from C8, `O-01` resolved; Chat's parity after 1.6.0 ([ACTIVE-PLAN §5](plans/ACTIVE-PLAN.md#5-post-160-roadmap-items) item 4).
23. **Cleanup** (`@user`'s word, `evidence/cleanup-20261022.md`): 23 build scratches and 40 old packages (22 GB) moved to `~/.Trash/loom-cleanup-20261022`; 36 clean worktrees removed (their commits stay in git); `build/v2`, `build/c8`, the `rc2` package, the 0.4.4 reference package, the evidence and every branch kept.

### Active File Locks
- None: every slice is integrated. **`@planner`:** canonical docs.

---

## 4. Next Actions by Role (`@role` Handoff Queue)

- **`@user`:** look at the dev build (`rc2`, fake data; the planner closes it on your word); then the promote word: the tag `release/1.6.0`, `promote.sh`, the build and install over 0.4.4 in `/Applications` (the planner copies `~/Library/Application Support/Loom` first: the catalog migrates forward on open), the push and the GitHub release. Acceptance 6 wants the closing `@optimizer` review before the public release. Also open: `O-09`, Remora's public-build default, the eye checks (the pool's by-hand list), emptying `~/.Trash/loom-cleanup-20261022`, and the 35 old worktrees with uncommitted changes.
- **`@planner` (main session):** on `@user`'s word, the steps above in order; then a Chat performance slice with feedback.
- **`@implementer-ink` / `@implementer-core`:** idle.
- **`@optimizer` (Claude Opus 5.5 `max` / `gpt-6-astra` `xhigh`):** stand by for the release candidate `v2` = `0461a54` plus the docs.
