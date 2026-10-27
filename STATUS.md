# Status (Live Relay Board)

- **Updated:** 2026-10-27, evening.
- **State:** `in progress`. 1.8.0's first wave has run ([plans/1.8.0](plans/1.8.0/README.md)):
  - B0 (approved, [D-106](DECISIONS.md)) and C1 are integrated on `v2`;
  - A1 was sent back by review: it breaks the sidebar's lazy paging. Its resume prompt is ready.

  The v4 rules are in `design/DESIGN.md` (its six rules and §0). B1, B0b and C2 can start.
- **Installed:** Sphyrna 1.7.2 (build 10702) in `/Applications/Loom.app`. The CLIs on this Mac: Claude Code 2.1.311,
  Codex 0.164.0, opencode 2.1.4, agy 1.4.5, pi 0.85.1.
- **Public:** `0.4.4` is still the latest GitHub release. The tags `v1.6.0` to `v1.7.2` are local in the loom tree; their push
  and the GitHub release wait for `@user` (D-16, D-83).
- **The record before today:** [plans/archive/STATUS-to-1.7.2.md](plans/archive/STATUS-to-1.7.2.md).

## 1. Last round (27 Oct)

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
| `~/Library/Caches/loom-v2/wt/v2` | `v2` | the docs commit after `59e300e` | Integration branch: B0 and C1 integrated, then the planner's docs ("D-106 …"), so slice worktrees cut from `v2` carry the plan and the briefs. `Package.resolved` modified by a SwiftPM resolve (not part of any release) |
| `~/Library/Caches/loom-v2/wt/core` | `core` | `e3941fb` | Kept: `build-c8.sh` adds measurement worktrees from it |
| `~/Library/Caches/loom-v2/wt/r9-b0` | `slice/r9-b0` | `5ba94f1` | Integrated (fast-forward) |
| `~/Library/Caches/loom-v2/wt/r9-c1` | `slice/r9-c1` | `ad4f128` | Integrated (cherry-picked as `adcff47`..`59e300e`) |
| `~/Library/Caches/loom-v2/wt/r9-a1` | `slice/r9-a1` | `824f0c3` | Sent back: its resume prompt is `~/Desktop/sphyrna-1.8.0-prompts/A1-resume-1027-2047.md` |
| Later 1.8.0 slices | `slice/r9-<id>` | — | Prepared when their turn comes, from the `v2` of that moment |

Build scratch folders of removed worktrees remain in `~/Library/Caches/loom-v2/build/` (`r6-v2*`, `r7`, `r7cand2`, `r7check`).

## 3. File locks

- **`@planner`:** canonical docs (`AGENTS.md`, `STATUS.md`, `DECISIONS.md`, `plans/`).
- **1.8.0:** each brief's write set. Shared by region: `CatalogModel.swift` (A1, C2, C4, D1, F1); `SidebarView.swift` (A1, B2,
  B3); Settings files (C3, B5c, G1). `Package.swift` belongs to I1 alone.

## 4. Next actions by role

- **`@user`:**
  1. Start B1, B0b and C2 (prepared), and resume A1 with its new prompt. All four can run side by side.
  2. Answer FEEDBACK-7's [open questions](plans/FEEDBACK-7.md#decisions-open) Q7–Q13. Q13 is needed before P0 and P1, which
     also need the isolated profiles signed in.
  3. Still open from before: the push of `v1.6.0`–`v1.7.2` and the GitHub release. The Trash folders of 22, 25 and 26 Oct
     are `@user`'s to empty.
- **`@planner`:**
  1. Review each slice as it comes back, and integrate it.
  2. Keep the slice table in ACTIVE-PLAN current.
- **Implementers:** none running. Each takes its assignment from its prompt file, its brief and COMMON.md.
- **`@optimizer`:** at the 1.8.0 gate (plans/1.8.0/README.md §4).
