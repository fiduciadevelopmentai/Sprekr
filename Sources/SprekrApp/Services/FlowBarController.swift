import AppKit
import Combine
import SwiftUI

enum FlowBarGeometry {
    static let messageHeight: CGFloat = 40
    static let messageMinimumWidth: CGFloat = 148
    static let messageMaximumWidth: CGFloat = 360
    static let messageHorizontalPadding: CGFloat = 12
    static let messageIconWidth: CGFloat = 14
    static let messageSpacing: CGFloat = 8

    static func panelSize(for state: FlowBarState, hoverExpanded: Bool = false) -> NSSize {
        switch state {
        case .listening:
            NSSize(width: 86, height: 25)
        case .transcribing:
            NSSize(width: 52, height: 25)
        case .success:
            NSSize(width: 52, height: 20)
        case .undo:
            NSSize(width: 200, height: 40)
        case .idle:
            hoverExpanded ? NSSize(width: 114, height: 36) : NSSize(width: 52, height: 20)
        case let .error(message, _), let .recovery(message, _):
            NSSize(width: messageWidth(for: message), height: messageHeight)
        }
    }

    static func messageWidth(for message: String) -> CGFloat {
        let font = NSFont(name: SprekrTypography.bodyMediumPostScriptName, size: 13)
            ?? NSFont(name: SprekrTypography.bodyRegularPostScriptName, size: 13)
            ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let fitted = textWidth
            + messageIconWidth
            + messageSpacing
            + messageHorizontalPadding * 2
        return min(max(fitted, messageMinimumWidth), messageMaximumWidth)
    }

    static func bottomInset(for state: FlowBarState) -> CGFloat {
        state == .idle ? 14 : 18
    }
}

enum FlowBarHoverPolicy {
    static let expandDuration: TimeInterval = 0.18
    static let collapseDuration: TimeInterval = 0.13
    static let collapseDelayMilliseconds = 160

    static func shouldCollapse(
        panelFrame: NSRect?,
        pointerLocation: NSPoint,
        languageMenuPresented: Bool
    ) -> Bool {
        guard !languageMenuPresented, let panelFrame else { return false }
        return !panelFrame.contains(pointerLocation)
    }
}

enum FlowBarTransitionPolicy {
    static let minimumProcessingPresentation = Duration.milliseconds(700)
    static let animatesStateChanges = false

    static func waitForProcessingPresentation(
        since startedAt: ContinuousClock.Instant,
        clock: ContinuousClock = .continuous
    ) async throws {
        let elapsed = startedAt.duration(to: clock.now)
        let remaining = minimumProcessingPresentation - elapsed
        if remaining > .zero {
            try await Task.sleep(for: remaining)
        }
    }
}

enum FlowBarCountdownPolicy {
    static let messageDuration: TimeInterval = 3.8
    static let undoDuration: TimeInterval = 6
    static let animatedRefreshInterval: TimeInterval = 1.0 / 30.0
    static let reducedMotionRefreshInterval: TimeInterval = 1

    static func progress(
        deadline: Date,
        duration: TimeInterval,
        now: Date = .now
    ) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(deadline.timeIntervalSince(now) / duration, 0), 1)
    }

    static func refreshInterval(reducedMotion: Bool) -> TimeInterval {
        reducedMotion ? reducedMotionRefreshInterval : animatedRefreshInterval
    }
}

enum FlowBarMessageResetPolicy {
    static func shouldReset(state: FlowBarState, expectedDeadline: Date) -> Bool {
        switch state {
        case let .error(_, deadline), let .recovery(_, deadline):
            deadline == expectedDeadline
        default:
            false
        }
    }
}

enum FlowBarSamplePolicy {
    static func appending(_ level: Float, to samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [level] }
        return Array(samples.dropFirst()) + [level]
    }
}

enum FlowBarWaveformPolicy {
    static let sampleCount = 28
    static let updateInterval = Duration.milliseconds(20)

