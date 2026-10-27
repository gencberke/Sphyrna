# Status (archived): 1.6.0 to 1.7.2

> **Archived 27 Oct 2026** ([D-105](../../DECISIONS.md)): the relay board as it stood from 1.6.0 to 1.7.2 and the
> 27 Oct reference round, kept so the live board can stay short (AGENTS §4). The live board is [STATUS.md](../../STATUS.md).


- **Updated:** 2026-10-27 (just after midnight)
- **Now (27 Oct): Orca and T3 Code are the final references; docs only** ([D-104](../../DECISIONS.md)). `waiting for planning`.
  - **What was done:** the feature map is written: [`docs/FEATURES.md`](../../docs/FEATURES.md) lists Sphyrna's 22 main features, one heading each, with an empty Orca / T3 Code / verdict slot for each. D-104 is recorded, and AGENTS.md, DESIGN.md and ACTIVE-PLAN §0.1 point to it. No code changed.
  - **The references:** both apps are installed (`/Applications/Orca.app` 1.4.241, `/Applications/T3 Code (Nightly).app` 0.1.3-nightly.20261027), and their sources are in `~/Documents/github/orca` and `~/Documents/github/t3code`.
  - **One gap found while writing it:** Changes' `Send to Claude` needs the Chat face, so it cannot reach a terminal session since D-100 (FEATURES F11).
  - **Cleanup on `@user`'s word (26–27 Oct):** 46 old Claude sessions of `loom-dev` and `loom` (about 4.3 GB: transcripts, `file-history`, `session-env`) were moved to the Trash; this session and the project's `memory/` stayed. Neither catalog (Loom, Loom-Dev) referenced them. 18 Claude Desktop sessions in `loom-dev` were archived. Sphyrna's install and data were not touched (`@user` withdrew the uninstall). The Trash is `@user`'s to empty.
