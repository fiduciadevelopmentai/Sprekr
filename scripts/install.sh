#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/product-identity.sh"
APP_NAME="$SPREKR_PRODUCT_NAME"
LEGACY_APP_NAME="$SPREKR_LEGACY_APPLICATION_NAME"
BUNDLE_IDENTIFIER="$SPREKR_BUNDLE_IDENTIFIER"
DESTINATION="${SPREKR_INSTALL_DIR:-${KLIM_TALKS_INSTALL_DIR:-/Applications}}"
AUDIO_INPUT_REQUIREMENT='=entitlement["com.apple.security.device.audio-input"]'
LAUNCH_AFTER_INSTALL=1
SOURCE_REQUESTED=0
STAGED_APP=""
BACKUP_APP=""
LEGACY_BACKUP_APP=""

usage() {
  cat <<'EOF'
Usage:
  scripts/install.sh --source [--destination <directory>] [--no-launch]

Sprekr is source-only. This command creates or reuses one certificate-bound
local signing identity in the login Keychain, builds with hardened runtime, and
installs the verified app without sudo. Release artifacts, DMGs, Gatekeeper
bypasses, and environment-supplied download URLs are intentionally unsupported.
EOF
}

fail() {
  print -u2 "error: $*"
  exit 1
}

cleanup() {
  if [[ -n "$STAGED_APP" && ( -e "$STAGED_APP" || -L "$STAGED_APP" ) ]]; then
    rm -rf "$STAGED_APP"
  fi
}
trap cleanup EXIT

while (( $# )); do
  case "$1" in
    --source)
      SOURCE_REQUESTED=1
      shift
      ;;
    --destination)
      [[ -n "${2:-}" ]] || fail "--destination requires a value."
      DESTINATION="$2"
      shift 2
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=0
      shift
      ;;
    --artifact|--sha256|--version)
      fail "Artifact installation is disabled. Use install.sh --source from a trusted checkout."
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

(( SOURCE_REQUESTED )) || {
  usage >&2
  fail "Choose --source explicitly."
}
[[ "$(uname -m)" == "arm64" ]] || fail "Sprekr requires an Apple-silicon Mac."
[[ -d "$DESTINATION" ]] || fail "Install destination does not exist: $DESTINATION"
[[ -w "$DESTINATION" ]] \
  || fail "$DESTINATION is not writable. This installer never invokes sudo; choose a writable destination or authorize the operation yourself."

app_is_running() {
  local target_app="$1"
  [[ -d "$target_app" ]] || return 1
  local executable_name executable
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target_app/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "$executable_name" ]] || return 1
  executable="$target_app/Contents/MacOS/$executable_name"
  local command
  while IFS= read -r command; do
    [[ "$command" == *"$executable"* ]] && return 0
  done < <(ps -axo command=)
  return 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

requirement_for() {
  print -r -- "=identifier \"$BUNDLE_IDENTIFIER\" and certificate leaf = H\"$1\""
}

validate_bundle() {
  local app="$1"
  local fingerprint="$2"
  local identifier architectures requirement
  [[ -d "$app" && -f "$app/Contents/Info.plist" ]] || fail "The source build is not a complete app bundle."
  [[ -x "$app/Contents/MacOS/$APP_NAME" ]] || fail "The source build is missing its executable."
  identifier="$(plist_value "$app" CFBundleIdentifier)" || fail "Could not read the bundle identifier."
  [[ "$identifier" == "$BUNDLE_IDENTIFIER" ]] \
    || fail "The installed source build must use bundle identifier $BUNDLE_IDENTIFIER, found $identifier."
  architectures="$(lipo -archs "$app/Contents/MacOS/$APP_NAME")" || fail "Could not inspect app architecture."
  [[ " $architectures " == *" arm64 "* ]] || fail "The source build is not Apple-silicon compatible."
  codesign --verify --deep --strict --verbose=2 "$app"
  requirement="$(requirement_for "$fingerprint")"
  codesign --verify -R "$requirement" "$app" \
    || fail "The source build does not match its certificate-bound designated requirement."
  codesign --verify -R "$AUDIO_INPUT_REQUIREMENT" "$app" >/dev/null 2>&1 \
    || fail "The source build is missing the required audio-input entitlement."
  local signature_details
  signature_details="$(codesign -d --verbose=4 "$app" 2>&1)"
  [[ "$signature_details" == *runtime* ]] || fail "The source build is missing hardened runtime."
}

