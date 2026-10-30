# Sphyrna (loom-dev)

Sphyrna is a native macOS 27 session manager. It hosts real CLI sessions in owned process scopes, shows working/attention/completion state, resumes sessions and stops its owned work on Quit. The current development line targets **1.8.0** and Ink v4.

The app is terminal-first. General Native Chat is frozen (D-101); the task-only managed child view is the approved exception (D-116), with bounded progress, individual user permission cards and Take Over. Claude/Codex managed execution is implemented in the candidate, with native acceptance and recovery gaps still open. Other harness work and the release gate remain tracked in [STATUS.md](STATUS.md) and [the active plan](plans/ACTIVE-PLAN.md). This is not a daily-use-ready 1.8.0 release claim.

Sphyrna is the product name. Internal Loom targets, bundle identifiers and existing data paths remain compatibility boundaries; name/migration completion is part of the active plan. Public promotion, installation and publishing require the user's explicit approval.

## Docs

| Doc | What it holds |
| --- | --- |
| [AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md) | Agent workflow, role matrix, canonical file routing, working principles, and safety rules |
| [STATUS.md](STATUS.md) | Live relay board: where the work stands now, worktrees, active file locks, and `@role` handoff queue |
| [SPEC.md](SPEC.md) | Unified product & behavioral specification (replacing `LOOM-PRODUCT-CONTRACT.md` and `plans/v2/CHAT-SPEC.md`) |
| [DECISIONS.md](DECISIONS.md) | Dated user decisions: Approved & Active, Rejected & Superseded, and Pending / Open |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture: targets, runtime flows, process ownership, UI surface-to-code index (§11, replacing `design/UI-MAP.md`), and technical gotchas (§12) |
| [design/DESIGN.md](design/DESIGN.md), [design/reference.html](design/reference.html) | Visual design system (Ink v4) and interactive reference |
| [DEVELOPMENT.md](DEVELOPMENT.md), [scripts/README.md](scripts/README.md) | Build, test, isolation, evidence mode, packaging, and measurement |
| [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md), [plans/README.md](plans/README.md) | The active plan (none since the archive, [COLD-START.md](COLD-START.md)), the release notes and the perf baseline |

This repository is **loom-dev**, the development tree. The daily-use app is built from a separate clean **loom** tree that receives tested releases from here and is public at [github.com/gencberke/loom](https://github.com/gencberke/loom); its README is [scripts/release/README.release.md](scripts/release/README.release.md), with pictures rendered from [design/readme/](design/readme/build.py) ([DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).

## Build

Swift package, macOS 27. Read [DEVELOPMENT.md](DEVELOPMENT.md) first: development packages, test data and scratch builds must stay outside `~/Documents`, and tests never use your real Claude profile or installed app.

```bash
scripts/check.sh --scratch ~/Library/Caches/loom-dev-build
```

`scripts/check.sh` acquires the shared build slot (`~/Library/Caches/loom-run1/build-slot.lock`), builds into the isolated scratch path outside `~/Documents`, and runs the required guards and tests ([DEVELOPMENT.md §2](DEVELOPMENT.md#2-build-and-test), [AGENTS.md §7.3](AGENTS.md#7-multi-agent-build--user-data-safety-rules)). Never invoke `swift build` or `swift test` directly.
