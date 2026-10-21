# Loom agent workflow

Loom is a native macOS 27 app that hosts real Claude Code sessions, in their terminal or as a native chat, in one window ([README](README.md)). This file is the process authority for every agent session in this repo. The user's chat request wins over it; it wins over personal defaults.

## Start of every session

1. Read [STATUS.md](STATUS.md) (where we are), this file, and [ROADMAP.md](ROADMAP.md) (where we are going). Check [DECISIONS.md](DECISIONS.md) before assuming scope, budgets or permissions.
2. Read what the task needs, and no more: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for code, [design/DESIGN.md](design/DESIGN.md), [design/reference.html](design/reference.html) and [design/UI-MAP.md](design/UI-MAP.md) for UI, [DEVELOPMENT.md](DEVELOPMENT.md) before building, testing, packaging or measuring, the [product contract](LOOM-PRODUCT-CONTRACT.md) for product behavior. History in `plans/` is read only when a task points to it ([plans/README.md](plans/README.md)).
3. Run `git status`; keep every change you did not make.
4. A subagent takes its work only from its Brief, never from STATUS.

## Roles

| Role | Who | Claude Code agent type |
| --- | --- | --- |
| Planner-reviewer ([role](agents/reviewer.md)) | The main session. Plans, delegates, accepts or rejects, owns the canonical records. | main session |
| Implementer ([role](agents/implementer.md)) | Delivers one bounded change in its assigned write area and verifies it. | `implementer` |
| Researcher | Read-only investigation of code, evidence or external sources. | `explorer` |
| Optimizer ([role](agents/optimizer.md)) | Mandatory read-only structure and resource review before a checkpoint closes. | `strict-reviewer` with the optimizer Brief |

The optimizer runs on `gpt-6-astra` / `high`, or in Claude Code on Opus 5.5 / `xhigh` ([D-06](DECISIONS.md)); never lower. If neither setting is available, tell the user; a review on another model does not count as the closing optimizer review. The planner-reviewer starts implementers, researchers and the closing optimizer without asking the user; other review roles (`reviewer`, `verifier`, `advisor`) start only when the user asks. Subagents never start agents. Claude Code does not load `agents/*.md`, so the Brief restates the role rules a subagent needs.

## Delegation

**Brief:** Goal / Context / Scope (write ownership and out-of-scope) / Done when / Checks. Include the decisions and file paths needed to act, any experiment or real-model budget, and the reminder that other agents share the tree. Do not rely on the subagent reading chat history or plan archives.

**Report:** Status / Result / Evidence / Unverified / Needs (one line each for short work), plus **Doc impact**: which canonical docs the change makes untrue. Evidence is labelled verified, failed or unverified. A reported implementation is not an accepted one.

Independent work runs in parallel only with disjoint write areas; tightly coupled work is not split. The planner-reviewer reviews changes and decisive evidence, sends gaps back to the same subagent, and makes routine technical decisions itself. Only product choices, scope and permissions go to the user.

## Multi-agent and swarm rules

