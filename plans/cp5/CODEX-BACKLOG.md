# Codex backlog (deferred at CP5 closure)

Codex development is paused since 4 Oct 2026 and Codex is not part of the first production release ([D-08, D-14](../../DECISIONS.md)). CP5 closed without these Codex-only items ([D-23](../../DECISIONS.md)). They are the starting list when Codex returns after the first release; re-validate each against the code and the Codex CLI of that time before planning.

| Item | What is missing | Source |
| --- | --- | --- |
| Real Codex idle/Stop measurement | Model-free idle and Stop cost of native TUI versus Loom (remote TUI + app-server + Loom) on a current package | [PERF](PERF.md) M1 |
| In-app observer cost (Codex) | App-side cost of following a live Codex session | [PERF](PERF.md#kullanıcı-kararı-codex-geliştirmesi-duraklatıldı-4-ekim-2026) (Codex pause section) |
| In-app Stop for Codex (PERF-4 app side) | Stop from the app measured and accepted for Codex sessions | PERF |
| Codex CLI settings (C1) and PERF-O1 | Measured cost of Codex CLI behavior settings; any change is a user decision ([D-20](../../DECISIONS.md)) | PERF C1 |
| Codex-only CP5 acceptance rows | C1/C4 and related rows were last verified for Codex on 2 Oct (17/17); not re-run on packages H/I | [CHECKPOINT-5](../CHECKPOINT-5.md), [C](C.md) |
| Contract rows to revisit | Codex memory figure, Codex 30-minute cache versus §4.4 ([O-08](../../DECISIONS.md)) | Contract §3, §4.4 |
| Production build surfaces | Codex menu items, context menus and `--codex-home` are excluded from the production build in roadmap stage F | [ROADMAP](../../ROADMAP.md) |
| Server teardown that is joined returns early | `SessionRuntime.tearDown(_:card:)`: a caller that joins a teardown already running (`server.teardownTask`) returns its result before the first caller has set `finished` and removed the server from `codexServers`. So `stopConversation` can report success while `codexServerState().servers` still counts the server for a moment. `eachCodexConversationHasItsOwnServerAndStopClosesOnlyIt` failed once on this, at line 1108, in the round-4 full run 4 on 13 Oct. Fix candidate: do the bookkeeping inside the teardown task, so that every caller sees it | [FEEDBACK-4](../FEEDBACK-4.md#verification) |

Code locations: [docs/ARCHITECTURE.md §8](../../docs/ARCHITECTURE.md#8-codex-paused-not-in-first-release).
