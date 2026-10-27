# Status (Live Relay Board)

- **Updated:** 2026-10-27, evening.
- **State:** `in progress`. 1.8.0's first wave is mostly in ([plans/1.8.0](plans/1.8.0/README.md)):
  - B0 (approved, [D-106](DECISIONS.md)), C1, A1 and B0b are integrated on `v2`; `--tests` passes on `v2` with A1;
  - C2 is integrated too; its rest runs as C2b (the brief's write set was too narrow for three of its Done-when items);
  - B1 and C2b are running as Haiku 5.5 implementers (max effort) in the planner's session, on `@user`'s word.
- **Installed:** Sphyrna 1.7.2 (build 10702) in `/Applications/Loom.app`. The CLIs on this Mac: Claude Code 2.1.311,
  Codex 0.164.0, opencode 2.1.4, agy 1.4.5, pi 0.85.1.
- **Public:** `0.4.4` is still the latest GitHub release. The tags `v1.6.0` to `v1.7.2` are local in the loom tree; their push
  and the GitHub release wait for `@user` (D-16, D-83).
- **The record before today:** [plans/archive/STATUS-to-1.7.2.md](plans/archive/STATUS-to-1.7.2.md).

## 1. Last round (27 Oct)

- **The implementers run in the planner's session** from now on (`@user`: Haiku 5.5 at max effort). Each gets its prompt
  file's text plus the safety rules the opencode config enforced (no push, switch, reset, stash or merge; builds only
  through `bgcheck.sh`; writes only in its worktree, evidence and build scratch).
- **A1 integrated** (`7c42ee5`..`fe4decd` as `d1c9069`..`075cd7d`, plus `689911b`): each project's head, drafts, cards and note are
  direct children of the lazy list again, each one part of the reorder (`SidebarPagingTests` passes: 100 rows, no extra
  pages); a released move keeps its gap until the new order lands, and a refused one slides back. `--tests` on `v2` with
  A1: PASS (365 XCTest, 1902 Swift Testing). Left for the gate: the drag by hand in the dev app, and whether the lifted head
  should drop into the gap instead of vanishing on release.
- **C2 integrated** (`94cb018`..`608266d`): one probe outcome (answered, failed with its reason, cached, not asked); Claude's
  limits derive from the probe's reading, nil included; `ModelCatalogEntry` carries harness, description, efforts (checked by
  shape) and default effort; the Peek store lives on `CatalogModel`. Its own `--tests` passed (365 + 1896). Its Needs: the seven
  readers of `ModelCatalog.shared`, the new-session lists and availability were outside its write set, so the planner wrote
  C2b; the usage chip's harness names go to B3 (noted in its brief); `SettingsConnectionsModel` stays C3's.
- **B0b integrated** (23 commits to `e17c499`, then `23ee04b` for DESIGN §1): the reference is Ink v4 only, in eleven
  chapters; every window draws the one v4 sidebar and status bar (`shared/side4.*`); no art (D-102); menus, sheets and the
  palette are back as the v4 chapter's section 03 (B5c needs them); the build is reproducible (gzip time 0); 375 KB.
  The planner's answers to run 1's questions are in its `PROGRESS.md`; the planner fixed three things on review.

- **B0 approved** on the rendered reference ([D-106](DECISIONS.md)):
  - Q1–Q6 take their defaults;
  - Ink tertiary becomes `#8F8F8F` and Paper faint `#9C9C9C`;
  - Activity cards carry the harness mark;
  - the model and the effort become two pickers, drawn by the planner in chapter 06;
  - a new slice, B0b, redraws the rest of the reference in v4.

  The planner's edits are committed as `5ba94f1`. B0 is integrated on `v2`.
- **C1 integrated** (`adcff47`..`59e300e`): the catalogue and availability are sound, and `--tests` passes. The planner's
  fix: opencode has no doctor until P1, because `opencode debug config` prints the whole config, credentials included.
- **A1 sent back** after review:
  - The drag model, the gap geometry and the single `moveProject` are sound.
  - **The regression:** each project's rows are now one plain stack inside the lazy list, so an expanded project builds every
    row and reads every page. With 350 sessions it reads 350 rows and 3 more pages, where `v2` reads 100 rows and no more
    pages. The planner's `SidebarPagingTests` proves it, failing on A1 and passing on `v2`.
  - **To fix as well:** the release jump. The blocks slide back before the saved order arrives.
  - **Flaky tests:** A1's full runs met two load-timing flakes, `HookWatchdogTests` and `ConversationControllerTests`.
- **loom-dev mirror:** `design/` was stale (22 Oct). It is synced from `v2`, and so are `SPEC.md` and `ARCHITECTURE.md`.
- **The runs** went through `@user`'s own opencode TUI on the background service, with its `build` agent and without the tools'
  deny rules. A check found nothing outside the slice worktrees touched.

