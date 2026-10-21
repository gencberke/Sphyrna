# UD — design preview of the new surfaces

Stage [U](../STAGE-U.md) · wave 1 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice) (no build needed).

## Goal

Before any UI code: one static HTML page that shows the three new surfaces at real size in identity A, with the states that matter, so the planner-reviewer can fix the design and the user can review it at the end. The planner-reviewer has design authority for these new surfaces within identity A (the user's run prompt); existing design rules do not change.

## Inputs

- Identity A tokens and rules: `design/IDENTITY-PROPOSAL.md` §2 and §3.1 column A; reuse the CSS custom properties of `design/identity-preview.html` (`.dir-a` block) so values match exactly. Current layout and sizes: `design/DESIGN.md` §2–§4, `design/UI-MAP.md` (sidebar header 52 pt, search 30 pt, footer 38 pt, chrome buttons 26×24 radius 6, cards radius 10, panel inset 8, radius 10, terminal inset 6, detail header row 36 + 16).
- References: `design/references/t3-code-usage-reference.png` (the usage page the user likes; Loom's must be lighter and usage-first, cost secondary and labelled estimate) and `design/references/layout-guidance.jpg` ("tabs" above main content; "bottom bar" becomes the compact footer inside the sidebar; no left rail, no right sidebar).
- Data available (no limits): tokens by type (input, output, cache write 5m/1h, cache read), per day, per model, sessions, cache share, an approximate 5-hour activity window, est. cost from a static price table with an "as of" date. Claude only; layout provider-generic so Codex can be added later.

## Deliverable

`design/run1-surfaces-preview.html`, self-contained (no network), in the style of `identity-preview.html`, showing:

1. **Sidebar footer bar** (inside the sidebar, at its bottom, full sidebar width 300 pt and at the 220 pt minimum): `+` menu button left, compact usage chip middle, gear right. Two chip variants to choose from, e.g. (a) "Today 1.2M tok · ~$3.10" text-only, (b) a tiny 5-hour activity meter plus today's tokens. States: indexing (first scan), no data, normal, a long value truncated. Hover state for the chip. Tooltip text written out.
2. **Settings window** (dark, ~680×520): top section switcher (General · Usage · About) or a slim left list — pick one and say why. General: terminal font size (11–20) with the existing caption. Usage (default view when opened from the chip): period control (24 h · 7 d · 30 d · 90 d), headline total tokens with the est. cost secondary and the label "API-equivalent estimate — subscriptions are not billed per token", totals row (input, output, cache write, cache read, cache share), daily bars (tokens), per-model table (model, tokens, share, est. cost, "—" for unknown models), the 5-hour activity window labelled "approximate", "Updated <time>" and "Prices as of <date>". About: version, data folder. Empty and indexing states.
3. **Conversation tab strip** inside the detail panel between the header row and the terminal: hidden with fewer than two tabs; each tab shows the status indicator (identity status language: chase/dots, `IndicatorView` look), title (truncated), close on hover; active, inactive, transient (selected but not pinned — e.g. italic title or no close until pinned, say which), attention and failure states; overflow behaviour with 8 tabs at 780 pt window width. Strip height and paddings on the 4 pt grid.
4. A short rationale section: what was taken from the references and what was left out (lightness, no limits, cost secondary), and the open choices with your recommendation.

Copy follows identity §2 (sentence case for labels and messages, no exclamation marks).

## Scope

Write only `design/run1-surfaces-preview.html`. Do not edit DESIGN.md, UI-MAP.md or any code.

## Done when

The page opens in a browser (verify by loading it in the built-in browser tools if available, or check it is well-formed), every element above is present with real sizes and identity A tokens, and the report lists the variants and recommended picks.
