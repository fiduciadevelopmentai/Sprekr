# Sprekr

**Free and open-source project by Fiducia Development.** Licensed under [Apache-2.0](LICENSE).

Sprekr is a private, fast dictation app for Apple-silicon Macs and Windows 11 x64. Use your talk key from another app, speak naturally, and Sprekr transcribes locally with NVIDIA Parakeet TDT 0.6B v3 before returning the text to where you were writing.

> **Source/development beta:** macOS remains source-only; there is no official DMG, Homebrew package, Sparkle feed, or notarized binary. Windows supports a source install and a clearly named, unsigned `development-unsigned` ZIP produced by CI. It is not a production installer. Build only from a trusted checkout.

The production macOS implementation remains isolated in Swift/SwiftUI. Windows development lives on the `Windows-gebruikers` branch as a native WPF app; nothing is merged into `master` until both platform gates pass.

## Install with a coding agent

Give Codex, Claude Code, Cursor, Antigravity, or another local coding agent the repository URL and this prompt:

> Install Sprekr from source from this repository. Read AGENTS.md, README.md, and docs/AGENT_INSTALL.md first. Run `make doctor`, explain any failing requirement without displaying private content, then run `./scripts/install.sh --source`. Never use sudo, bypass Gatekeeper, reset TCC permissions, force-quit the app, remove existing Sprekr data, or print transcript, audio, clipboard, or text-field contents. After launch, guide me through the pinned model download, Microphone permission, Accessibility permission, Hold and Toggle controls, and a first dictation.

The complete agent hand-off and safe fallback instructions are in [docs/AGENT_INSTALL.md](docs/AGENT_INSTALL.md).

## Requirements

### macOS

- Apple-silicon Mac
- macOS 14 or newer
- About 1 GB free while the speech model is installed (the required download is roughly 482 MB, with room needed for Core ML and update overhead)
- Internet for the single model download; no internet is needed for later transcription

### Windows