    static func smoothedAmplitudes(from samples: [Float]) -> [CGFloat] {
        guard !samples.isEmpty else { return [] }
        return samples.indices.map { index in
            let left = CGFloat(samples[max(0, index - 1)])
            let center = CGFloat(samples[index])
            let right = CGFloat(samples[min(samples.count - 1, index + 1)])
            let blended = max(0, min(1, left * 0.22 + center * 0.56 + right * 0.22))
            return sqrt(blended)
        }
    }
}

@MainActor
final class FlowBarController: NSObject, ObservableObject {
    @Published private(set) var state: FlowBarState = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var samples = Array(
        repeating: Float.zero,
        count: FlowBarWaveformPolicy.sampleCount
    )
    @Published private(set) var isHoverExpanded = false
    @Published private(set) var outputLanguage: RecognitionLanguage = .automatic

    let translationService = LocalTranslationService()
    var onToggle: (() -> Void)?
    var onUndo: (() -> Void)?
    var onLanguageChange: ((RecognitionLanguage) -> Void)?
    private var panel: NSPanel?
    private var showWhenIdle = true
    private var preferredScreenNumber: NSNumber?
    private var isLanguageMenuPresented = false
    private var hoverCollapseTask: Task<Void, Never>?
    private var messageResetTask: Task<Void, Never>?

    var acceptsNewDictation: Bool { state == .idle }
    var presentedPanelSize: NSSize? { panel?.frame.size }
    var presentedContentSize: NSSize? { panel?.contentView?.bounds.size }

    var acceptsTap: Bool {
        switch state {
        case .idle, .listening, .undo:
            true
        case .transcribing, .success, .recovery, .error:
            false
        }
    }

    func showIfNeeded(_ shouldShow: Bool) {
        showWhenIdle = shouldShow
        guard shouldShow || state != .idle else {
            clearHoverState()
            panel?.orderOut(nil)
            return
        }
        presentPanel()
    }

    func captureActiveScreen() {
        preferredScreenNumber = (NSScreen.main ?? NSScreen.screens.first).flatMap(Self.screenNumber)
    }

    func setListening(level: Float) {
        let stateChanged = state != .listening
        if stateChanged {
            prepareForStateChange()
            performWithoutStateAnimation {
                state = .listening
                self.level = level
                samples = Array(repeating: .zero, count: samples.count)
                samples = FlowBarSamplePolicy.appending(level, to: samples)
                presentPanel()
            }
            return
        }
        self.level = level
        // Assign the full buffer once. Mutating the published array with
        // removeFirst() and append() exposed a transient 11-sample frame to
        // SwiftUI, which made the waveform look cropped after a quiet pause.
        samples = FlowBarSamplePolicy.appending(level, to: samples)
    }

    func setTranscribing() {
        prepareForStateChange()
        performWithoutStateAnimation {
            level = 0
            state = .transcribing
            presentPanel()
        }
    }

    func setUndo(deadline: Date) {
        prepareForStateChange()
        performWithoutStateAnimation {
            level = 0
            state = .undo(deadline: deadline)
            presentPanel()
        }
    }

    func setSuccess() {
        // Successful delivery needs no extra badge or frozen waveform. The
        // processing loader already communicated the wait, so return directly
        // to the quiet idle handle once the text is ready.
        reset()
    }

    func setError(_ message: String) {
        prepareForStateChange()
        let deadline = Date.now.addingTimeInterval(FlowBarCountdownPolicy.messageDuration)
        performWithoutStateAnimation {
            level = 0
            state = .error(message: message, deadline: deadline)
            scheduleMessageReset(deadline: deadline)
        }
    }

    func setRecovery(_ message: String) {
        prepareForStateChange()
        let deadline = Date.now.addingTimeInterval(FlowBarCountdownPolicy.messageDuration)
        performWithoutStateAnimation {
            level = 0
            state = .recovery(message: message, deadline: deadline)
            scheduleMessageReset(deadline: deadline)
        }
    }

