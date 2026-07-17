#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/product-identity.sh"
APP_NAME="$SPREKR_PRODUCT_NAME"
LEGACY_APP_NAME="$SPREKR_LEGACY_APPLICATION_NAME"
BUNDLE_IDENTIFIER="$SPREKR_BUNDLE_IDENTIFIER"
DESTINATION="${SPREKR_INSTALL_DIR:-${KLIM_TALKS_INSTALL_DIR:-/Applications}}"
APP="$DESTINATION/$APP_NAME.app"
LEGACY_APP="$DESTINATION/$LEGACY_APP_NAME.app"
DATA="$HOME/Library/Application Support/$SPREKR_LEGACY_APPLICATION_SUPPORT_NAME"
MODE="prompt"
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage:
  scripts/uninstall.sh [--keep-data | --purge [--yes]] [--destination <directory>]

The app bundle is always removed. Without an option, the script asks whether to
keep local data. --purge removes Sprekr-owned Application Support data and
models, the app's UserDefaults domain, its two encryption keys in the login
Keychain, and its app-owned launchd login-item registration. --yes is accepted
only with --purge for a deliberately non-interactive full removal.
EOF
}

fail() {
  print -u2 "error: $*"
  exit 1
}

while (( $# )); do
  case "$1" in
    --keep-data)
      [[ "$MODE" == "prompt" ]] || fail "Choose only one data-removal mode."
      MODE="keep"
      shift
      ;;
    --purge)
      [[ "$MODE" == "prompt" ]] || fail "Choose only one data-removal mode."
      MODE="purge"
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --destination)
      [[ -n "${2:-}" ]] || fail "--destination requires a value."
      DESTINATION="$2"
      APP="$DESTINATION/$APP_NAME.app"
      LEGACY_APP="$DESTINATION/$LEGACY_APP_NAME.app"
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

if (( ASSUME_YES != 0 )) && [[ "$MODE" != "purge" ]]; then
  fail "--yes is valid only together with --purge."
fi

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

choose_mode() {
  if [[ "$MODE" != "prompt" ]]; then
    if [[ "$MODE" == "purge" && "$ASSUME_YES" -eq 0 ]]; then
      [[ -t 0 ]] || fail "--purge in a non-interactive session requires --yes."
      print -n "Type REMOVE to delete Sprekr data, models, preferences, encryption keys, and its login item: "
      local confirmation
      read confirmation
      [[ "$confirmation" == "REMOVE" ]] || fail "Full data removal cancelled."
    fi
    return
  fi

  if [[ ! -t 0 ]]; then
    MODE="keep"
    print "Keeping local data in this non-interactive session. Use --purge --yes only after explicit user approval."
    return
  fi

  print -n "Remove local Sprekr history, Dictionary, model, preferences, encryption keys, and login item too? [y/N] "
  local answer
  read answer
  if [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]; then
    MODE="purge"
  else
    MODE="keep"
  fi
}

remove_login_item() {
  local domain="gui/$(id -u)"
  local service="$domain/$BUNDLE_IDENTIFIER"

  if launchctl print "$service" >/dev/null 2>&1; then
    if launchctl bootout "$service" >/dev/null 2>&1; then
      print "Removed the Sprekr launch-at-login registration."
    else
      print -u2 "warning: Could not remove the Sprekr login item automatically. Remove it from System Settings > General > Login Items."
    fi
  else
    print "No active Sprekr launch-at-login registration was found."
  fi
}

remove_keychain_keys() {
  local account
  for account in \
    history.encryption.key history.encryption.key.v2 \
    dictionary.encryption.key dictionary.encryption.key.v2; do
    if security find-generic-password -s "$BUNDLE_IDENTIFIER" -a "$account" >/dev/null 2>&1; then
      if security delete-generic-password -s "$BUNDLE_IDENTIFIER" -a "$account" >/dev/null 2>&1; then
        print "Removed the Sprekr Keychain key: $account"
      else
        print -u2 "warning: Could not remove Keychain key $account. Delete it manually from Keychain Access if it remains."
      fi
    fi
  done
}

choose_mode

if app_is_running "$APP" || app_is_running "$LEGACY_APP"; then
  fail "Quit Sprekr from its menu before uninstalling it. This script will not force-quit your app."
fi

if [[ "$MODE" == "purge" ]]; then
  remove_login_item
fi

if [[ -e "$APP" || -L "$APP" ]]; then
  rm -rf "$APP"
  print "Removed $APP"
else
  print "No installed app was found at $APP"
fi
if [[ -e "$LEGACY_APP" || -L "$LEGACY_APP" ]]; then
  rm -rf "$LEGACY_APP"
  print "Removed legacy app bundle $LEGACY_APP"
fi

if [[ "$MODE" == "purge" ]]; then
  "$ROOT/scripts/local-signing-identity.sh" remove --yes || \
    print -u2 "warning: Could not fully remove the local signing identity. Review it in Keychain Access."
  rm -rf "$DATA"
  print "Removed $DATA"
  defaults delete "$BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true
  print "Removed Sprekr preferences."
  remove_keychain_keys
else
  print "Kept $DATA, Sprekr preferences, Keychain keys, and any login-item setting."
fi
