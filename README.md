# Sprekr

A free, open-source dictation app by [Fiducia Development](https://github.com/fiduciadevelopmentai).

You hold a key, you speak, Sprekr transcribes on your machine and puts the text where you were typing. Nothing more.

Licensed under [Apache-2.0](LICENSE).

## Core principles

- **Free.** No accounts, no subscriptions, no telemetry, no cloud transcription.
- **Local.** Audio is temporary. Transcripts stay on your device.
- **Source-only.** There is no official installer, DMG, Homebrew package, or store listing. Build it yourself from this repo.
- **Ordinary.** This is a small open project, not a product with guarantees.

## No warranty

Sprekr is provided as is. Fiducia Development and the authors are not responsible for anything that happens if you use, build, modify, or fail to use it — lost text, permissions, data, broken installs, or anything else.

See the [Apache-2.0 license](LICENSE) for the full legal terms.

## Install

macOS (Apple silicon, macOS 14+):

```sh
git clone https://github.com/fiduciadevelopmentai/Sprekr.git
cd Sprekr
./scripts/install.sh --source
```

Windows 11 x64:

```powershell
git clone https://github.com/fiduciadevelopmentai/Sprekr.git
Set-Location Sprekr
.\windows\scripts\install-windows.ps1
```

Details for coding agents live in [AGENTS.md](AGENTS.md). Privacy notes are in [PRIVACY.md](PRIVACY.md).
