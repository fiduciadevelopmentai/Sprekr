# Architecture

## Principles

- Local-first: no API keys, accounts, telemetry, cloud sync, or remote transcription.
- Replaceable transcription: UI layers depend on `TranscriptionEngine`, never directly on FluidAudio.
- Native macOS control: SwiftUI owns content; AppKit owns agent lifecycle, global input, focus, non-activating panels, and window behavior.
- Sensitive data minimization: raw audio is temporary; no audio, transcript, or clipboard content may be logged.

## Runtime

| Component | Choice |
| --- | --- |
| Language | Swift 6 |
| UI | SwiftUI + AppKit |
| Minimum OS | macOS 14 |
| Bundle ID | `com.klimtalks.app` (legacy compatibility identity) |
| ASR dependency | `https://github.com/FluidInference/FluidAudio.git`, exactly `v0.15.5` (`19600a485baa4998812e4654b70d2bab8f2c9949`) |
| Speech model | FluidInference Core ML conversion of NVIDIA Parakeet TDT 0.6B v3, INT8 encoder |
| Model root | `~/Library/Application Support/Klim Talks/Models` (retained for data continuity) |

Visible product naming lives under `SprekrIdentity`; frozen macOS/data anchors live
under `SprekrIdentity.Compatibility`. Shell tooling mirrors that boundary in
`scripts/product-identity.sh`. They intentionally remain legacy values so a visible
rename cannot silently create a second settings domain, encryption identity, model
cache, or privacy-permission identity.
| Persistence | Encrypted local store; database key in macOS Keychain |
| Updates | Source-only installer/updater with one certificate-bound local identity |

## Service boundaries

```text
SwiftUI scenes ── AppLifecycleController ── MenuBar / Windows / FlowBarController
       │                         │
       ├── TranscriptRepository  ├── HotkeyManager
       ├── DictionaryRepository  ├── PermissionService
       ├── SpokenWordLibrary     ├── AudioCaptureService
       └── InsightsService       ├── TranscriptionEngine
                                 │     └── LocalParakeetEngine → FluidAudio/Core ML
                                 ├── LocalTranslationService → Apple Translation
                                 └── TextInjectionService
```

Required interfaces and local boundaries are `ModelManager`, `AudioCaptureService`, `TranscriptionEngine`, `LocalParakeetEngine`, `PinnedModelInstaller`, `LocalTranslationService`, `TextInjectionService`, its internal `AccessibilityTreeClient`, `HotkeyManager`, `FlowBarController`, `AppLifecycleController`, `TranscriptRepository`, `DictionaryRepository`, `SpokenWordLibrary`, `SpokenWordClassifier`, `InsightsService`, and `PermissionService`.

`TranscriptionEngine` accepts a temporary local audio-file URL and returns a transcript plus timing metadata. `AudioCaptureService` writes the selected device's native PCM format; FluidAudio performs the model's input conversion inside the sole `LocalParakeetEngine` boundary. A fake engine conforms to the same interface in deterministic tests.

## Model lifecycle

`ModelManager` checks free space and exposes progress. `PinnedModelInstaller` owns the immutable HTTPS URLs, resumable `.part` files, byte sizes, SHA-256 verification, retry, and atomic activation for the reviewed v3/INT8 revision. `LocalParakeetEngine` enables FluidAudio offline mode and calls only `AsrModels.load(from: ...)` after all files pass the manifest. FluidAudio remains the Core ML loader and inference engine, never the network downloader.

## Dictation flow

