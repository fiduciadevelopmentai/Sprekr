# Contributing

Sprekr welcomes contributions. macOS and Windows source are maintained together on `master`, with native platform boundaries and cross-platform acceptance gates.

## Ground rules

- Use original code and product language. Do not copy from Wispr Flow or GPL-only applications such as FluidVoice.
- Preserve local-only processing; do not add cloud calls, accounts, telemetry, tracking, or API keys.
- Never commit models, raw audio, transcript data, logs containing user text, signing identities, provisioning profiles, update keys, or secrets.
- Add unit tests for logic and fakes for protocol-bound services. UI code must not call FluidAudio directly.
- Keep macOS and Windows native boundaries separate. WPF code must not enter the Swift package; SwiftUI/AppKit code must not enter `windows/Sprekr.sln`.
- Keep SwiftPM and NuGet dependencies exact and locked. Windows restores in CI and release work use `--locked-mode`.
- Test light, dark, and system appearance; keyboard navigation; VoiceOver labels; Reduce Motion; and safe failure paths.

## Development workflow

1. Read the architecture and privacy constraints.
2. Run `make bootstrap`, `make build`, and focused tests.
3. Make the smallest coherent change.
4. Run relevant tests, a build, and a smoke test.
5. Update notices and public documentation with real results.

For Windows changes, run `doctor-windows.ps1`, locked restore, Release build, unit tests and `build-development-unsigned.ps1` on Windows 11 x64. Then rerun `make test`, `make integration-test`, `make build` and `make audit` on macOS before merging shared behavior or documentation.

The project is Apache-2.0. Third-party licenses and attributions must remain intact.