- **Write ownership.** Every Brief names the files or directories an agent may edit. Default areas: `Sources/LoomCore` + `Sources/CLoomPOSIX` + `Sources/CLoomTestSupport`, `Sources/LoomTerminal` + `Vendor/` + `patches/`, `Sources/LoomChat`, `Sources/LoomCatalogUI`, `Sources/loom-app` + `Sources/LoomLaunchOptions`, helper executables, `scripts/`, and the matching `Tests/` targets. `Package.swift`, `Vendor/SwiftTerm/LOOM-VENDOR.md` and canonical docs have one owner per round.
- **Shared tree.** Never `git stash`, `checkout`, `reset`, `clean` or revert work you did not make. No commits, pushes or PRs unless the user asked in chat ([D-16](DECISIONS.md)); a plan that calls for one is not authority.
- **Builds and heat** ([D-13](DECISIONS.md)). No parallel builds. Each agent uses its own `--scratch-path` outside `~/Documents`. One named agent runs the full suite on the combined result. Heavy measurements and tests that put windows on screen run only when the user says the computer is idle. Details: [DEVELOPMENT.md](DEVELOPMENT.md).
- **User data.** Real `~/.claude` and `~/.codex`, the installed `Loom Dev.app`, the default dev catalog, and the daily `Loom.app` with its data are never test material. The clean loom tree is written only by the promote step ([DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).
- **Workflows.** A scripted multi-agent run has a named owner (the main session) who alone writes STATUS, ROADMAP, DECISIONS and plans, and who reviews the combined result before anything counts as accepted.

## Keeping docs true

Docs are the memory that lets the next session continue; they are not a message channel. Each doc has an owner and a trigger:

| Doc | Owner | Update when |
| --- | --- | --- |
| STATUS.md | planner-reviewer | End of every round: position, next owner, links, blocker. Position only, no history or numbers. |
| ROADMAP.md | planner-reviewer | A stage opens or closes, or scope changes. |
| DECISIONS.md | planner-reviewer | The user decides something in chat. |
| LOOM-PRODUCT-CONTRACT.md | planner-reviewer | Product decision by the user; §3 changes only with the user's decision. |
| docs/ARCHITECTURE.md | implementer who changes structure, checked at review | New target, moved responsibility, new process type, new vendor patch. |
| design/DESIGN.md (Ink, v3: the target), design/UI-MAP.md (what the code draws) | UI implementer, checked at review; rule changes only with a user decision | DESIGN.md: a new or changed rule, surface, token, state or interaction. UI-MAP.md: any change to a surface in code, each Ink migration step included. |
| design/reference.html, design/landing.html (built from design/reference-src/) | planner-reviewer | A design decision that changes a surface: its document in `reference-src/docs/` changes with DESIGN.md, and `build.py` writes both pages. Never edited by hand. |
| design/pre-reference-preview-pages/ | none (a record) | Never. The accepted previews 01 to 07 and identity (D-74 to D-81) as they stood before the reference; not the visual target. |
| DEVELOPMENT.md, scripts/README.md | whoever changes tooling, checked at review | New command, flag, script, path or policy. |
| plans/V2-PLAN.md and its specs in plans/v2/ (earlier checkpoints: plans/CHECKPOINT-n.md, plans/cpn/*.md) | planner-reviewer | Plan, slice decisions, acceptance results, closure. |

A subagent edits a canonical doc only inside its Brief's write area; otherwise it lists the needed change under Doc impact and the planner-reviewer applies it. Changing a design rule (not just describing the UI) needs a user decision. Before writing any record, re-read its latest content.

Record content rules:
- `STATUS.md` is the single source of the current position: date, stage or checkpoint, slice, state, next owner, work link, latest result link, blocker. If the position did not change, leave it. No history, numbers or decisions.
- `plans/V2-PLAN.md` is the active plan: goal, releases and their slices, acceptance criteria, open work, and each release's evaluation and closure. `plans/v2/*.md` holds the specs the slices build to. Briefs, diffs and run evidence live under `~/Library/Caches/loom-v2/evidence/`. Earlier checkpoints kept the same records in `plans/CHECKPOINT-n.md` and `plans/cpn/<slice>.md`, with closure in `plans/cpn/CLOSURE.md`.
- Experiment files under `plans/experiments/` (or the probe directory) hold detailed measurements and evidence; a subagent may write the evidence files its Brief assigns. Raw logs and whole-diff narratives are not copied into plans.
- Records state the current truth; a superseded entry gets a short new entry pointing at the old one instead of being rewritten. No per-message or per-round reports. Hand-off or correspondence instructions in old plan files are historical; this file is the current way of working.

## Status values

**waiting for planning**, **waiting for implementation**, **waiting for review**, **waiting for optimization**, **waiting for user decision**, **done**. "Waiting for implementation" does not mean waiting for a separate user session: within authorized scope the planner-reviewer starts the subagent and follows it. On resume, check running subagents before starting new ones and never restart the same work.

## Checkpoint closure

In the v2 plan a checkpoint is a release (A, B, C …). Every slice passes the planner-reviewer's behavior and acceptance review. The optimizer is not run per slice; it is mandatory before a checkpoint closes, and an earlier review happens only for a concrete structural or resource problem. The planner-reviewer verifies its decisive findings and records the result in the checkpoint's closure record. A checkpoint closes when acceptance is verified, the optimizer review is done and blocking findings are closed. After a fix, re-verify only the affected acceptance and findings. Improvement suggestions are not new scope or closure blockers unless the planner-reviewer justifies it.

## Language and communication

Repository docs, code, identifiers and commit messages are English ([D-15](DECISIONS.md)). Talk to the user in short, plain Turkish and link evidence in the records. Older plan and history files remain in Turkish as written.
