# Feedback round 5 on 1.6.0 (24 Oct 2026)

This file records the round that started from `@user`'s first notes on the installed Sphyrna 1.6.0:
- `~/Desktop/gelistirme.md` of 23 Oct;
- two chat rounds of 24 Oct.

It covers what the code says about each note (`v2` at `988256a`), what other apps do, the decisions `@user` made (D-93 to D-99) and the plan for 1.6.1 and 1.6.2. [FEEDBACK-4](archive/FEEDBACK-4.md) was round 4.

## Resume here

- **The go (24 Oct, about 12:50):** `@user` said the Mac would be idle and the work could start. The open questions take their defaults. 1.6.1's slices run from [ACTIVE-PLAN §0](archive/ACTIVE-PLAN-1.6.0-to-1.7.2.md#0-round-5-sphyrna-161-from-24-oct-d-93).
- **State before the go:**
  - The causes are traced by read-only explorers, and the planner checked the decisive lines.
  - Four web and code studies are done: usage with harness health, competitor UX, T3 Code's usage and providers pages, and Chat's streaming cost.
  - `@user`'s decisions are recorded as D-93 to D-99.
  - Nothing is built yet. This file, DECISIONS, STATUS and plans/README are edited and not committed.
- **Open:**
  1. The go for 1.6.1's slices.
  2. One observation for FB5-2: do the Settings page's own controls answer a click, for example General → Sessions run in?
  3. Defaults `@user` has not confirmed yet: Q3, Q6 and Q7, and Chat's Q13 to Q17, in [the decisions](#decisions).
  4. Remora's default in the public build (Q2), needed before the first public push.
