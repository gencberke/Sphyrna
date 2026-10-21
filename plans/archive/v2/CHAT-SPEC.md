# Loom v2: chat behaviour spec

**Date:** 17 Oct 2026 · **State:** built through [V2-PLAN](../V2-PLAN.md): Releases A and B are closed, C is evaluated · **Owner:** the planner-reviewer (main session) · **Slices:** V12 model, V13 stream view, V16 driver, V17 composer, V18 pinned cards, V19 Chat first, V21 rewind files, V22 the quick question and the side chat, V23 a subagent's requests, V24 the chat bar, and V07 for the draft session.

## About this spec

**Look.** The app's design language is Ink (v3) since 20 Oct 2026 ([D-74](../../DECISIONS.md), [design/DESIGN.md](../../design/DESIGN.md)). This spec is behaviour. The chat's Ink look was accepted on 20 Oct ([D-75](../../DECISIONS.md)) and is drawn in [the reference](../../design/reference.html#session), and DESIGN §7 and §11–§16 hold its rules; where a line here names a look, Ink's rule wins.

This spec turns the [concept's chat chapter](../v2-research/V2-CONCEPT.md#5-the-chat-in-depth) into rules that an implementer can build and test. Where the two differ, this spec wins.

The rules borrow what T3 Code does well. They come from three read-only studies of its code at commit 5c8528f:

- [timeline](../v2-research/evidence/t3code-timeline-20261017.md)
- [composer](../v2-research/evidence/t3code-composer-20261017.md)
- [shell](../v2-research/evidence/t3code-shell-20261017.md)

Each rule is adapted to Claude's stream-json wire and to native views.

**Tiers:**

- **must**: Release B is not done without it.
- **should**: built in its slice if it fits the slice's budget, otherwise in the next release.
- **later**: needs the user's word first.

**[T3]** marks a rule ported closely from T3 Code (MIT, Copyright 2026 T3 Tools Inc.). Its Swift code carries a comment that names T3 Code and the source file. V12 adds T3 Code's MIT notice to a third-party notices file that ships with the release, and allowlists that file for the clean tree. No T3 code or assets are copied as is.

## What Loom takes from T3 Code, and what it changes

| T3 Code | Loom |
| --- | --- |
| One flat list of entries; pure functions derive the rows; views only draw | Same. `LoomChat` holds the entries and the row derivation without AppKit, so both are unit-tested |
| Claude's text arrives only as whole messages, because T3's adapter does not stream it | Loom streams text from partial messages |
| Steering sends `priority:"now"`, which cancels running tools, so Enter queues by default | ↵ sends with `priority:"next"`, which cancels nothing, and ⌘↵ queues ([Composer](#composer)) |
| Stop sends `interrupt` and then closes the process | Esc and the composer's Interrupt keep the process alive, and the queue pauses |
| Approvals have no keyboard path, no agent name and no record of the answer | Approvals get a keyboard path, the subagent's name and a one-line record in the stream |
| Full access is the default for new threads | The mode chip always shows, and Loom never picks Full access by itself |
| A compact chip can change what Enter does on stale threads (#17467) | No key ever changes meaning behind the user's back. Compacting is a button |
| In plan mode with Auto, the adapter allowed edits without asking (#15503) | The driver never answers a request by itself |
| A spacer installed to anchor new turns left stale state (PR #6519) | A new turn gets a one-off scroll animation and no spacer |
| A list library's "near the end" flag drove follow mode and caused the scroll-back bugs (#4668, PR #5566) | Loom measures the distance from the true bottom in its own scroll view |

## Model

**must**, V12.

- **Entries.** A session is one chronological list of entries:
  - user message, assistant text block, thinking block;
  - tool call (the `tool_use` and its result in one entry, updated in place);
  - subagent, plan, request record;
  - marker: session start, resume, compaction, reset, interrupt, retry, mode or model change, face switch;
  - unknown record.

  The live stream, the session transcript and a subagent's transcript all produce this list ([concept §5.1](../v2-research/V2-CONCEPT.md#51-engine)).
- **Turns.**
  - A turn runs from a user message to the main thread's `result`.
  - A subagent finishing never ends the turn [T3].
  - A message sent while Claude works joins the running turn and does not start a new one.
- **Stable identity.** Every row keeps one id: the message uuid with the block index, or the `tool_use_id`. A streaming update replaces only the row that changed, so the other rows are not redrawn [T3].
- **Cold open.**
  - Loom reads the last 10 user turns [T3], capped at about 1.5 MiB from the transcript tail (the concept's budget).
  - A cut by the budget starts at a human prompt or at the first record of an API message, never at a tool result, so a call and its result never split across pages.
  - When the top comes within one screen, Loom loads the next 20 user turns and holds the anchor.
  - Long tool bodies keep their head and tail (64 KiB to start). "Show all" reads the rest from the transcript ([concept §5.7](../v2-research/V2-CONCEPT.md#57-performance-budgets)).
- **Unknown records** stay as raw rows. A line over the decoder's limit (64 MiB on the live stream) is marked, never dropped silently.
- **Records with no row.** Checked against 137 real transcripts from the test profiles (V12, 18 Oct):
  - The transcript's bookkeeping types are silent.
  - The terminal's `/exit` leaves a command, a farewell and a caveat record; all three are silent.
  - `system/local_command` becomes a notice, and `system/api_error` a retry marker.
  - A hand-back with `origin` `peer` shows as a notice for now.
  - Still guessed, never seen in a real file: the compaction metadata, and the `bash-*` and `local-command-stderr` wrapper tags.

## Thinking

**must**, V12 with fixture tests.

- **Normal view.** While Claude works, the live row shows a thought line taken from the latest thinking block [T3]:
  - its first `**bold**` line, or else its first sentence;
  - links, heading marks and list markers removed;
  - at most 4 lines.

  After the turn, thinking folds with the work.
- **Thinking and Verbose views** show each block where it occurred, as an italic block that can be collapsed.
- **Narrative before a tool call.**
  - T3 saw Claude 5.1+ write this narrative as thinking blocks (T3 #18355).
  - On Claude Code 2.1.300 with Haiku 5.5, [S1](../experiments/v2-spikes/S1-wire-20261017.md) found it arrives as a plain text block before the `tool_use`, with no marking field.
  - Loom keeps text as text and thinking as thinking, and relabels nothing. Fixtures cover both shapes, so a model that still writes thinking blocks shows them as thought lines.
- **Thinking text needs a flag.** With the default display, Haiku 5.5's thinking text is empty ([S1](../experiments/v2-spikes/S1-wire-20261017.md)). The driver passes `--thinking-display summarized`, so the thought line and the Thinking view have text. It is a hidden flag that works on 2.1.300, so it is gated by version.
- **Redacted thinking** shows as one line, "Thinking (hidden)".

## Stream

V13.

### Messages

- **Your message.**
  - It sits on the right, as in the prototype.
  - Over 600 characters or 8 lines, it collapses to about 7 lines with "Show full message" [T3, **should**].
  - It can carry marks: the ticket chip, "Sent while Claude worked", "From the queue".
- **Claude's prose.**
  - No bubble.
  - Deltas apply once per frame (about 50 ms), and only the last block is parsed again while it streams.
  - New blocks fade in briefly, with no fade under Reduce Motion.
- **Automatic turns.** When a background task ends, the CLI starts a turn by itself, with a task notification as the prompt ([S0](../experiments/v2-spikes/S0-hooks-20261017.md), [S1](../experiments/v2-spikes/S1-wire-20261017.md)). Loom shows a short row such as "Background command finished", never a message from you.
- **Hover actions** appear only on the last assistant message of a settled turn [T3]: Copy and Open in Terminal. Fork from here is **later**. Your own messages offer Copy, the time and, from V21, "Rewind files to before this message": a file checkpoint is the state at the start of a user message, so there is none for the end of a turn ([S8](../experiments/v2-spikes/S8-rewind-20261018.md)).
- **Times** use the system locale [T3]:
  - today: the time only;
  - yesterday: "yesterday at 14:05";
  - older: the date, with the year only when it is not the current year.

### Work rows

- **One line per tool**, about 24 pt tall: icon, label, the time on hover, and a chevron.
  - Labels read like "Read src/pdf.py", "Searched "refund" in src/", "Ran npm test", "Edited src/a.py +31 −6", "Created src/b.py +40", "Fetched docs.stripe.com", "Skill: deploy" and "Used linear · create_issue".
  - A Bash command is shown as written, on one line.
- **Groups.** Two or more tools in a row form one group, whose summary names the top two kinds of work [T3, **must**]:
  - Commands, edits and agents rank 0. Reads, searches and web rank 1. Everything else ranks 2.
  - The two kinds with the best (rank, first appearance) are named, in order of appearance. The rest becomes "and N other actions".
  - Counts read "Read N files", "Changed N files" (distinct paths), "Ran N commands", "Searched code N times", "Searched the web N times" and "Used N tools". Thinking alone reads "Thought".
  - For example: "Changed 3 files, ran 2 commands and 4 other actions".
- **Success is quiet, failure is loud** ([concept §5.3](../v2-research/V2-CONCEPT.md#53-the-stream)).
  - A tool failed when its result has `is_error`, or when it was denied or interrupted. A failed Bash also says "Exit code N" in its text. There is no exit-code field, and grep or diff exiting 1 is not an error ([S1](../experiments/v2-spikes/S1-wire-20261017.md)).
  - A group takes its failure state from its latest tool [T3].
  - A failed command opens with its last 12 lines and its exit code.
- **Bodies** open inline:
  - a command: its output and exit code;
  - an edit: its path, counts, and an inline diff up to about 200 lines, then "Open in Changes";
  - a read: its path, or a thumbnail for an image;
  - a search: its pattern and results;
  - other tools: their arguments.

  Bodies scroll after about 16 lines, and their text is selectable. Output arrives with the tool result. Release B does not poll files for live output, which T3 has to do.
- **Subagents** [T3]:
  - A card shows a status dot, the task description, one detail line and the elapsed time from timestamps. The detail line is the result when done, otherwise the latest progress, with markdown stripped and at most 280 characters. While the subagent runs (V23), the line is its newest words, one line cut at the end, updated per block, since subagents send no partial stream events; the card ends with "Open in Agents". Claude Code 2.1.300 forwards a subagent's text and thinking to the parent's stream only with `--forward-subagent-text`, so every Chat-face spawn passes it when `--help` lists it (Release C's real check, R4). The terminal face never passes it.
  - Neighbouring subagents of one turn merge into a group such as "3 agents · 2 working · 1 done" (**should**).
  - A live subagent card never folds.
  - Clicking a card opens it in the inspector's Agents tab.
- **Changed files** [T3, **should**].
  - Under the final answer of a turn that edited files, a card shows "3 files changed +120 −34", a file tree with single-child folders merged, and "Open in Changes".
  - The counts come from the edit records: the `structuredPatch` of an Edit result, or of a Write over an existing file. A Write that creates a file has an empty patch, so its lines count from `content` ([S1](../experiments/v2-spikes/S1-wire-20261017.md)).
- **Tasks** [T3, **should**].
  - TodoWrite never becomes a row.
  - While a turn works, one line above the composer reads "Tasks 3/7 · Writing the migration" and opens the Tasks tab.

### Turn fold

[T3, **must**]

- **What folds.** When a turn settles, everything between your message and the turn's final answer folds into one row. The row takes the live row's place: "Worked for 4m 12s · changed 5 files and ran 3 commands". The duration comes from `result.duration_ms`, or else from the timestamps.
- **What never folds.** A turn does not fold:
  - while it is live, a request waits, or text streams;
  - when it failed or was interrupted;
  - when nothing foldable is left.
- **Inside a fold.** Plan cards stay visible. Everything else folds, request records included.
- **Open folds.** Each session keeps one set of open folds. A new turn closes the previous turn's fold if you had opened it [T3]; other open folds stay open.
- **Interrupted and failed turns.**
  - An interrupted turn gets a neutral divider: "You stopped after 1m 4s".
  - In a failed turn, the failed step is loud.

### Live row

[T3, **must**]

- **One row with a fixed id** at the end of the running turn. It shows the running tool's label, then the timer: "Editing migrations/0042.py · 3m 05s". In place of a tool label it can read "Thinking", "Compacting", or "Waiting for you" while a card waits. The thought line sits above the row.
- **The trailing tools** of the running turn collapse into this row. Clicking opens them.
- **The timer** starts at the send. Loom keeps the start time in its own state, so a relaunch, a window switch or a hidden window never resets it (T3 #15029, #16449).
  - One label updates once a second, and nothing else redraws.
  - A hidden window gets no timer.
- **After 40 s with nothing new**, the row says "No activity for 40s" instead of looking busy (concept). Any stdout line counts as activity, because the CLI sends no `tool_progress` frames ([S1](../experiments/v2-spikes/S1-wire-20261017.md)).

### Markers and banners

- **Markers** are hairline dividers with a centred label:
  - session started (model, effort, mode, branch);
  - "Resumed after 4 days";
  - "Context compacted · 180k → 42k tokens";
  - "You stopped after 1m 4s";
  - model or mode changed. Every mode marker reads Loom's names ("Session started · Ask before edits", "Mode changed to Ask"). It is placed when the change is confirmed, or when a resumed run comes up in another mode than the last one marked, so it always sits before the turn it affects;
  - conversation cleared;
  - "Continued in Terminal" and "Back in Chat".
- **Banners** sit above the composer. One shows, and the others wait behind a "+2" peek [T3]. The order is:
  1. Blockers: a usage limit with its reset time from `rate_limit_info.resetsAt`, sign-in needed with Open in Terminal, or a policy signal with Switch to Terminal (D-69: it sets Settings' switch to Terminal and moves the session). As built in V19, the policy signal, wire drift and unknown records share one banner above the pinned cards. The banner never covers a card, and its fallback text matches the face that owns the session.
  2. "Retrying · attempt 2 of 4".
  3. Notices: a drift notice or "Queue paused".

  A dismissed error stays dismissed for that session and that error [T3].
- **Unknown records** show as a collapsed raw row, plus one drift notice per session (concept).

### Content

- **Markdown** goes into attributed text through Loom's own block parser, with Apple's inline markdown for the text inside blocks; there is no new dependency (V13). Nesting stops at depth 8, and links open only for `http`, `https` and `mailto`.
- **Code blocks** are separate views with the language, Copy ("Copied" for 1.2 s) and a wrap toggle [T3].
- **Highlighting** [T3]:
  - common languages only;
  - never while a block streams;
  - nothing above 20,000 characters;
  - a cache bounded by entries and by bytes.
- **Other content:**
  - Tables scroll sideways.
  - Mermaid shows as code; opening it in the browser is **later**.
  - Images show as thumbnails and open in Quick Look.
- **Copy** takes the source markdown of whole blocks, not a re-serialized selection.

### Views

Normal, Thinking and Verbose, cycled with ⌃O ([concept §5.3](../v2-research/V2-CONCEPT.md#53-the-stream)). Verbose opens every fold and group.

## Scrolling

**must**, V13. Scrolling is the highest-risk part of the renderer. The rules are T3's latch [T3], with the fixes T3 had to learn from its bugs.

- **Two states.** Following keeps the newest content in sight. Free leaves the view where you put it.
- **Back to following** happens only when the distance from the true content bottom is at most 40 pt.
  - Loom measures it in its own `NSScrollView`, with the composer inset subtracted.
  - No framework "near the end" flag decides it.
- **Leaving following** happens on any of these:
  - scrolling up with the wheel or trackpad, when the content overflows;
  - dragging the scroller;
  - Page Up, Home or ↑ in the stream;
  - Page Down, End or ↓, only when away from the end.

  Leaving also cancels any programmatic scroll still queued.
- **On send,** your message scrolls to about 24 pt below the top in one animation. Loom installs no spacer. Following resumes when the turn's first tool activity appears, or when you scroll back to the end.
- **Opening or closing** a fold or a body keeps that row's top in place. At the end, it keeps the end in view.
- **"Jump to latest"** sits above the composer.
  - It appears 150 ms after you leave the end, while not following.
  - It hides at once when you return.
- **Rows** are a view-based `NSTableView`.
  - Heights are cached by row id, width and open state.
  - A height change above the viewport corrects the anchor.
- **Memory.** For each session opened since launch, Loom remembers the anchor row, the offset, and whether the view was at the end.

## Composer

**must** unless marked. V17 builds the composer; V16 holds the queue model.

### Keys

| Key | Claude idle | Claude working | Notes |
| --- | --- | --- | --- |
| ↵ | Send; this starts a turn | **Send now** with `priority:"next"`: Claude reads it after the current step | Never sends during IME composition (`hasMarkedText`) or key repeat [T3] |
| ⌘↵ | Send | **After this turn**: the message goes into Loom's queue | In a new-session draft, ⌘↵ starts the session and opens a fresh draft [T3] |
| ⇧↵ | New line | New line | |
| Esc | Closes a menu, or cancels editing a queued message | The same first; otherwise **Interrupt**, but only when no card waits | While a card waits, Esc does nothing; the card's Deny and stop, or the Interrupt button, ends the turn. Esc never denies |
| ↑ | Recalls earlier messages of this session [T3] | Same | Only when the composer is empty or holds an unedited recall, the caret is on the first line, and no modifier is held. ↓ walks forward and clears past the newest. Editing a recall makes it a normal draft. Recall is text only |
| ⌘⇧V | Pastes as plain text, never a chip | Same | |

**Why ↵ means Send now.**

- T3's steer sends `priority:"now"`, which cancels Claude's running tools. That is disruptive, so T3 made Queue the default (issue #231; issue #19773 is about the docs).
- Loom's ↵ sends `next`, which cancels nothing. [S1](../experiments/v2-spikes/S1-wire-20261017.md) confirmed that `next` waits for the whole running tool, so a message sent during a long command waits for it, as in the terminal.
- **Read now** (**should**). While a sent message waits for a long step, its row offers Read now.
  - Loom unsends the message (`cancel_async_message`) and sends it again with `priority:"now"` and a human origin.
  - S1 saw this move a running Bash to the background, so Claude reads the message within seconds.
  - The command keeps running and reports back as a task notification.
- A setting that swaps ↵ and ⌘↵ while Claude works is **later**.

**Type to focus** [T3, **should**]. A printable key typed while no text field has focus goes to the composer.

**As built in V17 and V18** (18 Oct).

- ↵ always sends `next`. S1 §D item 3's Bash-only `now` was not taken: it can land on a pending approval, it races a Bash that just finished, and it moves the command to the background silently. Read now is the fast path.
- With a card shown, ↵ and ⌘↵ send nothing and answer nothing, Send is disabled, and Esc only closes an open menu. Tab and Shift-Tab move between the composer and the card.
- ⌘↵ queues text only; with attachments it says so and queues nothing. Update on a queued message refuses while attachments are present.
- A paste of 32 KiB or more becomes a chip. Images are scaled to 2000 px at most, and files over 40 MB are refused. History keeps 200 messages, text only.
- Returned messages come back in front of the typed text, after a blank line, with their attachments. Messages the CLI never read when a run ends go into the draft the same way.
- A queued message sent while it was being edited leaves its text in the composer only if the user changed it.
- `@` never walks the home folder, `/`, an ancestor of home or a volume root; there it lists sessions only. A scan reads at most 2,000 entries per folder, 20,000 in all, depth 8, for 0.5 s.

### Send button

[T3]

| State | Button |
| --- | --- |
| Idle, empty | Send, disabled |
| Idle, text | Send |
| Working, empty | Interrupt (a square) |
| Working, text | Send now. Holding ⌘ turns it into After this turn |
| Editing a queued message | Update |
| Queue paused, composer empty | Resume |
| A card waits, text | What the text does to the card: Deny with note, Answer, or Keep planning |

### Queue

- **Loom owns the queue** (V16).
  - It is kept with the session in Loom's data folder, never in the transcript.
  - The CLI's own queue (`priority:"later"`) is not used, because it cannot be edited or reordered. T3 keeps its queue outside the agent for the same reason.
- **The strip** above the composer reads "Queued · 2" and can collapse.
  - Each row shows one line and offers Edit, Send now and Remove.
  - Rows reorder by dragging, or with ⌥↑ and ⌥↓ while a row has focus [T3].
- **Release.** When the turn's `result` arrives and no card waits, the first item is sent. Items go one at a time.
- **Edit** [T3].
  - The item moves into the composer, its row is highlighted, and the button reads Update.
  - Esc cancels and brings your own draft back.
  - If the item is sent while you edit it, editing ends and any changed text stays in the composer.
- **Pause.**
  - Interrupting pauses the queue: "Queue paused because you interrupted · Resume · Clear".
  - Messages Claude had not read come back as drafts. The interrupt's response lists them in `cancelled[]` ([S1](../experiments/v2-spikes/S1-wire-20261017.md), [concept §5.2](../v2-research/V2-CONCEPT.md#52-wire-mapping)).
  - A failed turn and a relaunch of Loom pause the queue too [T3]. An interrupt's own `result` (`error_during_execution`, `is_error`, no text) does not count as a failed turn.
  - A message queued while the queue is paused waits.
- **Queued items survive** Stop, Quit and a crash.
- **A move to the terminal** pauses the queue: "Queue paused because the session moved to the terminal · Resume · Clear". Back in Chat it stays paused until the user resumes it. What was queued before the move may not fit what was done in the terminal, so nothing goes out by itself (the planner's call in fix round 2).

### Delivery and drafts

- **Delivery** follows the CLI's `command_lifecycle` records, matched by Loom's own message uuid ([S1](../experiments/v2-spikes/S1-wire-20261017.md)):
  - The message stays dimmed until `queued` arrives, meaning the CLI has it.
  - After `queued` it looks normal. A small "Waiting for the current step" mark shows until Claude has read it.
  - The `isReplay` echo, or `started`, means Claude read it, and the mark goes.
  - `cancelled` puts the text back in the composer.
  - A message that never got `queued` before the process ended shows "Not delivered · Retry · Copy". Loom never resends on its own ([concept §5.4](../v2-research/V2-CONCEPT.md#54-the-composer)).
  - Stdout also carries `isReplay` records that Loom did not send, such as task notifications, so only Loom's own uuids count.
  - A CLI without the `msg_lifecycle_v1` capability sends no `queued`. The capability is listed in `system/init`, not in the `initialize` response, so Loom only learns it after the first send. Without it, the echo marks both delivery and reading.
- **Drafts** are kept per session. Loom saves them 300 ms after the last change [T3], on blur, on send and on Quit.
- **A message sent while a turn runs** is in the draft file until Claude reads it, so Quit or a crash leaves it in the composer once (fix round 2).

### Menus

- **`/`** works only at the start of the message, where the CLI expands commands.
  - It lists Claude's commands and skills from `system/init`, then Loom's actions (Ask on the side). Since D-69 it holds no move: a terminal-only command says it runs only in the terminal and points to Settings → General → "Sessions run in".
  - Skills that are not user-invocable are hidden.
  - A terminal-only command says so and opens the terminal (concept).
- **`@`** lists, in this order:
  - files and folders of the session's folder: at most 80, after typing pauses for 120 ms [T3];
  - other sessions, which insert their transcript path and last answer as text (concept).
- **One flat list per menu**, ranked by T3's bands [T3]: exact, prefix, word start, contains, fuzzy, each with a length penalty.
  - ↑ and ↓ wrap around the list.
  - ↵ or Tab inserts.
  - Esc closes the menu and ignores that trigger until the next one.
- **What goes into the message** is plain text that the CLI understands (`@path`, `/name`). Chips only change how the composer shows it.
- **Turkish Q layout.** `@` and some other trigger characters may need Option there; V17 checks which on the device.
  - The + menu opens both menus, and each menu also has a shortcut.
  - All shortcuts match by key code, not by the typed character.

### Attachments

- **Images** come from +, paste or drop and are sent as image blocks.
  - They are scaled to at most 2000 px on the long side [T3].
  - Thumbnails sit above the text.
  - Removing a thumbnail that the text still mentions asks first [T3].
  - The CLI shrinks large images itself ([S1](../experiments/v2-spikes/S1-wire-20261017.md): a 7.2 MB PNG went out as a 0.5 MB JPEG), so Loom's own size check only names an image that is far too large.
- **A large paste** of 32 KiB or more becomes a "Pasted text · 48 KB" chip [T3].
  - The size counts as UTF-16 length or as UTF-8 bytes, whichever is reached first.
  - The chip goes out as its own text block in the same message.
  - ⌘⇧V pastes the text inline instead.
- **Files** become `@path` mentions. The CLI decides whether Claude may read them.

### The bar

The bar under the text takes the look of Codex's composer bar ([D-58](../../DECISIONS.md)). Loom's own controls stay; only the look changes.

- **Left:** + opens a menu with Add images and files, Mention a file or session (@), and Commands and skills (/); each item also has a shortcut. Next to it, the permission mode with its icon.
- **Right:** the context ring, then the model with its effort in a lighter tone, after the harness's mark ("Opus 5.5 High ⌄", one menu for both), then Send. Send names what Return does now ([DESIGN §11](../../design/DESIGN.md#11-chat-composer-v17-v24)): the round arrow for a plain send, light when it can act and dim when there is nothing to send; Interrupt, "Send now", "After this turn" (⌘ held), "Update" and "Resume" in the other states.
- **No boxes** around the controls. Each mode has an icon and a soft colour that runs from cool to warm as the mode lets Claude do more: Ask, Ask before edits, Accept edits, Auto, Full access ([D-63](../../DECISIONS.md), which replaces D-58's "no colour" rule). Plan is not offered, but a session can be in plan mode anyway and keeps its name. "Ask before edits" keeps its name beside Ask (the user's answer, 18 Oct).
- **Full access live.** Loom launches every Chat session with `--allow-dangerously-skip-permissions` (D-62). The flag makes Full access selectable without turning it on; without it the CLI refuses a live change to it.
- **Mode** always shows.
- **Mode, model and effort** change the live session at once, through `set_permission_mode`, `set_model` and `apply_flag_settings`. T3 waits for the next send.
- **Starting mode** of a new session is the last mode used in that project, otherwise Ask before edits (`default`), passed explicitly. There is no "Claude's default" (D-63). Loom never picks Full access by itself, it is T3's most criticised default, and Full access is never remembered as the last mode. An older session whose mode Loom does not know shows what the CLI reports (`initialize`'s `current_permission_mode`) under Loom's name.
- **Model and effort** are one chip with one popover ([D-63](../../DECISIONS.md), [D-75](../../DECISIONS.md)): the chip reads the harness's mark, the model, and its effort in a lighter word.
  - The popover lists the models grouped by harness, the session's own first. Claude Code's group lists Default (Recommended), then the CLI's models, or Opus, Sonnet and Haiku when the CLI lists none. A session keeps its harness, so the other harness's models are listed dimmed, "in a new session", and cannot be picked; on the new-session page both groups are live, and the model picked decides the harness.
  - Under the list, the effort is a slider with the level's name and a reset. The levels are the model's own (`supportedEffortLevels`), in the order low, medium, high, xhigh, max. A model with no levels gets no slider and no `--effort`. A model change clamps an effort the new model lacks, or clears it.
  - The reset returns to the effort the session opened with (the stored choice or the CLI's report), else to Default.
- **Ask** is Loom's own mode, in the Chat face only ([S9](../experiments/v2-spikes/S9-ask-mode-20261018.md), with S9b).
  - It is the CLI's `dontAsk`, plus live `permissions`, plus the `loom:Ask` output style from Loom's own plugin (`--plugin-dir` on every Chat spawn). The permissions allow WebFetch and WebSearch. They deny Write, Edit and NotebookEdit, plus every non-flag allow rule the user has, except those for Read, Glob, Grep, WebFetch, WebSearch and Agent. Those rules are read from `list_permission_rules` on entry, because the user's own allow rules are honoured in `dontAsk`.
  - Everything is set by control requests, never on the command line: launch-layer rules cannot be lifted live. `permissions.disableBypassPermissionsMode` is never sent.
  - To enter, Loom sends `set_permission_mode`, then `apply_flag_settings`. To leave, it clears the rules and the style, then sets the mode. A leave that fails halfway puts the rules back and stays in Ask.
  - A start or resume in Ask applies the layer before the first message, and again after `conversation_reset`. A message waits until the layer is on, so no turn runs before the rules. On the real CLI, `dontAsk` and the live allow and deny rules survive `/clear` in the same process (fix round 2, 1 Haiku turn): `list_permission_rules` matched before and after, the next `system/init` reported `dontAsk`, and an edit asked for after `/clear` was refused. The reapply is therefore a safeguard against a CLI that forgets. A session without the plugin does not start in Ask, and entering Ask is refused.
  - Entering Ask is refused while a tool approval waits ("Answer the waiting request first."). The driver never answers a request by itself.
  - In Ask only `ExitPlanMode` and `AskUserQuestion` reach Loom. A plan approved in Ask stays in Ask ("Stays in Ask"). A refused tool call shows as "refused in Ask", never as a failure. Mode changes go through one FIFO lock in the driver.
- **Ask in the terminal.** A terminal run never starts in `dontAsk`. Every terminal spawn (a start, a resume, Continue in Terminal) turns Ask into Ask before edits; the catalog records it, and the session says "Ask works in Chat. This terminal session runs in Ask before edits." Where "Sessions run in" is Terminal, the draft shows Ask disabled with "Chat only". Continue in Chat after such a run comes back in Ask before edits; Ask returns only when the user picks it. Full access in the terminal is unchanged.
- **Picks during a handover.** A mode, model or effort picked while a handover waits is the session's choice. It is not sent to the child that is going away: the target face's launch applies it. A handover that ends with the run still in Chat sends it afterwards. If the child then refuses a model or an effort, the pick is taken back: the choice, the chip and the catalog return to what the child runs.
- **Context ring** [T3 formula]:
  - **Used tokens** = input + cache creation + cache read + output tokens of the latest main-thread assistant message. Messages with a `parent_tool_use_id` and the model `<synthetic>` are skipped. After a `compact_boundary`, the count is the one after compaction.
  - **Display:** the ring alone, as in Codex's bar, when the model's window is known; otherwise a short token count ("84k") takes its place. The ring turns red above 90 %.
  - **Popover:** after 150 ms of hover it shows "Context · 120k of 1M (12%)", a bar, Compact now, and a note that Claude compacts by itself when needed. Compact now is disabled while Claude works or a card waits.
  - **Compacting** never changes what ↵ does (T3 #17467).

## Requests

Approvals, questions and plans. **must**, V18.

### Rules for every card

- **One card at a time.**
  - The card sits above the composer and shows "1 of 3" when several wait. Cards come in order of arrival.
  - A subagent's request names the subagent; T3's does not. The request carries `agent_id`, which Loom joins with the `system/task_started` record's `subagent_type` and `description` ([S1](../experiments/v2-spikes/S1-wire-20261017.md)). The hub's pending request carries it too (V23), with the name and description, so the Agents tab and the sidebar mark the subagent that waits and say where to answer: in the chat, where "Show the request" brings its pinned card forward, or in the session's terminal. On the terminal face the `PermissionRequest` hook carries `agent_id` (Claude Code 2.1.300). A main-thread request marks no subagent.
- **The driver never answers a request by itself**, in any mode. Every answer is a user action. (T3 #15503: in plan mode with Auto, T3 allowed edits without asking.)
- **Typing guard** [T3].
  - A card that arrives while you typed within the last 1.5 s does not take over the composer.
  - It waits as a one-line "1 request waiting" until you pause for 1.5 s, leave the composer, or send.
  - A send in that window goes out as a normal message, so text written for Claude never becomes a denial by accident.
- **Keys.**
  - No button is the default. ↵ never approves and Esc never denies (the concept's extension of DESIGN.md §6 to Chat).
  - Tab moves from the composer to the card, ← and → move between its buttons, and Space presses the focused one.
  - Digits 1–9 pick a question's options while the card has focus [T3].
  - The keys are checked on the Turkish Q layout ([concept decision 10](../v2-research/V2-CONCEPT.md#10-decisions-for-the-user)).
- **Afterwards** the card becomes one line in the stream; T3 keeps no visible record of the answer. For example:
  - "Allowed once: git push origin fix/webhook-sig"
  - "Allowed for this session: Bash(npm test:*)"
  - "Denied: rm -rf build · use make clean"
- **If Claude stops** while a card waits, the card says "Claude stopped before you answered", disables its buttons and offers Resume.
- **Elsewhere.** Home, the sidebar card, the Dock badge, the menu bar and notifications show what waits ([concept §5.5](../v2-research/V2-CONCEPT.md#55-approvals-questions-and-plans)).

### Approvals

- **The card shows:**
  - the kind: Command, File edit, File read, Web, or the MCP server and tool;
  - the full command or a diff summary, in mono: 5 lines, then it scrolls inside the card;
  - Claude's own words (`description`, present on every Bash request [S1](../experiments/v2-spikes/S1-wire-20261017.md) saw), then `decision_reason` when it is there.
- **The answers:**
  - **Allow once:** `allow` with `updatedInput` set to the original input.
  - **Allow for this session:** `allow` with `updatedPermissions` set to the request's own suggestions with the destination `session`, or a rule for the tool when there are none [T3]. No settings file is written. A command with a redirection (`> file`) asks again every time even after this answer ([S1](../experiments/v2-spikes/S1-wire-20261017.md)), so for those the card offers Allow once only.
  - **Deny:** `deny` with your typed note, or a short default message.
  - **⋯ → Deny and stop:** `deny` with `interrupt: true` [T3].

### Questions

- **The card shows** the header, the question as markdown, the options with their descriptions (and previews where given), and "Select one or more" for multi-select.
- **"Other"** is the composer text. Typing clears the picks, and picking clears the text [T3].
- **Picking.**
  - A single-select pick moves to the next question after 200 ms. The timer is cancelled when the question changes or another pick comes [T3].
  - Multi-select toggles, with Next and Submit.
  - Submit needs every question answered.
- **No dismiss.** Claude's questions cannot be dismissed: answer them or stop the turn [T3].
- **The answer** is `allow` with `updatedInput` set to the original input plus `answers`, keyed by the question text. Multi-select labels are joined with ", " [T3].
- **The stream keeps** "Asked: … · You chose: …".

### Plans

- **In the stream** the plan is a document card.
  - Its title comes from the first heading.
  - Over 900 characters or 20 lines, it collapses to a 10-line preview with "Show full plan" [T3].
  - It offers Copy and Open file.
  - It stays visible in a folded turn, and every version stays in the transcript.
- **The pinned decision:**
  - **Approve**, with the build mode: Ask before edits, Accept edits or Auto. This sends `allow` for ExitPlanMode with the mode set in the answer (`updatedPermissions` with `setMode`), which keeps the same turn going ([S1](../experiments/v2-spikes/S1-wire-20261017.md)). A plain allow would return to the mode before planning, so Loom always sends the chosen mode.
  - **Keep planning:** `deny`, with the composer text as feedback. Claude keeps planning in the same turn.
- **No fallback.** S1 showed that the allow carries the turn on, so T3's deny-and-new-turn way is not built.
- **After approval,** the plan's steps fill the Tasks tab (concept).
- **"Implement in a new session"** is **later** [T3].

### As built in V18 (18 Oct)

- The answers' wire shapes are as above. Allow for this session uses the CLI's own suggestions, rewritten to the destination `session`; with none, the button names the whole tool ("Allow all WebFetch this session"). It is not offered for a command that writes to a file: `/dev/null` targets and descriptor duplications (`2>&1`) are not file writes, while a quoted `>` and a here-doc count as one.
- A `setMode` granted through Allow for this session is recorded like a plan's mode.
- Deny and stop pauses Loom's queue, like an interrupt. No answer is taken while the session stops, and a request that arrives during Stop is not shown.
- The plan card preselects Ask before edits and offers Ask before edits, Accept edits and Auto.
- The ring on a focused card starts on no button, so a Space right after Tab presses nothing.
- The typing guard runs on system uptime; text the composer or the cards set themselves is not typing.
- An answered card folds for 4 s. The cut-off card stays until the next run.

### As built in V24 (18 Oct)

- While a card waits, the composer is compact: one line and the bar, with no hints line. The card has layout priority, so at 780×500 its buttons, the banner and the composer stay visible.
- The queue's Send now is refused while a request waits.
- A Retry that succeeds takes its returned copy out of the composer and the draft file. It removes text only at a message boundary, so the user's own text is never cut.
- The live feed is released when no view shows it; the ended view counts as a view. A cut-off card shows again when the session is opened.
- Draft files, attachments and thumbnails are read off the main thread. Text typed before a draft's read finishes is kept after the draft's text.
- In Ask, the plan card's approval keeps the session in Ask ("Stays in Ask"), and no tool approval is allowed while Ask is on.
- Checked on the real CLI by Release B's acceptance (18 Oct):
  - Entering and leaving Ask keeps the process, and the same edits work after leaving.
  - In Ask, Haiku follows the `loom:Ask` style and attempts no tool at all. With the rules and no style, the CLI itself refuses Write, Edit, a project-allowed `mkdir` (through the mirrored deny) and `echo >`, and no request reaches Loom.
  - The first call after entering Ask read 13,247 and created 9,995 prompt tokens, so part of the prefix is cached again. Fix round 1 found the cause: the switch of the permission mode to `dontAsk` itself (mode alone: 9,693 created). Ask's rules and style add about 0.3k. The cache breaks about 13.2k tokens in, inside the first user turn's context, while the system prompt and the tools stay the same. A shorter style would not help. Planner decision: Ask keeps `dontAsk`, because without it the CLI would ask Loom about every tool the rules do not cover, and the driver never answers a request itself. Whether the other mode switches cost the same is not measured.

## Lifecycle additions

These add to [concept §5.6](../v2-research/V2-CONCEPT.md#56-lifecycle):

- Working ends only with the main thread's `result`.
- Esc and the composer's Interrupt keep the process alive. Only the header's Stop ends it, as the concept describes.
- The working state and its timer come from timestamps that Loom keeps, never from the moment a view appeared.
- **Ready** is the response to the `initialize` control request, which Loom sends first (0.26 s in [S1](../experiments/v2-spikes/S1-wire-20261017.md)). `system/init` arrives only at the start of each turn, after a send, so it never gates Ready.
- **Stop and face switching** keep this order:
  1. interrupt;
  2. wait for the `result`;
  3. close stdin;
  4. wait for the exit.

  Closing stdin does not cancel a pending request: the request fails as a tool error and Claude carries on. A waiting card is therefore cancelled by the interrupt first.

  [S2](../experiments/v2-spikes/S2-handover-20261017.md) ran this order cleanly in both directions. A switch during a turn or with a card waiting is covered by V16's own tests.
- **Resume** brings back the history, but neither face reliably restores the mode, the model or the effort ([S1](../experiments/v2-spikes/S1-wire-20261017.md), [S2](../experiments/v2-spikes/S2-handover-20261017.md)).
  - Every spawn therefore passes all three, the terminal's `--resume` included.
  - The model stays the one the session had: a different model at a handover re-creates the whole cache (47k tokens in S2).
  - Loom reads the mode from `initialize`, `system/init`, `system/status` or a hook payload. The transcript's `permission-mode` records are not the runtime truth (S2).
- **Cost of a handover.** The first resume in the other face writes about 17k tokens of cache, because the terminal's prompt is larger ([S3](../experiments/v2-spikes/S3-resources-20261017.md)). The resumed session's `SessionStart` hook carries `context_tokens`, `prompt_cache_likely_expired` and `estimated_cache_write_usd`, so Loom can show the cost before the first message in the new face (S2).
- **The CLI's own picker.** A session born in Chat does not appear in `claude --resume` in the user's own terminal. A terminal-born session does, even after Chat continued it ([S2](../experiments/v2-spikes/S2-handover-20261017.md)). Loom's Continue in Terminal opens a session by id, so it is unaffected.
- **Records from the other face.** The terminal's `/exit` leaves three user-role records in the transcript, which the reader filters. Every record carries `entrypoint` and `version`, so Loom can tell which face wrote a turn (S2).
- **Privacy.** The `initialize` response holds the account's e-mail, organisation and plan. Loom never logs or stores them.
- **Drift signals** include:
  - `assistant.error` categories;
  - `result.terminal_reason` (`api_error`) with `api_error_status`.

  A `result` can say `subtype:"success"` with `is_error:true`, so Loom reads `is_error` and `terminal_reason`, never `subtype` alone.

  A safety refusal can come back as an `is_error` result even for a harmless prompt; [S0](../experiments/v2-spikes/S0-hooks-20261017.md)'s run saw one on Haiku. Loom shows the CLI's text with Retry and does not count it as drift.
- **As built in V16** (the driver, `Sources/LoomChat/Driver/`):
  - Every Chat spawn and resume sets `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` and `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1`, and passes `--thinking-display summarized` when the CLI accepts it. The first message goes over stdin. `control_request_progress` is a known message, never drift.
  - Mode, model and effort live per session in the catalog, written by the runtime on start and on a successful live change, and read by every spawn in either face. A session's running state is its run (terminal or pipe), never whether a terminal view exists.
  - Stop, Quit and a face switch run the run's `leave` step: interrupt, then wait for the `result` within the input-close grace (2 s); then stdin closes and Loom waits for the exit; signals come only after a second grace. A run whose leader already exited skips `leave`, so a crash never reads as the user's Stop. Quit waits for pipe stops already under way.
  - A Stop while Starting cancels the start. An exit before Ready shows the CLI's first stderr line.
  - Background tasks (`background_tasks_changed`, `task_*`) keep a finished turn under way; the session reads Working, not Finished, until they end. Stopping them before a Stop (`stop_task`) is not built. Its shape, recorded by Release B's acceptance on the real CLI (18 Oct): the request `{subtype: "stop_task", task_id}` is answered with an empty success `{}`, then `task_updated`, `task_notification` and `background_tasks_changed` follow. The task id comes from `system/task_started` (`is_backgrounded: true`, type `local_bash`).
  - Only Loom's own interrupt makes an aborted turn read "You stopped", whatever `is_error` says (S1 §0 item 9 says a `now` cut gives `is_error:true`; its recordings t07 and t23 show `false`).
  - `/clear` moves the run to a new card in both faces, with its choices and face. The Chat stream on the new card starts over with a "Conversation cleared" marker; the old card keeps its transcript.
    - On the real CLI (2.1.300, measured by fix round 1 on 18 Oct), `/clear` writes `conversation_reset`, then the SessionStart(clear) hook, then `system/init`, then `result`.
    - The reset's `new_conversation_id` is the reset record's own uuid, not a session, and no transcript is written under it. The hook and the init carry the session the transcript is written under.
    - Loom keeps only the reset's trigger, for the marker, and moves once, on whichever of the hook and the init it reads first. Adopting the reset's id had made an empty card and a second move.
  - A tool call that a permission decision refused reads Denied, whatever its result text says. The wire marks it with `tool_result_meta[].non_execution_kind` (`user-rejected` or `permission-rule`); transcripts call it `toolDenialKind`. A deny with a note has the note alone as its text. A tool that ran and failed stays Failed.
  - A failed capability probe (`claude --version` and `--help`) is retried once after about 1 s, and journaled as `toolchain_probe_failed` with its kind (timeout, exit status or spawn) and no output. The acceptance saw it fail once in six launches.
  - The queue holds at most 100 items and 1 MiB. An item leaves the queue only once it is written; on failure it stays and the queue says why. An unreadable queue file is set aside, never overwritten, and deleting a session deletes its queue.
  - Waiting requests of both providers reach Home, the sidebar and the Dock through one list (`SessionViewState.waitingRequests`).
  - The live stream shows only the newest run. An earlier run's rows that only Loom has (face, mode and model markers, "Session started" or "Resumed", failure notices, answered cards) stay above it in the history, placed by their time. A run that resumes a session opens with "Resumed", after a relaunch too; a new session shows one "Session started".
  - The live row's "No activity" follows the CLI's output only, never Loom's own changes to the rows.
  - "Show all" on a live row reads the result from the transcript, so it is hidden when Loom has no Claude config folder.
- **As built in V19** (Chat first, 18 Oct):
  - Chat is the default face. A new Claude session starts in the face that Settings → General → "Sessions run in" names (D-69 (1)). Codex is unchanged.
  - The owning face is the persisted `sessions.run_endpoint` (pipe is Chat, anything else is the terminal). It is written before the run-started event, also on `/clear`'s move path. A legacy NULL reads as terminal, and every resume reads the face from the catalog.
  - The ⋯ menu offers Continue in Terminal and Continue in Chat.
    - A handover waits for a running turn and never cuts it. It refuses when a request waits for an answer, when background work runs (checked again right before the stop), or while the session starts, stops or already hands over.
    - Every handover has a point of no return. Before it, Stop and "Cancel Continue in …" win. After it, Cancel is no longer offered, and Stop ends the target face's start.
    - A terminal session at its prompt is idle: only an input reason (MCP elicitation, `agent_needs_input`) counts as a waiting request, not `idle_prompt`. Terminal to Chat waits for the idle standing to hold for 1.5 s, then checks it again. A prompt typed but not sent in the TUI is lost, and the item's help says so.
    - The queue and the draft are kept both ways. While a handover is in progress the composer says "Moving to the terminal…" and send is off. `/clear` during the wait ends the handover with a notice.
  - A stopped Chat-owned session keeps its composer. A send resumes it in Chat, and the unread messages and the draft come back there.
  - A Chat start reports started only after Ready. A start that fails before Ready gives the first message back to the draft page.
  - Keys:
    - ⌃O cycles the view from the live composer.
    - Typing in the stream moves focus to the composer, and the key goes through the input method, so ⌥-typed characters arrive too.
    - Stop ⌘. ends the session in both faces and cancels a waiting handover.
  - The composer outlives the live feed: every view binds it to the feed it shows.
  - The session's top stack (header and banners) is drawn above the live stream.
- **As changed in fix round 3** ([D-69](../../DECISIONS.md), 19 Oct). It supersedes three V19 points above:
  - The face is one app-wide switch, Settings → General → "Sessions run in" (the stored key is still `newSessionFace`). A start or a resume takes the switch, not the endpoint of the last run; a running session keeps its face until it stops, and a stopped Claude session shows the live chat while the switch says Chat. Codex stays in the terminal.
  - No menu moves a session: the ⋯ menu and the `/` menu lose Continue in Terminal and Continue in Chat. The ⋯ menu keeps "Cancel Continue in …" while a move waits. The policy banner's "Switch to Terminal" is the one move: it sets the switch to Terminal and moves the session with the handover above. A queue paused for a move stays paused until the user resumes it.
  - The default permission mode is a Settings choice ("Mode of new sessions"): last used in the project, or one fixed mode, Full access included after a confirmation there. Ask is Chat only, so an Ask default starts as Ask before edits where the switch says Terminal.
- **How sent messages reach the transcript** (checked on the S1 recordings, 18 Oct). A message sent while the session is idle becomes a `user` record with the uuid Loom put on its stdin line and `origin.kind` `human`; 75 of 85 such lines are found that way. A message sent while a turn runs (`next` or `now`) is written instead as an `attachment` record of type `queued_command` with its own uuid, a `source_uuid`, `commandMode` `prompt` and `origin.kind` `human`, beside `queue-operation` records (S1 t07); a finished background task's notification is also a `queued_command`, with `commandMode` `task-notification`. A message that was cancelled before it was read, or a session without persistence, leaves no user record. The transcript view shows a human `prompt` `queued_command` as your message inside the turn that read it, under its `source_uuid`; task notifications stay silent. The live view matches a transcript prompt to the live run by its id, by a uuid Read now re-sent it under, or by its text when it was written at or after the run's start, so it does not depend on `source_uuid` being the uuid Loom sent. Release B's acceptance checked it on the real CLI (18 Oct): `source_uuid` is the uuid Loom sent, the record has its own `uuid`, and no `user` record exists under the sent uuid.

## Side chat, quick question and rewind (S6, S8)

From [S6](../experiments/v2-spikes/S6-fork-20261018.md) and [S8](../experiments/v2-spikes/S8-rewind-20261018.md) on Claude Code 2.1.300.

- **Quick question (⌘;)** uses the `side_question` control request: `{question}` in, one `control_request_progress`, then `{response, synthetic:false}`. It runs over the parent's cached context, has no tools, writes nothing to the transcript, and works while the session is idle, waiting or running a tool. It reports no usage. An identical question asked twice makes two model calls. One answer given while text was streaming carried text from the main answer, so the panel shows the answer as Claude's reply to the side question only. There is no `/btw` fallback. Built in V22's first part: ⌘; (File → Ask a Quick Question…, and the palette) opens a floating card over a running Chat session; the wait is 120 s; nothing is kept, and a late answer is discarded. It is off, with its reason, for a stopped, starting, stopping or handed-over session and for the terminal face. A CLI without the request answers "Unsupported control request subtype", which the panel shows as "This Claude version has no quick questions".
- **Side chat** is a fork: `--resume <parent> --fork-session --permission-mode default`, with model, effort and thinking as the parent's. Its first call reads about 97% of the parent's context from cache, and an approval waiting or a tool running in the parent does not stop it. Never use `--disallowed-tools` or `--tools` (cache miss), plan mode (partial miss) or `--no-session-persistence` (cannot resume). Edits are refused by Loom answering `can_use_tool` with a deny and its own message, Bash included, unless the user allows them. The fork's transcript is a full copy that never names the parent, so Loom stores the link. Discard runs after the fork's process has exited and removes the six items S6 lists (Q4); the parent's transcript is not touched. Built in V22's second part: the fork is `--resume <parent> --fork-session --session-id <new>` with the id chosen before the spawn, on a hidden card linked to its parent. Its `--settings` add `permissions.ask` for the edit tools and Bash, so the user's own allow rules never let an edit through (S6b's step 0: the cache held at 99.99%). It refuses edits unless "Allow edits" is on in that side chat, allows only commands it can prove read-only, runs no slash commands, is never titled by Claude, and is deleted through the verified path without touching the parent.
- **Side tab** (V22's third part): the inspector's fourth tab, 392 pt, on a Claude session that has a provider conversation id, in either face; never on Codex or on a side chat. A side chat's thread is the main chat's own rows from its first question on (`side_first_uuid`): the parent's copied records and the CLI's repair records before it are never shown, and it has no "Rewind files". The first question forks, a stopped side chat resumes on the next question, and "New side chat" forks again. "Allow edits" is off at every start of a side chat, however its last run ended. "Send to main as a note" sends one message to the parent the way the composer's Return goes (`next` to a live Chat parent; a stopped Chat parent resumes first; off on the terminal face): "A note from a side chat:", a blank line, the question quoted line by line with "> " (a bare ">" for an empty line), a blank line, then the answer. A side chat that waits for the user shows only as a dot on the Side tab: no list, count, notification or badge sees it.
  - **Process lifetime** (D-72, Release C's evaluation): a side chat's process runs only while it is the open one in its parent's Side tab.
    - When another side chat is opened, or "New side chat" starts, the previous one is retired. An idle one stops at once (Close's stop, so "Allow edits" turns off). One with a running turn or a waiting card stops when it settles, unless it became the open one again meanwhile.
    - When the parent's run ends (the user's Stop, or by itself; not a move to the terminal), every side chat is retired by the same rule, the open one too.
    - The thread stays, and the next question resumes the chat. Closing the inspector or selecting another session retires nothing.
- **Rewind files** needs `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` on every Chat spawn from the session's first turn; `rewind_files` takes the uuid Loom put on its own user line. A checkpoint is the state at the start of a user message. The dry run matched the real rewind exactly in 11 of 11 pairs and reads nothing it changes, so it is the confirmation sheet. Write, Edit and NotebookEdit are covered; a file only Bash or only a subagent changed is never touched, and a file an edit tool touched is restored even over a later Bash change. A rewind silently overwrites the user's own edits to those files. So (V21) the sheet marks a file modified more than 2 s after Claude's last edit record of it, or deleted since; Loom copies the listed files aside before the call (64 MiB a file and 256 MiB a rewind, checked by `stat` before the copy; each copy an APFS clone, its hash streamed) and never rewinds without that copy. Undo, on the newest rewind's marker until the next send, puts the copies back and asks before it overwrites files changed since; the newest turn's changes come back only through it. The copies exist only while their Undo can be offered (D-72). They are deleted when the Undo closes: at the next send, at a newer rewind's marker, or by Undo itself. So a session holds the copies of at most one rewind, usually none. A stopped session keeps its open Undo and its copies. At launch the host removes every copy an earlier run left. Rewind is on only at the prompt: ready, no turn, no request, no handover.
- **Rewind conversation** (`rewind_conversation`) accepts only the latest user message. It returns `prefillText`, appends a `last-prompt` record with `rewound:true` and keeps the old branch in the file; `TranscriptLens` follows `parentUuid` from the latest `last-prompt.leafUuid`. Rewinding files first, in the same process, is required, because checkpoints of rewound-away messages are gone after a resume.

## Notifications

[T3, **should**, V18]

Loom keeps its notification settings. What reaches the user outside the window is DESIGN §19's ([D-52](../../DECISIONS.md), [D-79](../../DECISIONS.md)), which replaced the routing this section first took from T3:

- **A system notification** only when a session starts to wait for an approval, a question or a plan while the app is not the active app. It goes when the session stops waiting. Finished, failed and working send nothing.
- **The Dock badge** counts the sessions that need you.
- **A click** on the notification brings the app forward on the session.

## Draft session

V07. The user chose N1 ([D-59](../../DECISIONS.md)). [T3, shell study §1]

- **Opening.**
  - ⌘N opens the draft in the project you were last in: the persisted last-used project. On Home, the sidebar's "New session" row under Home opens the same draft (V19); Home has no start box (D-63).
  - The headline asks "What should we work on in [project ▾]?", and the project name is the picker.
- **The composer** is the session's own composer.
  - Under it, one strip holds the branch choice: stay on the current branch, a new branch, or a new worktree.
  - The strip disappears after the first send, and the branch then shows in the header.
- **Draft storage.**
  - Each project keeps at most one empty draft and reuses it [T3].
  - An empty draft is invisible. A draft with text shows in the sidebar with Discard [T3].
- **Defaults**, in this order:
  1. what you pick in the draft;
  2. for the mode, the fixed mode of Settings → General → "Mode of new sessions" when the user set one (D-69; Full access included, after a confirmation there);
  3. what you last used in that project;
  4. Loom's settings (the model; the mode's Settings level is 2);
  5. for the mode, Ask before edits (`default`), passed explicitly; there is no "Claude's default" (D-63).

  This fixes T3 #6508, where the result depended on the entry point.
- **Starting.**
  - ↵ starts the session. ⌘↵ starts it and opens a fresh draft [T3].
  - Nothing runs until the first send. The session then starts through today's launch path, with that message.
  - After the send, the composer moves to the bottom. There is no movement under Reduce Motion; T3's default is no motion either.

## Not taken from T3 Code

- **Assistant text only as whole messages.**
- **Polling task files** every 250 ms for Bash output.
- **Terminal-style command output:** a terminal model for output and a 1,436-line shell-wrapper tokenizer. Loom shows the command as written and its output with basic ANSI colour.
- **Web content:** HTML replies, Mermaid rendering and an embedded browser. Loom has no web views.
- **History behind an explicit "Load earlier turns" button.** Loom reads a local file and loads on scroll.
- **Two separate fold states.** Loom keeps one set of open folds.
- **T3's defaults:** Full access by default, compacting before send, and every notification off by default.
- **A prompt stash on ⌘S**, which is Save on macOS. A stash is **later**, with another key.
- **Rich-text editing in the composer.** Loom uses plain text with chips.

## Questions added to spike S1

These questions were answered on 17 Oct in the [S1](../experiments/v2-spikes/S1-wire-20261017.md) evidence, §B. The sections above already use the answers.

The [protocol brief](../v2-research/evidence/chat-protocol-20261017.md) already asks how `priority` behaves and which mode follows an ExitPlanMode allow. This spec adds:

1. Is the replay echo sent when the CLI accepts a message, or when Claude reads it? The answer decides whether "delivered" can also mean "read".
2. Which field of a `can_use_tool` request names the subagent that asked?
3. Is there a control request that moves running subagents to the background, as T3 does before it steers?
4. Does `@path` in a stream-json user message attach the file the way the terminal does?
5. Do Claude 5.1+ update blocks carry a field that tells them apart from private thinking?
6. Do Edit and Write results in stream-json carry `structuredPatch`, for the +/− counts?
7. Is a failed Bash command always `is_error`, and is its exit code a field?
8. What does `rate_limit_event` carry for the usage-limit banner's reset time?

## Summary by tier

| Tier | Items | Slices |
| --- | --- | --- |
| must | **Model and thinking:** entry list and pure row derivation, stable row ids, the turn rule, cold open, the thinking rule. **Stream:** work rows and group summaries, the failure rule, the turn fold, the live row and its timer, markers, the scroll latch. **Composer:** ↵, ⌘↵, Esc and ↑, the send button, the queue with pause, delivery, drafts, `/` and `@` with Turkish Q access, images and large pastes, the bar after Codex's with live mode, model and effort, the starting mode, the context ring. **Requests:** one card at a time, no self-answers, the typing guard, card keys, answer records, approvals, questions, plans | V12, V13, V16, V17, V18 |
| should | Long-message collapse, the changed-files card, the tasks line, subagent groups, error dismissal, type to focus, notification routing, Read now | V13, V17, V18 |
| later | Fork from here, Implement in a new session, swapping ↵ and ⌘↵, a prompt stash, Mermaid in the browser, a timeline minimap, citations, opening Changes by itself after large turns (T3: 3 files or 50 lines) | after Release C, with the user's word |
