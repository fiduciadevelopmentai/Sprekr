import AppKit
import AVFoundation
import SwiftUI

private enum OnboardingFinishPhase {
    case preparing
    case ready
}

enum OnboardingFinishPolicy {
    static let progressStepCount = 60
    static let progressStepMilliseconds = 100
    static let automaticTipStepInterval = 18
    static let tips = [
        "Hold your talk key for quick messages, then release it to finish.",
        "Use Toggle to talk when you want to speak without holding a key.",
        "Press Escape whenever you want to cancel a live recording.",
        "Without a text field, your transcript is saved and copied for you.",
        "Your recordings and transcripts stay private on this Mac.",
    ]
}

enum OnboardingReadinessPolicy {
    enum ModelAction: Equatable {
        case install
        case retry
        case continueFlow
        case none
    }

    static func modelAction(for state: ModelInstallState) -> ModelAction {
        switch state {
        case .notInstalled: .install
        case .failed: .retry
        case .installed: .continueFlow
        case .checking, .preparing, .downloading: .none
        }
    }

    static func canContinueFromModel(_ state: ModelInstallState) -> Bool {
        if case .installed = state { return true }
        return false
    }

    static func canContinueFromTalkKeys(
        hotkeyRegistered: Bool,
        conflictMessage: String?,
        isRecordingShortcut: Bool
    ) -> Bool {
        blockingTalkKeyMessage(
            hotkeyRegistered: hotkeyRegistered,
            conflictMessage: conflictMessage,
            isRecordingShortcut: isRecordingShortcut
        ) == nil
    }

    static func blockingTalkKeyMessage(
        hotkeyRegistered: Bool,
        conflictMessage: String?,
        isRecordingShortcut: Bool
    ) -> String? {
        if isRecordingShortcut {
            return "Finish choosing your talk key before continuing."
        }
        if let conflictMessage { return conflictMessage }
        if !hotkeyRegistered {
            return "Sprekr could not activate your talk controls yet. Check Accessibility and try again."
        }
        return nil
    }
}

enum OnboardingDictationButtonState: Equatable {
    case idle
    case starting
    case recording
    case transcribing

    static func resolve(
        isStarting: Bool,
        isRecording: Bool,
        isTranscribing: Bool
    ) -> Self {
        if isRecording { return .recording }
        if isStarting { return .starting }
        if isTranscribing { return .transcribing }
        return .idle
    }

    var title: String {
        switch self {
        case .idle: "Start dictation"
        case .starting: "Starting…"
        case .recording: "Stop dictation"
        case .transcribing: "Transcribing…"
        }
    }

