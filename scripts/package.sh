#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/product-identity.sh"
APP_NAME="$SPREKR_PRODUCT_NAME"
BUNDLE_IDENTIFIER="$SPREKR_BUNDLE_IDENTIFIER"
DEVELOPMENT_BUNDLE_IDENTIFIER="$SPREKR_DEVELOPMENT_BUNDLE_IDENTIFIER"
APP=""
STAGING=""

usage() {
  cat <<'EOF'
Usage:
  scripts/package.sh [--app <path-to-signed-or-development-app>]

Without --app, this builds the local ad-hoc development bundle. The resulting
DMG is named development-adhoc and is only a local verification artifact, never
an official download.
EOF
}

fail() {
  print -u2 "error: $*"
  exit 1
}

cleanup() {
  if [[ -n "$STAGING" && -d "$STAGING" ]]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT

while (( $# )); do
  case "$1" in
    --app)
      [[ -n "${2:-}" ]] || fail "--app requires a bundle path."
      APP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown option: $1"
      ;;
  esac
done

if [[ -z "$APP" ]]; then
  APP="$($ROOT/scripts/build-app.sh release)"
fi
[[ -d "$APP" ]] || fail "App bundle does not exist: $APP"
[[ -f "$APP/Contents/Info.plist" ]] || fail "App bundle is missing Info.plist."

identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" || fail "Could not read the app bundle identifier."
[[ "$identifier" == "$BUNDLE_IDENTIFIER" || "$identifier" == "$DEVELOPMENT_BUNDLE_IDENTIFIER" ]] \
  || fail "Expected a Sprekr source or development bundle identifier, found $identifier."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" || fail "Could not read the app version."
[[ -n "$version" ]] || fail "App bundle has no marketing version."

architectures="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")" || fail "Could not inspect the app architecture."
[[ " $architectures " == *" arm64 "* ]] || fail "Packaging requires an arm64 app (found: $architectures)."
codesign --verify --deep --strict --verbose=2 "$APP"

DIST="$ROOT/dist"
DMG="$DIST/Sprekr-$version-arm64-development-adhoc.dmg"
mkdir -p "$DIST"
STAGING="$(mktemp -d "$DIST/.sprekr-staging.XXXXXX")"
ditto "$APP" "$STAGING/$APP_NAME.app"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

(
  cd "$DIST"
  shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256"
)

print "$DMG"
