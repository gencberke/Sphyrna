# Audit: process, plans and session onboarding (Loom, read-only, 6 Oct 2026)

Facts come from reading files and git. Inferences are labelled.

## 0. Headline facts

- **Nothing is committed since `f064fb2` (28 Sep 2026 16:03, "close CP2").** Everything from CP5 (28 Sep to 6 Oct) is uncommitted, and `git branch` shows only `main`.
  - `git status --short` shows 190 entries: 141 untracked (`??`) and 49 modified or deleted.
  - Tracked diff is `49 files changed, 5492 insertions, 1102 deletions`.
  - Untracked first-party code, tests, scripts, patches and CP5 plans total about 17.4k lines.
  - `Vendor/` is untracked as a whole: 142 files, about 67k lines of Swift.
  - **`AGENTS.md`, `STATUS.md` and `DEVELOPMENT.md` are themselves untracked.** A fresh checkout or worktree would not contain the process docs.
  - `plans/CHECKPOINT-5*.md`, `plans/cp5/*` and 100+ `plans/experiments/*` files are untracked too.
  - Only the CP1 and CP2 plans, `agents/*` and `design/*` are tracked.
- **There is no roadmap after CP5, and there are no CP3 or CP4 plan files.**
  - Contract §11 (`LOOM-PRODUCT-CONTRACT.md:284-302`) lists CP1 to CP5 with one-line "done when" evidence.
  - It sets the order "1 → 2 → 5's terminal engine and first window → 4 → 3".
  - So CP4 (deletion and retention) is next and CP3 (authorised coordination) is last.
  - Neither has a plan file. They exist only as table rows and in §7, §8 and §13.
  - `AGENTS.md` item 2 ("do not treat the highest checkpoint number as current") is a workaround for this numbering mismatch.
- **There is no README.md and no CLAUDE.md.** Claude Code does not load `AGENTS.md` natively. Whether it loads here is unknown.
  - The user's global `~/.claude/CLAUDE.md` imports `~/.codex/AGENTS.md`, but it does not import the repo's `AGENTS.md`.
  - A subagent started from a Brief only sees `AGENTS.md` if it reads the file itself.
  - `STATUS.md` itself says "Sıradaki rol: planner-reviewer: doküman güncellemeleri…", so a doc update is already queued.

## 1. Minimal startup reading path today

Lines, bytes and a rough category for each file:

| Step | File | Lines / bytes | Content | History noise |
|---|---|---|---|---|
| 1 | `AGENTS.md` | 46 / 6.2 KB | process, roles, closure rules | none |
| 2 | `STATUS.md` | 11 / 1.9 KB | position | none, but see below |
| 3 | `agents/README.md` plus your role file | 11 + 14 to 26 | roles | none |
| 4 | `DEVELOPMENT.md` | 43 / 5.8 KB | checks, isolation, signing, measurement | low |
| 5 | `plans/CHECKPOINT-5.md` | 69 / 11.8 KB | goal, acceptance table A1 to D6, open work | medium: acceptance rows carry per-run numbers |
| 6 | `plans/cp5/UI.md` (the STATUS "slice") | 74 / 14.5 KB | UI plan plus about 25 KB-equivalent of dated result paragraphs | high |
| 7 | contract §1, §3, §10, §11 | about 110 of 325 lines (40.7 KB total) | purpose and decisions | medium |
| 8 | `design/DESIGN.md` §2, §3, §5 | about 40 of 80 lines | UI | §4 is a legacy inventory, "not a Loom requirement" |
| 9 | code orientation | none | none exists | n/a |

- **Cost:** a fresh session reads roughly 450 lines and about 70 KB (about 20 to 25k tokens, my inference for Turkish text) before touching code.
- **Where the history noise is:** items 5 to 7. Only `STATUS.md` and the process docs (items 1 to 4, about 14 KB) are clean.
- **Reaching the real current state costs far more.**
  - STATUS links into `CLOSURE.md` (37 KB, 210 lines) and `PERF.md` (28 KB).
  - `plans/cp5/C.md` is 180 KB, 875 lines and 34 numbered sections of review ping-pong. `CHECKPOINT-5-HISTORY.md` is 152 KB.
- **History weight in `plans/`:**
  - Plan markdown totals about 605 KB across 3,580 lines. That is roughly 15 times the startup path.
  - `plans/experiments/` is 2.1 MB in 135 files, with 4 JSON files of about 10k lines each.