    private func scheduleMessageReset(deadline: Date) {
        presentPanel()
        messageResetTask = Task { @MainActor [weak self] in
            let remaining = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled,
                  let self,
                  FlowBarMessageResetPolicy.shouldReset(
                    state: self.state,
                    expectedDeadline: deadline
                  ) else { return }
            self.reset()
        }
    }

    func reset() {
        prepareForStateChange()
        performWithoutStateAnimation {
            level = 0
            state = .idle
            samples = Array(repeating: .zero, count: samples.count)
            if showWhenIdle {
                presentPanel()
            } else {
                panel?.orderOut(nil)
            }
        }
    }

    private func prepareForStateChange() {
        clearHoverState()
        messageResetTask?.cancel()
        messageResetTask = nil
    }

    func setHoverExpanded(_ expanded: Bool) {
        guard state == .idle, showWhenIdle else { return }
        if expanded {
            hoverCollapseTask?.cancel()
            hoverCollapseTask = nil
            guard !isHoverExpanded else { return }
            isHoverExpanded = true
            positionPanel(animationDuration: FlowBarHoverPolicy.expandDuration)
        } else {
            scheduleHoverCollapse()
        }
    }

    private func scheduleHoverCollapse() {
        guard !isLanguageMenuPresented, isHoverExpanded else { return }
        hoverCollapseTask?.cancel()
        hoverCollapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .milliseconds(FlowBarHoverPolicy.collapseDelayMilliseconds)
            )
            guard !Task.isCancelled, let self else { return }
            self.hoverCollapseTask = nil
            guard self.state == .idle, self.showWhenIdle, self.isHoverExpanded else { return }
            guard FlowBarHoverPolicy.shouldCollapse(
                panelFrame: self.panel?.frame,
                pointerLocation: NSEvent.mouseLocation,
                languageMenuPresented: self.isLanguageMenuPresented
            ) else { return }

