#!/bin/zsh
# Makes Sphyrna's app icon, the hammerhead seen from above (design/DESIGN.md §6 Name and marks, D-97), into
# assets/icon/ from its sources in design/identity/icon/: the figure layer (figure-1024.png, drawn by layers.html
# through draw.sh) and the document's icon.json, whose fill is the deep ink-blue ground (the gradient that
# ground-1024.png shows). A dev script: it needs Xcode (actool, Icon Composer's ictool, iconutil).
# Its outputs are committed, so the build scripts (package-dev-app.sh, release/build-loom.sh) and the promoted loom
# tree only copy them and never need Xcode:
#   assets/icon/Sphyrna.icon   the Icon Composer document: two layers, the ink-blue ground (the document's gradient
#                              fill) and the figure, so that macOS makes the dark, clear and tinted versions
#   assets/icon/Assets.car     the compiled icon (CFBundleIconName Sphyrna), what macOS 26 and later draw
#   assets/icon/Sphyrna.icns   the default (light) rendition flattened, 16 to 1024 pt (CFBundleIconFile Sphyrna), on
#                              the system's icon grid: the body 824 of 1,024, centred, as system apps' .icns are
# Usage: scripts/make-app-icon.sh [--renders <dir>]
#   --renders  also writes every rendition (Default, Dark, ClearLight, ClearDark, TintedLight, TintedDark) at 512 px
set -euo pipefail

root=${0:A:h:h}
renders=
while (( $# > 0 )); do
  case $1 in
    --renders) (( $# >= 2 )) || { echo "--renders needs a directory" >&2; exit 2; }; renders=${2:a}; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

developer=$(xcode-select -p)
ictool="$developer/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x $ictool ]] || { echo "Icon Composer's ictool is missing: $ictool (needs Xcode 26 or later)" >&2; exit 1; }
xcrun --find actool >/dev/null

name=Sphyrna
out="$root/assets/icon"
src="$root/design/identity/icon"
for file in figure-1024.png icon.json; do
  [[ -f $src/$file ]] || { echo "Missing icon source: $src/$file (see design/identity/icon/README.md)" >&2; exit 1; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/loom-app-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The document. The ground is the fill (icon.json); the figure is one layer, opaque (no translucency) so that the
# default rendition keeps the figure's own white; macOS's clear and tinted versions still apply.
doc="$work/$name.icon"
mkdir -p "$doc/Assets"
cp "$src/figure-1024.png" "$doc/Assets/figure.png"
cp "$src/icon.json" "$doc/icon.json"

# The compiled icon. actool names the icon after the document and reports both Info.plist keys.
mkdir -p "$work/car"
xcrun actool --compile "$work/car" --platform macosx --minimum-deployment-target 27.0 --app-icon "$name" \
  --output-partial-info-plist "$work/car/partial.plist" --output-format human-readable-text --errors --warnings \
  "$doc" >/dev/null
[[ -f $work/car/Assets.car ]] || { echo "actool made no Assets.car" >&2; exit 1; }
[[ $(plutil -extract CFBundleIconName raw "$work/car/partial.plist") == "$name" ]] \
  || { echo "actool did not name the icon $name" >&2; exit 1; }

# The flattened icon: the default rendition at every size an .icns holds. ictool fills the whole tile with the
# squircle, while an .icns carries the system's icon grid (the body 824 of 1,024, centred, with the margin clear), so
# each size is rendered at 824/1024 of the tile and padded, transparent, to the full size.
render() { # <rendition> <pixels> <file>
  "$ictool" "$doc" --export-image --output-file "$3" --platform macOS --rendition "$1" \
    --width "$2" --height "$2" --scale 1 >/dev/null
  [[ -f $3 ]] || { echo "ictool did not render $1 at $2" >&2; exit 1; }
}
on_grid() { # <pixels> <file>
  render Default $(( ($1 * 824 + 512) / 1024 )) "$2"
  sips -p $1 $1 "$2" >/dev/null
}
set_dir="$work/$name.iconset"
mkdir -p "$set_dir"
for points in 16 32 128 256 512; do
  on_grid $points "$set_dir/icon_${points}x${points}.png"
  on_grid $(( points * 2 )) "$set_dir/icon_${points}x${points}@2x.png"
done
iconutil -c icns "$set_dir" -o "$work/$name.icns"

mkdir -p "$out"
rm -rf "$out/$name.icon"
cp -R "$doc" "$out/$name.icon"
cp "$work/car/Assets.car" "$out/Assets.car"
cp "$work/$name.icns" "$out/$name.icns"
echo "Wrote $out/$name.icon, Assets.car and $name.icns"

if [[ -n $renders ]]; then
  mkdir -p "$renders"
  for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    render $rendition 512 "$renders/icon-$rendition.png"
  done
  echo "Wrote the renditions to $renders"
fi
