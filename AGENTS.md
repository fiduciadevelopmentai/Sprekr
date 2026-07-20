# Agent guide for Sprekr

Sprekr is a free and open-source Fiducia Development project. This file is the primary entry point for Codex, Cursor, Claude Code, and other coding agents asked to install, update, diagnose, or change the app.

## Start here

1. Read `README.md`, `SECURITY.md`, `PRIVACY.md`, and `ARCHITECTURE.md` before changing or installing anything.
2. Preserve the user’s worktree and the legacy-compatible `~/Library/Application Support/Klim Talks/`. Never reset, clean, overwrite, export, or remove user data unless the user explicitly requests the exact action.
3. On macOS, run the read-only, redacted preflight:

   ```sh
   make doctor
   ```

4. For a source install, use only:

   ```sh
   ./scripts/install.sh --source
   ```

5. For an update, first inspect `git status`. Do not pull over local changes. When the checkout is clean and the user requested an update:

   ```sh
   git pull --ff-only
   ./scripts/update.sh --source
   ```

6. On Windows 11 x64, use only the PowerShell entry points from the default `master` branch:

   ```powershell
   .\windows\scripts\doctor-windows.ps1
   .\windows\scripts\install-windows.ps1
   ```

   Never run PowerShell, the installer, or Sprekr as administrator. The ordinary Windows uninstall preserves `%LOCALAPPDATA%\Sprekr`; purging it requires the user's explicit request and the exact confirmation parameter documented in README.

There is no supported DMG, Homebrew, Sparkle, MSIX, production Windows installer, Gatekeeper bypass or SmartScreen bypass. `make package` creates a local `development-adhoc` DMG. Windows CI creates an explicitly unsigned `development-unsigned` ZIP. Never advertise either as an official signed release.

## Hard safety boundaries

Never:

- use `sudo` or change system/admin trust settings;
- disable Gatekeeper, remove quarantine attributes as a bypass, or run an unsigned downloaded binary;
- reset or edit TCC permissions, Microphone permissions, Accessibility permissions, or another app’s settings;
- force-quit Sprekr or another app;
- delete or move local data, models, preferences, Keychain items, signing identities, or the installed app without explicit user approval;
- print, log, upload, copy into an issue, or otherwise inspect unredacted transcript text, raw audio, clipboard contents, encrypted-store plaintext, or another app’s text-field content;
- replace the pinned model revision, hashes, dependency lock, signing requirement, privacy limits, or secure-field exclusions as a troubleshooting shortcut;
- silently create a new encryption key when encrypted data already exists;
- introduce telemetry, cloud transcription, remote logging, accounts, API keys, or environment-overridable model registries.
- run Sprekr or its Windows installer elevated, bypass Windows integrity levels, or inject into an administrator process;
- read or replace the Windows clipboard for delivery; Windows uses a one-shot Unicode write and never retries an indeterminate result;

If a command would cross one of these boundaries, stop and explain the safe manual step to the user.

## What the app should do

- **Hold:** record only while the configured Hold control is pressed.
- **Toggle:** start on the first press and stop on the second.
- **Escape:** cancel recording, keep it for a six-second Undo window, then remove it.
- **Flow Bar:** remain non-activating, show listening/processing/recovery state, and never steal text focus.
- **Language:** Automatic preserves detected language; Nederlands or English may translate locally through Apple’s Translation framework.
- **Windows language:** Automatic preserves detected language; explicit Dutch/English retains the source text and reports that local translation is unavailable.
- **History:** store transcripts locally with AES-GCM and keys protected by macOS Keychain or Windows DPAPI `CurrentUser`; copying/exporting is always user initiated.
- **Insights:** derive local metrics without analyzing other apps.
- **Dictionary and correction learning:** keep explicit spellings and bounded aliases encrypted; immediate learning inspects only the just-inserted range with a tiny in-memory boundary.
- **Delivery:** refuse secure/read-only targets, never read a complete target value, inspect at most 64 characters from the expected inserted segment, and never retry an indeterminate write.
- **Model:** use only the platform's bundled, pinned HTTPS model source, verify every byte before Core ML or ONNX loading, then keep inference offline.
- **Updates:** preserve all local data and keys; macOS reuses its unique local signing certificate so Keychain access and privacy identity remain continuous.

