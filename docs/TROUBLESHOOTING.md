# Troubleshooting Sprekr safely

Start with the read-only, redacted check:

```sh
make doctor
```

It reports architecture, macOS/Swift versions, free space, installed signature/version, private file modes, and pinned model integrity. It never reads transcript plaintext, audio, clipboard data, or another app’s field content.

## Installation

- **Apple silicon, macOS, Swift, or disk check fails:** meet the named requirement. Apple Command Line Tools can be requested with `xcode-select --install`.
- **`/Applications` is not writable:** never use `sudo`; install into a user-owned Applications directory as shown in `AGENTS.md`.
- **Signing identity missing or different:** stop. Do not ad-hoc sign. Preserve the app data and ask whether the identity was intentionally removed.
- **App is running during update:** quit Sprekr normally from its menu and rerun the source updater. Never force-quit it.

## Model

- **Not installed:** reconnect temporarily and use the in-app download.
- **Integrity failed:** retry once through the app. The downloader discards only the Sprekr pinned model subdirectory and never uses unverified bytes.
- **Offline transcription failed:** run `make doctor`; all 23 manifest files must verify before offline Core ML loading.

## Permissions and delivery

- **No waveform:** select an input and guide the user through Microphone access in System Settings.
- **Microphone is enabled but onboarding still says it is denied:** after migrating a legacy ad-hoc build, macOS may still display the old build's consent while the certificate-bound build needs one normal consent prompt. Run `make doctor`, reinstall only with `./scripts/install.sh --source`, and approve the normal Microphone prompt. If the switch remains stale, quit Sprekr normally, switch Sprekr off and on once in System Settings, and reopen it. Never reset TCC.
- **Hold/Toggle do nothing:** check Accessibility and both independent controls. Do not reset TCC or simulate consent.
- **Transcript not inserted:** confirm the focused target is editable and not secure/read-only. The transcript remains in encrypted History and may be copied for manual Command-V. Never dump the target field.
- **History cannot unlock:** allow the normal Keychain prompt. If encrypted files exist but their key is missing, preserve everything and stop; a replacement key would make recovery impossible.

## Reports

Use synthetic text and sanitized command output. Never attach real recordings, transcripts, clipboard contents, target-field content, Keychain material, tokens, private keys, or personal absolute paths. Security vulnerabilities go through GitHub Private Vulnerability Reporting, not a public issue.
