import AppKit
import AVFoundation
import Combine
import Foundation
import Security
import SprekrCore

enum ShortcutUpdateResult: Equatable {
    case accepted
    case rejected(String)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

enum DictationRecoveryMessage {
    static let historySaveFailed = "Couldn’t save history. Copied. Press ⌘V to paste."
    static let restoredTranscriptCopied = "Your restored text was copied. Press ⌘V to paste."

    static func insertionFailed(reason: TextInjectionRecoveryReason) -> String {
        switch reason {
        case .insertionFailed:
            "Couldn’t insert. Copied. Press ⌘V to paste."
        case .noEditableTarget, .protectedOrReadOnlyTarget:
            "Copied. Select a text field, then press ⌘V."
        case .accessibilityTreeUnavailable:
            "Copied. This app hides its text fields from Accessibility."
        }
    }
}

enum DictationFeedbackPolicy {
    /// Gives the destination app one render pass after insertion before the
    /// audible confirmation starts. This keeps the cue perceptually attached
    /// to the visible text without making transcription feel slower.
    static let completionCueDelay = Duration.milliseconds(70)
    static let startSoundResourceName = "SprekrStart"
    static let startSoundVolume: Float = 0.38

    static func shouldPlayCompletionCue(copiedForRecovery: Bool) -> Bool {
        !copiedForRecovery
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var values: SprekrSettings
    private let key = SprekrIdentity.Compatibility.settingsKey

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SprekrSettings.self, from: data) {
            values = decoded
        } else {
            values = SprekrSettings()
        }
    }