            self.isHoverExpanded = false
            self.positionPanel(animationDuration: FlowBarHoverPolicy.collapseDuration)
        }
    }

    private func clearHoverState() {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil
        guard isHoverExpanded else { return }
        performWithoutStateAnimation {
            isHoverExpanded = false
        }
    }

    private func performWithoutStateAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = !FlowBarTransitionPolicy.animatesStateChanges
        withTransaction(transaction, updates)
    }

    func setOutputLanguage(_ language: RecognitionLanguage) {
        outputLanguage = language
    }

    func cycleOutputLanguage() {
        let next = outputLanguage.nextOutputLanguage
        outputLanguage = next
        onLanguageChange?(next)
    }

    func showOutputLanguageMenu() {
        guard let contentView = panel?.contentView, state == .idle else { return }
        isLanguageMenuPresented = true

        let menu = NSMenu(title: "Output language")
        menu.autoenablesItems = false
        for language in RecognitionLanguage.allCases {
            let item = NSMenuItem(
                title: language.outputDisplayName,
                action: #selector(selectOutputLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == outputLanguage ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
        }

        let selected = menu.items.first { $0.state == .on }
        menu.popUp(
            positioning: selected,
            at: NSPoint(x: 2, y: contentView.bounds.height + 4),
            in: contentView
        )

        isLanguageMenuPresented = false
        if let panel, !panel.frame.contains(NSEvent.mouseLocation) {
            setHoverExpanded(false)
        }
    }

    @objc private func selectOutputLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = RecognitionLanguage(rawValue: rawValue) else { return }
        outputLanguage = language
        onLanguageChange?(language)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: .init(x: 0, y: 0, width: 52, height: 20),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        let hostingView = NSHostingView(rootView: FlowBarView(controller: self))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.panel = panel

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func reposition() {
        positionPanel()
    }

    private func positionPanel(animationDuration: TimeInterval? = nil) {
        guard let panel else { return }
        let screen = preferredScreenNumber.flatMap { preferredNumber in
            NSScreen.screens.first { Self.screenNumber($0) == preferredNumber }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panelSize
        let targetFrame = NSRect(
            x: frame.midX - size.width / 2,
            y: frame.minY + FlowBarGeometry.bottomInset(for: state),
            width: size.width,
            height: size.height
        )
        if let animationDuration,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            // State content and panel geometry change in one main-actor turn.
            // A direct frame assignment prevents the new SwiftUI content from
            // being rendered inside the previous state's animated width.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.setFrame(targetFrame, display: true, animate: false)
                panel.contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
                panel.contentView?.needsLayout = true
                panel.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }

    private func presentPanel(animationDuration: TimeInterval? = nil) {
        ensurePanel()
        positionPanel(animationDuration: animationDuration)
        panel?.orderFrontRegardless()
    }

    private var panelSize: NSSize {
        FlowBarGeometry.panelSize(for: state, hoverExpanded: isHoverExpanded)
    }

    private static func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
}

private struct FlowBarView: View {
    @ObservedObject var controller: FlowBarController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if controller.state == .idle, controller.isHoverExpanded {
                hoverControls
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            } else {
                Button(action: handleTap) {
                    content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(controller.acceptsTap)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if controller.state != .idle || controller.isHoverExpanded {
                Capsule().fill(Color.sprekrFlowBackground)
            }
        }
        .overlay {
            if controller.state != .idle || controller.isHoverExpanded {
                Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { controller.setHoverExpanded($0) }
        .animation(
            reduceMotion ? nil : .easeOut(duration: controller.isHoverExpanded ? 0.18 : 0.13),
            value: controller.isHoverExpanded
        )
        .sprekrLocalTranslationHost(controller.translationService)
    }

    private var hoverControls: some View {
        HStack(spacing: 4) {
            Button {
                controller.showOutputLanguageMenu()
            } label: {
                HStack(spacing: 3) {
                    Text(controller.outputLanguage.flowBarCode)
                        .font(SprekrTypography.body(9, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 5.5, weight: .bold))
                        .opacity(0.55)
                }
                .foregroundStyle(Color.sprekrFlowForeground)
                .frame(width: 48, height: 28)
            }
            .buttonStyle(SprekrFlowControlButtonStyle(reduced: reduceMotion))
            .help("Output language: \(controller.outputLanguage.outputDisplayName)")
            .accessibilityLabel("Output language, \(controller.outputLanguage.outputDisplayName)")
            .accessibilityHint("Press to change the output language")

            Button(action: handleTap) {
                Image(systemName: "microphone.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.sprekrFlowForeground)
                    .frame(width: 56, height: 28)
            }
            .buttonStyle(SprekrFlowControlButtonStyle(reduced: reduceMotion))
            .help("Start dictation")
            .accessibilityLabel("Start dictation")
        }
        .padding(3)
    }

    private func handleTap() {
        guard controller.acceptsTap else { return }
        if case .undo = controller.state {
            controller.onUndo?()
        } else {
            controller.onToggle?()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            Capsule()
                .fill(Color.sprekrIdleHandle)
                .frame(width: 44, height: 7)
                .overlay(Capsule().stroke(Color.black.opacity(0.18), lineWidth: 1))
        case .listening:
            HStack(spacing: 5) {
                SprekrBrandMarkView(width: 16, height: 11)
                Waveform(samples: controller.samples, active: true, reduced: reduceMotion)
                    .frame(width: 56, height: 18)
            }
        case .transcribing:
            DotMatrixLoader(reduced: reduceMotion)
                .frame(width: 15, height: 15)
        case let .undo(deadline):
            UndoRecordingView(deadline: deadline, reduced: reduceMotion)
        case .success:
            Capsule()
                .fill(Color.sprekrIdleHandle)
                .frame(width: 44, height: 7)
                .overlay(Capsule().stroke(Color.black.opacity(0.18), lineWidth: 1))
        case let .recovery(message, deadline):
            TimedFlowBarMessageView(
                message: message,
                systemImage: "doc.on.clipboard",
                deadline: deadline,
                reduced: reduceMotion
            )
        case let .error(message, deadline):
            TimedFlowBarMessageView(
                message: message,
                systemImage: "exclamationmark.circle",
                deadline: deadline,
                reduced: reduceMotion
            )
        }
    }

    private var accessibilityLabel: String {
        switch controller.state {
        case .idle: "Sprekr, ready"
        case .listening: "Sprekr is listening"
        case .transcribing: "Sprekr is transcribing"
        case .undo: "Undo cancelled recording"
        case .success: "Sprekr finished the dictation"
        case let .recovery(message, _): "Sprekr recovery: \(message)"
        case let .error(message, _): "Sprekr error: \(message)"
        }
    }

    private var accessibilityHint: String {
        if case .undo = controller.state {
            return "Activate within six seconds to transcribe the cancelled recording."
        }
        return ""
    }
}

private struct SprekrFlowControlButtonStyle: ButtonStyle {
    let reduced: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.15 : 0.07))
            }
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(reduced ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct Waveform: View {
    let samples: [Float]
    let active: Bool
    let reduced: Bool

    var body: some View {
        Canvas { context, size in
            let amplitudes = reduced
                ? Array(repeating: CGFloat(0.08), count: max(samples.count, 2))
                : FlowBarWaveformPolicy.smoothedAmplitudes(from: samples)
            guard amplitudes.count > 1 else { return }

            let centerY = size.height / 2
            let minimumHalfHeight: CGFloat = 1.15
            let availableHalfHeight = max(0, size.height / 2 - minimumHalfHeight - 0.75)
            let points = amplitudes.enumerated().map { index, amplitude in
                let progress = CGFloat(index) / CGFloat(amplitudes.count - 1)
                let edgeCurve = sin(CGFloat.pi * progress)
                let edgeEnvelope = CGFloat(0.42 + 0.58 * pow(Double(edgeCurve), 0.58))
                let halfHeight = minimumHalfHeight + amplitude * availableHalfHeight * edgeEnvelope
                return CGPoint(
                    x: progress * size.width,
                    y: halfHeight
                )
            }

            let top = points.map { CGPoint(x: $0.x, y: centerY - $0.y) }
            let bottom = points.reversed().map { CGPoint(x: $0.x, y: centerY + $0.y) }
            var ribbon = Path()
            addSmoothCurve(points: top, to: &ribbon, moveToFirstPoint: true)
            addSmoothCurve(points: bottom, to: &ribbon, moveToFirstPoint: false)
            ribbon.closeSubpath()

            context.fill(
                ribbon,
                with: .color(active ? .sprekrFlowForeground : .sprekrFlowForeground.opacity(0.42))
            )
        }
        .accessibilityHidden(true)
    }

    private func addSmoothCurve(
        points: [CGPoint],
        to path: inout Path,
        moveToFirstPoint: Bool
    ) {
        guard let first = points.first else { return }
        if moveToFirstPoint {
            path.move(to: first)
        } else {
            path.addLine(to: first)
        }

        for index in 0..<(points.count - 1) {
            let previous = index > 0 ? points[index - 1] : points[index]
            let current = points[index]
            let next = points[index + 1]
            let following = index + 2 < points.count ? points[index + 2] : next
            let firstControl = CGPoint(
                x: current.x + (next.x - previous.x) / 6,
                y: current.y + (next.y - previous.y) / 6
            )
            let secondControl = CGPoint(
                x: next.x - (following.x - current.x) / 6,
                y: next.y - (following.y - current.y) / 6
            )
            path.addCurve(to: next, control1: firstControl, control2: secondControl)
        }
    }
}

private struct UndoRecordingView: View {
    let deadline: Date
    let reduced: Bool

    var body: some View {
        TimelineView(.animation(
            minimumInterval: FlowBarCountdownPolicy.refreshInterval(reducedMotion: reduced)
        )) { timeline in
            let progress = FlowBarCountdownPolicy.progress(
                deadline: deadline,
                duration: FlowBarCountdownPolicy.undoDuration,
                now: timeline.date
            )

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.sprekrFlowForeground)
                    Text("Recording cancelled")
                        .font(SprekrTypography.body(11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("Undo")
                        .font(SprekrTypography.body(11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 23)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .foregroundStyle(Color.sprekrFlowForeground)

                FlowBarCountdownView(progress: progress)
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct TimedFlowBarMessageView: View {
    let message: String
    let systemImage: String
    let deadline: Date
    let reduced: Bool

    var body: some View {
        TimelineView(.animation(
            minimumInterval: FlowBarCountdownPolicy.refreshInterval(reducedMotion: reduced)
        )) { timeline in
            let progress = FlowBarCountdownPolicy.progress(
                deadline: deadline,
                duration: FlowBarCountdownPolicy.messageDuration,
                now: timeline.date
            )

            VStack(spacing: 4) {
                HStack(spacing: FlowBarGeometry.messageSpacing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.sprekrFlowForeground)
                        .frame(width: FlowBarGeometry.messageIconWidth)
                    Text(message)
                        .font(SprekrTypography.body(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(Color.sprekrFlowForeground)

                FlowBarCountdownView(progress: progress)
            }
            .padding(.horizontal, FlowBarGeometry.messageHorizontalPadding)
        }
    }
}

private struct FlowBarCountdownView: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color.sprekrFlowForeground.opacity(0.14))
            )
            context.fill(
                Path(CGRect(
                    x: 0,
                    y: 0,
                    width: size.width * min(max(progress, 0), 1),
                    height: size.height
                )),
                with: .color(.sprekrFlowForeground)
            )
        }
        .clipShape(Capsule())
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A compact native adaptation of the 3×3 diagonal dot-matrix loader from
/// beui.dev. One Canvas keeps the short processing state inexpensive, while
/// reduced motion replaces the loop with a static matrix.
private struct DotMatrixLoader: View {
    let reduced: Bool
    private let matrixSize = 15.0
    private let dimension = 3

    var body: some View {
        Group {
            if reduced {
                matrix(elapsed: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    matrix(elapsed: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: matrixSize, height: matrixSize)
        .accessibilityHidden(true)
    }

    private func matrix(elapsed: TimeInterval?) -> some View {
        Canvas { context, _ in
            let cycle = 0.9
            let gap = matrixSize * 0.14
            let dot = (matrixSize - gap * Double(dimension - 1)) / Double(dimension)

            for index in 0..<(dimension * dimension) {
                let column = index % dimension
                let row = index / dimension
                let delay = Double(column + row) / Double(2 * (dimension - 1))
                let wave: Double
                if let elapsed {
                    let position = positiveRemainder(elapsed / cycle - delay, divisor: 1)
                    wave = 0.5 - 0.5 * cos(position * 2 * .pi)
                } else {
                    wave = 0.55
                }
                let scale = elapsed == nil ? 1 : 0.7 + 0.3 * wave
                let opacity = elapsed == nil ? 0.62 : 0.2 + 0.8 * wave
                let renderedDot = dot * scale
                let cellX = Double(column) * (dot + gap)
                let cellY = Double(row) * (dot + gap)
                let rect = CGRect(
                    x: cellX + (dot - renderedDot) / 2,
                    y: cellY + (dot - renderedDot) / 2,
                    width: renderedDot,
                    height: renderedDot
                )
                var dotContext = context
                dotContext.opacity = opacity
                dotContext.fill(Path(ellipseIn: rect), with: .color(.sprekrFlowForeground))
            }
        }
    }

    private func positiveRemainder(_ value: Double, divisor: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

private extension Color {
    static let sprekrFlowBackground = Color(red: 0.065, green: 0.070, blue: 0.068)
    static let sprekrFlowForeground = Color(red: 0.94, green: 0.94, blue: 0.91)
    static let sprekrIdleHandle = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.58, alpha: 0.82)
            : NSColor(white: 0.43, alpha: 0.72)
    })
}