- **Before (26 Oct, about 23:35): Sphyrna 1.7.2 is installed, a fix to 1.7.1** ([`plans/release-notes/RELEASE-NOTES-1.7.2.md`](../release-notes/RELEASE-NOTES-1.7.2.md)). `@user`'s first project drag in the installed 1.7.1 locked the window: 1.7.1 declared the in-app drag types as `public.data`, AppKit made the drag a file promise, `NSFilePromiseReceiver` raised (`NSFilePromiseReceiver.m:300`), AppKit cancelled the drag and clicks stopped answering. The planner sampled the app (main thread idle), read the exception in the log, quit the app (no live session), removed the declarations (`7be8c69` = `release/1.7.2`, cherry-picked onto `v2`), and on `@user`'s word promoted it (loom `903adaf`, tag `v1.7.2`, 658 files) and installed build 10702; `codesign --verify --deep --strict` passes, the Info.plist declares no drag types, and LaunchServices holds no registration of them. Backup before it: `~/Library/Application Support/Loom-backup-1.7.1-20261026T232514`. `@user` after 1.7.2: "okydir". **1.8.0 is parked** ("1.8.0 planan işleri bekleyebilir"; ACTIVE-PLAN §0.1 Next). **Still open for `@user`:** the rest of 1.7.1's hand checks below, an idle Mac for the real-Claude checks and the energy cells, and the push of `v1.7.0` to `v1.7.2`.
- **Before that (26 Oct, about 23:30): Sphyrna 1.7.1, round 6, is tagged, promoted and installed** ([`plans/FEEDBACK-6.md`](../../plans/FEEDBACK-6.md), [D-103](../../DECISIONS.md), [`plans/release-notes/RELEASE-NOTES-1.7.1.md`](../release-notes/RELEASE-NOTES-1.7.1.md)). `@user`'s word: "1.7.1'i v2'ye al, versiyonu bump et, tag/promote edip /Applications'a kur. El kontrollerini kurulu uygulamada yapacağım."
  - **Where it is:** the slices ran in a separate implementer session (Sonnet, high) on `slice/r8-171` in `wt/r8`; the planner reviewed them, fixed Quit's count of background work (`a809fec`), sent 13 failing tests back, and `v2` was fast-forwarded to `ce03df4` = `release/1.7.1`. Promoted as the loom tree's `9dbad0e` (tag `v1.7.1`, 658 files, local, unpushed). Installed in `/Applications/Loom.app` as build 10701; `codesign --verify --deep --strict` passes; both drag types are declared in its Info.plist (`evidence/r8/install-171.log`). The data before it is in `~/Library/Application Support/Loom-backup-1.7.0-20261026T231330`.
  - **Checks behind it:** `check.sh --tests --release-tree` on `e4d8005` passes: 1,893 + 989 + 365 + 197 + 63 + 8 tests (one known issue, `droppedDirtyRowIsDetected`), the lints and the release-tree build (`check-20261026T224751-67609.log`). **Not run:** the window tests, a real Claude session in 1.7.1 (S5's opened session, S8's Turkish brief), the energy cells of FB6-11, the table check in Terminal.app.
  - **Not built from the plan:** a draft's title passed to Claude (FEEDBACK-6 FB6-16; ids already match). The implementer's narrow checks missed 13 test failures that the full run found; the next round's brief asks for the full off-screen run before the report.
  - **Waiting for `@user`:** the hand checks on the installed 1.7.1 (real drags and a cancelled one, the sidebar's fill and opacity, the open request's card, full-screen Home, the footer's harness lines); an idle Mac for the real-Claude checks and the energy cells; the push of `v1.7.0` and `v1.7.1` and the GitHub releases; Claude Code 2.1.308 (`brew upgrade claude-code@latest`, H3).
  - **Health check (26 Oct):** no crash and no error in the log; both sessions' hooks answered in 10 to 41 ms; the ~25 short runs a day are the Codex probe; Activity Monitor lists Claude Code's energy under LoomRunHost because `claude` is its child. Details in FEEDBACK-6 "Health check".
- **Before (26 Oct, about 03:30):** the state below.
- **Now (26 Oct, about 03:30): Sphyrna 1.7.0, the rescue, is tagged, promoted and installed** ([`plans/archive/RESCUE-PLAN.md`](RESCUE-PLAN.md) §5, [D-100](../../DECISIONS.md) to [D-102](../../DECISIONS.md)). `@user`'s word on 25 Oct night: "bunları bu gece yapıyoruz … bu akşam implementasyon bitmiş ve minör version bump'ı almış olalım".
  - **Where it is:**
    - `release/1.7.0` is `v2` `b69a24c` (the slices ran on `slice/r7-rescue` in `wt/r7`, fast-forwarded onto `v2`), promoted as the loom tree's `3958797` (tag `v1.7.0`, 653 files, local, unpushed).
    - It is installed in `/Applications/Loom.app` as build 10700, signed, and `codesign --verify --deep --strict` passes (`evidence/r7/install-170.log`). 1.6.2's data is backed up in `~/Library/Application Support/Loom-backup-1.6.2-20261026T025410`, and the data before the cleanup in `Loom-backup-before-r7-20261025T235812`.
    - **Measured installed, with the real profile** (app and its children, `evidence/r7/real-app-170.json`): launch 0.2 (max 6.8), Home at rest 0.0, after re-activation 0.0; 1.6.2 read 1.8 (max 35.5), 1.0 and 1.3. The planner launched it once for this and quit it; the stored Glass sidebar now reads Transparent.
    - `v2`'s working tree has one uncommitted change, `Package.resolved` (swift-png 4.5.1 → 4.5.2, written by a SwiftPM resolve during the checks). The release used the committed pin.
  - **What 1.7.0 is** (ACTIVE-PLAN §0.1, `plans/release-notes/RELEASE-NOTES-1.7.0.md`):
    - every Claude session in its terminal, with the Chat face frozen;
    - full model names, and quiet readers of unknown records;
    - no art (Remora stays);
    - Settings → Sessions → Storage, Claude's retention with consent, and usage per session;
    - the sidebar from `@user`'s notes;
    - the menu bar's working mark standing still.
  - **Checks behind it:**
    - each slice's narrow suites;
    - `check.sh --release-tree --tests` on `d8b6352` (`check-20261026T022633-5571.log`): release tree, 984 + 1,875 + 365 + 195 + 57 + 8 tests. One failure, the capability guard (D-94) on `SidebarCardModels`, was fixed in `b69a24c` and re-checked in scope;
    - Phase B's energy cells, `sample`s and screenshots (RESCUE-PLAN §5).
    - **Not run:** the window tests of the full gate, C8, and a real Claude session in 1.7.0.
  - **The cleanup (25 Oct, 23:58):** Sphyrna's 15 sessions are out of the catalog; their Claude files (336 MB) are in `~/.Trash/sphyrna-sessions-20261025` with a `RESTORE.md`. Emptying the Trash is `@user`'s.
  - **Open (RESCUE-PLAN §5):** WindowServer at about 8 while Sphyrna is in front and a session works; the customized pointer's redraw cost; the 118 not reproduced; C4 (status truth).
  - **Waiting for `@user`:**
    - the hand checks on the installed 1.7.0: the sidebar's look (Transparent at 0.8 is unverified on screen), the cards, project drag, Storage and retention, the Overview's Usage;
    - the push (`git -C ~/Documents/github/loom push origin main v1.7.0`, with `v1.6.1` and `v1.6.2` if wanted) and the GitHub release (DEVELOPMENT §10);
    - a macOS prompt on screen since about 01:13, "Claude is requesting to bypass the system private window picker…", raised by the planner's `screencapture`. The planner did not answer it.
  - `0.4.4` remains the latest public GitHub release ([gencberke/loom](https://github.com/gencberke/loom), [D-56](../../DECISIONS.md)).
- **Blocker:** none. The push and the GitHub release wait for `@user` ([D-16](../../DECISIONS.md), [D-83](../../DECISIONS.md)).

---

## 1. Current Operational Mode

- **Next (26 Oct):**
  1. `@user`'s hand checks on the installed 1.7.0.
  2. On `@user`'s word, the push and the GitHub release.
  3. Then RESCUE-PLAN's open items with `@user`: C4 (status truth) and the energy items of §5. Chat stays frozen (D-100).
- **Planner (24 Oct):** the session that wrote [FEEDBACK-5](FEEDBACK-5.md) plans round 5 with `@user`. Before it, the session "Sphyrna 1.6.0 release planlama" was `@planner` from 22 Oct 02:20 (`@user`'s word). The earlier planner session and the track sessions `sphyrna-ink` / `sphyrna-core` are idle; implementers run as the planner's own subagents and slices integrate straight onto `v2` (the `ink` and `core` track branches are not used).
- **Night window (22–23 Oct, `@user` at 23:41):** the Mac idle, on the adapter, the screen unlocked; the planner ran the screen work after the review's fixes (the full gate, `rc3`'s C8 cells and an A/B against `rc2`, the service smoke) without asking again. It ended at 01:10. Briefs tell implementers to avoid commands that ask for approval, and to wait on `evidence/tools/wait-measurements.sh` (a C8 run, or the `HOLD-BUILDS` file while `@user` uses the Mac) before any build.
- **Test cadence ([D-90](../../DECISIONS.md), [DEVELOPMENT.md §3.1](../../DEVELOPMENT.md#31-test-cadence-slices-one-pooled-batch-fixes-scoped-re-checks-d-90-22-oct-2026)):** narrow off-screen checks per slice; the pool runs when enough has collected; fixes get scoped re-checks.
- **Quota:** 5-hour window 7 % at 01:15 (resets 04:50), weekly 52 %.

---

## 2. Worktrees, Branches & HEAD Commits

| Role / Slice | Worktree Path | Branch | HEAD SHA | Working Tree Status |
| --- | --- | --- | --- | --- |
| Main repo (`loom-dev`) | `/Users/gencberke/Documents/github/loom-dev` | `swarm/1` | this board's commit | Planner docs |
| Round 5 and 6 slices | worktrees removed (25 Oct, clean and integrated) | `slice/r5-*`, `slice/r6-*` | the slices' last commits | Branches kept; Briefs and logs in `evidence/r5/` and `evidence/r6/`; their build scratch removed (25 Oct, `@user`) |
| Integration branch | `~/Library/Caches/loom-v2/wt/v2` | `v2` | this board's commit (after `b69a24c`, tag `release/1.7.0`) | `Package.resolved` modified by a resolve (above); local only, never pushed; scratch `build/r6-v2` |
| The rescue | `~/Library/Caches/loom-v2/wt/r7` | `slice/r7-rescue` | same as `v2` | Clean; tools and logs in `evidence/r7/`; measurement packages `r7base`, `r7cand`, `r7cand2`..`4`, `r7exp` in `Loom-Dev/packages/` |
| C8 packages | worktrees `wt/*-candidate` and packages `r5*`, `rc2`, `rc3` removed (25 Oct, `@user`: "bütün gereksiz cache'leri temizle") | — | — | `build-c8.sh <sha>` rebuilds one; `Loom-Dev/packages/v2-base-044-reference` kept |
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
22. **[D-92](../../DECISIONS.md)** (`@user`, 22:50): 1.6.0's budgets from C8, `O-01` resolved; Chat's parity after 1.6.0 ([ACTIVE-PLAN §5](ACTIVE-PLAN-1.6.0-to-1.7.2.md#5-post-160-roadmap-items) item 4).
23. **Cleanup** (`@user`'s word, `evidence/cleanup-20261022.md`): 23 build scratches and 40 old packages (22 GB) moved to `~/.Trash/loom-cleanup-20261022`; 36 clean worktrees removed (their commits stay in git); `build/v2`, `build/c8`, the `rc2` package, the 0.4.4 reference package, the evidence and every branch kept.

24. **The closing `@optimizer` review** (acceptance 6; four `strict-reviewer`s on Opus 5.5 `max` over `cc54a17..0461a54`, `evidence/optimizer-160/`, triage in `FINDINGS.md`): 3 Blocking — a terminal-face parent never retired its side chats (D-72 (1)); a Quit during the automatic brief gave the day's slot back (SPEC §10.2); the art kept its display link scrolled out of view (DESIGN §17) — and 9 Should-Fix.
25. **Fixes #3** on `v2`: `af3f246` (side chats stop with the parent's run on either face, read from the live states; a Stop during Resume is not a failure), `c41fe3e` (Chat's split reads fences by the parser's rules; only a message's newest head is cached), `5b13f09` (the art follows its scroll view, `visibleRect` within its bounds; About's crossing replays; a closing window, zero size and deinit stop the link), `1b974c4` (Remora: the slot is given back only before the spawn; Home asks once the host is in; the automatic brief waits after `notLoggedIn`; the sessions' account, by the plan-limits rule; Home shows only its own door's call; nothing read with Remora off; one narrow newest-activity query; the stream helper polls at 50 ms).
26. **Re-checks on `1b974c4`** (`evidence/optimizer-160/RECHECK-PLAN.md`): the full gate passes (`check-20261023T000452-81677.log`, 364 + 1,735 tests, 32 min); C8 on `rc3` (`BUDGETS-1b974c4.md`): Chat 22.9 % at 600 and 48.2 % at 6,000, peak 399–442 MiB; idle 0.07–0.10 %; 100 cycles leave nothing; the service smoke 12 of 12 (`r5/smoke-1b974c4`). An A/B against `rc2` in the same machine state (`BUDGETS-ab-0461a54.md`) shows that the higher Chat peak (447.5 MiB on `rc2`) and an occasional +28 MiB after 100 cycles (1 run in 3–4 on both packages) are not the fixes'.

27. **Logging** (`f891a92`, `@user`'s ask on 23 Oct, inside 1.6.0; [DEVELOPMENT §11](../../DEVELOPMENT.md#11-logs-and-diagnostics)):
    - five new categories: `Session`, `Chat`, `Remora`, `Deletion`, `Sidebar`;
    - every line about a session carries its `s:` ref;
    - runs log their start and their end (reason, exit code or signal);
    - `SessionService`, the Chat face, Remora and deletion log their outcomes and the errors `try?` used to swallow;
    - never content, kept by source guards in `LoggingAndJournalTests`.

    Retention: Sphyrna's own diagnostic files are kept 3 days (`DiagnosticRetention`). The export reads the last 72 h of the unified log and keeps its newest 5 MB. The unified log itself stays macOS's, capped by size, with no app time limit. Checks:
    - the touched suites: `check-20261023T091345-9945.log`, `…091908-11375.log`, `…094048-18912.log`, `…095159-22177.log`;
    - the suites that read the journal: `…170819-30026.log`;
    - the release tree: `…094738-21143.log`, `…171055-31070.log`.
28. **1.6.0 tagged, promoted and installed** (23 Oct, `@user`'s word): the 0.4.4 data backed up; `release/1.6.0` = `678d5ab`; the loom tree `9da0467` with `v1.6.0`, local; `/Applications/Loom.app` built by `build.sh` and its codesign checked (`evidence/release-1.6.0-build-2.log`). A first promote this evening ran from `swarm/1`, whose older `allowlist.sh` dropped LoomChat and LoomRemora (538 files instead of 618). It was caught before the build, undone, and promoted again from `v2`'s worktree ([DEVELOPMENT §10](../../DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).

### Active File Locks
- **Round 5 (24 Oct):** each slice's write set is in its Brief.
  - `CatalogModel.swift` is shared by region: tabs (`r5-drag`), drafts' state (`r5-drafts`), and one inspector setter if unavoidable (`r5-inspector`). The planner resolves the cherry-picks.
  - `scripts/check.sh`: the `window_tests` list only (`r5-settings`).
  - `scripts/perf/chat_stream_*` and `loom-fake-provider/ChatStreamScenario.swift`: `r5-chat-cost`.
  - Evidence commands: `EvidenceTabCommands.swift` (`r5-drag`) and `EvidenceStudioCommands.swift` (`r5-drafts`).
- **`@planner`:** canonical docs.

---

## 4. Next Actions by Role (`@role` Handoff Queue)

- **`@planner` (from 27 Oct, [D-104](../../DECISIONS.md)):** plan the reference round with `@user`. Read each feature of [`docs/FEATURES.md`](../../docs/FEATURES.md) in Orca and T3 Code (source and installed app), logic first. Fill its slots, and bring every verdict that changes what the user sees or a contract to `@user` as a decision before a slice. F11's `Send to Claude` gap is a likely first item. The older queue below stays as it was.
- **`@user` (after round 6):**
  - the hand checks on the installed 1.6.2 (ACTIVE-PLAN §0.1);
  - the word on the push and the GitHub release: `git -C ~/Documents/github/loom push origin main v1.6.2` (and `v1.6.1`), then the zip and `gh release` with `plans/release-notes/RELEASE-NOTES-1.6.2.md` (DEVELOPMENT §10);
  - the next round's scope (ACTIVE-PLAN §0.1 "Next").
  - **Still open from before:**
    - the Remora account rule (`FINDINGS.md`, Should-Fix 4), `O-09`, and Remora's public-build default;
    - the 35 old worktrees with uncommitted changes.
- **`@planner`:**
  - on `@user`'s word, the push and the release;
  - then plan the next round with `@user` from ACTIVE-PLAN §0.1:
    - the `@optimizer`'s later items (`evidence/r6/optimizer/REPORT.md` 2, 4, 6, 10, 11);
    - the rest of FB5-7;
    - Chat S5 (Q17);
    - the reference pages;
    - 1.7.0.
- **`@implementer-*`:** idle; the next slices come from the next round's Briefs.
- **`@optimizer`:** done for 1.6.1 and 1.6.2 (25 Oct, `evidence/r6/optimizer/REPORT.md`).
