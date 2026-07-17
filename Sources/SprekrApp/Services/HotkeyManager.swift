import ApplicationServices
import AppKit
import Combine
import Foundation

enum HotkeyAction: Equatable {
    case pass
    case swallow
    case start
    case stop
    case cancel
}

final class HotkeyEventState: @unchecked Sendable {
    private enum ShortcutTransition {
        case pressed
        case released
    }

    private let lock = NSLock()
    private var holdShortcut: ShortcutConfiguration = .fnGlobe
    private var toggleShortcut: ShortcutConfiguration = .optionSpace
    private var holdShortcutIsPressed = false
    private var toggleShortcutIsPressed = false
    private var holdShortcutStartedDictation = false
    private var dictationActive = false
    private var shortcutCaptureActive = false
    private var tap: CFMachPort?

    func configure(
        holdShortcut: ShortcutConfiguration,
        toggleShortcut: ShortcutConfiguration
    ) {
        lock.withLock {
            self.holdShortcut = holdShortcut
            self.toggleShortcut = toggleShortcut
            holdShortcutIsPressed = false
            toggleShortcutIsPressed = false
            holdShortcutStartedDictation = false
        }
    }

    func configure(shortcut: ShortcutConfiguration, mode: DictationMode) {
        switch mode {
        case .hold:
            configure(holdShortcut: shortcut, toggleShortcut: .controlReturn)
        case .toggle:
            configure(holdShortcut: .controlReturn, toggleShortcut: shortcut)
        }
    }

    func setDictationActive(_ active: Bool) {
        lock.withLock { dictationActive = active }
    }

    func setShortcutCaptureActive(_ active: Bool) {
        lock.withLock {
            shortcutCaptureActive = active
            holdShortcutIsPressed = false
            toggleShortcutIsPressed = false
            holdShortcutStartedDictation = false
        }
    }

    func resetTransientState() {
        lock.withLock {
            holdShortcutIsPressed = false
            toggleShortcutIsPressed = false
            holdShortcutStartedDictation = false
            dictationActive = false
            shortcutCaptureActive = false
        }
    }

    func setTap(_ tap: CFMachPort?) {
        lock.withLock { self.tap = tap }
    }

    func reenableTap() {
        lock.withLock {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }

    func process(type: CGEventType, event: CGEvent) -> HotkeyAction {
        lock.withLock {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return .pass
            }

            if shortcutCaptureActive { return .pass }

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let mouseButtonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if keyCode == 53 && type == .keyDown && dictationActive {
                return .cancel
            }

            if let transition = Self.transition(
                for: holdShortcut,
                type: type,
                keyCode: keyCode,
                mouseButtonNumber: mouseButtonNumber,
                flags: event.flags
            ) {
                return processHold(transition)
            }

            if let transition = Self.transition(
                for: toggleShortcut,
                type: type,
                keyCode: keyCode,
                mouseButtonNumber: mouseButtonNumber,
                flags: event.flags
            ) {
                return processToggle(transition)
            }

            return .pass
        }
    }

    private func processHold(_ transition: ShortcutTransition) -> HotkeyAction {
        switch transition {
        case .pressed:
            guard !holdShortcutIsPressed else { return .swallow }
            holdShortcutIsPressed = true
            guard !dictationActive else {
                holdShortcutStartedDictation = false
                return .swallow
            }
            holdShortcutStartedDictation = true
            return .start
        case .released:
            guard holdShortcutIsPressed else { return .pass }
            holdShortcutIsPressed = false
            let shouldStop = holdShortcutStartedDictation
            holdShortcutStartedDictation = false
            return shouldStop ? .stop : .swallow
        }
    }

    private func processToggle(_ transition: ShortcutTransition) -> HotkeyAction {
        switch transition {
        case .pressed:
            guard !toggleShortcutIsPressed else { return .swallow }
            toggleShortcutIsPressed = true
            if dictationActive && holdShortcutStartedDictation { return .swallow }
            return dictationActive ? .stop : .start
        case .released:
            guard toggleShortcutIsPressed else { return .pass }
            toggleShortcutIsPressed = false
            return .swallow
        }
    }

    private static func transition(
        for shortcut: ShortcutConfiguration,
        type: CGEventType,
        keyCode: UInt16,
        mouseButtonNumber: Int,
        flags: CGEventFlags
    ) -> ShortcutTransition? {
        if let expectedButtonNumber = shortcut.mouseButtonNumber {
            guard mouseButtonNumber == expectedButtonNumber else { return nil }
            return switch type {
            case .otherMouseDown: .pressed
            case .otherMouseUp: .released
            default: nil
            }
        }

        guard keyCode == shortcut.keyCode else { return nil }

        if let modifierFlag = shortcut.modifierOnlyFlag {
            guard type == .flagsChanged else { return nil }
            return flags.contains(modifierFlag) ? .pressed : .released
        }

        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        switch type {
        case .keyDown:
            guard flags.intersection(relevant).rawValue == shortcut.modifierFlags else { return nil }
            return .pressed
        case .keyUp:
            return .released
        default:
            return nil
        }
    }
}

