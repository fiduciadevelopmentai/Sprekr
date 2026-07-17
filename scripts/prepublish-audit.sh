#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
source "$ROOT/scripts/product-identity.sh"

fail() {
  print -u2 "error: $*"
  exit 1
}

print "== Repository hygiene =="
git diff --check
plutil -lint App/Info.plist >/dev/null
for script in scripts/*.sh; do zsh -n "$script"; done
xcrun swift scripts/verify-fonts.swift
ruby -e 'require "yaml"; (Dir[".github/workflows/*.{yml,yaml}"] + [".github/dependabot.yml", ".github/ISSUE_TEMPLATE/bug.yml", ".github/ISSUE_TEMPLATE/config.yml"]).each { |file| YAML.load_file(file) }'
for key in CFBundleDisplayName CFBundleExecutable CFBundleName; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" App/Info.plist)" == "Sprekr" ]] \
    || fail "$key must use the visible Sprekr product name."
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' App/Info.plist)" == "$SPREKR_BUNDLE_IDENTIFIER" ]] \
  || fail "The legacy bundle identifier changed and would break macOS identity continuity."
/usr/bin/grep -Fq '.executable(name: "Sprekr", targets: ["SprekrApp"])' Package.swift \
  || fail "The Sprekr executable product is missing from Package.swift."

print "== Rebrand compatibility allowlist =="
while IFS= read -r legacy_file; do
  legacy_file="${legacy_file#./}"
  case "$legacy_file" in
    .github/workflows/model-integration.yml|\
    AGENTS.md|ARCHITECTURE.md|App/Info.plist|PRIVACY.md|README.md|SECURITY.md|\
    Sources/SprekrCore/SprekrIdentity.swift|Tests/SprekrAppTests/ProductLogicTests.swift|\
    docs/AGENT_INSTALL.md|docs/RELEASING.md|docs/SECURITY_AUDIT.md|\
    scripts/build-app.sh|scripts/doctor.sh|scripts/install.sh|\
    scripts/local-signing-identity.sh|scripts/package.sh|scripts/product-identity.sh|\
    scripts/uninstall.sh|scripts/update.sh)
      ;;
    *)
      fail "A legacy product name or identifier exists outside the compatibility allowlist: $legacy_file"
      ;;
  esac
done < <(rg -l --hidden \
  -g '!.git/**' -g '!.build/**' -g '!build/**' -g '!dist/**' \
  -g '!scripts/prepublish-audit.sh' \
  'Klim Talks|KlimTalks|klimtalks|klim-talks|KLIM_TALKS' . || true)
[[ -f Package.resolved ]] || fail "Package.resolved is missing."
! /usr/bin/grep -Eqi 'sparkle-project|"sparkle"' Package.resolved \
  || fail "Sparkle remains in Package.resolved."
/usr/bin/grep -Fq '"version" : "0.15.5"' Package.resolved \
  || fail "FluidAudio is not locked to 0.15.5."

print "== Secret, path, and artifact scan =="
secret_pattern='AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
scan_paths=(
  ':!scripts/prepublish-audit.sh'
  ':!docs/SECURITY_AUDIT.md'
)
if git grep -IlE "$secret_pattern" -- . "${scan_paths[@]}" | /usr/bin/grep .; then
  fail "A possible secret exists in tracked files (contents were not displayed)."
fi
while IFS= read -r commit; do
  if git grep -IlE "$secret_pattern" "$commit" -- . "${scan_paths[@]}" \
      | /usr/bin/grep . >/dev/null; then
    fail "A possible secret exists in Git history at commit ${commit[1,12]} (contents were not displayed)."
  fi
done < <(git rev-list --all)
worktree_matches="$(rg -l --hidden \
  -g '!.git/**' -g '!.build/**' -g '!build/**' -g '!dist/**' \
  -g '!scripts/prepublish-audit.sh' -e "$secret_pattern" . || true)"
[[ -z "$worktree_matches" ]] \
  || fail "A possible secret exists in the worktree (contents were not displayed)."
if git grep -IlE '/Users/[A-Za-z0-9._-]+/' -- . "${scan_paths[@]}" | /usr/bin/grep .; then
  fail "A personal absolute path exists in tracked files."
fi
worktree_paths="$(rg -l --hidden \
  -g '!.git/**' -g '!.build/**' -g '!build/**' -g '!dist/**' \
  -g '!scripts/prepublish-audit.sh' -e '/Users/[A-Za-z0-9._-]+/' . || true)"
[[ -z "$worktree_paths" ]] || fail "A personal absolute path exists in the worktree."
if git ls-files | /usr/bin/grep -Ei '^(Models?|Audio|Transcripts?)/|(^|/)(Sprekr|Klim Talks) Data/|\.(caf|wav|m4a|mp3|flac|mlmodel|mlmodelc|mlpackage|p12|pfx|pem|mobileprovision)$'; then
  fail "A model, recording, transcript directory, or signing artifact is tracked."
fi
if git ls-files | /usr/bin/grep -Ei 'Satoshi|Fontshare|Sparkle'; then
  fail "A removed Satoshi/Fontshare/Sparkle artifact is still tracked."
fi
while IFS= read -r commit; do
  if git ls-tree -r --name-only "$commit" | /usr/bin/grep -Eqi 'Satoshi|Fontshare'; then
    fail "Restricted font content remains in Git history at commit ${commit[1,12]}. Publish from a sanitized history."
  fi
done < <(git rev-list --all)
if rg -n --hidden -g '*.yml' -g '*.yaml' \
    'pull_request_target|uses:[[:space:]]+[^[:space:]]+@(main|master|v[0-9])([[:space:]#]|$)' .github; then
  fail "A GitHub workflow uses pull_request_target or a mutable action reference."
fi
/usr/bin/grep -Fq 'certificate leaf = H' scripts/build-app.sh \
  || fail "The source signature is not bound to its certificate fingerprint."
/usr/bin/grep -Fq -- '-p codeSign' scripts/local-signing-identity.sh \
  || fail "The local certificate trust is not constrained to code signing."
if /usr/bin/grep -Eq '^[[:space:]]*sudo([[:space:]]|$)|add-trusted-cert.*[[:space:]]-d([[:space:]]|$)' scripts/install.sh scripts/local-signing-identity.sh; then
  fail "The source-signing path requests sudo or admin-domain trust."
fi

print "== Tests and application bundles =="
make test
./scripts/build-app.sh debug >/dev/null
release_app="$(./scripts/build-app.sh release)"
[[ "${release_app:t}" == "Sprekr.app" ]] || fail "The release bundle is not named Sprekr.app."
[[ -x "$release_app/Contents/MacOS/Sprekr" ]] || fail "The Sprekr executable is missing from the release bundle."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$release_app/Contents/Info.plist")" == "$SPREKR_DEVELOPMENT_BUNDLE_IDENTIFIER" ]] \
  || fail "The ad-hoc verification bundle is not isolated under its development bundle ID."
codesign --verify --deep --strict "$release_app"
codesign -d --verbose=4 "$release_app" 2>&1 | /usr/bin/grep 'runtime' >/dev/null \
  || fail "The release verification bundle lacks hardened runtime."
for font in Onest-Regular.otf Onest-Medium.otf Onest-Bold.otf CrimsonText-Regular.ttf Lucide.ttf; do
  [[ -f "$release_app/Contents/Resources/$font" ]] || fail "Bundled font is missing: $font"
done
[[ -f "$release_app/Contents/Resources/Licenses/Onest-OFL.txt" ]] \
  || fail "The Onest OFL is missing from the app."
[[ -f "$release_app/Contents/Resources/Sprekr_SprekrCore.bundle/ParakeetV3ModelManifest.json" ]] \
  || fail "The pinned model manifest is missing from the app."
if find "$release_app" -iname '*satoshi*' -o -iname '*sparkle*' | /usr/bin/grep .; then
  fail "Removed Satoshi or Sparkle content is bundled."
fi
if rg -a -l -e "$secret_pattern" -e '/Users/[A-Za-z0-9._-]+/' "$release_app" \
    | /usr/bin/grep .; then
  fail "The app bundle contains a possible secret or personal absolute path."
fi

print "== Development-only package =="
dmg="$(./scripts/package.sh --app "$release_app")"
[[ "${dmg:t}" == Sprekr-*-development-adhoc.dmg ]] \
  || fail "The local DMG is not clearly named development-adhoc."
[[ -f "$dmg.sha256" ]] || fail "The development DMG checksum is missing."
mount="$(mktemp -d "${TMPDIR:-/tmp}/sprekr-audit-mount.XXXXXX")"
cleanup_mount() {
  hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
  rmdir "$mount" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
bundled="$mount/Sprekr.app"
codesign --verify --deep --strict "$bundled"
if find "$bundled" -iname '*satoshi*' -o -iname '*sparkle*' | /usr/bin/grep .; then
  fail "Removed content exists in the development DMG."
fi
if rg -a -l -e "$secret_pattern" -e '/Users/[A-Za-z0-9._-]+/' "$bundled" \
    | /usr/bin/grep .; then
  fail "The development DMG contains a possible secret or personal absolute path."
fi
cleanup_mount
trap - EXIT

print "Prepublication audit passed. The DMG remains a local development artifact only."
