#!/bin/zsh
set -u

ROOT="${0:A:h:h}"
source "$ROOT/scripts/product-identity.sh"
APP_NAME="$SPREKR_PRODUCT_NAME"
LEGACY_APP_NAME="$SPREKR_LEGACY_APPLICATION_NAME"
DESTINATION="${SPREKR_INSTALL_DIR:-${KLIM_TALKS_INSTALL_DIR:-/Applications}}"
APP="$DESTINATION/$APP_NAME.app"
LEGACY_APP="$DESTINATION/$LEGACY_APP_NAME.app"
DATA="$HOME/Library/Application Support/$SPREKR_LEGACY_APPLICATION_SUPPORT_NAME"
MODEL_ROOT="$DATA/Models"
MANIFEST="$ROOT/Sources/SprekrCore/Resources/ParakeetV3ModelManifest.json"
AUDIO_INPUT_REQUIREMENT='=entitlement["com.apple.security.device.audio-input"]'
FAILURES=0

ok() { print "[ok] $*"; }
warn() { print "[warn] $*"; }
fail() { print "[fail] $*"; FAILURES=$((FAILURES + 1)); }

print "Sprekr doctor (read-only; no transcript, audio, clipboard, or field content is inspected)"

architecture="$(uname -m 2>/dev/null || true)"
[[ "$architecture" == "arm64" ]] && ok "Architecture: Apple silicon" || fail "Architecture: $architecture (arm64 required)"

macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
macos_major="${macos_version%%.*}"
[[ "$macos_major" == <-> && "$macos_major" -ge 14 ]] \
  && ok "macOS: $macos_version" || fail "macOS 14+ required (found ${macos_version:-unknown})"

swift_version="$(swift --version 2>/dev/null | head -1 || true)"
if print -r -- "$swift_version" | /usr/bin/grep -Eq 'Swift version ([6-9]|[1-9][0-9])\.'; then
  ok "Swift toolchain: ${swift_version#Apple }"
else
  fail "Swift 6+ toolchain not found"
fi

available_kb="$(df -Pk "$ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }')"
if [[ "$available_kb" == <-> && "$available_kb" -ge 1048576 ]]; then
  ok "Free space: at least 1 GiB"
else
  fail "Free space: less than 1 GiB or unavailable"
fi

if [[ -d "$APP" && -d "$LEGACY_APP" ]]; then
  warn "Installed app: both $APP_NAME.app and legacy $LEGACY_APP_NAME.app exist; quit both before the next source migration"
elif [[ ! -d "$APP" && -d "$LEGACY_APP" ]]; then
  APP="$LEGACY_APP"
  warn "Installed app: legacy $LEGACY_APP_NAME.app name found; the next source install will migrate it to $APP_NAME.app"
fi

if [[ -d "$APP" ]]; then
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    signature="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
    requirement="$(codesign -d -r- "$APP" 2>&1 || true)"
    if [[ "$signature" == *runtime* && "$requirement" == *'certificate leaf = H'* ]]; then
      if codesign --verify -R "$AUDIO_INPUT_REQUIREMENT" "$APP" >/dev/null 2>&1; then
        ok "Installed app: v${version:-unknown}, certificate-bound hardened-runtime source build with audio input"
      else
        fail "Installed app: hardened runtime is missing the required audio-input entitlement"
      fi
    else
      fail "Installed app: signature is not certificate-bound with hardened runtime"
    fi
  else
    fail "Installed app: code signature verification failed"
  fi
  [[ "$identifier" == "$SPREKR_BUNDLE_IDENTIFIER" ]] || fail "Installed app: unexpected bundle identifier"
else
  warn "Installed app: not present (source installation has not been run)"
fi

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || true
}

if [[ -d "$DATA" ]]; then
  [[ "$(mode_of "$DATA")" == "700" ]] && ok "Data directory permissions: 0700" \
    || fail "Data directory permissions are not 0700"
  for store in "$DATA/history.enc" "$DATA/dictionary.enc" "$DATA/source-signing-identity.sha1"; do
    [[ -e "$store" ]] || continue
    [[ "$(mode_of "$store")" == "600" ]] || fail "A private Sprekr data file is not mode 0600"
  done
else
  warn "Local data directory: not created yet"
fi

if [[ -f "$MANIFEST" ]]; then
  revision="$(plutil -extract revision raw "$MANIFEST" 2>/dev/null || true)"
  local_directory="$(plutil -extract localDirectory raw "$MANIFEST" 2>/dev/null || true)"
  model="$MODEL_ROOT/$local_directory"
  if [[ -d "$model" ]]; then
    index=0
    model_failed=0
    expected_file_count="$(plutil -extract files raw "$MANIFEST" 2>/dev/null || true)"
    while relative_path="$(plutil -extract "files.$index.path" raw "$MANIFEST" 2>/dev/null)"; do
      expected_size="$(plutil -extract "files.$index.byteCount" raw "$MANIFEST" 2>/dev/null)"
      expected_hash="$(plutil -extract "files.$index.sha256" raw "$MANIFEST" 2>/dev/null)"
      file="$model/$relative_path"
      if [[ ! -f "$file" || "$(stat -f '%z' "$file" 2>/dev/null)" != "$expected_size" ]]; then
        model_failed=1
        break
      fi
      actual_hash="$(shasum -a 256 "$file" 2>/dev/null | awk '{ print $1 }')"
      if [[ "$actual_hash" != "$expected_hash" ]]; then
        model_failed=1
        break
      fi
      index=$((index + 1))
    done
    (( index == expected_file_count && model_failed == 0 )) \
      && ok "Speech model: $index files match pinned revision ${revision[1,12]}…" \
      || fail "Speech model: integrity check failed (content was not displayed)"
  else
    warn "Speech model: not installed"
  fi
else
  fail "Pinned model manifest is missing"
fi

if (( FAILURES > 0 )); then
  print "Doctor found $FAILURES blocking issue(s)."
  exit 1
fi
print "Doctor found no blocking issue."
