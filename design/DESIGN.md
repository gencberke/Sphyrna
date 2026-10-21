# Sphyrna design: Ink

**Status:** Ink is the design language of Sphyrna, the app this repository builds as Loom until 1.6.0's rename ([D-74](../DECISIONS.md), [D-77](../DECISIONS.md), [D-83](../DECISIONS.md)). It replaces Night Fleece (identity A, [D-22](../DECISIONS.md)) and Night Fleece 2 (V2-PLAN's V01), which are outdated. This file is the canonical visual contract: the rules and values that every new or changed surface follows. Where a rule comes from a user decision, the decision follows in parentheses. It names the app Sphyrna, as the app's own words do from 1.6.0; the code's names (`LoomCore`, `LoomTheme` and the rest) stay.

**v3.** The user calls this direction v3 ([D-75](../DECISIONS.md)): the Ink language with its two appearances, Ink (dark) and Paper (light). In these documents "Ink" names the language, and "Ink" and "Paper" also name the appearances (§2). v3 is not a product version and not the `v2` branch.

**The reference.** [reference.html](reference.html) draws every surface as decided, live, in both appearances and every tone ([D-82](../DECISIONS.md), §1). Where the reference and this file differ, this file wins.

The code still draws Night Fleece 2 until the Ink migration moves each surface ([V2-PLAN §13](../plans/V2-PLAN.md#13-the-ui-revision-ink), §18 below). Until then:
- [UI-MAP.md](UI-MAP.md) says what the code draws today;
- the Night Fleece contract is in git, as this file was before Ink (`git show 371aaf6:design/DESIGN.md`), for the migration only;
- new work is designed in Ink. A change that ships before the Ink tokens land uses the existing tokens by role (canvas, raised, text tier, accent), so the migration can remap it, and never adds a Night Fleece value.

## Ink in six rules

1. **One canvas.** The window is one surface. Hairlines divide it, and nothing is boxed twice. Only what you act on is lifted: the composer, a menu, a card.
2. **Two voices.** SF Pro for what you read. SF Mono for what the machine says: branches, paths, times, tokens, counts and keys.
3. **Colour means state.** The chrome is grey. Periwinkle marks focus and the default action. Orange, blue and red are status only. A project's tone is its mark, the tint of its tabs and the tint of its selected session.
4. **One control family.** One height, radius, hover and focus ring for every control. Session tabs are pills and view tabs are underlined, wherever they appear.
5. **Two reading points.** The sidebar tells how every session is doing. The header tells how this one is doing and what you can do. Everything else is detail.
6. **A school of sharks.** The sharks are the identity: a hammerhead, a thresher, a whale shark and the remora, drawn in ASCII. They swim on empty canvases and while something waits, never behind the terminal, a list or text being read (§17).

Ink keeps what Sphyrna is:
- the sidebar, the header, the inspector and the tabs;
- the status marks and what they mean, and the periwinkle accent;
- the untouched CLI;
- every behaviour in §7–§16.

What it changes is the surface.

## 1. References

**The Ink reference.** [reference.html](reference.html) is the visual reference ([D-82](../DECISIONS.md)). It gathers the accepted previews, each brought up to date with the decisions that came after it, in ten chapters: Identity, The language, The school, The session window, Home, Remora, Projects and new sessions, The review surfaces, Settings and About, and The edges. Every window is live: its menus open, its states switch and its keys work. The bar sets the appearance, the tone and the art for every window, and shows the pins that the notes under a window name, or a window at 100 %.
- **Its sources** are in `design/reference-src/`. `docs/` holds one document per accepted preview: the foundations (D-74), the chat (D-75), the project page (D-76), the identity (D-77), the review surfaces (D-78), the edges (D-79), Remora (D-80), and Settings and About (D-81). `shared/` holds the tokens, the parts, the sheets and the art engine they share, and `shell/` and `landing/` the two pages' own parts.
- **The build:** `python3 design/reference-src/build.py` writes `reference.html` and `landing.html`, each under 1 MB; `--docs DIR` also writes each document on its own, for checks. A change to a surface changes its document and this file, and the pages are built again, never edited by hand.
- **The landing page,** [landing.html](landing.html), shows the same windows with plain copy around them, one for each thing the app does, in the app's voice (§6 Voice and copy).
- **The identity's files** are in [identity/](identity/): the icon's two layers and the Front mark (§6 Name and marks).

**Where Ink comes from.** These are inspiration only; nothing is copied.
- Orca: one consistent app, read from one or two definite points, clearly segmented, with one family of slick controls. Its sidebar's harness marks led to Sphyrna's (D-75).
- haj's interface: a black canvas with a faint grid, an ultralight heading, one composer card, mono hints and ASCII hammerheads.
- Claude's desktop sidebar: subagents branching from their session, one branch per row.
- [stackedlol/ascii-sharks](https://github.com/stackedlol/ascii-sharks): sharks drawn as an ASCII density field. Sphyrna's sharks are its own code (§17).

**History.** The earlier previews and design files that the reference replaced (D-82) are not part of this contract, and nothing here links to them. The content and behaviour they chose still stand where §2–§20 keep them; their look does not.

## 2. Elements to keep

The window's structure stays; Ink redraws it.

1. **Window buttons and the sidebar header.** The native red, yellow and green window buttons stay. The sidebar's 52 pt header row holds them and the sidebar toggle, nothing else. The view switch is the list's heading (item 3), so the header has no folder and clock buttons and no ⋯ menu; Add Project is in the footer's `+` menu (D-75).

   There is no navbar band: the header sits on the canvas (O-03, closed by D-69), with a hairline under it.
2. **One canvas.** The sidebar and the main pane are one canvas, divided by a 1 pt hairline; nothing between them is boxed (rule 1).
   - **Appearance:** Ink (dark, the default), Paper (light) or Match system, chosen in Settings → Theme.
   - **The terminal face** is dark in every appearance (§6 Terminal framing).
   - **The sidebar** is Solid by default (D-81). Settings → Theme → Sidebar keeps Glass as an option (D-57): the sidebar's canvas at 0.8 over the behind-window material (D-81). Reduce Transparency draws Solid.
   - **The tone** (D-63, D-81): Neutral, Warm or Cool, chosen in Settings → Theme → Tone, a cast over every grey of the window (§3 Tones).
3. **The sidebar, top to bottom.**
   - The search field: 30 pt, a hairline box, with ⌘K in mono.
   - The Home row: 28 pt, with the count of sessions that need you. The count is the Dock badge's, drawn only above 0, as an attention-wash badge with attention text.
   - The New session row (V19).
   - The list, under its heading: the view's name as a section label, and at the trailing end the switch "projects · activity" in text, the chosen word in primary medium and the other in tertiary (⌘2 and ⌘1 still switch). Then the project view or the activity view.
   - The footer.
4. **Session rows** (§6 Rows).
   - **The project view** has one 28 pt line per session: the status column, the harness's mark (§6 Iconography), the title, a pin glyph when pinned, and the time in mono. A selected session takes its project's tint.
   - **The activity view** (E7 in [the reference](reference.html#session), D-75) lists Drafts, then Active, then the days (Today, Yesterday, weekday, date). Each section has a heading in 11.5 medium tertiary, with its count in mono. Active holds the sessions with a run under way or an end nobody read; the selected one stays until another is selected. A session is a card, from top to bottom:
     - the status column, the harness's mark, the title (13) and the time;
     - the reason line, only in the Active section (D-69), in 11.5 secondary with a command in mono, such as "Allow: <command>", "Asks: <header>", "Plan ready for review" or "Failed: <cause>";
     - a fixed bottom row in 11 tertiary: the branch glyph and the branch in mono (or the origin of a session another one opened), the pin glyph, and at the trailing end the project's mark (12) and name (D-69 (7)).

     The second and third lines align under the title. A card takes the project view's row language: radius 10, the selected one in its project's tint, and its subagents branching from the status column (§4). The harness's mark replaces the old trailing provider mark.
5. **Footer bar** (D-32). It is 46 pt, with a hairline above it, and holds:
   - **Left: a `+` menu.** Its session items carry their harness's mark (14). It offers:
     - a new Claude session;
     - a new Codex session, disabled with "Codex comes in a later version" in a build that cannot start it;
     - a new Claude session without a project, while a session is selected;
     - Add Project.
   - **Middle: the usage chip**, in mono 11.
     - Its left side is today's tokens (`1.2M today`).
     - Pinned to the right is the plan window that runs out first, when the Claude CLI reports plan limits: `5h` or `Wk`, a 40×4 meter of the share remaining, and the percent remaining.
     - There is no money. Under 20 % remaining, the percent and the meter fill take the attention colour.
     - When the chip is narrow, the meter drops first, then the tokens are cut with an ellipsis. The limit is never cut.
     - Its states are `Indexing…` and `No usage yet`, and it is hidden when there is no usage index.
     - The tooltip has the token split and both plan windows; the accessibility label has the tokens and the bottleneck window.
     - A click opens Settings at Usage.
   - **Right: a gear** that opens Settings.

   **Settings** (D-81; [the reference](reference.html#settings)) is one 680×520 window that follows the appearance and the tone. Only its close button shows. Its sections are underlined view tabs (§6 Tabs) in the 52 pt title band, where the window's title would be: General, Theme, Usage, Sessions, Remora (§20, D-80) and About. ⌘, opens it on the section last shown, and the usage chip opens it on Usage.
   - **A section's content** has a 32 inset and scrolls under the band. A group is a card on raised 1 under a section label, 20 apart. A row holds the label in 13, one line of help in 12 secondary and the control at the trailing edge, and is at least 48 high. A notice from macOS adds an attention line and its button. A menu picker is a secondary button with the value and two chevrons; its menu is the popover.
   - **Full access asks first** (D-83): choosing it as the default mode opens a sheet of §6's family, not an alert. Cancel has the focus, Use Full Access is tinted in the Full access mode's tone, Return does nothing and Esc cancels. Picking Full access again while it is the default asks nothing.
   - **Theme:** Appearance (Ink, Paper, Match system), Animated art (§17, D-79), Tone as three tiles (Neutral, Warm, Cool, §3 Tones), Sidebar (Solid, Glass) and Project colors (§6). Every choice applies at once.
   - **Usage:** the period (24 h, 7 d, 30 d, 90 d), then four cards, plan limits first (FB3-1): Plan limits; the period's total, with the tokens, the estimated cost, the kinds and the share served from the cache; tokens per day; and tokens by model. A footer says when it was updated and the prices' date, with a refresh button.
   - **Sessions:** the cleanup review. Nothing is checked by default. Delete asks first, with §6's Delete for every checked session at once: the names, Removed and Kept, and Delete Permanently in the failure tint (§6 Sheets, D-83). Each row then says what happened to it.
   - **About:** the app icon (Rising from 1.6.0, item 7), with a hammerhead that crosses once behind it each time About opens and then rests (§17); the name in title type; the version in mono; and three facts, each with its one action: the data folder (Reveal), the Claude profile in use (read only) and Diagnostics (Collect Diagnostics…).
6. **The header** (§6 Header) and **the tab row** (§6 Tabs).
7. **The app icon.** The ram mark stays until 1.6.0, which brings the name Sphyrna, the Rising icon and the Front menu bar mark (D-77, §6 Name and marks; their files are in [identity/](identity/)). Today's: [ICNS](../assets/Loom.icns), [PNG](../assets/Loom.png), [SVG](../assets/Loom.svg), [raw mark](../assets/Loom-mark.svg), [menu-bar mark](../assets/Loom-menubar.svg). The harness marks (§6 Iconography) are in [assets/harness](../assets/harness); originals and sources are in [assets/brand](../assets/brand/README.md).
8. **Accessibility** (§6 Accessibility).
   - Reduce Transparency draws the sidebar Solid.
   - Reduce Motion makes every transition instant. The working spinner keeps moving (D-12), and so does the art while Settings → Theme → Animated art is on, as it is by default (D-79, §17).
   - The focus ring shows only with keyboard navigation.

## 3. Sizes and colours

All sizes are points. Every token has an Ink value (dark) and a Paper value (light): one name with two values, as before (`LoomTheme.Adaptive`). The code moves to these values in the Ink migration; until then it draws Night Fleece 2's (UI-MAP → Design tokens in code). `scripts/check-theme-literals.sh` keeps colour, size and radius literals out of the views, as before.

### Surfaces, lines and fills

| Token | Ink | Paper | Use |
| --- | --- | --- | --- |
| Canvas | `#0C0C0E` | `#F7F6F3` | The window: sidebar, main pane, inspector, header and tab row. The terminal face's whole pane uses Ink's canvas in both appearances |
| Raised 1 | `#121215` | `#FBFAF8` | Cards: Home's lists and side cards, Settings' groups |
| Raised 2 | `#17171B` | `#FEFDFC` | The composer |
| Popover | `#1C1C21` | `#FFFFFF` | Menus, pickers, the palette, the inspector when it overlays the content, the quick question |
| Segment on | `#26262C` | `#FFFFFF` | The chosen segment of a segmented control |
| Hairline, strong, stronger | white 7.5 %, 11.5 %, 20 % | ink 8.5 %, 13 %, 24 % | Dividers; the edges of controls, fields and chips; a hovered edge |
| Hover, selected, pressed | white 5 %, 8 %, 12 % | ink 4.5 %, 7 %, 10 % | The pill (below) and the control family |
| Grid | white 3.4 % | ink 6 % | The faint grid of an empty canvas: the new-session page and Home's band |
| Tree | `#3B3B41` | `#C4C2BE` | The subagent branches. It is opaque, so crossing lines never brighten |
| Art | `#ECECF0` at the art's alpha | `#161518` at the art's alpha | The sharks (§17) |
| Scrim | black 40 % | ink 22 % | Behind the palette and sheets |

In Paper, "ink" is `#1E1C1A`.

### Tones

(D-63, D-81; Settings → Theme → Tone.) Neutral is the table above, and the default. Warm and Cool are casts: they replace these six greys and leave every other token as it is, the status, accent and project colours included. The terminal face takes the tone's canvas, so it stays flush (§6 Terminal framing). Text keeps its contrast floors in every tone (Contrast, below).

| Token | Warm, Ink | Warm, Paper | Cool, Ink | Cool, Paper |
| --- | --- | --- | --- | --- |
| Canvas | `#0E0C0A` | `#F8F2E8` | `#0A0C10` | `#F1F3F6` |
| Raised 1 | `#15120F` | `#FCF8F1` | `#0F1217` | `#F8F9FB` |
| Raised 2 | `#1A1714` | `#FEFCF8` | `#14171D` | `#FCFDFE` |
| Popover | `#201C18` | `#FFFDF9` | `#191D24` | `#FFFFFF` |
| Segment on | `#2C2721` | `#FFFDF9` | `#232833` | `#FFFFFF` |
| Tree | `#433C34` | `#CFC4B3` | `#363E4C` | `#BCC2CB` |

**Depth.** Only lifted things cast a shadow; the canvas, rows and tabs never do.
- **A card:** a 1 pt inner top highlight in Ink and a 1–2 pt drop.
- **A popover:** a hairline ring and a 64 pt soft shadow.
- **The composer:** a 12 % hairline ring and a 90 pt soft shadow.
- **The window:** a hairline ring and a deep soft shadow.

The exact values are the reference's `--sh-card`, `--sh-pop`, `--sh-composer` and `--sh-win`.

### Text

| Tier | Ink | Paper | Use | Floor |
| --- | --- | --- | --- | --- |
| Primary | `#ECECEF` | `#19181B` | Titles, body text and values | 7:1; about 16:1 on the canvas |
| Secondary | `#9E9EA8` | `#5F5D63` | Supporting text, descriptions, inactive tabs | 4.5:1; 7.4 and 6.0 on the canvas |
| Tertiary | `#868690` | `#67656B` | The quiet voice: labels, meta, key hints, counts, line numbers | 4.5:1 on the canvas, both raised levels and the hover and selected fills; 5.4 and 5.2 on the canvas |
| Faint | `#6B6B75` | `#8E8B91` | Placeholders, disabled items and decorative marks, never text you need | 2.5:1 |

A first draft drew tertiary one step dimmer (`#6B6B75`, 3.7:1). Ink keeps the app's contrast floors, so quiet text is a step brighter, and the dimmer value became the faint tier. On a popover, quiet text uses secondary.

### Accent, status and content colours

| Token | Ink | Paper | Use |
| --- | --- | --- | --- |
| Accent base, high, low | `#8791CF`, `#A9B0E3`, `#5E68A8` | `#4B56A8`, `#3A4491`, `#A3ABDD` | **Base:** the default or main action's fill, Sphyrna's focus ring, the open view tab's underline, a switch that is on. **High:** accent text on raised levels and popovers. **Low:** strokes and fills without text |
| Accent wash | 16 % | 11 % | A field's focus halo, a comment box |
| On accent | `#0B0E16` | `#FBF8F2` | Text on the accent fill. Light text on the Ink accent is 3.0:1, so it is not allowed |
| Attention, its text, its wash | `#FF9E0A`, `#FFB547`, 13 % | `#C46A00`, `#7A3A00`, 11 % | Needs approval, Waiting for you, Identity unclear |
| Unviewed, its text, its wash | `#5C8CFF`, `#8FB0FF`, 13 % | `#2557CC`, `#1B43A3`, 10 % | Finished, nobody looked yet |
| Failure, its text, its wash | `#F2615C`, `#FF8A85`, 13 % | `#C8322C`, `#8E1D19`, 10 % | Failed, Stop not verified, Problem; destructive buttons |
| Success, its text | `#4CC38A`, `#7BDBA8` | `#186E43`, `#125A36` | Content only (added lines, passing checks), never a status mark |
| Diff bands | success or failure at 9 % | at 8 % | A changed line in a diff |

**How the status colours are used.**
- A status hue marks, and its text variant writes; the text variant holds 4.5:1 on every level.
- In Paper, the attention and failure dots are lighter than Night Fleece's Light ones (`#974700`, `#B22722`): a dot needs only 3:1, and these give 3.6 and 4.9 on the canvas. Words keep the deep text variants.

### Project tones

| Tone | Ink | Paper | Ink, Increase Contrast | Paper, Increase Contrast |
| --- | --- | --- | --- | --- |
| Rose | `#E68EBA` | `#B03F78` | `#F5B2D4` | `#962A60` |
| Orchid | `#D194E6` | `#8A42AC` | `#E6B7F5` | `#742E94` |
| Aqua | `#80D5DB` | `#10747E` | `#A0E9EE` | `#0A5C65` |
| Mint | `#83D8B0` | `#1A7A51` | `#A2ECC9` | `#12603C` |
| Sage | `#92C186` | `#557A28` | `#AADB9E` | `#435F1D` |
| Lemon | `#CCE07B` | `#6F7500` | `#E0F29C` | `#555A00` |

Each tone stays at least 30° of hue from the status hues and the accent. Their use is in §6 Project colour.

### Mode tones

`Chat/LoomTheme+Composer.swift`, `ModeTone`; the modes are in §11.
- Each tone is at least 4.5:1 on the composer, the popover and the canvas, also under the hover fill.
- The migration checks them again on Ink's levels.

| Mode | Ink | Paper |
| --- | --- | --- |
| Ask (teal) | `#7FC8D8` | `#0E6B7A` |
| Ask before edits | accent high `#A9B0E3` | accent high `#3A4491` |
| Accept edits (green) | `#86D3A4` | `#1B6B3F` |
| Auto (yellow) | `#D9C677` | `#745B00` |
| Full access (orange) | `#EF9C70` | `#9E4108` |
| Plan (purple) | `#B9A0E6` | `#6B46B0` |

### Type

| Role | Face, size and weight | Use |
| --- | --- | --- |
| Display | SF Pro Display 46, weight 200 (ultralight), tracking −3 % | The new-session page's one question |
| Statement | SF Pro Display 42, weight 200, tracking −3 % | Home's one sentence |
| Title | SF Pro 20, semibold | A page's title: a project page, Settings, an empty state |
| Header | 13, semibold | The session's title in the header; a card's heading |
| Body | 13, regular | Rows, menus and fields. Buttons are 12.5 medium |
| Small | 12, regular | Supporting lines, facts, a card's reason line |
| Label | SF Mono 10.5, capitals, tracked | Section labels (Session, Worktree, Plan limits), written in sentence case and drawn in capitals |
| Meta | SF Mono 11 to 11.5 | Branches, paths, times, tokens, counts and key hints |
| Terminal | SF Mono 14; Settings allows 11 to 20 | The CLI |
| Reading | 14 / 22 | Chat prose, your message and the composer's text (D-75) |
| Code | SF Mono 12.5 / 20 | Code blocks in the chat. A work row's subject is mono 12 (§7) |

Weight carries hierarchy before size. Sizes are fixed (no Dynamic Type), as before.

### Shape and rhythm

| Item | Value |
| --- | --- |
| Grid | 4 pt. A glyph and its text may be 2 apart. Optical values stay off the grid: hairlines and the tree's offsets |
| Radii | **4:** key caps. **6:** controls (buttons, icon buttons, chips). **8:** rows, fields and large buttons. **10:** the activity view's cards. **12:** cards, menus and the window. **18:** the composer. A nested control steps down by its padding: a control group or a segmented control is 7, with 5 inside. The palette keeps 14 |
| Heights | **22:** chip, state pill, small button. **24:** subagent row. **26:** control (button, icon button, segment, control group, session tab); the chat's work row. **28:** sidebar row and project head; the chat's turn fold and live row. **30:** field and large button; a row of the model popover. **36:** tab row. **38:** the composer's bar. **52:** header |
| Window | Initial 1220×780, minimum 780×500 |
| Sidebar | Default 300 wide, range 220–520, persisted |
| Detail pane | Minimum 480 |
| Header and centre line | The 52 pt header's content is centred 26 from the window top, on the window buttons' line; an empty unified `NSToolbar` makes AppKit centre the buttons there. Clearance for the window buttons: 76 in the sidebar header, and 66 in the detail header, only when the sidebar is collapsed and not full screen |
| Tab row | 36, under the header, with a hairline under it. It is drawn with two or more tabs (D-33) |
| Inspector | 328 wide; 556 on Changes (V20); 392 on Side (V22). It is a column while the content keeps 480 beside it, else it overlays on the popover level with its shadow (V09). No animation: a width change is one PTY resize |
| Palette | 620 wide, 88 below the window top, radius 14. Input 48; rows 34 (hit rows 54); headers 28 in label type; footer 34 with key hints in mono; the list is up to 420 high, then scrolls. With Remora on, a typed question's first row is Ask Remora, and its answer opens in the palette (§20) |
| Columns | Chat 700; the new-session page 720; Home 1,000 at most |

### The pill

One rounded fill sits under a row, a menu row or an icon button for hover, selection and press (D-63).
- **Fills:** hover 5 %, selected 8 % with a 1 pt hairline, pressed 12 %. Paper uses 4.5 %, 7 % and 10 % of the ink.
- **Selected session rows** take their project's tint instead (§6 Project colour). Home, the head of a project whose page is open and every other row keep the neutral selected fill.
- **Radius:** 8 for rows and menu rows, 6 for icon buttons.
- **Motion:** it fades in and out in 120 ms (`Motion.selection`), and at once under Reduce Motion.
- **Increase Contrast** draws the hairline on hover and press too, and the fill at 0.75.
- **Keyboard focus** draws Sphyrna's focus ring on the pill's edge, and hit areas never shrink.
- **A hover redraws only its own pill.**

View tabs, segments and session tabs are not the pill (§6 Tabs).

### Contrast

Each pair is checked in both appearances when its token lands, by `ThemeAppearanceTests`, `LoomThemeTests`, `HighlightTests` and `ProjectColorUITests`. The floors:
- **Primary:** at least 7:1.
- **Secondary and tertiary:** at least 4.5:1 on the canvas, both raised levels and the pill's hover and selected fills. A press is momentary, so the pressed fill sets no floor (V2-PLAN §14, under D-83).
- **Status and accent as text:** in their text variants and the accent's high step, at least 4.5:1.
- **Marks and the focus ring:** at least 3:1. The tree's turns are structure, like the hairlines: they carry no state (the row's mark does), so they keep the tree's colour with no floor (V2-PLAN §14, under D-83).

The figures above are estimates from the reference's values; the tests give the real ones.

### Meters and the effort slider

**Plan meters** keep their rule (Home's Plan limits card, `PlanPaceLine`, the footer chip and Settings → Usage).
- A meter fills the share still left, from the leading edge, in secondary on a strong-hairline track.
- It turns attention orange when under 20 % is left, or when the window runs out before its reset (over pace).
- In `PlanPaceLine`, a 2 pt primary tick marks where an even pace would leave the remainder now.
- The track and the fill are 6 pt (the chip's are 4); the tick is 10.
- There is no green.
- The figure reads "N% left", with the used share in the tooltip.

**The effort slider** (§11).
- The track is the strong hairline.
- The thumb is white in Ink and the on-accent cream in Paper, at least 3:1 against the accent fill.
- The dots on the fill are white 55 % or on-accent 70 %; the off dots are white or ink 22 %.

**Visual acceptance.** Compare a surface with its window in [the reference](reference.html) at the same size and scale (the bar's 100 %). Screenshots cannot show hover, focus, Glass, motion or the art's frame rate; those need the user's eyes. A pill's hover can be held on with the `hover:` command (DEVELOPMENT §5).

## 4. Status language

(User decisions: 5 Oct 2026, UI feedback package G, [UI plan](../plans/cp5/UI.md); 6 Oct 2026 for Reduce Motion; 20 Oct 2026 for the spinner, D-74.)

- **One status column.** Every status surface draws the same marks in a 12 pt slot at the start of the row: the sidebar, the tabs, the header's pill, the inspector, Home, the palette and the menu bar. One glance down the left edge reads every session.
- **Working: the braille spinner** `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`.
  - It is ten frames of one SF Mono braille cell, at 12 frames a second.
  - It is 14 pt in the 12 pt slot, in primary; in a subagent row it is 12.5 pt, in secondary.
  - In code it is a render-server layer animation of pre-drawn frames, a `CAKeyframeAnimation` over the frames' contents, so it costs the app no wakeups, as the chase did.
  - It stands on its first frame when the window is hidden or inactive, and in the sidebar when the sidebar is collapsed ([contract §10](../LOOM-PRODUCT-CONTRACT.md#10-resource-and-performance-acceptance)).
  - It keeps moving under Reduce Motion (D-12), like the system's own small progress indicators.
  - It replaces the chase everywhere, the menu bar badge included (D-52's badge, D-74).
- **The other marks.**

  | State | Mark |
  | --- | --- |
  | Needs approval, Waiting for you | A 7 pt attention dot |
  | Finished (nobody looked yet) | A 7 pt unviewed dot |
  | Failed, Stop not verified, Problem | A 7 pt failure dot; a 7 pt diamond while macOS "Differentiate without color" is on (O-12, D-69) |
  | Idle, Ready, Stale, ended | No mark. Stale also dims the title |
  | State unknown | A hollow 8 pt ring in faint |
  | Identity unclear | A hollow attention ring |

  The exact mapping and derivation order are in [UI-MAP.md](UI-MAP.md#status-to-visual-mapping).
- **The header's state pill.** A 22 pt capsule carries the mark and the label (11.5 medium).
  - Working: primary on the selected fill.
  - Ready, Idle, Stale and State unknown: secondary on the hover fill, with no mark.
  - Needs approval, Waiting for you and Identity unclear: the attention wash behind the attention text.
  - Failed, Stop not verified and Problem: the failure wash and text.
  - Finished: the unviewed wash and text.

  A status wash appears only behind its own label. `.ended` has no pill.
- **Subagents under a session** (D-39, 12 Oct 2026; Ink look, D-74). The full rule is in its own section below.
- **A session that opens a session** (D-39, D-40, 12 Oct 2026). The full rule is in its own section below.
- **Project rows** show no session count. A dot appears when a session in the project fails, needs attention or finished unviewed (by priority: failure, then attention, then unviewed).
- **A click on a project's name** opens its page (V04). The chevron, shown on hover, collapses and expands the project's sessions. The head of an open page takes the neutral selected fill.
- **A draft with text** is a one-line italic row in secondary, the height of a session line (28 pt). It sits under its project in the project view, and under a "Drafts" heading in the activity view. Discard is the hover ×. It has no mark.
- **The project view** does not repeat the project name; the activity view shows the project's mark and name on its cards.
- **New-session entries.** A project's right-click menu and its actions menu list New Claude Session and New Codex Session, each with its harness's mark (§6 Iconography). A build that cannot start Codex shows the Codex entry disabled, followed by "Codex comes in a later version" (D-69; Codex stays frozen, D-28).

### Subagents under a session

(D-39, 12 Oct 2026; Ink look, D-74; A8 in [the reference](reference.html#session).)

**The tree.** A session that runs subagents shows them below its row; a session without subagents draws its row alone, unchanged. Each subagent row (24 pt) hangs on its own branch:
- The branch is a 1 pt line in the tree colour. It leaves the session's status column (22 pt from the list's edge), runs down and turns into the row with a 7 pt curve.
- A middle branch carries the line on to the next sibling. The last branch curves and ends.
- A subagent started by a subagent (depth above 1) branches one step (19 pt) further. Its ancestor's line runs on beside it while that ancestor has a sibling below.

**What a row shows.**
- One row per **running** subagent, at most 3:
  - the working spinner, the same layer frames, so no new animation;
  - the agent type (12 medium, primary);
  - the description (secondary, cut at the end);
  - the elapsed time in mono tertiary ("now", "2m"), from the sidebar's minute tick, with no timer of its own.
- **More than 3 running:** a "+N more" row opens the rest, and "Show fewer" closes them.
- **Finished subagents** of the current turn fold into one secondary "N finished" row, with a check in faint. A click opens their rows (type in secondary, description, and a static duration in seconds such as "18s") and closes them again. A session with only finished subagents shows only that row.
- The fold rows hang on branches like any other row.
- Subagent rows carry no harness mark: a subagent runs on its session's harness (D-75).

**Clicks and lifetime.**
- A click on any subagent row selects the parent session and opens its inspector on the Agents tab, where the subagent's transcript is read (V09). A subagent has no terminal of its own, so the terminal stays on screen.
- Finished ones go with the user's next real prompt; a hand-back of a background subagent or a task notification is not one. They also go with the end of the run.
- Running ones stay until they stop or the run ends.

**Accessibility.**
- Each row reads "Subagent Explore, Find login flow handlers, running".
- The fold rows read "N subagents finished", with an expanded or collapsed value.
- The marks are hidden from accessibility, like every status mark.

**A subagent that waits for the user (V23).**
- **In the tree:** a running subagent whose request waits takes the attention dot in place of the spinner. It stays among the shown rows even past the cap of 3, and its row reads "..., running, waiting for you".
- **In the Agents tab:** the same subagent gets the same dot, with "Waiting for you" under its description (small, in the attention text).
- **A main-thread request** marks no subagent.
- **The open subagent's notice**, under its name, says where to answer, in the face the session runs in:
  - On the Chat face: "Waiting for you: answer it in the chat", with a "Show the Request" button (accent text, small). The button makes that subagent's request the pinned card, opens a stack the typing guard holds, and scrolls the pinned stack to it. It does so with no animation and without scrolling the stream.
  - On the terminal face: "Waiting for approval: answer it in the session's terminal". It shows on the subagent that the `PermissionRequest` hook named; the hook carries `agent_id` (checked 20 Oct 2026 with Claude Code 2.1.300). When no hook reported the request and only Claude's registry says the session waits, it shows on the running open subagent.

**A stopped session's list (V23).** With the Agents tab open on a Claude session that has no run, the list is the session's own folder (`<project folder>/<session id>/subagents/`).
- Each entry has its type, its description and the transcript file's times, shown as a duration. The list keeps at most 500 entries, the newest.
- An entry reads "Finished 41s", or "Interrupted" when the main transcript has no result for the Agent call that started it. "Interrupted" shows as small text under the description, and in the state pill.
- The empty list says "No subagents in this session." over a small hammerhead swimming in place (§17).
- Opening an entry shows its transcript as a live subagent's.

**The Agents tab** (V09, V23; [the reference](reference.html#review), D-78).
- **The list:** "Running N", then "Finished N", oldest first in each. A row is a card (raised 1, hairline, radius 10) with the tree's status column (the spinner, the attention dot, or nothing once finished), the type in 12.5 medium primary, the time in mono tertiary, and the description in secondary. "Waiting for you" (attention text) or "Interrupted" (secondary) sits under the description. There is no accent badge and no accent type.
- **The transcript** opens in place of the list, under "‹ Agents" (Esc goes back too), the state pill ("Running 1m", "Finished 1m 34s", "Interrupted") and the name, "type · description", in body semibold. Opening it widens the inspector to 556, the review width; the list keeps 328. The width changes on the click and never animates.
- **Two voices:** the agent's words in the chat's type (12.5, primary) after ⏺; a tool call in mono 11.5, its name in semibold primary and its argument in secondary; its result after ⎿ in mono 11 tertiary, one line with "(+N lines)", an error in the failure text; "✻ Thought for Ns" in tertiary. The brief opens it under the "Brief" label, in secondary, cut at four lines. The text is plain: no Markdown, and no link opens.
- **The tail:** the working spinner and "Running…"; while the agent's request waits, the attention dot and "Waiting for you". A finished agent's last words carry the label "Result", since they are what goes back to the session.

**The chat's subagent card (V23).**
- While the subagent runs, the card's detail line is its newest words, updated as each block arrives: one line, cut at the end.
- When it is done, the line is its result, up to 3 lines.
- Under the header, the card ends with "Open in Agents" (meta, secondary, chevron). The card as a whole opens the Agents tab on that subagent.

### A session that opens a session

(D-39, D-40, 12 Oct 2026.)

**The request.** An agent's request to open a session never starts anything by itself. A callout above the requesting session's terminal (§6 Controls) asks "Open a new session?". It shows:
- the project and the title, in mono meta;
- the first lines of the message, with the rest one click away in a bounded scroll area;
- two buttons, **Deny** and **Open Session**.

**Keys and state.**
- Neither button is the default action, and Return never answers the callout; Return stays with the terminal.
- While it waits, or after a failed start until it is dismissed, the requester's row, tab and project dot read **Needs approval**.
- Sphyrna keeps no tracker keys (D-69). `open` always starts a new session; an agent can list the user's sessions, read only, with `sessions` (D-83), and asks the user before it reuses one.

**After approval.** Nothing changes the selection: approving leaves the user where they are, and the new session appears at the top of its project with its spinner.

**The new session's row shows where it came from.**
- When both sessions are on the same branch, an arrow glyph and "from <requester>" take the branch's place in the meta row.
- Otherwise the branch stays, and the origin is in the tooltip ("Opened by <requester>").
- A requester that no longer exists reads "another session".
- The detail facts add "Opened by".

## 5. Open design items

- **The previews are settled** (D-74 to D-81) and gathered in [the reference](reference.html) (D-82, §1). Its documents carry the decisions that came after each preview: the app named Sphyrna, the harness marks, the Rising icon, the remora with its disc, Animated art, the tones and Glass at 0.8, the sheets' one family and Title Case for commands.
- **Settled by D-83:** the two readings the reference made in Settings, which §2 now holds as rules (Full access asks first; the cleanup's Delete), and the rename's open questions (O-14): the bundle id, the data folder and the repository keep Loom's names, and the wordmark is set in SF Pro (§6 Name and marks).
- **The knot in code.** The app draws the harness marks as images (`ProviderIcon`). The ChatGPT knot needs a template image drawn in the text colour, so it comes with the build (V2-PLAN §13). Until then the app shows `harness-codex.png`, the ChatGPT app icon.
- **The art in the app** (§17): a native renderer within the budgets. A spike measures it before it is built.
- **The README renders** (`design/readme/*.html`) show Night Fleece. They are redrawn in Ink before 1.6.0's README, from the reference's documents.
- **Settled by Ink:** the navbar's "more solid" layout (user feedback item 6, 5 Oct 2026). The header on the canvas, with its hairline, its two groups and one control family, is the answer; O-03 stays closed.
- **Settled by D-69** (O-12):
  - the failure diamond under Differentiate without color, on a row's mark and a project's dot alike;
  - the app's mark above the first-run Home's message, now the app icon at 84 (D-77, D-79);
  - Title Case for menu and button commands, and sentence case for messages, labels and alerts.

## 6. Identity (Ink)

(Chosen 20 Oct 2026, D-74. It replaces identity A · Night Fleece, D-22.)

| Area | Rule |
| --- | --- |
| Personality | A calm black canvas where many agents work, for one power user. Competent and quiet. The art gives it character; the words stay plain. Never cheerful at the user's expense. |
| Name and marks | (D-77; [the reference](reference.html#identity).)<br><br>**The name** is **Sphyrna**, the hammerhead's genus, from 1.6.0 (D-68, D-83); 0.4.4 stays Loom. It is written wherever the app is named: the app menu (About Sphyrna, Hide Sphyrna, Quit Sphyrna), About, every sentence that names the app ("Sphyrna could not find Claude"), the banners, the Dock and README. The code's names stay (LoomCore and the rest). The bundle id (`local.loom.desktop`), the data folder (`~/Library/Application Support/Loom`) and the repository (gencberke/loom) keep Loom's names, so that macOS keeps the app's permissions and the data stays where it is; the wordmark is set in SF Pro (D-83).<br><br>**Home's assistant is Remora** (Lombot until D-77): the field "Ask Remora about your sessions", VoiceOver's group "Remora", Settings' Remora tab and the memory note `Remora.md` (§9, §20).<br><br>**The app icon** is drawn by the art engine (§17): Rising, the hammerhead climbing to the left on black, in SF Mono Bold glyphs at 0.97 white, 0.7 of the square and centred on its outline's box. It ships as two layers for Icon Composer, the black ground and the glyphs, so that macOS makes its dark, clear and tinted versions (`identity/icon-1024.png`, `icon-foreground.png`).<br><br>**The menu bar mark** is Front: the hammerhead seen from the front, with an eye hole at each tip of the hammer, the dorsal fin, the jaw and the pectoral fins. It is one colour on the 20 pt canvas, 18 wide. Idle, it is a template image; with a badge the app draws it, white on a dark bar and black on a light one. The badge slot is today's: a 7 pt dot at the lower right, cut 5.2 around, where working draws the braille spinner (§4). Its paths use only M, L, C and Z (`identity/menubar-front.svg`). |
| Voice and copy | Sentence case for messages, labels and alerts. No exclamation marks, no emoji, no "Oops". Say what happened, what Sphyrna did or did not do, and what the user can do. Exact provider names ("Claude", "Codex"). No metaphor, including empty states: the art never speaks, so there are no sharks in the copy, no puns and no names for the sharks in the interface. Remora names the assistant, not the fish drawn for it (D-77). Vocabulary: text the user reads says "session"; "conversation" appears only in code, protocol names and quoted CLI output (`scripts/check-user-wording.sh` guards LoomCatalogUI and loom-app). |
| Colour | **Appearance** (D-63; Settings → Theme → Appearance, `UIPreferences.appearance`, applies live): Ink (dark, the default), Paper (light) or Match system. **Tone** (D-63, D-81; Settings → Theme → Tone): Neutral, Warm or Cool, a cast over every grey (§3 Tones). **The chrome is grey:** four neutral levels (§3), hairlines and the pill. **One accent.** **Three status hues** with text variants, and a content-only success hue. **One project colour class** (below). **The permission modes** keep their icons and tones (D-63, §3 Mode tones): Ask `bubble.left` in teal, Ask before edits `shield` in the accent's high step, Accept edits `pencil.line` in green, Auto `bolt` in yellow, Full access `exclamationmark.circle` in orange, Plan `list.bullet.rectangle` in purple. A mode Sphyrna has no name for takes secondary and the plain shield. **No harness colour tokens:** the Claude spark keeps its own clay, and the ChatGPT knot takes the text colour (Iconography, below). |
| Project colour | (D-48; the Ink look, D-74, replaces D-50's stripe.) A fixed palette of six tones (§3). A project gets the least-used tone, ties in palette order, and the user can change it (the project menu's Color: the six tones and None, as a row of swatches with the current one ringed, D-76). The tone appears in four places only:<br>- **The mark:** the project's initial, the first letter of its name, bold, on a soft square of the tone (24 % in Ink, 15 % in Paper), with the initial in the tone. It is 16 pt (radius 5) in the sidebar's project head, 14 pt (radius 4) in tabs, chips and lists, 12 pt (radius 3.5) on an activity card, and 26 pt (radius 8) on the project page.<br>- **The tabs:** every session tab is washed with its project's tone: 6 % at rest, 11 % under the pointer, and 16 % with a 1 pt edge of the tone at 42 % when open.<br>- **The selected session:** its row takes 14 % with a 1 pt edge at 34 %.<br>- **The header chip:** 10 % with a 1 pt edge at 32 %.<br><br>Where it never appears: never a dot, never in the status slot, never the colour of a title or a name, never inside the terminal, never a stripe.<br><br>**No tone.** A session without a project, a project set to None and an unknown stored tone stay neutral: the mark is a neutral square with the initial in secondary, and the tabs and the selection take the neutral fills.<br><br>**The setting.** Settings → Theme → Project colors (default on) turns every part off: the marks turn neutral, the tabs and the selection go grey, and the header chip stays as a neutral chip with the name and the branch. Stored tones are kept.<br><br>**Colour is never the only carrier.** The name is written beside the mark in the sidebar and the header. Tabs carry it in the tooltip ("Project: <name>") and the accessibility label (", project <name>").<br><br>**Contrast.** Primary holds at least 7:1 and secondary at least 4.5:1 on every tint. Ink gives primary at least 11.7 on an open tab and secondary at least 5.5 on a selected row; Paper gives 13 and 4.9. The mark's initial holds at least 3:1 on its square (Ink 5.5 to 7.6, Paper 3.8 to 4.5).<br><br>**Increase Contrast:** the edges take the tone at 75 %, and the mark's initial takes its Increase Contrast tone (§3).<br><br>All values are `LoomTheme.ProjectColor`. |
| Contrast | §3 Contrast. |
| Typography | Two voices (rule 2): SF Pro for what you read, SF Mono for what the machine says (§3 Type). Sizes are fixed; weight comes before size. |
| Iconography | SF Symbols: monochrome, regular, 13 to 16 pt in chrome (16 in an icon button), never palette-coloured.<br><br>**Harness marks** (D-75) say which agent runs a session, after Orca's sidebar but a size smaller:<br>- **Claude Code:** the Claude spark in its own clay, never tinted (`assets/harness/harness-claude.png`).<br>- **Codex:** the ChatGPT knot as a template image in primary text, so it is white in Ink and dark in Paper (`assets/harness/harness-codex-template.png`).<br>- **Sizes:** 12 pt on rows, cards and tabs; 13 in the header and on the model chip; 14 in menus.<br>- **Where:** it leads the title on every session row (both views), every activity card and the header. It sits in a tab's end slot until the pointer turns it into the close button. It starts the model chip (§11) and heads each harness in the model popover, marks the New Claude Session and New Codex Session items, and stands before the side chat's model (§16). Subagent rows carry none: a subagent runs on its session's harness.<br><br>The app icon (the ram until 1.6.0, then Rising, D-77) is the About mark and heads the first-run Home; the menu bar carries its one-colour mark (the ram's until 1.6.0, then Front). |
| Shape and spacing | §3 Shape and rhythm. |
| Materials | Opaque: one canvas, the raised levels and the popovers. Only the sidebar can be glass, and only in the Glass style (D-57): its canvas at 0.8 over the behind-window material, with Solid the default (D-81). There is no blur anywhere else. |
| Header | (Rule 5; A3 and A4 in [the reference](reference.html#session).) The 52 pt header sits on the canvas with a hairline under it, with no band (O-03). It reads left to right: the harness's mark (13), the title (13 semibold, one line), what this is, and right after it **the state pill** (§4), how it is.<br><br>Everything you can do sits at the trailing edge, 8 apart, from the left:<br>- **The project chip.** 22 pt, radius 6: the mark (14) 4 pt from its edge, the name in 12 primary, a 1×12 hairline, the branch glyph and the branch in mono 11.5 secondary, on the tint of §6 Project colour.<br>- **The model segment** (D-69). A small context ring and the model's short name in 12 secondary, 6 apart. It shows only where the session has no composer bar.<br>- **A 1×16 hairline.**<br>- **The inspector toggle.** A 26 pt icon button (`sidebar.right`), on the selected fill while the inspector is open.<br>- **The control group.** 26 high, radius 7, with a strong-hairline edge. It holds a Stop segment while the run can be stopped (an 8×8 square with radius 1.5, and "Stop" in 12 medium), a hairline, and the ⋯ segment (30 wide), which is always there. A segment's hover is the hover fill.<br><br>**Transient texts** take the pill's place as secondary text: "Starting — complete any prompts in the terminal", "Continuing in Terminal when this turn ends", "Continuing in Chat when the session rests", "Moving to Chat…", "Deleting…" and the "Preparing…" notice.<br><br>**Narrow rows.** The title gives way first, down to 100 pt; then the model segment goes; then the chip gives up its branch; then the project name shortens (the chip never goes below 56). The pill and the group never shorten (`HeaderFlowPlan`).<br><br>**The branch** is a named branch or "Detached HEAD". Its tooltip is "Git branch", and a branch name is capped at 320 pt (FB4-6).<br><br>**Accessibility:** the chip reads "Project: <name>, branch <branch>". |
| Tabs | (Rule 4; A5.) There are two kinds, never mixed.<br><br>**Session tabs** are things you hold open, so they are pills.<br>- They sit in the 36 pt tab row under the header, with a hairline under the row.<br>- Each is 26 high, radius 7, 4 apart, 8 from the row's edge, and at most 230 wide.<br>- A tab holds the project's mark (14), the status slot, the title (12.5, secondary; primary on hover and when open) and a 16 pt end slot. The slot shows the harness's mark (12) and turns into the close button on hover, on the open tab too (D-75).<br>- Tabs carry the project tint of §6 Project colour.<br>- A "+" icon button (24) ends the row.<br><br>**View tabs** switch what you look at, so they are underlined text. They are the inspector's (Overview, Changes, Agents, Side), a project page's and Settings'.<br>- Labels are 12.5 medium, secondary; primary on hover and when open.<br>- The open tab has a 1.5 pt accent underline on the bar's hairline.<br>- Counts are in mono 10.5 tertiary ("Changes 4").<br>- Tabs are 18 apart.<br>- There is no pill.<br><br>**A segment** is a choice inside a pane (Last turn · Whole session · Branch; Ink · Paper · Match system). It is a 26 pt group with radius 7 on the hover fill; the chosen segment is raised (Segment on, with a strong hairline and a 1 pt drop).<br><br>The session tab row and the inspector's tab bar share the 36 pt height, so they read as one line. The tab strip's behaviour (when it shows, overflow, pinning, closing) is unchanged (UI-MAP → Tab strip). |
| Controls | (Rule 4.)<br><br>**Buttons:**<br>- 26 high, radius 6, 12.5 medium.<br>- A page's main action is 30 high, radius 8, 13.<br>- A small button is 22 high, radius 5, 11.5.<br>- One fill, the accent with on-accent text, for the default or main action. The rest are secondary buttons with a strong-hairline edge, ghost buttons in secondary text, or a destructive button in the failure text with the failure wash on hover.<br>- Hover adds the hover fill. Disabled is 38 % opacity.<br><br>**Icon buttons:** 26 pt, radius 6, a 16 pt glyph in secondary until hovered.<br><br>**Fields:** 30 high, radius 8, with a strong hairline. Focus draws the accent edge and a 3 pt accent-wash halo, never a glow.<br><br>**Switches:** 28×16, accent when on.<br><br>**Focus:** Sphyrna's ring is the accent, 2 pt, 2 pt outside the control. Native text fields keep the system ring.<br><br>**Menus and pickers:** the popover level, radius 12, 6 pt inside. Rows are 28 with the pill (radius 8). A menu appears with opacity and a 3 pt rise over 160 ms, and closes at once.<br><br>**Callouts** carry a request above the terminal or the history view: a provider's request, or a session's request to open a session.<br>- The box: the attention wash (13 %), a 1 pt attention edge at 32 %, radius 12, 14×16 inside.<br>- The heading: the dot and a 13 semibold heading; the meta in mono.<br>- The text: 12.5 primary.<br>- The buttons sit at the trailing end.<br>- The orange is the edge and the dot, not a solid box.<br>- Return never answers a callout while a terminal is below it.<br><br>**The palette:** §3. |
| Sheets | (D-78; [the reference](reference.html#review), The sheets.) Every question asked before something changes is a sheet of one family.<br><br>**Shape:**<br>- 420 wide, or 480 when it lists files; the popover surface, radius 12, 20 inside, with the popover's ring and shadow.<br>- It comes down under the window's header, centred, over the scrim (§3).<br>- The question is the title, in 14 semibold. The subject sits under it in 13 medium, cut at two lines: the session's name, or the message in quotes.<br>- Then the facts in 12.5, and the buttons at the trailing edge, Cancel first. A way out, such as Delete's Remove from Sphyrna Only, sits at the leading edge.<br><br>**Filled means Return:**<br>- The filled button is the sheet's default, and only a sheet that saves has one (Rename's Save).<br>- A sheet that removes or rewinds has none. Its button is tinted: the failure wash and text when it deletes (Delete Permanently, Remove, Discard), the accent wash and text for Rewind Files. Return does nothing there, Esc cancels, and the focus starts on Cancel.<br>- Remove from Sphyrna Only asks through the system's compact alert, with the app icon, and follows the same keys.<br><br>**Delete's facts** come as one lead sentence that ends "This can't be undone.", then two short lists under labels: "Removed" (the transcript and the subagent transcripts; file snapshots and session folders; then the count, size and folder in mono) and "Kept" (your prompts in Claude's shared prompt history; project files and worktrees; anything already sent to Anthropic). A blocked delete adds its note in the failure text. |
| Rows | **Sidebar rows** are 28 pt, radius 8, 8 inside the list. A row holds the status slot (12), the harness's mark (12), the title (13; medium when selected) and the time in mono 11 tertiary. **Activity cards** are §2's, radius 10.<br><br>**A project head** is 28 pt: the mark (16), the name (12.5 medium, primary) and the attention dot. Its chevron, `+` and ⋯ show on hover. While its page is open, the head takes the neutral selected fill (D-76).<br><br>**Subagents branch from their session** (§4).<br><br>**Home's rows and the inspector's lists** are hairline rows inside a card. A row's actions appear on hover and on keyboard focus, because the whole row already acts; they stay accessibility actions at all times. |
| Motion | **Persistent motion** is only a gated layer animation: the working spinner (12 frames a second, §4) and the art (§17).<br><br>**One-shot transitions:**<br>- hover and selection: 120 ms;<br>- a menu or the palette: 160 ms, opacity and a 3 pt rise;<br>- closing: instant;<br>- banners: 200 ms.<br><br>Above the terminal, transitions change opacity only, because a height change would resize the PTY every frame.<br><br>**Never:** glow, pulse, breathing, motion inside the terminal, or motion behind text being read.<br><br>**Under Reduce Motion,** transitions are instant. The spinner keeps moving (D-12), and so does the art while Settings → Theme → Animated art is on, the default; off, the art stands still (D-79, §17). |
| Art | The sharks (rule 6, §17). |
| Status language | §4. No status words on rows; they are in the accessibility label only. |
| Terminal framing | **Dark in both appearances.** The terminal face is dark in both appearances: Claude's and Codex's TUIs choose their colours for a dark background, and Sphyrna never writes their configuration.<br><br>**What is drawn in Ink.** A live terminal, the kept screen of an ended run and the development terminal are drawn in Ink's appearance (`DetailRoute.drawsDark`). This covers the whole pane, with its header, tab row, banners and inspector. Menus the system draws inside that pane follow the window's appearance.<br><br>**Flush on the canvas** (A6). There is no panel inset, no border and no second background. The terminal's text keeps a 16 pt inset (20 at the leading edge), and its background is Ink's canvas, so the CLI and the window read as one surface.<br><br>**Colours:** ANSI 16 = VS Code Dark+, the xterm 256 cube, a steady block cursor.<br><br>**What follows the appearance:** the Chat face, the record, Home, a draft and a project page. |
| Accessibility | **Increase Contrast:**<br>- raises the hairline to white 30 % (ink 45 % in Paper);<br>- raises secondary text to Ink `#BDBDC6` and Paper `#47454B` (at least 7:1), and tertiary takes secondary's normal value;<br>- makes the focus ring 2.5 pt (`LoomTheme.ContrastStyle`).<br><br>**On the pill,** Increase Contrast draws the hairline on hover and press too, and the fill at 0.75. A keyboard-focused row's focus ring sits on the pill's edge.<br><br>**Hit areas:** clickable controls answer over at least 24×24 pt even when drawn smaller.<br><br>**Labels and traits:**<br>- headings carry the header trait;<br>- a project's name is a button that opens its page, and its chevron carries the expanded or collapsed value;<br>- the Home row reads "Home, N sessions need you";<br>- the marks and the art are hidden from accessibility.<br><br>**Requests:** Return never approves a request while a live terminal is shown below it; Approve stays one click away. |
| Sound | None. |

**Before review,** every new surface is checked against this section:
- theme tokens only;
- status through the status column's marks;
- copy in this voice;
- persistent animation only as a gated layer animation;
- Reduce Transparency and Reduce Motion handled;
- text at the contrast tier for its role;
- nothing boxed twice.

## 7. Chat view (V13)

The stream of a Claude session read as chat (`Sources/LoomCatalogUI/Chat/`; the spec is `plans/v2/CHAT-SPEC.md`). It is drawn by `ChatTranscriptView`, read only for a stopped session and a live tail for a running terminal one. Values live in `LoomTheme+Chat.swift` (`LoomTheme.Chat`); the rules below are the ones a change must keep. Rules marked T3 follow T3 Code (MIT, Copyright 2026 T3 Tools Inc.); no T3 code is copied. Its Ink look is [the reference](reference.html#session)'s, accepted on 20 Oct 2026 (D-75); the code takes it in the chat's build step (V2-PLAN §13, I6). The rules below hold the behaviour and the look.

| Item | Rule |
| --- | --- |
| Column | 700 pt reading column centred in the pane, at least 32 pt from each side |
| Messages | Claude's prose reads on the canvas in reading type (§3), with no bubble. Your message is the only bubble: right-aligned, at most 80 % of the column and 560 wide, padded 9×14, radius 12, on the bubble fill (white 7 % in Ink, ink 6 % in Paper), with no edge. Over 600 characters or 8 lines it collapses to about 7 lines with "Show Full Message". One line under it, in 11.5 tertiary, says what happened to it (§11 Delivery); its hover footer holds Copy, the time and Rewind Files (§14). An automatic turn (a background task ended) is a quiet row, never a message from you |
| Rows | One row per message, work step, group, fold, marker or card; a row's id is stable (entry id, or `fold:`, `group:`, `live:`, `changes:` plus the turn or first tool), so only changed rows redraw. Work rows are 26 pt high, 16 pt indent per level |
| Work rows | One quiet line per step: the icon, the verb in 12.5 secondary, its subject (a path, a command, a query) in mono 12, the counts in the success and failure hues, and the time on hover. A click opens its body in place: a command's output, an edit's diff up to about 200 lines and then "Open in Changes", a search's results; the text can be selected. A step that Ask refused says so in the quiet voice: a refusal is not a failure |
| Failure | Failure is loud and success is quiet. A failed command opens by itself with its exit code and its last lines (up to 12), its body edged in the failure colour at 36 %; a passing one takes no colour |
| Turn fold [T3] | A settled turn's work between your message and the final answer folds into one row, "Worked for 4m 12s · changed 5 files and ran 3 commands". It never folds while the turn is live, failed or interrupted, or when nothing is left to fold; plan cards and dividers stay visible. A new turn closes the previous turn's opened fold. Your own messages inside a folded turn stay visible too. The fold is one 28 pt line in tertiary, with the duration in mono; opened, its steps hang on a tree guide. A stopped turn gets a neutral divider instead ("You stopped after 1m 4s") |
| Group summary [T3] | Two or more tools in a row are one line that names the two best kinds by (rank, first appearance) and counts the rest ("Changed 3 files, ran 2 commands and 4 other actions"); the latest tool decides its state. TodoWrite is never a row. Work that never finished in a settled turn reads as stopped. Opened, its steps branch from its icon on lines of the tree colour, as subagents branch in the sidebar (§4) |
| Live row | The one row at the end of a running turn, 28 pt: the working spinner, what Claude does now ("Editing" with the path in mono), and the clock from your send in mono tertiary (1 s, only while visible). It says "No activity for Ns" after 40 s, and "Waiting for you" in the attention text while a request waits. In Normal, Claude's latest thought sits above it in italics (12.5 / 19, tertiary, cut after 4 lines). Trailing tools of a live turn collapse into it |
| Markers | A centred label in mono 11 tertiary between two hairlines, 28 pt above and below, for what Sphyrna or the CLI did to the session: "Session started · Opus 5.5 · high · Ask before edits · main", "Context compacted · 180k → 42k tokens", "Mode changed to Ask" (in Sphyrna's mode names), "Continued in Terminal", and the rewind marker (§14) |
| Views | Normal (the latest thought above the live row), Thinking (each thinking block where it happened, folded under ✻, the CLI's mark), Verbose (also opens every fold and group); ⌃O cycles them, the chip at the top right shows the view, compact (the glyph and ⌃O) when the stream is under 700 wide, and not drawn when it is under 90 pt high (`viewChipMinimumStreamHeight`: a card, the banner and the composer leave it a sliver). The view, open folds and the reader's place are kept per session for the last 64 sessions. ⌃O works only while the stream has focus, so a terminal beside it keeps the key |
| Content | Markdown without a dependency: a small block parser (paragraph, heading, list, quote, code, table, rule; nesting capped at 8; blocks 12 pt apart) and `AttributedString(markdown:)` for inline text. Only http, https and mailto links open. Tables scroll sideways, and quotes take a 2 pt rule. Code blocks are cards (raised 1, radius 8, a hairline) in code type (§3), with the language, a wrap toggle and Copy ("Copied" for 1.2 s) in their header; syntax colours (VS Code Dark+; in Light a Light+-based set, a step deeper where a Light+ colour fell under 4.5:1 on a card) only for finished blocks of up to 20,000 characters; tool output over 16 lines scrolls; "Show All" reads the whole result from the transcript. "Show All" shows at most 1 MiB or 10,000 lines of a result, with a note where it was cut |
| Subagent card | A card on raised 1 (radius 12, a hairline): the status mark, the agent's type, its task, its newest words and the clock, then "Open in Agents" (§4). A live one never folds |
| Changed-files card | A card like the subagent card, with "Open in Changes" (§13) in its header, under the final answer of a turn that edited files: "N files changed +A −R" from the edit records (no git), a tree with single-child folders merged and paths relative to the working folder. A zero count is left out, so a record without counts shows none. Counts use the success colour, never a status colour. It also shows for an interrupted turn that edited files |
| Scroll latch [T3] | Following keeps the end in view; Free leaves the view where the reader put it. The distance is measured from the true content bottom with the bottom inset taken off; within 40 pt of it the view follows again. Wheel up, scroller drag and ↑, Page Up, Home leave Following; programmatic scrolls never change the state. "Jump to Latest", a pill on the popover level above the composer, appears 150 ms after leaving the end and hides at once on return. Older turns load when the top is within one viewport and the top row holds its place. A message you just sent is held 24 pt from the top until the turn's first activity |
| Motion | New rows fade in over 150 ms; none under Reduce Motion. The clock and the spinner run only while the window can be seen and a live row exists |
| Cost | Rows are virtualized (a view only for the rows near the viewport); heights are cached by row id and width; a delta applies at most about every 50 ms and redraws only the rows that changed; a hidden window or a closed view has no watcher and no timer |
| Top stack | The session's header, `Banners` and `DeletionBanner` are drawn above the stream, on the page's own fill (the stream's scroll view is laid over its neighbours and covered the header in the live chat before V19). The banners' look and order are §19's (D-79) |
| Copy | "session" in every user-visible string, never "conversation"; times and dates use the system locale and clock ("yesterday at 14:05"; `LoomDateFormat`, one place for every surface); percents are written "41%"; counts say what they count ("running", "sessions with usage") |

## 8. Draft session (V07)

A project's new-session page (`DraftSessionView`, `Sources/LoomCatalogUI/`; N1, [D-58, D-59](../DECISIONS.md)). Nothing runs until the first send. In Ink the page is the app's empty canvas, so it is where the art lives ([the reference](reference.html#project)): the faint grid, two hammerheads crossing slowly behind the question with a whale shark deep below (§17), and one lifted surface, the composer. `NewSessionLayout` holds its sizes.

| Item | Rule |
| --- | --- |
| Entry | The sidebar's "New session" row under Home (V19) opens it in the project of the most recently used session, read from the catalog when the row is clicked, so the project holds in the Projects view, with a search and after a relaunch; ⌘N on Home does the same, and elsewhere ⌘N opens the draft of the project on screen. The row is an action, never drawn selected, and off while Claude cannot be started. The page's project picker changes the project |
| Page | One question in display type (§3), "What should we work on in [project]?", where the project's name is the picker, underlined in its tone. Under it: the project's folder, branch and state in mono tertiary, the composer, the keys line, the branch strip and the presets. 720 pt column, 40 pt side inset, lifted 70 pt above the middle. One page per project |
| Composer | The shared composer (§11): a card on raised 2 (radius 18, with the composer's hairline ring and shadow) holding the text and the bar (Sphyrna reads no tracker key from the text, D-69): the mode chip, the one model chip (§11) and a round 30 pt Send. The pickers are §11's. On this page both harnesses' models are live, and the model picked decides the harness the session starts on (D-75); a build that cannot start Codex shows its group off, with "Codex comes in a later version". The model chip sits at the bar's trailing end before Send; its popover opens under it, aligned with its trailing edge so it stays put when the name changes; and Send's tooltip names the harness ("Start a Codex session") (D-76). The mode chip keeps Sphyrna's modes; Codex's own approval modes come with Codex's planning. The draft keeps its own lists: Claude's models are Opus, Sonnet and Haiku after Default, and the effort levels are the five the CLI takes. A mode pick adds "Use the default for this project" to its popover and an effort pick a reset to what the project starts with. Where "Sessions run in" is Terminal, Ask is disabled with "Chat only", and a picked, remembered or configured Ask starts as Ask before edits. Its text inset (16), its top (12) and the 8 pt gap between the chips of the branch strip are the live composer's tokens (`FixRoundLookTests`); only its minimum text height, 60, is its own |
| Keys | ↵ starts the session and shows it; ⌘↵ starts it in the background and leaves a fresh draft; ⇧↵ (and ⌥↵) a new line. ↵ never sends while an input method composes. A start that fails keeps every word. The keys line sits under the card, centred, in mono tertiary: "↵ start", "⌘↵ start in the background", "⇧↵ new line" (B3) |
| Branch strip | Stay on the current branch, New branch (in this folder) or New worktree (its own folder, `<repo>/.claude/worktrees/<slug>`); Git runs only at the first send, and only for the two new choices |
| Presets | A row of saved starts (name, message, mode, model); "Save as preset" appears once there is text |
| Remora's brief | (D-80; one of Remora's two doors beyond Home, §20.) With Remora on and once the project has a session, one quiet row sits under the presets: "Remora can write this session's brief from <project>'s recent work." and Draft Brief, a small secondary button. It is one call, on the click: the row says "Reading 3 sessions in <project> and its note…" with the spinner and Stop. The brief lands in the composer, unsent, in plain paragraphs: the goal, where it stands, the next step, the files, and what to watch for. A line above the composer says where it came from, "Remora's draft" and "from 3 sessions in <project> · not sent" in mono tertiary, with Sources and Clear; the row then says "Remora drafted the brief above. Nothing is sent until you press ↵." with the time and Draft Again. A composer that has text keeps it, and the brief is copied instead. Remora never sends it (D-64) |

## 9. Home (V05)

The launch view (`HomeView`, `Sources/LoomCatalogUI/`). `LoomTheme.Home` (`LoomTheme+Home.swift`) holds its sizes. It is a summary of what Sphyrna already knows, and it starts nothing by itself. In Ink it says the state in one sentence, then lists what wants you ([the reference](reference.html#home)). It has no start box: sessions start from the sidebar's "New session" row (§8).

The top band is Remora's (D-65; Lombot until D-77). Until Remora lands, the band holds:
- the date and time in mono tertiary;
- one sentence in statement type (§3), such as "Two sessions are working. One needs you.", where only "needs you" takes a colour, the attention text;
- a line of counts in secondary;
- one hammerhead behind it, at low contrast, circling the band on its fixed loop (§17, D-79).

In the morning, Remora's brief takes the band: the heading, Remora's sentence and a tile per project (R1–R9 in [the reference](reference.html#home), D-77, D-80). Its parts, its states and asking are §20.
- **Remora's place** (D-77). The sentence starts after a 136 pt column, where the remora rests, rising toward it (§17). The sentence keeps two lines' room, so nothing moves while it is written.
- **The arrival.** When Home opens with a new brief (the first Home of the day, and after Catch Me Up), the hammerhead swims in from the right through the brief before it is written, with the remora on its flank. At the brief's start the remora lets go and turns up to its place, and the hammerhead swims on, out to the left. It takes about 2.2 seconds. Any other time the remora is already in its place, still.
- **Reading and writing.** While Remora reads, the remora swims in place and the line says what it reads, with the working spinner ("Reading 6 sessions and 3 project notes…"). Then the sentence comes in word by word and the tiles one by one, and the remora holds still. During the arrival the band's own hammerhead is the one that carries the remora: the band's loop gives it up as the arrival starts, and about 1.2 seconds after it leaves at the left, it comes back in from the left along its loop's lower pass (D-80).
- **With Animated art off** (§17) there is no crossing: the remora fades in at its place. **Under Reduce Motion** the brief appears whole once it is read, and the crossing still plays while Animated art is on (D-79).
- **Later,** once one entry is picked up (its session ran since the brief), the brief folds: the remora's line ("Remora · morning brief 09:12 · 2 of 3 picked up", with Show Brief), one line per entry with a tick or a ring, and the field. The remora rests at the line's start, level, 72 long and in semibold glyphs, so that its disc shows (§17).

| Item | Rule |
| --- | --- |
| Column | At most 1,000 wide, 32 side inset. The band has 84 above the sentence and 34 below it; blocks are 14 apart. The canvas, no session header |
| Cards | Raised 1, radius 12 (`Radius.block`), a hairline edge and the card's depth. **List cards:** a 42 pt heading row (the 7 pt status dot in the attention or unviewed colour, the title in header type, the count in mono tertiary), then rows divided by a hairline, their text 16 from the card's edge, with the hover fill across the whole row. **Side cards:** 16 padded; the title in header type, and an optional right-hand note in mono tertiary |
| Two columns | From 820 of content width, the side column (316, 24 from the lists) sits beside the lists; below it, under them, with Continue first because it is the one block that asks for a click |
| Row | **One line:** the status mark, the title, the project's mark and name in mono tertiary, and the age in mono tertiary. **Under it:** the reason line in small secondary (two lines at most). **Actions:** Open Session (the accent button) and Mark as Read (a secondary button) appear at the trailing end on hover and keyboard focus (C3), and are accessibility actions at all times. A click anywhere on the row opens the session, as Open Session does; the row takes the hover fill |
| Empty states | Centred message with symbol, title and text. An empty catalog is Home's own state, with no start screen of its own: Add Project…, New Claude Session and New Codex Session (disabled, with "Codex comes in a later version" under it, in a build that cannot start Codex), while the sidebar says only "No projects yet.". The first-run message carries the app icon at 84 in place of a symbol, with the school behind it: the hammerhead comes in from the right, the whale shark keeps to the deep and remoras keep to the two, faint in the message's middle (§17, D-79). With no Claude CLI the attention triangle takes the icon's place, the title says what is missing, Check Again takes New Claude Session's place, and no shark swims. Over a catalog with sessions the no-Claude notice is a card under the band, with an attention-coloured symbol and Check Again; Plan limits is left out and the sidebar's New session row is off. While Check Again asks, it says "Checking…" with the spinner |
| Nothing waiting | The band's sentence says it: "One session is working. Nothing needs you.", or, with nothing working either, the menu bar's line, "Nothing is working or waiting.". The Needs you card stays, empty, with one line that says what appears there; it replaces the "Nothing needs you" card (D-79) |
| Usage | Two side cards, as in the reference; a card with nothing to say is left out. "Plan limits" (`HomePlanLimits`, `home-limits`): the heading with "updated HH:MM" at its right, then one `PlanPaceLine` per window: the name in bold and "N% left", the meter, and "Resets … · at this pace it lasts" (or when it runs out) in caption, which takes a second line rather than being cut. No button and no popover (fix round 3, I: V25 had folded the meters into a popover behind one line). VoiceOver reads the card as one element, "Plan limits, 5-hour window 62% left, Weekly 74% left, on pace"; the tooltip carries each window's sentence. Meters: §3. When Claude answered without limits the card says "Claude did not report plan limits, so Sphyrna shows none.". "Today" (`home-usage`): one Today line, "16.1K tokens · 2 sessions · 40% from cache", the figures semibold primary and the labels secondary, a column when the card is narrow; its tooltip gives today's tokens by kind. While the usage index reads for the first time a note stands in place of the tokens |
| Continue | Each card says "Last active <age> ago": the session's last use, capped at the run's recorded end and never before the run began. The 7-day window uses the same time. After a quit that cut sessions short, Continue comes first: its lead line, then each session with Resume on hover, and "Show N More" after the fifth (D-79) |

## 10. Project page (V08)

A project's page (`ProjectPageView`, `Sources/LoomCatalogUI/`). Tokens are `LoomTheme.ProjectPage` (`LoomTheme+ProjectPage.swift`). Its Ink look is [the reference](reference.html#project)'s, accepted on 20 Oct 2026 (D-76; A1–A8 and C1–C4 there); the code takes it in the build's pages step (V2-PLAN §13, I4). The page shows what Sphyrna already holds and starts nothing by itself: it reads the catalog, the usage index, the git files and CLAUDE.md once per visit, and lets them go when it closes.

| Item | Rule |
| --- | --- |
| Page | A column of at most 1,000 on the canvas, 32 side inset (20 below 760 of pane width) and 32 below. Two columns from 760 |
| Head | (A1, D-76.) The head sits on the window's 52 pt header line, where a session's title would be, with no bar and no stripe of its own: the project's mark (26), the name in title type (§3) and the folder in mono 12 tertiary, which can be selected. At the trailing edge, 8 apart: ⋯, an icon button that opens the project menu (below), and New session, the page's main action (30) with the compose glyph |
| Stats | (A2.) One line right under the head, in 12 secondary with the figures semibold primary: "3 running · 9 sessions · 3.1M tokens, past 7 days" and the branch glyph with the branch in mono 11.5. Nothing is counted when there is nothing to count: no "running" without a run, no tokens without usage, no branch outside Git |
| Tabs | (A3.) View tabs (§6 Tabs) on a 36 pt bar with a hairline, 14 below the stats: Sessions, Branches and Instructions, with their counts. The page opens on Sessions every time |
| Session row | (A4.) It reads like the sidebar's row: the status slot, the harness's mark (12), the title in 13 medium and its last line in 12 secondary (one line each; a command or a path in mono), the branch in mono 11.5 (170 wide) and the time in mono 11.5 tertiary (44 wide, trailing). The last line is the reason Sphyrna holds ("Allow: <command>", "Asks: <header>", "Plan ready for review", "Failed: <cause>"), else the first line of the transcript's end. Rows lie flat on the canvas between hairlines, with the pill on hover and press (radius 8, 12×8 inside, 2 inside the hairlines). A stale session's title is secondary. The branch drops when the row is under 460 and outside Git; the time keeps its column. A click shows the session |
| Side cards | (A5, A6.) Presets and Past 7 days are the only lifted parts: raised 1, radius 12, a hairline edge, 16 padded, the title in header type with an optional note in mono tertiary ("this project"). They sit in a 300 column, 20 from the list; under 760, Presets goes above the list and Past 7 days below it (C1) |
| Presets | A row is 28 high with the pill (radius 8, reaching the card's padding): the mode's icon in its tone (§3 Mode tones), the name, an "all" tag in mono for a preset every project shares, and the model in mono 11 tertiary after its harness's mark (12). The message is in the tooltip. A click opens the project's new-session page with the preset in it and starts nothing; the context menu removes it. Empty: "Save a first message as a preset from a new session, and it shows up here." |
| Past 7 days | Three figures in 18 semibold with tabular digits, each over a label in 11.5 secondary: tokens, sessions with usage, and the estimate. Its states are one line in 12 secondary: "Reading usage…", "Could not read this project's usage." and "No usage in the past 7 days." |
| Empty project | (C3.) The list's place holds a small hammerhead swimming in place (§17) over one line in 12.5 secondary: "No sessions in this project yet. New session starts one." |
| Branches | A column of at most 700. Rows are 34 high between hairlines: the branch glyph, the name in mono 12.5 (secondary; primary for the current one, which has an accent-high "current" label), "worktree" and its folder in mono for a branch another worktree has checked out, then the count of listed sessions on it and the time in mono tertiary. A capped list says "Only the first N branches are listed."; a folder outside Git says "This folder is not in a Git repository, or its branches could not be read." |
| Instructions | A column of at most 700. A 30 pt line holds the book glyph, `CLAUDE.md` in mono 12.5, its lines (or size) and age in 11.5 tertiary, and **Open in Editor** at the trailing end (D-76). Under it, CLAUDE.md in a card (raised 1, radius 12, 18×22 inside), rendered with the chat's Markdown at reading size, the first 32 KB, with "Showing the first X of Y. Open the file to read the rest." when cut. No file: "This project has no CLAUDE.md. Claude reads one from the project folder when it starts a session there." |
| Project menu | (A8.) ⋯ opens the sidebar's project menu: New Claude Session and New Codex Session with their harness's marks (14; Codex off with "Codex comes in a later version" in a build that cannot start it), Color with the tone's name over a row of seven swatches (the six tones and None, the current one ringed), Move Up and Move Down, and Remove Empty Project, which only an empty project allows |
| Sidebar | (A7, C4.) While its page is open, the project's head takes the neutral selected fill; the tint stays for a selected session. An empty project says "No sessions" under its head |

## 11. Chat composer (V17, V24)

One composer for the draft session and the live session (`ChatComposerView`, `ChatComposerDock`, `ComposerTextEditor` in `Sources/LoomCatalogUI/Chat/`; tokens in `LoomTheme+Composer.swift`; spec CHAT-SPEC → Composer; [D-58, D-59, D-62, D-63](../DECISIONS.md)); the chip and picker code is `ComposerPickers.swift`.

| Item | Rule |
| --- | --- |
| Dock | The draft's card (§8), docked: raised 2, radius 18. Top to bottom: the queue strip (a drawer tucked behind the card's top edge, on raised 1 with radius 12 at its top), the attachment row, the text (two lines at least, one while compact), a notice line and the 38 pt bar, with the keys line under the card in mono tertiary (a narrow window keeps its first three hints). Typed text is `LoomTheme.TypeScale.reading` in `LoomTheme.Text.primary`, 16 from the card's sides and 12 below its top; inside a chip its parts are 8 apart |
| Bar | `+` (attach, `@` mention, `/` commands), the mode chip (the mode's icon and name in its tone, §6), the context ring, the model chip and Send.<br>**The model chip** (D-75) is one target: the harness's mark (13), the model, the effort as a lighter word and a chevron, opening one popover (Pickers). The model name reads the resolved name, else "Default model", and shows a live change at once; a model with no effort setting shows no effort word.<br>**Send** says what Return does: the round arrow for a plain send, off with no text. While Claude works it is Interrupt with no text (a circle in primary with a square), "Send Now" with text, and "After this turn" while ⌘ is held. It reads "Update" while a queued message is edited, and "Resume" while the queue is paused and the field is empty. The words are accent capsules. Send is off while a card waits, because the card's buttons take the text |
| Modes | The menus offer Ask, Ask before edits, Accept edits, Auto and Full access, each with its icon, tone and a one-line explanation (D-63; "Claude's default" is gone). A new session starts in the mode Settings → General → "Mode of new sessions" names (D-69): "Last used in the project" (the default: the project's last used mode, else Ask before edits) or one fixed mode; a draft pick beats both, and the mode is passed to the CLI explicitly. Full access can be the fixed mode because the user picks it there, after a confirmation in Settings; Sphyrna never picks it by itself, and a Full access pick in a draft is never kept as the project's last used mode. Ask is Chat only: where "Sessions run in" is Terminal, the draft shows it disabled with "Chat only", and an Ask default starts as Ask before edits. Picking Ask while a tool approval waits is refused with "Answer the waiting request first." |
| Pickers | The mode chip and the model chip each open one popover. The lists share one pick list: rows that draw the pill (radius 8, 6 inside the popover's edge) under the pointer or ↑ ↓, ↵ to choose, a check mark on the chosen one; a disabled row shows no pill.<br>**The model popover** (D-75), 332 wide, lists the models grouped by harness, the session's own first. A group's heading carries the mark, the harness's name ("Claude Code", "Codex") and a note in mono ("this session", "in a new session"). A row is 30 high: the model's name (13 medium), a one-line note in tertiary and the check. Claude Code's group lists Default (Recommended), then the CLI's models, or Opus, Sonnet and Haiku when the CLI lists none. A session keeps its harness, so the other harness's models show dimmed and cannot be picked; on the new-session page both groups are live (§8).<br>**The effort** sits under the list: its name, a segmented track with a thumb (click, drag or ← →) and Reset. The levels are the picked model's own (Claude Code's five, low to max; Codex's six, none to max), and a model with none says "This model has no effort setting." in place of the track. The reset goes back to the effort the session opened with, or to Default. A model that lacks the chosen effort takes the nearest level below it, or its lowest.<br>**Keys:** ↑ ↓ move between models, ← → change the effort, ↵ picks the highlighted model and closes. A pick applies at once, and a click on a model leaves the popover open for the effort |
| Compact | While a card waits, the composer is one line and the bar, the card's note takes one line and the keys line goes (each note fits the narrowest composer: "If you deny, Claude gets this as your note.", "Claude gets this as your own answer.", "If you keep planning, Claude gets this as feedback."; `ReleaseBReviewTests`), so the card's buttons stay on screen in a short window; the pinned stack may then take more of the pane (§12) |
| Handover | No menu moves a session between faces: the face is Settings → General → "Sessions run in" (D-69). The policy banner's "Switch to Terminal" is the one move: it sets that switch to Terminal and moves this session. While that handover is in progress the composer says "Moving to the terminal…" above the bar, and Send is off (an interrupt stays); text typed meanwhile stays in the field |
| Stopped session | A stopped Chat session keeps its composer; a send resumes it in Chat |
| Keys | ↵ sends; while Claude works it sends `next`, read after the current step. ⌘↵ puts the message in Sphyrna's queue while Claude works. Esc closes a menu, else interrupts a working turn, and never loses text. With a card shown, ↵ and ⌘↵ send nothing and Esc only closes a menu (§12). ⇧⌘A, ⇧⌘M and ⇧⌘K open the attach, mention and command menus; ⇧⌘V pastes plain text |
| Delivery | Your rows read Queued ("Waiting for the current step" with Read Now, only when a turn was running at send time), Read, Cancelled, or Not delivered with Retry and Copy |
| Queue strip | Edit, drag or ⌥↑/⌥↓ to reorder, Send Now, Remove; Resume and Clear when paused; the queue's issue line |
| Menus | `/` (only at the start of a message) and `@` open above the card, up to 80 rows, the cursor row drawn with the pill (radius 8, 6 inside the menu's edge); terminal-only commands are dimmed. `@` never walks the home folder, `/`, an ancestor of home or a volume root. It scans the session's folder (up to 20,000 entries) and builds the session rows when it opens, ranks them as the user types, and lets both go when it closes |
| Attachments | Images are scaled to 2000 px at most, and files over 40 MB are refused; a paste of 32 KiB or more becomes a chip; ⌘↵ queues text only |
| Drafts | Per session, never lost: an interrupt or the end of a run hands unread messages back in front of the typed text |
| Edit menu | Undo, Redo and Cut work in the composer |

## 12. Pinned cards (V18, V19)

A live Chat session's requests (approvals, questions, plans) as one card at a time between the stream and the composer (`PinnedCards.swift`, `PinnedCardParts.swift`, `PinnedCardsModel.swift`, `PinnedApprovalContent.swift`, `PinnedKeys.swift` in `Sources/LoomCatalogUI/Chat/`; tokens in `LoomTheme+Pinned.swift`; spec CHAT-SPEC → Requests).

| Item | Rule |
| --- | --- |
| Stack | One card with a counter ("1 of 3") when several wait, in order of arrival, at most 0.55 of the pane's height (0.68 while the composer is compact); a subagent's request names the subagent. A card is padded 16, its sections are 12 apart and its buttons 8 apart |
| Look | (E1–E3 in [the reference](reference.html#session), D-75.) The card is on raised 2 with radius 12, a 1 pt attention edge at 34 % and the attention dot before its heading: the request in Sphyrna's words, the kind in mono and "1 of 3". The card itself stays neutral, with no wash, so code and options read on it; this is where a pinned card differs from a §6 callout. A command shows in mono, five lines before it scrolls, then Claude's own words on why it asks. Submit and Approve take the accent because they are the way forward, but Return never presses them; Deny and Stop waits behind ⋯ |
| Answers | Approvals: Allow Once, Allow for This Session (the CLI's own rule, or a rule that names the whole tool; not offered for a command that writes to a file), Deny, and ⋯ Deny and Stop. Questions: options by click or digit, Submit. Plans: Approve with a build mode (Ask before edits preselected, Accept edits, Auto) or Keep Planning |
| Composer text | The composer's text is the deny note, a question's own answer and the plan feedback; a line above the composer says so while a card waits. Typing clears a question's picks and picking clears the text |
| Keys | No default button: ↵ never approves and Esc never denies. Tab and Shift-Tab move between the composer and the card; ← and → move the ring, which starts on no button; Space presses; digits pick a question's options |
| Typing guard | A card that arrives within 1.5 s of typing waits as "1 request waiting" until a pause, leaving the composer or a send; it never takes the composer's text or focus |
| Afterwards | The card folds to one line for 4 s; the stream keeps one line per request ("Allowed once: …", "Denied: … · note", "Cancelled: …") |
| Cut off | A card whose process ended stays, disabled, with "Claude stopped before you answered" and Resume; messages Claude never read show as "Not delivered: N messages" with Copy |
| Banner | One banner between the stream and the cards carries the live chat's policy signal (with Switch to Terminal, which sets Settings' switch to Terminal and moves the session), wire drift and unknown records, the first one with "+N" for the rest and a dismiss button; it replaces the notices that lay over the stream. It never covers a card |
| Short windows | The plan's text gives way so its buttons stay on screen, and the compact composer (§11) leaves room: at 780×500 the banner, a card's buttons and the composer are all visible. The view chip drops out of a stream too short for it (§7) |

## 13. Changes tab (V20)

The inspector's third tab (`ChangesTab.swift`, `ChangesDiffViews.swift`, `ChangesState.swift`, `CatalogModel+Changes.swift`; tokens `LoomTheme.Changes` in `LoomTheme+Changes.swift`). It shows what changed, in the session's own terms, with line comments that go back to Claude as one message. It is read only: no staging, no committing, no editing in Sphyrna. Its Ink look is [the reference](reference.html#review)'s (D-78).

| Item | Rule |
| --- | --- |
| Tab | Third in the bar: "Changes", a view tab (§6 Tabs). Its count, in mono tertiary, is the number of files in the current scope once that scope was read, else none. It widens the inspector to 556 (`Rhythm.inspectorWidthReview`); the other tabs keep 328. The width changes only on the user's tab switch (or the card's "Open in Changes") and never animates. The overlay rule is unchanged and takes the open tab's width: a pane that would keep under 480 pt beside 556 gets the inspector drawn over it, no wider than the pane |
| Scopes | A segmented control: Last turn, Whole session, Branch. **Last turn** is everything after the newest user prompt (typed, or sent by Sphyrna), up to now; **Whole session** is every edit the read reaches. Both show Claude's own file edits (the successful Write, Edit, MultiEdit and NotebookEdit calls of the main session) from their `structuredPatch`; a created file shows its content as added lines; a notebook cell shows its new source as added lines with no line numbers. Under them one quiet line: "Claude's file edits. Shell commands and subagents show under Branch." **Branch** is git: the working tree against the merge base with the base branch (`origin/HEAD`'s target, else a local `main`, else `master`), uncommitted changes and untracked files that are not ignored included. On the base branch itself it shows the uncommitted changes and says so ("You are on main. Showing the uncommitted changes."). No base branch: the scope is off, "No base branch found". Outside Git: off, "Not a Git repository". A scope that does not apply to the session (a Codex session's edits) is off with its reason |
| Reads | Only while the tab is open on the session, and never on a timer: when the tab opens, when a turn ends while it is open, and when the scope changes (one scope at a time). The turn scopes read the main transcript on disk, backward from its end, at most 64 MiB; beyond that the tab says "Older edits were not read" and shows what it has. Branch asks git for the file list (10 s), and for one file's diff when that file is shown (15 s). A file whose diff is over 1 MiB or 2,000 lines shows "Too large to show here" with Open in Editor. A timeout shows "Git did not answer" with Try Again, an error its own words; a read never spins forever and never crashes the tab |
| File list | Folders first, single-child folders merged, as the changed-files card draws them; each file with the card's status letter (M, A, D, R) and a rename with its old path ("old → new"); +/− counts and "· N comments" per file; the first file is open at first; a list taller than six rows scrolls inside itself. Each file has "Open in Editor" (the app macOS opens it with); there is no "Open all" |
| Diff | The open file's unified diff in a code card (raised 1, radius 8): a header (path, Open in Editor), an old and a new line-number column, a sign column, and the text; a changed line is a band of the success or failure hue at 8 % opacity (a diff is content, §3; 8 % is the most the numbers' 4.5:1 allows on the Light inspector). Hunks follow each other with a header line. Primary text holds 7:1 and the numbers 4.5:1 on every band, in both looks and every tone (`ChangesInspectorTests`). The line numbers are tertiary. A long line wraps; nothing is cut |
| Comments | A "+" appears in the gutter of the line under the pointer; it or a click on the line opens a box under it, "Your comment · line N", with the accent wash. A comment is anchored to the file, the line (the new side's number, the old side's for a removed line) and the line's text. A saved comment shows under its line with Edit and Remove; a comment whose line left the diff after a re-read stays and is drawn after the lines. Drafts live in memory, per session and per scope, in `ChangesState` on `CatalogModel`; they are not kept across a relaunch (nothing in the UI says so) |
| Footer | While the scope has comments: "N comments in M files", Discard, and Send to Claude. The message is one plain text: "Comments on the changes (Last turn):" (or "Whole session", "Branch vs main"), then for each comment `path:line`, the line quoted after "> ", and the comment, blocks separated by a blank line; comments read by file as the list shows them, then by line. It goes the way the composer's Return goes on that session: sent as `next` to a live Chat session, or resuming a stopped Chat session and sending. A terminal-face session shows the diffs but Send is off, with "Comments go to Claude in a Chat session". After a send that was accepted the comments clear; a refused one keeps them and says why |
| Card | The changed-files card under a turn's answer has a small "Open in Changes": it opens the inspector on this tab, on Last turn when the card is the newest turn's, else on Whole session |
| Empty and waiting | An empty scope says so in one sentence, over a small thresher swimming in place: "Claude has not edited files in the last turn.", "Claude has not edited files in this session.", and for Branch "No changes against main." (the base's name), or "No uncommitted changes." on the base branch itself. The quiet line above says what was read. While git reads, a small hammerhead swims in place over "Reading the branch…", with the command and its time in mono (§17). A scope that is off says its reason, with no shark |

## 14. Rewind files (V21)

"Rewind Files to Before This Message" on one of your messages in a live Chat session (`ChatRewindAction.swift`, `RewindSheetState.swift`, `RewindSheetView.swift` in `Sources/LoomCatalogUI/Chat/`, `CatalogModel+Rewind.swift`; tokens `LoomTheme.Rewind` in `Chat/LoomTheme+Rewind.swift`; the driver in LoomChat, `ChatSessionDriver+Rewind.swift`). The CLI restores only the files Claude's own Write, Edit and NotebookEdit calls touched (S8), so the wording and the sheet say exactly that, and Sphyrna keeps its own copy of the listed files first and offers Undo from it.

| Item | Rule |
| --- | --- |
| Action | In the hover footer of a user row, after Copy: arrow glyph and "Rewind Files to Before This Message" (11.5 pt, secondary). Only on a prompt Claude read that has a message uuid, typed or sent by Sphyrna: never on a task notification, a meta record, Sphyrna's own marker rows, a subagent's brief, or a message not delivered. Not drawn at all where no live chat stands behind the stream (the terminal face, a transcript) |
| When it is on | One rule: the session is live and at its prompt (phase `ready`, no turn running, no request waiting, no handover, no rewind under way). Otherwise it is drawn dimmed and disabled, and its tooltip says why: "Rewind works while the session waits for you"; a stopped session says "Resume the session to rewind its files". A rewind never resumes a session |
| Sheet | A sheet on the window (`RewindSheetView`, 480 wide): title "Rewind files to before this message?", the message's first words in quotes, then the dry run: "N files" and the totals "+A −R" (the CLI gives totals, not counts per file), the paths relative to the working folder in 12 pt mono (a list of more than six scrolls inside its box), the honest label, and, when the message is the newest turn's, "This turn's file changes can only come back through Undo." in the attention colour |
| Label | "Restores the files Claude changed with its file tools to how they were before this message. Changes made by shell commands and subagents stay. Sphyrna keeps a copy of these files, so you can undo this." |
| Marks | A file the user may have changed outside Claude is marked under its path in the attention colour (caption), so the path is never cut: "Changed since Claude's last edit" (modified more than 2 s after Claude's last edit record of it, from V20's scan of the whole session), "Deleted since Claude's last edit" (the rewind would bring it back), "Could not check" (no record inside the scan's bound). The marks warn; the safety is the copy |
| Cannot | The dry run's refusals read "No file checkpoint for this message" (sent before checkpointing was on, or from the terminal face) and "File rewinding is off for this run", in the failure colour, with Cancel only |
| Copy limit | The copy keeps at most 64 MiB per file and 256 MiB per rewind. Over either, or for a file that is not a regular file, the sheet says "These files are too large to keep a copy for Undo" (or "Sphyrna cannot keep a copy of some of these files, so it does not rewind them") and Rewind is off: Sphyrna never rewinds without its copy. The copy lives only while its Undo is offered: it is deleted when Undo closes (a message is sent, a newer rewind comes, or Undo is used), so a session holds the copies of at most one rewind, usually none (D-72) |
| Buttons and keys | Cancel (Esc; it has the focus when the sheet opens) and "Rewind Files", tinted in the accent: no filled button, since Return does nothing (§6 Sheets, D-78). No default button: Return does nothing (`RewindSheetKeys`). Cancel is disabled while the rewind runs |
| Marker | After the rewind the stream gets a Sphyrna-only marker at the end of the stream: "Files rewound to before “fix the login…” · 14:02" (the message's first six words), with a quiet "Undo" link while it is the session's newest rewind and no message was sent since. After Undo it reads "Rewind undone". A rewind Claude never answered (a timeout, the process ended) leaves the marker too, with Undo, since the files may have changed; the sheet says so. A relaunch keeps neither the marker nor the copies (Sphyrna removes them at launch), so Undo is not offered after one; a stopped session keeps its open Undo and its copies for as long as Sphyrna runs |
| Undo | Puts every copied file back (written atomically) and moves a file that did not exist before the rewind to the Trash, never a plain delete. Files changed since the rewind are named first, in an alert ("Undo the rewind?" with "Overwrite and Undo"); Undo never overwrites silently |
| Journal | `chat.rewound` records counts only (files, insertions, deletions); `chat.rewind_undone` the counts restored and trashed |

## 15. Quick question (V22)

⌘; opens a small panel over a live Chat session; you ask a one-shot question and Claude answers from the session's context through the CLI's `side_question` control request (`QuickQuestionPanelView.swift` in `Sources/LoomCatalogUI/Chat/`, the holder in `CatalogModel+QuickQuestion.swift`, tokens `LoomTheme.QuickQuestion` in `Chat/LoomTheme+QuickQuestion.swift`; the driver in LoomChat, `ChatSessionDriver+Side.swift`). Nothing reaches the session's transcript, history, queue or usage: the CLI writes no record for it (S6 Q3).

| Item | Rule |
| --- | --- |
| Where it works | A running Chat-face session only: while it is ready, working or waiting for you. Not while it starts, stops or is stopped, not while a handover to the terminal holds it. A terminal-face session has its own `/btw` that Sphyrna cannot reach, so there is no fallback. A stopped session is never resumed for a question |
| Entry points | File → "Ask a Quick Question…" (⌘;) and the palette's "Ask a quick question" (listed only while it applies, so it is reachable on layouts where ";" needs Shift). The menu item is greyed with its reason under it: "Quick questions need a running Chat session" (a starting, stopping or moving session says that instead) |
| Card | A floating card over the bottom of the chat column, above the composer and at the composer's width (`Composer.column` less the dock's side inset), on the popover level, with its hairline ring and shadow. It is not a sheet or a window; the stream behind it stays live. A small close button sits at its top right |
| Field | Placeholder "Ask a quick question"; focused when the panel opens, also when the main composer had the keyboard, so a question never goes to the session with Return (⌘; again gives an open panel the keyboard). Return asks, Shift-Return (or Option-Return) makes a new line, Esc closes the panel (`ComposerKeys.Mode.quick`, matched by key code like the composer's keys). No key asks while an input method composes, or while one question waits |
| Waiting | A quiet "Thinking · 3 s" line under the question, from Sphyrna's own one-second `TimelineView` that exists only while the question waits (the CLI reports a single "started"). Text 12 pt, secondary |
| Answer | Under the question (12.5 pt, medium, secondary), through the same Markdown renderer as an assistant message (`ChatMarkdownView`, reading size), in a scroll area of at most 240 pt, with "Copy" below. The field clears for the next question; the panel shows the last question and answer only |
| Hint | Under the field, quiet: "Claude answers from this session's context. The session never sees the question." (11.5 pt, secondary) |
| One at a time | While a question waits, Return does nothing; what you type meanwhile stays in the field |
| Errors | One quiet line above the field, and the question comes back to the field (unless you typed something else meanwhile): "No answer came back. Try again." after 120 s; "This Claude version has no quick questions" when the CLI answers "Unsupported control request subtype"; otherwise the CLI's own message |
| Closing | Esc, the close button, or the session no longer taking questions (it stops, leaves the Chat face, a handover begins). Closing drops the question and the answer, and a late answer is discarded. Nothing is kept: the answer lives in memory until the panel closes |
| Contrast | Primary text 7:1 and secondary 4.5:1 on the card's surface, in both appearances and every tone (`QuickQuestionThemeTests`); the placeholder is the popover's (`OnPopover.placeholder`). Every value is a `LoomTheme.QuickQuestion` token |
| Journal | `chat.sideQuestion` records the outcome (answered, timeout, unsupported, failed, cancelled, ended) and the latency in milliseconds, never the question or the answer |

## 16. Side tab (V22 part 3)

The inspector's fourth tab (`SideTab.swift`, `SideThread.swift`, `SideComposer.swift`, `CatalogModel+Side.swift`; tokens `LoomTheme.Side` in `LoomTheme+Side.swift`). A side chat is a fork of the session (the engine of part 2): it sees the session up to the moment of the fork, answers on the side, and the main session never sees it unless the user sends one answer back as a note. Its answers are drawn by the main chat's own renderer, so a side chat reads like the chat beside it.

| Item | Rule |
| --- | --- |
| Tab | Fourth in the bar: "Side", a view tab (§6 Tabs). Only on a Claude session that has a provider conversation id (a fork needs one), on either face; never on a Codex session or on a side chat. It widens the inspector to 392 (`Rhythm.inspectorWidthSide`); the overlay rule takes the open tab's width. A dot (the attention hue, `LoomTheme.Side.dot`) takes the slot of the count while one of the session's side chats waits for the user; it is the only sign: nothing outside the tab counts, lists, notifies or badges a waiting side chat |
| Empty | "Ask on the side. A side chat is a copy of this session: it sees the session up to now, and the main session never sees it.", over a small whale shark swimming in place (§17), and the composer. Nothing starts until the first question |
| Header | "Side chat", then "Forked at 14:05 · sees the session up to then · the main session never sees it" (the time alone on the day of the fork, else with the day), and a "+" ("New side chat") that opens a fresh empty side chat; the earlier ones stay. Under it, when the session has other side chats, "Earlier side chats · N", a menu of them newest first: the first line of the question and when it was forked |
| Thread | The main chat's stream over the fork's driver (`LiveChatFeed`, the same rows), cut at the fork's first question: the fork's file begins with a copy of the parent's records, and none of it is shown. It has no "Rewind Files", no composer-driven rows and no slash menu. A side chat that is stopped shows the same thread from its file; the next question resumes it |
| Composer | A compact field, "Ask on the side"; Return asks, Shift-Return makes a new line, Esc does nothing (`ComposerKeys.Mode.quick`). Text starting with "/" is refused before any fork exists (a side chat runs no commands): "Commands don't run in a side chat", and the text stays. The bar: Close, the session's model after its harness's mark (read only; the help says it is the same model so the cache is reused), "Allow edits", "…" (Discard Side Chat) and Send |
| Allow edits | Off for every side chat that starts or resumes. While on, the side chat may ask to change files or run commands, and each request asks the user first, in the tab, as a card with no "allow for session" choice. It belongs to the running process: Close, or any restart, turns it off. The toggle is disabled while the side chat is not running |
| Close | Stops the side chat's process and keeps its thread; the next question resumes it. Discard is the only way to delete one |
| Process | A side chat's process runs only while it is the open one in its session's tab (D-72). Opening another one or "New side chat" stops the one that was open (when a turn runs or a card waits, when that ends; if it is opened again before then, it stays), and so does the session's own Stop; a switch between the Chat face and the terminal does not. Its thread stays and the next question resumes it. Closing the inspector or selecting another session changes nothing |
| Send to Main as a Note | Under each finished side answer, with Copy. One plain message to the main session, sent the way the composer's Return goes (as `next` to a live Chat session, or resuming a stopped Chat session first): "A note from a side chat:", a blank line, the side question quoted line by line after "> " (a bare ">" for an empty line), a blank line, then the answer. After it was accepted the button reads "Sent to the main session". On a terminal-face session it is off, with "Notes go to Claude in a Chat session" |
| Discard | "Discard Side Chat" in the "…" menu opens a sheet, "Discard this side chat?": "Sphyrna deletes its copy of the session. The main session is not touched." There is no default button (§6 Sheets, D-78): Cancel has the focus and Esc, Discard is tinted in the failure tone, and Return does nothing. A discard that could not finish keeps the thread, says why, and offers "Try Again" (the deletion's own retry). Deleting the main session names its side chats in the confirmation and deletes them with it |
| Unsupported | A Claude that cannot fork says "This Claude version cannot fork a session" under the field and the field takes nothing; Sphyrna learns it by trying, never by version number |
| Memory | What the tab remembers (the open side chat, the typed text) lives in memory; the side chats themselves are sessions of the catalog that no list shows |
| Contrast | Every value is a `LoomTheme.Side` token; the thread uses the chat's own, already proven pairs |

## 17. The school

(D-74; [the reference](reference.html#school).)

The sharks are Sphyrna's identity, not decoration. The hammerhead is the main character, and a thresher and a whale shark swim with it. The remora rides with the hammerhead as Remora's face (D-77).

**How they are drawn.** They are drawn in ASCII:
- a body follows its trail, with a wave travelling along it;
- the body is filled into a density field of one cell per character;
- each cell's density picks a character from the ramp ` .:-=+*#%@`;
- eyes are `o`, the whale shark's spots are `°`, and the remora's disc is a bar across its head for each plate, `|`, `/`, `-` or `\`, whichever way it faces (D-80);
- plankton drifts, and a faint wake follows.

Sphyrna's own code draws them; the idea comes from stackedlol/ascii-sharks.

| Shark | Its character | Where it swims |
| --- | --- | --- |
| Hammerhead | The main character: a hammer with an eye at each tip | First launch, where it comes in from the right and roams with the whale shark and the remoras (D-79). About (it crosses once behind the mark, then rests). Home's band: one, always there, on its fixed loop (below). The new-session page (two of them). A waiting pane (a small one, swimming in place where a spinner would sit: a session starting, the Changes tab reading git). An empty Agents tab. An empty project's page (D-76). The app icon, Rising (D-77). Remora's arrival on Home, with the remora on its flank |
| Thresher | The quick one: its tail is as long as its body | An empty Changes tab. It left Home's band (D-79) |
| Whale shark | The slow giant, known by its spots | Deep below the first-run message (D-79) and the new-session page. An empty Side tab |
| Remora | Remora's face, known by its disc (D-80): a slender fish with a broad, flat head under its sucking disc, an oval of plates over its first two fifths, and an eye on each side of the head. A large remora also shows the ridge between the plates | On the hammerhead's flank, at the start of Home's brief, where it rests beside its sentence, and at the start of the folded brief's line (§9). At the first launch a few keep to the hammerhead and the whale shark (D-79). Never on its own anywhere else |

**Rules.**
- **Only where nothing is read.** The sharks swim on empty canvases (the new-session page, Home's band, first launch, About) and in empty or waiting panes. They never swim behind the terminal, a list, a card's text, the chat or anything being read, and never in the sidebar, the header or the tab row. The remora rests beside Remora's sentence, never behind it, and holds still while the sentence can be read.
- **Quiet.** They are drawn in the art colour at a low alpha over the faint grid: about 0.5 on the new-session page, about 0.45 at the first launch (fainter in the message's middle), about 0.4 in Home's band, about 0.7 for a small shark in a pane, and about 0.8 for the resting remora, in semibold glyphs on a finer grid, because it is Remora's face. They are never coloured and never a status.
- **The words stay plain.** An empty or waiting pane says what is empty or what Sphyrna waits for ("No subagents in this session.", "Reading the branch…"). The shark adds nothing to the copy.
- **The budget.**
  - Ambient art draws at most 24 frames a second; a shark in place and Home's loop draw at most 12.
  - Remora's arrival is the art's one scripted motion: at most 60 frames a second for its 2.2 seconds, 12 while the remora swims in place, then none.
  - It draws only while its view is on screen in a visible, active window. Off screen, in the background, or under an occluded or hidden window, it has no timer and no wakeups.
  - **Animated art** (Settings → Theme, under Appearance; on by default, D-79): the art moves under Reduce Motion too, as the working spinner does (D-12). Off, every drawing stands still on one frame, and the arrival becomes the remora fading in at its place. Reduce Motion still makes the transitions instant.
  - Its cost while visible is measured when it is built, against the resource budgets (O-01). A surface that cannot afford it shows a still frame.
- **Home's loop** (D-79). Home's band has one hammerhead, always there, on one fixed loop of 180 seconds: a wide, flat ellipse, left along the top and back along the bottom, whose turns fall out of sight past the band's edges, so that its tail leaves one side as its head comes back on the other. It draws with no plankton and no wake. The loop repeats, so the app may work out its frames once and then only draw them; the art's spike (§5) measures which way is cheaper.
- **Accessibility.** The art is hidden from VoiceOver. Increase Contrast leaves it as it is, because it carries no information. Reduce Transparency changes nothing.

## 18. Moving from Night Fleece

**The plan.** The order and the slices are planned in [V2-PLAN §13](../plans/V2-PLAN.md#13-the-ui-revision-ink). Each step:
- moves tokens or surfaces to Ink;
- updates UI-MAP's entries for what it moved;
- passes the contrast tests for its pairs in both appearances.

**What goes:**
- the navy sidebar;
- the violet-grey panel family, with its six levels, and D-63's tones as the code has them (Night fleece, Workshop, Instrument); Ink's tones are Neutral, Warm and Cool (§3 Tones, D-81);
- the panel inset and border around the terminal;
- the 3 pt project stripe;
- the working chase;
- the subagent tree's hairline guide;
- the old two-row card look and its trailing provider icon (the harness's mark now leads every title, D-75);
- the composer's separate model and effort chips (one chip now, D-75);
- the sidebar header's view buttons and ⋯ menu (the list's heading switches the view, D-75);
- every Night Fleece value (the contract before Ink: `git show 371aaf6:design/DESIGN.md`).

**What stays:**
- the accent ramp;
- the status hues (Paper's dots are lighter, §3);
- the project tones and the mode tones;
- the pill's behaviour;
- every content and behaviour rule of §2, §4 and §7–§16;
- the contrast floors and the motion limits.

## 19. The edges

(D-79; [the reference](reference.html#edges). Home's first-run, empty and no-Claude states are §9's; the art is §17's.)

| Item | Rule |
| --- | --- |
| The ended line | One line above the last screen, flush on the canvas: "This session is not running.", then Show Details and Resume at the trailing edge, Resume last. Resume is filled, because it is the pane's one action, but Return does nothing there: the screen below keeps the focus. A stale session's button reads "Reactivate and Resume". While it resumes, the line says "Resuming…" with the spinner |
| The last screen | As it was: a copy, selectable, scrolled to the bottom, dark in both appearances like any terminal, with no cursor and nothing swimming behind it |
| No pill | An ended session has no pill and no mark, in the header, the tab and the sidebar. The control group keeps only ⋯, because there is nothing to stop |
| The record | With no screen to show (after a relaunch, after a stop, or from Show Details) the record shows, in the appearance. What it says comes first: a notice when the state has one, then "Not running", what Resume does, and the buttons. The facts follow in a card. The notice is the state pill's long form, so the two always agree: the state's wash at 10 % and its edge, its symbol, a title and one sentence |
| The chat after an end | When sessions run in Chat, the chat keeps its composer: sending resumes the session, so there is no notice, and the missing pill says it is not running. A request Claude asked before it stopped stays pinned, quiet: "Claude stopped before you answered", its subject, and Resume. A message that never went says so above the composer, with Copy: "Not delivered: 1 message. It comes back in the composer when the session runs again." Resume resumes in place |
| Banners | One family, the chat's box (§12), in the top stack under the tab row and above the pane's own line, 12 from the edges. One shows; the rest wait behind a "+N" peek that opens them in place and closes them again. By weight: what did not happen first, in the failure tone with the triangle; then what limits Sphyrna, in the attention tone; then notes, quiet; newest first within a tone. Each tone has its own symbol, so colour is never alone, and only the edge and the symbol take the tone. The words are the code's: what happened, then the detail. × closes a banner at once and for the session; a notice that holds while its cause holds, such as the missing helper, has no ×. The stack pushes the screen down once and comes in by opacity only (§6 Motion) |
| The menu bar | The Front mark (§6 Name and marks) carries the strongest state in its corner: the failure dot over the attention dot over the unviewed dot, and any dot over the working spinner, which moves. The menu starts with what needs you (a header in 11 semibold tertiary, then up to five rows of the status dot, the title and the project in secondary, failures first, then "and N more…"), then what is working (the spinner on its first frame, since an open menu is not redrawn), then New Claude Session with Claude's mark, Open Sphyrna, Settings… and Quit Sphyrna, which asks first as ⌘Q does. A click on a row brings Sphyrna forward on that session. With nothing working or waiting it shows one line that cannot be clicked: "Nothing is working or waiting." It lists exactly the sessions the Dock counts |
| The notification | Only when a session starts to wait for an approval, a question or a plan while Sphyrna is not the active app. The title is the session's; the line says the project first, then why. No sound and no buttons: a click brings Sphyrna forward on the session, and the notification goes when the session stops waiting. Finished, failed and working send nothing. When macOS refuses, Settings' switch stays on, and a line under it in the attention text says why nothing comes and how to change it |
| The Dock | The badge counts the sessions that need you: failed, waiting and finished unread, the Home row's count (§2) |
| The alerts | System alerts with the app icon. Quit with sessions working asks D-45's question, and Cancel is its default, filled and on Return. When a stop is not verified, three buttons stack as macOS stacks three: Try Again (the default), Keep Sphyrna Open, and Quit Anyway in the failure text. A damaged session list asks at launch, before any window: Restore Backup, Start Fresh and Quit; a catalog newer than the build stops at Home's own message instead |

## 20. Remora

(D-64, D-65, D-77, D-80; [the reference](reference.html#remora).)

Remora is Home's assistant. It reads the sessions and says where you left off, answers what you ask about them, and remembers what you tell it to. It only reads (D-64): an answer links to the sessions it names and can leave an unsent line in a composer, and Remora never sends a message, starts or stops a session, or answers a request. Its sentences are the model's, in first person and in the question's language; the headings, the tiles' catalog lines, the states and the buttons stay in Sphyrna's plain voice. Every brief and answer ends with what it read, how long it took and its sources. It lives on Home (§9). Beyond Home it has two doors, ⌘K and a new session's brief, and nothing else in the app waits for it.

| Item | Rule |
| --- | --- |
| The brief | "Where you left off" in SF Pro Display 34, weight 200; the date and the span the brief covers in mono tertiary; and ⋯, with Catch Me Up (it writes a new brief), Memory… and Settings…. Once the brief folds, the heading goes. Then Remora's place and sentence (§9), in 14.5 primary, at most 780 wide; up to three tiles; one line for each further project that moved, and one folded line for each quiet project; the line that proposes a fact to remember; the field; and the footer. A project excluded in Settings is never named |
| Tiles | One per project that moved, at most three, ranked by Remora: closest to done, a failure, then work cut short. A tile holds the project's mark and name with the time its note was rewritten, the session's harness mark and title, how it ended (the catalog's, in Sphyrna's words), and "Next:" from the project's note. **Put in Draft** (a small secondary button) leaves that next step, shown whole on hover, in the session's composer, unsent: an empty Chat composer gets it; a composer with text keeps its text, and the line is copied instead; a terminal session only gets it copied (D-64). **Open** opens the session |
| Remember | "Remember this?" and the fact, with Save and Not Now. Save writes it to `Remora.md`, with Undo; Not Now drops it. Settings can turn these proposals off. A question that starts "Remember …" saves at once, with no call, and offers Undo |
| The field | "Ask Remora about your sessions", 46 high, radius 15, on raised 2 with the composer's shadow, with its scope chip (All projects or one project, from a menu with a check) and Send. ↵ asks, Esc stops, and ↑ in the empty field brings back the last question |
| The footer | What Remora read and how long it took, in mono tertiary ("Remora read 6 sessions and 3 project notes · 4.6 s"), then Sources, a popover that lists each session and note it read with its age, and the call's size, and Memory… |
| Answers | One at a time, under the field: the question with "You asked at HH:MM" and ×, then the reading line with the spinner ("Reading 4 sessions and searching 14 days of transcripts…"), then the answer, word by word. Each session it names is a chip (the project's mark, the title and when) that opens the session, as the sidebar does; an answer about where to go on carries Put in Draft beside its chip. A session it could not read is named as unread, never summarised from nothing. The answer ends with what it read, the time and Sources. While it answers, Stop takes Send's place, and Esc does the same; a stopped answer keeps its words and says "Stopped. Ask again for the whole answer." The question before folds into one Earlier line, the only history Home keeps; a click brings it back |
| States | **When I ask** (Settings): no call and no arrival; under the heading, "Your latest sessions, newest first." with Catch Me Up, and the catalog's tiles with Open only. **When Remora cannot answer,** its sentence says why in Sphyrna's voice, the tiles fall back to the catalog's, and the remora rests: "Remora uses your Claude Code login. Log in with claude in a terminal."; "Less than a tenth of your 5-hour limit is left until 13:40, so the morning brief waits. Questions still run.", with Catch Me Up Anyway; "Remora could not get an answer from Claude.", with Try Again. **Remora off:** Home is §9's band and Needs you. **Before any session:** the band's "Nothing is working or waiting.", then "Remora reads your sessions and tells you where you left off. It answers once you have a session.", and the empty Needs you card (§9) |
| Memory | One sheet, 560 wide, from ⋯, the footer's Memory… or Settings: "Remora's memory", "What Remora keeps between answers. Every change is written at once.", and three tabs. **Journal:** what Remora was asked and said, by day for 14 days, then one line a week for 12 weeks; × removes a line, and Remora's next calls no longer see it. **Project notes:** one per project, rewritten each morning from its sessions, at most 2 KB, with Edit, which changes it in place, and Remove, which forgets the project until its next session and offers Undo. **Remora.md:** the vault note, with who Remora is, how you want answers and what you asked it to remember, with dates; Remora writes only under its own headings; Open in Obsidian. The journal and the notes are the working memory, in Sphyrna's data folder; `Remora.md` is what lasts (D-64). Nothing waits for a save: Done closes the sheet, as Esc does, and is not filled (D-78). Clear Working Memory… asks first and keeps `Remora.md` |
| Settings | Remora's tab, before About (D-77). **Remora,** the switch: "Answers questions about your sessions on Home and from ⌘K, and drafts a new session's brief. It only reads." **Model** Sonnet 5.5 and **Effort** Low (D-64), with "Haiku 5.5 answers faster and uses much less of your plan." **Morning brief:** Automatic (one brief on the first Home of the day after 04:00, when a session moved since the last one) or When I ask. **Brief language:** the language of your last question unless set. **What it reads:** every project by default; excluding one deletes its note and keeps it out of every call, All projects included. **Memory:** Working memory (what it holds and when it was updated, with Show… and Clear…), the memory note's path (Choose… and Open), and Propose things to remember, the line under the brief that asks before anything is saved. **Use:** today's questions, briefs and tokens, and "Wait while the 5-hour limit is under 10%", a stepper: the morning brief waits, and questions still run with a warning line. A last line says what leaves the Mac: Remora reads the transcripts only while it answers and sends short excerpts to Claude through your Claude Code login, with Claude Code's telemetry and update checks off for its calls; its memory stays on the Mac. Off, the rest of the tab dims; Home starts with its band and Needs you, ⌘K has no Ask row, and the new-session page has no brief row. The memory stays |
| ⌘K | The first door. When what you type in the palette reads as a question, Ask Remora heads the list under a "Remora" header, with its scope, ⇥ and ↵; the palette's own results follow, sessions and then lines in transcripts. The scope is All projects, and ⇥ narrows it to this project or this session. In a session that runs in Chat the quick question (§15) asks Claude with the whole session in view, so This session is for ended and terminal sessions. ↵ asks, and the answer opens in the palette with its chips: a chip opens the session and closes the palette, and ⌘↵ opens the answer on Home as the field's Earlier line. The call runs beside the session, whose own context stays as it was |
| A new session's brief | The second door: §8's Remora's brief |
| Left out | Remora has no place on the project page (Home's tile already says the next step, and a stored one goes stale once you work on the project), inside a session (the quick question and the side chat ask Claude in place with the whole session in view, where Remora would see an excerpt; ⌘K covers ended sessions), on a request card (anything beside Approve could read as an answer, and Remora never answers a request, D-64), in the Changes tab (Remora does not read git, D-64, and the session's Claude explains its own change better), on a failure (its words come from the code and from Claude, and a summary would add a guess), in a notification or the menu bar (a notification means a session waits for you, §19, and the menu bar is for state), or in session cleanup (deleting on a model's summary is a risk; the title and the last line are enough). A new place has to pass one test: Remora saves a step you take often, without a new surface and without a second opinion beside what Claude or the code already says |
| Cost | A call only on a question, a click, or the first Home of the day (D-64), and none for "Remember …". The morning brief waits while less than a tenth of the 5-hour limit is left; questions still run |
| Accessibility | VoiceOver's group is "Remora" (§6). The remora is art, hidden from VoiceOver (§17) |
