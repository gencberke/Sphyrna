# Loom identity: proposal (6 Oct 2026)

**Status:** direction **A · Night Fleece** chosen by the user (6 Oct 2026, [D-22](../DECISIONS.md)). The optional borrowings in §4 and the sub-decisions in §5 stay open and default to A's values until the user decides them. Implementation (tokens into one Swift source, rules into DESIGN.md) is roadmap stage I.
Visual aid: [identity-preview.html](identity-preview.html) (open in a browser; tokens match the tables below).

Ground truth: [DESIGN.md](DESIGN.md) (§2 keep-list, §3 sizes and colours, §4 status language, §5 open items), [UI.md](../plans/cp5/UI.md) feedback of 5 Oct, code tokens in `Sources/LoomCatalogUI/CatalogTheme.swift`, `SidebarBackground.swift`, `SessionDisplay.swift`, `Sources/LoomTerminal/TerminalTheme.swift`. Contract §3 fixes the design and icons, so every direction **evolves and codifies** what exists. Where a direction changes something fixed, it says so and lists it as a user decision.

## 1. The story the identity is built on

The user's mark is a ram whose eye is a `>_` prompt, periwinkle fleece (`#E2E8FF` to `#858DC9`) on night navy (`#26314D` to `#0B1020`). Ram, wool, thread, loom: Loom takes a herd of agent conversations (the name it grew out of was Herdr) and keeps their threads in one place. The terminal is the cloth, and Loom does not weave it. Loom is the frame around it.

Three facts follow, and all three directions keep them:

1. **The accent is the fleece.** Today's accent `(0.53, 0.57, 0.81)` = `#8791CF` is almost exactly the mark's darkest fleece stop `#858DC9`. It is defined in code but never used. Identity starts by wiring it in.
2. **The terminal is the hero, and it is not Loom's.** Loom frames it and never restyles, overlays or recolours CLI content beyond supplying a vivid standard palette.
3. **Calm by default, loud only for you.** Colour and motion are reserved for states that ask for the user. Everything else is quiet.

## 2. What "identity" covers

| Area | Rule for every direction |
| --- | --- |
| Personality | A quiet night workbench for one power user running many agents. Competent and calm. Never cheerful at the user's expense. |
| Voice and copy | Sentence case, no exclamation marks, no emoji, no "Oops". Say what happened, what Loom did or did not do, and what the user can do. Use exact provider names ("Claude", "Codex"). Errors never use metaphor. Any metaphor budget (only direction B has one) applies to empty states only. |
| Colour | Dark only, which matches today's forced `darkAqua`. Two surfaces (sidebar glass, panel/terminal). Three text tiers. **One** brand accent. Three status hues. White-alpha fills for controls. No provider colour tokens: a provider's colour lives only in its official mark. |
| Typography | SF Pro for UI, SF Mono for terminal (14 pt, 11–20). Fixed sizes, as today. Weight carries hierarchy before size does. |
| Iconography | SF Symbols, monochrome, regular weight, 13 pt in chrome. Never palette-coloured. Provider marks are official art at 14/16/34 pt and are never tinted. The Loom mark appears as app icon, menu bar template, About, and (proposed) once in the empty catalog state at 48 pt in `text.tertiary`. The SVG accessibility label is "Loom" (D-24). |
| Shape and spacing | 4 pt grid. Concentric radii: panel ≥ card ≥ control. Geometry from DESIGN §3 stays: 52 pt header, 26 pt centre line, 8 pt panel inset, 6 pt terminal inset. |
| Materials | Only the sidebar is glass: `.sidebar` behind-window material under a dark tint. Panel and terminal are opaque. Reduce Transparency swaps in the opaque tint colour. No wallpaper colour may read through (5 Oct item 10). |
| Motion | Persistent motion only as render-server layer animations (`CAKeyframeAnimation`), stopped when the window is hidden or inactive or the surface is closed (contract §10). One-shot transitions ≤ 200 ms ease-out. No glow, pulse or breathing. Nothing animates inside the terminal panel. Under Reduce Motion, transitions become instant or cross-fades. The small working chase keeps running (user decision, 6 Oct). |
| Status language | DESIGN §4: small and coloured, Unpeel-like. Working = chase around a rounded square. Approval/input = attention dot. Unseen finish = unviewed dot. Error = failure mark. Idle/ready = nothing. The same component (`IndicatorView`) is used on every surface. |
| Terminal framing | Panel colour = terminal background, so the CLI sits edge to edge. The header lives outside the terminal. ANSI 16 = VS Code Dark+, xterm 256 cube, steady block cursor. Observation, not a change: normal ANSI red `#CD3131` and blue `#2472C8` are ~3.3–3.5:1 on the panel; the bright variants are ≥ 4.7:1. The CLI chooses which it uses. |
| Sound and haptics | **None.** Loom makes no sound. Dock and menu-bar notifications are out of v1 scope. If they arrive later, they use the system notification sound under the user's system settings, never a Loom sound. |

