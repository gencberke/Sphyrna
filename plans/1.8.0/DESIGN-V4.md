# Ink v4: the design proposal for 1.8.0

**Status:** approved by `@user` on B0's rendered reference on 27 Oct ([D-106](../../DECISIONS.md)):
- FEEDBACK-7's [Q1–Q6](../FEEDBACK-7.md#decisions-open) take their defaults, as written on this page.
- Two token values are corrected by B0's contrast table: Ink tertiary `#8F8F8F` and Paper faint `#9C9C9C` (§2).
- The model and the effort are two pickers (§6), not one panel with an effort step.

The planner moves these rules into [design/DESIGN.md](../../design/DESIGN.md) before B1 starts, and this file is then archived.
Until then, this page and the reference's "Ink v4" chapter are the contract for 1.8.0's slices.

**The aim.** The aim is Orca's design system (FEEDBACK-7 FB7-2) in a native macOS app, keeping what makes Sphyrna recognisable:
- **What it takes from Orca:**
  - a quiet neutral chrome;
  - one control family with fixed roles;
  - surface pairs;
  - three elevations;
  - a lifted sidebar;
  - a status bar;
  - Orca's UX rules.
- **What stays Sphyrna's:**
  - SF Pro and SF Mono;
  - the periwinkle accent as the mark of focus and of what is current;
  - the status language;
  - project tones and harness marks;
  - Ink and Paper with their tone casts;
  - Remora;
  - the untouched CLI in its terminal.

## 1. The six rules, v4

1. **Two planes.** The sidebar is a plane one step lighter than the content. The content (the terminal, pages, the inspector)
   is the canvas. Hairlines divide; nothing is boxed twice; only what you act on is lifted.
2. **Two voices.** SF Pro for what you read, labels included. SF Mono only for what the machine says: branches, paths, model ids,
   times, tokens, counts, keys.
3. **Colour means state.** The chrome is neutral grey. The default action is a neutral fill. Periwinkle marks focus and what is
   current. Orange, blue and red are status; green is content only. A project's tone is its mark and its tab.
4. **One control family.** Four heights (24, 28, 32, 36), one radius (8), one hover, one focus ring, six button roles.
5. **Three reading points.**
   - The sidebar says how every session is doing.
   - The header says how this one is doing and what you can do with it.
   - The status bar says how the accounts are doing.
6. **Quiet by default.** Feedback matches the duration, the way back is never coloured, a tooltip only names, and copy never
   claims more than the state proves.

## 2. Tokens

Every token keeps one name with an Ink and a Paper value (`LoomTheme.Adaptive`). Tone casts (Warm, Cool) recompute the six
greys from v4's neutrals as they do today. Status, accent, project and mode colours keep their v3 values (DESIGN §3).

### Surfaces and lines

| Token | Ink v3 | **Ink v4** | Paper v3 | **Paper v4** | Use |
| --- | --- | --- | --- | --- | --- |
| Canvas | `#0C0C0E` | `#0A0A0A` | `#F7F6F3` | `#FFFFFF` | Content: pages, the inspector, the header and tab row; the terminal keeps Ink's canvas in both appearances |
| Sidebar | the canvas | `#161616` | the canvas | `#F7F7F7` | The sidebar plane (Q2). Settings' sidebar fill keeps Canvas, Raised and Deep with their opacities; **Raised is the new default** |
| Card | `#121215` | `#171717` | `#FBFAF8` | `#FFFFFF` + hairline | Cards on the canvas: Home's lists, Settings' groups, the inspector's sections |
| Raised | `#17171B` | `#1E1E1E` | `#FEFDFC` | `#FAFAFA` | The selected session card (Q3), the composer, a card on the sidebar |
| Popover | `#1C1C21` | `#1C1C1C` | `#FFFFFF` | `#FFFFFF` | Menus, pickers, the palette, the model panel, the inspector as an overlay |
| Muted | — | `#262626` | — | `#F4F4F5` | Secondary buttons, a segmented control's track, badges, the status bar's meters' track |
| Hover | white 5 % | white 7 % | ink 4.5 % | ink 4.5 % | Ghost buttons and list rows under the pointer |
| Pressed | white 12 % | white 12 % | ink 10 % | ink 9 % | Momentary |
| Hairline | white 7.5 % | white 7 % | ink 8.5 % | `#E5E5E5` | Every divider and card edge |
| Hairline strong | white 11.5 % | white 10 % | ink 13 % | `#D9D9D9` | A selected card's edge, a hovered outline control |
| Input edge | — | white 15 % | — | `#E0E0E0` | Fields and outline buttons |
| Input fill | — | white 4 % | — | `#FFFFFF` | Fields and outline buttons |
| Scrim | black 40 % | black 50 % | ink 22 % | ink 20 % | Behind the palette, the model panel and sheets |

