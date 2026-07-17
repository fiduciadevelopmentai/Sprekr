# Privacy

Sprekr is designed to keep dictation on your Mac.

- Audio is captured locally and processed locally with Core ML.
- The initial speech-model download is required once. Sprekr contacts only fixed HTTPS URLs for the bundled, commit-pinned FluidInference manifest, without cookies, credentials, or registry environment overrides. Every file is size- and SHA-256-verified before local use. Optional output translation may also require macOS to download Apple's Dutch/English language packs once; after those packs are present, both transcription and translation work without Wi-Fi.
- Sprekr does not use accounts, API keys, cloud synchronization, analytics, telemetry, advertising SDKs, or remote logging.
- Raw audio exists only in an owner-only (`0700` directory, `0600` file) temporary location while a dictation is active. It is deleted after successful transcription, cancellation, or error.
- Transcript history and Dictionary entries remain on device in AES-GCM encrypted local storage. The encryption keys are stored in the user’s macOS Keychain with device-only accessibility; private storage files are owner-only.
- The spoken-word library is derived in memory from encrypted History whenever History or Dictionary changes. Sprekr does not create a separate plaintext word index. Clearing History therefore removes the derived observations; explicit saved corrections remain in the encrypted Dictionary until the user clears them separately.
- When **Learn immediate corrections** is enabled, Sprekr may temporarily re-read only the range it just inserted plus up to 12 characters before and 18 characters after it. This boundary exists only in memory, expires after about 30 seconds, is never used in secure text fields, and is never written to History or logs. Only one stable word replacement can become an encrypted Dictionary alias; ambiguous or broader edits are discarded.
- Immediately after delivery, Sprekr never reads the complete value of the target text field. It compares character count and selection range and may read at most 64 characters from only the segment where the new transcript was expected. Secure and read-only fields are excluded. If delivery cannot be determined safely, Sprekr does not perform a second automatic write.
- Clipboard content is used only for the last-resort paste fallback and is restored when it is safe to do so. Clipboard content is never logged or retained as telemetry.
- Diagnostics must never include transcript text, audio, clipboard contents, or the contents of another app’s text field.
- When an explicit Dutch or English output language is selected, Apple's Translation framework processes the formatted transcript on device. Apple states that it may collect framework usage/performance metadata such as the app bundle ID and source/target languages, but not the original or translated text. Sprekr itself does not transmit or log that metadata.

Microphone access is necessary to hear a dictation. The permission is granted to Sprekr rather than to one physical microphone, so switching between built-in, USB, and headset inputs does not create another permission request. Accessibility access is necessary to place a finished transcript into the text field that was active when dictation began and, only when correction learning is enabled and supported, to inspect the narrow just-inserted range described above. Both permissions are requested in context, can be revoked in System Settings at any time, and have recovery guidance in the app.

The current local data root is:

```text
~/Library/Application Support/Klim Talks/
```

Users can export history, clear history, clear the Dictionary, or remove the speech model from Settings. History export requires explicit confirmation that JSON is readable, unencrypted plaintext; the exported file is created with owner-only `0600` permissions. The Privacy page shows local record counts and requires an explicit destructive confirmation before the complete encrypted History or Dictionary can be removed. Ordinary source updates preserve this data and a valid model.
