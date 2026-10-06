# Completeness critique: multi-agent run 1 planning scans

## 1. Spot-checks (source read; nothing built or run)

All of these were verified. I found no refutations.

- **Startup serialization.** `AppDelegate.swift:98-102` awaits `startRuntime` and only then `model.start()`.
- **Bundle-id duplicates.** `AppDelegate.swift:113` uses `==`, while `:234` and `:402` use `!=`. The command-channel prefix is hard-coded to the dev value at `LaunchOptions.swift:53`.
- **Codex test pin.** `SidebarStatusTests.swift:57-62` asserts both providers in `NewConversationAction.all`, so F1 must change it.
- **Git reads on MainActor.** `GitBranch.read` is called at `CatalogModel.swift:380`, `:472` and `:690`.
- **Catalog deletion gaps.**
  - The only `DELETE` in `SessionCatalog.swift` is the project one at `:583`.
  - `quick_check` runs at `:1033`.
  - Nothing in `Sources/` contains `secure_delete` or `wal_checkpoint`.
- **Resume can recreate a row.** `ProcessSupervisor.swift:560-600` creates a new `ManagedSession` and row when the provider id is not in the catalog.
- **Restore loads everything.** `restoreCatalogSessions` (`ProcessSupervisor.swift:1467-1475`) loads all rows into `sessions`.
- **View counts as use.** This resolves the U-integration report's "inferred" marker.
  - `CatalogModel.updateViewing` (`:499-508`) calls `viewed`.
  - That reaches `SessionLifecycleController.markViewed` (`:350-352`), which runs `catalog.markUsed` and then `reschedule`.
  - Every selection or window activation is therefore a catalog write.
- **Accessibility and Settings.**
  - `ProjectHeader` collapses only via `onTapGesture` (`SidebarView.swift:273`).
  - `.defaultAction` is on Resume, Approve and Save (`DetailView.swift:274,320,393`).
  - The Settings `NSWindow` sets no appearance (`AppDelegate.swift:604-616`).
  - ⌘1 and ⌘2 are taken (`AppDelegate.swift:675-677`).
- **Release manifests.**
  - Neither manifest has any `swiftSettings` today.
  - `promote.sh:74` is a `git archive` with exclude pathspecs, so adding `Evidence/` is feasible.
  - `LoomCatalogUI` depends on `LoomTerminal` (`Package.swift:29`).
- **Provenance.** I did not re-check the price table. It came from a web fetch with no date and uses model names I cannot confirm. The user must confirm the values before they ship.

## 2. Contradictions and gaps between reports

1. **F8 (lazy `ProcessSupervisor.sessions`) is TAKE in F and perf, but "defer, invasive (about 35 callers)" in arch-scale.**
   - CP4-C needs it only for resurrection safety.
   - Recommendation: split it.
     - Take the startup reorder and the off-main catalog open now.
     - Defer lazy loading.
     - CP4 gets `discardSession` plus the tombstone set.
2. **The F report omits the biggest perf wins that arch-scale and perf found.** Both are verified above.
   - Add an F-perf slice with these items:
     - signposts;
     - `model.start()` concurrent with `startRuntime`;
     - catalog open and `quick_check` off the first-paint path;
     - `ProcessTable.record(pid:)` instead of the full snapshot (S2);
     - a background `BranchCache`;
     - no unconditional `now` or `branches` writes;
     - skip undecodable rows (arch-scale 2.3).
   - It touches `AppDelegate:98-102`, `CatalogModel`, `GitBranch` and `ProcessSupervisor`, so it conflicts with F2, F3, F4c and U3.
3. **Schema v3 has three proposers.**
   - CP4 wants `deletions`, `stale_since` and `app_state`.
   - Arch-scale wants child indexes and possibly a `search_text` column.
   - Perf suggests "a small file or a catalog table" for usage.
   - Resolution:
     - CP4-B is the single owner of v3, and it includes the child indexes.
     - Add `search_text` only if the measurement justifies it.
     - Usage uses its own disposable `usage-index.sqlite3`, per the usage-data report. That keeps it off the catalog.