### Text

| Tier | Ink v4 | Paper v4 | Use | Floor (unchanged) |
| --- | --- | --- | --- | --- |
| Primary | `#EDEDED` | `#0A0A0A` | Titles, body, values | 7:1 |
| Secondary | `#A1A1A1` | `#525252` | Supporting text, inactive tabs, descriptions | 4.5:1 on every plane and fill |
| Tertiary | `#8F8F8F` (B0: `#8A8A8A` missed 4.5 on the hover fill) | `#6B6B6B` | Labels, meta, counts, key hints | 4.5:1 on the canvas, the sidebar, the card and the hover fill |
| Faint | `#6B6B6B` | `#9C9C9C` (B0: `#A3A3A3` missed 2.5 on the sidebar) | Placeholders, disabled items, decorative marks | 2.5:1 |

The test suites that hold the floors (`ThemeAppearanceTests`, `LoomThemeTests`, `HighlightTests`, `ProjectColorUITests`) run
on the new values. A pair that misses its floor moves one step and the table is corrected; it is never waived.

### Accent and the default action (Q1)

- **The default (primary) button** is neutral: Ink `#EDEDED` with `#171717` text, hover at 90 %; Paper `#171717` with `#FAFAFA`
  text. "Filled means Return" stays: the one filled button is the one Return presses.
- **Periwinkle** (`#8791CF` Ink, `#4B56A8` Paper, unchanged) is the focus ring, the current view tab's underline, the current
  item's marker where one is drawn, a switch that is on, a slider's fill, links, and the drag looks' line and wash.
- **The focus ring** is a 3 pt halo of the accent at 45 % outside the control's edge, with the edge itself in the accent. It is
  drawn on keyboard focus only.

## 3. Type

