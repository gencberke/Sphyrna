# Status (Live Relay Board)

- **Updated:** 2026-10-22, 22:35
- **Stage:** Run toward **Sphyrna 1.6.0** (the first stable release, [D-83](DECISIONS.md)). Releases A, B, and C are closed (`cc54a17`); `0.4.4` remains the daily-use app and latest public GitHub release ([gencberke/loom](https://github.com/gencberke/loom), [D-56](DECISIONS.md)) until `@user` authorizes 1.6.0's tag, promote, install, and release.
- **State:** **waiting for `@user`** — the RC pool ran on `H` = `c5b5dd3` in the evening's idle window, shortened on `@user`'s word (C8's tiers as one 18-cell list, ink's items 17–18 cut to their core; about 2 h of screen after the trim). Its real failures are fixed on `v2` and re-checked on the `rc2` package: `ab1d0c9` (Remora's reading frames, the answer card's tests) and `0461a54` (Settings' sheets cover the title strip, full screen auto-hides the empty toolbar, Solid | Glass, the evidence toolchain's fork flag). C8 fails acceptance 3: Chat's CPU is 3.8× the terminal's at 600 chars/s and 2.5× at 6,000 (C7 cut about 10 %).
- **Blocker:** `@user`'s call on Chat's cost against acceptance 3, with `O-01`'s budgets (STATUS §4).

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
| RC packages | `wt/c8-candidate`, `wt/rc2-candidate` | detached | `c5b5dd3` (`H`), `0461a54` (the fixes) | Clean; packages `c8-*` (C8's numbers) and `rc2-*` (the re-check) under `Loom-Dev/packages/` |
| Fix slices (done) | `wt/fix-remora-home`, `wt/fix-shell` | `slice/fix-remora-home`, detached | `dfe9bc1`, `0461a54` | Clean (scratches `build/fix-remora-home`, `build/fix-shell`) |
| Free | `wt/core-devguard`, `wt/ink-remora-home`, `wt/oc-cleanup`, `wt/ink-idle` | — | earlier slices | Clean |
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
18. **The RC pool on `H` = `c5b5dd3`** (`evidence/end-batch-c5b5dd3/`, the runbook's "trimmed window"): window tests, the C8 runner smoke, the full gate (`check-20261022T171127-67168.log`, 364 + 1,709 tests) and real Claude 9a–9d pass (9a after its script's fix; Haiku 9 of 10 turns); ink's pairs 2–18, with the by-hand rest listed for `@user`. Most differences were the tools' or the seeds' (the dev build offers Codex; no presets or transcripts seeded; a 1280×880 reference window); `ended-terminal` caught Chat because a stopped Claude session shows Chat under the Chat switch (SPEC §6.1).
19. **C8, trimmed** (`evidence/core/budgets/BUDGETS-c5b5dd3.md`): idle CPU ≤ 0.3 % everywhere; the empty app 65 MiB (proposal ≤ 40); 100 open/close cycles leave nothing; launch to the first page 179–213 ms; Chat over 600 s +24 MiB, then flat. **Acceptance 3 fails:** Chat 23.3 % vs the terminal's 6.1 % at 600 chars/s (3.8×), 48.9 % vs 19.6 % at 6,000 (2.5×), Chat's peak 391 MiB vs 115. A profile (`evidence/core/c7/`, tonight's samples) puts half of the busy time in the display cycle: SwiftUI's focus bridge rebuilding the key-view loop (22 %), `.textSelection` (14 %), the measurer; memory is the one tall row per message (about 4 KB of backing store per character of the open message). The art costs 3–4.3 % CPU while visible, 0 hidden or off.
20. **Fixes #2:** `ab1d0c9` (while a brief is written Home shows three empty frames, DESIGN §9; tests that draw the answer card for a field question and none for a model-only one); `0461a54` (Settings' scrim and sheet measured from the window's top; full screen auto-hides the empty toolbar with the menu bar, with a Dock option AppKit accepts; Solid | Glass; `--fork-session` in the evidence toolchain).
21. **The re-check on `rc2` = `0461a54`** (`evidence/ink/recheck-queue.md`): the staged release tree builds with no evidence code (`check-20261022T222057-41042.log`); window tests 40 passed; the service smoke 12 of 12; the working indicator ≤ 0.02 % CPU in every row; the reading frames, the ended screen, Solid | Glass and both sheets pair; full screen leaves Home's date line and the session header uncovered. Left for a person: the menu bar's reveal over Home in full screen, and Cancel's focus ring with keyboard navigation on. The ended line over the read-only chat's kept-screen fallback has no Show Details (an edge case: a transcript normally shows there).

### Active File Locks
- None: every slice is integrated. **`@planner`:** canonical docs.

---

## 4. Next Actions by Role (`@role` Handoff Queue)

- **`@user`:** decide how 1.6.0 takes Chat's cost (acceptance 3): (A) ship with tonight's numbers recorded as budgets and a Chat performance slice after 1.6.0 (the planner's recommendation); (B) first slow the streaming flush from 80 to about 150 ms (about −40 % CPU, a choppier stream to judge by eye); (C) B plus no text selection while a message streams and the focus-loop trigger (a day or more). With it, `O-01`'s budgets (the empty app's footprint, Chat's growth, the art's CPU), `O-09`, Remora's public-build default, the 1.6.0 eye checks (the pool's by-hand list) and the release word.
- **`@planner` (main session):** on `@user`'s call, record `O-01` in `DECISIONS.md` and run the chosen Chat work; then the closing `@optimizer` review on `v2`, once; then the release steps on `@user`'s word.
- **`@implementer-ink` / `@implementer-core`:** idle.
- **`@optimizer` (Claude Opus 5.5 `max` / `gpt-6-astra` `xhigh`):** stand by for the release candidate `v2` = `0461a54` plus the docs.