- **Round 7 recorded:** [plans/FEEDBACK-7.md](plans/FEEDBACK-7.md): the card (FB7-1), Orca's design system (FB7-2), the project
  drag (FB7-3), 1.8.0 as one release (D-105), the logic read of Orca and T3 Code for the features 1.8.0 touches
  ([docs/FEATURES.md](docs/FEATURES.md) F1, F3, F5, F13–F17).
- **1.8.0 planned:** the plan, the shared rules, the v4 design proposal and 21 brief files for 25 slices in [plans/1.8.0/](plans/1.8.0/README.md).
  ACTIVE-PLAN and this board were rewritten; their old contents are in `plans/archive/`.
- **The implementer setup** in `~/Library/Caches/loom-v2/evidence/r9/tools/` (its `README.md`):
  - an opencode agent `sphyrna-impl` on DeepSeek V4.1 Flash Free at max, with deny rules tested in a real run;
  - `prep-slice.sh` (worktree, `PROGRESS.md`, a prompt file in `~/Desktop/sphyrna-1.8.0-prompts/`) and `tui.sh` (the TUI in the worktree);
  - `status.sh` to watch, `handoff.sh` to resume with any implementer, and `bgcheck.sh` / `waitcheck.sh` for long checks.

  Each slice carries its state in `evidence/r9/<id>/PROGRESS.md` and its branch's commits.
- **Worktrees cleaned up** on `@user`'s word:
  - 50 worktrees removed;
  - each one's uncommitted changes saved first in `~/Library/Caches/loom-v2/evidence/cleanup-20261027/` (`MANIFEST.md`, one patch and one tarball per worktree);
  - the sampled lines of every Release A–C worktree were already in `v2`;
  - every branch is kept.

## 2. Worktrees and branches

| Worktree | Branch | HEAD | State |
| --- | --- | --- | --- |
| `~/Documents/github/loom-dev` | `swarm/1` | `cd6afa4` | Docs mirror; the docs since 1.6.0 are uncommitted here and committed on `v2` |
| `~/Library/Caches/loom-v2/wt/v2` | `v2` | the STATUS commit after `23ee04b` | Integration branch: B0, C1, A1 and B0b integrated, then the planner's docs ("D-106 …"), so slice worktrees cut from `v2` carry the plan and the briefs. `Package.resolved` modified by a SwiftPM resolve (not part of any release) |
| `~/Library/Caches/loom-v2/wt/core` | `core` | `e3941fb` | Kept: `build-c8.sh` adds measurement worktrees from it |
| `~/Library/Caches/loom-v2/wt/r9-b0` | `slice/r9-b0` | `5ba94f1` | Integrated (fast-forward) |
| `~/Library/Caches/loom-v2/wt/r9-c1` | `slice/r9-c1` | `ad4f128` | Integrated (cherry-picked as `adcff47`..`59e300e`) |
| `~/Library/Caches/loom-v2/wt/r9-a1` | `slice/r9-a1` | `fe4decd` | Integrated (cherry-picked to `075cd7d`) |
| `~/Library/Caches/loom-v2/wt/r9-b0b` | `slice/r9-b0b` | `e17c499` | Integrated (cherry-picked) |
| `~/Library/Caches/loom-v2/wt/r9-b1` | `slice/r9-b1` | — | Running |
| `~/Library/Caches/loom-v2/wt/r9-c2` | `slice/r9-c2` | `94fdb47` | Integrated (cherry-picked to `608266d`) |
| `~/Library/Caches/loom-v2/wt/r9-c2b` | `slice/r9-c2b` | — | Running (cut from `71e7679`) |
| Later 1.8.0 slices | `slice/r9-<id>` | — | Prepared when their turn comes, from the `v2` of that moment |

Build scratch folders of removed worktrees remain in `~/Library/Caches/loom-v2/build/` (`r6-v2*`, `r7`, `r7cand2`, `r7check`).

## 3. File locks

- **`@planner`:** canonical docs (`AGENTS.md`, `STATUS.md`, `DECISIONS.md`, `plans/`).
- **1.8.0:** each brief's write set. Shared by region: `CatalogModel.swift` (A1, C2, C4, D1, F1); `SidebarView.swift` (A1, B2,
  B3); Settings files (C3, B5c, G1). `Package.swift` belongs to I1 alone.

## 4. Next actions by role

- **`@user`:**
  1. Answer FEEDBACK-7's [open questions](plans/FEEDBACK-7.md#decisions-open) Q7–Q13. Q13 is needed before P0 and P1, which
     also need the isolated profiles signed in.
  2. Still open from before: the push of `v1.6.0`–`v1.7.2` and the GitHub release. The Trash folders of 22, 25 and 26 Oct
     are `@user`'s to empty.
- **`@planner`:**
  1. Review each slice as it comes back, and integrate it.
  2. Keep the slice table in ACTIVE-PLAN current.
- **Implementers:** B1 and C2b running in the planner's session. Each takes its assignment from its prompt, its brief and
  COMMON.md.
- **`@optimizer`:** at the 1.8.0 gate (plans/1.8.0/README.md §4).