    func update(_ mutation: (inout SprekrSettings) -> Void) {
        mutation(&values)
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Resets only the settings that belong to the first-run experience.
    /// History, Dictionary entries, the Keychain encryption key, and the
    /// downloaded speech model live elsewhere and are intentionally untouched.
    func resetForOnboarding() {
        values = SprekrSettings()
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

@MainActor
final class SprekrAppController: ObservableObject {
    private struct DictationDeliveryContext {
        let deliverInApp: Bool
        let outputLanguage: RecognitionLanguage
        let smartFormatting: Bool
        let restoredAfterCancellation: Bool

        func restoringCancelledRecording() -> Self {
            Self(
                deliverInApp: deliverInApp,
                outputLanguage: outputLanguage,
                smartFormatting: smartFormatting,
                restoredAfterCancellation: true
            )
        }
    }

    private struct PendingCancelledDictation {
        let id: UUID
        let audioURL: URL
        let context: DictationDeliveryContext
    }

    let settings = SettingsStore()
    let permissions = PermissionService()
    let audioCapture = AudioCaptureService()
    let modelManager = ModelManager()
    let flowBar = FlowBarController()
    let lifecycle = AppLifecycleController()
    let hotkey = HotkeyManager()

    @Published var section: AppSection = .home
    @Published private(set) var transcripts: [TranscriptRecord] = []
    @Published private(set) var dictionaryEntries: [DictionaryEntry] = []
    @Published private(set) var spokenWords: [SpokenWordObservation] = []
    @Published private(set) var historyLoadError: String?
    @Published private(set) var historyNeedsKeychainUnlock = false
    @Published private(set) var toast: String?
    @Published private(set) var isTranscribing = false
    @Published private(set) var lastError: String?
    @Published private(set) var onboardingTestTranscript: String?
    @Published private(set) var isTalkKeyPreviewActive = false
    @Published private(set) var isMicrophoneTestActive = false

    private let transcriptRepository = TranscriptRepository()
    private let dictionaryRepository = DictionaryRepository()
    private let spokenWordClassifier = SpokenWordClassifier()
    private let textInjection = TextInjectionService()
    private var levelTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var currentTemporaryAudioURL: URL?
    private var pendingCancelledDictation: PendingCancelledDictation?
    private var undoExpiryTask: Task<Void, Never>?
    private var activeStartID: UUID?
    private var isStartingDictation = false
    private var deliverTranscriptToOnboarding = false
    private var onboardingTalkKeyPreviewEnabled = false
    private var didBoot = false
    private var startSound: NSSound?
    private var completionSound: NSSound?
    private var cancellables = Set<AnyCancellable>()

    init() {
        startSound = Self.loadBundledSound(
            named: DictationFeedbackPolicy.startSoundResourceName,
            volume: DictationFeedbackPolicy.startSoundVolume
        )
        completionSound = Self.loadCompletionSound()

        // `SprekrAppController` is the object observed by the SwiftUI root. Relay
        // SettingsStore changes so appearance, shortcut mode, language, and
        // onboarding choices redraw immediately instead of waiting for an
        // unrelated controller publication.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        lifecycle.onShowApp = { [weak self] in self?.activateFirstWindow() }
        lifecycle.onToggleDictation = { [weak self] in self?.toggleDictation() }
        lifecycle.onWillTerminate = { [weak self] in self?.prepareForTermination() }

        flowBar.setOutputLanguage(settings.values.recognitionLanguage)
        flowBar.onToggle = { [weak self] in self?.toggleDictation() }
        flowBar.onUndo = { [weak self] in self?.undoCancelledDictation() }
        flowBar.onLanguageChange = { [weak self] language in
            self?.updateSettings { $0.recognitionLanguage = language }
        }

        hotkey.onStart = { [weak self] in self?.startDictation() }
        hotkey.onStop = { [weak self] in self?.stopDictation() }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() }
        audioCapture.onCaptureFailure = { [weak self] message in
            self?.handleAudioCaptureFailure(message)
        }
        audioCapture.onAvailableInputsChange = { [weak self] devices in
            self?.handleAvailableInputsChanged(devices)
        }
    }

    func boot(delegate: SprekrAppDelegate, quietLaunch: Bool) async {
        guard !didBoot else { return }
        didBoot = true
        delegate.lifecycle = lifecycle
        lifecycle.configure(quietLaunch: quietLaunch)
        lifecycle.applyDockVisibility(settings.values.showInDock)
        audioCapture.selectInput(named: settings.values.microphoneUID)
        if settings.values.onboardingCompleted {
            lifecycle.migrateLaunchAtLoginForRebrandIfNeeded(
                settings.values.launchAtLogin
            )
            configureHotkey()
            flowBar.showIfNeeded(settings.values.showFlowBar)
        } else {
            // Do not register a background login item until the user has accepted onboarding.
            lifecycle.applyLaunchAtLogin(false)
            flowBar.showIfNeeded(false)
        }
        permissions.refresh()
        await reloadLocalData(allowingKeychainInteraction: false)
        await modelManager.refresh()
    }

    func reloadLocalData(allowingKeychainInteraction: Bool = true) async {
        do {
            transcripts = try await transcriptRepository.all(
                allowingKeychainInteraction: allowingKeychainInteraction
            )
            historyLoadError = nil
            historyNeedsKeychainUnlock = false
        } catch {
            historyLoadError = error.localizedDescription
            let nsError = error as NSError
            historyNeedsKeychainUnlock = nsError.domain == NSOSStatusErrorDomain
                && nsError.code == Int(errSecInteractionNotAllowed)
            lastError = error.localizedDescription
        }
        do { dictionaryEntries = try await dictionaryRepository.all() }
        catch { lastError = error.localizedDescription }
        spokenWords = SpokenWordLibrary.build(
            from: transcripts,
            dictionaryEntries: dictionaryEntries,
            isKnown: { [spokenWordClassifier] word, language in
                spokenWordClassifier.isKnown(word, language: language)
            }
        )
    }

    func toggleDictation() {
        if audioCapture.isRecording || isStartingDictation {
            stopDictation()
        } else if flowBar.acceptsNewDictation {
            startDictation()
        }
    }

    func toggleOnboardingTestDictation() {
        if audioCapture.isRecording || isStartingDictation {
            stopDictation()
        } else {
            deliverTranscriptToOnboarding = true
            startDictation()
        }
    }

    func startDictation() {
        guard !isStartingDictation,
              !isTranscribing,
              !audioCapture.isRecording,
              flowBar.acceptsNewDictation
        else { return }
        discardPendingCancelledDictation(resetFlowBar: false)
        flowBar.captureActiveScreen()
        textInjection.prepareForDictation()
        hotkey.setDictationActive(true)
        isStartingDictation = true
        let startID = UUID()
        activeStartID = startID
        startTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeStartID == startID {
                    self.activeStartID = nil
                    self.startTask = nil
                    self.isStartingDictation = false
                }
            }
            guard await self.permissions.requestMicrophone() else {
                self.deliverTranscriptToOnboarding = false
                self.hotkey.setDictationActive(false)
                self.lastError = SprekrError.noMicrophonePermission.localizedDescription
                self.flowBar.setError("Microphone access is needed")
                return
            }
            guard !Task.isCancelled, self.activeStartID == startID else { return }
            do {
                try self.audioCapture.start(deviceUID: self.settings.values.microphoneUID)
                if self.onboardingTalkKeyPreviewEnabled {
                    self.isTalkKeyPreviewActive = true
                }
                self.playStartSound()
                self.flowBar.setListening(level: self.audioCapture.level)
                self.beginLevelUpdates()
            } catch {
                self.deliverTranscriptToOnboarding = false
                self.hotkey.setDictationActive(false)
                self.lastError = error.localizedDescription
                self.flowBar.setError("Microphone unavailable")
            }
        }
    }