## 3. Three directions

Shared tokens in all three (not repeated below): ANSI 16 palette, SF Mono 14 terminal, 4 pt spacing unit, chase geometry (12 pt box, 8 pips, trail opacity 1 / .8 / .55 / .35, rest .16, 10 fps discrete = 0.8 s cycle), control fills (hover 9 %, pressed 14 %), Reduce Transparency behaviour.

### 3.1 Token comparison

| Token | A · Night Fleece | B · Workshop | C · Instrument |
| --- | --- | --- | --- |
| `surface.sidebar` (tint over glass) | `#0B0E16` @ 0.86 | `#141311` @ 0.90 | `#0E0F12` @ 0.96 |
| `surface.panel` = terminal bg | `#1D1C22` | `#1E1C1A` | `#16171B` |
| `surface.header` | panel, no divider | panel + hairline below | band `#1B1C21` + hairline |
| `fill.control` (search etc.) | white 6 % | `#EDE8E1` 6 % | white 5 % |
| `fill.selected` card | white 7 % + 1 pt white 10 % stroke | `#EDE8E1` 8 % + 1 pt 10 % stroke + 1 pt top highlight white 5 % | white 5 % + 2 pt `accent` bar at leading edge |
| `hairline` | white 10 % | `#EDE8E1` 10 % | white 12 % |
| `text.primary` | `#E0DBEB` | `#EDE8E1` | `#E6E7EB` |
| `text.secondary` | `#828799` (today `#757A8C`) | `#958D84` | `#8B909A` |
| `text.tertiary` (placeholder, disabled) | `#5A5F70` | `#6E6760` | `#636873` |
| `accent` | `#8791CF` | `#A3A9E5` | `#8C94D8` |
| `status.working` (chase) | `text.primary` | `text.primary` | `accent` |
| `status.attention` | `#FF9E0A` | `#F2A33A` | `#FFB224` |
| `status.unviewed` | `#5C8CFF` | `accent` `#A3A9E5` | `#5EA2FF` |
| `status.failure` | `#F2615C` | `#E8674F` | `#FF5F57` |
| terminal foreground | `#E8E6EE` | `#EDE8E1` | `#E8E6EE` |
| radius panel / card / control / search | 10 / 10 / 6 / 8 | 12 / 12 / 8 / 10 | 8 / 6 / 5 / 6 |
| card padding (h × v), row gap | 10 × 8, 2 | 12 × 9, 4 | 8 × 6, 1 |
| card title | SF Pro 13 medium (selected semibold) | same | same |
| card meta (time, branch) | SF Pro 11 regular | SF Pro 11 regular | SF Mono 11 regular, tabular |
| section header ("Today") | SF Pro 11 semibold, secondary | SF Pro 11 semibold, secondary | SF Mono 10 medium, uppercase, +0.6 tracking, tertiary |
| header title / status label | 13 semibold / 11 medium | 13 semibold / 11 medium | 13 semibold / SF Mono 10 uppercase chip |
| empty-state title | SF Pro 20 semibold | New York 22 regular | SF Pro 17 semibold |
| status pip | 8 pt circle | 8 pt circle, failure 7 pt diamond | 7 pt square, radius 1.5 |
| selection / banner transition | 120 ms / 200 ms ease-out | 160 ms / 220 ms ease-out | instant / 150 ms ease-out |

