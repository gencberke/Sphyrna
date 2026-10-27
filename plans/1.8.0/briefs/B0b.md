# B0b: the whole reference in Ink v4

**Goal.** After this slice, `design/reference.html` speaks one design language: Ink v4. Today it holds two:
- B0 drew an "Ink v4" chapter for the surfaces 1.8.0 changes;
- every other chapter is still the v3 reference, with only its tokens switchable.

`@user` (D-106): "v4 ayrı bir tasarım dili. v3 ile iç içe durması hem kafa karıştırı hem yanıltıcı olabilir." Redraw the other
chapters in v4. Remove what v3 alone needed. The landing page follows. This slice is HTML and CSS only.

**Starts after** B0 is integrated on `v2` and the planner has moved the v4 rules into `design/DESIGN.md`.

**Read.**
- `design/DESIGN.md` (the v4 rules at its top, §3 tokens, §6 components) and [DESIGN-V4.md](../DESIGN-V4.md), both as approved
  in D-106.
- The reference's "Ink v4" chapter: `design/reference-src/docs/v4/` (`body.html`, `v4.css`, `v4.js`). Its control family,
  sidebar, session window, status bar, chips, model and effort pickers, Connections, draft and Home are the source for every
  other drawing.
- `design/reference-src/build.py`, `shared/*`, `shell/*`, and each document under `docs/`:
  - foundations;
  - chat;
  - project;
  - settings;
  - review;
  - edges;
  - remora;
  - identity.
- D-100 (Chat frozen, terminal first) and D-102 (the art goes, Remora stays): they decide what is no longer drawn.

**Write set.** `design/reference-src/**`, and the built `design/reference.html` and `design/landing.html`. Not yours: anything
under `Sources/`, `Tests/`, `design/DESIGN.md` and `plans/`.

**Approach.**
1. **One token set.**
   - v4's values become the only ones in `shared/head.css`.
   - Remove the v3 set, the v3/v4 switch in the top bar and the bridge's `ink` state.
   - Remove the Q1–Q6 bar and the drawing of each alternative: the choices are made (D-106).
   - Keep the Ink and Paper switch and the Neutral, Warm and Cool casts.
2. **One chapter order.**
   - The v4 chapter's system sections come first: the rules, the control family, tokens, type and depth.
   - The surfaces follow in the order a user meets them: the sidebar; the session window; the model and the effort; the draft
     and Home; the project page; Settings with Connections; the review surfaces; Remora; the edges; identity.
   - A surface drawn in both places keeps the v4 drawing; the v3 one goes.
   - The nav lists every chapter and fits the page width.
3. **Redraw each remaining chapter** with v4's parts only:
   - the control family's six roles and four heights;
   - fields, switches and segments;
   - the lifted sidebar plane and the session card;
   - the 26 pt status bar instead of the sidebar footer;
   - the ghost chips;
   - cards at elevation 1;
   - popovers, menus and sheets at elevation 3;
   - v4's type, with labels in SF Pro;
   - the periwinkle only for focus and for what is current.

   Keep each surface's layout unless DESIGN.md changes it (DESIGN-V4 §6 "Elsewhere"). No new features: draw what the app has
   or what an approved 1.8.0 brief describes.
4. **What goes:**
   - The Chat face is frozen (D-100). Keep only the turn style that the Agents tab reads in (B5b), as a section of the session
     window chapter. Remove the rest of the chat chapter.
   - Remove any art left after D-102.
   - Remove the v3-only parts: the sidebar footer chip, the old model popover, the old header state pill if v4 replaced it.
     Remove any CSS and script that nothing draws any more.
5. **The landing page** takes the same tokens and windows.
6. **Build** with `python3 design/reference-src/build.py`. Each page stays under 1 MB. Make the build reproducible: today two
   builds of the same sources differ only in the gzip header's time (`build.py`'s `gzip.compress`); pass `mtime=0`.

**Done when.**
- `grep` finds no v3 token block, no `data-ink` switch and no `q1`–`q6` state in `design/reference-src/`.
- Every chapter draws in Ink and Paper with v4's parts, and the nav lists them all. Zero console errors in the page and its
  frames.
- No surface is drawn twice.
- Both pages are under 1 MB, and two builds in a row give identical files.
- Nothing outside the write set changed.

**Checks.**
- `python3 design/reference-src/build.py`, then `git diff --check v2`. Do not run `scripts/check.sh`: no Swift changes.
- Screenshots of every chapter in Ink and Paper into `evidence/r9/b0b/`. Use headless Chrome with a throwaway profile under
  `/private/tmp/loom-real/`, never the user's Chrome and never `screencapture`:
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --user-data-dir=/private/tmp/loom-real/r9-b0b-chrome --hide-scrollbars --window-size=1440,1000 --screenshot=<png> "file://<worktree>/design/reference.html"`.
  For one chapter at a time, `build.py --docs <dir>` writes each document on its own.

**Report extras.**
- The chapter list with its anchors.
- What was removed and why (each item with its decision).
- Any surface whose v4 shape DESIGN.md does not settle, for the planner.
