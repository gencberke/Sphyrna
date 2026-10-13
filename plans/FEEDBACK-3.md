# Feedback round 3 on 0.4.1 (13 Oct 2026)

The user's notes of 13 Oct on 0.4.1 ([FEEDBACK-2](FEEDBACK-2.md) was round 2), the causes found, the choices and the plan. Design choices were made on [design/feedback-3-preview.html](../design/feedback-3-preview.html) and recorded as [D-53](../DECISIONS.md). The user asked to build all three items together when the computer is idle. The round ships as 0.4.2 ([D-41](../DECISIONS.md) numbering).

## Resume here

- **State:** the user gave the go for the implementation and for commits on 13 Oct ("implementasyona geçebiliriz. commit yetkin de var"). FB3-3 and FB3-2 are done and committed ([verification](#verification)).
- **Next:** FB3-1, then the targeted checks of the round (the user, 13 Oct: no full suite until they say so). Then the combined check and release 0.4.2. The full suite and the on-screen checks wait for the user's word that the computer is idle ([D-13](../DECISIONS.md)). The user quits Loom for the install.
- **Still open from hardening round 1** ([Resume here](HARDENING-1.md#resume-here)):
  - The user looks for Loom in Screen Time.
  - DEVELOPMENT §5 lacks rows for the H1-F evidence commands.
  - About one point of visible-stream CPU is left for the next performance pass.
  - The old worktrees can be removed once the user says OK.

## Items

| # | User note | Cause or finding | Change | State |
| --- | --- | --- | --- | --- |
| FB3-1 | Usage page: the user loves seeing the data and the detail, but it could read better with cleaner separation | Every block sits directly on the window background with about the same weight. The plan limits sit in the middle. Two different "5 hours" sit apart and are easy to mix up: the plan's limit window and Loom's local activity cells. The five totals have equal weight, though cache reads are most of the tokens | U1, as drawn ([below](#fb3-1-usage-page-u1)) | planned |
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
  - It starts with the project's tone stripe, as `ProjectHeaderMark` draws it. There is no stripe when colours are off or the project has no colour.
  - Then come the project name in primary text, a hairline, the branch glyph and the branch name in secondary text.
  - The branch comes from `CatalogModel.branches`, the card's source. It shows for `.named` and `.detached` ("Detached HEAD") and is hidden for `.unavailable`. Its tooltip is "Git branch".
  - A session without a project shows only the branch.
  - The folders of the selection and the tabs keep their branch even when none of their cards is loaded.
- **Control group.** One rounded container holds a Stop segment (stop glyph and text) while `canStop`, and the ⋯ menu segment always, with a hairline between them. The menu items do not change. When the run ends, Stop disappears and ⋯ stays where it is.
- **Narrow window.** The title truncates first, then the branch, then the project name. The pill and the control group never truncate. The row stays 36 pt, and the tab strip does not change.
- **Docs.** DESIGN.md and design/UI-MAP.md describe the new header.

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
