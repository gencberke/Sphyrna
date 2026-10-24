# Sphyrna's app icon (D-97)

The hammerhead seen from above, drawn by the art engine (`design/reference-src/shared/engine.js`, `iconart.js`). It is filled solid near-white and climbs to the left at Rising's angle, on a deep ink-blue ground. It ships as two Icon Composer layers, so that macOS makes the dark, clear and tinted versions:

- **The ground** is the document's fill: a gradient from `#1D2445` to `#0B0E1D`, top to bottom. It lives in `icon.json`; `ground-1024.png` shows it as a flat layer.
- **The figure** is `figure-1024.png`, drawn by `layers.html`. The pose is `POSE` there: the heading and bend of `ICON_POSES.rising`, the hammer at 1.3 times its art size, a 22 px stroke, and the outline's box at 0.76 of the square.

## Rebuild

```sh
design/identity/icon/draw.sh   # layers.html -> figure-1024.png, ground-1024.png (headless Chrome)
scripts/make-app-icon.sh       # -> assets/icon/{Sphyrna.icon, Assets.car, Sphyrna.icns}
scripts/make-app-icon.sh --renders <dir>   # also every rendition at 512 px, to look at
```

`draw.sh` needs Google Chrome. It runs headless with a throwaway profile and no network. `make-app-icon.sh` needs Xcode (Icon Composer's `ictool`, `actool`, `iconutil`). Both write only their own outputs.
