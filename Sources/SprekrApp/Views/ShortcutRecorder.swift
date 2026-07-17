import AppKit
import SwiftUI

struct ShortcutRecorderState {
    private(set) var isRecording = false
    private(set) var pendingModifierConfiguration: ShortcutConfiguration?

    mutating func begin() {
        pendingModifierConfiguration = nil
        isRecording = true
    }

    mutating func cancel() {
        pendingModifierConfiguration = nil
        isRecording = false
    }

    mutating func accept(_ configuration: ShortcutConfiguration) {
        pendingModifierConfiguration = nil
        isRecording = false
    }

    mutating func modifierChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> ShortcutConfiguration? {
        guard isRecording,
              let candidate = Self.modifierOnlyConfiguration(for: keyCode)
        else { return nil }

        if Self.modifierIsPressed(candidate, in: flags) {
            pendingModifierConfiguration = candidate
            return nil
        }
        guard pendingModifierConfiguration?.matches(candidate) == true else { return nil }
        pendingModifierConfiguration = nil
        return candidate
    }

    func displayText(committed configuration: ShortcutConfiguration) -> String {
        guard isRecording else { return configuration.displayName }
        return pendingModifierConfiguration?.displayName ?? "Press a key or mouse button"
    }

    static func modifierOnlyConfiguration(for keyCode: UInt16) -> ShortcutConfiguration? {
        switch keyCode {
        case 63:
            .fnGlobe
        case 58:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskAlternate.rawValue,
                displayName: "Option"
            )
        case 61:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskAlternate.rawValue,
                displayName: "Right Option"
            )
        case 59:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskControl.rawValue,
                displayName: "Control"
            )
        case 62:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskControl.rawValue,
                displayName: "Right Control"
            )
        case 56:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskShift.rawValue,
                displayName: "Shift"
            )
        case 60:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskShift.rawValue,
                displayName: "Right Shift"
            )
        case 55:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskCommand.rawValue,
                displayName: "Command"
            )
        case 54:
            ShortcutConfiguration(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskCommand.rawValue,
                displayName: "Right Command"
            )
        default:
            nil
        }
    }

    static func modifierIsPressed(
        _ configuration: ShortcutConfiguration,
        in flags: NSEvent.ModifierFlags
    ) -> Bool {
        guard let modifier = configuration.modifierOnlyFlag else { return false }
        return switch modifier {
        case .maskSecondaryFn:
            flags.contains(.function)
        case .maskAlternate:
            flags.contains(.option)
        case .maskControl:
            flags.contains(.control)
        case .maskShift:
            flags.contains(.shift)
        case .maskCommand:
            flags.contains(.command)
        default:
            false
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let configuration: ShortcutConfiguration
    @Binding var isRecording: Bool
    let onRecord: (ShortcutConfiguration) -> Bool

    func makeNSView(context: Context) -> ShortcutRecordingView {
        let view = ShortcutRecordingView()
        let recordingBinding = _isRecording
        view.configuration = configuration
        view.syncRecording(isRecording)
        view.onRecord = onRecord
        view.onRecordingChange = { newValue in
            if recordingBinding.wrappedValue != newValue {
                recordingBinding.wrappedValue = newValue
            }
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecordingView, context: Context) {
        let recordingBinding = _isRecording
        view.onRecord = onRecord
        view.onRecordingChange = { newValue in
            if recordingBinding.wrappedValue != newValue {
                recordingBinding.wrappedValue = newValue
            }
        }
        view.syncRecording(isRecording)
        if !view.isActivelyRecording { view.configuration = configuration }
    }
}

final class ShortcutRecordingView: NSView {
    var configuration: ShortcutConfiguration { didSet { needsDisplay = true } }
    var onRecord: ((ShortcutConfiguration) -> Bool)?
    var onRecordingChange: ((Bool) -> Void)?
    private var recorderState = ShortcutRecorderState()
    private var mouseMonitor: Any?

    var isActivelyRecording: Bool { recorderState.isRecording }

    override init(frame frameRect: NSRect = .zero) {
        configuration = .standard
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Click, then press a key, key combination, or mouse side button."
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 68) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            endRecording(notify: true, releaseFocus: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        recorderState.isRecording ? cancelRecording() : beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard recorderState.isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            cancelRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let value = ShortcutConfiguration(
            keyCode: event.keyCode,
            modifierFlags: cgFlags(from: modifiers).rawValue,
            displayName: displayName(for: event, modifiers: modifiers)
        )
        finishRecording(with: value)
    }

    override func flagsChanged(with event: NSEvent) {
        guard recorderState.isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let value = recorderState.modifierChanged(
            keyCode: event.keyCode,
            flags: event.modifierFlags
        )
        needsDisplay = true
        if let value { finishRecording(with: value) }
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder { needsDisplay = true }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        if recorderState.isRecording {
            endRecording(notify: true, releaseFocus: false)
        }
        let didResignFirstResponder = super.resignFirstResponder()
        needsDisplay = true
        return didResignFirstResponder
    }

    func syncRecording(_ value: Bool) {
        guard recorderState.isRecording != value else { return }
        if value {
            recorderState.begin()
            installMouseMonitor()
        } else {
            endRecording(notify: false, releaseFocus: true)
        }
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Shortcut recorder" }
    override func accessibilityValue() -> Any? {
        recorderState.displayText(committed: configuration)
    }
    override func accessibilityHelp() -> String? {
        recorderState.isRecording
            ? "Press a key, key combination, or mouse side button. Escape cancels."
            : "Press to record a new shortcut."
    }

    override func accessibilityPerformPress() -> Bool {
        recorderState.isRecording ? cancelRecording() : beginRecording()
        return true
    }

    private func beginRecording() {
        recorderState.begin()
        installMouseMonitor()
        needsDisplay = true
        onRecordingChange?(true)
        window?.makeFirstResponder(self)
    }

    private func cancelRecording() {
        guard recorderState.isRecording else { return }
        endRecording(notify: true, releaseFocus: true)
    }

    private func finishRecording(with value: ShortcutConfiguration) {
        let committedConfiguration = configuration
        recorderState.accept(value)
        removeMouseMonitor()
        needsDisplay = true
        onRecordingChange?(false)
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
        configuration = onRecord?(value) == true ? value : committedConfiguration
    }

    private func endRecording(notify: Bool, releaseFocus: Bool) {
        let wasRecording = recorderState.isRecording
        recorderState.cancel()
        removeMouseMonitor()
        needsDisplay = true
        if notify, wasRecording { onRecordingChange?(false) }
        if releaseFocus, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let fill = NSColor.controlBackgroundColor
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        let isFocused = recorderState.isRecording || window?.firstResponder === self
        (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).stroke()

        let text = recorderState.displayText(committed: configuration)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )

        if !recorderState.isRecording,
           let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Choose key") {
            let symbol = pencil.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? pencil
            let iconSize = NSSize(width: 16, height: 16)
            symbol.draw(
                in: NSRect(
                    x: bounds.maxX - 29,
                    y: (bounds.height - iconSize.height) / 2,
                    width: iconSize.width,
                    height: iconSize.height
                )
            )
        }
    }

    private func cgFlags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    private func displayName(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "Control " }
        if modifiers.contains(.option) { text += "Option " }
        if modifiers.contains(.shift) { text += "Shift " }
        if modifiers.contains(.command) { text += "Command " }
        return text + keyName(for: event)
    }

    private func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Forward Delete"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "Left Arrow"
        case 124: return "Right Arrow"
        case 125: return "Down Arrow"
        case 126: return "Up Arrow"
        default:
            let characters = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if let characters, !characters.isEmpty { return characters }
            return "Key \(event.keyCode)"
        }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            guard let self, self.recorderState.isRecording else { return event }
            finishRecording(with: .mouseButton(event.buttonNumber))
            return nil
        }
    }

    private func removeMouseMonitor() {
        guard let mouseMonitor else { return }
        NSEvent.removeMonitor(mouseMonitor)
        self.mouseMonitor = nil
    }

}
