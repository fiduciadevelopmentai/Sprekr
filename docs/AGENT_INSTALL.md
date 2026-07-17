# Install Sprekr with a coding agent

For macOS, use this exact prompt:

> Install Sprekr from source from this repository. Read AGENTS.md, README.md, and docs/AGENT_INSTALL.md first. Run make doctor, explain any failing requirement without displaying private content, then run ./scripts/install.sh --source. Never use sudo, bypass Gatekeeper, reset TCC permissions, force-quit the app, remove existing Sprekr data, or print transcript, audio, clipboard, or text-field contents. After launch, guide me through the pinned model download, Microphone permission, Accessibility permission, Hold and Toggle controls, and a first dictation.

An agent must:

1. Confirm that the checkout comes from `https://github.com/fiduciadevelopmentai/Sprekr` and read root `AGENTS.md` plus the repository instructions before running commands.
2. Confirm that the Mac uses Apple silicon, runs macOS 14 or newer, has about 1 GB free, and has recent Apple Command Line Tools with Swift 6:

   ```sh
   uname -m
   sw_vers -productVersion
   xcode-select -p
   swift --version
   df -h /
   ```

   Prefer `make doctor`, which performs these checks read-only and redacts private content. If Command Line Tools are missing, ask the user to run `xcode-select --install`, wait for the user to complete Apple's installer, and then repeat the checks. Do not install unrelated package managers or full Xcode for this beta.
3. Preserve the compatibility data root `~/Library/Application Support/Klim Talks/` during installation and ordinary updates.
4. Build and install only through the reviewed repository script:

   ```sh
   ./scripts/install.sh --source
   ```

   This creates or reuses a unique local signing certificate in the login Keychain, trusts it only for user-domain code signing, and builds with hardened runtime plus a certificate-bound requirement. It is not a Developer ID-signed public binary. If `/Applications` is not writable, do not use `sudo`. Create a personal Applications folder and use:

   ```sh
   mkdir -p "$HOME/Applications"
   ./scripts/install.sh --source --destination "$HOME/Applications"
   ```

5. Never disable Gatekeeper, remove quarantine attributes as a bypass, reset privacy permissions, force-quit a running copy, dump another app’s Accessibility value, or expose transcript/audio/clipboard content in diagnostics.
6. Guide—not bypass—the user through the in-app model download, Microphone and Accessibility permissions, shortcut selection, and a first dictation.
7. For an update requested by the owner, pull only fast-forward changes and use the source updater. Preserve local data:

   ```sh
   git pull --ff-only
   ./scripts/update.sh --source
   ```

8. Never remove data automatically. For a complete local removal, first ask the owner explicitly, then use `./scripts/uninstall.sh --purge` interactively. `--purge --yes` is only for an already owner-approved non-interactive cleanup.

This source-only beta has no official DMG, Homebrew cask, public update feed, or automatic updater. Do not search for or invent those installation paths. `make package` is development verification only.

## Windows 11 x64

Use this exact prompt:

> Install Sprekr on Windows 11 x64 from the `Windows-gebruikers` source branch. Read AGENTS.md, README.md, SECURITY.md, PRIVACY.md and docs/AGENT_INSTALL.md first. Run `.\windows\scripts\doctor-windows.ps1`, explain any failing requirement without showing private content, then run `.\windows\scripts\install-windows.ps1`. Never run as administrator, bypass SmartScreen or Windows integrity controls, change Microphone privacy settings for me, remove `%LOCALAPPDATA%\Sprekr`, or print transcript, audio, clipboard or target-field contents. After launch, guide me through the verified model download, Microphone access, the Hold and Toggle controls, Escape, the six-second Undo window, and a first dictation into a normal non-elevated editable field.

A Windows agent must:

1. Confirm the checkout remote and exact `Windows-gebruikers` branch, then preserve all local changes.
2. Run the redacted doctor. Require current Windows 11 x64, .NET SDK 10.0.302 x64 and approximately 1.5 GB free.
3. Run PowerShell as the normal user. Never elevate the shell, installer or Sprekr.
4. Install only with `install-windows.ps1`. It performs a locked restore and self-contained `win-x64` publish under `%LOCALAPPDATA%\Programs\Sprekr`.
5. Preserve `%LOCALAPPDATA%\Sprekr` on installs, updates and ordinary uninstall. A purge requires a separate explicit user request and the exact `-PurgeData -ConfirmPurge Sprekr` confirmation.
6. Explain that the development ZIP is unsigned, that no production MSIX exists, and that disabling SmartScreen or other trust controls is not a supported fix.
7. Explain expected v1 limitations: no Windows 10/ARM64, no local Dutch/English translation, and no input into elevated administrator targets.
