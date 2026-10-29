# Status (Live Relay Board)

- **Updated:** 2026-10-29,09:44 +03.
- **State:** `waiting for implementation`. Active overnight goal D-112: a trustworthy daily-use local1.8.0. Planner is the technical authority; Pi deferred D-113. [Acceptance](plans/1.8.0/ACCEPTANCE.md) remains the completion gate.
- **Power/window:** user asleep, Mac idle/AC verified; thermal nominal. One shared build slot, isolated scratch and90s heavy-cell cooldowns remain.
- **Current work:** F1 stable source through a2e1f72 integrated1f38cc3 (two equivalent D1 fixes skipped); H1c32e35f callback/ordered-ingress/lifecycle fences preserved in merges. Existing F1 UI is now wired to real runtime reads; combined scoped check093908-75689 passed173Core+29UI. Peer-message/deletion and central transport-dispatch closure remain on warmcore. E1 primitives/profile/livefeed integrated79c6ed4; TUI route/policy observer under implementation, full provider/runtime pending. E2 exact local fake native text PASS with strict permissions/same native conversation/terminal result,0real calls; four-shape native fake discovery differential PASS (progressive skill metadata +startup hook from extra app-owned root).
- **Installed/public:** daily app1.7.2 build10702; public release0.4.4. No new push/tag/PR/public promotion authorization; clean loom tree remains release-script-only.

## Accepted evidence and open limits

- D1 T14: actual native0.164.0,1GPT-6-Luna/low input, exact occurrence approval/file/final reply, native model/effort/permissions, verified Stop, same native thread Resume with0new inputs/6VT replies, verified Quit and independent process/socket absence. Log071942-5765; `evidence/r9/d1/real-acceptance/D1-NATIVE-ACCEPTANCE.md`. Earlier T8–T13 FAIL retained; T8/T9≤1input unknown each and P0 auxiliary1 remain conservative holds. Ledger confirmed12inputs, no active reservation.
- Main D1+H1 connected run072300-8820:153/155Core tests and84UI pass;2issues are one legacy HarnessProbe expectation which assumed only2windows and now receives native Opus too. Parent corrected the retained Opus/partial-coverage expectation; scoped072804-11792 passes24 tests. The original combined run remains FAIL.
- D2 be3e17a/ecfce1e: bounded exact-profile reads,19connected +3source-revision checks PASS. Parent source dispatch guard660545d passes7Core+3UI. Deletion remains separate.
- F1 UI44447c3:78parent tests PASS. Core empty owned startup/proof/CLI/cards and cross-provider three-round native flow remain unaccepted. Pinned native turn/start does not subscribe a new observer; exact bounded persisted-input proof is being added, never receipt-only success.
- X126088a1:65tests PASS. B3bf3d4f01/f0d9117:93slice+29connected/window+14fix PASS; actual Help/Escape, collapsed/sidebar/fullscreen return PASS; process absent/default Dev metadata unchanged for those guarded runs. A1b50/B447with actual guarded Ink/Paper and picker keyboard PASS. B5a117/B5b156/B5c97connected PASS. B5b RSS+5.6–6MB and strict first-screen equivalence remain unproved; native parity/energy/whole gate still pending.
- Old whole offscreen3560 pool FAIL3 and later scoped112PASS remain distinct. Earlier CUA unguarded auto-relaunch changed default Dev WAL/SHM metadata; contents **unverified**, never rolled back or declared unchanged. Later clean runs do not erase the incident.
- OpenCode2.2.0 metadata/owned numeric loopback/API and G1 local fake wire PASS,0real inputs. E1 fake detached-child/HTTP/listener checks pass; full native runtime/TUI pending. AGY1.4.5 strict sandbox has positive owned read and negative outside read, then version/help PASS0inputs; root-literal dyld rule only, no Keychain/Mach/network allowance. No login or credential copying.
- Authorized free Codex reset used exactly once at96%used/4%remaining; same account verified, official API refreshed0%,0resets left. Shared account is now36%used/64%remaining; this includes planner/workers and cannot be attributed to one test. No purchased credit. Receipt `overnight-20261029/usage-reset-redemption-*.json`.

## Worktrees and locks

| Tree | Branch/HEAD | Owner/state |
| --- | --- | --- |
| `~/Library/Caches/loom-v2/wt/v2` | `v2`,79c6ed4 plus UI bridge wiring | planner: canonical integration, H1 trigger/native acceptance, deletion and remaining release slices |
| `wt/r9-d1` | removed | accepted D1 source, verified recovery bundle/manifest (36/39write-set files equal;3reviewed D2/H1 integration differences), scratch cleanup queued |
| `wt/r9-h1` | removed | accepted H1 source byte-equal27/27write-set files, verified recovery bundle/manifest; scratch cleanup queued |
| `wt/r9-f1` | `slice/r9-f1`,a2e1f72 plus peer/transport edits | warmc4_core: core task RuntimeHost/CLI/status/three rounds, native identity/ingress/syscall proofs; shared Runtime/adapter/Codex/Vendor ownership |
| `wt/r9-e1` | `slice/r9-e1`,c11d510 | warmb3_ink: new OpenCode Core/test primitives/profile/livefeed complete; runtime/provider integration Brief next, native TUI selection plugin seam being traced |
| `r9-f0`, `r9-d2-reader`, `r9-f1-ui`, `r9-b3b`, `r9-x1`, earlier A1b/B4/B5 trees | removed | accepted write-set/patch equivalence, verified recovery bundles/manifests; scratch removed |
| `~/Documents/github/loom-dev` | `swarm/1` | guarded canonical/reference mirror; never Sources/build/commit |
| `~/Documents/github/loom` | `main` | clean release repository; no test material |

At most2 implementation slices. Every build/test/package/measurement uses the shared slot; parent owns combined checks, ledger/model reservations, canonical/reference files and actual native/OS measurements. Don't re-run or spend a real input without a new recorded reservation.

## Next actions by role

- **@planner:** H1 parent source ready; integrate F1 staged code and E1 while preserving shared locks. Review F1 core and wire accepted UI bridge, prove real3round both directions. Review E1 primitives/profile proof then serialize runtime/provider integration. Complete E2, D2 deletion, F2/G1/I1, actual app/reference/native/resource/usage matrix, full gate. No feature is done by a fake-only proof.
- **@implementer-core warmc4_core:** self-contained chat Brief, r9-f1 only. Finish bounded exact-native first-input proof, real fake three rounds, wait/wake/read/report/interrupt/verified-stop/deletion, existing real terminal sink. No real providers/models, shown windows or canonical docs.
- **@implementer-ink warmb3_ink:** self-contained E1 continuation Brief, r9-e1 only. Primitive/profile/livefeed checkpoints985cb98/914fcb5/c11d510 ready (42test final); full runtime/provider wiring next. New OpenCode Core/test files only, existing shared runtime locks remain core/planner. No native/model/auth/window runs.
- **@researcher warmorca_cross_agents:** pinned native selection and action-broker contracts complete; final bounded config endpoint lookup for E1. No provider/model/build/auth or subagents.
- **@optimizer:** mandatory full-code architecture/quality/concurrency/resource review once candidate exists, gpt-6-astra/xhigh or Opus5.5/max. Planner fixes findings then final doc check and existing Claude's unfiltered independent critique. Preserve Claude permissions/effort and account usage; its subagents at least Opus5.5high.
- **@user:** pending async AGY existing-Keychain exception question remains unanswered; no real AGY account access until an affirmative reply. Other isolated/fake work continues. Genuine isolated login stays user-owned. Cheap short turns as needed D-112; Pi deferred. Local readiness does not authorize public promotion.