| Role | v3 | **v4** |
| --- | --- | --- |
| Display (the new-session question) | SF Pro Display 46, weight 200 | 34, weight 300 (Q5) |
| Statement (Home's sentence) | 42, weight 200 | 34, weight 300 (Q5) |
| Title (a page) | 20 semibold | 20 semibold |
| Header (the session's title, a card's heading) | 13 semibold | 13 semibold |
| Body (rows, menus, fields) | 13 regular | 13 regular |
| Button | 12.5 medium | 13 medium (12 medium at 24 high) |
| Small (supporting lines, a card's second line) | 12 regular | 12 regular |
| Caption | — | 11 regular, sans: a status bar's figures, a badge |
| **Label** (section labels) | SF Mono 10.5, capitals | **SF Pro 11 semibold, capitals, tracking 5 %** (Q4) |
| Meta (machine text) | SF Mono 11–11.5 | SF Mono 11 |
| Terminal | SF Mono 14 | unchanged |

Weight carries hierarchy before size. No Dynamic Type, as before.

## 4. Shape, size and depth

| Item | v4 |
| --- | --- |
| Grid | 4 pt, as before |
| Radii | **4** key caps; **8** controls, fields, rows, menu rows; **12** cards, popovers, menus, the model panel, the palette; **16** the composer; **capsule** badges, the state pill and status chips |
| Heights | **24** xs: chips, inline buttons, status bar controls; **28** sm: toolbar and icon buttons, sidebar rows and project heads, tabs, menu rows; **32** default: buttons in pages and sheets, fields, the search field, segmented controls; **36** lg: a sheet's or an empty state's main action; **26** the status bar; **52** the header (unchanged: the window buttons' line) |
| Elevation | Three levels, no fourth. **1.** A hairline: almost everything, cards included. **2.** A hairline and a small shadow (0 1 2, black 20 % in Ink, ink 6 % in Paper): outline buttons, the selected segment, the selected session card, the composer. **3.** Floating (0 10 24, black 35 % in Ink, ink 14 % in Paper, plus a hairline): popovers, menus, the palette, the model panel, sheets |
| Materials | None. No blur, no vibrancy. A floating surface is opaque |
| Motion | Hover and selection fade in 120 ms. A popover rises 3 pt in 160 ms. The sidebar's live reorder slides in 150 ms. Under Reduce Motion, movement goes and fades stay |

## 5. Components

**Buttons.** Six roles, each at the sizes above:

| Role | Look | Use |
| --- | --- | --- |
| Default | Neutral fill (§2), medium text | The one affirmative action of a surface (Start, Save, Open Session, Delete's confirm uses Destructive) |
| Secondary | Muted fill | The sibling of the default action |
| Outline | Input fill and edge, elevation 2 | Standalone and toolbar actions where a fill is heavy |
| Ghost | No fill; the hover fill under the pointer | Icon buttons, row actions, Cancel, Dismiss, Close |
| Link | Accent text, underline on hover | Inline in a sentence |
| Destructive | Failure red fill (Ink: red at 60 %), white text | Delete, Discard and irreversible actions; never Cancel |

**Back-out path:** Cancel, Dismiss, Close and Discard-draft are ghost or secondary, never coloured. Esc works, and they carry no
key chip.

**Fields.** 32 high, radius 8, input fill and edge, 12 inside. The focus ring is as in §2, and an error is the failure edge with
the message under the field.

**Switch.** 32 × 18, capsule. Off is the muted track with a white thumb; on is the accent track.

**Segmented control.** 32 high. Muted track, radius 8; the chosen segment is the canvas (Ink) or white (Paper) at elevation 2,
radius 6.

**Badge.** A capsule, 18 high, caption type. Muted fill with secondary text, or an outline. A status badge takes the status's
wash and text colours.

**Key chip.** One component for every shortcut (menus, tooltips, the palette's footer). SF Mono 11 in a 4-radius cap with a
hairline. Never on a back-out action.

**Tooltips** name icon-only controls and cut text, after a 400 ms delay. Never a warning, an error or a lesson.

**In-flight feedback:**
- under 100 ms, nothing;
- up to 1 s, disabled only;
- 1–3 s, disabled with the spinner or a label swap;
- longer, a stage label ("Checking…", "Starting Codex…").

The space a label or spinner will take is reserved from the start.

**Copy:** no "please", "simply" or "just". Result verbs ("deleted", "verified", "found") only after the result. Missing data
offers the action that gets it ("Codex is not signed in. Copy Sign-In Command").

**Icons:** SF Symbols, one weight (regular), 14 in chrome (16 in a 28 icon button), 12 in dense rows; colour from the text tier.
One spinner (the braille spinner) for every in-flight state.

## 6. Surfaces

### The sidebar (FB7-1, B2)

- **Top:**
  - the search field (32 high, full width, "Search" with the `⌘K` chip), opening the palette;
  - nav rows of 28 for Home and New Session (`⌘N`). Home carries a count badge when sessions need you, as Orca's
    Agent Dashboard does.
- **Section heading:** "Projects" or "Activity" in Small medium secondary, with its icon buttons at the trailing end (the view
  switch, Add Project or New Session). No mono capitals.
- **Project head:** 28 high, the mark (16), the name (13 medium), and the chevron, `+` and `⋯` on hover.
- **The session card:**

  ```
  ┌─────────────────────────────────────────────┐
  │ [EB] edd-backend               ◌ Working 37s │  ← top line: mark (14) + project, or harness mark + model in the
  │ Remove Task Config Status                   │     Projects view; status at the trailing end
  │ feature/bg/EDDP-20625                   [✳] │  ← branch in mono 11 tertiary; harness mark (12) at the end
  └─────────────────────────────────────────────┘
  ```
  - Padding 10 by 12. The lines are 18, 20 and 16 high, and the title wraps to two lines at most.
  - Radius 10; the card has no fill at rest. Under the pointer it takes the hover fill; selected, it is raised with the strong
    hairline at elevation 2 (Q3).
  - **The status** is a mark and a word in the status's text colour: Working with the spinner and the elapsed time; Needs you,
    orange; Failed, red; Finished, blue. Ready is nothing, and the top line's trailing end shows the time since the last
    activity in mono tertiary.
  - The reason line (the Activity view) sits under the title in Small secondary.
  - **Subagents** branch from the mark's column, the line leaving the mark's centre. Their rows are 24, with a still running mark.
- **Drag:** the project reorder is live (A1): the head lifts and the blocks slide.
- **The bottom:** the footer chip goes (the status bar takes it). Settings and Help stay as ghost icon buttons at the sidebar's
  bottom edge.

### The status bar (Q7, B3)

- **The bar:** 26 high along the whole window's bottom, under the sidebar and the content. It is the sidebar plane's colour with
  a hairline on top, in caption type.
- **The leading side** has one segment per connected harness that reports limits:
  - the segment reads `[mark] ▬▬▭ 4% · 3h 39m   7% · 5d`: the meter is 40 × 4, then each window's used share and its time to
    reset;
  - the meter fills by the share left, orange under 20 %, as the plan meters do;
  - a click opens a 360-wide popover with each window's full line, the reset times, when it was read, Check Again and Open Usage;
  - a harness that reports no limits shows only its mark and "No limits read";
  - nothing is asked to fill the bar beyond what Usage already asks.
- **The trailing side:**
  - "N working" when sessions work;
  - Keep Mac Awake as a toggle, its state the same as Settings → General;
  - a Remora segment while a brief is being read;
  - an update notice when a harness needs one.
- **Rules:** the bar never animates while the app is not in front, and it is redrawn only when a figure changes. It hides in
  full screen with the menu bar.

### The model and the effort (FB6-7, FB6-8, B4)

Two pickers side by side, as reference chapter 06 draws them (D-106: "model-effort seçicileri ayırmak"). They replace the one
panel with an effort step that this page proposed first.

- **The chips:**
  - two ghost buttons, 28 high, wherever a model is chosen: the draft's composer, the session header and Remora's setting;
  - the model chip: the harness mark, the model's name and a chevron;
  - the effort chip: the effort icon, the level and a chevron;
  - a model with no levels shows the model chip alone;
  - the open chip has the selected fill.
- **The model panel:** a popover under the model chip, 412 wide, at elevation 3.
  - **Search on top:** focused when the panel opens; typing filters across every harness that is on, and says which harnesses
    it did not search.
  - **The rail on the left (44):** marks only, in the list's order, with the name and state in the tooltip:
    - Recent;
    - the harnesses that are on;
    - then, under a hairline, the ones that are off or not found, dimmed with a small dot.

    The rail follows the list as it scrolls; a click jumps to that harness.
  - **The list:** every model grouped by harness under its mark, label and count.
    - A row is 32: the name, its one-line description in tertiary, and the context size in mono.
    - The highlighted row has the selected fill; the current model carries the accent check.
    - A search result also shows its harness's mark.
    - A harness that is off or not found closes the list as one row with the action that fixes it ("Install…", "Turn On…"),
      which opens Settings → Connections.
  - **Keys:** ↑↓ moves through the models, ↵ chooses and closes, Esc closes without a change.
- **The effort menu:** a popover under the effort chip, 300 wide, at elevation 3.
  - A header carries the label "Effort" and the model's name in mono.
  - One row per level the chosen model offers: the level, one line on what it is for, a "Default" tag on the model's default,
    and the accent check on the current level.
  - ↑↓ and ↵ choose; Esc closes.
- **Changing the model** keeps the effort when the new model has that level; otherwise the effort becomes the new model's
  default.

### Elsewhere (B5a–c)

Every other surface takes the components above, and nothing else changes in its layout unless a slice names it:
- Home, the project page and the draft page (B5a);
- the header, the tabs, the inspector, the ended line, banners and the open request's card (B5b);
- Settings, sheets, the palette, menus and About (B5c).

The Agents tab (B5b) reads a subagent's transcript the way Orca's chat reads a turn:
- text as Markdown;
- tool calls folded into one "Ran N tools" line with their times, opening on a click;
- tables drawn as tables.
