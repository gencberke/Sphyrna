# Status (Live Relay Board)

- **Updated:** 2026-10-29,03:51 +03.
- **State:** `waiting for implementation`. Active overnight goal D-112: a daily-use-ready, trustworthy local1.8.0 by morning. The planner is the main technical authority. Pi is deferred (D-113). Acceptance order/evidence: [plans/1.8.0/ACCEPTANCE.md](plans/1.8.0/ACCEPTANCE.md).
- **Power/window:** @user is asleep, Mac idle and left on; AC is now verified80%, attached/not charging. Earlier current-continuation battery exception remains recorded; thermal checks,90s heavy-cell cooldowns and one build slot still apply.
- **Current work:** X1 sidebar parity is integrated26088a1 (65 parent tests PASS); its tree and B3b tree are recovery-bundled and removed. F0 foundationff8627a is getting truthful typed execution proof before F1. D1 remote-TUI roots fix469eee6 passes26 scoped tests; parent is repairing the real-test terminal frontend for actual startup/approval acceptance. The terminal also renders a native trust choice; no input has been sent in the zero-input diagnostics. B3b actual Help/card-bar acceptance is now closed.
- **Installed/public:** daily app1.7.2 build10702; public release0.4.4. The local1.8 goal adds no public GitHub publication instruction. The clean loom tree is written only through the release flow.

## Current checkpoints

- `v2` code26088a1: X1 compact reference cards/whole child surface/icons/pin;65 integrated tests PASS.  B3b one bottom barf3d4f01 plus deferred Help fixf0d9117. Slice93 tests, integrated scoped/window29, then fix14 pass. Actual signedf0d9117 PID19564 passed Help AX open/Escape with sidebar open, collapsed and after native fullscreen enter/exit; calls return0.5–0.7s. It quit normally; process absent/default Dev metadata unchanged. Evidence `evidence/r9/b3b/`.
- D1 source4cda375 +opt-in test67e5896: neutral Codex first-message/settings, same-native safe resume and exact owned socket cleanup. Hostile native reviewer/network/roots were a real gap;10 zero-turn disposable-profile cells support invocation-only hardening.114 affected tests pass, cleanup fix4 pass; original220-Core combined verdict remains FAIL with scoped fixes. Real first-prompt and exact-leader acceptance remain unverified. T8 failed before identity (one input conservatively unknown); Z1–Z8 sent zero user inputs. The remote TUI rejects the CLI roots override; removing only that pair reaches native folder trust/terminal queries. No trust/config bypass. Original opt-out SKIP is preserved. Evidence `d1/startup-zero/REPORT.md`.
- A1bf8adc58:50 connected tests +actual Ink/Paper distinct draft-row/selection PASS; tree/scratch removed. B4 native picker fix0c8a0b2:47 tests +actual signed window/keyboard PASS. B5ae618124:117 connected PASS; B5b339929d:156 connected PASS. Its strict first-screen/RSS equivalence remains unproved (about5.6–6.0MB higher RSS); energy still required.
- Earlier offscreen pool3560 tests had3 failures; affected112 later pass. Preserve the pool's FAIL and scoped evidence; do not relabel it. Earlier broader UI collision/fixture/native failures remain in their reports.
- P0:7 submitted Codex inputs +1 auxiliary held conservatively. D-112 now authorizes short cheap turns as needed; reservations and per-turn/usage accounting remain. T8 is closed failed/unknown, with at most one input held; no active model-input reservation. Ledger `evidence/r9/REAL-TURN-BUDGET.md`.
- T3/Orca source/multi-round reports are complete. Stable child vs fresh round, repeated notifications and explicit cancellation scope are checked. F0 source seam map is complete. P1 official-source isolation reports support a narrow OpenCode metadata probe; full OpenCode system/MDM config and native agy initialization/Keychain exclusions need proof. No Pi execution/integration.

## Worktrees and locks

| Tree | Branch/HEAD | Owner and state |
| --- | --- | --- |
| `~/Library/Caches/loom-v2/wt/v2` | `v2`,26088a1 | planner; current goal/reference/canonical reconciliation in progress |
| `wt/r9-d1` | `slice/r9-d1`,469eee6 plus frontend test edits | parent owns actual real acceptance; no worker writes |
| `wt/r9-d2-reader` | `slice/r9-d2-reader`,26088a1 base | warmb3_ink; bounded reader/usage/Peek/search/Overview/Changes seams and tests; exact expanded write set in Brief |
| `wt/r9-f0` | `slice/r9-f0`,ff8627a | warmc4_core owns typed host-resolved execution provenance and operations task index follow-up; no runtime/wire/UI integration yet |
| `r9-b3b`, `r9-x1` | removed after source equivalence/recovery verification | recovery bundles/manifests in each evidence folder |
| `~/Documents/github/loom-dev` | `swarm/1` | guarded canonical/reference mirror only, never Sources/build/commit |
| `~/Documents/github/loom` | `main` | separate clean release repository, no test material |

At most2 implementation slices. Every build/test/package/measurement uses the shared slot with timeout600 or the normal longer default; no parallel build. Each active tree has its own scratch outside Documents. Parent owns canonical/reference files, real-turn ledger, acceptance runs and integration. The earlier unflagged CUA auto-relaunch touched default Dev WAL/SHM metadata; contents are **unverified**, not rolled back or declared unchanged. Later guarded runs do not erase that incident.

## Next actions by role

- **@planner:** finish D1 remote-TUI compatibility fix and use a real terminal frontend for native trust/terminal-query handling before reserving the next first-message/settings/Stop→Resume→Quit acceptance. Then accept/integrate or fix based on evidence. Review X1/F0 diffs and wire F1 after the durable contract is sound. Continue D2/E1/E2/F2/G1/H1/I1 and the full acceptance matrix. D-114 reference geometry wins; branch stays accessible when reason takes its visual row. Child name/model require truthful metadata, never parent-model/brief invention.
- **@implementer-ink warmb3_ink:** D2 reader-only brief in chat: bounded exact native ID/profile lookup, truthful data/usage/consumer paths, Claude behavior pin. No deletion/task/runtime lifecycle writes. X1/B3b trees are removed with verified recovery bundles.
- **@implementer-core warmc4_core:** F0 typed host-resolved execution proof and operations(task) migration/index in r9-f0 only. D1 source469eee6 is ready for parent real acceptance; no real execution by worker.
- **@researcher warmorca_cross_agents:** D2/G1 source reports complete; now current OpenCode2.2.0 source addendum and pinned Codex trust/edited-file schemas. Parent metadata --version returned2.2.0, so it stopped before debug paths/model; no login or model call. Pi deferred.
- **@optimizer:** once complete candidate exists, gpt-6-astra/xhigh or Opus5.5/max; all code through1.8.0 is in scope, including earlier code. Then planner fixes findings, checks docs and briefs the existing open Claude session for independent final planner-reviewer/optimizer critique. Preserve that session's permissions/effort and consider Claude usage; its delegated subagents at least Opus5.5 high.
- **@user:** no repeated routine permission request. Login remains user-owned if a genuine isolated-profile sign-in is needed. Cheap turns are now authorized as needed; Codex full reset may be used at3–4% remaining. Baseline at goal creation55% used/45% remaining, reset1available.

The complete slice table is in [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md); individual reports and failures live in `~/Library/Caches/loom-v2/evidence/r9/`, not in this relay.
