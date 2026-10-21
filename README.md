# Loom

Loom is a native macOS 27 app for running real Claude Code sessions side by side in one window: a sidebar of projects and sessions with live status, and the selected session either in its terminal, exactly as Claude Code draws it, or in a native chat over the same CLI. Loom launches and owns each CLI session in its own process scope, tracks its state (working, waiting for you, finished), resumes past sessions, and stops everything it started on Quit. From 1.6.0 the app is named Sphyrna ([D-77](DECISIONS.md), [D-83](DECISIONS.md)); the code keeps the name Loom.

For one power user on macOS 27. Out of scope for 1.6.0: Codex, other providers, and coordination between sessions beyond a session finding the sessions it needs and asking Loom, with the user's approval, to open a new one ([ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md)).

Status: 0.4.4 is in daily use on the user's Mac and public on GitHub. This tree builds Loom v2, which ships once, as 1.6.0, the first stable release ([D-68](DECISIONS.md), [D-83](DECISIONS.md)). The current position is in [STATUS.md](STATUS.md) and the active plan toward 1.6.0 in [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md). Codex support exists in development builds but is not part of 1.6.0.

## Docs

| Doc | What it holds |
| --- | --- |
| [AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md) | Agent workflow, role matrix, canonical file routing, working principles, and safety rules |
| [STATUS.md](STATUS.md) | Live relay board: where the work stands now, worktrees, active file locks, and `@role` handoff queue |
| [SPEC.md](SPEC.md) | Unified product & behavioral specification (replacing `LOOM-PRODUCT-CONTRACT.md` and `plans/v2/CHAT-SPEC.md`) |
| [DECISIONS.md](DECISIONS.md) | User decisions: Approved & Active (`D-01`–`D-91`), Rejected & Superseded, and Pending / Open (`#open`) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture: targets, runtime flows, process ownership, UI surface-to-code index (§11, replacing `design/UI-MAP.md`), and technical gotchas (§12) |
| [design/DESIGN.md](design/DESIGN.md), [design/reference.html](design/reference.html) | Visual design system (Ink v3) and interactive reference |
| [DEVELOPMENT.md](DEVELOPMENT.md), [scripts/README.md](scripts/README.md) | Build, test, isolation, evidence mode, packaging, and measurement |
| [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md), [plans/README.md](plans/README.md) | Active 1.6.0 execution plan, End Batch Runbook, experiments, and archived checkpoint history (`plans/archive/`) |

This repository is **loom-dev**, the development tree. The daily-use app is built from a separate clean **loom** tree that receives tested releases from here and is public at [github.com/gencberke/loom](https://github.com/gencberke/loom) ([DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).

## Build

Swift package, macOS 27. Read [DEVELOPMENT.md](DEVELOPMENT.md) first: development packages, test data and scratch builds must stay outside `~/Documents`, and tests never use your real Claude profile or installed app.

```bash
scripts/check.sh --scratch ~/Library/Caches/loom-dev-build
```

`scripts/check.sh` acquires the shared build slot (`~/Library/Caches/loom-run1/build-slot.lock`), builds into the isolated scratch path outside `~/Documents`, and runs the required guards and tests ([DEVELOPMENT.md §2](DEVELOPMENT.md#2-build-and-test), [AGENTS.md §7.3](AGENTS.md#7-multi-agent-build--user-data-safety-rules)). Never invoke `swift build` or `swift test` directly.
