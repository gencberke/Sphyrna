# Sphyrna 1.8.0: the plan

**Decision:** [D-105](../../DECISIONS.md) (27 Oct 2026). **Sources:** [FEEDBACK-7](../FEEDBACK-7.md), the 1.8.0 parts of
[FEEDBACK-6](../FEEDBACK-6.md) (FB6-7, FB6-8, FB6-13, FB6-14, FB6-16 part 2, FB6-22 part 2), and the leftovers listed in
[§5](#5-where-each-open-item-went).

## 1. The goal

1.8.0 is Sphyrna's first strong stop: an app fit for daily use. It is done when:
1. **Every harness is first-class.** Claude and Codex are equal: start from the draft with model, effort and mode, honest
   status, stop, resume, read, delete. opencode, agy and pi show in every list with their state, and start as plain terminal
   sessions (FEEDBACK-7 Q9).
2. **The look is Ink v4**, Orca's design system with Sphyrna's identity ([DESIGN-V4.md](DESIGN-V4.md)), on every surface, in
   Ink and Paper.
3. **Nothing known is broken:** the project drag reorders (FB7-3), Changes' comments reach a terminal session (F11), and the
   1.7.1 items that were never checked on screen are checked.
4. **Sessions work together:** `send` between sessions with `@user`'s approval, and Remora on any connected harness.
5. **The installed app passes the gate** in [§4](#4-the-release-gate).

What does not change: the contracts of SPEC §1–§5 and §12.
- The untouched CLI in an owned terminal; verified stop and deletion.
- Full access is never an agent's choice; `crossSessionInbound: refuse` stays.
- The user's harness profiles (`~/.claude`, `~/.codex`, opencode's, agy's and pi's folders) are never written by Sphyrna, except
  the one Claude retention key of SPEC §5.3.
- No model call the user did not cause, beyond the two of SPEC §12.2.
- Chat stays frozen (D-100); the bundle id and the data folder stay (D-83).

## 2. How the work runs

- **Who.** `@user` sets up each implementer (any provider) and starts it with one brief from [briefs/](briefs/). The planner
  (the main session) reviews every slice's diff and logs, integrates it onto `v2`, and keeps the docs. A slice is not accepted
  until the planner has reviewed it.
- **The brief.** Each brief is self-contained for a capable but not top-tier model: the goal, what to read, the write set, the
  approach, done-when, the checks and the report. Every brief also follows [COMMON.md](COMMON.md), which `@user` hands over with
  it.
- **Where.** One worktree and one branch per slice, cut from `v2`'s head when the slice starts:
  `~/Library/Caches/loom-v2/wt/r9-<id>` on `slice/r9-<id>` (COMMON §1).
- **Parallel slices.** Two slices may run at once only when the table below marks their write sets as disjoint. The build slot
  serializes their builds anyway (DEVELOPMENT §2).
- **Tests** follow D-90: narrow suites per slice; the pool runs once at the gate; a fix gets a scoped re-check.

## 3. The slices

### 3.1 Order

```
Wave 0  B0 reference v4 ──(@user approves the look)──┐      P0 Codex spike      P1 opencode/agy/pi spike
Wave 1  A1 project reorder        C1 harness catalogue │ B1 v4 tokens & controls    B0b the rest of the reference in v4
Wave 2  C2 catalogue consumers ──┬── B2 sidebar & card (after A1, B1)
                                  ├── C2b catalogue reaches every list (after C2)
                                  ├── C3 Connections & Home's connect cards (after B1, C1)
                                  └── B3 status bar (after B1, B2, C2)
Wave 3  C4 harness-neutral draft (after C2) ── B4 model & effort pickers (after B1, C4)
        D1 Codex sessions (after P0, C4) ── D2 Codex reader & deletion (after D1)
        B5a Home/project/draft · B5b session window & inspector · B5c Settings/sheets/palette/menus (after B1, B0b)
Wave 4  E1 opencode · E2 agy · E3 pi (after P1, C4, D1)    F1 send (after D1)    F2 Changes → session (after F1)
        G1 Remora backends (after P0, P1, C2, B4)    H1 usage completion (after C2, D2)    I1 names & leftovers
Wave 5  Z gate (planner): pool, real CLIs, energy, visual pass, optimizer, release
```

### 3.2 The table

| ID | Slice | Items | Area (write set in the brief) | After | Can run beside |
| --- | --- | --- | --- | --- | --- |
| **B0** | The reference in Ink v4: tokens, controls, sidebar and card, status bar, model panel, Connections, drawn in `reference.html` for `@user`'s approval (approved 27 Oct, D-106) | FB7-1, FB7-2 | `design/reference-src/**`, the built pages | — | P0, P1, A1, C1 |
| **P0** | Codex 0.164 spike: launch flags, the daemon and ownership, session-scoped hooks, the session id, resume, `delete`, `queue`, rollouts, title states, a no-tools one-shot | FB6-14, FB6-22 | evidence only | — | everything |
| **P1** | opencode, agy and pi spike: the same questions per CLI | FB6-13, Q9 | evidence only | — | everything |
| **A1** | The project reorder by a live drag gesture | FB7-3 | sidebar project list, `ProjectDrag`, `ProjectBlockDrop`, `DragActivity` | — | B0, C1, P0, P1 |
| **C1** | The harness catalogue: `HarnessID`, descriptors for five harnesses, availability, On/Off/Not found, the widened guard | FB6-13, optimizer 6 and 11 | `LoomCore` harness files, preferences, guard tests | — | B0, A1, B1 |
| **B1** | Ink v4 tokens and the control family | FB7-2 | `LoomTheme*.swift`, the shared control styles, DESIGN §0 and §3 | B0 approved, §0 written | C1, P0, P1 |
| **B0b** | The rest of the reference in v4: every other chapter redrawn with v4's parts; the v3 tokens, the v3/v4 switch and the Q bar removed; one design language in the reference and the landing page | D-106 | `design/reference-src/**`, the built pages | B0 integrated, the v4 rules in DESIGN.md | everything except B0 |
| **C2** | Everything that lists harnesses reads the catalogue: models with their efforts, probes, usage and limits, menus, palette, Home | FB6-13, FB6-3, optimizer 2, 4 and 10 | `LoomCore` model and usage files, `CatalogModel` (the harness region), menus | C1 | B2 |
| **C2b** | C2's rest: the catalogue on `CatalogModel` (no `ModelCatalog.shared`), availability wired, and every new-session list (File, Dock, Home, sidebar, menu bar) follows the catalogue, the switch and Not found | optimizer 10, C2's Done-when | `CatalogModel` (the catalogue and availability), the catalogue's readers (one line each), the list builders | C2 | B1 |
| **C3** | Settings → Connections and Home's connect cards in v4, with Not found | FB6-13 | Connections and Home's connect card files | B1, C1 | C2, B2 |
| **B2** | The sidebar and the session card in v4 | FB7-1, FB7-2 | sidebar files | A1, B1 | C2, C3 |
| **B3** | The status bar | Q7, FB6-3 | a new status bar view, the window layout, the footer's removal | B1, B2, C2 | C4, D1 |
| **C4** | The harness-neutral draft: `SessionDraft.harness`, `HarnessLaunchChoices`, modes per harness, presets and last-used migrated | FB6-7, FB6-8 | `LoomCore` draft and launch-choice files, `CatalogModel` (the draft region) | C2 | B3, B5a–c |
| **B4** | The model picker and the effort picker, two chips side by side (D-106) | FB6-7, FB6-8 | the two picker views, the chips that open them | B1, C4 | D1 |
| **D1** | Codex sessions: start and resume from the draft, status, ownership, the production gate opened | FB6-14 | Codex launch profile, hooks, `HarnessRegistry`, run host wiring | P0, C4 | B4, B5 |
| **D2** | Codex's rollout reader (last lines, search, context, edits, usage) and harness-owned deletion with `codex delete` | FB6-14, FB5-7 | `LoomCore` reader and deletion files | D1 | B5, E* |
| **B5a** | Home, the project page and the draft page in v4 | FB7-2 | those views | B1, B0b | C4, D1, D2 |
| **B5b** | The session window in v4: header, tabs, inspector (Overview, Changes, Agents in the turn style), ended line, banners, the open request's card | FB7-2, FB6-18 | those views | B1, B0b | C4, D1, D2 |
| **B5c** | Settings (not Connections), sheets, the palette, menus and About in v4 | FB7-2 | those views | B1, C3, B0b | C4, D1, D2 |
| **E1** | opencode sessions (plain terminal) | Q9 | its descriptor, launch profile, status source | P1, C4, D1 | E2, E3 |
| **E2** | agy sessions (plain terminal) | Q9 | as E1 | P1, C4, D1 | E1, E3 |
| **E3** | pi sessions (plain terminal) | Q9 | as E1 | P1, C4, D1 | E1, E2 |
| **F1** | `send` between sessions: approval, mailbox, the pointer on Ready, `inbox` | FB6-16 part 2, Q8 | the control socket, the CLI, the skill, a mailbox store, the approval card | D1 | G1, H1 |
| **F2** | Changes' comments to a terminal session through F1's delivery | F11 | Changes' send path | F1 | G1, H1 |
| **G1** | Remora on any harness with a verified no-tools run | FB6-22 part 2, Q9 of FEEDBACK-6 | `LoomRemora` backends, Remora's settings | P0, P1, C2, B4 | F1, H1 |
| **H1** | Usage completion: Claude's model-scoped weekly windows, the reset notification, Codex tokens by model and type | FB5-7 | usage index and Settings → Usage | C2, D2 | F1, G1 |
| **I1** | `Sphyrna.app` and its executable, after a migration check; the last "Loom" strings; a draft's title passed to Claude and Codex at start | FB6-17, FB6-16 part 1 leftover, Q12 | build scripts, Info.plist, launch profiles | D1 | E*, F*, G1, H1 |
| **Z** | The gate, the optimizer, the release | §4 | planner | all | — |

`CatalogModel.swift` is shared by A1, C2, C4, D1 and F1, each in its own region. Whichever lands second rebases, and the
planner resolves conflicts when cherry-picking.

## 4. The release gate

Run by the planner on the integrated head, once (D-90). `@user` gives the idle Mac for the screen parts.
1. **Off screen:** `scripts/check.sh --tests --release-tree`, then `--full --idle --windows`.
2. **Real CLIs**, each in `/private/tmp/loom-real/…` with its own data root:
   - **Claude:** a draft with Opus and medium; Stop; Resume; Delete.
   - **Codex:** the same; `send` from Claude to Codex and back, approved; Remora's brief on a Codex model.
   - **opencode, agy and pi:** start, status, stop (each one that shipped).
3. **Energy** (`scripts/perf/real_energy.py`, RESCUE-PLAN Phase B), in `@user`'s scenarios:
   - Home idle and a resting terminal stay at 0.0;
   - the status bar adds nothing at rest;
   - scrolling a working Claude terminal is no worse than Terminal.app with the same output;
   - FB6-11's cells, never run for 1.7.1, run here.
4. **Visual pass** against the approved v4 reference: every surface in Ink and Paper, Neutral and one cast, hover and focus held,
   VoiceOver over the sidebar, the status bar and the panel.
5. **Closing `@optimizer`** (D-06, FEEDBACK-7 Q11) over `release/1.7.2..head`; Blocking findings fixed and re-checked in scope.
6. **`@user`'s hand checks** on the installed build: the project drag; a day with Claude and Codex side by side; the panel;
   the status bar; send; Remora.
7. **Release:** release notes, the version, tag, promote and install on `@user`'s word; the push and the GitHub release on
   their word (D-16, D-83).

## 5. Where each open item went

| Item | Source | Goes to |
| --- | --- | --- |
| The model and effort panel; effort per model | FB6-7, FB6-8 | C2 (efforts), C4 (draft), B4 (panel) |
| The harness catalogue; Not found; opencode, agy, pi shown | FB6-13 | C1, C2, C3 |
| Codex sessions, reader, deletion | FB6-14 | P0, D1, D2 |
| `send` between sessions | FB6-16 part 2 | F1 |
| A draft's title passed to the CLI | FB6-16 part 1 (not built in 1.7.1) | I1 |
| Remora on other harnesses | FB6-22 part 2 | G1 |
| The footer per harness | FB6-3 | B3 (the status bar replaces it) |
| Changes' `Send to Claude` on a terminal session | FEATURES F11 | F2 |
| The optimizer's later items 2, 4, 6, 10, 11 (one probe outcome, one Claude limits source, per-harness facts and the wider guard, `ModelCatalog.shared` and `SidebarPeekStore.shared` onto `CatalogModel`, `cliVersion`) | `evidence/r6/optimizer/REPORT.md` | C1 (6, 11), C2 (2, 4, 10) |
| Usage: model-scoped weekly windows, reset notification, Codex tokens by type and model | FB5-7 | H1 |
| `Sphyrna.app` | FB6-17, D-103 Q4 | I1 |
| The 1.7.1 checks never run (window tests, real Claude, FB6-11's energy cells, FB6-9's Terminal.app table) | STATUS | Z |
| Chat cost S5, split view, the attention inbox, quick entry, sessions started outside Sphyrna | ACTIVE-PLAN's "Later" | Not in 1.8.0 (frozen or each with its own decision) |