- **Items missing from the path:**
  - No purpose summary shorter than contract §1 plus §3.
  - No code map. The only code facts are the `Package.swift` target list, `Vendor/SwiftTerm/LOOM-VENDOR.md`, and scattered mentions inside plans.
  - No UI map covering the source layout, window and sidebar structure, or where evidence screenshots live.

For scale, `Sources/` holds about 22k lines: LoomCore 11.6k, LoomCatalogUI 2.6k, loom-probe 2.4k, loom-app 1.7k, LoomTerminal 0.5k. `Tests/` holds about 12.9k lines: LoomCoreTests 9.8k, LoomTerminalTests 1.6k, LoomCatalogUITests 1.5k.

**Stale or inconsistent items found (count: at least 9)**

1. `STATUS.md:3-4` is internally mixed.
   - The slice line still says "UI cila … ardından optimizer ve PERF son büyük test".
   - The status line says optimizer pass 3 is done and package I is verified, and that the status is "kullanıcı kararı bekleniyor".
   - Two states are encoded in one line.
2. `CHECKPOINT-5.md` slice row PERF says "paket F app CPU 31,5→26,3, CPU40 hâlâ başarısız; … P3 sırada (duraklatıldı)".
   - Per `PERF.md:131-154`, package H and I passed CPU40 (total 26.8%, then 25.4 to 25.6%).
   - P3 and P3-S are done.
3. The `CHECKPOINT-5.md` "Birleşik inceleme" and "A kaynak kabulü" rows still describe "D23 valid / CPU40 failed" and "ASCII candidate runtime unverified".
   - That is the 3 Oct state. It is stale after H and I.
4. The contract header says "Güncelleme: 2 Ekim 2026" and "uygulama ve teknik kabul deneyleri henüz tamamlanmadı".
   - The contract also contains 3 Oct and 6 Oct decisions (§3, §10, DESIGN §5 amendments).
5. Contract §11 labels CP5 "Görsel deneyim ve performans".
   - `plans/CHECKPOINT-5.md` is titled "Terminal motoru ve ilk pencere".
   - The "28 Eylül 2026 durumu" paragraph in §11 only reports CP2 done.
   - There is no CP5 status line in the contract.
6. Contract §2, the document map, omits `plans/cp5`, the HISTORY file, `Vendor/`, `patches/` and `scripts/`.
   - `scripts/` has 17 files, no README, and a `dev-paths.sh` that contains the real operating constraints.
7. Contract §6 (lines about 155 to 172) holds CP1 and CP2 narrative inside a contract. It reads as history, not decision.
8. `DESIGN.md` §2 says some elements stay as designed, and §5 overrides some of them.
   - The reader must merge the two by hand.
   - §4 is explicitly "not requirement" but sits in the contract-level design doc.
9. `UI.md` result paragraphs are chronological (U-A, U-B, UA-3, O-1…O-4, UA-5, UA-6, final I).
   - Items superseded in later paragraphs stay in place.
   - Example: UA-5 gates the indicator on Reduce Motion, and UA-6 removes that gate.

## 2. Gaps that hurt a large swarm