- An up-to-date Windows 11 x64 installation; Windows 10 and ARM64 are not supported in v1
- [.NET SDK 10.0.302 x64](https://dotnet.microsoft.com/download/dotnet/10.0) for source/development builds
- At least approximately 1.5 GB free under `%LOCALAPPDATA%` while the model is downloaded and unpacked
- Windows Microphone access for desktop apps
- Internet for the single pinned model download; later transcription is offline

Sprekr uses [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). macOS loads the commit-pinned Core ML conversion through FluidAudio; Windows loads the official sherpa-onnx INT8 archive through ONNX. No NVIDIA API key, cloud account, or subscription is required.

## Feature map

| Feature | What it does |
| --- | --- |
| Hold / Toggle / Escape | Hold records while pressed; Toggle starts/stops on separate presses; Escape cancels with a six-second Undo window. |
| Flow Bar | Non-activating listening, processing, language, Undo, and recovery feedback without stealing focus. |
| Language and translation | Automatic preserves detected language. macOS can translate locally through Apple’s framework; Windows v1 keeps the source text and explains that local translation is unavailable. |
| History and Insights | Encrypted local transcripts plus factual, on-device usage metrics. |
| Dictionary and learning | Encrypted preferred spellings, aliases, bounded fuzzy repair, and optional immediate correction learning. |
| Smart writing | Local number, symbol, punctuation, stutter, list, and paragraph formatting with conservative safeguards. |
| Privacy and delivery | Temporary owner-only audio, no cloud/telemetry, secure-field refusal, bounded Accessibility verification, and clipboard recovery. |
| Model and updates | One cryptographically pinned model download; later inference is offline. Installation and updates are source-only. |

## Privacy

Audio is captured and transcribed on the device. Sprekr has no accounts, analytics, telemetry, cloud synchronization, or API keys. Audio is temporary and removed after success, cancellation, or failure. Transcript History and Dictionary entries remain local and use AES-GCM; the key is protected by macOS Keychain or Windows DPAPI `CurrentUser`. See [PRIVACY.md](PRIVACY.md).

## Install

### macOS: build and install from source

Clone the public repository and run the source installer:

```sh
git clone https://github.com/fiduciadevelopmentai/Sprekr.git
cd Sprekr
./scripts/install.sh --source
```

The script resolves the pinned Swift dependencies, creates or reuses a unique local code-signing identity in the login Keychain, signs with hardened runtime and a certificate-bound designated requirement, verifies the bundle, installs it in `/Applications`, and launches it. The certificate is trusted only for code signing in the user domain, not as a general root. The script does not use `sudo`, alter Gatekeeper, or remove existing Sprekr data. macOS may ask for Keychain approval during the first install.

If `/Applications` is not writable, use a personal Applications folder:

```sh
mkdir -p "$HOME/Applications"
./scripts/install.sh --source --destination "$HOME/Applications"
```

The source build requires recent Apple Command Line Tools with Swift 6. If they are missing, start Apple's installer with `xcode-select --install`, complete the displayed installation, and rerun the source installer. Full Xcode is not required for this beta.

### Windows 11 x64: source install

Clone the Windows branch from PowerShell, run the read-only doctor, and install without administrator rights:

```powershell
git clone --branch Windows-gebruikers https://github.com/fiduciadevelopmentai/Sprekr.git
Set-Location Sprekr
.\windows\scripts\doctor-windows.ps1
.\windows\scripts\install-windows.ps1
```

The installer performs a locked NuGet restore, publishes a self-contained `win-x64` app to `%LOCALAPPDATA%\Programs\Sprekr`, and creates a per-user Start-menu shortcut. Models, settings, encrypted History/Dictionary and DPAPI-protected keys stay under `%LOCALAPPDATA%\Sprekr` and are preserved during updates. Do not start PowerShell, the installer, or Sprekr as administrator.

Start a development checkout without installing it:

```powershell
.\windows\scripts\run-windows.ps1
```

Build the unsigned development ZIP locally:

```powershell
.\windows\scripts\build-development-unsigned.ps1
```

The ZIP and `.sha256` file appear under `windows\artifacts`. Because this v1 artifact is unsigned, Windows may show a trust warning; no Gatekeeper/SmartScreen bypass is recommended or automated. A trusted code-signing certificate and production MSIX are intentionally outside v1.

### Development commands

The current project builds locally with macOS Command Line Tools and Swift 6. Full Xcode is still needed later for Xcode archives and Apple signing workflows:

```sh
make bootstrap
make build
make test
make integration-test
make doctor
make audit
make run
```

`make package` produces a **`development-adhoc` DMG** for local verification only; it is deliberately isolated under the development bundle identifier and must never be presented as an official download. `make doctor` is read-only and redacted. `make audit` runs the complete local publication gate. See [docs/RELEASING.md](docs/RELEASING.md).

Windows development and test commands:

```powershell
Set-Location windows
dotnet restore .\Sprekr.sln --locked-mode --configfile .\NuGet.Config
dotnet build .\Sprekr.sln --configuration Release --no-restore
dotnet test .\tests\Sprekr.Windows.Tests\Sprekr.Windows.Tests.csproj --configuration Release --no-build
```

FFmpeg is not required. sherpa-onnx supplies the Windows x64 ONNX runtime, NAudio uses WASAPI for recording/playback/resampling, and SharpCompress extracts the pinned `.tar.bz2` model archive.

## First launch

On Windows, start Sprekr from the Start menu, download the pinned model, choose a microphone and leave the target application focused. F8 and mouse button 4 are available as global controls: Hold records while pressed, while Toggle starts on one press and stops on the next. Escape cancels and Ctrl+Z restores the cancelled recording for six seconds. The non-activating WPF Flow Bar never takes keyboard focus.

Windows uses UI Automation only to classify the focused target and to inspect at most 64 characters immediately before the caret after a write. Password, disabled, read-only, non-editable and elevated administrator targets are refused. Text is sent as Unicode without reading or replacing the clipboard, and an indeterminate write is never retried. Windows integrity levels prevent a normal desktop app from inserting into an elevated app; this is an intentional security boundary.

The detailed onboarding sequence below describes the established macOS app:

The onboarding explains each step and can be completed with the keyboard:

1. Confirm local-only processing.
2. Download the model once.
3. Allow Microphone access so the app can hear your dictation.
4. Allow Accessibility access so the app can type into the text field you started in.
5. Choose an independent keyboard key, key combination, or mouse side button for Hold to talk and Toggle to talk. Sprekr verifies that both controls are registered system-wide through the Accessibility access granted in the previous step.
6. Check the talk key and microphone with the live level meter.
7. Choose startup, Flow Bar, Dock, and sound preferences.
8. Try a first dictation in the built-in field.
9. Finish with a six-second local preparation screen, clickable tips, and a final ready check before opening Home.

Microphone and Accessibility are required onboarding steps. If access is denied, Sprekr explains why it is needed, opens the correct System Settings pane, and enables Continue as soon as macOS reports that access is granted and the global talk controls are active.

## Dictation

- **Hold to talk:** hold your independently chosen Hold key while speaking; release to transcribe.
- **Toggle:** press your independently chosen Toggle key once to start and again to stop.
- **Escape:** cancels an active recording.

Both talk controls remain registered together. Onboarding and General Settings record a keyboard key, key combination, or wired mouse side button directly rather than forcing a preset. Fn, Option, Control, Shift, or Command can be used by itself by pressing and releasing it in the recorder. While that recorder is listening, the global talk actions are suspended so the candidate key cannot start or stop dictation. Sprekr rejects identical, modifier-overlapping, and same-physical-key Hold and Toggle choices before saving them, keeps the previous valid choice, and explains which control already owns the key.

Sprekr remembers the foreground text field when dictation starts. It tries constrained clipboard paste, Accessibility insertion, and Unicode events without ever reading the complete field value. Delivery verification uses character count, selection range, and at most 64 characters from only the expected newly inserted segment. An unreadable result is never followed by a second automatic write. If there is no editable field, the transcript stays in encrypted History and is copied so you can press Command-V. A later empty recording clears only an unchanged Sprekr recovery copy, so it cannot accidentally present an older recording as new.

The optional **Learn immediate corrections** setting watches only the exact text range Sprekr just inserted, plus a tiny in-memory boundary needed to identify that range. It stops after about 30 seconds, never runs in secure fields, stores no surrounding text, and learns only one stable word replacement. A supported edit such as `microfon` → `microfoon` becomes an encrypted local Dictionary alias for later dictations; broader rewrites and ambiguous changes are ignored.

The supplied Sprekr artwork is bundled rather than loaded from the system: the transparent seven-bar mark appears in the app and listening Flow Bar, while the rounded near-black version supplies the Dock/app icon at every macOS size. The icon's four outer corners contain real alpha, so only the intended rounded container appears against the Dock rather than a black square image boundary. Completion uses a short bundled AIFF tone instead of a game-like system alert.

Hovering the idle Flow Bar reveals only the output-language control and microphone action. The restrained icons sit inside unchanged generous hit areas. Expansion is immediate; collapse uses a short exit grace period and verifies the pointer against the real panel frame, preventing the resizing non-activating panel from generating a hover flicker loop. After recording stops, the 86×25 listening bar becomes a recognizable 52×25 processing capsule with only its centered dot-matrix loader. It remains visible for at least 700 ms—even when recognition immediately finds no speech—and ignores additional recording input until delivery finishes. Only after that minimum does `No speech detected` replace the settled loader. Semantic state changes swap their content and final panel geometry directly inside one animation-free transaction, so an outgoing waveform or message never survives inside the next state’s smaller bounds. Motion remains inside stable capsules: the waveform, dot-matrix loader, countdowns, pressed feedback, and deliberate idle hover continue to animate. Processing finishes before text delivery; successful insertion returns the bar to idle and starts the one completion sound about 70 ms later so the visible text and audible cue feel like one event. Clipboard recovery remains silent. `Automatic` keeps the language that was spoken; `Nederlands` and `English` use Apple's on-device Translation framework on macOS 15 or newer when the spoken language differs. Translation language packs may require one-time system download approval. If translation is unavailable or declined, Sprekr preserves, saves, and delivers the original transcript instead of losing it.

Routine success does not display an “Added” badge or toast; only errors and transcripts that could not be inserted expand into a message. Those capsules measure their width from the actual single-line copy, use compact 12 pt side padding, and show a 3.8-second countdown bar tied to automatic dismissal. Pressing Escape preserves the current audio for six seconds in a `Recording cancelled` state. Choosing **Undo** transcribes it after all, prefers a newly selected editable field, and otherwise copies the restored text with clear Command-V guidance. Recording has no elapsed-time cutoff. Transient, healthy audio-configuration notifications are debounced and ignored, while an actual stopped engine or invalid microphone format still ends the capture safely with recovery guidance.

Spoken Dutch and English numbers and explicit symbol commands are always normalized locally, independently of Smart formatting. Cardinals and compounds such as `honderdzevenentwintig`, `duizend vierhonderd en dertien`, and `ten thousand four hundred twenty-three` become `127`, `1413`, and locale-appropriate grouped digits. Negative values, decimals, currencies, percentages, and ordinary quantities are supported; dates, times, telephone numbers, codes, versions, IP addresses, ordinals, overflow, and ambiguous Dutch `een` remain unchanged. The final output language controls notation: Dutch uses `10.423,5`, while English uses `10,423.5`, with grouping beginning at five digits. Spoken forms such as `apenstaartje`, `slash`, `streepje`, `procentteken`, and `euroteken` become `@`, `/`, `-`, `%`, and `€`; short quote commands produce typographic quotation marks, while URLs, paths, operators, percentages, currencies, and brackets receive context-aware spacing. A bounded email pass recognizes a literal `@` and common Dutch or English spoken variants, joins at most six local-name parts, handles `punt` / `puntje` / `dot` and glued forms such as `puntcom`, and safely repairs a unique one-character provider error or explicit variants such as `laif` → `live`. It validates every candidate, lowercases valid addresses, preserves unknown company domains, and leaves social handles or incomplete addresses untouched.

Optional local smart formatting handles high-confidence false starts, self-corrections, standalone spelling notes such as “creatives is met een K,” the canonical `Sprekr` brand spelling, common Dutch/English code-switch spellings such as `tweeken` → `tweaken`, and recognizer tails such as `gehad gehad gehad geh`. A second stutter-friendly pass collapses repeated sound fragments (`f-f-format`), adjacent word echoes (`format, format, format`), repeated short rough-copy phrases, and obvious question-boundary restarts while preserving common deliberate emphasis, grammatical doubles such as `dat dat` / `had had`, and normal repeated names across two sentences. A narrow alternative-restart repair also removes an unnatural recognizer bridge such as “of en” / “or and” when the fluent restatement clearly repeats the preceding phrase. It also handles clear spoken layout commands, numbered paragraph cues such as “alinea 1” and “alinea 2,” semantic quotes around short meaning subjects, high-confidence descriptive colons, and cautious question punctuation. Sequential `Punt 1 / Punt 2` or `Point one / Point two` markers become separate labelled paragraphs. Sequential `Ten eerste / Ten tweede` and English equivalents keep those labels and become separate paragraphs with a blank line instead of bullets, even when recognition omits punctuation. Only a clear list-intent phrase plus at least three short parallel items becomes a round `•` list with a blank line between items; ordinary point references and comma series remain unchanged. Balanced paragraphing accepts clear transitions from about 40 words, considers cohesive topic shifts from 70 words, and uses the safest sentence boundary near 70 words once a remaining block reaches 85 words. Short dependent continuations such as “dat hoeft hij niet” are joined with a comma only when the surrounding clauses provide a high-confidence grammatical frame; complete new sentences stay separate. Meaning questions about context or impact remain unquoted, and tail cleanup requires an incomplete echo or at least three unprotected copies at the end, so ordinary language stays intact. It runs on the Mac and can be disabled in Settings; transcripts are never sent to a cloud rewriting service. Number and symbol normalization remains active when this setting is off.

## History, Insights, and Dictionary

- **Home** groups local transcripts by Amsterdam date, lets you search, copy, and delete them. Filtering never replaces the live search control, so focus and the standard Command-A/C/V and Delete editing shortcuts remain available while results change or become empty.
- **Insights** shows total words, words per minute, speaking streaks, calendar activity, and explicit Dictionary fixes—never the content or categorization of other apps.
- **Dictionary** derives only unfamiliar names, brands, and uncommon spellings from encrypted History in memory, alongside explicit fixes under **Saved corrections**. Common recognized vocabulary is filtered out before it enters the visible word collection, keeping the screen and its in-memory model compact even with a long History. Editing `Jibrel` to `Jibreel` stores the heard form as an alias and applies the exact preferred spelling—including spacing, capitals, and diacritics—to future dictations whether Smart formatting is enabled or not. The same learned alias can repair a personal name inside a normalized email address, where the chosen lowercase email style is retained and the correction is counted once. A narrowly bounded, unique near-spelling match can repair a later one- or two-character recognizer variation; ambiguous candidates remain untouched and can be taught as another alias. Existing preferred spellings become aliases when renamed, names and brands default to both languages, inactive entries never apply, and the UI confirms what Sprekr learned. Its search keeps native keyboard focus after clearing, so typing and standard macOS edit shortcuts continue without another click. Immediate learning is controlled by its clearly labelled General setting and reports a saved spelling when one is learned.

## Settings

Settings uses four focused pages: General for independent Hold and Toggle keys, live microphone selection and testing, output language, formatting, bounded correction learning, and appearance; System for app lifecycle, sounds, permissions, the local speech model, and updates; Privacy for encrypted local data, export, and confirmed destructive actions; and About for build and license information. The microphone list refreshes when built-in, USB, or headset devices connect or disconnect. System Default follows the current macOS input route, while a removed explicit device falls back safely to System Default. Microphone permission belongs to Sprekr, so changing hardware does not require granting the app again. Light and Dark are fixed themes; System removes the app override and follows the current macOS appearance immediately. The main app opens with its sidebar collapsed to an icon rail. Hover labels identify every destination, and the top-chrome control expands the full navigation when needed. The bottom Info action opens a compact introduction to Fiducia Development, the free project, local processing, encrypted storage, and user controlled data removal.

## Updates and uninstall

On Windows, pull a clean `Windows-gebruikers` checkout and rerun `.\windows\scripts\install-windows.ps1`; installed binaries are replaced transactionally while `%LOCALAPPDATA%\Sprekr` is preserved. The normal uninstall also preserves local data:

```powershell
.\windows\scripts\uninstall-windows.ps1
```

Permanent Windows data removal requires the explicit command `.\windows\scripts\uninstall-windows.ps1 -PurgeData -ConfirmPurge Sprekr`. This removes only the Windows data root `%LOCALAPPDATA%\Sprekr`; it never touches the legacy macOS data root.

The source-only beta does not use automatic or package-manager updates. To update a source installation, pull the latest source and run the source updater:

```sh
git pull --ff-only
./scripts/update.sh --source
```

Source updates reuse the same certificate identity and preserve TCC continuity, settings, encrypted History, Dictionary data, and a valid downloaded model. The visible app is `Sprekr.app`, while the bundle identifier, Keychain service, settings key, and legacy `Application Support/Klim Talks` directory intentionally remain stable for compatibility. These frozen anchors are centralized in `SprekrIdentity.swift` for the app and `scripts/product-identity.sh` for source tooling. If that identity is missing or different, the updater stops safely; it never falls back to ad-hoc signing.

For a full uninstall, use `make uninstall`; it will separately ask whether you want to retain or remove app data and models. The normal app-data and model location is:

```text
~/Library/Application Support/Klim Talks/
```

## Troubleshooting

Start on macOS with `make doctor`; start on Windows with `.\windows\scripts\doctor-windows.ps1`. The full privacy-safe decision tree is in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

- **No waveform:** select a microphone in Settings and allow Microphone access.
- **Transcript was not inserted:** allow Accessibility access; the text remains in History and the clipboard fallback is available.
- **Model cannot download:** free enough disk space, reconnect temporarily, and retry; incomplete downloads resume safely.
- **Offline transcription fails:** ensure the model finished downloading and has not been removed in Settings.
- **Talk key does nothing:** allow Accessibility, then check the separate Hold and Toggle keys in General Settings and retry Talk key access in System Settings.
- **Windows native runtime missing:** reinstall from the locked source checkout so `org.k2fsa.sherpa.onnx.runtime.win-x64` is restored and published.
- **Windows insertion refused:** use a normal, non-elevated editable field; never run Sprekr as administrator.
- **Windows translation notice:** expected in v1; Automatic and explicit language selections preserve the original locally transcribed text.

## Development

Sprekr uses Swift 6/SwiftUI/AppKit on macOS and .NET 10/WPF on Windows. The platform applications share behavior contracts and golden formatting fixtures but do not share native audio, model, lifecycle, permission or text-delivery implementations. See [ARCHITECTURE.md](ARCHITECTURE.md), [DESIGN.md](DESIGN.md), and [CONTRIBUTING.md](CONTRIBUTING.md). Runtime and model acknowledgements are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The project is licensed under [Apache-2.0](LICENSE). This beta intentionally uses locally built source installations instead of a prebuilt Developer ID-signed download. Release gates are documented in [docs/RELEASING.md](docs/RELEASING.md).
