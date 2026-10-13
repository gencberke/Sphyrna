# Loom

Loom is a native macOS 27 app for running real Claude Code terminals side by side in one dark-glass window: a sidebar of projects and conversations with live status, and a full terminal for the selected conversation. Loom launches and owns each CLI session in its own process scope, tracks its state (working, needs approval, finished), resumes past conversations, and stops everything it started on Quit — without replacing the CLI's own interface.

For one power user on macOS 27. Out of scope for the first release: Codex, other providers, and coordination between sessions beyond a session asking Loom, with the user's approval, to open a new one ([ROADMAP](ROADMAP.md#release-target)).

Status: in daily use on the user's Mac through releases of the clean loom tree; the current position is in [STATUS.md](STATUS.md) and the path to the first production release in [ROADMAP.md](ROADMAP.md). Codex support exists in development builds but is not part of the first release.

## Docs

| Doc | What it holds |
| --- | --- |
| [STATUS.md](STATUS.md) | Where the work stands now |
| [ROADMAP.md](ROADMAP.md) | Stages toward the first production release |
| [DECISIONS.md](DECISIONS.md) | Dated user decisions and open decisions |
| [LOOM-PRODUCT-CONTRACT.md](LOOM-PRODUCT-CONTRACT.md) | Product behavior and technical limits |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Code map: targets, flows, process ownership |
| [design/DESIGN.md](design/DESIGN.md), [design/UI-MAP.md](design/UI-MAP.md) | Visual rules and the UI surfaces in code |
| [DEVELOPMENT.md](DEVELOPMENT.md), [scripts/README.md](scripts/README.md) | Build, test, isolation, packaging, measurement |
| [AGENTS.md](AGENTS.md) | How agent sessions work in this repo |
| [plans/README.md](plans/README.md) | Checkpoint plans and history |

This repository is **loom-dev**, the development tree. The daily-use app is built from a separate clean **loom** tree that receives tested releases from here ([DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).

## Build

Swift package, macOS 27. Read [DEVELOPMENT.md](DEVELOPMENT.md) first: development packages, test data and scratch builds must stay outside `~/Documents`, and tests never use your real Claude profile or installed app.

```bash
scripts/check.sh
```

`scripts/check.sh` builds into the development scratch path and runs the required checks ([DEVELOPMENT.md §2](DEVELOPMENT.md#2-build-and-test)); a plain build is `swift build --scratch-path ~/Library/Caches/loom-dev-build`.
