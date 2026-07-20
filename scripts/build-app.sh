#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/product-identity.sh"
CONFIGURATION="${1:-debug}"
BUILD_ARGS=()
OUTPUT_DIR="$ROOT/build/$CONFIGURATION"
SIGNING_IDENTITY=""
ENTITLEMENTS="$ROOT/App/Sprekr.entitlements"
AUDIO_INPUT_REQUIREMENT='=entitlement["com.apple.security.device.audio-input"]'
PLIST_BUDDY=/usr/libexec/PlistBuddy
shift || true

while (( $# )); do
  case "$1" in
    --signing-identity)
      [[ -n "${2:-}" ]] || { print -u2 "error: --signing-identity requires a SHA-1 fingerprint."; exit 1; }
      SIGNING_IDENTITY="${2:u}"
      shift 2
      ;;
    *)
      print -u2 "Usage: scripts/build-app.sh [debug|release] [--signing-identity <40-hex-SHA1>]"
      exit 1
      ;;
  esac
done

if [[ "$CONFIGURATION" == "release" ]]; then
  BUILD_ARGS=(-c release)
fi
if [[ -n "${SPREKR_SWIFT_SCRATCH_PATH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$SPREKR_SWIFT_SCRATCH_PATH")
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Missing Sprekr hardened-runtime entitlements." >&2
  exit 1
fi
if [[ "$("$PLIST_BUDDY" -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS" 2>/dev/null || true)" != "true" ]]; then
  echo "Sprekr must enable the hardened-runtime audio-input entitlement." >&2
  exit 1
fi
if [[ "$("$PLIST_BUDDY" -c Print "$ENTITLEMENTS" 2>/dev/null | awk '/ = / { count++ } END { print count + 0 }')" != "1" ]]; then
  echo "Sprekr may request only the required audio-input entitlement." >&2
  exit 1
fi

cd "$ROOT"
swift build "${BUILD_ARGS[@]}" --product "$SPREKR_PRODUCT_NAME" >&2

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$OUTPUT_DIR/$SPREKR_PRODUCT_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$SPREKR_PRODUCT_NAME" "$APP/Contents/MacOS/$SPREKR_PRODUCT_NAME"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/$SPREKR_PRODUCT_NAME"
if [[ "$CONFIGURATION" == "release" ]]; then
  strip -S "$APP/Contents/MacOS/$SPREKR_PRODUCT_NAME"
fi

SPREKR_VERSION_VALUE="${SPREKR_VERSION:-${KLIM_TALKS_VERSION:-}}"
SPREKR_BUILD_NUMBER_VALUE="${SPREKR_BUILD_NUMBER:-${KLIM_TALKS_BUILD_NUMBER:-}}"
if [[ -n "$SPREKR_VERSION_VALUE" ]]; then
  "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $SPREKR_VERSION_VALUE" "$APP/Contents/Info.plist"
fi
if [[ -n "$SPREKR_BUILD_NUMBER_VALUE" ]]; then
  "$PLIST_BUDDY" -c "Set :CFBundleVersion $SPREKR_BUILD_NUMBER_VALUE" "$APP/Contents/Info.plist"
fi

CORE_RESOURCE_BUNDLE="$BIN_DIR/Sprekr_SprekrCore.bundle"
if [[ ! -d "$CORE_RESOURCE_BUNDLE" ]]; then
  echo "Missing SprekrCore resource bundle with the pinned model manifest." >&2
  exit 1
fi
cp -R "$CORE_RESOURCE_BUNDLE" "$APP/Contents/Resources/"

if [[ -d "$ROOT/Resources/Fonts" ]]; then
  cp -R "$ROOT/Resources/Fonts/." "$APP/Contents/Resources/"
fi

REQUIRED_FONTS=(
  "Onest-Regular.otf"
  "Onest-Medium.otf"
  "Onest-Bold.otf"
  "CrimsonText-Regular.ttf"
  "Lucide.ttf"
)
for font in "${REQUIRED_FONTS[@]}"; do
  if [[ ! -f "$APP/Contents/Resources/$font" ]]; then
    echo "Missing required bundled font: $font" >&2
    exit 1
  fi
done
if [[ "$(plutil -extract ATSApplicationFontsPath raw "$APP/Contents/Info.plist")" != "." ]]; then
  echo "ATSApplicationFontsPath must expose bundled fonts from Contents/Resources." >&2
  exit 1
fi
if [[ -f "$ROOT/Resources/SprekrIcon.icns" ]]; then
  ICON_MASTER="$ROOT/Resources/SprekrIcon.iconset/icon_512x512@2x.png"
  if [[ ! -f "$ICON_MASTER" ]] || [[ "$(sips -g hasAlpha "$ICON_MASTER" | awk '/hasAlpha/ { print $2 }')" != "yes" ]]; then
    echo "SprekrIcon must contain transparent outer corners. Run scripts/generate-app-icon.sh." >&2
    exit 1
  fi
  cp "$ROOT/Resources/SprekrIcon.icns" "$APP/Contents/Resources/SprekrIcon.icns"
fi
REQUIRED_BRAND_ASSETS=(
  "SprekrMark-transparent.png"
  "FiduciaLogoColored3D.png"
  "SprekrStart.aiff"
  "SprekrCompletion.aiff"
)
for asset in "${REQUIRED_BRAND_ASSETS[@]}"; do
  if [[ ! -f "$ROOT/Resources/$asset" ]]; then
    echo "Missing required brand asset: $asset" >&2
    exit 1
  fi
  cp "$ROOT/Resources/$asset" "$APP/Contents/Resources/$asset"
done
if [[ -d "$ROOT/Resources/Licenses" ]]; then
  mkdir -p "$APP/Contents/Resources/Licenses"
  cp -R "$ROOT/Resources/Licenses/." "$APP/Contents/Resources/Licenses/"
fi
if [[ -f "$ROOT/THIRD_PARTY_NOTICES.md" ]]; then
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  if ! print -r -- "$SIGNING_IDENTITY" | /usr/bin/grep -Eq '^[0-9A-F]{40}$'; then
    echo "The local signing identity must be a 40-character SHA-1 certificate fingerprint." >&2
    exit 1
  fi
  DESIGNATED_REQUIREMENT="=identifier \"$SPREKR_BUNDLE_IDENTIFIER\" and certificate leaf = H\"$SIGNING_IDENTITY\""
  REQUIREMENTS="=designated => ${DESIGNATED_REQUIREMENT#=}"
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
    --entitlements "$ENTITLEMENTS" --requirements "$REQUIREMENTS" "$APP" >/dev/null
  codesign --verify --deep --strict --verbose=2 "$APP"
  codesign --verify -R "$DESIGNATED_REQUIREMENT" "$APP"
else
  # Ad-hoc bundles are isolated under a development bundle identifier, so they
  # cannot impersonate an installed source build for TCC or Keychain access.
  "$PLIST_BUDDY" -c "Set :CFBundleIdentifier $SPREKR_DEVELOPMENT_BUNDLE_IDENTIFIER" "$APP/Contents/Info.plist"
  codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP" >/dev/null
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNATURE_DETAILS" != *runtime* ]]; then
  echo "The app signature is missing hardened runtime." >&2
  exit 1
fi
if ! codesign --verify -R "$AUDIO_INPUT_REQUIREMENT" "$APP" >/dev/null 2>&1; then
  echo "The signed app is missing the required audio-input entitlement." >&2
  exit 1
fi

echo "$APP"
