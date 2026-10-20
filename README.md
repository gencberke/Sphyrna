# Loom

Loom is a native macOS 27 app for running real Claude Code sessions side by side in one window: a sidebar of projects and sessions with live status, and the selected session either in its terminal, exactly as Claude Code draws it, or in a native chat over the same CLI. Loom launches and owns each CLI session in its own process scope, tracks its state (working, waiting for you, finished), resumes past sessions, and stops everything it started on Quit. From 1.5.0 the app is named Sphyrna ([D-77](DECISIONS.md)); the code keeps the name Loom.

For one power user on macOS 27. Out of scope for 1.5.0: Codex, other providers, and coordination between sessions beyond a session asking Loom, with the user's approval, to open a new one ([ROADMAP](ROADMAP.md#release-target)).

Status: 0.4.4 is in daily use on the user's Mac and public on GitHub. This tree builds Loom v2, which ships once, as 1.5.0 ([D-68](DECISIONS.md)). The current position is in [STATUS.md](STATUS.md) and the path to 1.5.0 in [ROADMAP.md](ROADMAP.md). Codex support exists in development builds but is not part of 1.5.0.

## Docs

| Doc | What it holds |
| --- | --- |
| [STATUS.md](STATUS.md) | Where the work stands now |
| [ROADMAP.md](ROADMAP.md) | Stages toward 1.5.0 |
| [DECISIONS.md](DECISIONS.md) | Dated user decisions and open decisions |
| [LOOM-PRODUCT-CONTRACT.md](LOOM-PRODUCT-CONTRACT.md) | Product behavior and technical limits |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Code map: targets, flows, process ownership |
| [design/DESIGN.md](design/DESIGN.md), [design/reference.html](design/reference.html), [design/UI-MAP.md](design/UI-MAP.md) | Visual rules (Ink), every surface as designed, and the UI surfaces in code |
| [DEVELOPMENT.md](DEVELOPMENT.md), [scripts/README.md](scripts/README.md) | Build, test, isolation, packaging, measurement |
| [AGENTS.md](AGENTS.md) | How agent sessions work in this repo |
| [plans/README.md](plans/README.md) | The active v2 plan, earlier checkpoint plans and history |

This repository is **loom-dev**, the development tree. The daily-use app is built from a separate clean **loom** tree that receives tested releases from here and is public at [github.com/gencberke/loom](https://github.com/gencberke/loom) ([DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)).

## Build

Swift package, macOS 27. Read [DEVELOPMENT.md](DEVELOPMENT.md) first: development packages, test data and scratch builds must stay outside `~/Documents`, and tests never use your real Claude profile or installed app.

```bash
scripts/check.sh
```

`scripts/check.sh` builds into the development scratch path and runs the required checks ([DEVELOPMENT.md §2](DEVELOPMENT.md#2-build-and-test)); a plain build is `swift build --scratch-path ~/Library/Caches/loom-dev-build`.
