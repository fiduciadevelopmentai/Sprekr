import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: SprekrAppController
    @ObservedObject private var permissions: PermissionService
    @ObservedObject private var audioCapture: AudioCaptureService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: SettingsPage = .general
    @State private var editingShortcutMode: DictationMode?
    @State private var isRecordingHoldShortcut = false
    @State private var isRecordingToggleShortcut = false
    @State private var shortcutValidationMessage: String?
    @State private var microphoneLevelTask: Task<Void, Never>?
    @State private var microphoneTestError: String?
    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingHistoryExport = false
    @State private var isConfirmingDictionaryClear = false
    @State private var isConfirmingModelRedownload = false
    @State private var isConfirmingModelRemoval = false
    @State private var isConfirmingOnboardingReset = false
    @State private var isShowingAcknowledgements = false

    init(controller: SprekrAppController) {
        self.controller = controller
        _permissions = ObservedObject(wrappedValue: controller.permissions)
        _audioCapture = ObservedObject(wrappedValue: controller.audioCapture)
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsNavigation

            ZStack {
                pageContent
                    .id(page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: page)
        }
        .sheet(isPresented: $isShowingAcknowledgements) {
            AcknowledgementsSheet()
        }
        .onDisappear {
            stopMicrophoneTest()
            endShortcutCapture()
        }
        .onChange(of: page) { _, newPage in
            if newPage != .general {
                stopMicrophoneTest()
                endShortcutCapture()
            }
        }
        .confirmationDialog(
            "Export readable History data?",
            isPresented: $isConfirmingHistoryExport,
            titleVisibility: .visible
        ) {
            Button("Export unencrypted JSON") { controller.exportHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(HistoryExportPolicy.warning)
        }
        .confirmationDialog(
            "Permanently delete every transcript?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Delete all transcripts", role: .destructive) { controller.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the complete encrypted History from this Mac. It cannot be undone.")
        }
        .confirmationDialog(
            "Clear the entire Dictionary?",
            isPresented: $isConfirmingDictionaryClear,
            titleVisibility: .visible
        ) {
            Button("Clear entire Dictionary", role: .destructive) { controller.clearDictionary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every custom spelling and alias from this Mac. It cannot be undone.")
        }
        .confirmationDialog(
            "Download the speech model again?",
            isPresented: $isConfirmingModelRedownload,
            titleVisibility: .visible
        ) {
            Button("Re-download model") {
                Task {
                    await controller.modelManager.removeModel()
                    await controller.modelManager.installOrLoad()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sprekr will remove the installed model and download a fresh copy of about 483 MB.")
        }
        .confirmationDialog(
            "Remove the speech model?",
            isPresented: $isConfirmingModelRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove model", role: .destructive) {
                Task { await controller.modelManager.removeModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dictation will not work until the model is downloaded again.")
        }
        .confirmationDialog(
            "Run onboarding again?",
            isPresented: $isConfirmingOnboardingReset,
            titleVisibility: .visible
        ) {
            Button("Run onboarding again") { controller.restartOnboarding() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This keeps your History, Dictionary, and downloaded speech model. It resets only first-run settings and returns to the welcome flow. macOS permissions are controlled separately; to see fresh permission prompts, switch Sprekr off in System Settings after the reset.")
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: 8))
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .sprekrLabel()
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 24)

            VStack(spacing: 6) {
                ForEach(SettingsPage.allCases) { item in
                    let isSelected = page == item
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            page = item
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SprekrPalette.icon)
                                .frame(width: 22)
                            Text(item.navigationTitle)
                            Spacer(minLength: 0)
                        }
                        .font(SprekrTypography.body(15, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? SprekrPalette.primaryText : SprekrPalette.secondaryText)
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    }
                    .buttonStyle(SprekrHoverButtonStyle(
                        baseFill: isSelected ? SprekrPalette.primaryText.opacity(0.065) : .clear,
                        cornerRadius: 12,
                        hoverOpacity: isSelected ? 0.04 : 0.065,
                        pressedOpacity: 0.10
                    ))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Sprekr")
                    .font(SprekrTypography.body(13, weight: .semibold))
                Text("Version \(appVersion)")
                    .sprekrSmall(12)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .frame(width: 198)
        .frame(maxHeight: .infinity)
        .background(SprekrPalette.navigationSurface.opacity(0.56))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SprekrPalette.line.opacity(0.58))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general:
            settingsScroll(title: "General", introduction: "Choose how Sprekr listens, writes, and looks.") {
                generalContent
            }
        case .system:
            settingsScroll(title: "System", introduction: "Control how the local app behaves on this Mac.") {
                systemContent
            }
        case .privacy:
            settingsScroll(title: "Data & privacy", introduction: "Your recordings and words stay under your control.") {
                privacyContent
            }
        case .about:
            settingsScroll(title: "About", introduction: "Build details, acknowledgements, and local-first guarantees.") {
                aboutContent
            }
        }
    }

    private func settingsScroll<Content: View>(
        title: String,
        introduction: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).sprekrHeading(46)
                    Text(introduction).sprekrBody()
                }

                content()
            }
            .padding(.horizontal, 44)
            .padding(.top, 38)
            .padding(.bottom, 48)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            settingsGroup("Talk keys") {
                shortcutRow(for: .hold)

                if editingShortcutMode == .hold {
                    settingsDivider
                    shortcutEditor(for: .hold)
                        .padding(.vertical, 18)
                }

                settingsDivider

                shortcutRow(for: .toggle)

                if editingShortcutMode == .toggle {
                    settingsDivider
                    shortcutEditor(for: .toggle)
                        .padding(.vertical, 18)
                }

                if let message = controller.hotkey.conflictMessage {
                    settingsDivider
                    Text(message)
                        .font(SprekrTypography.body(13, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.86))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            }

            settingsGroup("Microphone") {
                SettingsRow(
                    title: "Input",
                    detail: selectedMicrophoneName
                ) {
                    HStack(spacing: 8) {
                        Picker("Microphone", selection: microphoneBinding) {
                            Text(audioCapture.systemDefaultInputName).tag(String?.none)
                            ForEach(audioCapture.availableDevices, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(Optional(device.uniqueID))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)

                        Button {
                            audioCapture.refreshAvailableInputs()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(SprekrPalette.icon)
                        }
                        .buttonStyle(SettingsActionButtonStyle())
                        .help("Refresh microphones")
                        .accessibilityLabel("Refresh microphones")
                    }
                }

                settingsDivider

                SettingsRow(
                    title: controller.isMicrophoneTestActive ? "Listening now" : "Test this microphone",
                    detail: controller.isMicrophoneTestActive
                        ? "Speak normally. The meter should follow your voice."
                        : "The same Sprekr permission covers built in, USB, and headset microphones."
                ) {
                    HStack(spacing: 12) {
                        microphoneLevelMeter
                        Button(controller.isMicrophoneTestActive ? "Stop" : "Test") {
                            toggleMicrophoneTest()
                        }
                        .buttonStyle(SettingsActionButtonStyle())
                        .disabled(controller.isTranscribing)
                    }
                }

                if let microphoneTestError {
                    settingsDivider
                    Text(microphoneTestError)
                        .font(SprekrTypography.body(13, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.86))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            }

            settingsGroup("Writing") {
                SettingsRow(
                    title: "Output language",
                    detail: "Automatic keeps what you speak; a chosen language translates locally."
                ) {
                    Picker("Output language", selection: binding(\.recognitionLanguage)) {
                        ForEach(RecognitionLanguage.allCases) { language in
                            Text(language.outputDisplayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                settingsDivider

                SettingsRow(
                    title: "Smart formatting",
                    detail: "Cleans up false starts, stutters, repetition, punctuation, lists, and paragraphs."
                ) {
                    Toggle("Smart formatting", isOn: binding(\.smartFormatting))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                settingsDivider

                SettingsRow(
                    title: "Learn immediate corrections",
                    detail: "When supported, watch only the text Sprekr just inserted and save one corrected spelling locally."
                ) {
                    Toggle("Learn immediate corrections", isOn: binding(\.learnFromCorrections))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            settingsGroup("Appearance") {
                SettingsRow(title: "Appearance", detail: "Follow macOS or choose a fixed theme.") {
                    Picker("Appearance", selection: binding(\.appearance)) {
                        ForEach(AppearanceChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 226)
                }
            }
        }
    }

    private func shortcutRow(for mode: DictationMode) -> some View {
        let configuration = mode == .hold
            ? controller.settings.values.holdShortcut
            : controller.settings.values.toggleShortcut
        let isEditing = editingShortcutMode == mode

        return SettingsRow(
            title: mode == .hold ? "Hold to talk" : "Toggle to talk",
            detail: mode == .hold
                ? "Hold this key while speaking. Releasing it stops the recording."
                : "Tap once to start and tap the same key again to stop."
        ) {
            HStack(spacing: 10) {
                Text(configuration.displayName)
                    .font(SprekrTypography.body(14, weight: .semibold))
                    .foregroundStyle(SprekrPalette.primaryText)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(SprekrPalette.primaryText.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button(isEditing ? "Done" : "Edit") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        endShortcutCapture()
                        shortcutValidationMessage = nil
                        editingShortcutMode = isEditing ? nil : mode
                    }
                }
                .buttonStyle(SettingsActionButtonStyle())
            }
        }
    }

    private func shortcutEditor(for mode: DictationMode) -> some View {
        let configuration = mode == .hold
            ? controller.settings.values.holdShortcut
            : controller.settings.values.toggleShortcut
        let recordingBinding = shortcutRecordingBinding(for: mode)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Choose your own key")
                .font(SprekrTypography.body(13, weight: .semibold))
                .foregroundStyle(SprekrPalette.primaryText)

            Text("Click the field, then press a combination. To use Fn, Option, Control, Shift, or Command by itself, press and release that key.")
                .sprekrSmall(12)
                .frame(maxWidth: 650, alignment: .leading)

            ShortcutRecorder(
                configuration: configuration,
                isRecording: recordingBinding
            ) { value in
                switch controller.updateShortcut(value, for: mode) {
                case .accepted:
                    shortcutValidationMessage = nil
                    return true
                case let .rejected(message):
                    shortcutValidationMessage = message
                    return false
                }
            }
            .frame(height: 64)

            if recordingBinding.wrappedValue {
                Text("Press your key now. Escape cancels without changing anything.")
                    .sprekrSmall(12)
            }

            if let shortcutValidationMessage {
                Text(shortcutValidationMessage)
                    .font(SprekrTypography.body(12, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
    }

    private func shortcutRecordingBinding(for mode: DictationMode) -> Binding<Bool> {
        Binding(
            get: {
                mode == .hold ? isRecordingHoldShortcut : isRecordingToggleShortcut
            },
            set: { isRecording in
                if mode == .hold {
                    isRecordingHoldShortcut = isRecording
                    if isRecording { isRecordingToggleShortcut = false }
                } else {
                    isRecordingToggleShortcut = isRecording
                    if isRecording { isRecordingHoldShortcut = false }
                }

                if isRecording {
                    shortcutValidationMessage = nil
                    controller.setShortcutCaptureActive(true)
                } else if !isRecordingHoldShortcut && !isRecordingToggleShortcut {
                    controller.setShortcutCaptureActive(false)
                }
            }
        )
    }

    private func endShortcutCapture() {
        isRecordingHoldShortcut = false
        isRecordingToggleShortcut = false
        controller.setShortcutCaptureActive(false)
    }

    private var microphoneLevelMeter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<8, id: \.self) { index in
                let threshold = Float(index + 1) / 9
                Capsule(style: .continuous)
                    .fill(audioCapture.level >= threshold ? SprekrPalette.accent : SprekrPalette.line.opacity(0.72))
                    .frame(width: 3, height: CGFloat(7 + index * 2))
            }
        }
        .frame(width: 46, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.isMicrophoneTestActive ? "Live microphone level" : "Microphone test ready")
    }

    private var systemContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            settingsGroup("App settings") {
                SettingsRow(title: "Launch at login", detail: "Keep the talk key available after signing in.") {
                    Toggle("Launch at login", isOn: binding(\.launchAtLogin))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                settingsDivider

                SettingsRow(title: "Always show Flow Bar", detail: "Keep the compact handle visible when idle.") {
                    Toggle("Always show Flow Bar", isOn: binding(\.showFlowBar))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                settingsDivider

                SettingsRow(title: "Show app in Dock", detail: "Keep Sprekr visible beside your other apps.") {
                    Toggle("Show app in Dock", isOn: binding(\.showInDock))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            settingsGroup("Beginner setup") {
                SettingsRow(
                    title: "Run onboarding again",
                    detail: "Walk through the welcome, model, microphone, Accessibility, system-wide talk key check, startup, and first dictation steps again."
                ) {
                    Button("Run again") { isConfirmingOnboardingReset = true }
                        .buttonStyle(SettingsActionButtonStyle())
                }
            }

            settingsGroup("Sound") {
                SettingsRow(
                    title: "Dictation feedback sounds",
                    detail: "Play a quiet start cue and one completion sound after delivery."
                ) {
                    Toggle("Dictation feedback sounds", isOn: binding(\.soundsEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            settingsGroup("Talk key access") {
                SettingsRow(
                    title: controller.hotkey.isRegistered
                        ? "Ready in every app"
                        : "Talk keys need attention",
                    detail: controller.hotkey.isRegistered
                        ? "Your Hold and Toggle keys are registered system-wide."
                        : "Sprekr uses Accessibility to make both talk keys work outside the app."
                ) {
                    if controller.hotkey.isRegistered {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(SprekrPalette.icon)
                    } else {
                        HStack(spacing: 8) {
                            Button("Try again") { controller.retryHotkeyRegistration() }
                            Button("Open Accessibility") { controller.requestAccessibility() }
                        }
                        .buttonStyle(SettingsActionButtonStyle())
                    }
                }
            }

            settingsGroup("Speech model") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(ModelManager.modelDisplayName)
                        .font(SprekrTypography.body(14, weight: .medium))
                        .foregroundStyle(SprekrPalette.secondaryText)
                    ModelProgressView(state: controller.modelManager.state)
                    HStack(spacing: 8) {
                        Button("Check model") {
                            Task { _ = await controller.modelManager.validateInstalledModel() }
                        }
                        Button("Re-download") { isConfirmingModelRedownload = true }
                        Button("Remove model", role: .destructive) { isConfirmingModelRemoval = true }
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 21)
            }

            settingsGroup("Updates") {
                SettingsRow(
                    title: "Source updates",
                    detail: "Sprekr is source-only. Pull trusted repository changes, then run make update from Terminal."
                ) {
                    Image(systemName: "terminal")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SprekrPalette.icon)
                }
            }
        }
    }

    private var privacyContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            settingsGroup("Local by design") {
                SettingsRow(
                    title: "On-device transcription",
                    detail: "Audio is processed on this Mac. Temporary recordings are removed after each dictation."
                ) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(SprekrPalette.icon)
                }

                settingsDivider

                SettingsRow(
                    title: "Encrypted storage",
                    detail: "History and Dictionary entries are encrypted with a key in your macOS Keychain."
                ) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(SprekrPalette.icon)
                }
            }

            settingsGroup("Your local data") {
                SettingsRow(
                    title: "Transcript History",
                    detail: "\(controller.transcripts.count) saved \(controller.transcripts.count == 1 ? "transcript" : "transcripts") on this Mac."
                ) {
                    Button("Export…") { isConfirmingHistoryExport = true }
                        .buttonStyle(SettingsActionButtonStyle())
                        .disabled(controller.transcripts.isEmpty)
                }

                settingsDivider

                SettingsRow(
                    title: "Dictionary",
                    detail: "\(controller.dictionaryEntries.count) custom \(controller.dictionaryEntries.count == 1 ? "entry" : "entries") stored locally."
                ) {
                    Button("Clear") { isConfirmingDictionaryClear = true }
                        .buttonStyle(SettingsActionButtonStyle(destructive: true))
                        .disabled(controller.dictionaryEntries.isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Danger zone")
                    .font(SprekrTypography.body(19, weight: .semibold, relativeTo: .title3))
                    .foregroundStyle(Color.red.opacity(0.86))

                SettingsCard {
                    SettingsRow(
                        title: "Delete every transcript",
                        detail: "Permanently remove your complete encrypted History from this Mac."
                    ) {
                        Button("Delete all…") { isConfirmingHistoryClear = true }
                            .buttonStyle(SettingsActionButtonStyle(destructive: true))
                            .disabled(controller.transcripts.isEmpty)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }

                Text("Sprekr always asks for confirmation before deleting local data.")
                    .sprekrSmall(12)
            }
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            settingsGroup("Sprekr") {
                SettingsRow(title: "Version", detail: "Local development build") {
                    Text(appVersion)
                        .font(SprekrTypography.body(14, weight: .semibold))
                        .foregroundStyle(SprekrPalette.primaryText)
                }

                settingsDivider

                SettingsRow(title: "License", detail: "The application source is licensed under Apache-2.0.") {
                    Text("Apache-2.0")
                        .font(SprekrTypography.body(14, weight: .semibold))
                        .foregroundStyle(SprekrPalette.primaryText)
                }

                settingsDivider

                SettingsRow(title: "Acknowledgements", detail: "Open-source components and bundled font licenses.") {
                    Button("Open") { isShowingAcknowledgements = true }
                        .buttonStyle(SettingsActionButtonStyle())
                }
            }

            settingsGroup("Release status") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No public release yet")
                        .font(SprekrTypography.body(16, weight: .semibold))
                        .foregroundStyle(SprekrPalette.primaryText)
                    Text("The public source repository and signed update feed will be linked here only after owner acceptance.")
                        .sprekrSmall(14)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 21)
            }
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(SprekrTypography.body(19, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(SprekrPalette.primaryText)
            SettingsCard {
                content()
            }
        }
    }

    private var settingsDivider: some View {
        Divider()
            .overlay(SprekrPalette.line.opacity(0.72))
            .padding(.horizontal, 24)
    }

    private var selectedMicrophoneName: String {
        guard let uid = controller.settings.values.microphoneUID else {
            return audioCapture.selectedDeviceName
        }
        return audioCapture.availableDevices.first(where: { $0.uniqueID == uid })?.localizedName
            ?? "Previously selected microphone"
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { controller.settings.values.microphoneUID },
            set: { value in
                let wasTesting = controller.isMicrophoneTestActive
                if wasTesting { stopMicrophoneTest() }
                controller.updateSettings { $0.microphoneUID = value }
                audioCapture.refreshAvailableInputs()
                if wasTesting { startMicrophoneTest() }
            }
        )
    }

    private func toggleMicrophoneTest() {
        if controller.isMicrophoneTestActive {
            stopMicrophoneTest()
        } else {
            startMicrophoneTest()
        }
    }

    private func startMicrophoneTest() {
        microphoneTestError = nil
        microphoneLevelTask?.cancel()
        microphoneLevelTask = Task { @MainActor in
            do {
                try await controller.startMicrophoneTest()
                while !Task.isCancelled, controller.isMicrophoneTestActive {
                    audioCapture.refreshLevel()
                    try? await Task.sleep(for: .milliseconds(60))
                }
            } catch {
                microphoneTestError = error.localizedDescription
                controller.stopMicrophoneTest()
            }
        }
    }

    private func stopMicrophoneTest() {
        microphoneLevelTask?.cancel()
        microphoneLevelTask = nil
        controller.stopMicrophoneTest()
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SprekrSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings.values[keyPath: keyPath] },
            set: { value in controller.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

}

private struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let document = AcknowledgementsDocument.bundled()

    var body: some View {
        ZStack {
            SprekrContentBackground()

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Acknowledgements").sprekrHeading(38)
                        Text("The open-source software, model, fonts, and design references bundled with Sprekr.")
                            .sprekrSmall(14)
                            .frame(maxWidth: 620, alignment: .leading)
                    }

                    Spacer(minLength: 12)

                    Button("Done") { dismiss() }
                        .buttonStyle(SettingsActionButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 30)
                .padding(.top, 28)
                .padding(.bottom, 22)

                Divider()
                    .overlay(SprekrPalette.line.opacity(0.72))

                ScrollView {
                    if document.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Acknowledgements are unavailable.")
                                .font(SprekrTypography.body(17, weight: .semibold))
                                .foregroundStyle(SprekrPalette.primaryText)
                            Text("The bundled notices could not be read. Reinstall this Sprekr build to restore them.")
                                .sprekrSmall(14)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(30)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(document.entries.enumerated()), id: \.element.id) { index, entry in
                                AcknowledgementEntryRow(entry: entry)

                                if index < document.entries.count - 1 {
                                    Divider()
                                        .overlay(SprekrPalette.line.opacity(0.58))
                                }
                            }

                            if let closingNote = document.closingNote {
                                Text(inlineMarkdown(closingNote))
                                    .sprekrSmall(13)
                                    .padding(.top, 20)
                            }
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 640)
    }

    private func inlineMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value)) ?? AttributedString(value)
    }
}

private struct AcknowledgementEntryRow: View {
    let entry: AcknowledgementEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(inlineMarkdown(entry.component))
                .font(SprekrTypography.body(16, weight: .semibold))
                .foregroundStyle(SprekrPalette.primaryText)

            Text(entry.use)
                .sprekrSmall(13)

            Text(inlineMarkdown(entry.license))
                .font(SprekrTypography.body(13, relativeTo: .callout))
                .foregroundStyle(SprekrPalette.secondaryText)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value)) ?? AttributedString(value)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case system
    case privacy
    case about

    var id: String { rawValue }

    var navigationTitle: String {
        switch self {
        case .general: "General"
        case .system: "System"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .system: "laptopcomputer"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SprekrPalette.surface.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(SprekrPalette.line.opacity(0.56), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(SprekrTypography.body(16, weight: .semibold))
                    .foregroundStyle(SprekrPalette.primaryText)
                Text(detail)
                    .sprekrSmall(14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsActionButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsActionButtonBody(
            configuration: configuration,
            destructive: destructive
        )
    }
}

private struct SettingsActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(SprekrTypography.body(14, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .frame(minWidth: 92, minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(backgroundColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(SprekrPalette.primaryText.opacity(
                                configuration.isPressed ? 0.10 : isHovered ? 0.055 : 0
                            ))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(SprekrPalette.line.opacity(isHovered ? 0.84 : 0.52), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.46)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    }

    private var foregroundColor: Color {
        destructive ? Color.red.opacity(0.88) : SprekrPalette.primaryText
    }

    private var backgroundColor: Color {
        destructive ? Color.red.opacity(0.075) : SprekrPalette.primaryText.opacity(0.045)
    }
}

private struct SettingsChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SettingsChoiceButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct SettingsChoiceButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(SprekrTypography.body(13, weight: .semibold))
            .foregroundStyle(isSelected ? SprekrPalette.onAccent : SprekrPalette.primaryText)
            .padding(.horizontal, 13)
            .frame(minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? SprekrPalette.accent : SprekrPalette.primaryText.opacity(isHovered ? 0.075 : 0.04))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    }
}
