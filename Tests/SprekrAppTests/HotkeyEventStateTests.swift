import ApplicationServices
import Testing
@testable import SprekrApp

@Suite
struct HotkeyEventStateTests {
    private let shortcut = ShortcutConfiguration(
        keyCode: 49,
        modifierFlags: CGEventFlags.maskAlternate.rawValue,
        displayName: "Option Space"
    )
    private let fnGlobeShortcut = ShortcutConfiguration.fnGlobe

    @Test
    func holdStopsWhenModifierIsReleasedBeforeShortcutKey() {
        let state = configuredState(mode: .hold)

        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .start)

        // A user can release Option before Space. The Space key-up must still
        // end hold-to-talk and leave the next press usable.
        #expect(state.process(type: .keyUp, event: keyEvent(49, down: false, flags: [])) == .stop)
        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .start)
    }

    @Test
    func toggleStartsThenStopsOnTheNextPress() {
        let state = configuredState(mode: .toggle)

        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .start)
        #expect(state.process(type: .keyUp, event: keyEvent(49, down: false, flags: [])) == .swallow)

        state.setDictationActive(true)
        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .stop)
        #expect(state.process(type: .keyUp, event: keyEvent(49, down: false, flags: [])) == .swallow)
    }

    @Test
    func escapeCancelsOnlyAnActiveDictation() {
        let state = configuredState(mode: .hold)
        let escape = keyEvent(53, down: true, flags: [])

        #expect(state.process(type: .keyDown, event: escape) == .pass)

        state.setDictationActive(true)
        #expect(state.process(type: .keyDown, event: escape) == .cancel)
    }

    @Test
    func resetAfterStopOrWakeAllowsAFreshHoldPress() {
        let state = configuredState(mode: .hold)

        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .start)
        state.resetTransientState()

        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .start)
    }

    @Test
    func repeatedHoldKeyDownIsSwallowedRatherThanStartingTwice() {
        let state = configuredState(mode: .hold)

        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .start)
        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .swallow)
    }

    @Test
    func fnGlobeHoldStartsOnFlagsChangedAndStopsOnRelease() {
        let state = configuredState(shortcut: fnGlobeShortcut, mode: .hold)

        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: true, flags: .maskSecondaryFn)) == .start)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: false, flags: [])) == .stop)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: false, flags: [])) == .pass)
    }

    @Test
    func fnGlobeToggleStartsAndStopsOnlyOnPresses() {
        let state = configuredState(shortcut: fnGlobeShortcut, mode: .toggle)

        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: true, flags: .maskSecondaryFn)) == .start)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: false, flags: [])) == .swallow)

        state.setDictationActive(true)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: true, flags: .maskSecondaryFn)) == .stop)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: false, flags: [])) == .swallow)
    }

    @Test
    func fnGlobeLeavesOtherModifierAndKeyboardEventsUntouched() {
        let state = configuredState(shortcut: fnGlobeShortcut, mode: .hold)

        #expect(state.process(type: .flagsChanged, event: keyEvent(56, down: true, flags: .maskShift)) == .pass)
        #expect(state.process(type: .keyDown, event: keyEvent(63, down: true, flags: .maskSecondaryFn)) == .pass)
        #expect(state.process(type: .keyDown, event: keyEvent(0, down: true, flags: .maskSecondaryFn)) == .pass)
    }

    @Test
    func independentHoldAndToggleKeysRemainAvailableTogether() {
        let optionOnly = ShortcutConfiguration(
            keyCode: 58,
            modifierFlags: CGEventFlags.maskAlternate.rawValue,
            displayName: "Option"
        )
        let state = HotkeyEventState()
        state.configure(holdShortcut: .fnGlobe, toggleShortcut: optionOnly)

        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: true, flags: .maskSecondaryFn)) == .start)
        state.setDictationActive(true)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: false, flags: [])) == .stop)

        state.setDictationActive(false)
        #expect(state.process(type: .flagsChanged, event: keyEvent(58, down: true, flags: .maskAlternate)) == .start)
        #expect(state.process(type: .flagsChanged, event: keyEvent(58, down: false, flags: [])) == .swallow)
        state.setDictationActive(true)
        #expect(state.process(type: .flagsChanged, event: keyEvent(58, down: true, flags: .maskAlternate)) == .stop)
    }

    @Test
    func holdKeyDoesNotTakeOverAToggleStartedRecording() {
        let state = HotkeyEventState()
        state.configure(holdShortcut: .fnGlobe, toggleShortcut: .optionSpace)

        #expect(state.process(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate)) == .start)
        state.setDictationActive(true)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: true, flags: .maskSecondaryFn)) == .swallow)
        #expect(state.process(type: .flagsChanged, event: keyEvent(63, down: false, flags: [])) == .swallow)
    }

    @Test
    func unmodifiedKeyboardKeyCanDriveHoldToTalk() {
        let plainK = ShortcutConfiguration(keyCode: 40, modifierFlags: 0, displayName: "K")
        let state = configuredState(shortcut: plainK, mode: .hold)

        #expect(state.process(type: .keyDown, event: keyEvent(40, down: true, flags: [])) == .start)
        #expect(state.process(type: .keyUp, event: keyEvent(40, down: false, flags: [])) == .stop)
    }

    @Test
    func mouseFiveCanDriveHoldToTalk() {
        let state = configuredState(shortcut: .mouseButton(4), mode: .hold)

        #expect(state.process(type: .otherMouseDown, event: mouseEvent(buttonNumber: 4)) == .start)
        #expect(state.process(type: .otherMouseUp, event: mouseEvent(buttonNumber: 4)) == .stop)
    }

    @Test
    func mouseFourCanToggleWithoutTakingOverOtherMouseButtons() {
        let state = configuredState(shortcut: .mouseButton(3), mode: .toggle)

        #expect(state.process(type: .otherMouseDown, event: mouseEvent(buttonNumber: 4)) == .pass)
        #expect(state.process(type: .otherMouseDown, event: mouseEvent(buttonNumber: 3)) == .start)
        #expect(state.process(type: .otherMouseUp, event: mouseEvent(buttonNumber: 3)) == .swallow)

        state.setDictationActive(true)
        #expect(state.process(type: .otherMouseDown, event: mouseEvent(buttonNumber: 3)) == .stop)
    }

    @Test
    func mouseShortcutKeepsItsStableStoredRepresentation() {
        let mouseFive = ShortcutConfiguration.mouseButton(4)

        #expect(mouseFive.mouseButtonNumber == 4)
        #expect(mouseFive.displayName == "Mouse 5")
        #expect(mouseFive.isMouseButton)
        #expect(mouseFive.modifierFlags == 0)
    }

    @Test
    func shortcutCapturePassesEventsWithoutTriggeringDictation() {
        let command = ShortcutConfiguration(
            keyCode: 55,
            modifierFlags: CGEventFlags.maskCommand.rawValue,
            displayName: "Command"
        )
        let state = HotkeyEventState()
        state.configure(holdShortcut: command, toggleShortcut: .mouseButton(4))
        state.setDictationActive(true)
        state.setShortcutCaptureActive(true)

        #expect(state.process(
            type: .flagsChanged,
            event: keyEvent(55, down: true, flags: .maskCommand)
        ) == .pass)
        #expect(state.process(
            type: .flagsChanged,
            event: keyEvent(55, down: false, flags: [])
        ) == .pass)
        #expect(state.process(type: .otherMouseDown, event: mouseEvent(buttonNumber: 4)) == .pass)
        #expect(state.process(type: .keyDown, event: keyEvent(53, down: true, flags: [])) == .pass)

        state.setShortcutCaptureActive(false)
        state.setDictationActive(false)
        #expect(state.process(
            type: .flagsChanged,
            event: keyEvent(55, down: true, flags: .maskCommand)
        ) == .start)
    }

    @Test
    func shortcutValidationRejectsExactModifierAndPhysicalKeyConflicts() {
        let command = ShortcutConfiguration(
            keyCode: 55,
            modifierFlags: CGEventFlags.maskCommand.rawValue,
            displayName: "Command"
        )
        let commandSpace = ShortcutConfiguration(
            keyCode: 49,
            modifierFlags: CGEventFlags.maskCommand.rawValue,
            displayName: "Command + Space"
        )
        let controlSpace = ShortcutConfiguration(
            keyCode: 49,
            modifierFlags: CGEventFlags.maskControl.rawValue,
            displayName: "Control + Space"
        )

        let exact = HotkeyManager.validationMessage(
            for: command,
            mode: .toggle,
            holdShortcut: command,
            toggleShortcut: .optionSpace
        )
        #expect(exact == "“Command” is already used for Hold to talk. Choose a different Toggle key.")

        let modifier = HotkeyManager.validationMessage(
            for: commandSpace,
            mode: .toggle,
            holdShortcut: command,
            toggleShortcut: .optionSpace
        )
        #expect(modifier?.contains("overlaps Hold to talk") == true)

        let physicalKey = HotkeyManager.validationMessage(
            for: controlSpace,
            mode: .toggle,
            holdShortcut: .optionSpace,
            toggleShortcut: .controlReturn
        )
        #expect(physicalKey?.contains("same physical key") == true)

        #expect(HotkeyManager.validationMessage(
            for: .controlReturn,
            mode: .toggle,
            holdShortcut: .fnGlobe,
            toggleShortcut: .optionSpace
        ) == nil)
    }

    private func configuredState(
        shortcut: ShortcutConfiguration? = nil,
        mode: DictationMode
    ) -> HotkeyEventState {
        let state = HotkeyEventState()
        state.configure(shortcut: shortcut ?? self.shortcut, mode: mode)
        return state
    }

    private func keyEvent(_ keyCode: UInt16, down: Bool, flags: CGEventFlags) -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: down
        ) else {
            fatalError("Unable to create a synthetic keyboard event for the test.")
        }
        event.flags = flags
        return event
    }

    private func mouseEvent(buttonNumber: Int) -> CGEvent {
        guard let button = CGMouseButton(rawValue: UInt32(buttonNumber)),
              let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: button
              ) else {
            fatalError("Unable to create a synthetic mouse event for the test.")
        }
        return event
    }
}
