# Feedback round 3 on 0.4.1 (13 Oct 2026)

The user's notes of 13 Oct on 0.4.1 ([FEEDBACK-2](FEEDBACK-2.md) was round 2), the causes found, the choices and the plan. Design choices were made on [design/feedback-3-preview.html](../design/feedback-3-preview.html) and recorded as [D-53](../DECISIONS.md). The user asked to build all three items together when the computer is idle. The round ships as 0.4.2 ([D-41](../DECISIONS.md) numbering).

## Resume here

- **State:** the user gave the go for the implementation and for commits on 13 Oct ("implementasyona geçebiliriz. commit yetkin de var"). FB3-3, FB3-2 and FB3-1 are done and committed ([verification](#verification)).
- **Release 0.4.2 is installed** (13 Oct) and is the daily app. It ships the round with targeted checks, at the user's choice. The full suite waits for their word (13 Oct: "tam suite test değil geliştirmeleri doğrulayan testleri yap"; "Hedefli testlerle kur"). Record: [Release 0.4.2](#release-042-13-oct). Then the combined check and release 0.4.2. The full suite and the on-screen checks wait for the user's word that the computer is idle ([D-13](../DECISIONS.md)). The user quits Loom for the install.
- **Open from this round:**
  - The full suite, when the user says.
  - The header's hover, ⋯ menu and focus ring, seen in daily use.
  - The subagent rows during a real workflow, seen by the user.
  - The Settings → General cards' secondary text at 4.0:1 (a follow-up).
- **Still open from hardening round 1** ([Resume here](HARDENING-1.md#resume-here)):
  - The user looks for Loom in Screen Time.
  - DEVELOPMENT §5 lacks rows for the H1-F evidence commands.
  - About one point of visible-stream CPU is left for the next performance pass.
  - The old worktrees can be removed once the user says OK.

## Items

| # | User note | Cause or finding | Change | State |
| --- | --- | --- | --- | --- |
| FB3-1 | Usage page: the user loves seeing the data and the detail, but it could read better with cleaner separation | Every block sits directly on the window background with about the same weight. The plan limits sit in the middle. Two different "5 hours" sit apart and are easy to mix up: the plan's limit window and Loom's local activity cells. The five totals have equal weight, though cache reads are most of the tokens | U1, as drawn ([below](#fb3-1-usage-page-u1)) | done; [verification](#verification) |
| FB3-2 | Session header: keep the title, state, project, Stop and ⋯, but give the row a settled structure | The state and the project trail the title, so they move when its length changes. Stop is a tinted capsule and ⋯ is a bare glyph, so they read as two control families | A with the branch, as drawn ([below](#fb3-2-session-header-a-with-the-branch)) | done; [verification](#verification) |
| FB3-3 | Subagent rows: a workflow's implementers showed as finished while they were still running (session `531D1AA3-121E-41D6-8A06-9CF3E50C48BB`) | Loom takes workflow agents for foreground subagents, and the parent's `Stop` ends foreground records ([cause](#fb3-3-cause)) | The parent's turn no longer ends workflow agents ([fix](#fb3-3-workflow-subagents)) | done; [verification](#verification) |

## FB3-3: cause

The planner verified this from the session's files (real `~/.claude`, read only) and from the code.

- **Timing.**
  - At 08:40:53 the parent called `Workflow`. The call returned at once ("launched in background"), and the first six agents started at 08:40:53–55.
  - At 08:41:08 the parent's turn ended (its `Stop` hook ran).
  - The transcripts of those six agents end between 08:48:34 and 08:56:43. Five later agents of the same workflow started from 08:48 on.
- **Files.** A workflow agent's files are under `<session>/subagents/workflows/<wf_id>/`: `agent-<id>.jsonl` and `agent-<id>.meta.json`. The workflow's `journal.jsonl` sits next to them, with `started` and `result` entries per agent id. The meta says `"requestShape":"foreground"` and `"workflowPhase":"Draft"`.
- **Meta lookup.** At `SubagentStart`, `SubagentMeta.fileURL` (`Sources/LoomCore/SubagentLedger.swift:99`) builds `<session>/subagents/agent-<id>.meta.json` from the parent's transcript path. So a workflow agent's meta is never found at that point. Even if it were found, `SubagentMeta.parse` (`:85`) would read it as foreground.
- **The early end.** The parent's `Stop` calls `SubagentLedger.turnEnded` (`:177`, from `ClaudeHook.swift:768`). It ends every running record that is not known to be background. This is the safety net for a lost `SubagentStop` (FB2-3). It ended the six running workflow agents 15 s after they started.
- **Why it stayed wrong.** The ended id is remembered (`:155`, `:164`), so each agent's own `SubagentStop` changed nothing later. The false finish was permanent.
- **Later agents.** Agents that started after that `Stop` should have shown correctly, because the parent sent no other `Stop` while they ran. This is inferred, not observed.
- **Background list.** `BackgroundSubagentTask.parse` (`:39`) keeps only the `type == "subagent"` entries of `Stop.background_tasks`.

Not verified:
- What `Stop.background_tasks` holds while a workflow runs. The hook schema in the Claude 2.1.293 binary lists entries of type `workflow` (with the workflow's `name`) among the in-flight tasks, but no payload was captured.
- That `SubagentStop` fires for each workflow agent when it ends. The rows came from `SubagentStart`, and the docs say the stop event fires when a subagent finishes.

## Planner decisions (routine, reversible)

### FB3-3: workflow subagents

LoomCore only; the rows' drawing does not change.

- **Not bound to the parent's turn.** A subagent whose meta has `workflowPhase` is treated like a background subagent (`isBackground`), and its `requestShape` is ignored. The parent's `Stop` never ends it; its own `SubagentStop` does.
- **Meta lookup.** When `<session>/subagents/agent-<id>.meta.json` does not exist, the lookup tries `<session>/subagents/workflows/*/agent-<id>.meta.json`. The id is validated as today, and the search is one bounded directory listing. At `SubagentStop`, `agent_transcript_path` already points into the workflow folder.
- **Running workflow.** A parent `Stop` whose `background_tasks` lists a running `workflow` task ends no unlisted record. This covers a `Stop` that arrives before the meta is read. Without such an entry, the FB2-3 safety net works as today.
- **Regression tests** in `Tests/LoomCoreTests/SubagentTests.swift`. The first two fail on today's code:
  - A workflow agent (meta under `subagents/workflows/wf_*/`) stays running through the parent's `Stop` and ends with its own `SubagentStop`.
  - A `Stop` that lists a running workflow leaves a foreground-shaped record running.
  - The existing FB2-3 test keeps passing.

### FB3-2: session header, A with the branch

As drawn in the preview's "Chosen" section.

- **Order.** From the left: the window-button gap and the sidebar button as today, the provider mark, then the title, which truncates first. At fixed places on the right: the state pill, the project chip, a hairline and one control group.
- **State pill.** It holds the indicator and the label from `SessionIndicator.label`.
  - Neutral states (Working, Ready, Idle, Stale, State unknown) sit on a light neutral wash. Working uses primary text; the others use secondary text.
  - Attention, failure and unviewed states use their own colour on a low wash of it.
  - `.ended` has no pill.
  - Transient texts take the pill's place as plain secondary text: "Starting — complete any prompts in the terminal", "Deleting…" and the preparing notice.
  - The contrast tiers of DESIGN.md hold (primary 7:1, secondary 4.5:1), and a test measures the pill colours.
- **Project chip.**
  - It starts with the project's tone stripe (`ProjectBranchChip`). There is no stripe when colours are off or the project has no colour.
  - Then come the project name in primary text, a hairline, the branch glyph and the branch name in secondary text.
  - The branch comes from `CatalogModel.branches`, the card's source. It shows for `.named` and `.detached` ("Detached HEAD") and is hidden for `.unavailable`. Its tooltip is "Git branch".
  - A session without a project shows only the branch.
  - The folders of the selection and the tabs keep their branch even when none of their cards is loaded.
- **Control group.** One rounded container holds a Stop segment (stop glyph and text) while `canStop`, and the ⋯ menu segment always, with a hairline between them. The menu items do not change. When the run ends, Stop disappears and ⋯ stays where it is.
- **Narrow window.** The title truncates first, then the branch, then the project name. The pill and the control group never truncate. The row stays 36 pt, and the tab strip does not change.
- **Docs.** DESIGN.md and design/UI-MAP.md describe the new header.
- **As built** (`CUI/SessionHeaderViews.swift`, `LoomTheme.Header`; accepted by the planner):
  - The chip names the project even with Project colors off: neutral, without a stripe. `CatalogModel.headerProjectMark(of:)` does this; the sidebar and the tabs still follow the setting.
  - Ready, Idle and Stale draw no indicator, so their pill has equal insets.
  - Lighter labels keep 4.5:1 on their washes: `#FFB547` attention, `#FF8A85` failure, `#8FB0FF` unviewed. Neutral labels use `Text.secondaryOnTint`.
  - The branch name is capped at 180 pt.
  - The transient texts stand alone, without the indicator.
  - The layout is a custom `HeaderFlow` that follows the pure `HeaderFlowPlan`: the title floor is 100 pt and the chip floor 56 pt. Below a detail width of about 480 pt (the sidebar can be 520 pt wide in a 780 pt window), the title shrinks further.
  - Branch data: `ensureSelectedRow` and `ensureTabRows` now read the branch last, after the requester lookup. Before, a prune in between could drop the branch of a selection whose card was not loaded.

### FB3-1: Usage page, U1

- **Cards.** The page becomes cards on the Settings background, in this order:
  1. **Plan limits**, or the unavailable notice. One row each for 5-hour and Weekly: a bar, "N% used" and the reset phrase. The remaining share moves into the tooltip.
  2. **The period**, titled for example "Last 7 days", with the session count. It shows the total tokens large, then the estimated cost with its API-price note. The token kinds become a list ranked by size with share bars, followed by "Served from the cache N %".
  3. **Activity**: "Tokens per hour" or "Tokens per day" bars with the peak. Under them comes the "Last 5 hours, local" strip with hour labels and its total. "approximate" and "Local activity, not your plan limit" move into its tooltip.
  4. **By model**: the table as today (model, tokens, share, estimated cost).
- **Unchanged parts.** The top bar (scope text and period control) and the footer (updated time, price date, refresh) stay as they are.
- **Card surface.** The existing `SettingsCard` of Settings → General: the 6 % control tone and a 10 pt radius. It replaces the preview's separate 4.5 % wash and hairline, so the two Settings pages match.
- **Window.** The size does not change (680 × 520), and the page scrolls as today.
- **Empty and error states** keep their texts, inside the matching card.
- **As built** (`CUI/UsageReportCards.swift`; accepted by the planner):
  - Secondary text on the cards uses the lifted `Text.secondaryOnTint` tone (`secondaryOnCardStyle`), because plain secondary is 4.0:1 on the card surface.
  - The unavailable card keeps today's two texts under its title.
  - The 24 h axis labels keep a blank line so they clear the baseline.
  - The model table's share column is as wide as "100 %", so the bars line up from row to row. The planner added this after the first renders; it was misaligned before this round too.
  - Follow-up, not in this round: the Settings → General cards still use plain secondary at 4.0:1.

## Slices and checks

| Slice | Writes | Checks |
| --- | --- | --- |
| FB3-3 | `SubagentLedger.swift`, `ProviderSessionAdapters.swift` (meta lookup), `ClaudeHook.swift` (workflow tasks), `SubagentTests.swift` | `scripts/check.sh --suite SubagentTests --suite ClaudeHookTests --suite SessionEventHubTests`. The new tests fail on the old code |
| FB3-2 | `DetailView.swift`, `ProjectColorViews.swift`, `CatalogModel.swift` (branch retention), theme tokens, DESIGN.md, UI-MAP.md, tests | The detail header and theme suites. A layout test at wide and narrow widths (`ImageRenderer`). The pill colours' contrast |
| FB3-1 | `UsageSettingsView.swift`, theme tokens, DESIGN.md, tests | The usage model and settings suites. A render test of the page at 24 h and 7 d, with and without plan limits |

The slices run one after another (D-13), and then:

- **Combined check:** `scripts/check.sh --tests` on the whole round.
- **On screen,** on a dev package with `--evidence` and fake providers:
  - The header in Working, Needs approval and Ready, at wide and narrow widths, with and without a branch, with project colours on and off.
  - The Usage page with fixture usage data, with plan limits shown and with plan limits unavailable.
- **Performance:** the visible-stream row against the 0.4.1 package, because the header is on screen in it.
- **Real Claude:** not planned, because a workflow run spends many turns. If the user wants it, one small workflow in the isolated profile checks the rows end to end.
- **Release:** 0.4.2 through the promote path. The user quits Loom for the install.

## Verification

| Check | Result |
| --- | --- |
| FB3-3: `scripts/check.sh --suite SubagentTests ClaudeHookTests SessionEventHubTests ClaudeRegistryTests` | guards and build ok; 59 tests passed (log `check-20261013T131330-70913.log`) |
| FB3-3 new tests fail without the fix | With the fix disabled (the `turnEnded` guard, `workflowPhase`, the folder rule in `read` and the run-folder lookup), all three new tests failed (9 issues, log `check-20261013T131308-70416.log`). The FB2-3 test `theParentsStopEndsAForegroundSubagentWhoseStopWasLost` still passed |
| FB3-2: `scripts/check.sh --suite LoomCatalogUITests` (window tests skipped) | guards and build ok; 394 tests passed, including the 15 new `SessionHeaderTests` and the 36 + 32 header-and-strip layout test (log `check-20261013T133520-93424.log`) |
| FB3-2 new tests fail without the change | Three changes reverted at once (the old branch read order, a title floor of 0, `.unavailable` shown as a branch): 13 failed expectations in six tests (log copy `~/Library/Caches/loom-fb3/logs/mutation-run.log`) |
| FB3-2 look | Offscreen renders (`~/Library/Caches/loom-fb3/header/`, from `SessionHeaderTests` with `LOOM_HEADER_RENDER_DIR`), checked by the planner:
<br>- Working, Needs approval, colours off, no project, and no project with no branch, at 900 pt.
<br>- Ready at 520 pt: the title shortened.
<br>- Finished at 480 pt: the branch dropped.
<br>Not seen in a real window yet: hover, focus, the menu and Increase Contrast |
| FB3-1: `scripts/check.sh --suite LoomCatalogUITests` (window tests skipped) | guards and build ok; 411 tests passed, including the 17 new `UsageCardsTests` (log `check-20261013T134428-11778.log`). After the planner's share-column change: `--suite UsageCardsTests`, 17 passed (log `check-20261013T134649-15089.log`) |
| FB3-1 new tests fail without the change | Four rules broken at once (the ranking sort, "left" in the used text, the card order, the period capitalisation) plus the card text token: five tests failed (log `check-20261013T134500-12698.log`) |
| FB3-1 look | Offscreen renders at 680 pt (`~/Library/Caches/loom-fb3/usage/`, from `UsageCardsTests` with `LOOM_USAGE_RENDER_DIR`), checked by the planner: 7 d with plan limits, 24 h, limits unavailable, not refreshed, 90 d with four models, and 30 d empty. Not seen in the real Settings window yet: tooltips, scrolling and VoiceOver |

## Release 0.4.2 (13 Oct)

0.4.2 adds feedback round 3 to 0.4.1: workflow subagents, the session header and the Usage page. The user chose the scope: targeted checks only, not the full suite.

- **Targeted checks.** Log `check-20261013T135718-17843.log`: the guards, the debug build, the staged release tree without evidence code, and 187 tests. That is 59 in LoomCore (`SubagentTests`, `ClaudeHookTests`, `SessionEventHubTests`, `ClaudeRegistryTests`) and 128 in LoomCatalogUI (`SessionHeaderTests`, `UsageCardsTests`, `UsageModelTests`, `UsageFormatTests`, `SettingsRoutingTests`, `SidebarFooterTests`, `ConversationTabStripTests`, `LoomThemeTests`, `ProjectColorUITests`). Each slice's earlier runs are in [Verification](#verification).
- **Package.** `Loom-Dev/packages/fb3-candidate`, build 84, `LoomRevision` `0a8fc0b`.
- **On-screen pass on the package.** Fake providers, a fresh data root, launched through LaunchServices. The scratch drivers `fb3.py` and `fb3_continue.py` are in `~/Library/Caches/loom-fb3/onscreen/`; screenshots are in `run-135428/evidence/`. The user allowed the window on screen.
  - **Header, one row per state:**
    - Working: the Claude mark, the title, a Working pill with the chase, `edd-backend | al-audit`, and Stop | ⋯.
    - Needs approval: an orange pill and `enmusait | main`.
    - Ready in a folder without Git: the chip shows only the project.
    - Stopped: no pill and no Stop; ⋯ stays at the trailing edge.
    - 780 × 500 window: the title shortens, the branch drops, and the pill and the group stay.
    - Sidebar collapsed: the row starts after the sidebar button.
  - **Usage page in the real Settings window** at 7 d, 24 h and 30 d: the cards scroll between the top bar and the footer. There are no plan limits with fake providers and no failure reason, so there is no plan card.
  - **Totals** equal the fixture's sums: 176 lines; 270,909 input, 255,018 output, 2,766,120 cache write and 23,147,645 cache read tokens.
  - **First driver run:** it stopped early because it waited on the activity list, which is empty in the project view. The tab rows held the right states, and the continuation finished the pass on the same instance. Quit was clean.
- **Tag, promote, install.** Tag `release/0.4.2` → loom-dev `83c56db`; loom `f6968f3` / `v0.4.2` (270 files). The release products were built ahead in the loom tree. The user quit the daily Loom, and `build.sh` built and swapped `/Applications/Loom.app`. Checked:
  - Deep-strict signature; version 0.4.2, `CFBundleVersion` 10, `LoomRevision` `f6968f3`, the category.
  - LaunchServices holds one record, version 10.0.
  - The binary holds the round's types (`HeaderFlowPlan`, `ProjectBranchChip`, `UsageCardText`, `listsRunningWorkflow`) and the new Usage texts, and no evidence code.
  - The install did not touch the user's data: the catalog was last written at 17:10:57, as Loom quit; the install was at 17:11:21.
- **Not run:**
  - The full suite (the user's scope).
  - Hover, pressed fills, the focus ring and the ⋯ menu opening; screenshots cannot show them.
  - Increase Contrast.
  - Real plan limits on the Usage page.
  - A real Claude workflow.
