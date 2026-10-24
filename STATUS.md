# Status (Live Relay Board)

- **Updated:** 2026-10-24 15:00
- **Stage:** **Round 5: 1.6.1's slices are in progress** ([plans/ACTIVE-PLAN.md §0](plans/ACTIVE-PLAN.md#0-round-5-sphyrna-161-from-24-oct-d-93), [plans/FEEDBACK-5.md](plans/FEEDBACK-5.md)), from `@user`'s first notes on 1.6.0.
  - Sphyrna 1.6.0, the first stable release ([D-83](DECISIONS.md)), is tagged, promoted and installed locally (23 Oct).
  - `0.4.4` remains the latest public GitHub release ([gencberke/loom](https://github.com/gencberke/loom), [D-56](DECISIONS.md)).
  - The release line is now **1.6.1**, then **1.6.2**, then **1.7.0** ([D-93](DECISIONS.md)):
    - **1.6.1:** the round's fixes, identity, drag and drop, and flow.
    - **1.6.2:** the app-wide infrastructure for Codex at parity ([D-94](DECISIONS.md)).
    - **1.7.0:** the session channel and Codex's binding.
- **State:** **1.6.0 is the daily app.** `release/1.6.0` is `v2` `678d5ab`, promoted as the loom tree's `9da0467` (tag `v1.6.0`, local, unpushed) and installed in `/Applications` as build 10600. The 0.4.4 data is backed up in `~/Library/Application Support/Loom-backup-0.4.4-20261023T084919`.
  - Round 5's causes are traced, Chat's streaming cost is studied (FB5-10), and the decisions are recorded as D-93 to D-99.
  - **`@user`'s go (24 Oct, about 12:50):** "mac boşta olacak. başlayabilirsin." The open questions take their defaults: Q2, Q3, Q6, Q7 and Q13 to Q17 in [FEEDBACK-5](plans/FEEDBACK-5.md#decisions). That is the planner's reading of the go; `@user` can change any of them.
  - The slices run as the planner's subagents, each in its own `wt/r5-*` worktree (§2).
  - **Paused at about 15:00 for the 5-hour usage limit** (`@user`: "düzgün şekilde duraklat … geri açılınca sağlıklı şekilde devam ederiz"). Each running agent writes `evidence/r5/<slice>/PAUSE.md` and leaves its uncommitted work in its worktree; nothing unverified is committed. The resume steps are in §1 below and in `evidence/r5/RUN.md`.
  - **On `v2` at 15:00** (`27b0831`), on top of `988256a`, 26 commits:
    - Settings' clicks `dfb90ba`; the icon `8161e80`, `7b6161a`; Put in Draft and the read key `f133761`;
    - drag: `8e9475c`, `be711f2`, `4fd009b`, `eeac5e9`, `27b0831` (tab strip drop and reorder, header zone, projects by drag, ⇧⌘T);
    - the inspector: `2202fc6` (widths), `2b9dd3c`, `5dd11ef` (drag out of Changes as `@path`);
    - Remora's face and cleanup: `37851a1`, `82ce829`, `2291efc`, `69bd12c`;
    - drafts: `1a593de`, `73e6b64`, `e0ada41` (several drafts; Draft Brief never overwrites);
    - the mention pill: `38717ad`, `9359193`;
    - Chat cost S0–S2: `7ccae36`, `ff13bf9`, `4dbf353`;
    - FB5-12: `0840516`.
  - A combined check on `v2` `9359193` passed (140 + 15 tests). Drag step 2's window suites passed on AC.
  - **Paused mid-step:** Settings step 2 (`10a4973` committed; proof and keep awake open), the inspector's step 3 (`b8a5b0a` committed; the palette uncommitted), the pill's step 2 (uncommitted, after merging `v2` `9359193`), Chat cost S3 (uncommitted).
  - **Chat cost baseline** (`run-r5s0`): Chat 22.4 % at 600 and 48.3 % at 6,000; the 300-line fence 37.6 %; terminal 5.1 / 20.7. S1+S2 are measured together with S3, after S3 lands.
- **Blocker:** the usage limit (paused, §1). The icon is picked (D-97). The tag, promote, push and GitHub release wait for `@user` ([D-16](DECISIONS.md), [D-83](DECISIONS.md)).

---

## 1. Current Operational Mode

- **Resume after the pause (24 Oct):**
  1. Read `~/Library/Caches/loom-v2/evidence/r5/RUN.md`'s last section and each `evidence/r5/<slice>/PAUSE.md` (settings, inspector, pill, chat-cost).
  2. Check the worktrees `wt/r5-<slice>` with `git status`; never stash or reset. Read the logs of the checks that ran during the pause.
  3. Resume each agent with SendMessage (ids in RUN.md). If one cannot be resumed, start a fresh `implementer` with its Brief plus PAUSE.md.
  4. Keep the build slot's queue short: at most three agents building at once.
  5. Then: review and integrate each step; build a C8 package from S3's commit and run the four Chat cells with `PROFILE=1`; decide S4; then the docs pass, the pool (D-90) and the closing review (D-06). Stop for `@user`'s word before tag, promote, install and push.
  6. `caffeinate` is stopped during the pause; start it again for window tests and C8 runs.
- **Planner (24 Oct):** the session that wrote [FEEDBACK-5](plans/FEEDBACK-5.md) plans round 5 with `@user`. Before it, the session "Sphyrna 1.6.0 release planlama" was `@planner` from 22 Oct 02:20 (`@user`'s word). The earlier planner session and the track sessions `sphyrna-ink` / `sphyrna-core` are idle; implementers run as the planner's own subagents and slices integrate straight onto `v2` (the `ink` and `core` track branches are not used).
- **Night window (22–23 Oct, `@user` at 23:41):** the Mac idle, on the adapter, the screen unlocked; the planner ran the screen work after the review's fixes (the full gate, `rc3`'s C8 cells and an A/B against `rc2`, the service smoke) without asking again. It ended at 01:10. Briefs tell implementers to avoid commands that ask for approval, and to wait on `evidence/tools/wait-measurements.sh` (a C8 run, or the `HOLD-BUILDS` file while `@user` uses the Mac) before any build.
- **Test cadence ([D-90](DECISIONS.md), [DEVELOPMENT.md §3.1](DEVELOPMENT.md#31-test-cadence-slices-one-pooled-batch-fixes-scoped-re-checks-d-90-22-oct-2026)):** narrow off-screen checks per slice; the pool runs when enough has collected; fixes get scoped re-checks.
- **Quota:** 5-hour window 7 % at 01:15 (resets 04:50), weekly 52 %.

---

## 2. Worktrees, Branches & HEAD Commits

| Role / Slice | Worktree Path | Branch | HEAD SHA | Working Tree Status |
| --- | --- | --- | --- | --- |
| Main repo (`loom-dev`) | `/Users/gencberke/Documents/github/loom-dev` | `swarm/1` | this board's commit | Planner docs |
| Round 5 slices | `wt/r5-settings`, `wt/r5-inspector`, `wt/r5-remora`, `wt/r5-drag`, `wt/r5-chat-cost`, `wt/r5-drafts`, `wt/r5-icon` (done), `wt/r5-pill` | `slice/r5-*` | `988256a` at start (`r5-pill`: `2202fc6`) | In progress; Briefs in `evidence/r5/<slice>/BRIEF.md`, shared rules in `evidence/r5/COMMON.md`; implementers commit on their branch, the planner cherry-picks onto `v2` |
| Integration branch | `~/Library/Caches/loom-v2/wt/v2` | `v2` | this board's commit (after `1b974c4`) | Clean; local only, never pushed |
| RC package | `wt/rc3-candidate` | detached | `1b974c4` | Clean; package `rc3-*` under `Loom-Dev/packages/` (`rc2-*` at `0461a54` kept for the A/B) |
| Fix slices (the review's) | `wt/fix-lifecycle`, `wt/fix-chat-fence`, `wt/fix-art`, `wt/fix-remora-review` | `slice/fix-*` | `cdaf588`, `140169c`, `a1db63f`, `6e6c884` | Clean; integrated by `cherry-pick -x`; kept until the release for follow-ups |
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

24. **The closing `@optimizer` review** (acceptance 6; four `strict-reviewer`s on Opus 5.5 `max` over `cc54a17..0461a54`, `evidence/optimizer-160/`, triage in `FINDINGS.md`): 3 Blocking — a terminal-face parent never retired its side chats (D-72 (1)); a Quit during the automatic brief gave the day's slot back (SPEC §10.2); the art kept its display link scrolled out of view (DESIGN §17) — and 9 Should-Fix.
25. **Fixes #3** on `v2`: `af3f246` (side chats stop with the parent's run on either face, read from the live states; a Stop during Resume is not a failure), `c41fe3e` (Chat's split reads fences by the parser's rules; only a message's newest head is cached), `5b13f09` (the art follows its scroll view, `visibleRect` within its bounds; About's crossing replays; a closing window, zero size and deinit stop the link), `1b974c4` (Remora: the slot is given back only before the spawn; Home asks once the host is in; the automatic brief waits after `notLoggedIn`; the sessions' account, by the plan-limits rule; Home shows only its own door's call; nothing read with Remora off; one narrow newest-activity query; the stream helper polls at 50 ms).
26. **Re-checks on `1b974c4`** (`evidence/optimizer-160/RECHECK-PLAN.md`): the full gate passes (`check-20261023T000452-81677.log`, 364 + 1,735 tests, 32 min); C8 on `rc3` (`BUDGETS-1b974c4.md`): Chat 22.9 % at 600 and 48.2 % at 6,000, peak 399–442 MiB; idle 0.07–0.10 %; 100 cycles leave nothing; the service smoke 12 of 12 (`r5/smoke-1b974c4`). An A/B against `rc2` in the same machine state (`BUDGETS-ab-0461a54.md`) shows that the higher Chat peak (447.5 MiB on `rc2`) and an occasional +28 MiB after 100 cycles (1 run in 3–4 on both packages) are not the fixes'.

27. **Logging** (`f891a92`, `@user`'s ask on 23 Oct, inside 1.6.0; [DEVELOPMENT §11](DEVELOPMENT.md#11-logs-and-diagnostics)):
    - five new categories: `Session`, `Chat`, `Remora`, `Deletion`, `Sidebar`;
    - every line about a session carries its `s:` ref;
    - runs log their start and their end (reason, exit code or signal);
    - `SessionService`, the Chat face, Remora and deletion log their outcomes and the errors `try?` used to swallow;
    - never content, kept by source guards in `LoggingAndJournalTests`.

    Retention: Sphyrna's own diagnostic files are kept 3 days (`DiagnosticRetention`). The export reads the last 72 h of the unified log and keeps its newest 5 MB. The unified log itself stays macOS's, capped by size, with no app time limit. Checks:
    - the touched suites: `check-20261023T091345-9945.log`, `…091908-11375.log`, `…094048-18912.log`, `…095159-22177.log`;
    - the suites that read the journal: `…170819-30026.log`;
    - the release tree: `…094738-21143.log`, `…171055-31070.log`.
28. **1.6.0 tagged, promoted and installed** (23 Oct, `@user`'s word): the 0.4.4 data backed up; `release/1.6.0` = `678d5ab`; the loom tree `9da0467` with `v1.6.0`, local; `/Applications/Loom.app` built by `build.sh` and its codesign checked (`evidence/release-1.6.0-build-2.log`). A first promote this evening ran from `swarm/1`, whose older `allowlist.sh` dropped LoomChat and LoomRemora (538 files instead of 618). It was caught before the build, undone, and promoted again from `v2`'s worktree ([DEVELOPMENT §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).

### Active File Locks
- **Round 5 (24 Oct):** each slice's write set is in its Brief.
  - `CatalogModel.swift` is shared by region: tabs (`r5-drag`), drafts' state (`r5-drafts`), and one inspector setter if unavoidable (`r5-inspector`). The planner resolves the cherry-picks.
  - `scripts/check.sh`: the `window_tests` list only (`r5-settings`).
  - `scripts/perf/chat_stream_*` and `loom-fake-provider/ChatStreamScenario.swift`: `r5-chat-cost`.
  - Evidence commands: `EvidenceTabCommands.swift` (`r5-drag`) and `EvidenceStudioCommands.swift` (`r5-drafts`).
- **`@planner`:** canonical docs.

---

## 4. Next Actions by Role (`@role` Handoff Queue)

- **`@user` (round 5):**
  - the power adapter, for the window tests and the C8 runs;
  - the icon pick when the strip arrives;
  - at the close, the word on the tag and the promote of 1.6.1.
- **`@planner` (round 5):**
  - review each slice's commits and cherry-pick them onto `v2`;
  - after S0, package and measure the C8 baseline (on AC power);
  - send each track its next step (ACTIVE-PLAN §0), and start `r5-pill` once `r5-drag`'s payload is on `v2`;
  - then the pool (D-90), the optimizer (D-06) and the docs.
- **`@implementer-ink` / `@implementer-core` (round 5):** the seven `r5-*` slices, from their Briefs.
- **`@user` (earlier):** the word on the push and the GitHub release (`git -C ~/Documents/github/loom push origin main v1.6.0`, then the zip and `gh release`, DEVELOPMENT §10). Feedback from use goes into slices after 1.6.0. Also open: the Remora account rule the planner chose (`FINDINGS.md`, Should-Fix 4), `O-09`, Remora's public-build default, the eye checks (the pool's by-hand list, and Home scrolled past the band with Animated art on), emptying `~/.Trash/loom-cleanup-20261022`, and the 35 old worktrees with uncommitted changes.
- **`@planner` (main session):** on `@user`'s word, the push and the release; the release notes get one line on a downgrade to 1.5.x (it drops Remora's settings, exclusions included). After 1.6.0: Chat's streaming cost, now FB5-10 in round 5; the review's deferred notes (`FINDINGS.md`), and the occasional +20 MiB after 100 cycles.
- **`@optimizer`:** done for 1.6.0 (22–23 Oct).
