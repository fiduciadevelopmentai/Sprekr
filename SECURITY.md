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

## Reporting

Use [GitHub Private Vulnerability Reporting](https://github.com/fiduciadevelopmentai/Sprekr/security/advisories/new). Do not open a public issue for a suspected vulnerability, and never include transcripts, audio, clipboard content, tokens, private keys, or Keychain material. If Private Vulnerability Reporting is unavailable before publication, contact the owner privately and share only a minimal redacted reproduction.