4. **The Codex switch and the evidence switch use opposite reasoning.**
   - F rejects a compile define for Codex because the release suite would test a non-shipped flavor.
   - It then adopts `#if LOOM_EVIDENCE`, which has the same problem.
   - It only works if `check.sh --full` builds the staged no-define tree.
   - Make that a required acceptance item of F3, not an F5 afterthought.
5. **Settings is claimed by both I-2 and U1.**
   - I-2 edits `SettingsView` and `showSettings` to force dark.
   - U1 rewrites both.
   - Resolution: I only supplies tokens. U1 owns the Settings window, in a new `SettingsWindowController.swift`.
6. **Usage index vs deletion "no trace" guarantee.**
   - The usage `msg` and `file` rows hold session ids and transcript paths.
   - They survive CP4 deletion by design.
   - That conflicts with the contract §8 "no trace" and with CP4's trace test.
   - It needs a user decision, in one of three forms:
     - keep per-day and per-model aggregates only, with no session id or path;
     - purge the deleted session's rows on delete;
     - document the exception.
   - Related: the usage reader reads files CP4 deletes, so a missing file must not reset the aggregates.
7. **Tab switching is a catalog write with side effects.** The write is now verified.
   - Each switch runs `markUsed`, then `reschedule`, then possibly a list reorder.
   - CP4 decision 4 ("view extends the stale wait") and the tab design both depend on this.
   - It must be decided once.
   - The preferences write per switch is separate and can be debounced.
