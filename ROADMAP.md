# Roadmap

Path from today to Loom's first production release. Checkpoint numbers are identities, not order ([D-02](DECISIONS.md)). Rows marked **proposed** are the main agent's draft and wait for the user; they are not decisions. The current position is only in [STATUS.md](STATUS.md).

## Release target

**First production release:** a signed macOS 27 app (signing and notarization form: O-06) for one power user that hosts real Claude Code terminals in the accepted design and identity, with verified process ownership, state, resume, Stop and Quit, permanent deletion of a conversation and the CP4 retention rules ([D-26](DECISIONS.md)), inside the agreed resource budgets. Codex is frozen and not included ([D-14, D-28](DECISIONS.md)); CP3 coordination is not included ([D-27](DECISIONS.md)). Other providers, child-task view, Dock/menu-bar notifications and the ideas in contract §13 are out unless the user adds them.

## Stages

| Stage | Goal | Done when | State |
| --- | --- | --- | --- |
| CP1 Ownership and launch | Loom owns exactly the processes it starts | [CP1 plan](plans/CHECKPOINT-1.md) acceptance | closed |
| CP2 State and resume | Identity, turn, error and approval sources; safe idle; same-conversation resume | [CP2 matrix](plans/CHECKPOINT-2.md) | closed |
| CP5 Terminal engine and first window | Usable window with real Claude terminals in the preserved design | [CHECKPOINT-5](plans/CHECKPOINT-5.md) acceptance verified; optimizer done | closed 6 Oct ([D-23](DECISIONS.md)); Codex-only items in the [Codex backlog](plans/cp5/CODEX-BACKLOG.md) |
| L Clean loom line | Daily-use `Loom.app` built only from a clean loom tree ([D-25, D-29](DECISIONS.md)) | [Stage L plan](plans/STAGE-L.md) | in progress (before the multi-agent run) |
| F Foundation hardening (**proposed**, multi-agent run) | Make the base safe for parallel feature work and production | See below | not started |
| I Identity and UI system (**proposed**, multi-agent run) | Codify identity direction A ([D-22](DECISIONS.md)) as tokens and rules; settle the navbar | See below | direction chosen; navbar waits for O-03 |
| CP4 Deletion and retention (multi-agent run) | Contract §5 and §8: permanent deletion first, then stale, retention and cleanup; recovery from half-done deletes | Contract §11 row 4 | in first-release scope ([D-26](DECISIONS.md)); not started |
| CP3 Authorized coordination | Contract §7: delegated hand-off between sessions under user authority | Contract §11 row 3 | out of the multi-agent run and the first release ([D-27](DECISIONS.md)); maybe a later test-environment trial |
| R Release readiness (**proposed**) | Ship the first production release | See below | waits for O-06 |

### L: Clean loom line

Model and rules: [DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree); plan and acceptance: [plans/STAGE-L.md](plans/STAGE-L.md). Runs before the multi-agent run so that every later release has a clean daily build path.

### F: Foundation hardening (proposed)

Facts behind it are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (hotspots) and the [CP5 optimizer passes](plans/cp5/CLOSURE.md).

- Production build excludes Codex surfaces (menu items, context menus, `--codex-home`), keeping the code paused behind one switch.
- Quit and shutdown no longer route through the CP5-A synthetic `TerminalRunController`.
- Evidence and fixture code is separated from production paths without losing the evidence tooling.
- Large actors (`ProcessSupervisor`, `SessionRuntime`, `SessionCatalog`) are split where a change would otherwise touch unrelated responsibilities, with no behavior change.
- One local command runs the required checks (no CI exists); perf scripts in `scripts/perf/` reproduce the CP5 matrix.
- Deferred optimizer items (F6, F8–F10, S2, S4, S-C) are taken or explicitly dropped.

Done when: behavior is unchanged (full release suite plus a real-Claude check), the CP5 performance baseline holds, and the architecture doc matches the code.

### I: Identity and UI system (proposed)

- Direction A from [the identity proposal](design/IDENTITY-PROPOSAL.md) is chosen; its open sub-decisions are settled, tokens move into one Swift source and the rules into [design/DESIGN.md](design/DESIGN.md).
- Measure the indicator's WindowServer cost (CP5 optimizer R-A) and apply the 10 fps frame-rate hint if it matters.
- The theme rewrite removes the dead `CatalogTheme` constants (CP5 optimizer S-B).
- Navbar layout is decided (O-03) and built.
- Every surface in [design/UI-MAP.md](design/UI-MAP.md) is reviewed against the identity; accessibility pass (contrast, keyboard, Reduce Motion/Transparency).

Done when: the user accepts the result on a package, evidence screenshots match the rules, and indicator and render costs stay at baseline.

### CP4: Deletion and retention (multi-agent run)

- Permanent deletion of one conversation first: its local Claude data only, never another conversation's; half-done deletes recover; late events never bring a deleted conversation back (contract §8).
- Then stale handling, retention and cleanup: monthly cleanup of eligible stale conversations, at least 15 days stale, exceptions (pinned, protected worktrees), list-and-confirm after a long absence (contract §3, §5).
- Open inputs: contract §12 items 3–4 (deletion data contract, cleanup arithmetic; [O-09](DECISIONS.md)).

Done when: contract §11 row 4 evidence passes on synthetic data and a real-Claude deletion check, with no harm to other conversations.

### R: Release readiness (proposed)

- Distribution (O-06): Developer ID signing, notarization, production bundle identity and data paths, versioning from tags instead of the commit hash, an update approach.
- First-run experience: provider CLI detection, missing-CLI and launch errors, empty states.
- Crash and Force Quit guarantees stated and tested (contract §12.1).
- Resource budgets (O-01) enforced by a repeatable measurement.
- Release checklist: full suite, real-Claude check, perf matrix, clean install on a fresh user account.

Done when: the checklist passes on the release candidate and the user accepts it.

## Order (proposed)

L (now, before the multi-agent run) → multi-agent run (authority [D-30](DECISIONS.md); the prompt is kept by the user outside the repo): F, I and CP4 in parallel where write areas are disjoint, with UI/UX, architecture/scalability and performance evaluations along the way → R. Each verified state can be promoted to the daily app through L's path. Codex returns after the first release, starting from the [Codex backlog](plans/cp5/CODEX-BACKLOG.md); CP3 may be tried after that.
