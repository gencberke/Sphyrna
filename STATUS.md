# Status (Live Relay Board)

- **Updated:** 2026-10-27, afternoon.
- **State:** `waiting for user decision`. 1.8.0 is planned ([D-105](DECISIONS.md),
  [plans/1.8.0](plans/1.8.0/README.md)); nothing is built. `@user` starts the implementers.
- **Installed:** Sphyrna 1.7.2 (build 10702) in `/Applications/Loom.app`. The CLIs on this Mac: Claude Code 2.1.311,
  Codex 0.164.0, opencode 2.1.4, agy 1.4.5, pi 0.85.1.
- **Public:** `0.4.4` is still the latest GitHub release. The tags `v1.6.0` to `v1.7.2` are local in the loom tree; their push
  and the GitHub release wait for `@user` (D-16, D-83).
- **The record before today:** [plans/archive/STATUS-to-1.7.2.md](plans/archive/STATUS-to-1.7.2.md).

## 1. Last round (27 Oct)

- **Round 7 recorded:** [plans/FEEDBACK-7.md](plans/FEEDBACK-7.md): the card (FB7-1), Orca's design system (FB7-2), the project
  drag (FB7-3), 1.8.0 as one release (D-105), the logic read of Orca and T3 Code for the features 1.8.0 touches
  ([docs/FEATURES.md](docs/FEATURES.md) F1, F3, F5, F13–F17).
- **1.8.0 planned:** the plan, the shared rules, the v4 design proposal and 21 brief files for 25 slices in [plans/1.8.0/](plans/1.8.0/README.md).
  ACTIVE-PLAN and this board were rewritten; their old contents are in `plans/archive/`.
- **Worktrees cleaned up** on `@user`'s word:
  - 50 worktrees removed;
  - each one's uncommitted changes saved first in `~/Library/Caches/loom-v2/evidence/cleanup-20261027/` (`MANIFEST.md`, one patch and one tarball per worktree);
  - the sampled lines of every Release A–C worktree were already in `v2`;
  - every branch is kept.

## 2. Worktrees and branches

| Worktree | Branch | HEAD | State |
| --- | --- | --- | --- |
| `~/Documents/github/loom-dev` | `swarm/1` | `cd6afa4` | Docs mirror; the docs since 1.6.0 are uncommitted here and committed on `v2` |
| `~/Library/Caches/loom-v2/wt/v2` | `v2` | `fe72ee2` | Integration branch; `Package.resolved` modified by a SwiftPM resolve (not part of any release); round 7's docs committed here ("D-105: 1.8.0 as one release …"), so slice worktrees cut from `v2` carry the plan and the briefs |
| `~/Library/Caches/loom-v2/wt/core` | `core` | `e3941fb` | Kept: `build-c8.sh` adds measurement worktrees from it |
| 1.8.0 slices | `slice/r9-<id>` | — | Created by each implementer from `v2` (plans/1.8.0/COMMON.md §1) |

Build scratch folders of removed worktrees remain in `~/Library/Caches/loom-v2/build/` (`r6-v2*`, `r7`, `r7cand2`, `r7check`).

## 3. File locks

- **`@planner`:** canonical docs (`AGENTS.md`, `STATUS.md`, `DECISIONS.md`, `plans/`).
- **1.8.0:** each brief's write set. Shared by region: `CatalogModel.swift` (A1, C2, C4, D1, F1); `SidebarView.swift` (A1, B2,
  B3); Settings files (C3, B5c, G1). `Package.swift` belongs to I1 alone.

## 4. Next actions by role

- **`@user`:**
  1. Answer or accept FEEDBACK-7's [open questions](plans/FEEDBACK-7.md#decisions-open) Q1–Q13 (the design ones before B0
     ends; Q13 before P0 and P1).
  2. Start B0, A1 and C1, which have no dependencies; P0 and P1 once Q13 is answered and the isolated profiles are signed in.
     Hand each implementer its brief with `plans/1.8.0/COMMON.md`.
  3. Still open from before: the push of `v1.6.0`–`v1.7.2` and the GitHub release; the Trash folders of 22, 25 and 26 Oct are
     theirs to empty.
- **`@planner`:**
  - review each slice's report and diff as it comes back, and integrate it onto `v2`;
  - move the approved v4 rules into `design/DESIGN.md` after B0;
  - keep the slice table in ACTIVE-PLAN current.
- **Implementers:** none running. Each takes its assignment only from its brief.
- **`@optimizer`:** at the 1.8.0 gate (plans/1.8.0/README.md §4).