1. `HotkeyManager` receives only the configured global talk keys. Its locked event state enters a pass-through capture mode while Settings or onboarding records a replacement, so the candidate keyboard, modifier, or mouse event cannot start, stop, or cancel dictation. Candidate pairs are validated before persistence for exact, modifier, and physical-key overlap. `TextInjectionService` clears the prior delivery observation without locking dictation to the app or field where recording began, then generically requests both `AXManualAccessibility` and `AXEnhancedUserInterface` when the frontmost process currently exposes no editable target. The idempotent requests activate Chromium/Electron web trees without recognizing an app, bundle identifier, browser, or website and are never reversed by Sprekr.
2. `AudioCaptureService` records temporary PCM with no elapsed-time cutoff, emits actual level samples to the non-activating flow bar, and handles interruption/cancel/route loss. Audio-engine configuration notices are debounced for 650 ms and stop capture only when the engine has actually stopped or the input format is invalid, so healthy transient route notifications do not end a long dictation.
3. `LocalParakeetEngine` transcribes with automatic source-language detection on a detached worker; UI remains responsive.
4. `SpokenNumberFormatter` converts Dutch and English spoken cardinals, compounds, scales, negatives, and decimals into digits immediately after recognition. It formats grouping and decimal separators for the final output language, groups only from five digits, and leaves ambiguous `een`, dates, times, telephone numbers, codes, versions, IP addresses, ordinals, and overflow untouched. `SpokenSymbolFormatter` then converts explicit Dutch and English spoken symbol names. `SpokenEmailFormatter` follows with a bounded parser that activates only for a literal `@` or a narrow spoken-at alias, joins at most six local-name parts, accepts explicit dot and local separator commands, corrects only unique safe provider/TLD variants in domain position, validates the candidate, and lowercases the finished address. Unknown valid company domains remain unchanged, while social handles, double-at input, and addresses without a dotted domain remain prose. All three passes run before optional Smart formatting and translation, remain active when Smart formatting is disabled, and are idempotently available through `TranscriptFormatter`. Symbol matching is longest-first and non-cascading, with context-aware spacing for punctuation, quotes, brackets, URLs, paths, operators, percentages, and currencies. Ambiguous words are accepted only in command-like contexts; point labels, contract references, percentages in prose, and protected idioms remain unchanged.
5. `TranscriptFormatter` applies conservative, deterministic local self-correction, spoken spelling instructions, the canonical `Sprekr` brand spelling, common code-switch spelling normalization, recognizer-tail cleanup, semantic punctuation, lists, and paragraph formatting in the detected source language. `SemanticPunctuationFormatter` quotes short subjects after Dutch or English meaning-question frames and turns a fixed set of genuinely forward-pointing description phrases into colon lead-ins. `ConversationalPunctuationFormatter` joins only short dependent Dutch/English continuations behind a comma and leaves complete new sentences intact. Demonstrative/context questions, already quoted subjects, overlong candidates, and impact phrases containing contextual connectors remain untouched. Numbered paragraph cues are consumed as layout instructions. `DiscourseStructureFormatter` first runs explicit sequential `Punt 1 / Punt 2` and English point labels, preserving their labels as separate paragraphs; incomplete, duplicate, out-of-order, and single references remain prose. Sequential `Ten eerste / Ten tweede` and English ordinal markers then retain their labels and become separate blank-line-delimited paragraphs, with recognizer punctuation repaired conservatively. General paragraphing follows: a clear transition can split from roughly 40 words, a cohesive semantic shift from 70 words, and the safest sentence boundary near a 70-word target from 85 words while keeping about 20 words on each side. Finally, only a clear list-intent cue with three to ten short safe parallel items becomes round bullets with a blank line between items. Self-correction remains restricted to high-confidence immediate restarts, spoken repair markers, conflicting numeric values behind the same repeated phrase, and a standalone spelling-note sentence whose target occurs earlier. `what I mean` / `wat ik bedoel` are explicitly excluded from the repair-marker interpretation. A spelling note can appear at the end or between dictated sentences; surrounding content stays intact. A truncated tail is removed only when at least two complete equal words are followed by a strict prefix of that word; without a fragment, only three or more longer copies at the transcript end are collapsed, with common emphasis words protected. `StutterCleanupFormatter` then performs a separate text-level rough-copy pass for partial-sound, adjacent word, short-phrase, constrained question-boundary repetitions, and the high-confidence unnatural `of en` / `or and` alternative-restart bridge. Planned emphasis words, valid `dat dat` / `had had` constructions, capitalized duplicate names, and a following sentence with its own finite verb are protected. Ordinary intentional repetition and cohesive long-form dictation stay intact.
6. `DictationLanguagePlan` compares the detected source with the selected output. `Automatic` preserves the source language; explicit Dutch or English uses `LocalTranslationService` only when source and target differ. Before Apple Translation receives text, validated email ranges are replaced with deterministic local placeholders and restored exactly afterward; if a placeholder is changed, translation fails safely and delivery falls back to the already formatted source. Apple Translation otherwise processes the text on device on macOS 15+, with the Flow Bar hosting one-time system language-pack approval. A current macOS 26 system with installed packs uses the direct installed-session path.
7. `DictionaryRepository` always applies active corrections in the final delivered language, independently of Smart formatting. `DictionaryCorrectionEngine` resolves exact canonical preferred forms and aliases in one longest-first range pass, restoring saved capitals, spacing, and diacritics without cascading replacements. Inside a validated email range the same learned alias is applied in lowercase so a personal correction such as `Saet` → `Saed` yields `a.saed@…`; one actual range replacement increments `appliedCount` exactly once. Unmatched alphabetic tokens can use a bounded Damerau-Levenshtein comparison only against previously learned single-word aliases; a correction requires one unique closest entry, while ambiguous candidates remain untouched.
8. `SpokenWordLibrary` tokenizes encrypted History only after it has been decrypted in memory, aggregates frequency and latest use, and asks the local cached `NSSpellChecker` classifier to separate recognized vocabulary from potential names, brands, and uncommon spellings. Existing preferred spellings and aliases are excluded from observations; editing an observation creates an explicit Dictionary alias, names and brands default to both languages, changing a preferred spelling preserves its prior form as an alias, and alias normalization deduplicates case and diacritic variants.
9. `TranscriptRepository` persists the transcript before injection.
10. At delivery time, `TextInjectionService` resolves the current frontmost app and focused editable element again through standard text roles, writable selection/value capabilities, browser text-marker signals, editable-ancestor attributes, bounded parent traversal, and bounded traversal of descendants that explicitly report focus. A focused `AXGroup` counts as a custom text editor only when selected text, selected text range, or selected text-marker range is writable; a writable value alone remains insufficient, and ordinary `AXWebArea` or static page selection stays excluded. A small injectable `AccessibilityTreeClient` owns focused-element inspection, activation requests, and retry timing. Activation results and their first request time are cached by PID plus process launch date, so Chromium's enhanced-UI debounce is never restarted. Still-building trees are checked at absolute 40, 120, 280, 600, 1,200, and 2,250 ms checkpoints, with checkpoints that elapsed during recording skipped at delivery. Secure, disabled, and positively read-only targets are refused. It prefers clipboard + Command-V to the current app PID, verifies observable edits before any AX/Unicode retry, and otherwise leaves the transcript in History and copies it for explicit user paste. A process that accepts activation but still exposes no usable web tree receives a distinct Accessibility explanation instead of a blind paste.
11. Brand resources are assembled explicitly into `Contents/Resources`: `SprekrIcon.icns` is generated from the supplied near-black icon artwork, while the cropped transparent mark and custom PCM AIFF completion tone are required build inputs. The build fails if either runtime asset is absent.
12. The temporary audio file is deleted on success, cancellation, failure, device loss, termination, and stale-startup cleanup. Routine success keeps the frozen Flow Bar visible for 1.55 seconds and collapses it over 0.46 seconds without a success label; only clipboard recovery becomes persistent guidance.

## Lifecycle

The app is a menu-bar agent with a normal main window. Closing the main window does not terminate hotkeys or the flow bar; only **Quit Sprekr** shuts down the app. `SMAppService` manages launch at login. The flow bar is an `NSPanel` that does not become key or steal focus, targets the active screen, and re-establishes state after sleep/wake or display/Space changes.