validate_existing_identity() {
  local target="$1"
  local fingerprint="$2"
  local requirement details
  [[ -e "$target" || -L "$target" ]] || return 0
  app_is_running "$target" \
    && fail "Quit ${target:t:r} from its menu before updating it. The installer will not force-quit the app."

  requirement="$(requirement_for "$fingerprint")"
  if codesign --verify --deep --strict "$target" >/dev/null 2>&1 \
      && codesign --verify -R "$requirement" "$target" >/dev/null 2>&1; then
    return
  fi

  details="$(codesign -d --verbose=4 "$target" 2>&1 || true)"
  if print -r -- "$details" | /usr/bin/grep -q 'Signature=adhoc'; then
    print -u2 "Migrating a legacy ad-hoc installation to the unique local identity. macOS may request permissions once more."
    return
  fi
  fail "The installed app uses a different certificate identity. Refusing an update that could lose TCC or Keychain continuity."
}

copy_and_activate() {
  local source_app="$1"
  local fingerprint="$2"
  local target="$DESTINATION/$APP_NAME.app"
  local legacy_target="$DESTINATION/$LEGACY_APP_NAME.app"
  local nonce="$$-${RANDOM}"
  local had_previous=0

  validate_existing_identity "$target" "$fingerprint"
  validate_existing_identity "$legacy_target" "$fingerprint"
  STAGED_APP="$DESTINATION/.$APP_NAME.app.installing-$nonce"
  BACKUP_APP="$DESTINATION/.$APP_NAME.app.previous-$nonce"
  LEGACY_BACKUP_APP="$DESTINATION/.$LEGACY_APP_NAME.app.previous-$nonce"
  [[ ! -e "$STAGED_APP" && ! -L "$STAGED_APP" ]] || fail "Temporary install path already exists."
  [[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]] || fail "Temporary backup path already exists."
  [[ ! -e "$LEGACY_BACKUP_APP" && ! -L "$LEGACY_BACKUP_APP" ]] || fail "Temporary legacy backup path already exists."

  ditto "$source_app" "$STAGED_APP"
  validate_bundle "$STAGED_APP" "$fingerprint"
  if [[ -e "$target" || -L "$target" ]]; then
    mv "$target" "$BACKUP_APP"
    had_previous=1
  fi
  local had_legacy=0
  if [[ -e "$legacy_target" || -L "$legacy_target" ]]; then
    mv "$legacy_target" "$LEGACY_BACKUP_APP"
    had_legacy=1
  fi
  if ! mv "$STAGED_APP" "$target"; then
    if (( had_previous )) && [[ -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
      mv "$BACKUP_APP" "$target" || print -u2 "warning: The previous app remains at $BACKUP_APP"
    fi
    if (( had_legacy )) && [[ -e "$LEGACY_BACKUP_APP" || -L "$LEGACY_BACKUP_APP" ]]; then
      mv "$LEGACY_BACKUP_APP" "$legacy_target" || print -u2 "warning: The legacy app remains at $LEGACY_BACKUP_APP"
    fi
    fail "Could not activate the verified source build."
  fi
  STAGED_APP=""

  # Validate again at the final bundle path before deleting either backup.
  # Running this check in a subshell lets the install transaction restore the
  # previous visible bundle even though validate_bundle exits on a mismatch.
  if ! (validate_bundle "$target" "$fingerprint"); then
    rm -rf "$target"
    if (( had_previous )) && [[ -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
      mv "$BACKUP_APP" "$target" || print -u2 "warning: The previous app remains at $BACKUP_APP"
    fi
    if (( had_legacy )) && [[ -e "$LEGACY_BACKUP_APP" || -L "$LEGACY_BACKUP_APP" ]]; then
      mv "$LEGACY_BACKUP_APP" "$legacy_target" || print -u2 "warning: The legacy app remains at $LEGACY_BACKUP_APP"
    fi
    fail "The activated source build failed final validation; the previous installation was restored."
  fi

  if (( had_previous )); then
    rm -rf "$BACKUP_APP"
    BACKUP_APP=""
  fi
  if (( had_legacy )); then
    rm -rf "$LEGACY_BACKUP_APP"
    LEGACY_BACKUP_APP=""
    print "Migrated $LEGACY_APP_NAME.app to $APP_NAME.app without changing its bundle identity or local data."
  fi
  print "Installed verified $APP_NAME source build at $target"
  if (( LAUNCH_AFTER_INSTALL )) && ! open "$target"; then
    print -u2 "warning: Sprekr was installed successfully but macOS did not open it. Open $target normally when ready."
  fi
}

fingerprint="$($ROOT/scripts/local-signing-identity.sh ensure)"
print -r -- "$fingerprint" | /usr/bin/grep -Eq '^[0-9A-F]{40}$' \
  || fail "The signing helper did not return a valid identity."
source_app="$($ROOT/scripts/build-app.sh release --signing-identity "$fingerprint")"
validate_bundle "$source_app" "$fingerprint"
copy_and_activate "$source_app" "$fingerprint"
