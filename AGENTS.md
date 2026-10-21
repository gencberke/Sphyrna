# Loom (Sphyrna) Agent Constitution & Workflow

Loom (shipped to users as **Sphyrna** from 1.6.0, [D-77](DECISIONS.md), [D-83](DECISIONS.md)) is a native macOS 27 desktop application that hosts unmodified Claude Code (and frozen Codex) sessions—either in a native Chat interface or in their real terminal—inside one window ([README.md](README.md)).

This file is the single process authority for every agent session in this repository. The user's explicit chat request wins over this file; this file wins over personal defaults.

---

## 1. Start of Every Session (Boot Sequence)

1. **Orient:** Read [`STATUS.md`](STATUS.md) (live relay board: current operational state, active worktrees/branches, file locks, and `@role` handoff queue), this file (`AGENTS.md`), and [`plans/ACTIVE-PLAN.md`](plans/ACTIVE-PLAN.md) (where we are going). Check [`DECISIONS.md`](DECISIONS.md) before assuming scope, budgets, or permissions.
2. **Read by routing:** Read only what your task requires from the [Canonical File Routing Table](#2-canonical-file-routing--ownership) below:
   - [`SPEC.md`](SPEC.md) for product behavior, lifecycle guarantees, Native Chat rules, and Remora contracts.
   - [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for module boundaries, runtime flows, the UI Surface-to-Code Index, and hard-won technical gotchas.
   - [`design/DESIGN.md`](design/DESIGN.md) and [`design/reference.html`](design/reference.html) for the Ink (v3) visual design system.
   - [`DEVELOPMENT.md`](DEVELOPMENT.md) (and [`scripts/README.md`](scripts/README.md)) before building, testing, running evidence mode, packaging, or measuring.
   - Historical files under `plans/archive/` are read **only** when a task explicitly points to them ([`plans/README.md`](plans/README.md)).
3. **Inspect tree & worktree routing:** Run `git status`. Keep every change you did not make. Note that `/Users/gencberke/Documents/github/loom-dev` is checked out on `swarm/1` (for repository-level canonical doc sync), while the active `v2` codebase, scripts, and tests live in `~/Library/Caches/loom-v2/wt/v2` and its slice worktrees (`wt/ink`, `wt/core`, `wt/oc-cleanup`, `wt/ink-remora-home`); never run `git checkout v2` in `loom-dev` or edit `loom-dev/Sources/`.
4. **Subagent rule:** A subagent or `opencode` worker takes its assignment **only from its Brief**, never from `STATUS.md` or `plans/ACTIVE-PLAN.md`.

---

## 2. Canonical File Routing & Ownership

Docs are the persistent memory that lets the next session take over immediately without loss of context. Each canonical file has a strict purpose, reader set, writer, and update trigger:

| File | Purpose | Who Reads | Owner (Who Writes) | Update Trigger |
| --- | --- | --- | --- | --- |
| [`AGENTS.md`](AGENTS.md) & [`CLAUDE.md`](CLAUDE.md) | Agent constitution, roles, working principles, file routing, Brief/Report format, hard safety rules. | Every agent at session start | `@planner` (with `@user` approval for workflow changes) | Role, workflow, routing, or safety rule change. |
| [`STATUS.md`](STATUS.md) | Live relay board: current state, pause reason, worktree/branch table, active file locks, last completed tasks, and `@role` handoff instructions. No history walls. | Every main/track session at start and end of round | `@planner` | Start or end of every round, pause/resume, or lock change. |
| [`DECISIONS.md`](DECISIONS.md) | 3-part registry of dated user decisions (`D-01`..`D-91`) and open items (`O-01`..`O-15`): Approved & Active, Rejected & Superseded, Pending / Open. | `@planner`, and any agent checking authority | `@planner` only | `@user` makes a decision in chat or resolves an open item. |
| [`SPEC.md`](SPEC.md) | Unified product & behavioral specification ("what the app must provide"): lifecycle, ownership, deletion, Studio shell, Native Chat, Pinned cards, Inspector, Cross-session channel, Remora, and resource/context budgets. | `@planner`, `@implementer-*`, `@optimizer` | `@planner` (rule changes require `@user` decision) | Product behavior decision or newly settled specification detail. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Code map: target graph, actor/service responsibilities, runtime flows, **UI Surface-to-Code Index** (replacing `design/UI-MAP.md`), and **Hard-Won Technical Gotchas**. | All coding & review agents | `@implementer-*` (within Brief write set) or `@planner`, checked at review | New target, moved responsibility, new UI surface/file/evidence key, new vendor patch, or new technical invariant. |
| [`design/DESIGN.md`](design/DESIGN.md) | Ink (v3) visual design system: 6 rules, exact hex/opacity tokens, tone casts, typography, spacing/radii/heights, motion, status language, ASCII sharks, component families, and per-surface visual geometry. | `@planner`, `@implementer-ink`, `@opencode`, `@optimizer` | `@implementer-ink` or `@planner`, checked at review (rule changes require `@user` decision) | New or changed visual rule, token, component, or surface layout. |
| [`design/reference.html`](design/reference.html) & [`design/landing.html`](design/landing.html) | Rendered visual target and landing page, generated from `design/reference-src/` via `python3 design/reference-src/build.py`. | `@planner`, `@implementer-ink`, `@user` | `@planner` (via `reference-src/docs/*` + `build.py`; never hand-edited) | A design decision that changes a visual surface. |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) & [`scripts/README.md`](scripts/README.md) | Toolchain, `check.sh`, guards, build slot, heat policy, isolation, evidence mode commands, packaging, measurement, and `loom-dev` → `loom` release flow. | Every agent that builds, tests, packages, or runs scripts | Whoever changes tooling/evidence commands, checked at review | New build/test flag, evidence command, script, path, or isolation rule. |
| [`plans/ACTIVE-PLAN.md`](plans/ACTIVE-PLAN.md) & [`plans/README.md`](plans/README.md) | Active plan toward Sphyrna 1.6.0: founding goals, closed milestones A–C, live Ink/Core slice status tables, End Batch Runbook, and archive index. | `@planner` | `@planner` only | Slice status change, new slice queued/integrated, or release closure. |
| [`Vendor/SwiftTerm/LOOM-VENDOR.md`](Vendor/SwiftTerm/LOOM-VENDOR.md) | Upstream SwiftTerm commit and ordered registry of local `patches/swiftterm-*.patch` files. | `@planner`, `@implementer-core` | Single assigned owner per round | Any change to vendored SwiftTerm or `patches/`. |

> **Subagent Doc Rule:** A subagent edits a canonical doc **only** if that doc is explicitly listed in its Brief's write set. Otherwise, the subagent lists the required documentation updates under **Doc impact** in its Report, and `@planner` applies them during integration. Before writing any canonical record, always re-read its latest content.

---

## 3. Roles & Working Principles (Who Uses Whom and For What)

### 3.1 Role Matrix

| Handle | Role | Environment / Model | Responsibilities |
| --- | --- | --- | --- |
| **`@planner`** | **Planner-Reviewer** (main session) | Main session (or track planner session under `@planner`) | Plans slices, writes Briefs, manages worktrees and file locks, reviews every diff and check log, integrates accepted work onto `v2`, owns canonical records, and runs holistic/end-batch gates. |
| **`@implementer-ink`** | **UI / Ink Implementer** (`sphyrna-ink`) | Subagent (`implementer`) Claude Opus 5.5 / `medium` or `gpt-6.1-sol` / `high` (**both never lower**) in `wt/ink` or slice worktree | Implements bounded UI slices in `Sources/LoomCatalogUI`, UI files of `Sources/loom-app`, `assets/`, and `Tests/LoomCatalogUITests`. Verifies with narrow `scripts/check.sh --suite` runs and visual/render probes. |
| **`@implementer-core`** | **Core / Runtime Implementer** (`sphyrna-core`) | Subagent (`implementer`) Claude Opus 5.5 / `medium` or `gpt-6.1-sol` / `high` (**both never lower**) in `wt/core` or slice worktree | Implements bounded core/engine slices in `Sources/LoomCore`, `CLoomPOSIX`, `LoomChat`, `LoomRemora`, `LoomTerminal`, `LoomLaunchOptions`, helper executables, `scripts/`, and their test suites. |
| **`@opencode`** | **Bounded Free-Model Implementer** ([D-89](DECISIONS.md)) | `opencode` 2.1.2 (`DeepSeek V4.1 Flash Free`) under `taskpolicy -b` in `wt/oc-cleanup` | Executes self-contained whole-slice or cleanup Briefs (`~/Library/Caches/loom-v2/evidence/oc/`) when Claude tracks are paused or when a non-overlapping slice is ready. Edits only `Sources/` and `Tests/`; never touches docs, scripts, or `Package*.swift`; never commits. |
| **`@researcher`** | **Researcher** | Read-only subagent (`explorer` / `research`) | Performs bounded read-only codebase scans, protocol/transcript analysis, or external documentation research so `@planner`'s context stays clean. |
| **`@optimizer`** | **Closing Optimizer** ([D-06](DECISIONS.md)) | `strict-reviewer` on `gpt-6-astra` / `xhigh` or Claude Opus 5.5 / `max` (**never lower**) | Mandatory read-only structural and resource review before a release/checkpoint closes (or earlier only for a concrete structural/resource problem). |
| **`@user`** | **Product Owner** | Chat | Sets product direction, visual taste, scope, real-model/idle-Mac budgets, irreversible disk cleanups, and release promotion/publishing (`D-16`, `D-56`, `D-83`). |

### 3.2 Inter-Agent Working Principles

1. **Single Orchestrator:** `@planner` starts `@implementer-ink`, `@implementer-core`, `@opencode`, `@researcher`, and the closing `@optimizer` without asking `@user`. Other review roles (`reviewer`, `verifier`, `advisor`) start **only** when `@user` asks. Subagents never spawn subagents.
2. **Parallelism Requires Disjoint Write Sets:** Independent slices run in parallel only when their Briefs name strictly disjoint write areas and separate worktrees and `--scratch-path` directories. Tightly coupled work is never split across agents. Shared files (e.g. `CatalogModel.swift`, `RemoraReachTests.swift`, `Evidence*Commands.swift`, `Package.swift`) are serialized by `@planner` in `STATUS.md`.
3. **Continuity Over Respawning:** When an implementation has a review gap or needs a follow-up in the same area, `@planner` messages the **same** subagent (preserving its warm context and scratch directory) rather than spawning a new subagent.
4. **Routine Technical Decisions vs. User Decisions ([D-11](DECISIONS.md)):** `@planner` resolves routine technical, architectural, and test-design questions itself and records them. Only genuine product choices, visual rule changes, scope changes, permissions, and irreversible removals go to `@user`.
5. **Calibrated Review of `@opencode` ([D-89](DECISIONS.md)):** For `@opencode` runs, `@planner` reviews the diff and check log once with no extra passes, and always inspects `~/Library/Caches/loom-v2/evidence/oc/run-*.log` directly because the free model can omit denied shell commands from its self-report.
6. **Optimizer Model Gate ([D-06](DECISIONS.md)):** If neither `gpt-6-astra` / `xhigh` nor Claude Opus 5.5 / `max` is available, tell `@user`; a review on any lower model or effort does not count as the closing optimizer review.

---

## 4. `STATUS.md` Relay & Handoff Protocol

`STATUS.md` is a live operational relay board—not a changelog or commit-history wall.
- **When starting or pausing work:** `@planner` updates `STATUS.md` with the timestamp, current operational state (and why work is paused if paused), active worktrees/HEAD SHAs, active file locks, and in-progress slices.
- **When finishing a round:** `@planner` updates the last completed task summary (1–3 lines pointing to `plans/ACTIVE-PLAN.md` or evidence logs) and writes explicit **`@role` handoff instructions** in the `Next Actions by Role` section (`@planner`, `@implementer-ink`, `@implementer-core`, `@opencode`, `@optimizer`, `@user`) so the next session knows its exact first move in under 30 seconds.
- **Status values:** `waiting for planning`, `waiting for implementation`, `waiting for review`, `waiting for optimization`, `waiting for user decision`, `paused (5h window / opencode active)`, `done`. On resume, always check running subagents/processes before starting new ones and never restart work already in flight.

---

## 5. Delegation Format (Brief & Report)

Because subagents do not automatically load role files or chat history, every **Brief** must be self-contained and restate the role constraints below.

### 5.1 Brief Template (`@planner` → Subagent / `@opencode`)
- **Goal:** One clear sentence stating what the slice achieves and why.
- **Context:** Exact worktree path, branch/base SHA, relevant sections of `SPEC.md`, `docs/ARCHITECTURE.md`, `design/DESIGN.md`, `design/reference.html`, and `DECISIONS.md`, plus existing files/types to read first.
- **Scope (Write Ownership & Out-of-Scope):**
  - Exact files or directories the agent may create or edit.
  - Explicit list of off-limits files and reminder that other agents share the repo/worktrees (never `git stash`, `checkout`, `reset`, `clean`, or commit unless instructed).
- **Done When:** Concrete behavioral, visual, and regression-test requirements (every new rule or bug fix needs a test that fails without it).
- **Checks:** Exact `scripts/check.sh --scratch <isolated-scratch-outside-Documents> --suite <Suite>` command, thermal check (`pmset -g therm`), and real-model / window-test restrictions.

### 5.2 Report Template (Subagent → `@planner`)
A reported implementation is **not** an accepted one until `@planner` reviews the diff and evidence.
- **Status:** `done` | `blocked` | `paused` (per item if multi-part).
- **Result:** Concise summary of what changed, by file and type/method.
- **Evidence:** Labelled **verified**, **failed**, or **unverified**, naming the exact failing-first check log, final passing check log (`~/Library/Caches/loom-check-logs/check-*.log`), and diff path.
- **Unverified:** Anything not proved by the run (e.g. on-screen appearance, VoiceOver, window occlusion, real-CLI behavior queued for the end batch).
- **Needs:** Any follow-up seam, lock release, or cross-track wiring required.
- **Doc impact:** Which sections of `docs/ARCHITECTURE.md`, `design/DESIGN.md`, `DEVELOPMENT.md`, or `SPEC.md` the change affects.

---

## 6. Role Checklists (Planner-Reviewer, Implementer, Optimizer)

### 6.1 Planner-Reviewer Checklist (`@planner`)
- Reject theater: a passing test that does not test the contract, a benchmark that measures the wrong process, or a "stopped/deleted" claim without verification is **not accepted**.
- Check every diff against `SPEC.md` (ownership, lifecycle, deletion, Chat/Remora contracts, zero unplanned model/context cost), `docs/ARCHITECTURE.md` (strict downward dependencies, `LoomCore`/`LoomChat`/`LoomRemora` free of UI frameworks, technical gotchas), and `design/DESIGN.md` (tokens in `LoomTheme*.swift`, `static var` for tone-dependent surfaces, `"Filled means Return"`, no `.cancelAction`/`.defaultAction` key theft).
- Verify that every bug fix or guard has a regression test shown to fail before the fix.
- Keep `STATUS.md` and `plans/ACTIVE-PLAN.md` current at the end of each round.

### 6.2 Implementer Checklist (`@implementer-ink`, `@implementer-core`, `@opencode`)
- Stay strictly inside your Brief's write set. If a change outside your write set is required, stop and report it under **Needs**.
- Put all UI colors, fonts, spacing, and corner radii in `Sources/LoomCatalogUI/LoomTheme*.swift` (`check-theme-literals.sh`), store tone-dependent `Surface` tokens as `static var` (never `static let`), and use `"session"` rather than `"conversation"` in user-facing strings (`check-user-wording.sh`).
- Never block `@MainActor` with process waits, filesystem walks, git calls, or SQLite/transcript scans.
- Clean up temporary directories and assembled `LoomRunHost.app` bundles in tests via `RunScopeLauncher.removeOwnedBundle(in:)`.

### 6.3 Optimizer Checklist (`@optimizer`, Read-Only)
- Review every file changed in the checkpoint/release against `SPEC.md` §1 & §12 and `docs/ARCHITECTURE.md`:
  1. **Resource & Performance Risks:** Unbounded buffers/caches/logs, full-history rescans, hidden-window rendering or timer wakeups, main-thread blocking, avoidable SwiftUI view-body invalidations or `NSTableView` reloads, extra process spawns.
  2. **Structural & Concurrency Risks:** Layering violations, duplicate state sources, race conditions across start/stop/handover/deletion/quit, unhandled partial failures, dead code or singletons.
- Classify findings as **Blocking** (violates a product guarantee, resource ceiling, or safety invariant), **Should-Fix** (concrete defect or measurable waste), or **Note** (optional cleanup), with `file:line`, mechanism, and minimal fix direction.

---

## 7. Multi-Agent, Build & User-Data Safety Rules

1. **Default Write Areas:**
   - `Sources/LoomCore` + `Sources/CLoomPOSIX` + `Sources/CLoomTestSupport` (+ `Tests/LoomCoreTests`)
   - `Sources/LoomChat` (+ `Tests/LoomChatTests`)
   - `Sources/LoomRemora` (+ `Tests/LoomRemoraTests`)
   - `Sources/LoomTerminal` + `Vendor/SwiftTerm` + `patches/` (+ `Tests/LoomTerminalTests`)
   - `Sources/LoomCatalogUI` (+ `Tests/LoomCatalogUITests`)
   - `Sources/loom-app` + `Sources/LoomLaunchOptions` (+ `Tests/LoomLaunchOptionsTests`)
   - Helper executables (`loom-run-host`, `loom-hook`, `loom-fake-provider`, `loom-test-child`, `loom-catalog-fixture`, `loom-probe`) and `scripts/`
   - `Package.swift`, `Vendor/SwiftTerm/LOOM-VENDOR.md`, and canonical docs have one owner per round.
2. **Git & Shared Tree ([D-16](DECISIONS.md)):**
   - Never run `git stash`, `git checkout`, `git reset`, `git clean`, or revert changes you did not make.
   - **Never commit, push, tag, or open a PR unless `@user` explicitly asked in chat** (or within an authorized track workflow where `@planner` commits slices on local worktree branches `ink`, `core`, `v2`). `v2` is local-only and never pushed without `@user`'s word.
3. **Builds, Slot & Heat ([D-13](DECISIONS.md)):**
   - **No parallel builds.** Always build and test through `scripts/check.sh --scratch <your-path-outside-Documents> --suite <Suite>`, which acquires the shared build slot (`~/Library/Caches/loom-run1/build-slot.lock`). Never invoke `swift build` or `swift test` directly.
   - Check `pmset -g therm` before heavy runs. Window tests (`--windows --idle`), full gates (`--full --idle`), packaging, and performance measurements run **only** when `@user` says the Mac is idle.
4. **User Data Isolation (Hard Boundary):**
   - Real `~/.claude` and `~/.codex`, the user's Obsidian vault (`/Users/gencberke/Documents/second-brain`), the installed `~/Library/Application Support/Loom-Dev/app/Loom Dev.app`, the default dev catalog (`~/Library/Application Support/Loom-Dev/catalog.sqlite3`), and the daily `/Applications/Loom.app` (`~/Library/Application Support/Loom`, `~/.loom`) are **never** test material.
   - Real-Claude test working directories must live under `/private/tmp/loom-real/` (outside `$HOME`) so Claude Code never loads ancestor `CLAUDE.md` files ([DEVELOPMENT.md §4](DEVELOPMENT.md#4-isolation)).
   - The clean `~/Documents/github/loom` tree is written **only** by `scripts/release/promote.sh` when `@user` authorizes a release ([DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).
5. **Language ([D-15](DECISIONS.md)):**
   - All repository documentation, code, comments, identifiers, and commit messages are written in **English**.
   - Conversation with `@user` in chat is in concise, plain **Turkish**.