| Gap | Observation | Why it matters |
|---|---|---|
| **Roadmap / next checkpoints** | None. CP4 and CP3 are one-liners. The contract lists post-CP5 open decisions only in §12 (exit boundary, communication path, data contract, cleanup arithmetic, budgets). | The swarm "planning the next step" has no authoritative backlog, scope or sequencing to plan from. |
| **Uncommitted base** | See §0: about 190 entries including the process docs and the whole vendor tree. No checkpoint tag or branch for CP5. | Any swarm that reverts, stashes or re-checks-out destroys CP5. No baseline exists for review diffs ("what did this swarm change"). Rule needed: user-authorised checkpoint commit before the swarm. This is the user's decision (AGENTS.md: commit only when asked). |
| **Per-area owners / write ownership** | `UI.md` has a job table with write areas (e.g. U-A `Sources/LoomCatalogUI/*` minus `DetailView`, U-B `DetailView` plus `LoomTerminal`). It lives inside a slice file and is dated. | There is no standing ownership map. The shared tree has big files: `LoomCore` is 11.6k lines across about 50 files. No rule for who edits `Package.swift`, `LOOM-VENDOR.md` or `patches/`. |
| **Concurrency in one working tree** | `AGENTS.md` only says "share the tree, preserve others' changes", and `PERF.md:30` says use a separate `--scratch-path`. No rule on serialising `swift build` and `swift test` (SwiftPM `.build` lock), who owns the full suite, or what to do when two agents hit one file. | Parallel builds contend on `.build` and heat the laptop. Both are real here: `.build` exists, and `loom_default_scratch=$HOME/Library/Caches/loom-dev-build` exists in `scripts/dev-paths.sh`. |
| **Verify without touching the user's installed app** | The mechanism exists but is scattered: `DEVELOPMENT.md` states real `~/.claude`/`~/.codex` are read-only and isolated profiles are used. `UI.md` O-1 adds `--data-root` and evidence mode (always an isolated root). `package-dev-app.sh` refuses a running target (exit 3). | `DEVELOPMENT.md` does not mention `--data-root`, evidence mode, the installed `Loom Dev.app`, or `~/Library/Application Support/Loom-Dev/{app,probe,runs,packages}`. Paths under `~/Documents` are forbidden for packages and scratch (TCC), and that rule is only in a script comment and `OWN.md`. |
| **Budget / heat rules for tests** | `PERF.md:98` is a user decision (4 Oct): no heavy tests or measurements during development, deferred to one "final big test" the user starts. `DEVELOPMENT.md:5` says full suite only at closure or after a big revision. Measurement conditions (screen unlocked, no concurrent build, cooldown 90 to 120 s, fanless Mac14,2) are in `DEVELOPMENT.md` "Ölçüm" and `PERF.md`. | A swarm "test and improvement" run contradicts that 4 Oct decision unless it is explicitly renewed. `AGENTS.md` and `STATUS.md` link the decision only through `STATUS.md:6`. |
| **Doc-update rules** | `AGENTS.md` says the planner-reviewer updates `plans/…` and `STATUS.md` and subagents "do not write" them. `implementer.md` forbids touching contract, plans and STATUS. | There is no map of which doc a given change must update. Design changes go to `DESIGN.md` and the contract, but no rule says so. A swarm with N implementers needs a rule for per-slice notes and who merges them. |
| **Decision authority** | `AGENTS.md:42` says contract §3 changes need a user decision. | `DESIGN.md` and `STATUS.md` are not covered. The `UI.md` rule "authorised for certain UI/UX, code and optimisation improvements; ambiguous design choices and navbar go to the user" is slice-scoped and per-user-statement. |
| **Closure ritual** | An optimizer pass (Opus 5.5 xhigh, read-only) is mandatory before checkpoint close. | Fine for CP-level. A swarm of parallel slices has no "slice-level light review" rule. |

## 3. Role mapping: `AGENTS.md` vs Claude Code agent types and workflow swarms

| Loom role (`agents/*.md`) | Claude Code type available | Match | Friction |
|---|---|---|---|
| **planner-reviewer** (main agent, plans, accepts, owns records) | main session (no subagent type) | OK | Name is `reviewer.md` for historical link reasons (README says so). The `description` front matter is "loom-planner-reviewer" but `~/.claude/agents/reviewer.md` is a different, code-review role; a reader sees two "reviewer"s. |
| **implementer** | `~/.claude/agents/implementer.md` (Sonnet, high, no Agent tool) | Good: a Brief and report, write ownership, no commit unless the Brief authorises | Loom's `agents/implementer.md` is not loaded by Claude Code (front matter `name: loom-implementer`, not in `~/.claude/agents`). The Brief must restate its Loom rules. |
| **researcher** | `explorer` (Sonnet, high, read-only) | Mentioned in `AGENTS.md` ("implementer, araştırmacı ve optimizer"), no `agents/researcher.md` exists | A role named in policy but not defined in `agents/`. |
| **optimizer** | closest: `strict-reviewer` (Opus, xhigh, read-only), or `reviewer` (Opus, high) | The model setting matches: repo mandates "Opus 5.5 / xhigh" or `gpt-6-astra` / high | `strict-reviewer` is "correctness / high-risk" in its role text, not structure and resource review. The Loom optimizer prompt has to be pasted into the Brief. Its description says "only on explicit user request", so the user authorisation has to be explicit per run. |
| (none) | `advisor`, `verifier` | Not referenced in repo docs | `verifier` is a good fit for the "doğrulandı / başarısız / doğrulanmadı" ritual, but the repo never names it. It is also "only on explicit user request". |

Frictions, concretely:

1. **Report format.**
   - Loom wants `Status / Result / Evidence / Unverified / Needs` headings and messages sent directly to the planner-reviewer.
   - The global default says "no fixed headings". In a workflow script the final message is the return value. A subagent cannot message anyone during the run.
   - So "bulgularını doğrudan mesajla ilet" and "rapor başlıkları" have to be restated per Brief for swarm use.
