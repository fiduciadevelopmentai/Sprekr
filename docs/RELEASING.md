# macOS source and Windows development release procedure

Production binary distribution is out of scope for the first Sprekr release. Do not publish a DMG, Homebrew cask, automatic update feed, notarized binary, MSIX or signed Windows installer. `make package` creates only `Sprekr-<version>-arm64-development-adhoc.dmg` for local verification. Windows CI may publish only `Sprekr-windows-x64-development-unsigned.zip` plus its SHA-256.

## Before the repository becomes public

1. Preserve the clean `master` root commit and keep all Windows development on `Windows-gebruikers` until both platform gates pass.
2. Review the complete worktree and Git history for secrets, personal paths, models, recordings, transcripts, logs, signing material, and generated app artifacts.
3. Run:

   ```sh
   make audit
   make integration-test
   ```

4. Confirm the weekly real-model workflow, macOS CI, CodeQL, dependency review, and gitleaks checks are green.
5. Verify Onest Regular/Medium/Bold and the OFL are tracked and bundled, and that Satoshi/Fontshare and Sparkle are absent from Git history intended for publication and from the built bundle.
6. Perform the clean-install and source-update acceptance flow in `docs/SECURITY_AUDIT.md` on macOS 14 and the current macOS release.
7. Verify GitHub Private Vulnerability Reporting, secret scanning, push protection, Dependabot and branch protection.
8. Do not merge `Windows-gebruikers` until Windows CI plus real Windows 11 x64 hardware acceptance pass.

## Required GitHub controls

For `master`, require pull requests, the configured green checks, linear history, and block force-push and deletion. Zero approvals is acceptable for the solo-owner flow. Default Actions permissions stay read-only. Workflows never use `pull_request_target`.

Dependabot checks SwiftPM and GitHub Actions weekly. The large real-model test runs weekly and manually with a cache key containing revision `aed02740059203c4a87495924f685de3722ae9ce`.

Dependabot also checks NuGet under `/windows`. Windows restores use committed lockfiles and `--locked-mode`. The scheduled Windows model integration uses only `test_wavs/en.wav` from the verified sherpa model archive and never prints transcript text.

## Windows acceptance gate

Run on Windows 11 x64:

```powershell
.\windows\scripts\doctor-windows.ps1
Set-Location windows
dotnet restore .\Sprekr.sln --locked-mode --configfile .\NuGet.Config
dotnet build .\Sprekr.sln --configuration Release --no-restore
dotnet test .\tests\Sprekr.Windows.Tests\Sprekr.Windows.Tests.csproj --configuration Release --no-build
.\scripts\build-development-unsigned.ps1
```

Manually verify built-in, USB and headset microphones; Hold/Toggle/Escape/six-second Undo; keyboard and mouse controls; sleep/resume and unlock; multi-monitor Flow Bar placement; launch at login; and insertion into Notepad, Office, Chromium, Firefox and Electron. Password, disabled, read-only, static/non-editable and elevated administrator targets must refuse safely. Windows 10, ARM64 and local translation are expected unsupported cases.

After Windows work, rerun the full macOS regression gate from the same commit:

```sh
make test
make integration-test
make build
make audit
```

## Local artifacts

The development DMG is not notarized and is not a supported installation channel. It may be mounted during `make audit` to verify:

- arm64 architecture;
- hardened-runtime ad-hoc development signature;
- isolated `com.klimtalks.app.development` identity;
- required fonts, licenses, brand assets, and model manifest;
- absence of Satoshi, Sparkle, secrets, personal absolute paths, models, audio, and transcripts.

The only supported user commands remain:

```sh
./scripts/install.sh --source
./scripts/update.sh --source
```

Never commit or publish certificates, private keys, provisioning profiles, notarization credentials, models, raw audio, transcripts, clipboard data, or unredacted logs. Never weaken Gatekeeper or TCC.