    var isDisabled: Bool {
        self == .starting || self == .transcribing
    }
}

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: SprekrAppController
    @ObservedObject private var permissions: PermissionService
    @ObservedObject private var modelManager: ModelManager
    @ObservedObject private var audioCapture: AudioCaptureService
    @State private var step = 0
    @State private var testText = ""
    @State private var isCheckingPermissions = false
    @State private var isTestingMicrophone = false
    @State private var microphoneLevel: Float = 0
    @State private var microphoneTestError: String?
    @State private var microphoneLevelTask: Task<Void, Never>?
    @State private var isRecordingHoldShortcut = false
    @State private var isRecordingToggleShortcut = false
    @State private var shortcutValidationMessage: String?
    @State private var finishPhase: OnboardingFinishPhase = .preparing
    @State private var finishProgress = 0.0
    @State private var finishTipIndex = 0
    @State private var finishTask: Task<Void, Never>?
    private let permissionPoller = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    private let steps = ["Welcome", "Privacy", "Model", "Microphone", "Accessibility", "Talk key", "Startup", "Test", "Finish"]

    init(controller: SprekrAppController) {
        self.controller = controller
        _permissions = ObservedObject(wrappedValue: controller.permissions)
        _modelManager = ObservedObject(wrappedValue: controller.modelManager)
        _audioCapture = ObservedObject(wrappedValue: controller.audioCapture)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sprekr")
                        .font(SprekrTypography.body(20, weight: .semibold, relativeTo: .title))
                        .foregroundStyle(SprekrPalette.primaryText)
                    Spacer().frame(height: 64)
                    ForEach(steps.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(index <= step ? SprekrPalette.accent : SprekrPalette.line)
                                .frame(width: 7, height: 7)
                            Text(steps[index])
                                .font(SprekrTypography.body(13, relativeTo: .body))
                                .foregroundStyle(index == step ? SprekrPalette.primaryText : SprekrPalette.secondaryText)
                        }
                        .padding(.vertical, 8)
                    }
                    Spacer()
                    FiduciaOnboardingBrand()
                }
                .frame(width: 200, alignment: .leading)
                .padding(32)
                .background(SprekrPalette.surface)

                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { geometry in
                        ScrollView {
                            content
                                .frame(
                                    maxWidth: step == steps.count - 1 ? .infinity : 590,
                                    alignment: step == steps.count - 1 ? .center : .leading
                                )
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: max(0, geometry.size.height - (contentVerticalPadding * 2)),
                                    alignment: step == steps.count - 1 ? .center : .leading
                                )
                                .padding(.horizontal, 70)
                                .padding(.vertical, contentVerticalPadding)
                        }
                        .scrollIndicators(.automatic)
                    }

                    Divider().overlay(SprekrPalette.line)

                    HStack {
                        if step > 0 && step < steps.count - 1 {
                            Button("Back") {
                                move(to: step - 1)
                            }
                                .buttonStyle(.plain)
                                .foregroundStyle(SprekrPalette.secondaryText)
                        }
                        Spacer()
                        action
                    }
                    .padding(.horizontal, 70)
                    .padding(.vertical, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SprekrPalette.canvas)
            }

            if let toast = controller.toast {
                ToastView(text: toast).padding(.bottom, 24)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            audioCapture.refreshAvailableInputs()
            refreshPermissions(showSpinner: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions(showSpinner: false)
            if step == 5 { controller.beginOnboardingTalkKeyPreview() }
        }
        .onReceive(permissionPoller) { _ in
            guard (3...4).contains(step) else { return }
            permissions.refresh()
            if (step == 3 && permissions.microphoneStatus == .authorized)
                || (step == 4 && permissions.accessibilityGranted) {
                isCheckingPermissions = false
            }
        }
        .onChange(of: controller.onboardingTestTranscript) { _, transcript in
            if step == 7, let transcript { testText = transcript }
        }
        .onDisappear {
            stopMicrophoneTest()
            controller.setShortcutCaptureActive(false)
            controller.endOnboardingTalkKeyPreview()
            finishTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            OnboardingCopy(
                eyebrow: "WELCOME",
                title: "Welcome to Sprekr",
                description: "Private, fast dictation that stays on your Mac."
            )
        case 1:
            OnboardingCopy(
                eyebrow: "LOCAL BY DEFAULT",
                title: "Your voice stays here.",
                description: "Sprekr records and transcribes locally. There is no account, cloud sync, telemetry, or API key."
            )
        case 2:
            modelContent
        case 3:
            microphoneContent
        case 4:
            accessibilityContent
        case 5:
            talkKeyContent
        case 6:
            startupContent
        case 7:
            testContent
        default:
            finishContent
        }
    }

    private var action: some View {
        Group {
            if step == 0 {
                Button("Get started") { advance() }.buttonStyle(SprekrPrimaryButtonStyle())
            } else if step == 2 {
                switch OnboardingReadinessPolicy.modelAction(for: modelManager.state) {
                case .continueFlow:
                    Button("Continue") { advance() }
                        .buttonStyle(SprekrPrimaryButtonStyle())
                case .install:
                    Button("Install model") { Task { await modelManager.installOrLoad() } }
                        .buttonStyle(SprekrPrimaryButtonStyle())
                case .retry:
                    Button("Try again") { Task { await modelManager.installOrLoad() } }
                        .buttonStyle(SprekrPrimaryButtonStyle())
                case .none:
                    EmptyView()
                }
            } else if step == 3 {
                if permissions.microphoneStatus == .authorized {
                    Button("Continue") { advance() }.buttonStyle(SprekrPrimaryButtonStyle())
                } else {
                    Button(microphoneActionTitle) { handleMicrophoneAction() }
                        .buttonStyle(SprekrPrimaryButtonStyle())
                    refreshPermissionButton
                }
            } else if step == 4 {
                if permissions.accessibilityGranted {
                    Button("Continue") { advance() }.buttonStyle(SprekrPrimaryButtonStyle())
                } else {
                    Button("Open Accessibility settings") { openAccessibilitySettings() }
                        .buttonStyle(SprekrPrimaryButtonStyle())
                    refreshPermissionButton
                }
            } else if step == steps.count - 1 {
                if finishPhase == .ready {
                    Button("Open Sprekr") { controller.finishOnboarding() }
                        .buttonStyle(SprekrPrimaryButtonStyle())
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            } else {
                Button("Continue") { advance() }.buttonStyle(SprekrPrimaryButtonStyle())
                    .disabled(step == 5 && !talkKeysReady)
            }
        }
    }

    private var modelContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingCopy(
                eyebrow: "SPEECH MODEL",
                title: "Install the speech model",
                description: "Sprekr downloads the model once. It stays on your Mac, and later dictation works without Wi-Fi."
            )
            ModelProgressView(state: modelManager.state)
            Text("\(ModelManager.modelDisplayName). About 483 MB download. Sprekr reserves 1 GB of free space so installation and updates stay safe.")
                .sprekrBody()
        }
    }

    private var microphoneContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingCopy(
                eyebrow: "MICROPHONE",
                title: "Let Sprekr hear you.",
                description: "Microphone access is used only while you dictate. You can change or revoke it at any time in System Settings."
            )
            PermissionRow(
                title: permissions.microphoneStatus == .authorized ? "Microphone allowed" : "Microphone not yet allowed",
                detail: permissions.microphoneStatus == .authorized
                    ? "This permission covers every microphone connected to your Mac."
                    : "Required so Sprekr can hear your dictation.",
                allowed: permissions.microphoneStatus == .authorized
            )
            if permissions.microphoneStatus == .authorized {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone")
                        .font(SprekrTypography.body(13, weight: .semibold))
                        .foregroundStyle(SprekrPalette.primaryText)
                    HStack(spacing: 8) {
                        Picker("Microphone", selection: microphoneBinding) {
                            Text(audioCapture.systemDefaultInputName).tag(String?.none)
                            ForEach(audioCapture.availableDevices, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(Optional(device.uniqueID))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        Button {
                            audioCapture.refreshAvailableInputs()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(SprekrPalette.icon)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)
                        .help("Refresh microphones")
                        .accessibilityLabel("Refresh microphones")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    MicrophoneLevelMeter(level: microphoneLevel, isActive: isTestingMicrophone)
                    HStack(spacing: 10) {
                        Button(isTestingMicrophone ? "Stop test" : "Test microphone") {
                            handleMicrophoneAction()
                        }
                        .buttonStyle(.bordered)
                        Text(isTestingMicrophone
                            ? "Speak normally. The meter should move with your voice."
                            : "Optional. Start the test, then speak normally.")
                            .font(SprekrTypography.body(12, relativeTo: .caption))
                            .foregroundStyle(SprekrPalette.secondaryText)
                    }
                }
            } else {
                Text("Microphone access is required to continue. Sprekr only listens while you dictate.")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            if let microphoneTestError {
                Text(microphoneTestError).font(SprekrTypography.body(12, relativeTo: .caption)).foregroundStyle(.red)
            }
            permissionRefreshStatus
            if permissions.microphoneStatus == .denied {
                Text("Access was previously declined. Open Microphone settings and enable Sprekr.")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
        }
    }

    private var accessibilityContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingCopy(
                eyebrow: "TYPE FOR YOU",
                title: "Allow Sprekr to type for you",
                description: "Accessibility lets Sprekr return your transcript to the field you were already writing in. It does not read or send your documents."
            )
            PermissionRow(
                title: permissions.accessibilityGranted ? "Accessibility allowed" : "Accessibility not yet allowed",
                detail: "Needed for direct text insertion",
                allowed: permissions.accessibilityGranted
            )
            if !permissions.accessibilityGranted {
                Text("Accessibility access is required to continue so Sprekr can place text in the field you selected.")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            permissionRefreshStatus
        }
    }

    private var talkKeyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingCopy(
                eyebrow: "YOUR TALK KEYS",
                title: "Choose how you talk",
                description: "Choose one key to hold while speaking and another to tap when you want to talk hands free."
            )
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose your keys")
                    .font(SprekrTypography.body(13, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(SprekrPalette.primaryText)
                VStack(spacing: 0) {
                    onboardingShortcutRow(for: .hold)
                    Divider().overlay(SprekrPalette.line)
                    onboardingShortcutRow(for: .toggle)
                }
                .sprekrSurface()
                Text("Click a field, then press any key, key combination, or mouse side button. Escape cancels without changing it.")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            TalkControlStatusRow(
                accessibilityGranted: permissions.accessibilityGranted,
                controlsRegistered: controller.hotkey.isRegistered,
                isChoosingShortcut: isRecordingShortcut,
                openAccessibilitySettings: openAccessibilitySettings,
                retryRegistration: { controller.beginOnboardingTalkKeyPreview() }
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Test your talk controls")
                    .font(SprekrTypography.body(13, weight: .semibold))
                    .foregroundStyle(SprekrPalette.primaryText)
                Text(talkKeyTestInstruction)
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
                MicrophoneLevelMeter(
                    level: audioCapture.level,
                    isActive: controller.isTalkKeyPreviewActive
                )
                HStack(spacing: 10) {
                    Button(controller.isTalkKeyPreviewActive ? "Stop test" : "Start test") {
                        controller.toggleTalkKeyPreview()
                    }
                    .buttonStyle(.bordered)
                    Text(controller.isTalkKeyPreviewActive
                        ? "Speak normally. Release Hold or tap Toggle again to stop."
                        : "Or use this button as a mouse fallback.")
                        .font(SprekrTypography.body(12, relativeTo: .caption))
                        .foregroundStyle(SprekrPalette.secondaryText)
                }
            }
            if shouldShowTalkKeyBlockingMessage,
               let message = talkKeyBlockingMessage {
                Text(message).font(SprekrTypography.body(12, relativeTo: .caption)).foregroundStyle(.red)
            }
        }
    }

    private func onboardingShortcutRow(for mode: DictationMode) -> some View {
        let configuration = mode == .hold
            ? controller.settings.values.holdShortcut
            : controller.settings.values.toggleShortcut

        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .hold ? "Hold to talk" : "Toggle to talk")
                    .font(SprekrTypography.body(15, weight: .semibold))
                    .foregroundStyle(SprekrPalette.primaryText)
                Text(mode == .hold
                    ? "Hold the key while speaking. Release it to stop."
                    : "Tap once to start. Tap the same key again to stop.")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorder(
                configuration: configuration,
                isRecording: shortcutRecordingBinding(for: mode)
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
            .frame(width: 210, height: 48)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    controller.endOnboardingTalkKeyPreview()
                    controller.setShortcutCaptureActive(true)
                } else if !isRecordingHoldShortcut && !isRecordingToggleShortcut && step == 5 {
                    controller.setShortcutCaptureActive(false)
                    controller.beginOnboardingTalkKeyPreview()
                }
            }
        )
    }

    private var startupContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingCopy(
                eyebrow: "WORKSPACE",
                title: "Set your starting preferences",
                description: "These choices can be changed any time in Settings."
            )
            Toggle("Launch at login", isOn: settingBinding(\.launchAtLogin))
            Toggle("Show Flow Bar at all times", isOn: settingBinding(\.showFlowBar))
            Toggle("Show app in Dock", isOn: settingBinding(\.showInDock))
            Toggle("Play dictation sounds", isOn: settingBinding(\.soundsEnabled))
        }
        .toggleStyle(.switch)
    }

    private var finishContent: some View {
        Group {
            switch finishPhase {
            case .preparing:
                VStack(spacing: 24) {
                    Text("Sprekr")
                        .font(SprekrTypography.heading(72))
                        .tracking(-1.8)
                        .foregroundStyle(SprekrPalette.primaryText)
                        .frame(maxWidth: .infinity)

                    FloatingDotsLoader(size: 66)
                        .foregroundStyle(SprekrPalette.accent)

                    VStack(spacing: 10) {
                        ProgressView(value: finishProgress)
                            .progressViewStyle(.linear)
                            .tint(SprekrPalette.accent)
                            .frame(width: 290)
                            .accessibilityLabel("Preparing Sprekr")
                            .accessibilityValue("\(Int(finishProgress * 100)) percent")

                        Text("Preparing your private workspace")
                            .font(SprekrTypography.body(13, weight: .medium, relativeTo: .callout))
                            .foregroundStyle(SprekrPalette.secondaryText)
                    }

                    finishTipButton
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)

            case .ready:
                VStack(spacing: 22) {
                    Text("READY")
                        .font(SprekrTypography.body(11, weight: .semibold, relativeTo: .caption))
                        .tracking(1.4)
                        .foregroundStyle(SprekrPalette.accent)
                    Text("You’re ready to talk.")
                        .sprekrHeading(46)
                        .multilineTextAlignment(.center)
                    Text("Sprekr is prepared. Your talk keys and Flow Bar will stay close while you work.")
                        .sprekrBody()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 510)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: finishPhase)
    }

    private var finishTipButton: some View {
        Button {
            showNextFinishTip()
        } label: {
            VStack(spacing: 8) {
                Text("TIP")
                    .sprekrLabel()
                Text(OnboardingFinishPolicy.tips[finishTipIndex])
                    .font(SprekrTypography.body(14, weight: .medium, relativeTo: .body))
                    .foregroundStyle(SprekrPalette.primaryText)
                    .multilineTextAlignment(.center)
                    .id(finishTipIndex)
                    .transition(.opacity)
                Label("Show another tip", systemImage: "arrow.right")
                    .font(SprekrTypography.body(12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 430, minHeight: 112)
        }
        .buttonStyle(
            SprekrHoverButtonStyle(
                baseFill: SprekrPalette.surface,
                cornerRadius: 16,
                hoverOpacity: 0.055,
                pressedOpacity: 0.09
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SprekrPalette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Tip. \(OnboardingFinishPolicy.tips[finishTipIndex])")
        .accessibilityHint("Shows another tip")
    }

    private var testContent: some View {
        let buttonState = OnboardingDictationButtonState.resolve(
            isStarting: controller.isStartingDictation,
            isRecording: audioCapture.isRecording,
            isTranscribing: controller.isTranscribing
        )
        return VStack(alignment: .leading, spacing: 18) {
            OnboardingCopy(
                eyebrow: "FIRST DICTATION",
                title: "Try a thought out loud.",
                description: "Place the cursor below, then use your talk key or the button. Sprekr will show listening, processing, and delivery in the Flow Bar."
            )
            TextEditor(text: $testText)
                .font(SprekrTypography.body())
                .lineSpacing(7)
                .frame(height: 120)
                .padding(10)
                .sprekrSurface()
            Button(buttonState.title) {
                controller.toggleOnboardingTestDictation()
            }
                .buttonStyle(SprekrPrimaryButtonStyle())
                .disabled(buttonState.isDisabled)
        }
    }

    private var isRecordingShortcut: Bool {
        isRecordingHoldShortcut || isRecordingToggleShortcut
    }

    private var talkKeysReady: Bool {
        OnboardingReadinessPolicy.canContinueFromTalkKeys(
            hotkeyRegistered: controller.hotkey.isRegistered,
            conflictMessage: activeShortcutConflictMessage,
            isRecordingShortcut: isRecordingShortcut
        )
    }

    private var talkKeyBlockingMessage: String? {
        OnboardingReadinessPolicy.blockingTalkKeyMessage(
            hotkeyRegistered: controller.hotkey.isRegistered,
            conflictMessage: activeShortcutConflictMessage,
            isRecordingShortcut: isRecordingShortcut
        )
    }

    private var activeShortcutConflictMessage: String? {
        shortcutValidationMessage ?? controller.hotkey.conflictMessage
    }

    private var shouldShowTalkKeyBlockingMessage: Bool {
        isRecordingShortcut
            || activeShortcutConflictMessage != nil
            || !controller.hotkey.isRegistered
    }

    private func settingBinding(_ keyPath: WritableKeyPath<SprekrSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.settings.values[keyPath: keyPath] },
            set: { value in controller.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func advance() {
        move(to: min(step + 1, steps.count - 1))
    }

    private func move(to destination: Int) {
        if destination > step {
            if step == 2,
               !OnboardingReadinessPolicy.canContinueFromModel(modelManager.state) {
                return
            }
            if step == 5, !talkKeysReady { return }
        }

        stopMicrophoneTest()
        isRecordingHoldShortcut = false
        isRecordingToggleShortcut = false
        controller.setShortcutCaptureActive(false)
        shortcutValidationMessage = nil
        if step == steps.count - 1 { finishTask?.cancel() }
        if step == 5 { controller.endOnboardingTalkKeyPreview() }
        if step == 7 { controller.endOnboardingTest() }
        setStep(destination)
        if destination == 5 { controller.beginOnboardingTalkKeyPreview() }
        if destination == 7 { controller.beginOnboardingTest() }
        if destination == steps.count - 1 { startFinishSequence() }
    }

    private func startFinishSequence() {
        finishTask?.cancel()
        finishPhase = .preparing
        finishProgress = 0
        finishTipIndex = 0

        finishTask = Task { @MainActor in
            let totalSteps = OnboardingFinishPolicy.progressStepCount
            for index in 1...totalSteps {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(OnboardingFinishPolicy.progressStepMilliseconds))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .linear(duration: 0.1)) {
                    finishProgress = Double(index) / Double(totalSteps)
                }
                if index % OnboardingFinishPolicy.automaticTipStepInterval == 0 {
                    showNextFinishTip()
                }
            }

            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
                finishPhase = .ready
            }
        }
    }

    private func showNextFinishTip() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            finishTipIndex = (finishTipIndex + 1) % OnboardingFinishPolicy.tips.count
        }
    }

    private var talkKeyTestInstruction: String {
        let holdKey = controller.settings.values.holdShortcut.displayName
        let toggleKey = controller.settings.values.toggleShortcut.displayName
        return "Hold \(holdKey) to speak, or tap \(toggleKey) to start and stop."
    }

    private var contentVerticalPadding: CGFloat {
        step == 5 ? 28 : 52
    }

    private func setStep(_ value: Int) {
        if reduceMotion {
            step = value
        } else {
            withAnimation(.easeOut(duration: 0.28)) { step = value }
        }
    }

    @ViewBuilder
    private var permissionRefreshStatus: some View {
        if isCheckingPermissions && !currentStepPermissionGranted {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking permission…")
                    .font(SprekrTypography.body(13, relativeTo: .body))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            .transition(.opacity)
        }
    }

    private var refreshPermissionButton: some View {
        Button { refreshPermissions() } label: {
            Group {
                if isCheckingPermissions {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(SprekrPalette.icon)
                }
            }
            .frame(width: 30, height: 30)
            .background(SprekrPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(SprekrPalette.icon)
        .disabled(isCheckingPermissions)
        .help("Refresh permission status")
        .accessibilityLabel("Refresh permission status")
    }

    private func requestMicrophone() {
        Task {
            isCheckingPermissions = true
            _ = await permissions.requestMicrophone()
            await finishPermissionRefresh()
        }
    }

    private var microphoneActionTitle: String {
        if isTestingMicrophone { return "Stop microphone test" }
        if permissions.microphoneStatus == .denied { return "Open Microphone settings" }
        return permissions.microphoneStatus == .authorized ? "Test microphone" : "Allow microphone"
    }

    private func handleMicrophoneAction() {
        if isTestingMicrophone {
            stopMicrophoneTest()
        } else if permissions.microphoneStatus == .authorized {
            startMicrophoneTest()
        } else if permissions.microphoneStatus == .denied {
            permissions.openPrivacySettings(.microphone)
        } else {
            requestMicrophone()
        }
    }

    private func startMicrophoneTest() {
        microphoneTestError = nil
        do {
            try audioCapture.start(deviceUID: controller.settings.values.microphoneUID)
            isTestingMicrophone = true
            microphoneLevelTask?.cancel()
            microphoneLevelTask = Task { @MainActor in
                while !Task.isCancelled, isTestingMicrophone {
                    audioCapture.refreshLevel()
                    microphoneLevel = audioCapture.level
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        } catch {
            microphoneTestError = error.localizedDescription
            stopMicrophoneTest()
        }
    }

    private func stopMicrophoneTest() {
        microphoneLevelTask?.cancel()
        microphoneLevelTask = nil
        if isTestingMicrophone { audioCapture.cancel() }
        isTestingMicrophone = false
        microphoneLevel = 0
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { controller.settings.values.microphoneUID },
            set: { value in
                let wasTesting = isTestingMicrophone
                if wasTesting { stopMicrophoneTest() }
                controller.updateSettings { $0.microphoneUID = value }
                audioCapture.refreshAvailableInputs()
                if wasTesting { startMicrophoneTest() }
            }
        )
    }

    private func refreshPermissions(showSpinner: Bool = true) {
        Task {
            if showSpinner { isCheckingPermissions = true }
            permissions.refresh()
            await finishPermissionRefresh()
        }
    }

    private func finishPermissionRefresh() async {
        try? await Task.sleep(for: .milliseconds(350))
        permissions.refresh()
        isCheckingPermissions = false
    }

    private var currentStepPermissionGranted: Bool {
        switch step {
        case 3: permissions.microphoneStatus == .authorized
        case 4: permissions.accessibilityGranted
        default: true
        }
    }

    private func openAccessibilitySettings() {
        isCheckingPermissions = true
        controller.requestAccessibility()
        Task { await finishPermissionRefresh() }
    }
}

private struct FiduciaOnboardingBrand: View {
    var body: some View {
        HStack(spacing: 8) {
            FiduciaBrandMarkView(width: 20, height: 20)
            Text("Fiducia Development")
                .font(SprekrTypography.body(12, weight: .medium, relativeTo: .caption))
                .foregroundStyle(SprekrPalette.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fiducia Development")
    }
}

private struct FloatingDotsLoader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            Canvas { context, canvasSize in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let positions = [
                    CGPoint(
                        x: center.x + cos(time * 2.15) * size * 0.17,
                        y: center.y + sin(time * 1.75) * size * 0.11
                    ),
                    CGPoint(
                        x: center.x + cos(time * 1.55 + 2.1) * size * 0.19,
                        y: center.y + sin(time * 2.05 + 1.2) * size * 0.14
                    ),
                    CGPoint(
                        x: center.x + cos(time * 1.85 + 4.3) * size * 0.15,
                        y: center.y + sin(time * 1.45 + 3.4) * size * 0.17
                    ),
                ]
                let radii = [size * 0.17, size * 0.145, size * 0.13]

                for (index, position) in positions.enumerated() {
                    let radius = radii[index]
                    let rect = CGRect(
                        x: position.x - radius,
                        y: position.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(SprekrPalette.accent))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing Sprekr")
    }
}

private struct OnboardingCopy: View {
    let eyebrow: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow)
                .font(SprekrTypography.body(11, weight: .semibold, relativeTo: .caption))
                .tracking(1.4)
                .foregroundStyle(SprekrPalette.accent)
            Text(title).sprekrHeading(46)
            Text(description).sprekrBody().frame(maxWidth: 510, alignment: .leading)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let allowed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(SprekrPalette.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(SprekrTypography.body(14, weight: .medium, relativeTo: .body))
                Text(detail).font(SprekrTypography.body(12, relativeTo: .caption)).foregroundStyle(SprekrPalette.secondaryText)
            }
        }
        .padding(14)
        .sprekrSurface()
    }
}

private struct TalkControlStatusRow: View {
    let accessibilityGranted: Bool
    let controlsRegistered: Bool
    let isChoosingShortcut: Bool
    let openAccessibilitySettings: () -> Void
    let retryRegistration: () -> Void

    private var isReady: Bool { accessibilityGranted && controlsRegistered }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use your talk keys in every app")
                        .font(SprekrTypography.body(14, weight: .semibold))
                        .foregroundStyle(SprekrPalette.primaryText)
                    Text(detail)
                        .font(SprekrTypography.body(12, relativeTo: .caption))
                        .foregroundStyle(SprekrPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(isReady ? "Ready" : isChoosingShortcut ? "Choosing keys" : "Needs attention")
                    .font(SprekrTypography.body(11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(isReady ? SprekrPalette.accent : SprekrPalette.secondaryText)
            }

            if isChoosingShortcut {
                EmptyView()
            } else if !accessibilityGranted {
                Button("Open Accessibility settings", action: openAccessibilitySettings)
                    .buttonStyle(.plain)
                    .foregroundStyle(SprekrPalette.accent)
            } else if !controlsRegistered {
                Button("Try again", action: retryRegistration)
                    .buttonStyle(.plain)
                    .foregroundStyle(SprekrPalette.accent)
            }
        }
        .padding(14)
        .sprekrSurface()
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        if isReady {
            return "Ready. Your chosen keys now work here and while you use other apps."
        }
        if isChoosingShortcut {
            return "Finish choosing your keys, then Sprekr will verify them in every app."
        }
        if accessibilityGranted {
            return "Accessibility is allowed, but Sprekr could not activate the chosen keys yet."
        }
        return "Accessibility must be allowed before your chosen keys can work while another app is open."
    }
}

private struct MicrophoneLevelMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Float
    let isActive: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<22, id: \.self) { index in
                let shape = CGFloat(0.45 + Float((index * 7) % 9) / 12)
                Capsule()
                    .fill(isActive ? SprekrPalette.accent : SprekrPalette.line)
                    .frame(width: 4, height: isActive ? 4 + CGFloat(level) * 18 * shape : 4)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
            }
            Spacer()
            Text(isActive ? "Listening" : "Ready")
                .font(SprekrTypography.body(12, relativeTo: .caption))
                .foregroundStyle(SprekrPalette.secondaryText)
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
        .background(SprekrPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isActive ? "Microphone test is listening" : "Microphone test is ready")
        .accessibilityValue(isActive ? "Level \(Int(level * 100)) percent" : "")
    }
}