Contrast is WCAG ratio, computed on the opaque tint (glass is unmeasurable) and on the selected card. `text.secondary` is ≥ 4.5:1 on sidebar, selected card and panel in all three. Today's `#757A8C` is 3.86:1 on a selected card, which is why A raises it. `text.tertiary` is 2.6–3.4:1 and only allowed for placeholders, disabled items and decorative marks. Every status hue and accent is ≥ 4.7:1 on every surface.

### 3.2 A · Night Fleece (closest to today)

**Character.** The current window, made deliberate. Night-indigo glass and an almost-black violet panel. The ram's periwinkle is the single brand colour: focus rings, default buttons, links, nothing else. Status is small and bright against a quiet frame. The identity comes from consistency and voice, not from new paint.

- **Status:** today's set exactly: text-coloured chase; 8 pt orange, blue and red dots; 1.5 pt rings for unknown (grey) and identity unclear (orange); nothing for idle/ready/ended; stale dims the title to `text.secondary`.
- **Sidebar, cards, header:** as today. Selected card is a 7 % fill with a 10 % stroke at 10 pt radius. The header stays transparent over the panel (the navbar remains open, see decisions in §5 below). The accent replaces the system accent on Approve, Resume, Save and Stop and on focus rings (today they follow the user's system accent).
- **Copy:** "No conversations yet. Add a project folder to begin." · "Claude didn't start: the `claude` command wasn't found in your shell's PATH." · "Finished while you were away."
- **Changes vs today:** accent wired in; `text.secondary` `#757A8C` → `#828799`; Settings window forced dark; all tokens written down. **Cost:** small (one theme file, about six call sites). **Risk:** low; may feel like "no change" to the user. It touches a DESIGN §3 colour value (secondary), which is a minor §3 decision.

### 3.3 B · Workshop (warmer, crafted)

**Character.** A craftsman's bench at night. Charcoal with a little warmth instead of indigo, and fleece-cream text. The periwinkle accent also becomes the "finished for you" dot, so the brand colour literally means *Loom has something for you*. Slightly rounder, airier cards, and a hairline under the header that reads as a solid shelf. A serif (New York) appears in exactly one place, empty-state titles, as a handmade signature.

- **Status:** cream chase. Amber attention dot. Unviewed dot = accent periwinkle. Failure is a terracotta 7 pt **diamond**, so failure is distinguishable without colour (Differentiate Without Color), which today's set lacks.
- **Sidebar, cards, header:** 12 pt card radius, 12 × 9 padding, warm 8 % selection with a 1 pt top highlight (a "milled edge"). Header has a hairline divider.
- **Copy (weaving words only in empty states):** "Nothing on the loom yet. Add a project folder to begin." · "Claude didn't start. Loom couldn't find the `claude` command in your shell's PATH." · "Done while you were away."
- **Changes vs today:** base hues (sidebar, panel), text colours, unviewed colour, radii, failure shape, one serif. **Cost:** medium (theme plus `IndicatorView` shape plus card style; terminal background changes too). **Risk:** the app icon is cool navy and periwinkle, so warm surfaces next to it may read as two brands. A warm panel shifts how CLI colours look. Changes DESIGN §3 colours and radii → **user decision (contract §3)**.

### 3.4 C · Instrument (technical, precise)

**Character.** A calm control panel. Neutral graphite, nearly opaque (the most solid of the three, and the cheapest to composite). Crisp hairlines, and metadata set in SF Mono with tabular digits so times and branches line up like readouts. Status reads like an LED plus a word: pips are small squares, and rows that need the user also carry a short mono label. The header is a solid band with a status chip. This direction answers 5 Oct item 6 ("more solid navbar") most directly.

- **Status:** chase of 8 square pips in `accent`. 7 pt square pips: attention amber, unviewed blue, failure red. Cards show a mono uppercase label only for attention states: `APPROVE`, `INPUT`, `FAILED`, `DONE`. The header shows the label as a chip (10 % hue fill, hue text).
- **Sidebar, cards, header:** 6 pt card radius; dense 8 × 6 padding. Selection is a 2 pt accent bar plus a 5 % fill, with no stroke. Section headers are mono uppercase. The header band is `#1B1C21` with a hairline.
- **Copy (terse, factual):** "No conversations · Add Project ⌘O" · "Start failed: claude not found in PATH" · "Turn complete · 2m ago"
- **Changes vs today:** card layout (labels on cards, accent bar instead of fill), mono metadata, header band, square pips, accent-coloured chase. **Cost:** medium to high (card layout, header, indicator geometry and their UI tests). **Risk:** mono metadata competes with the terminal's own mono text, and the result may feel colder and less "theirs". Changes DESIGN §2.4 (card) and §4 (shape), and pre-empts the open navbar decision → **user decision**.

## 4. Recommendation

**A · Night Fleece as the system, with two optional borrowings: B's failure diamond and C's solid header band (as the answer to the navbar item).**

Reasons:
- A is the only direction where window, accent and app icon share one hue family (indigo glass, periwinkle fleece), so the mark the user chose stays the centre of the identity.
- Contract §3 fixes design and icons. A codifies rather than repaints. Its only colour change fixes a measured contrast gap.
- The 5 Oct feedback is mostly about solidity and consistency ("simple points shouldn't stumble", "high-end"), not about hue. A wired accent, accessible text tiers and one written voice deliver that at the lowest cost and resource risk.
- The diamond closes a real accessibility gap: today attention, unviewed and failure differ only by colour. C's header band is the most concrete proposal on the table for the deferred navbar question. Both can be adopted independently.

## 5. Decisions for the user

1. Direction: A, B, C, or A with borrowings (recommended).
2. Unviewed finish colour: blue `#5C8CFF` (today) or the brand periwinkle (B).
3. Failure mark: dot (today) or diamond (B), for colour-independent recognition.
4. Header / navbar (5 Oct item 6, still open): transparent (A), hairline (B) or solid band with status chip (C).
5. Status words on cards: none (today, a11y label only) or attention states only (C).
6. Metadata digits: proportional (today), tabular SF Pro, or SF Mono (C).
7. Weaving metaphor in empty-state copy (B): yes or no.
8. Settings window forced dark like the main window (all directions assume yes; it is the only unforced surface today).
9. Loom mark in the empty catalog state at 48 pt (all directions propose it).

## 6. How this becomes the design system

Once a direction is chosen:

1. **Tokens live in one Swift source:** `Sources/LoomCatalogUI/LoomTheme.swift`, which replaces `CatalogTheme.swift`. It has grouped namespaces `Surface`, `Text`, `Accent`, `Status`, `Radius`, `Space`, `Type`, `Motion`. Terminal colours stay in `Sources/LoomTerminal/TerminalTheme.swift`, because `LoomTerminal` sits below `LoomCatalogUI` and cannot import it. `LoomTheme.Surface.panel` reads from it, as `CatalogTheme.panel` does today. Views use no literal `Color(red:…)`, no `.system(size:)` and no radius outside these two files. The dead `accent` and the duplicate `sidebarWidthRange` (S-B) go away in the same change.
2. **Rules live in `design/DESIGN.md`:** a new "Identity" section holds §2 of this proposal plus the chosen column of §3.1. §3 colours and §4 status language get updated to the chosen values, and the §5 open item closes. This proposal file then becomes history.
3. **Every new feature checks against it** before review: only theme tokens are used; status goes through `IndicatorView`; copy follows the voice rules; any persistent animation is a gated layer animation; Reduce Transparency is handled; text reaches the contrast tier for its role. Two cheap guards make this durable: a unit test that asserts the text-tier and status contrast ratios against the surfaces (the tokens are data), and a `git grep 'Color(red:' Sources/LoomCatalogUI` check that only matches the theme file.
