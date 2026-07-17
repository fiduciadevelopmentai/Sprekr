#!/bin/zsh

# Shared shell-side product identity. The values under LEGACY_COMPATIBILITY are
# deliberately frozen: changing them would disconnect existing settings,
# encrypted stores, signing metadata, and macOS privacy identity.
readonly SPREKR_PRODUCT_NAME="Sprekr"
readonly SPREKR_LEGACY_APPLICATION_NAME="Klim Talks"
readonly SPREKR_BUNDLE_IDENTIFIER="com.klimtalks.app"
readonly SPREKR_DEVELOPMENT_BUNDLE_IDENTIFIER="com.klimtalks.app.development"
readonly SPREKR_KEYCHAIN_SERVICE="com.klimtalks.app"
readonly SPREKR_SETTINGS_KEY="com.klimtalks.app.settings"
readonly SPREKR_LEGACY_APPLICATION_SUPPORT_NAME="Klim Talks"
readonly SPREKR_SIGNING_LABEL="Fiducia Development Sprekr Local Source"
readonly SPREKR_LEGACY_SIGNING_LABEL="Fiducia Development Klim Talks Local Source"
