Docs are mostly consistent on facts and links, but the plan and status layers lag the code, and several durable decisions have no canonical home. Evidence is from read-only greps and file reads; I ran no builds or tests.

**Verified-correct baseline (so you can trust these):**
- Test counts: 280 + 39 + 5 + 53 = 377 `@Test` lines, matching `plans/cp5/UI.md:74`.
- Flags, channel and renderer match the code: `--evidence`, `--data-root` (`LaunchOptions.swift`), the channel name `local.loom.desktop.dev.command.<sha256(realpath)[:16]>` (`dev-paths.sh:32`), and Metal only via `--metal` with `--evidence` (`AppDelegate.swift:516`).
- `package-dev-app.sh` behavior matches `UI.md:58` and `DEVELOPMENT.md:29`. The identity hash `223E8AC…` is the installed valid identity.
- Both data paths in `DEVELOPMENT.md:22` exist.
- `COLORTERM=truecolor` is set unconditionally in `LaunchEnvironment.swift:68`, and the Reduce Motion decision is implemented as decided.
- Link check over 408 relative links: 1 broken, `plans/cp5/C.md:148` (anchor `#senaryolar-ve-model-turu` is missing from `cp5-c-real-provider-setup.md`).
- Size of the reading set: AGENTS + STATUS + DEVELOPMENT + agents/* + CP5 map is about 22 KB. The contract is 41 KB, `plans/cp5/` is about 330 KB (`C.md` 180 KB, `CLOSURE.md` 37 KB, `PERF.md` 28 KB), and `CHECKPOINT-5-HISTORY.md` is 152 KB.

## 0. Swarm-blocking facts (not just doc staleness)

- **The working tree is uncommitted.** HEAD is `f064fb2`, the CP2 close on 28 Sep. There are 48 modified and 141 untracked paths. `AGENTS.md`, `STATUS.md`, `DEVELOPMENT.md`, `Vendor/`, `patches/`, `Sources/LoomTerminal`, `LoomCatalogUI`, `loom-app` and `plans/cp5/` are all untracked.
  - A worktree or clone from HEAD would have no docs and would not build.
  - `package-dev-app.sh` stamps `CFBundleVersion` with `git rev-parse --short HEAD`, so every package reports `f064fb2` regardless of source state. Docs work around this by citing app SHA hashes.
  - A checkpoint commit before the swarm is a user decision (`AGENTS.md:46`).
- **Role plumbing is undefined for Claude Code.**
  - `agents/*.md` use `name: loom-*` frontmatter but live outside `~/.claude/agents/`, which holds only advisor, explorer, implementer, reviewer, strict-reviewer and verifier. There is no `optimizer`.
  - `AGENTS.md:11` mentions an "araştırmacı" role that has no file.
  - `CLOSURE.md` shows the optimizer and strict reviewer were run through explorer or strict-reviewer in practice.
  - The global rule says to start reviewer-type roles only when the user asks.
- **Subagents are forbidden from writing docs.** `agents/implementer.md:10` and `AGENTS.md:21` bar subagents from plans, STATUS and the contract. The new goal "every session updates docs when needed" has no protocol, so you need a rule such as "propose doc edits in the Report, planner merges".
- **Parallel builds in one tree.** The `.build` lock and the `--scratch-path` convention appear only in `PERF.md:30` and `D.md:38` ("single shared build/test owner"). `DEVELOPMENT.md` is silent.
- **Optimizer effort.** `AGENTS.md:36` pins Opus 5.5 / `xhigh` (or `gpt-6-astra` / `high`). No rule exists for other roles' effort, and "ultracode" is not defined. Inference: higher is allowed, because the rule only forbids dropping lower.

## 1. Stale or contradictory statements

| Where | Says | Actually true (evidence) | Severity |
|---|---|---|---|
| `STATUS.md:4` | After the UI slice comes "optimizer and PERF last big test" | Optimizer pass 3 is closed (`CLOSURE.md:198`). Final matrix H and I ran (`PERF.md:131-154`). The anchor `#son-büyük-test-geliştirmeler-bitti-kullanıcı-başlatacak` points at the pre-test plan. | misleads |
| `STATUS.md:6-7,10` | Decisions and numbers live in STATUS | `AGENTS.md:28` says STATUS holds only position and link. STATUS has no date stamp. | cosmetic |
| `STATUS.md:8,11` | Open user decisions: budgets, Codex closure, navbar | Missing: app CPU ceiling ≤%30 (`PERF.md:65,87`), Metal fast path PERF-M, C1 Claude-CLI settings (`PERF.md:27,114`), and the user-deferred Finder drop/link and covered GPU4 (only partly listed). | misleads |
| `plans/CHECKPOINT-5.md:19` | PERF: CPU40 "still failing", F-fix and P3 "next (paused)" | CPU40 passed (H total median 26.8%; I stream1 25.4-25.6%, `PERF.md:135,148`). F-fix and P3 were accepted 4 Oct (`PERF.md:102-104`). P3-S was added. | misleads |
| `CHECKPOINT-5.md:54,56` | D23 CPU40 failing; ASCII candidate runtime unverified "due to Mac lock" | The ASCII guard is vendor patch #6 (`LOOM-VENDOR.md:18`) and was superseded by packages H and I. | misleads |
| `CHECKPOINT-5.md:18,55` | D: remaining matrix open; "Reduce Motion native acceptance passed" | Partly done. The Reduce Motion semantics were reversed on 6 Oct (`DESIGN.md:75`). | cosmetic |
| `CHECKPOINT-5.md` slice table | No UI slice and no Codex pause | UI is the active slice (`STATUS.md:4`, `cp5/UI.md`). The Codex pause (4 Oct) is in `PERF.md:89` and STATUS only. | misleads |
| `UI.md:31-38` | Statuses: U-A, U-B, O-4 "implementation"; U-C "waiting"; Z "optimizer running" | 5 of 8 rows are stale. Acceptance is recorded at `UI.md:48-64`. U-C was fixed by O-1 (`UI.md:58`). | misleads |
| `UI.md:23,43` | Indicator is static under Reduce Motion | Reversed at `UI.md:70-72`, `DESIGN.md:75` and in the code (no gate). | misleads |
| `UI.md:48,50` | Header centered 34 pt, `WindowButtonsPositioner`, 22 pt | Superseded in the same file (UB-2 `:50`, UA-3 `:56`). Code: `CatalogTheme.swift` says 26 pt centre and 52 pt row. | cosmetic |
| `UI.md:52` | Evidence channel is system-global, fix "to be planned" | Fixed in O-1 (`UI.md:58`). | cosmetic |
| `PERF.md:19-28,71-72` | P1, P2, T1, T2, M1, T3, F-fix, P3 are "implementation/waiting/paused" | 8 of 10 rows stale; all were accepted in the results below. | misleads |
| `PERF.md:74-87` | "Where we left off 3 Oct": next steps F-fix, P3, package G | Done by 4-6 Oct. | misleads |
| `PERF.md:111,140` | Ritual depends on `/tmp/ffix/cmp.sh` and `claude_real.py` | `/tmp/ffix` currently exists but is ephemeral. `claude_real.py` and the matrix drivers are not in the repo (`scripts/` has no such file). The perf matrix cannot be rerun from the repo. | misleads |
| `CLOSURE.md:22,142-144` | "No new work will start"; Codex budget 6/6 | Superseded by 2-3 Oct (`:146-162`). `:5-16` is the old 30 Sep plan. There is no current closure checklist; it is a chronological log. | misleads |
| `FINAL-ACCEPTANCE.md:48` | "Next: package the ASCII candidate; real Codex idle/Stop" | Done or paused. | cosmetic |
| `RESOURCE-BUDGET-PROPOSAL.md:13-17,41` | Reference column = package C; CPU 43.5% over the ceiling | Package I is the current reference (CPU ceiling met). The proposal is the pending user decision but its data is stale. | misleads |
| `DEVELOPMENT.md:43,41` | "No Xcode/Instruments"; tools list has no xctrace | `xcode-select -p` is `/Applications/Xcode.app/...`, Xcode mtime is 5 Oct, and `Instruments.app` and `xctrace` exist. The macro-plugin workaround path (`:12`) is the CLT path and is now unverified. | misleads |
| `DEVELOPMENT.md:23` | Real Claude and Codex tests run with no permission asked | Codex real model turns are paused (`PERF.md:95`). Heavy tests wait for a user-run final test (`PERF.md:100`). | misleads |
| `DEVELOPMENT.md:27-29` | Signing identity is preferred, explicit id stops the build | Does not say that with no identity the script falls back to Apple Development, then **ad-hoc**, which loses TCC grants. Default output, the `~/Documents` refusal (exit 2), refusal while running (exit 3) and `LOOM_SCRATCH_PATH` are undocumented. | misleads |
| `cp5-c-real-provider-setup.md:3,22` | "Prepared, not run"; `--env LOOM_FORCE_COALITION_FAILURE=1` | That variable no longer exists in `Sources/`. The live one is `LOOM_FORCE_SCOPE_FAILURE` (`AppDelegate.swift:231`). The 8-turn budget is superseded (`DEVELOPMENT.md:23`). | misleads |
| `Vendor/SwiftTerm/LOOM-VENDOR.md:4`, `Package.swift` dependency comment | "chosen in `CHECKPOINT-5.md §3.1`" | The section moved to `CHECKPOINT-5-HISTORY.md §3.1`. | cosmetic |
| `design/DESIGN.md:3` | References the earlier `SPEC.md` | The file no longer exists (contract `:36`). | cosmetic |
| `agents/reviewer.md:16` | Lowercase informal paragraph | Inconsistent style. | cosmetic |
| `AGENTS.md` "no round reports" vs. practice | Rule: no per-round entries | `C.md` has about 40 numbered round sections, `HISTORY` 33, and `CLOSURE`, `UI` and `PERF` are per-round logs. | misleads |

## 2. Duplicated rules (drift risk)

- **Optimizer model/effort:** `AGENTS.md:36`, `agents/README.md:9`, `agents/optimizer.md:10`. Also repeated in `UI.md:25,38`, `PERF.md:5,28`, `CLOSURE.md:167,182,198`, `FINAL-ACCEPTANCE.md:50`, `RESOURCE-BUDGET-PROPOSAL.md:30`. The older copies mention only astra, because the Claude path was added on 3 Oct.
- **Real-provider test rule:** `DEVELOPMENT.md:23`, `CHECKPOINT-5.md:58`, contract `§3` isolation row, `HISTORY`.
- **Signing and TCC:** `DEVELOPMENT.md:27-31`, `FINAL-ACCEPTANCE.md:11,27`, `OWN.md`, `HOLISTIC.md`, `PERF.md:78`, and the script header.
- **Open user decisions:** `STATUS.md:8,11`, `CHECKPOINT-5.md` open-work table, `PERF.md:87,115`, `CLOSURE.md:206-208`. Four non-identical sets (see the §1 row on STATUS).
- **No commit/push/PR authority:** `AGENTS.md:46`, `PERF.md:5`, `FINAL-ACCEPTANCE.md:5,52`, `C.md`.
- **CPU ≤%40:** contract `§10`, `PERF.md`, `RESOURCE-BUDGET-PROPOSAL.md`, `FINAL-ACCEPTANCE.md`, `D.md`, `CLOSURE.md`. Definition drift risk: the sum covers app + fixture + run-scope hosts, and the fixture was changed (F-fix).
- **Current position:** `STATUS.md`, `CHECKPOINT-5.md:3`, `CLOSURE.md:24`, `FINAL-ACCEPTANCE.md:23`, each saying "STATUS is the source", while each also carries its own stale status table.
- **Evidence-flag semantics and command list:** only in code comments (`DevelopmentEvidence.swift:5-22`, `LaunchOptions.swift`). Docs mention flags only in plans.

## 3. Durable decisions buried in plan or history files (lift candidates)

1. **Codex development paused, Claude is the focus (4 Oct):** `PERF.md:89-96` and STATUS only. It conflicts with `DEVELOPMENT.md:23` and contract `§3`.
2. **Heavy tests and measurements deferred to one final run the user starts (4 Oct):** `PERF.md:98-100`. Includes the conditions: screen unlocked, adapter plugged in, no concurrent build or test, Terminal windows miniaturized, `caffeinate -u`, cool-down of 90-120 s, interleaving, and no System Events. These are in `PERF.md:84,108`.
3. **Product renderer is CG, Metal is dev-only (`--metal`, requires `--evidence`), PERF-M deferred:** `PERF.md:49`. Also the "no second engine or product fork" rule from `HISTORY §3.1`.
4. **Standing improvement authority (5 Oct):** `UI.md:5` — the user authorized "certain" UI/UX, code and optimization improvements along the way. It is time-scoped and needs reconfirming for the swarm.
5. **Evidence-mode rules:**
   - `--evidence` always uses an isolated root, and `--data-root` is valid only with it.
   - Evidence-only flags: `--fixture`, `--metal`, `--fake-providers`, `--claude-config`, `--codex-home`, `--evidence-tokens`, `--evidence-transparency`, `--fake-toolchain-delay`, `--fail-first-quit`.
   - Real-provider evidence redacts screen text (`AppDelegate.swift:702`).
   - The default dev catalog `Loom-Dev/catalog.sqlite3` must not change; it was once polluted, which is why `catalog-backup-20261005-synthetic` exists.
   - Source: `UI.md:58`, `CLOSURE.md:169-180`, code comments.
6. **Provider environment:** `TERM=xterm-256color` and `COLORTERM=truecolor` are always added. This is in `UI.md:50`, the code and a test; the contract is silent.
7. **Vendored SwiftTerm policy:** pinned commit `fe4fb45…`, local changes only via `patches/*.patch` plus `LOOM-VENDOR.md` (12 items, 10 patches, consistent). Neither `AGENTS.md` nor `DEVELOPMENT.md` mentions it, and the contract `§2` table omits `Vendor/` and `patches/`.
8. **Packages and scratch must live outside `~/Documents` (TCC):** `OWN.md`, `HOLISTIC.md` SR3-P2-3, and the scripts. `DEVELOPMENT.md` is silent.
9. **Other undocumented items:**
   - The dev data layout: `Loom-Dev/{catalog.sqlite3, ui-preferences.json, app, packages (15 archives), app-* (7 dirs), runs, signing}`, plus `~/.loom-dev/{scopes, h-*.sock}` for hooks and run scopes.
   - The prod identity branch (`local.loom.desktop` → `Loom`, `~/.loom`; `AppDelegate.swift:113,234,402`) has no packaging, notarization or Developer ID doc and no script.
   - Perf baselines (stream1 app 24%, spinner1 12-15%, hidden 3.5%, p95 ~20 ms, footprint peak ~115 MiB) are scattered across `PERF.md` and `plans/experiments/*.json`.
   - `LOOM_RENDER_BENCH`, `LOOM_FORCE_SCOPE_FAILURE` and `LOOM_EXPERIMENT_DIR` appear only in scripts and tests.
10. **Navbar and "closing CP5 without Codex items":** `UI.md:15`, `PERF.md:96`.

## 4. Contract `LOOM-PRODUCT-CONTRACT.md` `§3` — possibly outdated, needs user decision (no rewording proposed)

- **`:47` first-window scope includes Codex.** The 4 Oct pause was recorded only in `PERF.md`; whether it is temporary sequencing or a scope change is the user's call.
- **`:52` "Terminal engine and UI technology to be selected."** In fact SwiftTerm `fe4fb45` + patches, SwiftUI/AppKit and the CG renderer are chosen. No user decision is recorded for this; `HISTORY §3.1` says "first candidate".
- **`:60` Codex path "about 110 MiB extra fixed memory".** That was the shared-server estimate. The `:55` per-session decision and `PERF.md:55` give different numbers (Loom path vs. `--no-daemon`: +37 MiB, 156 vs. 119 MiB).
- **`:62` Codex 30-minute cache accepted.** This conflicts with `§4.4 :117` ("no server cache remains for a stopped session") and `:55`.
- **`:57` Managed CLI environment.** It names only "Loom markers"; the code also adds `TERM` and `COLORTERM`. Inference: this is covered, but it is not stated.
- **Open (not outdated) for prod planning:** whether CP4 (delete/stale) and CP3 (coordination) are required before prod. `:47` defers delete, and the order at `:59` is fixed.
- **Non-§3 contract staleness** (editable by the planner under its own rules): `:3-4` header date (2 Oct) predates the 3 Oct `§10` edit; `:150-155` "will be compared" is now decided; `:161` mentions the A5 gap superseded by run scope; `:234` calls SQLite/SwiftUI/AppKit "candidates"; `:304-312` open items 1 and 5 are partly resolved; `:323` lists "project/activity views" as undecided though they are implemented and also in `§3 :47`.

## 5. Verdict per top-level doc

- **`AGENTS.md`: update.**
  - Add a doc-update protocol and role→`subagent_type` mapping.
  - Note which tree state to work from (worktree vs. shared).
  - Reconcile the "no round reports" rule with practice.
  - Add pointers to canonical decisions.
- **`STATUS.md`: update.** Add a date stamp, fix line 4, make the open-decisions list complete or link to one canonical list, and drop numbers and decisions.
- **`DEVELOPMENT.md`: update and extend.**
  - Fix the Xcode, Codex and heavy-test statements.
  - Add the sections from §3 above: evidence mode, packaging behavior, data paths, build and scratch concurrency, release-suite command, perf baseline pointer, vendor policy, and `COLORTERM`.
  - Consider splitting into dev guide, evidence and scripts reference, and perf method.
- **`LOOM-PRODUCT-CONTRACT.md`: keep `§3` as is** until the §4 decisions are taken; update the non-§3 sections listed above. Optionally split `§4-§8` (future checkpoints) from the current-state sections.
- **`design/DESIGN.md`: keep.** Fix the `SPEC.md` mention and say plainly that `§5` overrides `§2.8` for the working indicator. Add the 36 pt detail header row and the unified-toolbar fact, or mark them as living in `CatalogTheme.swift`.
- **`agents/*.md`: update.** Add Claude Code mapping, an explicit doc-ownership rule, and effort rules for the swarm.
- **`plans/CHECKPOINT-5.md`: update.** Add a UI row, the Codex-pause note and refreshed PERF/D rows. It has no CP3/CP4 stubs.
- **`plans/cp5/UI.md`, `PERF.md`, `CLOSURE.md`: archive** after lifting §3 content. Add a short top-level "closure checklist" and "current state" to each, or move the lifted summary into the checkpoint map. `C.md` (180 KB) and `CHECKPOINT-5-HISTORY.md` (152 KB) stay as archives and need an index.
- **`RESOURCE-BUDGET-PROPOSAL.md`: refresh** its reference column to package I before the user decision.
- **`plans/experiments/cp5-c-real-provider-setup.md`: archive** (stale env var and budget).

Key files audited: `/Users/gencberke/Documents/github/loom/AGENTS.md`, `STATUS.md`, `DEVELOPMENT.md`, `LOOM-PRODUCT-CONTRACT.md`, `design/DESIGN.md`, `agents/*.md`, `plans/CHECKPOINT-5.md`, `plans/cp5/{UI,PERF,CLOSURE,FINAL-ACCEPTANCE,RESOURCE-BUDGET-PROPOSAL,D,OWN,HOLISTIC}.md`, `scripts/{package-dev-app,dev-paths}.sh`, `Sources/LoomLaunchOptions/LaunchOptions.swift`, `Sources/loom-app/AppDelegate.swift`, `Vendor/SwiftTerm/LOOM-VENDOR.md`.