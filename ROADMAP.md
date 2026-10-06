# Roadmap

Path from today to Loom's first production release. Checkpoint numbers are identities, not order ([D-02](DECISIONS.md)). Rows marked **proposed** are the main agent's draft and wait for the user; they are not decisions. The current position is only in [STATUS.md](STATUS.md).

## Release target

**First production release:** a signed macOS 27 app (signing and notarization form: O-06) for one power user that hosts real Claude Code terminals in the accepted design and identity, with verified process ownership, state, resume, Stop and Quit, inside the agreed resource budgets. Codex is not included ([D-14](DECISIONS.md)). Other providers, child-task view, Dock/menu-bar notifications and the ideas in contract §13 are out unless the user adds them.

## Stages

| Stage | Goal | Done when | State |
| --- | --- | --- | --- |
| CP1 Ownership and launch | Loom owns exactly the processes it starts | [CP1 plan](plans/CHECKPOINT-1.md) acceptance | closed |
| CP2 State and resume | Identity, turn, error and approval sources; safe idle; same-conversation resume | [CP2 matrix](plans/CHECKPOINT-2.md) | closed |
| CP5 Terminal engine and first window | Usable window with real Claude terminals in the preserved design | [CHECKPOINT-5](plans/CHECKPOINT-5.md) acceptance verified; optimizer done | closed 6 Oct ([D-23](DECISIONS.md)); Codex-only items in the [Codex backlog](plans/cp5/CODEX-BACKLOG.md) |
| L Clean loom line (**proposed**) | Daily-use `Loom.app` built only from a clean loom tree ([D-25](DECISIONS.md)) | See below | not started; details wait for O-11 |
| F Foundation hardening (**proposed**) | Make the base safe for parallel feature work and production | See below | not started |
| I Identity and UI system (**proposed**) | Codify identity direction A ([D-22](DECISIONS.md)) as tokens and rules; settle the navbar | See below | direction chosen; navbar waits for O-03 |
| CP4 Deletion and retention | Contract §5 and §8: stale, retention, safe deletion, recovery | Contract §11 row 4 | not started; first-release need is O-05 |
| CP3 Authorized coordination | Contract §7: delegated hand-off between sessions under user authority | Contract §11 row 3 | not started; first-release need is O-05 |
| R Release readiness (**proposed**) | Ship the first production release | See below | waits for O-05, O-06 |

### L: Clean loom line (proposed)

Model and rules: [DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree).

- Decide O-11 (location, history, versioning, signing for the daily app).
- A promote script in loom-dev: export an allowlist from a tag, generate the release-only `Package.swift`, commit into loom.
- A build script in loom that produces a signed `Loom.app` with the production identity and its own data paths, and a short install note.
- First daily build from the CP5 state; verify on it: launch, a real Claude conversation, Stop, Quit with no leftover process, and that Loom-Dev data is untouched.

Done when: the user runs the daily `Loom.app` built from loom, and loom contains only product sources, assets, the release manifest, its one build script and README — no tests, plans, experiments or dev tooling.

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

### R: Release readiness (proposed)

- Distribution (O-06): Developer ID signing, notarization, production bundle identity and data paths, versioning from tags instead of the commit hash, an update approach.
- First-run experience: provider CLI detection, missing-CLI and launch errors, empty states.
- Crash and Force Quit guarantees stated and tested (contract §12.1).
- Resource budgets (O-01) enforced by a repeatable measurement.
- Release checklist: full suite, real-Claude check, perf matrix, clean install on a fresh user account.

Done when: the checklist passes on the release candidate and the user accepts it.

## Order (proposed)

L (first daily build) → F → I (can overlap with F where write areas are disjoint) → CP4 and/or CP3 as O-05 decides → R. Codex returns after the first release, starting from the [Codex backlog](plans/cp5/CODEX-BACKLOG.md).