@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var conflictMessage: String?
    @Published private(set) var holdConfiguration: ShortcutConfiguration = .fnGlobe
    @Published private(set) var toggleConfiguration: ShortcutConfiguration = .optionSpace

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private nonisolated let eventState = HotkeyEventState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localPreviewMonitor: Any?

    private static let listenedEventMask =
        (CGEventMask(1) << CGEventType.keyDown.rawValue) |
        (CGEventMask(1) << CGEventType.keyUp.rawValue) |
        (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
        (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
        (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)

    func configure(
        holdShortcut: ShortcutConfiguration,
        toggleShortcut: ShortcutConfiguration
    ) {
        holdConfiguration = holdShortcut
        toggleConfiguration = toggleShortcut
        conflictMessage = Self.validate(
            holdShortcut: holdShortcut,
            toggleShortcut: toggleShortcut
        )
        eventState.configure(
            holdShortcut: holdShortcut,
            toggleShortcut: toggleShortcut
        )
    }

    func configure(_ configuration: ShortcutConfiguration, mode: DictationMode) {
        switch mode {
        case .hold:
            configure(holdShortcut: configuration, toggleShortcut: .controlReturn)
        case .toggle:
            configure(holdShortcut: .controlReturn, toggleShortcut: configuration)
        }
    }

    func setDictationActive(_ active: Bool) {
        eventState.setDictationActive(active)
    }

    func setShortcutCaptureActive(_ active: Bool) {
        eventState.setShortcutCaptureActive(active)
    }

    func start() {
        stop()
        guard conflictMessage == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.listenedEventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: context
        ) else {
            isRegistered = false
            return
        }

        eventTap = tap
        eventState.setTap(tap)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRegistered = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Lets onboarding prove the selected controls while Sprekr is the
    /// active app when the global event tap cannot be created yet.
    func startLocalPreview() {
        stop()
        guard conflictMessage == nil else { return }
        localPreviewMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
        ) { [weak self] event in
            self?.handleLocalPreview(event) ?? event
        }
    }

    func startOnboardingPreview() {
        start()
        if !isRegistered { startLocalPreview() }
    }

    func stop() {
        if let localPreviewMonitor {
            NSEvent.removeMonitor(localPreviewMonitor)
        }
        localPreviewMonitor = nil
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        eventState.setTap(nil)
        eventState.resetTransientState()
        isRegistered = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func handleLocalPreview(_ event: NSEvent) -> NSEvent? {
        guard let type = Self.cgEventType(for: event.type),
              let cgEvent = event.cgEvent else { return event }

        switch eventState.process(type: type, event: cgEvent) {
        case .pass:
            return event
        case .start:
            onStart?()
        case .stop:
            onStop?()
        case .cancel:
            onCancel?()
        case .swallow:
            break
        }
        return nil
    }

    private static func cgEventType(for type: NSEvent.EventType) -> CGEventType? {
        switch type {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .flagsChanged: .flagsChanged
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        default: nil
        }
    }

    @objc private func workspaceDidWake() {
        if isRegistered { start() }
    }

    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let action = eventState.process(type: type, event: event)
        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .start:
            Task { @MainActor [weak self] in self?.onStart?() }
        case .stop:
            Task { @MainActor [weak self] in self?.onStop?() }
        case .cancel:
            Task { @MainActor [weak self] in self?.onCancel?() }
        case .swallow:
            break
        }
        return nil
    }

    private static func validate(
        holdShortcut: ShortcutConfiguration,
        toggleShortcut: ShortcutConfiguration
    ) -> String? {
        if let message = validate(holdShortcut) { return "Hold shortcut: \(message)" }
        if let message = validate(toggleShortcut) { return "Toggle shortcut: \(message)" }
        guard !holdShortcut.matches(toggleShortcut) else {
            return "Choose a different key for Hold and Toggle."
        }
        if shortcutsOverlapByModifier(holdShortcut, toggleShortcut) {
            return "The Toggle combination also uses the Hold modifier. Choose keys that do not overlap."
        }
        if shortcutsOverlapByModifier(toggleShortcut, holdShortcut) {
            return "The Hold combination also uses the Toggle modifier. Choose keys that do not overlap."
        }
        guard holdShortcut.keyCode != toggleShortcut.keyCode else {
            return "Hold and Toggle use the same physical key. Choose keys that do not overlap."
        }
        return nil
    }

    nonisolated static func validationMessage(
        for candidate: ShortcutConfiguration,
        mode: DictationMode,
        holdShortcut: ShortcutConfiguration,
        toggleShortcut: ShortcutConfiguration
    ) -> String? {
        if let message = validate(candidate) { return message }
        let otherMode: DictationMode = mode == .hold ? .toggle : .hold
        let other = otherMode == .hold ? holdShortcut : toggleShortcut
        let attemptedLabel = mode == .hold ? "Hold" : "Toggle"

        if candidate.matches(other) {
            return "“\(candidate.displayName)” is already used for \(otherMode.rawValue). Choose a different \(attemptedLabel) key."
        }
        if shortcutsOverlapByModifier(candidate, other)
            || shortcutsOverlapByModifier(other, candidate) {
            return "“\(candidate.displayName)” overlaps \(otherMode.rawValue) (“\(other.displayName)”). Choose a different \(attemptedLabel) key."
        }
        if candidate.keyCode == other.keyCode {
            return "“\(candidate.displayName)” uses the same physical key as \(otherMode.rawValue) (“\(other.displayName)”). Choose a different \(attemptedLabel) key."
        }
        return nil
    }

    nonisolated private static func shortcutsOverlapByModifier(
        _ modifierShortcut: ShortcutConfiguration,
        _ otherShortcut: ShortcutConfiguration
    ) -> Bool {
        guard let modifier = modifierShortcut.modifierOnlyFlag else { return false }
        return CGEventFlags(rawValue: otherShortcut.modifierFlags).contains(modifier)
    }

    nonisolated private static func validate(_ configuration: ShortcutConfiguration) -> String? {
        guard configuration.keyCode != 53 else {
            return "Escape cancels dictation and can’t be used as a talk key."
        }
        return nil
    }
}
