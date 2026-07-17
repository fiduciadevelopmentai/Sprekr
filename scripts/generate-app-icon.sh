#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Resources/SprekrIcon.svg"
ICONSET="$ROOT/Resources/SprekrIcon.iconset"
ICNS="$ROOT/Resources/SprekrIcon.icns"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sprekr-icon.XXXXXX")"
MASTER="$TEMP_DIR/SprekrIcon.png"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

[[ -f "$SOURCE" ]] || { print -u2 "Missing app-icon source: $SOURCE"; exit 1; }
mkdir -p "$ICONSET"

# The SVG deliberately draws only the rounded dark container. Rendering it
# directly to PNG preserves real alpha in the four outer corners.
sips -s format png "$SOURCE" --out "$MASTER" >/dev/null
[[ "$(sips -g hasAlpha "$MASTER" | awk '/hasAlpha/ { print $2 }')" == "yes" ]] || {
  print -u2 "Rendered app icon lost its alpha channel."
  exit 1
}

render() {
  local pixels="$1"
  local name="$2"
  sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/$name" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ICNS"
print "Generated transparent-corner app icon at $ICNS"