8. **Keep-alive vs swap for tabs.** U says swap (`DetailView:163-167`). Perf says a persistent container may be better. Both are unmeasured, so measure switch latency with signposts first.
9. **Tab shortcuts.**
   - U proposes Shift+Cmd+]/[ and Ctrl+Tab.
   - I notes ⌘1/⌘2 are taken.
   - ⌘F search is I-3, and Close Tab is U4, so both land in `installMenus`. Serialize them.
10. **"Matches Claude's records" is unachievable as worded.** Transcript totals are 86% of `cost-state` on the probe profile. Define it as tokens exact after dedupe, with cost shown as an estimate.
11. **Per-conversation forget hooks.** The tab list, usage cache, `CatalogModel` caches, hub, adapters and supervisor all need a forget hook. Put it in one registered list, with an acceptance line in U and CP4.

## 3. Not covered by the scans

- **Nothing was measured.** There is no cold-launch baseline, no switch latency, and no `quick_check` or search timing at 10k or 100k rows. No Instruments body counts were taken. The usage cold-scan figures are guesses.
- **Several behaviours are unverified:**
  - whether `@Observable` equal-value dictionary writes notify;
  - whether `LazyVStack` retains views;
  - whether `secure_delete` is on inside the app's connection;
  - Claude's `debug/`, `tasks/` and subagent file names;
  - whether Return reaches the CLI when Approve has `.defaultAction`.
- **Real-Claude checks.** A subagent-plus-edit turn in the probe profile would settle the CP4 and usage layout questions. That is about 2 of the 40-turn budget.
- **Screenshots cannot cover several surfaces.** The existing `screenshot:` renders only the main content view. Missing:
  - Settings and sheets, which need the small evidence additions;
  - menus, hover, tooltips, glass and motion, which need computer-use or the user.
  - The accessibility audit is static only. No VoiceOver or Full Keyboard Access run was done.
- **No fixture covers new chrome in the perf matrix.** The matrix measures synthetic terminal load. Nothing measures a tab strip, a footer chip, or the usage refresh.
- **Not read:**
  - the SwiftTerm render path;
  - Codex (frozen);
  - `RunScope` internals;
  - the evidence scripts beyond the cited lines.
- **Evaluations.**
  - The reviewer, verifier and advisor roles start only when the user asks (global AGENTS).
  - The planner must schedule the stage-end evaluations and optimizer as main-session work, or request user permission.
- **Open user decisions:**
  - Codex build policy.
  - Tab model, close semantics and shortcuts.
  - Usage scope and index privacy.
  - Retention and cleanup parameters.
  - Schema v3 meaning Loom 0.1.0 cannot open the catalog.
  - Whether quit confirmation is wanted.
  - Whether the `--evidence` flag is ignored or refused in release.

## 4. Cross-stage write-area conflicts

Hot files, with who edits them:

- **`AppDelegate.swift`:** F1, F2, F3, F-perf, I-2, I-3, U1, U4 and CP4-D.
- **`SidebarView.swift`:**
  - F1;
  - I-1, I-2, I-3 and the I-1 `ChromeButtonStyle` item (S-C);
  - U2 and U4;
  - CP4-D.
- **`DetailView.swift`:** F1, I-1 to I-3, U4, CP4-D.
- **`CatalogModel.swift`:** F1, F-perf, U3, U-usage hook (`apply`), CP4-D and CP4-G.
- **`ProcessSupervisor`, `SessionRuntime` and `SessionCatalog`:** F4a-c, F6/F8, CP4-B and CP4-C.
- **`DevelopmentEvidence.swift`:** F3 moves it. U5, U4, CP4-D and CP4-E all want to add commands.

Rules to impose:

- One owner per round for `AppDelegate.swift` and `Package.swift`.
- New evidence commands go in new files after F3.
- New UI goes in new files with a one-line mount: `SidebarFooter.swift`, `ConversationTabStrip.swift`, `SettingsWindowController.swift`, `CatalogModel+Deletion.swift` and `ConversationTabs.swift`.
- No new targets, because of the promote drift guard.

## 5. Recommended order and parallelism

The build slot is serialized (`lockf` lock exists at `~/Library/Caches/loom-run1/build-slot.lock`). Parallelism therefore means disjoint writers whose builds queue. The full matrix of about 35 minutes (reference included) holds the slot, so schedule it only at stage ends.

**Wave 0, serial and short:**
1. F5-lite: `with-build-slot.sh` plus `check.sh`, including the untracked-file whitespace check and the window-test skips. Everything else uses it.
2. Signposts, then a baseline package, then launch and switch numbers. Reference package I already exists.

**Wave 1, parallel writers:**
- **F1**, small. It must merge first because I and U share its files.
- **F4a**, the `SessionCatalog` split. Pure move, before any CP4-B.
- **U0**, the usage reader, in new `LoomCore` files.
- **CP4-A**, the inventory and deleter, and **CP4-F**, the planner. Both are pure and new.
- **F2 then F3** as one serial track on `AppDelegate`, `Package.swift` and `promote.sh`. Nothing else touches `AppDelegate` until it lands.

**Wave 2:**
- **I-1**, the theme migration. It does not touch `AppDelegate` or `LoomCore`, so it can run beside F2/F3 once F1 lands.
- **F4b and F4c** (the `SessionRuntime` and `ProcessSupervisor` splits).
- **F-perf**, after the splits, with `ProcessSupervisor` edits serialized.

**Wave 3, after I-1 and the splits:**
- **U1 and U2**, Settings and footer.
- **U3**, then **U4**.
- **I-2 and I-3.** They touch `SidebarView`, `DetailView` and the View menu, so serialize them with U2 and U4.
- **CP4-B**, after F4a and the v3 owner decision.
- **CP4-C**, after F4b, F4c and the supervisor-side discard hook.

**Wave 4:**
- **CP4-D, then CP4-G.** CP4-E is the real-Claude deletion check.
- **I-4**, the WindowServer measurement. It is exclusive and noisy, so it needs an idle Mac.
- **U5** and the docs.

**Stage ends:**
- Optimizer, then the full gate.
- Package and the matrix with `--reference-app`.
- Indicator cost run, only if sidebar or chrome changed.
- Real-Claude run (2 turns), only if provider, session, terminal or quit changed.
- Screenshot pass, with the user or computer-use for Settings, sheets, menus and hover.

CPU40 must hold. The baseline is `plans/experiments/cp5-final-matrix-I-20261006.json`: stream1 total about 25.5% against the 40% ceiling. The comparer thresholds in the tooling report are proposals, not documented limits.

**Critical path:** F5-lite, then F1, then F2/F3 and F4a, then I-1, then U1/U2/U4, then CP4-B/C/D. U0, CP4-A and CP4-F are off the critical path and can run immediately.