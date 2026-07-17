# Contributing

Sprekr welcomes future contributions after publication. Until then, this local workspace is not a public release.

## Ground rules

- Use original code and product language. Do not copy from Wispr Flow or GPL-only applications such as FluidVoice.
- Preserve local-only processing; do not add cloud calls, accounts, telemetry, tracking, or API keys.
- Never commit models, raw audio, transcript data, logs containing user text, signing identities, provisioning profiles, update keys, or secrets.
- Add unit tests for logic and fakes for protocol-bound services. UI code must not call FluidAudio directly.
- Test light, dark, and system appearance; keyboard navigation; VoiceOver labels; Reduce Motion; and safe failure paths.

## Development workflow

1. Read the architecture and privacy constraints.
2. Run `make bootstrap`, `make build`, and focused tests.
3. Make the smallest coherent change.
4. Run relevant tests, a build, and a smoke test.
5. Update notices and public documentation with real results.

The project is Apache-2.0. Third-party licenses and attributions must remain intact.
