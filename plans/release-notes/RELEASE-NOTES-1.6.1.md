# Sphyrna 1.6.1

Draft of 24 Oct 2026, for `@user`'s release (the push and the GitHub release wait for `@user`, [D-16](../../DECISIONS.md), [D-83](../../DECISIONS.md)). The round is [FEEDBACK-5](../archive/FEEDBACK-5.md); the release line is [D-93](../../DECISIONS.md).

1.6.1 fixes what 1.6.0 got wrong in daily use, lets you move things by dragging, and gives the app a new icon.

## Fixes

- **Settings takes clicks again.** The section tabs and the controls on a page did not answer a click in 1.6.0. The window no longer moves by its background; its title strip still moves it.
- **Put in Draft says what it does.** On Home, it puts the line below any text already in the session's composer and opens the session, so you see it land. A session that runs in the terminal gets a button that reads Copy to Clipboard, with the reason on hover.
- **Draft Brief never overwrites your draft.** When your draft has text, the brief goes into a new draft of the same project and your draft keeps every word. Nothing is copied to the clipboard any more.
- **Several drafts per project.** ⌘N opens an empty draft, the project's own when it has one. The sidebar lists every draft that has text, newest first, by its first line, and Discard works on one draft.
- **Two faults in the log are gone**, one in Home's Remora reads and one in the run host's signature check.

## Drag and drop

- **Tabs.** Drag a session from the sidebar, Home or a tab onto the tab strip to open it there, and drag tabs to put them in order. While you drag a session over the header, the tab row shows as a drop zone, even with no tabs open.
- **Reopen Closed Tab** (⇧⌘T, in the File menu) brings back the last tab you closed. Sphyrna remembers the last 10 until you quit.
- **Projects.** Drag a project's head in the sidebar to move it. Move Up and Move Down stay.
- **Sessions into the chat.** Drop a Claude session on the composer of a Chat session, or pick it in the @ list, and it becomes a pill. When you send, each pill becomes the mention Claude reads (the session's title, its transcript path and the start of its last answer), before your words. The pills stay in the draft.
- **Files and folders** drop into every composer as @path and @folder/, and anywhere on a session's stream or on the new-session page.
- **From the Changes tab,** drag a changed file into a composer. It brings the @path text, never the file itself.

## Flow

- **A resizable inspector.** Drag its edge. Overview, Side and Changes each remember their own width, and the content takes the new width when you let go.
- **The Dock menu.** Right-click the Dock icon for the sessions that need you, the sessions that are working (up to 5 each) and New Claude Session.
- **The session menu** gains Open Folder in Editor, Open in Terminal and Copy Transcript Path.
- **The command palette** gains Add project… and Reveal in Finder, and New session answers to "draft".
- **Keep Mac awake** (Settings → General): Off, or While a session works. It holds off idle sleep of the Mac while any session works; the display still sleeps.
- **Notify when a long turn finishes** (Settings → General, off until you turn it on): a silent banner with an Open button, for a turn of 30 seconds or more that ends while you are elsewhere.

## Look

- **A new app icon:** the hammerhead seen from above, near-white on deep ink blue.
- **Remora's face** on Home is the menu bar's hammerhead, still. It fades in when a new brief starts. The swimming arrival is gone.

## Chat

- **The stream costs less.** While a long answer arrives, Sphyrna lays it out once per update and spaces updates out when one costs a lot, up to 160 ms. A long code block settles in chunks while it streams, so it costs no more than prose; its Copy appears when the block closes. An answer's text can be selected once the answer finishes. A Chat answer streaming at 600 characters a second costs about 14 % less CPU than in 1.6.0, about 19 % less at 6,000, and a long code block about half.

## Going back to 1.6.0

1.6.0 keeps one draft per project. If you go back to it, it shows the latest draft of each project, and the others are not kept.
