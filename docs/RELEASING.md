# Source-only release procedure

Public binary distribution is out of scope for the first Sprekr release. Do not publish a DMG, Homebrew cask, automatic update feed, or notarized binary. `make package` creates only `Sprekr-<version>-arm64-development-adhoc.dmg` for local verification.

## Before the repository becomes public

1. Keep `fiduciadevelopmentai/Sprekr` private while sanitizing and running checks.
2. Review the complete worktree and Git history for secrets, personal paths, models, recordings, transcripts, logs, signing material, and generated app artifacts.
3. Run:

   ```sh
   make audit
   make integration-test
   ```

4. Confirm the weekly real-model workflow, macOS CI, CodeQL, dependency review, and gitleaks checks are green.
5. Verify Onest Regular/Medium/Bold and the OFL are tracked and bundled, and that Satoshi/Fontshare and Sparkle are absent from Git history intended for publication and from the built bundle.
6. Perform the clean-install and source-update acceptance flow in `docs/SECURITY_AUDIT.md` on macOS 14 and the current macOS release.
7. Verify GitHub Private Vulnerability Reporting, secret scanning, push protection, and branch protection in the repository UI.
8. Make the repository public only after the owner’s later product change, a fresh audit, and an explicit publication instruction.

## Required GitHub controls

For `main`, require pull requests, the configured green checks, linear history, and block force-push and deletion. Zero approvals is acceptable for the solo-owner flow. Default Actions permissions stay read-only. Workflows never use `pull_request_target`, and third-party actions are pinned to immutable commit SHAs.

Dependabot checks SwiftPM and GitHub Actions weekly. The large real-model test runs weekly and manually with a cache key containing revision `aed02740059203c4a87495924f685de3722ae9ce`.

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
