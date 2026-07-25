#!/bin/zsh
# Shared helpers for locating Sprekr / Klim Talks app bundles across common
# install and build paths. Sourced by install.sh and doctor.sh. Never edits TCC.

sprekr_app_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

sprekr_app_is_adhoc() {
  local details
  details="$(codesign -d --verbose=4 "$1" 2>&1 || true)"
  print -r -- "$details" | /usr/bin/grep -q 'Signature=adhoc'
}

sprekr_app_is_development_identity() {
  local identifier
  identifier="$(sprekr_app_bundle_id "$1")"
  [[ "$identifier" == "$SPREKR_DEVELOPMENT_BUNDLE_IDENTIFIER" ]] || sprekr_app_is_adhoc "$1"
}

sprekr_app_signature_kind() {
  if sprekr_app_is_adhoc "$1"; then
    print "ad-hoc"
  elif codesign -d -r- "$1" 2>&1 | /usr/bin/grep -q 'certificate leaf = H'; then
    print "certificate-bound"
  else
    print "other"
  fi
}

# Prints absolute app paths, one per line. Skips missing paths. Deduplicates by
# resolved absolute path (:A is zsh-native; avoids PATH-dependent dirname).
sprekr_enumerate_candidate_apps() {
  local -a candidates=()
  local path resolved
  candidates=(
    "/Applications/${SPREKR_PRODUCT_NAME}.app"
    "/Applications/${SPREKR_LEGACY_APPLICATION_NAME}.app"
    "${HOME}/Applications/${SPREKR_PRODUCT_NAME}.app"
    "${HOME}/Applications/${SPREKR_LEGACY_APPLICATION_NAME}.app"
    "${ROOT}/build/debug/${SPREKR_PRODUCT_NAME}.app"
    "${ROOT}/build/release/${SPREKR_PRODUCT_NAME}.app"
  )
  local -A seen=()
  for path in "${candidates[@]}"; do
    [[ -d "$path" || -L "$path" ]] || continue
    resolved="${path:A}"
    [[ -n "${seen[$resolved]:-}" ]] && continue
    seen[$resolved]=1
    print -r -- "$resolved"
  done
}

sprekr_describe_app_line() {
  local app="$1"
  local identifier kind
  identifier="$(sprekr_app_bundle_id "$app")"
  kind="$(sprekr_app_signature_kind "$app")"
  print -r -- "$app  (id=${identifier:-unknown}, signature=${kind})"
}
