# Troubleshooting Sprekr safely

Start with the read-only, redacted check:

```sh
make doctor
```

It reports architecture, macOS/Swift versions, free space, installed signature/version, private file modes, and pinned model integrity. It never reads transcript plaintext, audio, clipboard data, or another app’s field content.

On Windows 11 x64, start with:

```powershell
.\windows\scripts\doctor-windows.ps1
```

It reports only Windows build/architecture, exact .NET SDK availability, free space, Microphone policy state and lockfile presence.

## Windows installation and runtime

- **Windows 10 or ARM64:** unsupported in v1. Use an up-to-date Windows 11 x64 environment.
- **.NET SDK missing/wrong:** install .NET SDK 10.0.302 x64 from Microsoft. Do not substitute an unreviewed SDK or weaken `global.json`.
- **Less than 1.5 GB free:** free space on the `%LOCALAPPDATA%` drive and rerun the doctor.
- **Locked restore fails:** do not delete or regenerate lockfiles as a shortcut. Confirm the `Windows-gebruikers` checkout is complete and report the sanitized package error.
- **Native sherpa runtime missing or wrong architecture:** rerun `install-windows.ps1` from the trusted source checkout. The source must restore `org.k2fsa.sherpa.onnx.runtime.win-x64` 1.13.4.
- **Unsigned development warning:** expected for the `development-unsigned` ZIP. Prefer a source build. Do not disable SmartScreen, lower trust settings or run as administrator.

## Windows microphone and model

- **No microphone:** open Windows Settings > Privacy & security > Microphone and enable Microphone access plus desktop-app access. Do not edit the policy or registry on the user's behalf.
- **Chosen USB/headset device disappeared:** reopen Sprekr, refresh microphones and choose the default or an active device.
- **Model download interrupted:** retry in Sprekr; the fixed partial file resumes. Integrity is checked against 487,170,055 bytes and SHA-256 `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf` before extraction.
- **Model integrity fails twice:** stop and report the sanitized status. Never bypass size/hash checks or load the partial archive.

## Windows delivery and storage

- **Text is refused:** verify that the target is enabled, editable, non-password, non-read-only and not running as administrator. Sprekr itself must not be elevated.
- **Delivery is indeterminate:** do not trigger an automatic retry. The transcript remains in encrypted History; the one-shot policy exists to prevent duplicates.
- **History/Dictionary cannot unlock:** if ciphertext exists but the DPAPI key is absent or inaccessible to the current Windows user, preserve both. Sprekr will not generate a replacement key.
- **Explicit Dutch/English did not translate:** expected in Windows v1. The source text is deliberately preserved; Automatic remains the recommended setting.
- **Uninstall:** `uninstall-windows.ps1` preserves `%LOCALAPPDATA%\Sprekr`. A data purge is irreversible and requires both `-PurgeData` and `-ConfirmPurge Sprekr` after explicit owner approval.

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
