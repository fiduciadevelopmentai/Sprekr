# Open-source security audit and publication gate

This document records the release controls for the source-only Sprekr beta. It is a checklist, not permission to publish. Publication still requires the owner’s planned product change, a new full audit, and an explicit instruction to make the repository public.

## Implemented controls

- Onest 1.000 Regular, Medium, and Bold replace the redistribution-restricted Satoshi files under SIL OFL-1.1.
- Sparkle, artifact installation, the release-signing helper, feed configuration, and the Homebrew template are removed. The only supported install/update commands are source-based.
- Local source installs use a unique login-Keychain certificate, user-domain trust restricted to code signing, hardened runtime with only the required audio-input entitlement, and a designated requirement bound to both the production bundle ID and certificate fingerprint.
- Ad-hoc development bundles use `com.klimtalks.app.development` and cannot impersonate the installed source build. Their DMG name ends in `development-adhoc`.
- Existing AES-GCM keys migrate transactionally to `.v2` Keychain accounts with `WhenUnlockedThisDeviceOnly`; ciphertext without a key is preserved and rejected instead of receiving a replacement key.
- Application Support and model directories use `0700`; encrypted stores, signing metadata, temporary audio, model files, and plaintext exports use `0600`.
- History export requires explicit confirmation that JSON is readable plaintext.
- Delivery verification never reads a complete `AXValue`, reads at most 64 characters from the expected inserted segment, excludes secure/read-only fields, and never retries an indeterminate delivery.
- The development spike hides transcript text by default. Only synthetic test audio may use `--print-transcript`.
- The speech model is pinned to FluidInference revision `aed02740059203c4a87495924f685de3722ae9ce`. Every required file has a reviewed HTTPS path, size, and SHA-256. Activation is atomic after complete validation; FluidAudio is offline before loading.
- Root `AGENTS.md`, redacted `make doctor`, complete `make audit`, privacy/security documentation, GitHub Actions, CodeQL, dependency review, gitleaks, Dependabot, and privacy-safe issue forms are present.

## Automated gate

`make audit` must pass from the exact commit intended for publication. It checks:

- Swift tests and the local test runner;
- debug and release app builds;
- shell syntax, plist validity, dependency lock, and Git diff hygiene;
- current files and full Git history for likely secrets and personal absolute paths;
- tracked models, recordings, transcripts, signing material, and restricted font history;
- hardened runtime and isolated development identity;
- Onest files/licenses, notices, brand assets, and the bundled model manifest;
- app bundle and mounted development DMG for removed dependencies and sensitive material.

The weekly/manual model workflow additionally downloads from the pinned revision, verifies hashes, transcribes synthetic audio, and repeats transcription offline.

## Manual clean-install acceptance

Run on Apple silicon with macOS 14 and again on the current macOS release:

1. Start from a clean user-owned checkout and run `make doctor`.
2. Run `./scripts/install.sh --source`; approve only the expected login-Keychain prompts.
3. Verify `codesign -d -r-` shows both `com.klimtalks.app` and a certificate-leaf hash, `codesign -d --verbose=4` shows hardened runtime, and `codesign --verify -R '=entitlement["com.apple.security.device.audio-input"]' /Applications/Sprekr.app` succeeds.
4. Complete onboarding, pinned model download, Microphone, Accessibility, Hold, Toggle, Escape, and first dictation.
5. Verify TextEdit and one Chromium/Electron editor; confirm secure/read-only targets are refused and offline dictation works.
6. Test source update. Confirm the designated requirement is unchanged, TCC is not requested again, and History/Dictionary/model data remain intact.
7. Confirm History export warns before the save panel and the resulting JSON file is mode `0600`.
8. Test uninstall with data preservation. Test purge only with explicit approval.
9. Check VoiceOver, keyboard navigation, Reduce Motion, Light/System/Dark, and minimum/normal window sizes.

Do not include real dictation content in test evidence. Use synthetic phrases.

## GitHub controls to verify in the UI

- Repository begins private and receives only sanitized history.
- Secret scanning, push protection, and Private Vulnerability Reporting are enabled.
- `main` requires pull requests, required green checks, linear history, and blocks force-push/deletion. Zero approvals is acceptable for the solo-owner workflow.
- Default workflow permissions are read-only.
- No workflow uses `pull_request_target`; all action references are immutable commit SHAs.

## Publication blockers

The repository must remain private while any item below is true:

- the historical commit containing restricted Satoshi/Fontshare files has not been removed from the history that will be pushed;
- the latest `make audit` or real-model integration is not green;
- the clean install/update matrix above has not been completed;
- the GitHub repository, branch protection, secret scanning, push protection, and Private Vulnerability Reporting have not been visibly verified;
- the owner’s planned final product change and explicit publication approval are still pending.