- **Next:** on the go, W1-a starts with a failing shown-window click test (it needs the idle Mac), and the slices with disjoint write sets run beside it ([1.6.1's slices](#release-161-slices)).

## Release line (D-93)

| Release | What it holds |
| --- | --- |
| **1.6.1** | The fixes and identity work (FB5-1 to FB5-5); drag and drop and flow (FB5-6); several drafts (FB5-3); Chat's streaming cost (FB5-10); two log faults (FB5-11, FB5-12). Promoted as `1.6.1`. |
| **1.6.2** | The app-wide infrastructure for Codex at parity (D-94): Settings → Connections (FB5-8), Usage after T3 Code with Codex (FB5-7), every surface made ready through harness-neutral seams (FB5-9). |
| **1.7.0** | The session channel (CP3) and Codex's binding. Planned with `@user` later. |

The push and the GitHub release still wait for `@user` (D-16, D-83). A push after 1.6.1's promote carries both the 1.6.0 and the 1.6.1 commits of the clean tree.

## Items

| ID | Area | The user said | Kind | Finding in one line | Release |
| --- | --- | --- | --- | --- | --- |
| FB5-1 | Inspector | "çerçevesinden tutup büyük küçüklüğünü ayarlayamıyorum" | Design change | The widths are fixed by D-78, with no handle | 1.6.1 |
| FB5-2 | Settings | "genel olarak settings'te sekme değiştiremiyorum" | Bug | Deterministic; prime suspect: the window moves by its background | 1.6.1 |
| FB5-3 | Remora, drafts | "put in draft çalışmadı … birkaç draft tutabilmem iyi olur" | Design change and bug | The line was copied to the clipboard; the label never clears | 1.6.1 |
| FB5-4 | Remora | "hamsi gibi duruyor … sabit bir görsel" | Design change | It is the 110 pt ASCII resting remora | 1.6.1 |
| FB5-5 | Identity | "simgesi recognizable değil pek" | Design change | The ASCII strokes vanish below 128 px | 1.6.1 |
| FB5-6 | Whole app | Drag a project, drag a session to the tab strip, drop a session onto a chat; "bunun gibi" | Features | Most seams exist | 1.6.1 |
| FB5-7 | Usage | "codex'inde görünebilirliğini arttırmak gerek"; "T3 code bu usage sayfasını çok iyi oturtuyor" | Feature | Nothing reads Codex usage today | 1.6.2 |
| FB5-8 | Settings | "harness'ların … sağlık durumunun listelendiği … bir sekme"; "connections daha iyi" | Feature | There is no harness health model | 1.6.2 |
| FB5-9 | Codex | "yüzeylerdeki hazırlığını yapalım"; "ikincil deneyim olarak varsayamayız" | Feature | The entries exist; most surfaces are Claude-only | 1.6.2 |
| FB5-10 | Chat | "chat cost'unuda bu turda incelemeye alalım" | Performance | 3.8× the terminal's CPU at 600 chars/s, 2.5× at 6,000; most of it is a fixed cost per flush | 1.6.1 |
| FB5-11 | Home | (found in the log) | Bug | A SwiftUI fault in Home's Remora reads | 1.6.1 |
| FB5-12 | Run host | (found in the log) | Bug | A Security call on `loom-run-host`'s main thread | 1.6.1 |

The user also asked how the name is said. It is /ˈsfərnə/ (Merriam-Webster), roughly "sfır-na", from the Greek *sphyra*, hammer.

## What the code says

### FB5-1: the inspector's widths are fixed by design

- The inspector is not a split view item. `detailInspector` (`InspectorContainer.swift:226-259`) lays it out in SwiftUI beside the content, under the 52 pt header.
- Its width comes from the tab: 328 for Overview and the Agents list, 392 for Side, 556 for Changes and a subagent transcript (`InspectorTab.width`, `shownInspectorWidth`). No width is persisted.
- D-78 fixed the widths and made changes instant, so that a terminal resizes at most once per change. A live drag would cost two things on every pixel:
  - a PTY resize, one SIGWINCH per grid change (`TerminalSurface.swift:344-357`);
  - a main-actor re-measure of every visible Chat row (`ChatStreamController.viewResized`, `ChatHeights.swift:150-164`).
- The left sidebar is the in-app precedent for a handle: an `NSSplitViewItem`, 220–520 pt, persisted 250 ms after a drag.

### FB5-2: Settings tabs do not switch (general, deterministic)

**What `@user` reports (24 Oct).**
- A click on another tab never switches, from any tab.
- It happens whichever door opened Settings: the usage chip, or Home's Remora ⋯.
- The window does not move.

**What is ruled out.**
- Nothing in the code selects a tab on its own. `SettingsNavigation.section` changes only on a tab click, on `show(section:)` from an explicit door, and in `openRemoraMemory` (`SettingsView.swift:29-50`).
- The sheet layer is consistent: `isOpen` is `presented != nil`, and its scrim exists only while a sheet is presented (`SheetFamily.swift:60-89, 101-125`).
- Two days of the installed app's log hold no line about Settings and no error tied to it.

**Prime suspect: the window moves by its background.** This is inferred, not proved.
- `SettingsWindowController.swift:57` sets `isMovableByWindowBackground = true`; it has done so since U12 (7 Oct). The main window does not set it, and its header's controls answer clicks.
- In a window that moves by its background, AppKit treats a mouse-down on a view that does not claim it (a non-opaque view) as the start of a window drag. SwiftUI's own buttons are drawn, not AppKit controls. A still click then moves nothing and fires nothing.
- Ink's Settings (21 Oct, D-88) put the section tabs in the 52 pt title strip. Nothing ever clicked them:
  - the tests and the evidence runs switch tabs through `navigation.section` or `open-settings:<tab>`;
  - synthesised clicks do not reach SwiftUI in a window that is not shown (`InkSettingsHostedTests.swift:8-12`).
- The proof is a shown-window click test, which runs while the Mac is idle. `@user`'s observation of the page's own controls splits the two candidates:
  - if those controls fail too, the cause is the window flag;
  - if they work, the cause is the title strip.

**Also found.**
- A sheet left open outlives the window: closing does not dismiss `navigation.sheets`.
- The menu bar's Settings… forces General, while ⌘, keeps the tab.
- Every show runs a usage refresh (`refresh(.settingsOpened)` → `start()`), off the main actor.

### FB5-3: Put in Draft copies when the composer has text, and its label never clears

- **Where the line goes.** Home's Put in Draft puts the tile's "Next:" line in **that session's** Chat composer, not in a new-session draft. The path is `HomeRemoraTileViews.swift:153-176` → `remoraDraftTarget(for:)` (`CatalogModel+RemoraDraft.swift:113-121`).
- **When it copies instead.** The old rule (`RemoraPutInDraft.plan`, `:50-62`) copied the line when the composer or its saved draft held text, and when the session ran in a terminal.
- **What the user saw.** Only a small label ("Copied: it already has a draft"), and nothing navigated.
- **Two meanings of "draft".** The sidebar's Draft is something else: the one new-session draft each project keeps. The two meanings met in `@user`'s report.
- **Bug.** After any result the button is replaced by the label for as long as Home stays mounted. `HomeRemoraUI.placed` is set at `HomeRemoraTileViews.swift:164` and never cleared.
- **Draft Brief.** It copies when the draft holds other text, and Draft Again copies again (`DraftRemoraModel.swift:209-230`).
- **One draft per project.** A project keeps one draft (`new-session.json`). When the file loads, a second draft for the same project is dropped (`CatalogModel+NewSession.swift:75`).

### FB5-4: the "anchovy" is Remora's resting remora

- **What it is.** The 110 pt ASCII remora, in 6 pt semibold cells at alpha 0.82, resting at the start of the brief's sentence (`ArtPlace.remoraLane`, `HomeRemoraArt.swift:103-120`).
- **Where else it appears.** A 72 pt copy starts the folded brief. In the arrival, the band's hammerhead carries it in (D-80).
- **Why it reads wrong.** At this size the disc's plates read as a stripe.

### FB5-5: the Dock icon dissolves below 128 px

- **How it is built.** Rising is ASCII glyphs about 14.6 px tall on a 1024 px canvas (1.4 % of the height), on black. The pipeline is `design/identity/icon-foreground.png` → `scripts/make-app-icon.sh` → `assets/icon/{Sphyrna.icon, Assets.car, Sphyrna.icns}`.
- **Measured.** The mean luminance is 1.7 % at every size. At 64 px, only 0.2 % of the pixels pass 100/255, and the brightest is 45 % grey.
- **Why it fails.**
  - The diagonal side view hides the hammer.
  - The black ground sits beside Terminal and Activity Monitor.
  - Its one image layer has no appearance specialisations.
- **The bolder variant.** The identity preview (`design/pre-reference-preview-pages/identity.html`, "Round 1 and round 2") holds a bolder variant: Rising, round 1, at 0.8 of the square, placed by its head.

### FB5-6: what exists for drag and drop

| Want | Today | Seam |
| --- | --- | --- |
| Drag a project to reorder it | Move Up and Move Down only | `SessionCatalog.moveProject(id:toIndex:)` and `projects.sort_order` exist. No schema change |
| Drag a session to the tab strip | A double-click or "Open in Tab" pins it | `openTab` pins, and refuses when 8 are pinned and none can go. There is no `pin(_:at:)`, no `move` and no drop target. The strip hides below 2 tabs |
| Drop a session onto a chat | Typing `@` lists 8 Claude sessions and inserts `[Another session, "title" · transcript <path> · its last answer began: …]` as text (`sessionMentionText`, `CatalogModel+LiveComposer.swift:59`) | A pill needs a new attachment kind in the draft store, in `ComposerAttachment.outgoing` and in the chip row |
| Drop files and folders into the chat | The live Chat composer takes files and images. A file becomes `@path` (`ComposerTextEditor.swift:77`, `ChatComposerModel+Attach.swift`) | A folder's result is not checked yet. The draft, Side and Quick Question composers return `false` from `drop` |
| Drop files into the terminal | **Done since CP5** (`TerminalSurface.swift:168, 439-448`, tested) | O-07 and D-21 still call it deferred: a docs fix |
| Reorder queued messages | Done (the queue strip) | The in-repo pattern for a SwiftUI drag |
| Dock menu, notification actions | None | SPEC §11 says the notification is silent, with no buttons |

The sidebar list is a `LazyVStack`, not a `List`, so each drag needs its own source, target and insertion mark. Drag against click on rows with tap, double-tap and context menus needs a check by hand.

### FB5-7 to FB5-9: usage, harnesses and Codex

**Usage is Claude only.**
- The surfaces: the chip, Settings → Usage, Home's Plan limits and Today, and the project page's Past 7 days.
- The sources: `ClaudeUsageIndex`, plus one `claude -p` child that answers `get_usage`. That child makes no model call, and it runs on events with floors, never on a timer.
- Nothing reads Codex:
  - The Codex connection opts out of `account/rateLimits/updated` (`CodexAppServer.swift:241-242`).
  - The index has no provider dimension.

**There is no harness health model.**
- `HarnessRegistry` covers session behaviour only.
- The binaries are found on the login shell's `PATH`, with no override and no minimum version.
- Sign-in is known only from a Remora failure.
- Usage reads `CLAUDE_CONFIG_DIR` from Sphyrna's own environment, while sessions read the login shell's.

**Codex's entries are shown and disabled; its surfaces are mostly Claude-only.**
- Overview, Changes' turn scopes, Agents, Side, Rewind, Quick Question and the Chat face are Claude-only.
- The palette's transcript search hard-codes `provider == .claude`.
- Remora lists Codex sessions but never reads them.
- The project page's usage is Claude-only.
- The model popover shows three hard-coded Codex names.

### FB5-10: where Chat's streaming time goes

The study re-read the RC pool's C8 profiles of `c5b5dd3` (`evidence/core/budgets/run-c5b5dd3/`); their line numbers match today's source. Nothing was run. Measured there: Chat 23.3 % of one core at 600 chars/s and 48.9 % at 6,000, against the terminal's 6.1 % and 19.6 % (`BUDGETS-c5b5dd3.md`).

| Share of the busy main thread (the rows overlap) | 6,000 chars/s | 600 chars/s |
| --- | --- | --- |
| SwiftUI's display cycle (`NSHostingView.layout`) | 50 % | 40 % |
| The focus bridge rebuilding the key-view loop | 22 % | 11 % |
| The row measurer (`sizeThatFits`) | 15 % | 19 % |
| The open tail's text selection | 12–16 % | 5 % or more |
| Markdown parsing | 5.5 % | under 1 % |

- **A cost per flush, not per character.** About 16 ms of main-thread work per 80 ms flush at 600 chars/s, and about twice the terminal's cost per extra character (inferred from C8's numbers). So the number of flushes is a direct lever.
- **The focus bridge.**
  - Each flush swaps the cell's `rootView` (`ChatStreamViews.swift:116-118`).
  - SwiftUI's preferences change, and its focus bridge rebuilds AppKit's key-view loop over every live row. That lays those rows out again and asks each one whether it takes focus.
  - ARCHITECTURE §12.2 item 9 removed `reloadData`, but the swap reaches the same path.
  - Which preference changes is unknown. The candidates are the selectable text, and the code card's buttons and hovers.
- **Selection.** `.textSelection(.enabled)` on the open tail (`ChatMarkdownViews.swift:167, 204, 259, 314`) builds a second text layout on every flush.
- **Three layouts of the same text.** `refresh` measures the open tail in a separate hosting controller (`ChatHeights.swift:186`), the display cycle lays it out in the cell, and the selection lays it out again.
- **Memory.** One message is one row and one hosting view. CoreAnimation grows from 26 to 141 MB within one message while the heap stays flat: about 4 KB of backing store per character, as D-92 noted. That the backing store covers the off-screen part is inferred.
- **Long blocks** (verified in the code, never measured). The head and the open tail split only at a blank line outside a fence (`ChatContent.swift:211`). This has three effects:
  - A long fence or a tight list stays the whole open tail, laid out and measured on every flush: O(n²) per message.
  - The head is re-parsed whole each time it grows (`ChatContent.swift:127-147`). This is O(n²) in today's fixture too: parsing grows from 7 to 183 samples for 10 times the rate.
  - A fence inside a quote makes the message non-composable, so the whole message is measured on every flush.
- **A stale line.** SPEC §7.2 says 50 ms frame coalescing; the code shows streaming text every 80 ms (`ChatPresentation.swift:58`).

### FB5-11 and FB5-12: two faults in the log

Found while reading the installed app's log for FB5-2, from 22 to 24 Oct.
- **FB5-11:** `onChange(of: HomeRemoraReadKey) action tried to update multiple times per frame`, once. Home's Remora read key changes more than once in one frame (`HomeRemoraCalls.swift`).
- **FB5-12:** `loom-run-host` logged 14 runtime-issue faults from Security: "This method should not be called on the main thread as it may lead to UI unresponsiveness". The helper has no UI, so this is noise rather than a hang, but it costs a fault per run.

## What other apps do

### Usage and harness health (study of 24 Oct)

O marks an official, documented source.

**Codex limits without a model call.**
- The newest rollout's `token_count.rate_limits`: local, undocumented, and stale between turns.
- A short `codex app-server` over stdio: `initialize`, then `account/read`, then `account/rateLimits/read` (O). This is a backend read made by the CLI with its own login, as `get_usage` is for Claude; Sphyrna never sees a token.
- Tell the windows apart by duration (`windowDurationMins` or `window_minutes`), not by slot. The main bucket is `codex`.

**Health checks, cheap and local:**
- `command -v` in the login shell.
- `claude --version` and `claude auth status` (O): JSON with `loggedIn`, `authMethod`, `subscriptionType` and `configDirectory`.
- `codex --version` and `codex login status` (O).
- The app-server's `account/read` (O).

**Heavier checks**, run only behind a button: `claude doctor`, `codex doctor --json`, and `claude mcp list`.

**What to avoid.** Calling `chatgpt.com/backend-api/wham/usage`, or Anthropic's OAuth usage endpoint, with the user's tokens. Anthropic's legal page forbids intermediating Claude.ai tokens.

### Competitor UX (study of 24 Oct)

**Studied:**
- Claude desktop's Code tab, and the ChatGPT desktop app with Codex.
- Conductor, bb, T3 Code, Emdash, Superset, HumanLayer, Amp, Prowl, cmux, Happy, Warp.
- VS Code's Agents window, Cursor 3, Zed.
- CodexBar, and Claude Code's agent view.

**Dropped:** Crystal (deprecated), opcode (stale), Vibe Kanban (company shut down).

| Area | Pattern | Who |
| --- | --- | --- |
| Drag and drop | Drag projects to reorder them | Claude desktop (Jun 2026), Conductor, Codex |
| | Drag a session to a pane's edge to split; ⌥-click to split, ⌘-click for a new window | VS Code, Claude desktop, Cursor 3.1 |
| | Drag a thread into the composer to mention it as a pill | bb |
| | Drop files anywhere in the window to attach them | HumanLayer, Claude desktop, Zed |
| Cross-session | Mention another thread (`@T-…`, `@` threads) | Amp, Zed |
| | The agent reads and messages other sessions | Claude desktop |
| | Hand a session between Claude and Codex | HumanLayer, bb |
| Attention | An activity bell with All, Unread and Errors | Codex, Warp, HumanLayer |
| | A notification level per session; snooze until the next reply | bb, Amp |
| | Keep the Mac awake while an agent works | Zed |
| Review | "Changed since your last review", viewed marks | HumanLayer, Conductor |
| Harnesses | A providers page: version, sign-in, plan, path, an on/off switch | T3 Code, Conductor, Emdash |
| Usage | Plan meters, countdowns to the reset, usage by provider, model and day | Claude desktop, CodexBar, T3 Code |
| Delight | Quick entry from anywhere; a floating companion | Codex, Claude desktop |
| | A suggested next prompt | Claude desktop, Codex. Not for Sphyrna: a background model call |

`codex mcp-server` was removed after 5 Sep 2026. `codex app-server`, the path Sphyrna's Codex code uses, is labelled experimental.

### T3 Code in depth (study of 24 Oct)

T3 Code is MIT-licensed. Its providers page is Settings → Providers; its "Connections" means remote environments, so Sphyrna's Connections (D-98) follows T3's Providers page. The study read the clone of 17 Oct and checked `main` of 24 Oct.

**How it reads facts.**
- It asks the vendor CLI for health, account, plan and limits.
  - Claude: an SDK child that never sends a message, reading `initialize`'s account and the `get_usage` control request. This is the same request Sphyrna uses.
  - Codex: `codex app-server` with `initialize`, `account/read` and `account/rateLimits/read`.
- It reads no credential files for these.

**A provider row.**
- The icon, name and version, a status dot, and an on/off switch.
- A headline from one state machine: checking, disabled, install, sign in, attention or ready. For example "Authenticated · Claude Max 5x".
- A detail view with the binary path, the home folder (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`), launch arguments and environment variables.
- Refresh, with "checked 2m ago".

**First run.** A "Connect your agents" step with a card per agent.
- Install or Sign In opens a terminal with the vendor's command typed in but not run: the user reviews it and presses Return.
- When the terminal closes, the agent is checked again.

**Accounts.**
- Each account is its own row with its own home folder.
- A failed check keeps the last good limits unless the account changed.
- "Unsupported", for an API-key account, is kept apart from "failed".

**The Usage page.**
- A switch between Limits, Tokens and Cost (Limits by default), and periods of 24h, 7d, 30d and 90d.
- The Limits cards:
  - one card per window per provider;
  - "N% left", with a tick where even spending would be, ahead, on or under pace, and "resets in 3h 12m";
  - Claude's model-scoped weekly windows come from `get_usage`.
- Tokens and Cost:
  - a big number with rows per provider and a daily line per provider;
  - five totals: processed, cached input, uncached input, output, and cache savings;
  - share bars by token type;
  - a breakdown by model or by day, and a sheet per model.
- Cost is an API-equivalent estimate from a price table, with overrides, and the unpriced share is shown.

**Collection.**
- Both providers are read from their transcripts, incrementally, by size, mtime and offset.
- Claude's records are de-duplicated by `messageId:requestId`.
- Codex is summed from the `token_count` deltas, with the model carried from `turn_context`. Duplicate events are dropped, and history copied into a fork is skipped.

**In a session.** A limits panel answered from the last snapshot, and a banner when a limit is hit.

**Breaks Sphyrna's rules, so it is not taken:**
- the auto-resume worker that sends "Continue where you left off." after a reset (a background model call);
- a 5-minute health timer;
- its own ChatGPT sign-in, reset credits through Anthropic's OAuth endpoint, and CLIProxyAPI hubs (credentials);
- a price table fetched on every scan.

## Proposals

### FB5-1: a resizable inspector (1.6.1)

- **The handle.** A 6–8 pt strip inside the inspector's leading edge, with `.pointerStyle(.columnResize)`, a double-click to reset, and an accessibility adjustable action.
- **The drag.** While dragging, only the inspector's edge moves; the content keeps its width and takes the new width once, on release. The terminal and Chat resize once, which keeps D-78's intent.
- **Three remembered widths:** narrow (default 328), side (392) and review (556), in `UIPreferences.inspectorWidths`. The minimums are about 280, 280 and 440. It docks while the content keeps 480 pt.
- **Tests.** `InspectorRig`: N drag steps then a release add exactly one terminal size. A preferences round trip. A shown-window check of the handle's hit area.
- This amends D-78 once `@user` confirms (Q3).

### FB5-2: Settings tabs (1.6.1)

1. **A failing test first.** Show the Settings window, send a mouse-down and mouse-up at each tab's frame and at one page control (as `SearchFocusAndHitTests` does), and expect the section to change. If the diagnosis holds, it fails today.
2. **Drop `isMovableByWindowBackground`.** The window still moves by its title strip outside the tabs; check this by hand.
3. **If the test still fails,** the title strip's region is next: move the tabs' hit area out of it, or give the band an AppKit-backed hit region.
4. **Sheets.** Dismiss Settings' sheets when the window closes (a unit test that fails first). The menu bar's Settings… keeps the tab.
5. **The main window too.** Run the same click test over the main window's header controls, so a regression there is caught as well.

### FB5-3: Put in Draft and several drafts (1.6.1, D-95)

**Placing.**
- Put in Draft places the line in the session's composer, unsent, below any text after a blank line. It then opens that session with the composer focused, so the line is seen landing.
- A stopped Chat session keeps the line in its saved draft, and opening the session shows it.
- A session that runs in the terminal gets a button that reads **Copy to Clipboard**, with a hover that says why. After the click it says "Copied".
- The tile clears its label on Home's next read.
- Draft Brief goes into a new draft when the open draft holds other text, and the page shows that draft. Draft Again replaces the brief it placed.

**Several drafts per project** (default Q6):
- Each draft gets its own id. `StoredDraft.id` is optional, so old files load.
- The slots and their side tables move to the draft id.
- ⌘N opens an empty draft, reusing the project's empty one.
- The sidebar lists every draft that has text, newest first, with its first line. Discard works per draft.
- A downgrade to 1.6.0 keeps one draft per project; the release notes say so.
- The size: about 34 call sites and 13 test files.

### FB5-4: Remora's still face (1.6.1, default Q7)

- **A (default).** Front, the menu bar's hammerhead, becomes Remora's still face.
  - About 64 pt in the brief's 136 pt column, and about 36 pt in the folded line.
  - Drawn in the art colour at about 0.8, as a template.
  - The arrival becomes the existing 0.6 s fade; the band's hammerhead keeps its loop.
  - The cost: Remora's face becomes Sphyrna's mark, which D-77 and D-80 kept apart.
- **B.** A new still remora mark drawn in Front's style.
- The arrival and fold scenes go, with their tests.

### FB5-5: a new icon (1.6.1, D-97)

**Four candidates:**
1. The Front silhouette, solid, near-white on a deep ink blue.
2. The Front silhouette on the accent's dark step.
3. Rising, round 1, from the identity preview: the bolder variant at 0.8 of the square, with heavier glyphs.
4. The Front silhouette filled with the art's ASCII field, which reads as solid at small sizes and as texture at large ones.

**How they are compared.** In a Dock strip at 32, 64 and 128 px, beside Terminal, Activity Monitor and Rising; `@user` picks one.

**After the pick.**
- The chosen icon gets two real Icon Composer layers, with dark, clear and tinted renditions checked by `make-app-icon.sh --renders`.
- Then README's icon, DESIGN §6, D-77 and the reference's identity page follow.
- If `@user` meant another variant, it joins the strip.

### FB5-6: drag and drop, and flow (1.6.1, D-96)

**Drag and drop:**
1. **A session mention pill.**
   - Drag a session (a sidebar row, an activity card, a tab, a Home row) onto a Chat composer, and it becomes a pill showing the mark and title.
   - The `@` list inserts the same pill.
   - On send, the pill becomes the text Claude reads today: the title, the transcript path and the first line of the last answer.
   - Pills persist in the composer's draft.
   - Only Claude sessions, never the session itself or a side chat.
   - Dropped on a terminal session, it pastes the transcript path.
   - A bounded excerpt instead of the path is a later decision.
2. **A session onto the tab strip.**
   - It opens pinned at the drop position, and tabs reorder by drag.
   - While a session is being dragged, the tab row shows as a drop zone even with 0 or 1 tabs.
3. **Projects reorder by drag** in the Projects view. Move Up and Move Down stay.
4. **Files and folders into the chat.**
   - A folder becomes `@folder/`, as a file becomes `@path`. Check today's result for folders.
   - The draft, Side and Quick Question composers take drops too.
   - A drop anywhere on the session's pane lands in its composer.
5. **A file from Changes** into a composer as `@path`.

No folder drop on the sidebar (D-96).

**Flow:**
- A Dock menu with Needs you, Working and New Claude Session.
- Keep the Mac awake while a session works, with Off and While working.
- The session menu gains Open Folder in Editor, Open in Terminal and Copy Transcript Path. The palette gains Add Project…, New Draft and Reveal in Finder.
- Reopen the closed tab (⇧⌘T).
- Peek: hover a sidebar row for the last ask or answer.
- An opt-in "notify when a long turn finishes", plus an Open action on the notification. This changes SPEC §11.

**Later, each with its own decision:**
- A split view and windows.
- An attention inbox with filters, notification levels and snooze.
- Review memory in Changes.
- Rows rich in status.
- Send the queue when the limit resets.
- Quick entry from anywhere.
- Sessions started outside Sphyrna, shown as history.

### FB5-7: Usage after T3 Code, with Codex (1.6.2, D-99)

**The page.**
- A switch between Limits, Tokens and Cost (Limits by default, remembered), periods of 24h, 7d, 30d and 90d, and a harness filter.

**Limits.**
- One card per window per harness: "N% left", a tick where even spending would be, ahead, on or under pace (±5 points), and "resets in …".
- Claude shows its 5-hour and weekly windows, and the model-scoped weekly windows when `get_usage` reports them.
- Codex windows are named by duration, from bucket `codex`.
- An API-key account shows "No subscription limits".
- A failed read keeps the last good windows unless the account changed. Each card shows when it was read.

**Tokens and Cost.**
- A big number, with rows per harness and a daily line per harness.
- Totals: processed, cached input, uncached input, output, and cache savings.
- Share bars by token type.
- A breakdown by model or by day, and a sheet per model (trend, cost per 1M tokens, cache hit rate).

**Cost is an API-equivalent estimate.**
- A bundled price table with a "prices as of" date, overrides and aliases.
- The unpriced share is shown.
- Nothing is fetched on a scan.

**Collection.**
- `ClaudeUsageIndex` gains a provider dimension, and a Codex parser is added: `token_count` deltas, the model from `turn_context`, duplicate events dropped, history copied into a fork skipped.
- Check Claude's de-duplication by `messageId:requestId`.

**Limits.**
- Claude: through the existing `get_usage` child, which also reads `initialize`'s account.
- Codex: through a short `codex app-server` (`initialize`, `account/read`, `account/rateLimits/read`), after a spike with an isolated `CODEX_HOME`.
- Both run on events (the page opens, the app activates, a session ends), with a 5-minute floor; Refresh bypasses the floor. Never a timer.

**In a session.**
- A limits panel answered from the last snapshot.
- When a limit is hit, a notification at the reset time with a Continue button the user presses. No automatic resume.

**The chip and Home.** They show the tighter harness and both harnesses' meters; the details are settled in 1.6.2's design.

### FB5-8: Settings → Connections (1.6.2, D-98)

**The page.** A seventh Settings tab; check that seven tabs fit 680 pt. It has a list and a detail view.

**A row.**
- The mark, the name, the version and a status dot.
- A headline from one state machine: checking, disabled, install, sign in, attention or ready. For example "Ready · Claude Max", "Not signed in", "Not found" or "Update recommended".
- The **connect switch**. Off, Sphyrna does not offer the harness, does not check it, and does not read its usage. Off never signs the CLI out.

**The detail.**
- Path, with Reveal.
- Version, judged against a bundled table of minimum and recommended versions.
- Account: email and plan, from `initialize` or `account/read`.
- Profile folder: `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
- Whether limits can be read, and when it was checked, with Check Again.
- Deep Check runs `claude doctor`, `claude mcp list` and `codex doctor --json`, shown as text.

**Setup.**
- Install and Sign In open a Sphyrna terminal with the vendor's command typed in but not run. The user reviews it and presses Return.
- When the terminal closes, the harness is checked again.
- Sphyrna never handles credentials.

**First run.** Home's first run shows "Connect your agents", with cards for Claude and Codex (Install, Sign In or Ready). It replaces today's "no Claude" notice.

**Accounts.**
- The account in use is shown.
- A change of account (another email or plan) resets the usage and limit snapshots.
- Several accounts side by side, as rows with their own profile folder, is a later decision.

**Probes.**
- The probe child runs without hooks or MCP, with a timeout. The `get_usage` child already runs this way.
- Checks run when the page opens, when the app activates, at a session's start and end, and on Check Again, with a 5-minute floor.
- Usage reads the login shell's `CLAUDE_CONFIG_DIR`, as sessions do.

### FB5-9: Codex at parity, the infrastructure (1.6.2, D-94)

**The principle.** Codex has Claude's priority. Every surface a Claude session has, a Codex session gets, with a matching experience. The model's behaviour is not part of this.

**Step 1, a parity matrix (planning).** It crosses every surface with the data that surface needs:
- the surfaces: rows, header, tabs, Home, Overview, Changes, Agents, Side, Rewind, Quick Question, composer, queue, pinned cards, palette search, Remora, project page, usage, connections, notifications, menu bar, deletion and resume;
- for each one: what it needs from a harness, Claude's source today, Codex's source (app-server events, rollout files), and the gap.

Its output is the list of harness-neutral contracts to build.

**Step 2, the infrastructure that ships in 1.6.2.**
- One capability table drives every gate; no `provider == .claude` remains.
- A transcript reader contract with a Claude reader and a Codex reader, tested on fixtures. It serves search, Remora, Changes' turn scopes, the project page and mentions.
- Usage and limits per harness (FB5-7), and health (FB5-8).
- A model catalog read from the harness; Codex's list comes from the app-server instead of three hard-coded names.
- A design for a second Chat driver. At parity, Codex gets the Chat face too, which SPEC §6.1 excludes today. That is decided when 1.7.0 is planned.

**Not in 1.6.2:** starting or resuming Codex, the Codex Chat driver itself, the session channel.

### FB5-10: Chat's streaming cost (1.6.1)

**The target.**
- SPEC §12.1 asks a visible Chat stream to cost no more CPU than the terminal; D-92 moved that after 1.6.0.
- If S1, S2 and S4 below work as the profile suggests, a flush costs about 0.4 of today's (inferred). That is about 10 % at 600 chars/s against the terminal's 6.1, and about 20 % at 6,000 against 19.6.
- So 6,000 is within reach, and 600 likely needs S5. 1.6.1's target is Q17.

**Slices, in order.** After each one, `chat-visible-600` and `chat-visible-6000` run twice on the idle Mac with the window visible, with a 10 s `sample` to see where the cost went.

| # | Change | What it shows |
| --- | --- | --- |
| S0 | Two new C8 cells: a 300-line fence, and a four-backtick fence holding three-backtick fences with blank lines. The fixture's fence closer (`ChatStreamScenario.swift`) learns four backticks. A baseline on `988256a` | The size of the long-block cost; whether the nested fence stays composable |
| S1 | The open tail is not selectable (Q14); `isRule` stops at the first character that is not a rule | Whether the focus bridge drops too, which names its trigger |
| S2 | A cost-aware interval: `due = last + max(80 ms, k × the last flush's cost)`, up to a ceiling (Q13) | The largest single lever: about −45 % at a flat 160 ms |
| S3 | The head re-parses only what settled. A long fence or list settles in chunks while it streams (Q15) | The long-block cells' flush cost stays flat as the block grows |
| S4 | One layout per flush: measure with the cell's own hosting view. Then, only if S1 left the focus bridge, stream cells stop taking focus (Q16) | Heights match `ChatStreamMeasureTests` within 0.5 pt; selection and Copy still work |
| S5 | Rows of settled blocks instead of one row per message | Only if Q17's target is missed after S4. About 800–1,500 lines; VoiceOver reads each block as a row |

A native text view for the open tail would take SwiftUI off the hot path, but its visual parity is a risk, so it is not in this round.

### FB5-11 and FB5-12 (1.6.1)

- **FB5-11:** find what changes `HomeRemoraReadKey` twice in one frame, and make it change once.
- **FB5-12:** find the Security call on `loom-run-host`'s main thread, and move it off the main thread, or confirm that it is harmless and silence the fault at its source.

## Decisions

**Decided on 24 Oct:**
- **D-93:** the release line.
- **D-94:** Codex at parity.
- **D-95:** Put in Draft says what it does.
- **D-96:** mention pills, and folders into the chat; no sidebar folder drop.
- **D-97:** a new icon from candidates.
- **D-98:** Settings → Connections.
- **D-99:** Usage after T3 Code.

**Open, with defaults:**

| # | Question | Default | Alternative |
| --- | --- | --- | --- |
| Q2 | Remora's default in the public build | On, with the morning brief set to When I ask. A stored choice is kept | Off; or On with Automatic |
| Q3 | Inspector widths (FB5-1) | Resizable, three remembered widths; the edge follows live, and the content takes the width on release | One shared width |
| Q6 | Several drafts (FB5-3) | In 1.6.1; ⌘N opens an empty draft | One draft per project |
| Q7 | Remora's face (FB5-4) | A: Front, still; the arrival becomes a fade | B: a new still remora mark |
| Q13 | How far the stream may slow under load (FB5-10, S2) | 80 ms while flushes are cheap, stretching to at most 160 ms | A flat 120 or 160 ms; or keep 80 ms and give up S2 |
| Q14 | The paragraph being written (S1) | Selectable once it settles, at the next blank line. Everything settled stays selectable; Copy is unchanged | Keep it selectable, giving up 12–16 % at 6,000 |
| Q15 | A long code block while it streams (S3) | It grows in full, from settled chunks; built only if S0 shows the cost | The last lines, with "N lines above", until it closes |
| Q16 | Tab into the stream's buttons (S4) | Kept. Dropping it is a fallback, asked first | Drop it; SPEC §8.1 requires Tab only for pinned cards |
| Q17 | Chat's target in 1.6.1 | Half of today: ≤ 12 % at 600 chars/s and ≤ 25 % at 6,000, as D-92 (3)'s new budgets. The terminal's 1× stays the goal; S5 is decided on S4's numbers | 1× now, which likely needs S5 in 1.6.1 |
| — | FB5-2's observation | Do the page's own controls answer a click? | — |

## Release 1.6.1: slices

W1 and W3 are the round's first and third waves, as D-93 names them; the second became 1.6.2. Every slice follows AGENTS §5–§7: its own worktree from `v2`'s head, narrow `scripts/check.sh --suite` runs, the D-90 cadence, and window tests and measurements only while the Mac is idle.

| Slice | Owner | Write set (main files) | Done when | Idle Mac |
| --- | --- | --- | --- | --- |
| W1-a Settings | ink | `loom-app/SettingsWindowController.swift`, `SettingsView.swift`, `AppDelegate+System.swift`, a new shown-window test | The click test fails first, then passes; the sheets close with the window | The click test |
| W1-b Inspector | ink | `InspectorContainer.swift`, `InspectorState.swift`, `InspectorAgents.swift`, `UIPreferences.swift`, `CatalogModel.swift` (one setter), `LoomTheme+Inspector.swift` | One terminal resize per drag; the widths persist per class | The handle |
| W1-c Put in Draft | ink | `CatalogModel+RemoraDraft.swift`, `HomeRemoraTileViews.swift`, `HomeRemoraUI.swift`, `HomeRemoraText.swift`, `DraftRemoraModel.swift` | D-95's behaviour; the tests that pinned the copy are rewritten deliberately | No |
| W1-d Remora's face | ink | `HomeRemoraArt.swift`, `HomeRemoraSection.swift`, `ArtPlaces.swift`, `ArtArrival.swift`, a mark view | The still face and the fade; the art tests are updated | An eye check |
| W1-e Icon | planner, ink | `design/identity/*`, `assets/icon/*`, `assets/readme/icon.png` | `@user` picks; the renders hold in every appearance | An eye check |
| W1-f Several drafts | core, ink | `NewSessionStore.swift`, `NewSessionDraft.swift`, `CatalogModel+NewSession.swift`, `SidebarDraftRows.swift`, `DraftSessionView.swift`, `Destination.swift` | Draft ids, migration, the sidebar per draft, ⌘N's rule | No |
| W3-a Mention pill | ink, core | The composer (`ComposerTextEditor.swift`, `ChatComposerModel+Attach.swift`, `ComposerAttachments.swift`, the chip row), `LoomChat` draft store and outgoing blocks, a drag source on rows | Drag and `@` both make a pill; send turns it into the mention text | A hand check |
| W3-b Tab strip | ink | `ConversationTabs.swift`, `ConversationTabStrip.swift`, `CatalogModel.swift` (tabs) | Drop opens pinned at a position; drag reorders; persisted | A hand check |
| W3-c Project reorder | ink | `SidebarView.swift` (project heads), `CatalogModel.swift` (`moveProject(_:to:)`) | Drag reorders with an insertion mark | A hand check |
| W3-d Drops into composers | ink | `NewSessionComposer.swift`, `SideComposer.swift`, `QuickQuestionPanelView.swift`, the pane's drop target | Files and folders land as references in every composer | No |
| W3-e Changes drag | ink | `ChangesTab.swift`, `ChangesDiffViews.swift` | A file drags out as `@path` | No |
| W3-f Flow | ink | `loom-app` (Dock menu, keep awake), `SessionMenuItems.swift`, `PaletteAction.swift`, `ConversationTabs.swift` (reopen) | Each item with its narrow test | No |
| W3-g Notifications | ink | `ApprovalNotifier.swift`, `ApprovalNotifications.swift`, Settings → General | The opt-in "finished" notification and an Open action | A hand check |
| FB5-10 Chat cost, S0–S5 | core | `LoomCatalogUI/Chat/`: `ChatPresentation.swift`, `ChatMarkdownViews.swift`, `ChatMarkdown.swift`, `ChatContent.swift`, `ChatHeights.swift`, `ChatStreamController.swift`, `ChatStreamViews.swift`; `loom-fake-provider/ChatStreamScenario.swift`; `scripts/perf/chat_stream_cost.py` | Q17's target at both rates; the other D-92 budgets hold; the long-block cells stay flat | Every C8 run |
| FB5-11, FB5-12 | ink, core | `HomeRemoraCalls.swift`; `loom-run-host` | No fault in the log | No |
| Docs | planner | DECISIONS, SPEC, DESIGN, ARCHITECTURE, release notes | [Docs to amend](#docs-to-amend) | No |

**Order and parallel work.**
- W1-a, W1-b, W1-e, W3-b, W3-e and FB5-10 can run side by side; W1-b and W3-b only share `CatalogModel.swift` (below).
- Home's Remora files run in order: W1-c, then W1-d.
- Drafts: W1-c, then W1-f.
- The composer: W3-a, then W3-d.
- `SidebarView.swift`: W3-a's drag source, then W3-c.
- `CatalogModel.swift`: one owner at a time.
- FB5-10 runs S0 to S5 in order. It shares the `Chat/` folder with W3-a and W3-d but no file. Its C8 runs go into the same idle-Mac batches as the window tests.

**Close.** The pool (D-90), the closing optimizer review on the round's diff (D-06), the tag `release/1.6.1`, the promote and install as 1.6.1 (D-93), then `@user`'s word on the push.

## Release 1.6.2: outline

| Step | Owner | Content |
| --- | --- | --- |
| P0 | planner, researcher | The parity matrix (FB5-9 step 1) and the contracts |
| C1 | core | The Codex app-server spike: isolated `CODEX_HOME`, the payloads of `account/read` and `account/rateLimits/read`, failures, wall time, writes |
| C2 | core | Harness health: the state machine, the checks, account facts from `initialize` and `account/read`, the connect switch, the profile fix |
| C3 | ink | Settings → Connections, and Home's "Connect your agents" with the terminal setup |
| C4 | core | The usage index's provider dimension and the Codex parser |
| C5 | core | Limits per harness: the `get_usage` child extended, and the Codex app-server read |
| C6 | ink | The Usage page after T3 Code; the chip and Home |
| C7 | core | The capability gate and the transcript reader contract with both readers |
| C8 | core | The model catalog from the harness |
| C9 | planner | The second Chat driver's design, as input to 1.7.0 |

Close as 1.6.1 does: the pool, the optimizer, the tag, the promote and install as 1.6.2.

## Docs to amend

- **DECISIONS:**
  - D-78, once Q3 is answered.
  - D-77 and D-80, once the icon and the face are picked.
  - D-21 and O-07: the terminal's file drop is done.
  - D-69 (5), when 1.7.0 binds Codex.
  - D-92 (3), with FB5-10's measured numbers (Q17).
- **SPEC:**
  - §6.2, §6.3, §6.5 (drafts).
  - §7.2 (the stream's interval, and selection while a paragraph streams).
  - §7.3 (pills).
  - §8.2.
  - §10.5 (D-95).
  - §11 (the Dock menu and notifications).
  - §12.1 (Chat's budgets), and §12.2 (new processes that make no model call: the harness checks and the Codex limits read).
  - Codex's place everywhere (D-94).
- **DESIGN:** §6 (the icon, Connections), §9, §17 and §20 (Remora's face), §2 item 5 (seven tabs).
- **ARCHITECTURE:** §8 (Codex), §11.6, §11.7, §11.10, §11.13 and §11.16, and §12.2 (the focus bridge's path).
- **DEVELOPMENT:** the Codex spike's isolation rule, and the icon renders.
- **ACTIVE-PLAN and plans/README:** on the go, 1.6.1's slices replace the 1.6.0 tables, and §5's items 1, 3 and 4 point to this file.

## Not in this round

- Codex's binding, its Chat face, and the session channel: 1.7.0 (D-93).
- The split view, and drops on the Dock icon.
- A folder drop on the sidebar (D-96).
- Answering approvals from notifications.
- Automatic resume after a limit's reset. It would be a background model call (SPEC §12.2).
- Reading limits through vendor endpoints with the user's tokens.
