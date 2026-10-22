#!/bin/zsh
# Makes Sphyrna's app icon, Rising (design/DESIGN.md §6 Name and marks, D-77), into assets/icon/ from the glyph layer
# in design/identity/icon-foreground.png. A dev script: it needs Xcode (actool, Icon Composer's ictool, iconutil).
# Its outputs are committed, so the build scripts (package-dev-app.sh, release/build-loom.sh) and the promoted loom
# tree only copy them and never need Xcode:
#   assets/icon/Sphyrna.icon   the Icon Composer document: two layers, the black ground (the document's fill) and
#                              the glyphs, so that macOS makes the dark, clear and tinted versions
#   assets/icon/Assets.car     the compiled icon (CFBundleIconName Sphyrna), what macOS 26 and later draw
#   assets/icon/Sphyrna.icns   the default (light) rendition flattened, 16 to 1024 pt (CFBundleIconFile Sphyrna)
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
glyphs="$root/design/identity/icon-foreground.png"
[[ -f $glyphs ]] || { echo "Missing glyph layer: $glyphs" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/loom-app-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The document. The ground is the fill (black); the glyphs are one layer, opaque (no translucency) so that the
# default rendition keeps the glyphs' own white; macOS's clear and tinted versions still apply.
doc="$work/$name.icon"
mkdir -p "$doc/Assets"
cp "$glyphs" "$doc/Assets/glyphs.png"
cat > "$doc/icon.json" <<'JSON'
{
  "fill" : {
    "solid" : "srgb:0.00000,0.00000,0.00000,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "glyphs.png",
          "name" : "glyphs"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
JSON

# The compiled icon. actool names the icon after the document and reports both Info.plist keys.
mkdir -p "$work/car"
xcrun actool --compile "$work/car" --platform macosx --minimum-deployment-target 27.0 --app-icon "$name" \
  --output-partial-info-plist "$work/car/partial.plist" --output-format human-readable-text --errors --warnings \
  "$doc" >/dev/null
[[ -f $work/car/Assets.car ]] || { echo "actool made no Assets.car" >&2; exit 1; }
[[ $(plutil -extract CFBundleIconName raw "$work/car/partial.plist") == "$name" ]] \
  || { echo "actool did not name the icon $name" >&2; exit 1; }

# The flattened icon: the default rendition at every size an .icns holds.
render() { # <rendition> <pixels> <file>
  "$ictool" "$doc" --export-image --output-file "$3" --platform macOS --rendition "$1" \
    --width "$2" --height "$2" --scale 1 >/dev/null
  [[ -f $3 ]] || { echo "ictool did not render $1 at $2" >&2; exit 1; }
}
set_dir="$work/$name.iconset"
mkdir -p "$set_dir"
for points in 16 32 128 256 512; do
  render Default $points "$set_dir/icon_${points}x${points}.png"
  render Default $(( points * 2 )) "$set_dir/icon_${points}x${points}@2x.png"
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