    func stopDictation() {
        if isStartingDictation {
            cancelPendingStart()
            flowBar.reset()
            return
        }
        if isTalkKeyPreviewActive {
            stopTalkKeyPreview(showSuccess: true)
            return
        }
        if isMicrophoneTestActive {
            stopMicrophoneTest()
            return
        }
        guard let audioURL = audioCapture.stop() else { return }
        beginTranscription(audioURL: audioURL, context: finishCaptureContext())
    }

    func cancelDictation() {
        if isStartingDictation {
            cancelPendingStart()
            flowBar.reset()
            showToast("Dictation cancelled.")
            return
        }
        if isTalkKeyPreviewActive {
            stopTalkKeyPreview(showSuccess: false)
            showToast("Talk key test cancelled.")
            return
        }
        guard audioCapture.isRecording else { return }
        guard let audioURL = audioCapture.stop() else { return }
        let pending = PendingCancelledDictation(
            id: UUID(),
            audioURL: audioURL,
            context: finishCaptureContext()
        )
        pendingCancelledDictation = pending
        undoExpiryTask?.cancel()
        let deadline = Date.now.addingTimeInterval(6)
        flowBar.setUndo(deadline: deadline)
        showToast("Recording cancelled. Click Undo within 6 seconds to keep it.")
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled,
                  let self,
                  self.pendingCancelledDictation?.id == pending.id else { return }
            self.discardPendingCancelledDictation(resetFlowBar: true)
        }
    }

    func undoCancelledDictation() {
        guard let pending = pendingCancelledDictation else { return }
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        pendingCancelledDictation = nil
        showToast("Recording restored. Transcribing now.")
        beginTranscription(
            audioURL: pending.audioURL,
            context: pending.context.restoringCancelledRecording()
        )
    }

    func deleteTranscript(_ id: UUID) {
        Task {
            do {
                try await transcriptRepository.delete(id)
                await reloadLocalData()
            } catch { lastError = error.localizedDescription }
        }
    }

    func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Copied to clipboard.")
    }

    func clearHistory() {
        Task {
            do {
                try await transcriptRepository.clear()
                await reloadLocalData()
                showToast("History cleared.")
            } catch { lastError = error.localizedDescription }
        }
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sprekr History.json"
        panel.message = HistoryExportPolicy.warning
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    try await self.transcriptRepository.export(to: url)
                    self.showToast("History exported.")
                } catch { self.lastError = error.localizedDescription }
            }
        }
    }

    func saveDictionaryEntry(_ entry: DictionaryEntry) {
        persistDictionaryEntry(entry, confirmationMessage: nil)
    }

    func saveDictionaryCorrection(_ entry: DictionaryEntry) {
        let message: String
        if let alias = entry.aliases.first {
            message = "Saved. Next time Sprekr hears “\(alias)”, it will write “\(entry.preferredSpelling)”."
        } else {
            message = "Saved. Future dictations will use “\(entry.preferredSpelling)” exactly as written."
        }
        persistDictionaryEntry(entry, confirmationMessage: message)
    }

    private func persistDictionaryEntry(
        _ entry: DictionaryEntry,
        confirmationMessage: String?
    ) {
        Task {
            do {
                try await dictionaryRepository.save(entry)
                await reloadLocalData()
                if let confirmationMessage { showToast(confirmationMessage) }
            } catch { lastError = error.localizedDescription }
        }
    }

    func deleteDictionaryEntry(_ id: UUID) {
        Task {
            do {
                try await dictionaryRepository.delete(id)
                await reloadLocalData()
            } catch { lastError = error.localizedDescription }
        }
    }

    func clearDictionary() {
        Task {
            do {
                try await dictionaryRepository.clear()
                await reloadLocalData()
                showToast("Dictionary cleared.")
            } catch { lastError = error.localizedDescription }
        }
    }

    func updateSettings(_ mutation: (inout SprekrSettings) -> Void) {
        settings.update(mutation)
        flowBar.setOutputLanguage(settings.values.recognitionLanguage)
        audioCapture.selectInput(named: settings.values.microphoneUID)
        lifecycle.applyAppearance(settings.values.appearance)
        lifecycle.applyDockVisibility(settings.values.showInDock)
        if settings.values.onboardingCompleted {
            configureHotkey()
            lifecycle.applyLaunchAtLogin(settings.values.launchAtLogin)
            flowBar.showIfNeeded(settings.values.showFlowBar)
        } else if onboardingTalkKeyPreviewEnabled {
            configureHotkeyBindings()
            hotkey.start()
        }
    }

    func updateShortcut(
        _ candidate: ShortcutConfiguration,
        for mode: DictationMode
    ) -> ShortcutUpdateResult {
        if let message = HotkeyManager.validationMessage(
            for: candidate,
            mode: mode,
            holdShortcut: settings.values.holdShortcut,
            toggleShortcut: settings.values.toggleShortcut
        ) {
            return .rejected(message)
        }

        updateSettings {
            if mode == .hold {
                $0.holdShortcut = candidate
            } else {
                $0.toggleShortcut = candidate
            }
        }
        return .accepted
    }

    func setShortcutCaptureActive(_ active: Bool) {
        hotkey.setShortcutCaptureActive(active)
    }

    func finishOnboarding() {
        updateSettings { $0.onboardingCompleted = true }
        hotkey.start()
        showToast("Sprekr is ready.")
    }

    /// Returns the app to the first-run experience without removing local
    /// content. macOS privacy grants are managed by macOS, so they remain
    /// visible as already granted until the user revokes them in System
    /// Settings; the onboarding still walks through each permission step.
    func restartOnboarding() {
        prepareForTermination()
        hotkey.stop()
        flowBar.reset()
        flowBar.showIfNeeded(false)
        onboardingTalkKeyPreviewEnabled = false
        onboardingTestTranscript = nil
        settings.resetForOnboarding()
        flowBar.setOutputLanguage(settings.values.recognitionLanguage)
        audioCapture.selectInput(named: settings.values.microphoneUID)
        lifecycle.applyAppearance(settings.values.appearance)
        lifecycle.applyDockVisibility(settings.values.showInDock)
        lifecycle.applyLaunchAtLogin(false)
        permissions.refresh()
        section = .home
        showToast("Onboarding reset. Your History and model are still here.")
    }

    func beginOnboardingTest() {
        onboardingTalkKeyPreviewEnabled = false
        configureHotkeyBindings()
        hotkey.start()
        flowBar.showIfNeeded(false)
    }

    func endOnboardingTest() {
        guard !settings.values.onboardingCompleted else { return }
        hotkey.stop()
        flowBar.reset()
        flowBar.showIfNeeded(false)
    }

    func beginOnboardingTalkKeyPreview() {
        guard !settings.values.onboardingCompleted else { return }
        onboardingTalkKeyPreviewEnabled = true
        configureHotkeyBindings()
        hotkey.startOnboardingPreview()
        flowBar.showIfNeeded(false)
    }

    func endOnboardingTalkKeyPreview() {
        guard onboardingTalkKeyPreviewEnabled else { return }
        if isTalkKeyPreviewActive { stopTalkKeyPreview(showSuccess: false) }
        cancelPendingStart()
        onboardingTalkKeyPreviewEnabled = false
        hotkey.stop()
        flowBar.reset()
        flowBar.showIfNeeded(false)
    }

    func toggleTalkKeyPreview() {
        guard onboardingTalkKeyPreviewEnabled else { return }
        toggleDictation()
    }

    func startMicrophoneTest() async throws {
        guard !audioCapture.isRecording,
              !isStartingDictation,
              !isTranscribing
        else { return }
        guard await permissions.requestMicrophone() else {
            throw SprekrError.noMicrophonePermission
        }
        try audioCapture.start(deviceUID: settings.values.microphoneUID)
        isMicrophoneTestActive = true
    }

    func stopMicrophoneTest() {
        guard isMicrophoneTestActive else { return }
        audioCapture.cancel()
        isMicrophoneTestActive = false
    }

    func applicationDidBecomeActive() {
        permissions.refresh()
        audioCapture.refreshAvailableInputs()
        guard settings.values.onboardingCompleted else { return }
        configureHotkey()
    }

    func retryHotkeyRegistration() {
        permissions.refresh()
        configureHotkey()
        showToast(hotkey.isRegistered
            ? "Talk keys are ready in every app."
            : "Couldn’t activate talk keys. Check Accessibility and try again.")
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
        permissions.openPrivacySettings(.accessibility)
        showToast("System Settings opened for Accessibility.")
    }

    func showToast(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard self?.toast == message else { return }
            self?.toast = nil
        }
    }

    var insights: InsightSummary { InsightsService.summary(for: transcripts, calendar: .sprekrAmsterdam) }

    private func finishCaptureContext() -> DictationDeliveryContext {
        let context = DictationDeliveryContext(
            deliverInApp: deliverTranscriptToOnboarding,
            outputLanguage: settings.values.recognitionLanguage,
            smartFormatting: settings.values.smartFormatting,
            restoredAfterCancellation: false
        )
        deliverTranscriptToOnboarding = false
        hotkey.setDictationActive(false)
        levelTask?.cancel()
        levelTask = nil
        return context
    }

    private func beginTranscription(audioURL: URL, context: DictationDeliveryContext) {
        isTranscribing = true
        flowBar.setTranscribing()
        let processingStartedAt = ContinuousClock.now
        currentTemporaryAudioURL = audioURL

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.audioCapture.deleteTemporaryAudio(at: audioURL)
                if self.currentTemporaryAudioURL == audioURL {
                    self.currentTemporaryAudioURL = nil
                    self.transcriptionTask = nil
                }
                self.isTranscribing = false
            }
            do {
                let transcribed = try await self.modelManager.transcribe(
                    audioURL: audioURL,
                    language: .automatic
                )
                let languagePlan = DictationLanguagePlan.resolve(
                    text: transcribed.text,
                    outputPreference: context.outputLanguage
                )
                let numberedSource = SpokenNumberFormatter.format(
                    transcribed.text,
                    spokenLanguage: languagePlan.sourceLanguage,
                    outputLanguage: languagePlan.outputLanguage
                )
                let symbolizedSource = SpokenSymbolFormatter.format(
                    numberedSource,
                    language: languagePlan.sourceLanguage
                )
                let emailStructuredSource = SpokenEmailFormatter.format(
                    symbolizedSource,
                    language: languagePlan.sourceLanguage
                )
                let formattedSource = context.smartFormatting
                    ? TranscriptFormatter.format(
                        emailStructuredSource,
                        language: languagePlan.sourceLanguage
                    )
                    : emailStructuredSource
                guard !formattedSource.isEmpty else {
                    // Empty audio can finish recognition almost immediately. Keep
                    // the processing capsule visible for the same minimum period
                    // as a successful dictation so its content transition settles
                    // before the wider error message replaces it.
                    try await FlowBarTransitionPolicy.waitForProcessingPresentation(
                        since: processingStartedAt
                    )
                    self.textInjection.clearOwnedRecoveryClipboard()
                    self.lastError = SprekrError.noSpeechDetected.localizedDescription
                    self.flowBar.setError("No speech detected")
                    self.showToast("No speech detected. Nothing was copied.")
                    return
                }

                let deliveredText: String
                let deliveredLanguage: RecognitionLanguage
                let translationFailed: Bool
                if languagePlan.requiresTranslation {
                    do {
                        deliveredText = try await self.flowBar.translationService.translate(
                            formattedSource,
                            using: languagePlan
                        )
                        deliveredLanguage = languagePlan.outputLanguage
                        translationFailed = false
                    } catch {
                        // Never lose a transcript because a language pack was declined,
                        // unavailable, or still downloading. Keep the source text and
                        // surface the translation issue after normal delivery.
                        deliveredText = formattedSource
                        deliveredLanguage = languagePlan.sourceLanguage
                        translationFailed = true
                        self.lastError = error.localizedDescription
                    }
                } else {
                    deliveredText = formattedSource
                    deliveredLanguage = languagePlan.outputLanguage
                    translationFailed = false
                }

                let corrected = try await self.dictionaryRepository.apply(
                    to: deliveredText,
                    language: deliveredLanguage
                )
                var record = TranscriptRecord(
                    text: corrected.text,
                    audioDuration: transcribed.audioDuration,
                    language: deliveredLanguage,
                    wasInserted: false,
                    dictionaryFixes: corrected.fixes
                )
                do {
                    try await self.transcriptRepository.append(record)
                } catch {
                    self.textInjection.copyForRecovery(corrected.text)
                    self.lastError = error.localizedDescription
                    self.flowBar.setRecovery(DictationRecoveryMessage.historySaveFailed)
                    self.showToast("History couldn’t be saved. Transcript copied.")
                    return
                }

                // Keep the dot-matrix loader ahead of delivery. Previously the
                // text arrived first and this presentation wait made the sound
                // feel detached from it.
                try await FlowBarTransitionPolicy.waitForProcessingPresentation(
                    since: processingStartedAt
                )

                let recoveryReason: TextInjectionRecoveryReason?
                if context.deliverInApp {
                    self.onboardingTestTranscript = corrected.text
                    record.wasInserted = true
                    recoveryReason = nil
                    self.textInjection.clearOwnedRecoveryClipboard()
                } else {
                    let injection = await self.textInjection.inject(corrected.text)
                    record.wasInserted = injection.wasInserted
                    recoveryReason = injection.recoveryReason
                    if injection.wasInserted {
                        self.textInjection.clearOwnedRecoveryClipboard()
                        if self.settings.values.learnFromCorrections {
                            self.textInjection.observeImmediateCorrection { [weak self] correction in
                                self?.saveImmediateCorrection(
                                    correction,
                                    language: deliveredLanguage
                                )
                            }
                        }
                    }
                }

                if let recoveryReason {
                    self.flowBar.setRecovery(
                        context.restoredAfterCancellation
                            ? DictationRecoveryMessage.restoredTranscriptCopied
                            : DictationRecoveryMessage.insertionFailed(
                                reason: recoveryReason
                            )
                    )
                } else {
                    self.flowBar.setSuccess()
                }

                if DictationFeedbackPolicy.shouldPlayCompletionCue(
                    copiedForRecovery: recoveryReason != nil
                ) {
                    try await Task.sleep(for: DictationFeedbackPolicy.completionCueDelay)
                    try Task.checkCancellation()
                    self.playCompletionSound()
                }

                if record.wasInserted {
                    do { try await self.transcriptRepository.save(record) }
                    catch { self.lastError = error.localizedDescription }
                }
                await self.reloadLocalData()
                if translationFailed {
                    self.showToast("Translation unavailable. Original transcript kept.")
                }
            } catch {
                self.lastError = error.localizedDescription
                self.flowBar.setError("Dictation couldn’t be completed")
                self.showToast("Dictation couldn’t be completed. Nothing was removed from History.")
            }
        }
    }

    private func discardPendingCancelledDictation(resetFlowBar: Bool) {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        guard let pending = pendingCancelledDictation else { return }
        pendingCancelledDictation = nil
        audioCapture.deleteTemporaryAudio(at: pending.audioURL)
        if resetFlowBar { flowBar.reset() }
    }

    private func configureHotkey() {
        configureHotkeyBindings()
        if settings.values.onboardingCompleted { hotkey.start() }
    }

    private func configureHotkeyBindings() {
        hotkey.configure(
            holdShortcut: settings.values.holdShortcut,
            toggleShortcut: settings.values.toggleShortcut
        )
    }

    private func beginLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.audioCapture.isRecording {
                self.audioCapture.refreshLevel()
                self.flowBar.setListening(level: self.audioCapture.level)
                try? await Task.sleep(for: FlowBarWaveformPolicy.updateInterval)
            }
        }
    }

    private func prepareForTermination() {
        cancelPendingStart()
        discardPendingCancelledDictation(resetFlowBar: false)
        levelTask?.cancel()
        levelTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let currentTemporaryAudioURL {
            audioCapture.deleteTemporaryAudio(at: currentTemporaryAudioURL)
            self.currentTemporaryAudioURL = nil
        }
        audioCapture.cancel()
        isTalkKeyPreviewActive = false
        isMicrophoneTestActive = false
        onboardingTalkKeyPreviewEnabled = false
        hotkey.setDictationActive(false)
    }

    private func cancelPendingStart() {
        activeStartID = nil
        startTask?.cancel()
        startTask = nil
        isStartingDictation = false
        deliverTranscriptToOnboarding = false
        hotkey.setDictationActive(false)
    }

    private func stopTalkKeyPreview(showSuccess: Bool) {
        levelTask?.cancel()
        levelTask = nil
        audioCapture.cancel()
        isTalkKeyPreviewActive = false
        hotkey.setDictationActive(false)
        if showSuccess {
            flowBar.setSuccess()
            showToast("Talk key and microphone work.")
        } else {
            flowBar.reset()
        }
    }

    private func handleAudioCaptureFailure(_ message: String) {
        levelTask?.cancel()
        levelTask = nil
        isTalkKeyPreviewActive = false
        isMicrophoneTestActive = false
        deliverTranscriptToOnboarding = false
        hotkey.setDictationActive(false)
        lastError = message
        flowBar.setError("Microphone disconnected")
        showToast(message)
    }

    private func handleAvailableInputsChanged(_ devices: [AVCaptureDevice]) {
        let previousUID = settings.values.microphoneUID
        let resolvedUID = AudioCaptureService.resolvedSelectedDeviceUID(
            previousUID,
            availableUIDs: devices.map(\.uniqueID)
        )
        guard let selectedUID = resolvedUID else {
            if previousUID != nil {
                settings.update { $0.microphoneUID = nil }
                showToast("Selected microphone disconnected. Using System Default.")
            }
            audioCapture.selectInput(named: nil)
            return
        }
        audioCapture.selectInput(named: selectedUID)
    }

    private func saveImmediateCorrection(
        _ correction: ImmediateSpellingCorrection,
        language: RecognitionLanguage
    ) {
        Task {
            do {
                var entries = try await dictionaryRepository.all()
                let heardKey = DictionaryEntryPolicy.normalizedKey(correction.heard)
                if entries.contains(where: { entry in
                    entry.aliases.contains(where: {
                        DictionaryEntryPolicy.normalizedKey($0) == heardKey
                    })
                }) {
                    return
                }

                let dictionaryLanguage: DictionaryLanguage = switch language {
                case .dutch: .dutch
                case .english: .english
                case .automatic: .both
                }
                if let index = entries.firstIndex(where: {
                    DictionaryEntryPolicy.normalizedKey($0.preferredSpelling)
                        == DictionaryEntryPolicy.normalizedKey(correction.preferred)
                        && ($0.language == dictionaryLanguage || $0.language == .both || dictionaryLanguage == .both)
                }) {
                    entries[index].aliases = DictionaryEntryPolicy.uniqueTerms(
                        entries[index].aliases + [correction.heard],
                        excluding: entries[index].preferredSpelling
                    )
                    try await dictionaryRepository.save(entries[index])
                } else {
                    try await dictionaryRepository.save(
                        DictionaryEntry(
                            preferredSpelling: correction.preferred,
                            aliases: DictionaryEntryPolicy.uniqueTerms(
                                [correction.heard],
                                excluding: correction.preferred
                            ),
                            language: dictionaryLanguage
                        )
                    )
                }
                await reloadLocalData()
                showToast("Learned \(correction.preferred) for next time.")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func activateFirstWindow() {
        let window = NSApp.windows.first { $0.canBecomeKey }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func playSound(named name: String, volume: Float) {
        guard settings.values.soundsEnabled else { return }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
    }

    private func playCompletionSound() {
        guard settings.values.soundsEnabled else { return }
        guard let completionSound else {
            playSound(named: "Purr", volume: 0.12)
            return
        }
        completionSound.stop()
        completionSound.play()
    }

    private func playStartSound() {
        guard settings.values.soundsEnabled, let startSound else { return }
        startSound.stop()
        startSound.play()
    }

    private static func loadCompletionSound() -> NSSound? {
        loadBundledSound(named: "SprekrCompletion", volume: 0.42)
    }

    private static func loadBundledSound(named name: String, volume: Float) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "aiff"),
              let sound = NSSound(contentsOf: url, byReference: false)
        else { return nil }
        sound.volume = volume
        return sound
    }
}