struct ModelProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: ModelInstallState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .notInstalled:
                Text("Ready to download")
                    .font(SprekrTypography.body(14, relativeTo: .body))
            case .checking:
                busyStatus(ModelProgressPresentation.checkingTitle)
            case let .preparing(detail):
                busyStatus(detail)
            case let .downloading(progress, detail):
                let percentage = ModelProgressPresentation.percentage(for: progress)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        busyIndicator
                        Text(ModelProgressPresentation.downloadTitle(percentage: percentage))
                            .font(SprekrTypography.body(14, relativeTo: .body))
                    }
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(SprekrPalette.accent)
                    Text(detail)
                        .font(SprekrTypography.body(12, relativeTo: .caption))
                        .foregroundStyle(SprekrPalette.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Downloading speech model")
                .accessibilityValue("\(percentage) percent, \(detail)")
            case let .installed(bytes):
                Label("Installed — \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SprekrPalette.accent)
            case let .failed(message):
                Text(message).font(SprekrTypography.body(12, relativeTo: .caption)).foregroundStyle(.red)
            }
        }
        .padding(14)
        .sprekrSurface()
    }

    private func busyStatus(_ text: String) -> some View {
        HStack(spacing: 9) {
            busyIndicator
            Text(text)
                .font(SprekrTypography.body(14, relativeTo: .body))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var busyIndicator: some View {
        if reduceMotion {
            Image(systemName: "hourglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SprekrPalette.icon)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(SprekrPalette.accent)
                .accessibilityHidden(true)
        }
    }
}

enum ModelProgressPresentation {
    static let checkingTitle = "Checking for a model on this Mac…"

    static func percentage(for progress: Double) -> Int {
        Int((min(max(progress, 0), 1) * 100).rounded())
    }

    static func downloadTitle(percentage: Int) -> String {
        "Downloading speech model — \(percentage)%"
    }
}