2. **Who may spawn.** Global rules: reviewer, strict-reviewer, verifier and advisor start only when the user asks. Loom's `AGENTS.md`: the planner-reviewer starts implementers, researchers and optimizers directly.
   - Precedence is "user > repo > project card > global defaults", so repo wins for the loom roles.
   - For the reviewer types the user must say so in chat. That authorisation is not durable and not written anywhere.
3. **Mandatory model and effort.** The repo mandates an optimizer at `gpt-6-astra` / high or Opus 5.5 / xhigh. Claude Code role files carry `model: opus`, `effort: xhigh` for `strict-reviewer`.
   - Whether `opus` currently resolves to 5.5 is not verifiable from the files.
4. **Ultracode / workflow swarm vs the slice model.** `AGENTS.md` assumes one planner-reviewer who delegates and reads, then updates the persistent records.
   - A script-driven swarm often has no planner-reviewer, so nobody owns `STATUS.md`.
   - Rule needed: the main session (or one named agent) is the only writer of `STATUS.md` and plans.
5. **Language.** The repo process docs are Turkish and user-facing replies are Turkish. Brief and Report text may be English (this audit). Nothing says so for agent-to-agent text.
6. **Native tool constraints.** A subagent in this environment cannot spawn agents and cannot use a Loom-specific `agents/*.md` file. The `agents/` directory is therefore documentation only for Claude Code.

## 4. Where durable user decisions live, and would a log help?

Today decisions sit inside dated sentences in at least 7 places:

- Contract §3 table (about 25 rows; dates only on some). It also holds §10 (3 Oct %40 CPU cap) and §11 order.
- `AGENTS.md:36` (3 Oct optimizer model, Opus 5.5 xhigh accepted).
- `DEVELOPMENT.md:23` (2 Oct real-provider tests without asking), `DEVELOPMENT.md` signing paragraph (3 Oct).
- `STATUS.md:6-7` (4 Oct Codex paused, 4 Oct heavy tests deferred), linking into `PERF.md` anchors.
- `PERF.md:89-105` (the same two decisions, in full).
- `UI.md` (5 Oct feedback list, 6 Oct Reduce Motion decision in a result paragraph), and `DESIGN.md` §5 (restates the UI decisions).
- `CHECKPOINT-1.md`, `CHECKPOINT-2.md`, `CHECKPOINT-5-HISTORY.md` §23 etc. (28 Sep).

A grep for "kullanıcı kararı" counts about 40 hits across the docs. Quantities: contract 9, `C.md` 6, `HISTORY` 6, `PERF.md` 5, `CP1` 3, `AGENTS.md` 3.

**Inference:** a single decision log would help.

- A fresh agent cannot answer "is Codex paused?" or "may I run real Claude tests?" without finding those sentences.
- `STATUS.md` already carries two decisions as links into 28 KB and 37 KB files.
- Open decisions (numeric budgets, deferring Codex items, navbar, GPU4, Finder drop) are listed only in `STATUS.md`, with no stable IDs.

What the log should hold: one line per decision (ID, date, decision, scope, link to the evidence or plan anchor), plus an "open decisions" section. It should not replace contract §3, which is the product-decision table, and should be the process and scope companion. Possibly the log's job is only index and pointers while contract §3 and `DESIGN.md` stay authoritative for product rows.

## 5. Proposed target doc set

Principle: `STATUS.md` stays the single position source. Startup path is at most about 250 lines. History stays in `plans/` and is never on the startup path.

