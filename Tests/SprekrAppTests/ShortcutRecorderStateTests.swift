import AppKit
import Testing
@testable import SprekrApp

@Suite("Shortcut recorder state")
struct ShortcutRecorderStateTests {
    @Test func modifierOnlyKeysAppearOnPressAndCommitOnRelease() {
        let cases: [(UInt16, NSEvent.ModifierFlags, String)] = [
            (59, .control, "Control"),
            (58, .option, "Option"),
            (63, .function, "Fn / Globe"),
        ]

        for (keyCode, flags, expectedName) in cases {
            var state = ShortcutRecorderState()
            state.begin()

            #expect(state.modifierChanged(keyCode: keyCode, flags: flags) == nil)
            #expect(state.displayText(committed: .optionSpace) == expectedName)

            let recorded = state.modifierChanged(keyCode: keyCode, flags: [])
            #expect(recorded?.displayName == expectedName)
            if let recorded { state.accept(recorded) }
            #expect(state.displayText(committed: recorded ?? .optionSpace) == expectedName)
        }
    }

    @Test func escapeStyleCancellationKeepsTheCommittedShortcut() {
        var state = ShortcutRecorderState()
        state.begin()
        _ = state.modifierChanged(keyCode: 59, flags: .control)

        state.cancel()

        #expect(!state.isRecording)
        #expect(state.pendingModifierConfiguration == nil)
        #expect(state.displayText(committed: .optionSpace) == "Option + Space")
    }

    @Test func keyboardAndMouseChoicesReplaceTheDisplayImmediately() {
        var state = ShortcutRecorderState()
        let plainK = ShortcutConfiguration(keyCode: 40, modifierFlags: 0, displayName: "K")

        state.begin()
        state.accept(plainK)
        #expect(state.displayText(committed: plainK) == "K")

        let mouseFive = ShortcutConfiguration.mouseButton(4)
        state.begin()
        state.accept(mouseFive)
        #expect(state.displayText(committed: mouseFive) == "Mouse 5")
    }

    @Test func aRapidSecondRecordingDoesNotRestoreTheFirstCandidate() {
        var state = ShortcutRecorderState()
        state.begin()
        _ = state.modifierChanged(keyCode: 59, flags: .control)
        let control = state.modifierChanged(keyCode: 59, flags: [])!
        state.accept(control)

        state.begin()
        _ = state.modifierChanged(keyCode: 58, flags: .option)
        #expect(state.displayText(committed: control) == "Option")
        let option = state.modifierChanged(keyCode: 58, flags: [])!
        state.accept(option)

        #expect(state.displayText(committed: option) == "Option")
    }
}
