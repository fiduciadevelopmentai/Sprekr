# Source updates and aftercare

Sprekr is a source-only beta. It has no automatic updater, public update feed, official DMG, Homebrew cask, or notarized binary.

## Safe update path

Before updating, inspect `git status`. Preserve local work and do not pull over uncommitted changes. From a clean trusted checkout:

```sh
git pull --ff-only
make doctor
./scripts/update.sh --source
```

The updater:

1. requires Apple silicon and a writable destination without invoking `sudo`;
2. refuses to force-quit a running app;
3. reuses the local code-signing certificate recorded in the login Keychain;
4. signs with hardened runtime and a designated requirement bound to the bundle ID and certificate fingerprint;
5. verifies the staged app before atomic replacement;
6. stops if an already certificate-signed installation has a different identity;
7. leaves Application Support data, Keychain encryption keys, preferences, and the model untouched.

The first transition from a legacy ad-hoc development install is recognized explicitly and may require the user to approve macOS permissions once. Every later source update must retain the certificate identity.

## Release notes

Changes should be documented in normal GitHub releases or repository notes without attaching an official binary. State whether a change affects:

- model manifest revision or download size;
- macOS or Swift requirements;
- permissions or privacy behavior;
- History/Dictionary migration;
- Hold, Toggle, Escape, Flow Bar, language, translation, or formatting behavior;
- manual action required after update.

Never claim that a local `development-adhoc` DMG is an official release. `make package` exists only to verify bundle composition and packaging locally.

## Recovery

- If the signing identity is missing, stop; do not ad-hoc sign or create a replacement over an existing certificate-bound installation.
- If encrypted data cannot unlock, preserve the `.enc` files and Keychain items. Never generate a new key over existing ciphertext.
- If the model fails integrity validation, Sprekr ignores it, removes only its own pinned model subdirectory, and retries once.
- If TCC access is denied, guide the user through System Settings. Never reset TCC or simulate consent.

The redacted `make doctor` command is the first diagnostic step. It never displays transcript, audio, clipboard, or text-field content.