| File | Purpose | Max size | Owner | Update trigger |
|---|---|---|---|---|
| `CLAUDE.md` (repo root) | Native Claude Code entry. 10 lines: "read `AGENTS.md`, then `STATUS.md`", plus the 5 hard rules (read-only on real `~/.claude`/`~/.codex`, no heavy tests, no commit unless asked, shared tree, STATUS single writer). It can `@AGENTS.md`-import. | 15 lines | planner-reviewer / main | Rule change only |
| `README.md` | Product in 15 lines: purpose, platform, how to run isolated, link to `docs/`. | 40 lines | main | Product change |
| `AGENTS.md` (trim) | Workflow, roles, closure, swarm rules (see below). Stays the process authority. | 80 lines | main | Process change |
| `STATUS.md` | Position only: checkpoint, slice, state, next owner, links, blocker. No two-state lines. | 15 lines | main, end of each round | Every round |
| `ROADMAP.md` (new) | Checkpoints 1 to 5 plus CP4, CP3 and "pre-prod": goal, entry condition, "done when" (from contract §11), size, open decisions, order. The swarm plans from this. | 100 lines | main, with user decisions | Checkpoint open / close, scope decision |
| `DECISIONS.md` (new) | Dated user-decision log with IDs, plus an open-decisions list. Links to evidence. Contract §3 stays product authority; this adds process, scope and budget. | 120 lines; archive older than a checkpoint | main only | Whenever the user decides something |
| `docs/ARCHITECTURE.md` (new) | Code map: targets (13 in `Package.swift`), dependency direction, key types per module, process/ownership model in a few lines, vendored SwiftTerm and patch stack, scripts, tests and how to find them. | 150 lines | any agent that changes structure (rule: "if you add a target or move a responsibility, edit this") | Structural change |
| `docs/UI.md` (new) | UI map: window and sidebar structure, state language (from `DESIGN.md` §5), geometry, where evidence screenshots and the isolated data root live. | 100 lines | UI implementer | UI change |
| `DEVELOPMENT.md` (extend) | Add: evidence mode and `--data-root`, installed-app protection, `Loom-Dev` paths, no `~/Documents`, heat and budget rules, parallel build rules, who owns the full suite. | 70 lines | main | Tooling change |
| `LOOM-PRODUCT-CONTRACT.md` | Keep. Fix header date and status, refresh §2 map, add a current CP5 status line, move CP1/CP2 narrative from §6 to history. | 325 lines is fine; plan for <300 | main (user for §3) | Product decision |
| `design/DESIGN.md` | Keep. Merge §5 overrides into §2 so there is one list. Label §4 clearly as legacy inventory. | 80 lines | main | Visual decision |
| `plans/CHECKPOINT-<n>.md` and `plans/cp<n>/*` | Unchanged: goal, acceptance, slices, closure. Mark them history for all but the active checkpoint. | existing | main | Per `AGENTS.md` |
| `plans/ARCHIVE-INDEX.md` (optional) | A 20-line map from topic to history file, so nobody opens `C.md` by accident. | 30 lines | main | When a checkpoint closes |

Startup path after the change: `CLAUDE.md` + `STATUS.md` + `AGENTS.md` + `ROADMAP.md` + role file ≈ 230 lines. Add `docs/ARCHITECTURE.md` or `docs/UI.md` only when the task needs them. That is about 3 times smaller than today's path, with no history file in it.

Swarm rules to add to `AGENTS.md` (these are the gaps from §2):

1. Checkpoint commit before the swarm. This needs the user's explicit request, per `AGENTS.md`.
2. Single writer for `STATUS.md`, `ROADMAP.md`, `DECISIONS.md` and plans. Subagents put findings in their Report.
3. Write-ownership table by directory: `LoomCore`, `LoomTerminal` plus `Vendor` and `patches`, `LoomCatalogUI`, `loom-app`, scripts, tests.
4. Per-agent `--scratch-path` and one owner for the shared suite. No concurrent heavy build or test.
5. Heat and budget rules, with a renewal of the 4 Oct "no heavy tests" decision if the swarm should run any.
6. Brief template that restates the report headings and the role definitions that `~/.claude/agents` does not carry.

## Unverified

- Whether Claude Code loads `AGENTS.md` here at all. I assumed it does not natively.
- Whether `opus` in the role files resolves to Opus 5.5.
- The vault project card for Loom was not read. The Brief does not allow reading the vault.
- Token estimates are approximate; byte and line counts are exact.
- Doc line counts and the 190-entry git status are from today's tree. Other agents share the tree, so the numbers can drift.

## Key paths

- `/Users/gencberke/Documents/github/loom/AGENTS.md`
- `/Users/gencberke/Documents/github/loom/STATUS.md`
- `/Users/gencberke/Documents/github/loom/DEVELOPMENT.md`
- `/Users/gencberke/Documents/github/loom/LOOM-PRODUCT-CONTRACT.md` (§3, §10, §11, §12)
- `/Users/gencberke/Documents/github/loom/design/DESIGN.md` (§2, §4, §5)
- `/Users/gencberke/Documents/github/loom/agents/*.md`
- `/Users/gencberke/Documents/github/loom/plans/CHECKPOINT-5.md`
- `/Users/gencberke/Documents/github/loom/plans/cp5/UI.md`
- `/Users/gencberke/Documents/github/loom/plans/cp5/PERF.md` (lines 89-105 for the 4 Oct decisions, 131-154 for H and I results)
- `/Users/gencberke/Documents/github/loom/scripts/dev-paths.sh`
- `/Users/gencberke/Documents/github/loom/Vendor/SwiftTerm/LOOM-VENDOR.md`
- `/Users/gencberke/.claude/agents/*.md`