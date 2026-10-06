# Stage F — foundation hardening

Part of [multi-agent run 1](RUN-1.md). Roadmap row: [ROADMAP → F](../ROADMAP.md#f-foundation-hardening-proposed). Facts: [F scan](experiments/run1-planning-scans/F-foundation.md), [architecture/scale scan](experiments/run1-planning-scans/arch-scale.md), [performance research](experiments/run1-planning-scans/perf-research.md), [tooling scan](experiments/run1-planning-scans/tooling-baseline.md), CP5 optimizer items in [cp5/CLOSURE.md](cp5/CLOSURE.md).

## Goal

Make the base safe for parallel feature work and for production, with no user-visible behavior change: Codex surfaces out of the production app, quit off the A-slice `TerminalRunController`, evidence code out of the release build, large actors split where it lowers coupling, one local check command, the deferred optimizer items taken or dropped, and the measured launch and sidebar hot paths fixed.

## Slices

| Slice | Delivers | Write area (summary) | Wave | Depends on | State |
| --- | --- | --- | --- | --- | --- |
| [F0](f/F0.md) | `scripts/with-build-slot.sh`, `scripts/check.sh`, perf baseline comparer, one command-channel helper for scripts | `scripts/`, `DEVELOPMENT.md` §2–§3, `scripts/README.md`, `.gitignore` | 1 | — | accepted `5b2d9b0` |
| [F1](f/F1.md) | `BuildIdentity` (one owner of the production/development identity); Codex entry points hidden in production | `Sources/LoomLaunchOptions`, listed sites in `AppDelegate`, `SidebarView`, `DetailView`, `CatalogModel`, `ConversationController`, their tests | 1 | — | accepted `ae40652` |
| [F2](f/F2.md) | `AppShutdownCoordinator`; quit no longer routes through `TerminalRunController` | new `Sources/LoomCore/AppShutdownCoordinator.swift`, quit sites in `AppDelegate`, `TerminalRunController`, tests | 1 | — | accepted `ea0150e` |
| [F3](f/F3.md) | Evidence code compiled only in dev builds (`LOOM_EVIDENCE`), promote excludes it, `check.sh --full` builds the release flavor | `Package.swift`, `Sources/loom-app/**`, `scripts/release/promote.sh`, `scripts/check.sh` | 2 | F0, F1, F2 | accepted (this commit) |
| [F4](f/F4.md) | Move-only splits of `SessionCatalog`, `SessionRuntime` (Codex, Claude parts), `ProcessSupervisor` | `Sources/LoomCore/SessionCatalog*.swift`, `SessionRuntime*.swift`, `ProcessSupervisor*.swift` | 1 | — | accepted `523cfba`, `e3b962f`, `614f9c3` |
| [F5](f/F5.md) | Signposts and a launch/switch baseline; first list paint no longer waits for the runtime; no git reads or needless observation writes on the main actor | `AppDelegate` startup, `CatalogModel`, `GitBranch`, new `BranchCache`, `SessionCatalog` open path | 2 | F3 (AppDelegate), F4 | planned |
| [F6](f/F6.md) | Optimizer items S2, F10 (the undecodable-row item moved to CP4-B, which owns the catalog files in wave 2) | `ProcessSupervisor+…`, `EnvironmentResolutionJob`, `SessionRuntime+Codex` (S2 site), `SessionCatalog` decode path | 2 | F4 | planned |

Docs (`docs/ARCHITECTURE.md` §2, §3 Quit, §7, §9; `DEVELOPMENT.md`; `scripts/README.md`) are updated by the slice that changes the fact, checked at review; the planner-reviewer applies the rest.

## Decisions taken in planning (routine, technical)

- **Codex switch is a runtime identity check, not a compile-time define.** A release-only define breaks `promote.sh`'s manifest drift check and ships a flavor the dev suite never tests; `BuildIdentity(bundleIdentifier:)` is testable in both flavors. Codex code stays in the binary, paused and unreachable (D-28).
- **Evidence separation is compile-time** (`#if LOOM_EVIDENCE` defined only in the dev manifest's `loom-app` target), because evidence code is the bulk of `loom-app` and must not ship. The gap this opens (the release flavor compiles only at promote time) is closed by F3's staged release-tree build in `check.sh --full`.
- **Deferred optimizer items:** TAKE S2 (process-table snapshot for one PID) and F10 (empty environment host kept until Quit). DROP F6 (procargs scan; scoped mode intersects with scope members, a change would touch the ownership oracle), F9 (per-session maps bounded per app run; CP4 adds forget hooks) and S4 (rare-contention 1 ms polling; changing it risks pinned stop/shutdown semantics). F8 (all sessions loaded at launch) is split: the launch-order part moves to F5; lazy loading is dropped for now (about 35 synchronous callers) and CP4-C adds a `discardSession` path instead. S-C (`ChromeButtonStyle` per-instance state) moves to I1, which rewrites that file region.
- `quick_check` stays at launch until F5 measures it; it is moved only if the measurement shows it matters, and never so that a write can happen before it passes.

## Acceptance (stage)

- **F-A1** Production identity (`local.loom.desktop`): no Codex item in menus, context menus, the `+` menu or the empty state; Codex cannot be started; development identity unchanged. Unit tests in both flavors.
- **F-A2** Quit behaves exactly as before: waits for startup, verified shutdown, Try Again alert on an unverified shutdown, `--fail-first-quit` evidence, quit while an environment job is held (`cp5-c-acceptance.sh` §3–§4 on a package), evidence keys unchanged.
- **F-A3** The staged release tree (promote allowlist + `Package.release.swift`) builds with no `LOOM_EVIDENCE` code and no `Sources/loom-app/Evidence/`; dev packages still pass the evidence acceptance scripts.
- **F-A4** Actor splits are move-only: same tests green; no logic diff beyond access-level relaxations.
- **F-A5** `scripts/check.sh` runs the default, `--suite`, `--windows` and `--full --idle` flows with the documented exit codes; the perf comparer exits non-zero on a regression against the paired reference cells.
- **F-A6** Launch: signpost timeline from process start to first list paint recorded before and after F5 at 0 / 1k / 10k catalog rows; the first list paint no longer includes the runtime start; no synchronous git read on the main actor during list reloads.
- **F-A7** Behavior unchanged on the combined tree: full release suite, `claude_real.py` (2 real turns), matrix against the package I reference with CPU40 held, architecture doc matches the code.

## Evaluation and closure

Stage-end recipe in [RUN-1](RUN-1.md#stage-end-evaluation-recipe) (steps 1–3, 5, 7, 8). Optimizer before closing.

## Real-Claude turns

Planned 2 (F-A7). Used: 0.

## Results

- **F0** (`5b2d9b0`): `scripts/check.sh`, `scripts/with-build-slot.sh`, `scripts/perf/compare_baseline.py` (self-test passes on the package I baseline shape); the CLT macro-plugin flag is not needed with Xcode selected. Planner fixes on accept: `usage()` path and the window label in `check.sh`; the theme literal guard joined the default mode.
- **F1** (`ae40652`): `BuildIdentity`; production offers only Claude (model and controller tests); production menu bar UI to be checked on the release candidate.
- **F4** (`523cfba`, `e3b962f`, `614f9c3`): three move-only splits; planner re-check: the normalized sorted-line diff (access modifiers, imports, extension headers and braces removed) of each original against its new files is empty; 198 tests in 13 suites on the combined tree, one load-sensitive failure of `RunScopeTests.hostStopsItsScopeWhenLoomDisappears` (one member still alive at the 15 s deadline, gone shortly after; 3/3 green alone; F4 does not touch the run host) — watched in the full suite.
- **F3** (this commit): `LOOM_EVIDENCE` dev define; `Sources/loom-app/Evidence/` (6 files) and `DevelopmentSeams.swift` stubs; shared `scripts/release/allowlist.sh`; `check.sh --release-tree` (also in `--full`) builds the staged release tree and fails on evidence symbols/strings (shown failing on the old sources, passing after); promote drift normalizer accepts only the define. Planner fixes: the stage step checks every command and keeps a fixed stage path so the release build stays incremental; DEVELOPMENT §2 and `scripts/README.md` document `--release-tree`. Accepted deviation: `check.sh` stages the checked-out tree (equal to HEAD when clean), `promote.sh` still archives the tag. `cp5-b`/`cp5-c` acceptance runs on the stage F package.
- **F2** (`ea0150e`): `AppShutdownCoordinator`; quit tests moved; deviation accepted: no own reply enum (AppDelegate keeps the AppKit branching). End-to-end quit evidence (`cp5-c-acceptance.sh` §3–§4) runs on the stage F package.
