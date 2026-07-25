#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/product-identity.sh"
source "$ROOT/scripts/sprekr-app-inventory.sh"
APP_NAME="$SPREKR_PRODUCT_NAME"
LEGACY_APP_NAME="$SPREKR_LEGACY_APPLICATION_NAME"
BUNDLE_IDENTIFIER="$SPREKR_BUNDLE_IDENTIFIER"
DESTINATION="${SPREKR_INSTALL_DIR:-${KLIM_TALKS_INSTALL_DIR:-/Applications}}"
AUDIO_INPUT_REQUIREMENT='=entitlement["com.apple.security.device.audio-input"]'
LAUNCH_AFTER_INSTALL=1
SOURCE_REQUESTED=0
CLEANUP_STALE_APPS=1
REMOVE_OTHER_INSTALLS=0
STAGED_APP=""
BACKUP_APP=""
LEGACY_BACKUP_APP=""

usage() {
  cat <<'EOF'
Usage:
  scripts/install.sh --source [--destination <directory>] [--no-launch]
                     [--no-cleanup-stale-apps] [--remove-other-installs]

Sprekr is source-only. This command creates or reuses one certificate-bound
local signing identity in the login Keychain, builds with hardened runtime, and
installs the verified app without sudo. Release artifacts, DMGs, Gatekeeper
bypasses, and environment-supplied download URLs are intentionally unsupported.

After a successful install, --cleanup-stale-apps (default on) removes repo
build/debug and build/release Sprekr.app bundles so they cannot create a second
Accessibility/Microphone row under com.klimtalks.app.development. Ad-hoc or
development copies outside the destination are also removed. A second
certificate-bound install elsewhere is only removed with --remove-other-installs.
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
    --no-cleanup-stale-apps)
      CLEANUP_STALE_APPS=0
      shift
      ;;
    --cleanup-stale-apps)
      CLEANUP_STALE_APPS=1
      shift
      ;;
    --remove-other-installs)
      REMOVE_OTHER_INSTALLS=1
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
  cleanup_stale_apps "$target"
  if (( LAUNCH_AFTER_INSTALL )) && ! open "$target"; then
    print -u2 "warning: Sprekr was installed successfully but macOS did not open it. Open $target normally when ready."
  fi
}

# Removes repo build apps and safe stale copies so System Settings does not keep
# showing two Sprekr rows (production vs .development). Never edits TCC.
cleanup_stale_apps() {
  local installed="$1"
  local installed_resolved="${installed:A}"
  local app resolved root_resolved="${ROOT:A}"

  print "Scanning for other $APP_NAME / $LEGACY_APP_NAME app bundles…"
  local found=0
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    resolved="${app:A}"
    [[ "$resolved" == "$installed_resolved" ]] && continue
    found=1
    print "  $(sprekr_describe_app_line "$app")"
  done < <(sprekr_enumerate_candidate_apps)

  if (( found == 0 )); then
    print "No other $APP_NAME app bundles found."
    return 0
  fi

  if (( CLEANUP_STALE_APPS == 0 )); then
    print -u2 "warning: Leaving other app bundles in place (--no-cleanup-stale-apps)."
    print -u2 "warning: Enable only the installed app in Accessibility/Microphone: $installed"
    return 0
  fi

  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    resolved="${app:A}"
    [[ "$resolved" == "$installed_resolved" ]] && continue

    # Repo build outputs always create a second TCC client under .development.
    if [[ "$resolved" == "$root_resolved/build/debug/$APP_NAME.app" \
       || "$resolved" == "$root_resolved/build/release/$APP_NAME.app" ]]; then
      if app_is_running "$app"; then
        print -u2 "warning: Quit the development build at $app before it can be removed."
        continue
      fi
      rm -rf "$app"
      print "Removed build artifact: $app"
      continue
    fi

    if sprekr_app_is_development_identity "$app"; then
      if app_is_running "$app"; then
        print -u2 "warning: Quit the development/ad-hoc app at $app before it can be removed."
        continue
      fi
      rm -rf "$app"
      print "Removed development/ad-hoc app: $app"
      continue
    fi

    if (( REMOVE_OTHER_INSTALLS )); then
      if app_is_running "$app"; then
        fail "Quit ${app:t:r} at $app before --remove-other-installs can delete it."
      fi
      rm -rf "$app"
      print "Removed other install (--remove-other-installs): $app"
      continue
    fi

    print -u2 "warning: Leaving certificate-bound app at $app"
    print -u2 "warning: Re-run with --remove-other-installs to delete it, or enable only $installed in Accessibility."
  done < <(sprekr_enumerate_candidate_apps)

  # Drop Dock tiles that still point at deleted build-tree / .development apps.
  if [[ -x "$ROOT/scripts/cleanup-stale-dock-pins.py" ]] || [[ -f "$ROOT/scripts/cleanup-stale-dock-pins.py" ]]; then
    /usr/bin/python3 "$ROOT/scripts/cleanup-stale-dock-pins.py" \
      || print -u2 "warning: Could not refresh Dock pins; remove any leftover Sprekr icon manually."
  fi
}

fingerprint="$($ROOT/scripts/local-signing-identity.sh ensure)"
print -r -- "$fingerprint" | /usr/bin/grep -Eq '^[0-9A-F]{40}$' \
  || fail "The signing helper did not return a valid identity."
source_app="$($ROOT/scripts/build-app.sh release --signing-identity "$fingerprint")"
validate_bundle "$source_app" "$fingerprint"
copy_and_activate "$source_app" "$fingerprint"