## Architecture boundaries

- `SprekrCore` owns the FluidAudio/Core ML boundary and pinned model installer. App views must not call FluidAudio or networking directly.
- `ModelManager` exposes install/load state to the UI.
- `AudioCaptureService` owns temporary audio and must remove it on every normal completion, failure, and cancellation expiry path.
- `TextInjectionService` owns target classification and delivery. Secure/read-only exclusion and no-duplicate fallback policy are invariants.
- `EncryptedJSONStore`, `TranscriptRepository`, and `DictionaryRepository` own local persistence. Application Support directories are `0700`; encrypted stores and exports are `0600`.
- `HotkeyManager`, `FlowBarController`, and `AppLifecycleController` own global controls and native macOS lifecycle behavior.
- Swift dependencies stay exact in `Package.swift` and `Package.resolved`. Third-party changes require notice and license review.
- `windows/Sprekr.sln` is isolated from the Swift build. Core defines platform contracts; Infrastructure owns sherpa-onnx, WASAPI, DPAPI, UI Automation and low-level hooks; App owns WPF and tray lifecycle.
- Windows dependencies stay centrally pinned in `windows/Directory.Packages.props` and every project lockfile remains committed. Do not restore without `--locked-mode` in CI or release flows.
- Windows data stays under `%LOCALAPPDATA%\Sprekr`; installed binaries stay under `%LOCALAPPDATA%\Programs\Sprekr`. Never reuse or migrate the macOS legacy data root.

## Verification commands

Use the smallest relevant check while developing, then the full gate before calling work complete:

```sh
make test
make integration-test      # real local model; synthetic audio only
make build
make audit
```

The development CLI reports only status, timing, and transcript character count. `--print-transcript` is allowed only with synthetic test audio. Do not use it with a user recording.

Windows verification uses:

```powershell
Set-Location windows
dotnet restore .\Sprekr.sln --locked-mode --configfile .\NuGet.Config
dotnet build .\Sprekr.sln --configuration Release --no-restore
dotnet test .\tests\Sprekr.Windows.Tests\Sprekr.Windows.Tests.csproj --configuration Release --no-build
.\scripts\build-development-unsigned.ps1
```

The scheduled model test may use only the synthetic WAV bundled in the pinned sherpa model archive. Never point it at a user recording or print transcript text.

## Troubleshooting decision tree

1. **`make doctor` reports the wrong architecture, macOS, Swift, or disk space:** explain the requirement. For missing Command Line Tools, the user may run `xcode-select --install`; do not install unrelated package managers.
2. **The destination is not writable:** use a user-owned Applications directory, never `sudo`:

   ```sh
   mkdir -p "$HOME/Applications"
   ./scripts/install.sh --source --destination "$HOME/Applications"
   ```

3. **The signing identity is missing/different:** stop. Do not use ad-hoc signing. Ask whether the user intentionally removed the Keychain identity and explain that a new identity can require permissions again; preserve data.
4. **The model is absent:** reconnect temporarily and use the in-app download. If integrity fails, retry once through the app. Never delete outside `~/Library/Application Support/Klim Talks/Models/parakeet-tdt-0.6b-v3`.
5. **Microphone is denied:** guide the user to System Settings from the app; do not reset TCC.
6. **Accessibility or talk controls fail:** quit normally if an update is needed, guide the user to the app’s System Settings link, then retry registration. Never force-quit or simulate consent.
7. **Text was not inserted:** confirm the target is editable and non-secure. The transcript remains in encrypted History and may already be in the clipboard for manual Command-V. Do not dump target content.
8. **History or Dictionary cannot unlock:** let the user approve the normal Keychain prompt. If encrypted files exist but the key is missing, stop and preserve both files; never generate a replacement key.
9. **A test fails:** report the exact command and sanitized failure. Do not weaken hashes, permissions, signatures, secure-field checks, or assertions to make it green.

Only `./scripts/uninstall.sh --purge` removes data, encryption keys, preferences, and the Sprekr local signing identity. Run it only after explicit owner approval; without that approval, keep data.
