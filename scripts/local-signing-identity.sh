#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/product-identity.sh"
APP_NAME="$SPREKR_PRODUCT_NAME"
LABEL="$SPREKR_SIGNING_LABEL"
LEGACY_LABEL="$SPREKR_LEGACY_SIGNING_LABEL"
# The old data root and fingerprint file are compatibility anchors. Moving
# either would disconnect existing encrypted stores from their signing key.
DATA_DIR="$HOME/Library/Application Support/$SPREKR_LEGACY_APPLICATION_SUPPORT_NAME"
METADATA="$DATA_DIR/source-signing-identity.sha1"
ACTION="${1:-ensure}"
TEMP_DIR=""
IMPORTED_FINGERPRINT=""

fail() {
  print -u2 "error: $*"
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    find "$TEMP_DIR" -depth -mindepth 1 -delete 2>/dev/null || true
    rmdir "$TEMP_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

login_keychain() {
  local keychain
  keychain="$(security default-keychain -d user \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')"
  [[ -n "$keychain" && -f "$keychain" ]] || fail "The login Keychain could not be located."
  print -r -- "$keychain"
}

valid_fingerprint() {
  print -r -- "$1" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{40}$'
}

identity_is_available() {
  local fingerprint="$1"
  local keychain="$2"
  security find-identity -v -p codesigning "$keychain" 2>/dev/null \
    | /usr/bin/grep -Eiq "[[:space:]]${fingerprint}[[:space:]]"
}

recover_unique_identity() {
  local keychain="$1"
  local matches
  matches="$(security find-identity -v -p codesigning "$keychain" 2>/dev/null \
    | awk -v label="$LABEL" -v legacy="$LEGACY_LABEL" \
        'index($0, "\"" label "\"") || index($0, "\"" legacy "\"") { print $2 }' \
    | sort -u)"
  local count
  count="$(print -r -- "$matches" | awk 'NF { count++ } END { print count + 0 }')"
  (( count == 1 )) || return 1
  print -r -- "$matches" | awk 'NF { print toupper($1); exit }'
}

persist_fingerprint() {
  local fingerprint="$1"
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  umask 077
  print -r -- "$fingerprint" > "$METADATA"
  chmod 600 "$METADATA"
}

ensure_identity() {
  local keychain fingerprint password certificate private_key archive
  keychain="$(login_keychain)"

  if [[ -f "$METADATA" ]]; then
    fingerprint="$(tr -d '[:space:]' < "$METADATA")"
    valid_fingerprint "$fingerprint" || fail "The local signing metadata is invalid. Remove it only after confirming the matching Keychain identity."
    fingerprint="${fingerprint:u}"
    identity_is_available "$fingerprint" "$keychain" \
      || fail "The recorded Sprekr signing identity is missing or not trusted for code signing. Installation stopped without an ad-hoc fallback."
    print -r -- "$fingerprint"
    return
  fi

  if fingerprint="$(recover_unique_identity "$keychain")"; then
    valid_fingerprint "$fingerprint" || fail "The recovered signing identity has an invalid fingerprint."
    persist_fingerprint "$fingerprint"
    print -r -- "$fingerprint"
    return
  fi

  [[ -x /usr/bin/openssl ]] || fail "The macOS OpenSSL compatibility tool is required to create the local signing identity."
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sprekr-signing.XXXXXX")"
  chmod 700 "$TEMP_DIR"
  private_key="$TEMP_DIR/private-key.pem"
  certificate="$TEMP_DIR/certificate.pem"
  archive="$TEMP_DIR/identity.p12"
  password="$(/usr/bin/openssl rand -hex 24)"

  print -u2 "Creating one Sprekr code-signing identity in the login Keychain. macOS may ask for Keychain approval."
  /usr/bin/openssl req -new -newkey rsa:3072 -x509 -sha256 -days 3650 -nodes \
    -subj "/CN=$LABEL/O=Fiducia Development/OU=Local Source Build" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$private_key" -out "$certificate" >/dev/null 2>&1
  fingerprint="$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 \
    | awk -F= '{ gsub(":", "", $2); print toupper($2) }')"
  valid_fingerprint "$fingerprint" || fail "Could not calculate the local certificate fingerprint."

  /usr/bin/openssl pkcs12 -export -name "$LABEL" \
    -inkey "$private_key" -in "$certificate" -out "$archive" \
    -passout "pass:$password" >/dev/null 2>&1
  security import "$archive" -k "$keychain" -P "$password" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  IMPORTED_FINGERPRINT="$fingerprint"

  # Trust is constrained to the code-signing policy in the user domain. The
  # certificate is not installed as a generally trusted root and no admin or
  # system trust settings are changed.
  if ! security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$certificate" >/dev/null; then
    security delete-identity -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    fail "The certificate could not be trusted specifically for local code signing."
  fi
  identity_is_available "$fingerprint" "$keychain" || {
    security remove-trusted-cert "$certificate" >/dev/null 2>&1 || true
    security delete-identity -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
    fail "The new identity is not available to codesign."
  }

  persist_fingerprint "$fingerprint"
  print -r -- "$fingerprint"
}

remove_identity() {
  [[ "${2:-}" == "--yes" ]] || fail "Removing the local signing identity requires: $0 remove --yes"
  local keychain fingerprint certificate
  keychain="$(login_keychain)"
  if [[ -f "$METADATA" ]]; then
    fingerprint="$(tr -d '[:space:]' < "$METADATA")"
  else
    fingerprint="$(recover_unique_identity "$keychain" || true)"
  fi
  if [[ -z "$fingerprint" ]]; then
    print -u2 "No Sprekr local signing identity was found."
    return
  fi
  valid_fingerprint "$fingerprint" || fail "Refusing to remove an identity with invalid metadata."

  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sprekr-untrust.XXXXXX")"
  chmod 700 "$TEMP_DIR"
  certificate="$TEMP_DIR/certificate.pem"
  if security find-certificate -c "$LABEL" -p "$keychain" > "$certificate" 2>/dev/null \
      || security find-certificate -c "$LEGACY_LABEL" -p "$keychain" > "$certificate" 2>/dev/null; then
    security remove-trusted-cert "$certificate" >/dev/null 2>&1 || true
  fi
  security delete-identity -Z "$fingerprint" "$keychain" >/dev/null 2>&1 || true
  if [[ -f "$METADATA" ]]; then
    /bin/rm "$METADATA"
  fi
  print -u2 "Removed the Sprekr local source-signing identity and its code-signing trust setting."
}

case "$ACTION" in
  ensure) ensure_identity ;;
  remove) remove_identity "$@" ;;
  *) fail "Usage: $0 [ensure | remove --yes]" ;;
esac
