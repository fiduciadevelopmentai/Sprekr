# Security

## Threat model and controls

- **Model integrity:** a bundled manifest pins FluidInference revision `aed02740059203c4a87495924f685de3722ae9ce`, HTTPS paths, sizes, and SHA-256 for every required file. Downloads use a credential-free ephemeral session, stable `.part` files, atomic activation, and one retry. FluidAudio is offline before Core ML loading.
- **Sensitive content:** logs exclude raw audio, transcripts, clipboard data, and the target app’s field content. Temporary audio is removed on all completion paths.
- **Local identity:** source installs use one unique certificate from the login Keychain, hardened runtime, and a designated requirement that binds both `com.klimtalks.app` and the certificate fingerprint. Updates stop instead of falling back to an identifier-only or ad-hoc signature.
- **Local data:** History and Dictionary use AES-GCM. Certificate-bound installs transactionally migrate the same keys to version-2 Keychain items with `WhenUnlockedThisDeviceOnly`; the legacy item is removed only after successful decryption and reload. Missing keys never cause silent replacement above existing ciphertext. Data directories use `0700`; private files use `0600`.
- **Permissions:** request the least privilege in context. Do not bypass macOS Microphone, Accessibility, Gatekeeper, or code-signing protections.
- **Global input:** the event tap consumes only the configured shortcut and releases state on cancel, sleep/wake, layout changes, and errors.
- **Text insertion:** secure and read-only fields are refused. Delivery verification never reads a complete `AXValue`; it uses count/range and at most 64 characters from the expected inserted segment. Indeterminate delivery is never automatically repeated. Unicode and clipboard paste remain constrained fallbacks, with encrypted History as a no-loss guarantee.
- **Dependencies:** FluidAudio is pinned to an exact release. Dependency changes require review, test, and a notice update.
- **Updates:** the beta is source-only. `install.sh --source` and `update.sh --source` are the only supported paths. Local `development-adhoc` DMGs are never official release artifacts.

## Windows controls

- **Supported boundary:** Windows v1 supports current Windows 11 x64 only. The app manifest is `asInvoker`; source installers and Sprekr must never run as administrator. Windows integrity levels intentionally prevent injection into elevated targets.
- **Model integrity:** Windows pins the official sherpa-onnx Parakeet TDT 0.6B v3 INT8 archive to 487,170,055 bytes and SHA-256 `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`. Downloads resume, retry once, reject path traversal and activate only after verification.
- **Native runtime:** `org.k2fsa.sherpa.onnx` and `org.k2fsa.sherpa.onnx.runtime.win-x64` are exact `1.13.4`; NAudio is `2.3.0`; SharpCompress is `0.49.1`. Central package versions and committed lockfiles are mandatory.
- **Local data:** History and Dictionary use AES-GCM with separate random keys protected by Windows DPAPI `CurrentUser`. Missing/unopenable keys above existing ciphertext stop access and never cause replacement-key generation.
- **Temporary audio:** WASAPI recordings are written only below `%LOCALAPPDATA%\Sprekr\Temporary Audio` and removed after every normal success, failure, cancellation expiry and Undo path. The removal service refuses paths outside that root.
- **Text delivery:** UI Automation is classification-only apart from a maximum 64-character range immediately preceding the caret for bounded verification. Password, disabled, read-only, non-editable, self and elevated targets are refused. Unicode `SendInput` is attempted once; an indeterminate result is never retried. The Windows clipboard is not read or overwritten.
- **Global input:** low-level keyboard/mouse hooks live on their own message thread, ignore injected events, and restart after resume and unlock. Escape and the six-second Ctrl+Z recovery window use the same state machine as keyboard and mouse controls.
- **Artifacts:** CI may publish `Sprekr-windows-x64-development-unsigned.zip` plus SHA-256 for development testing. It is not an official signed release, MSIX or production installer.

## Reporting

Use [GitHub Private Vulnerability Reporting](https://github.com/fiduciadevelopmentai/Sprekr/security/advisories/new). Do not open a public issue for a suspected vulnerability, and never include transcripts, audio, clipboard content, tokens, private keys, or Keychain material. If Private Vulnerability Reporting is unavailable before publication, contact the owner privately and share only a minimal redacted reproduction.
