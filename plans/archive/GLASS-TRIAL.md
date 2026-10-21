# Liquid Glass trial (12 Oct 2026)

Goal: the user wants a Liquid Glass look without losing much performance; the app reads as matte today.

Why it is matte: only the sidebar is glass (`NSVisualEffectView` `.sidebar`, behind-window) and it carries the dark tint at 0.86 (`sidebarTintOpacity`), chosen on 5 Oct so a blue wallpaper does not glow through (D-10, DESIGN §1 item 2). The panel and terminal are opaque by design. No performance reason. The CP5 GPU matrix ([data](experiments/cp5-final-runscope-gpu.json), one trial per cell) showed WindowServer coalition GPU time equal within noise for glass and opaque (idle 733 vs 756 ms/s, stream 742 vs 777 ms/s); the device-total modeled power differed (idle 1.55 vs 0.90 W) but is whole-device and single-trial.

Styles (`SidebarGlassStyle`, `SidebarBackground.swift`; a normal launch keeps `vibrancy`; tokens in `LoomTheme.Surface`):

| Style | Drawing |
| --- | --- |
| `vibrancy` | today: `.sidebar` material under the sidebar tone at 0.86 |
| `vibrancy-light` | the same material under the tone at 0.6 |
| `liquid` | `NSGlassEffectView` regular, tinted with the sidebar tone at 0.55 |
| `liquid-clear` | `NSGlassEffectView` clear, tint 0.35 |

Captures: `scripts/perf/glass_variants.py` (fake providers, no model turns; the window comes to the front for about half a minute because a window of an app launched with `open -g` could not be captured). First run 12 Oct: shots in `Loom-Dev/probe/runs/glass-variants-20261012T112945/` (a dark window was behind Loom, so the difference reads smaller than over a desktop).

Next: the user picks one or two styles (live, over their own desktop); then on an idle Mac `scripts/cp5-gpu-attribution.py --glass <style>` for `vibrancy` and the candidates, idle1 and stream1, visible, 60 s each with the 90 s cooldown (about 5 min per style); the chosen style becomes the default only if its WindowServer GPU time stays within the noise of `vibrancy`. A further step, if the user wants more than the background: a floating inset sidebar with rounded corners and glass controls.

## Outcome (D-44)

The user looked at the styles live over their own desktop and picked `vibrancy-light`. It uses the same material and blur as before, only the tint is lower, so no GPU measurement was run (no new drawing path). The trial styles, the `glass:` evidence command, the harness `--glass` option and `glass_variants.py` were removed again; `sidebarTintOpacity` is 0.6.

Contrast over a pure white window behind the sidebar (captures of the trial package, sidebar area without content, brightest sample): tint 0.86 → luminance 0.0115 (primary text 12.6:1, secondary about 4.8:1); tint 0.6 → 0.0284 (primary 9.9:1, secondary about 3.7:1). The dark material passes 0.38-0.51 of white per channel; `LoomThemeTests` now model the lightest backdrop as 0.5 gray and hold primary at AAA and secondary at 3:1 there.

Release 0.3.3, installed 12 Oct 2026: tag `release/0.3.3` → loom-dev `87487b5`; loom `611bc29` / `v0.3.3` (238 files); `/Applications/Loom.app` built and swapped by `build.sh` (Loom was not running). Checked: deep-strict signature, version 0.3.3, `CFBundleVersion` `611bc29`, no development evidence strings. Before the tag: LoomCatalogUI tests 280 passed (window tests skipped), the staged release tree built, `scripts/check.sh` passed. Not run: the full release suite, an isolated launch of the installed app.
