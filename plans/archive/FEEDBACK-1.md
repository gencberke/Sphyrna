# Day-one feedback on 0.2.1 (8 Oct 2026)

The user's first daily-use notes on `Loom.app` 0.2.1 ([D-36](../DECISIONS.md)), the causes found, what changed and what is still open. Investigation reports (file:line evidence) were kept outside the repo under `~/Library/Caches/loom-run1/feedback1/`.

## Items, causes and changes

| # | User note | Cause | Change | Commit |
| --- | --- | --- | --- | --- |
| 1 | After Stop → Resume the card read "State unknown", even while the agent worked | The hook tracker treated every SessionStart as "state unknown" until the first prompt; a late SessionStart of the run's own conversation wiped a prompt that arrived first; any Notification type it did not know reset the state to unknown. The exact trigger of the "unknown while working" case was not reproduced (a real resume in the isolated profile showed Working → Finished); dropped hook events were invisible in a daily build | SessionStart = at the prompt (`AgentActivity.atPrompt`, shown as Ready); a late SessionStart of the same conversation keeps the turn; informational notifications and unknown registry statuses keep the state; `elicitation_dialog` waits for the user; dropped events and unknown notification types are logged (`local.loom.desktop` / `ClaudeHooks`) | `955b326` |
| 1 | The resumed model was not at the effort the user set | Claude keeps `/effort` for one process; `max` is never saved ("Set effort level to max (this session only)" in the user's transcript), so `--resume` fell back to the saved default | Resume reads the last `effort` Claude recorded on an assistant message (transcript tail) and passes it back with `--effort` | `955b326` |
| 1 | "Am I talking to a Claude that remembers?" | Yes: `--resume` loads the same transcript (same conversation id, same file); the real check had the resumed Claude repeat a word it was told only before the Stop | Answered; `scripts/perf/claude_resume_real.py` keeps it as an acceptance step | `955b326` |
| 1 | (why it was stopped) | Loom's idle policy stopped the run after 60 min without use (`end_reason idle`, 13:25); the user resumed at 13:35 | Not changed: a product decision (open point 1) | — |
| 2 | Card time stuck at "now" for an hour; minutes inconsistent after resume | Viewing re-stamped `last_used_at`, which also drove the card time; the minute tick ran only while the window was key | `sessions.last_activity_at` (added inside schema v3, no version bump, so 0.2.1 still opens the catalog); start, resume, prompt, finished turn, `/resume` identity change and the user's Stop stamp it; viewing does not. The tick follows window visibility | `8e9ff0b` |
| 3 | Project name repeated on cards in the project view | Not found in code: the project view already hides it (D-10, `SessionCardView.projectLabel`) | None; screenshot requested (open point 4) | — |
| 4 | Clicking an old session in the activity view pulls it to Today | Same as item 2 | Same as item 2 | `8e9ff0b` |
| 5 | "+" on project headers to start a Claude session | Not built | `ProjectStartButton` before the ellipsis menu | `bd22b90` |
| 6 | Gap between the title and the tabs (or tabs above the title) | The header kept its 16 pt bottom padding above the strip | Gap closed (header row 36 + strip 32 pt, as in the approved preview); tabs above the header would have decided O-03 | `bd22b90` |
| 7 | No manual permanent delete in the daily app | Deliberate production gate while DP-CP4-1 was open (RC-0.2.0 disclosed it) | "Delete Permanently…" in every build (card menu, detail menu, File menu Cmd+Delete); the cleanup review stays development-only (`BuildIdentity.cleanupReviewEnabled`, DP-CP4-2) | `bd22b90` |
| 8 | Sessions without a project; right-click empty sidebar area → New Claude Session | Runtime supported it; no UI entry | Empty-area menu "New Claude Session" (home folder) and footer "New Claude Session Without Project" | `bd22b90` |
| 8 | Say "session", not "conversation" | No vocabulary rule | Wording sweep plus `scripts/check-user-wording.sh` (run by `check.sh`) | `ed2914c` |
| 9 | Usage page not current; bottom bar should show today's tokens and the remaining plan limit, no money | Refresh needed the main window to be key (Settings is another window); turn completion came from a coalesced frame; plan limits had no source | FSEvents transcript watcher; Settings counts as a reader; turn-completion counter in the event frame; plan limits from the Claude CLI's own `get_usage` control request (T3 Code's method; hooks disabled, no MCP servers, no session kept); chip "1.2M today · 5h 62% left" without money; Plan limits block on the Usage page | `6d487b4` |
| 10 | Sidebar hid but did not show again | Not reproduced. The model flag was copied from a resize callback and could disagree with AppKit | AppKit's `NSSplitViewItem.isCollapsed` (KVO) is the one truth; the Show button and the model mirror it; a toggle acts on the real state | `bd22b90` |

## Why 600+ passing tests missed these

The suites prove that reducers handle fake events and that each unit does what its author specified. These problems sit where no test or script looked:

- **Real Claude after Stop → Resume.** No real-Claude script resumed; the fake provider and the tracker tests encoded the same model (SessionStart, then a clean prompt/stop sequence), and a tracker test asserted "unknown after SessionStart" as correct.
- **Behaviour pinned as specified.** "Viewing counts as use" (contract §5, for staleness) was applied to the displayed time, and tests asserted it; the deletion gate was a test-pinned decision waiting on DP-CP4-1.
- **Live window over time.** The minute tick was tested with an injected clock only; the sidebar toggle and the two-window usage topology were never driven.
- **Production identity.** Acceptance ran on development packages, where deletion is on.

New tests now cover each changed behaviour (each fails without its change). The real-Claude resume check is `scripts/perf/claude_resume_real.py`. A "day in the life" release protocol (resume, time, sidebar, usage, keyboard layout steps on a production-faithful package) is proposed in the test-gap report and needs an idle, unlocked Mac.

## Decisions taken to satisfy explicit requests

Recorded as [D-37](../DECISIONS.md). Each reverses cleanly:

- Manual deletion in production uses the CP4-A default allowlist already used in development builds.
- Plan limits use one short headless `claude -p` per ask (first window, Usage page opened, a finished turn after ≥ 2 min, a window shown again after ≥ 5 min; never while hidden). This relaxes D-32's "no extra CLI processes" for this purpose only.
- Resume passes the recorded effort back (`--effort`), a D-20 class change made because the user asked for continuity.
- A Claude that just started or resumed shows **Ready** (no attention dot), not "Waiting for you".

## Open points for the user

Answered on 8 Oct:

1. **Idle auto-stop:** turn it off ([D-38](../DECISIONS.md)); done in `b997885` (`SessionIdlePolicy.stopsIdleRuns = false` in the app; stale classification unchanged).
2. **Plan-limit asks:** the user asked what collects the numbers; explained (tokens come from Claude's local transcripts read by Loom; the plan percentages come from the Claude CLI's own `get_usage`, which asks Anthropic with the CLI's login). Cadence unchanged.
3. **Sidebar:** the Show button **was visible** when the click did nothing. Two read-only investigations and a judge found no deterministic cause in code (an animated expand AppKit ignored or lost, or a click that never reached the button); `ee0fea1` applies a move AppKit did not carry out without animation, serializes toggles, routes Ctrl+Cmd+S through the same path and logs each toggle (`local.loom.desktop` / `Sidebar`), so a repeat shows whether the click arrived.
4. **Project name on cards:** no answer yet; screenshot if it still appears.
5. **Install:** the user asked to install this round as 0.3.0 without running the full release suite ([D-38](../DECISIONS.md)); done, see [Release 0.3.0](#release-030).

## Verification (8 Oct 2026, swarm/1 `ed2914c`)

| Check | Result |
| --- | --- |
| `scripts/check.sh --suite LoomCoreTests --suite LoomCatalogUITests --suite LoomLaunchOptionsTests` (debug, window tests skipped) | 452 + 246 passed on the combined tree before the wording sweep; after it, the sweep's own run 452 + 246 and on swarm/1 LoomCatalogUITests, LoomLaunchOptionsTests, SessionRuntimeTests, ConversationDeletionTests 246 + 51 passed |
| New tests fail without their change | checked per slice by disabling the change (tracker, effort, tick, view stamp, Stop-hook stamp, usage reader paths, tab spacing) |
| `scripts/check.sh --release-tree` | staged production tree builds, no evidence code |
| Real Claude: `scripts/perf/claude_resume_real.py` on `packages/fb1-candidate` | 9/9: Ready → Working → Finished before the Stop; **Ready** after Resume (was "State unknown" on 0.2.1's twin); the resumed turn Working → Finished; the resumed Claude repeated the word from turn 1; one transcript; effort max before and after (the profile's saved default is high). [Evidence](experiments/fb1-claude-resume-real.json) |
| Plan-limit source | `get_usage` answered on the isolated profile (CLI 2.1.293) with integer percent and ISO reset times in about 0.6–1.4 s; without `disableAllHooks` the profile's SessionStart and SessionEnd hooks ran for every ask, with it none ran |

Not verified: anything that needs a visible, unlocked window over time (live minute tick, a real right-click on the empty sidebar area, real sidebar toggling, chip and Plan limits visuals, Settings window topology), the full release suite, `get_usage` from the app on the real profile, and a real deletion through the production identity.

## Pre-release review (0.3.0)

A four-area read-only review (hooks and resume, catalog time, usage and plan limits, sidebar and menus) of `955b326..ee0fea1`, each finding checked before fixing. Fixed in one commit; each new test fails without its fix (checked by disabling all six at once):

| Area | Finding | Fix |
| --- | --- | --- |
| Menus | `validateMenuItem(_:)` was never exposed to Objective-C (no `NSMenuItemValidation` conformance), so File → Delete Permanently… (Cmd+Delete) stayed enabled while typing in the terminal or a text field; Cmd+Backspace there could open the delete sheet | `NSMenuItemValidation` conformance; the key equivalent yields to a text view, the terminal or an open sheet |
| Hooks | A prompt dropped before the first SessionStart was known (prompt typed at once) was followed by **Ready** while Claude worked | That start leaves the state unknown until the next event |
| Hooks | `elicitation_dialog` waited for input with no generation, so the registry's later "busy" sample could not move the card back to Working | It opens an input generation like a permission prompt |
| Effort | An effort level this build does not know fell back to an older recorded level | The newest assistant record with an effort decides; an unknown level means no carry-over |
| Catalog | A row 0.2.1 inserted has no `last_activity_at`; a view of it copied the view time into the fallback | A view freezes the fallback at the previous use date; the column check is repeated inside the migration transaction |
| Catalog | A turn ended by an API error (`StopFailure`) did not stamp activity; a stamp refused for a session being deleted threw and kept the turn's status from being published | `StopFailure` stamps too; the stamp is best effort |
| Usage | The default profile pinned `CLAUDE_CONFIG_DIR` to `~/.claude` even when the toolchain set another directory; a failed ask (offline after wake) cleared the limits; the minute tick did not drop an ended window while the window was not key; Refresh on the Usage page did not ask for limits; percentages outside 0–100 were not clamped | Only an explicit profile is pinned; a failed ask keeps the last answer; the chip is rebuilt on every tick; Refresh asks when due; clamp before rounding |
| Sidebar | A second click while the first Show had not taken effect reversed it (stayed hidden) | A toggle during a move finishes a move AppKit has not carried out, and reverses one that took effect |
| Wording | The footer and the empty-area menu named the projectless start differently | One title, "New Claude Session Without Project" |

Not changed: model-scoped weekly windows (`seven_day_opus` and similar) are not shown in the chip or the Plan limits block; whether to show them is the user's call.

Checks after the fixes: `scripts/check.sh` on the affected suites 136 + 249 passed (build and wording guard ok), then the seven directly affected suites 47 + 45 passed after the mutation check; the full release suite was **not** run (the user asked to install without it).

## Release 0.3.0

Installed 8 Oct 2026, 09:27: tag `release/0.3.0` → loom-dev `1681f0f`; promoted into loom as `e392d7c` / `v0.3.0` (227 files); `/Applications/Loom.app` 0.3.0 built by the loom tree's `build.sh` (Loom.app was not running). Checked: deep-strict signature, version 0.3.0 and `local.loom.desktop`, the menu validation selector and the shared projectless title in the binary, no development evidence strings in `Loom`, `loom-hook` or `loom-run-host`; an isolated hidden launch (own `--data-root`, empty `CLAUDE_CONFIG_DIR`) created catalog schema 3 and the usage index, exited on SIGTERM with no process left and did not touch the preferences file or `~/Library/Application Support/Loom`. Not run: the full release suite and the visible checks (the user asked to install without them).

## Real-Claude turns

Phase budget from the user: about 6 short turns. Used 5: 3 for the reproduction before the fixes (one lost to a wrong wait) and 2 for the verification above.
