import ApplicationServices
import AppKit
import Foundation

enum TextInjectionResult: Equatable {
    case accessibility
    case unicodeEvents
    case clipboardPaste
    case copiedForRecovery(TextInjectionRecoveryReason)

    var wasInserted: Bool {
        switch self {
        case .accessibility, .unicodeEvents, .clipboardPaste: true
        case .copiedForRecovery: false
        }
    }

    var recoveryReason: TextInjectionRecoveryReason? {
        guard case let .copiedForRecovery(reason) = self else { return nil }
        return reason
    }
}

enum TextInjectionRecoveryReason: Equatable {
    case noEditableTarget
    case protectedOrReadOnlyTarget
    case accessibilityTreeUnavailable
    case insertionFailed
}

enum EditableTargetClassification: Equatable {
    case editable
    case protectedOrReadOnly
    case notEditable
}

struct EditableTargetEvidence: Equatable {
    let role: String?
    let subrole: String?
    let enabled: Bool?
    let selectedTextSupported: Bool
    let selectedTextSettable: Bool
    let selectedTextRangeSupported: Bool
    let selectedTextRangeSettable: Bool
    let selectedTextMarkerRangeSupported: Bool
    let selectedTextMarkerRangeSettable: Bool
    let valueSupported: Bool
    let valueSettable: Bool
    let reportedEditableAncestor: Bool

    init(
        role: String? = nil,
        subrole: String? = nil,
        enabled: Bool? = nil,
        selectedTextSupported: Bool = false,
        selectedTextSettable: Bool = false,
        selectedTextRangeSupported: Bool = false,
        selectedTextRangeSettable: Bool = false,
        selectedTextMarkerRangeSupported: Bool = false,
        selectedTextMarkerRangeSettable: Bool = false,
        valueSupported: Bool = false,
        valueSettable: Bool = false,
        reportedEditableAncestor: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.enabled = enabled
        self.selectedTextSupported = selectedTextSupported
        self.selectedTextSettable = selectedTextSettable
        self.selectedTextRangeSupported = selectedTextRangeSupported
        self.selectedTextRangeSettable = selectedTextRangeSettable
        self.selectedTextMarkerRangeSupported = selectedTextMarkerRangeSupported
        self.selectedTextMarkerRangeSettable = selectedTextMarkerRangeSettable
        self.valueSupported = valueSupported
        self.valueSettable = valueSettable
        self.reportedEditableAncestor = reportedEditableAncestor
    }
}

enum EditableTargetPolicy {
    private static let knownTextRoles = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
    ].map { $0 as String }
    private static let customTextContainerRole = kAXGroupRole as String

    static func classify(_ evidence: EditableTargetEvidence) -> EditableTargetClassification {
        if evidence.subrole == kAXSecureTextFieldSubrole as String || evidence.enabled == false {
            return .protectedOrReadOnly
        }

        if evidence.reportedEditableAncestor {
            return .editable
        }

        guard let role = evidence.role else { return .notEditable }

        // Browser engines may expose a focused contenteditable as AXGroup
        // rather than AXTextArea. A writable text selection or text range is
        // strong editing evidence; a writable AXValue by itself is not, since
        // non-text custom controls can expose the same capability.
        if role == customTextContainerRole {
            return evidence.selectedTextSettable
                || evidence.selectedTextRangeSettable
                || evidence.selectedTextMarkerRangeSettable
                ? .editable
                : .notEditable
        }

        guard knownTextRoles.contains(role) else {
            return .notEditable
        }

        if evidence.selectedTextSettable
            || evidence.selectedTextRangeSettable
            || evidence.selectedTextMarkerRangeSettable
            || evidence.valueSettable {
            return .editable
        }

        // Some native and custom editors expose only their semantic text role,
        // so retain that role as a compatibility fallback. When an element does
        // expose one or more text-mutation attributes and explicitly marks all
        // of them non-settable, however, it is a positive read-only signal.
        let exposesMutationAttribute = evidence.selectedTextSupported
            || evidence.selectedTextRangeSupported
            || evidence.selectedTextMarkerRangeSupported
            || evidence.valueSupported
        return exposesMutationAttribute ? .protectedOrReadOnly : .editable
    }
}

enum TextDeliveryVerification: Equatable {
    case changed
    case unchanged
    case indeterminate
}

enum TextDeliveryFallbackPolicy {
    static func shouldRetry(after verification: TextDeliveryVerification) -> Bool {
        verification == .unchanged
    }
}

struct DeliveryVerificationProbe: Equatable {
    let location: Int
    let length: Int
    let expectedText: String

    var range: CFRange { CFRange(location: location, length: length) }
}

enum DeliveryVerificationProbePolicy {
    static let maximumCharacterCount = 64

    static func probes(in insertionRange: CFRange, expectedText: String) -> [DeliveryVerificationProbe] {
        guard insertionRange.location >= 0, !expectedText.isEmpty else { return [] }
        let length = expectedText.utf16.count
        guard length > 0 else { return [] }

        if length <= maximumCharacterCount {
            return [DeliveryVerificationProbe(
                location: insertionRange.location,
                length: length,
                expectedText: expectedText
            )]
        }

        let edgeLength = maximumCharacterCount / 2
        guard let prefix = expectedText.utf16Substring(from: 0, length: edgeLength),
              let suffix = expectedText.utf16Substring(from: length - edgeLength, length: edgeLength)
        else { return [] }
        return [
            DeliveryVerificationProbe(
                location: insertionRange.location,
                length: edgeLength,
                expectedText: prefix
            ),
            DeliveryVerificationProbe(
                location: insertionRange.location + length - edgeLength,
                length: edgeLength,
                expectedText: suffix
            ),
        ]
    }
}

enum ClipboardRestorationPolicy {
    static let restoreDelay: TimeInterval = 0.25

    static func shouldRestore(
        temporaryText: String,
        currentText: String?
    ) -> Bool {
        currentText == temporaryText
    }
}

enum ManualAccessibilityActivationResult: Equatable {
    case enabled
    case alreadyEnabled
    case unsupported
    case failed
}

enum ManualAccessibilityPolicy {
    static let attribute = "AXManualAccessibility"
    static let retryDelaysMilliseconds = [40, 80, 160]

    static func shouldRetryTargetResolution(
        after result: ManualAccessibilityActivationResult
    ) -> Bool {
        result == .enabled || result == .alreadyEnabled
    }
}

@MainActor
protocol AccessibilityTreeClient {
    func focusedElement(in application: AXUIElement) -> AXUIElement?
    func enableManualAccessibility(in application: AXUIElement) -> AXError
    func wait(milliseconds: Int) async
}

@MainActor
struct SystemAccessibilityTreeClient: AccessibilityTreeClient {
    func focusedElement(in application: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    func enableManualAccessibility(in application: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(
            application,
            ManualAccessibilityPolicy.attribute as CFString,
            kCFBooleanTrue
        )
    }

    func wait(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

@MainActor
final class TextInjectionService {
    private struct ProcessIdentity: Hashable {
        let processIdentifier: pid_t
        let launchDate: Date?
    }

    private struct Target {
        let applicationPID: pid_t
        let element: AXUIElement
        let selectedRange: CFRange?
    }

    private enum TargetResolution {
        case editable(Target)
        case protectedOrReadOnly
        case unavailable
        case accessibilityTreeUnavailable
    }

    private enum EditableElementResolution {
        case editable(AXUIElement)
        case protectedOrReadOnly
        case notEditable
    }

    private struct DeliveryVerificationSnapshot {
        let characterCount: Int?
        let selectedRange: CFRange?

        var hasObservableState: Bool {
            characterCount != nil || selectedRange != nil
        }
    }

    private struct InsertionCandidate {
        let applicationPID: pid_t
        let element: AXUIElement
        let range: CFRange
        let originalText: String
    }

    private struct ObservationSnapshot {
        let candidate: InsertionCandidate
        let windowStart: Int
        let prefix: String
        let suffix: String
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [:]) { values, type in
                    if let data = item.data(forType: type) { values[type] = data }
                }
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            let restored: [NSPasteboardWriting] = items.compactMap { values in
                guard !values.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    private var target: Target?
    private var ownedRecoveryClipboard: (changeCount: Int, text: String)?
    private var insertionCandidate: InsertionCandidate?
    private var correctionObservationTask: Task<Void, Never>?
    private let accessibilityTreeClient: any AccessibilityTreeClient
    private var enabledAccessibilityTrees: Set<ProcessIdentity> = []
    private var unsupportedAccessibilityTrees: Set<ProcessIdentity> = []

    init(
        accessibilityTreeClient: any AccessibilityTreeClient = SystemAccessibilityTreeClient()
    ) {
        self.accessibilityTreeClient = accessibilityTreeClient
    }

    func prepareForDictation() {
        correctionObservationTask?.cancel()
        correctionObservationTask = nil
        insertionCandidate = nil
        target = nil
        activateAccessibilityTreeForCurrentAppIfNeeded()
    }

    private func currentTarget() -> TargetResolution {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unavailable }
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        return currentTarget(in: app, applicationElement: applicationElement)
    }

    private func currentTarget(
        in app: NSRunningApplication,
        applicationElement: AXUIElement
    ) -> TargetResolution {
        guard let focusedElement = accessibilityTreeClient.focusedElement(
            in: applicationElement
        ) else { return .unavailable }
        switch Self.resolveEditableElement(from: focusedElement) {
        case let .editable(element):
            return .editable(Target(
                applicationPID: app.processIdentifier,
                element: element,
                selectedRange: Self.selectedTextRange(element)
            ))
        case .protectedOrReadOnly:
            return .protectedOrReadOnly
        case .notEditable:
            return .unavailable
        }
    }

    private func activateAccessibilityTreeForCurrentAppIfNeeded() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication
        else { return }
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        guard case .unavailable = currentTarget(
            in: app,
            applicationElement: applicationElement
        ) else { return }
        _ = enableManualAccessibility(for: app, applicationElement: applicationElement)
    }

    private func resolveDeliveryTarget() async -> TargetResolution {
        var appChangeCount = 0

        appResolution: while appChangeCount < 4 {
            guard let app = NSWorkspace.shared.frontmostApplication else { return .unavailable }
            let identity = Self.processIdentity(for: app)
            let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
            let initial = currentTarget(in: app, applicationElement: applicationElement)
            switch initial {
            case .editable, .protectedOrReadOnly:
                return initial
            case .unavailable, .accessibilityTreeUnavailable:
                break
            }

            let activation = enableManualAccessibility(
                for: app,
                applicationElement: applicationElement
            )
            guard ManualAccessibilityPolicy.shouldRetryTargetResolution(after: activation) else {
                return .unavailable
            }

            for delay in ManualAccessibilityPolicy.retryDelaysMilliseconds {
                await accessibilityTreeClient.wait(milliseconds: delay)
                guard Self.currentProcessIdentity() == identity else {
                    appChangeCount += 1
                    continue appResolution
                }

                let retried = currentTarget(in: app, applicationElement: applicationElement)
                switch retried {
                case .editable, .protectedOrReadOnly:
                    return retried
                case .unavailable, .accessibilityTreeUnavailable:
                    continue
                }
            }

            return Self.exposesWebAccessibilityTree(applicationElement)
                ? .unavailable
                : .accessibilityTreeUnavailable
        }

        return .unavailable
    }

    private func enableManualAccessibility(
        for app: NSRunningApplication,
        applicationElement: AXUIElement
    ) -> ManualAccessibilityActivationResult {
        let identity = Self.processIdentity(for: app)
        if enabledAccessibilityTrees.contains(identity) { return .alreadyEnabled }
        if unsupportedAccessibilityTrees.contains(identity) { return .unsupported }

        switch accessibilityTreeClient.enableManualAccessibility(in: applicationElement) {
        case .success:
            enabledAccessibilityTrees.insert(identity)
            return .enabled
        case .attributeUnsupported, .notImplemented, .illegalArgument:
            unsupportedAccessibilityTrees.insert(identity)
            return .unsupported
        default:
            return .failed
        }
    }

    func inject(_ text: String) async -> TextInjectionResult {
        guard !text.isEmpty else { return .copiedForRecovery(.insertionFailed) }

        let deliveryTarget: Target
        switch await resolveDeliveryTarget() {
        case let .editable(candidate):
            deliveryTarget = candidate
            target = candidate
        case .protectedOrReadOnly:
            copyToClipboard(text)
            return .copiedForRecovery(.protectedOrReadOnlyTarget)
        case .unavailable:
            copyToClipboard(text)
            return .copiedForRecovery(.noEditableTarget)
        case .accessibilityTreeUnavailable:
            copyToClipboard(text)
            return .copiedForRecovery(.accessibilityTreeUnavailable)
        }

        // Several browser and SwiftUI text fields report a successful
        // AXSelectedText write without changing their visible value. A real
        // Command-V sent directly to the remembered foreground process is the
        // most consistent path across native and web editors, so prefer it.
        let currentElement = deliveryTarget.element
        let insertionRange = Self.selectedTextRange(currentElement) ?? deliveryTarget.selectedRange
        if await attemptDelivery(
            to: deliveryTarget,
            expectedText: text,
            action: { pasteWithClipboard(text, applicationPID: deliveryTarget.applicationPID) }
        ) {
            rememberInsertionCandidate(
                text: text,
                element: currentElement,
                applicationPID: deliveryTarget.applicationPID,
                selectedRange: insertionRange
            )
            return .clipboardPaste
        }
        if await attemptDelivery(
            to: deliveryTarget,
            expectedText: text,
            action: { insertWithAccessibility(text, element: currentElement) }
        ) {
            rememberInsertionCandidate(
                text: text,
                element: currentElement,
                applicationPID: deliveryTarget.applicationPID,
                selectedRange: insertionRange
            )
            return .accessibility
        }
        if await attemptDelivery(
            to: deliveryTarget,
            expectedText: text,
            action: { insertWithUnicodeEvents(text, applicationPID: deliveryTarget.applicationPID) }
        ) {
            rememberInsertionCandidate(
                text: text,
                element: currentElement,
                applicationPID: deliveryTarget.applicationPID,
                selectedRange: insertionRange
            )
            return .unicodeEvents
        }
        copyToClipboard(text)
        return .copiedForRecovery(.insertionFailed)
    }

    func observeImmediateCorrection(
        onCorrection: @escaping (ImmediateSpellingCorrection) -> Void
    ) {
        correctionObservationTask?.cancel()
        guard let insertionCandidate else { return }

        correctionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                  let snapshot = self.makeObservationSnapshot(for: insertionCandidate)
            else { return }

            var pendingCorrection: ImmediateSpellingCorrection?
            var stableReads = 0
            for _ in 0..<38 {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled,
                      self.targetIsStillFrontmost(),
                      let edited = self.readInsertedText(using: snapshot)
                else { return }

                guard let correction = ImmediateCorrectionEngine.detect(
                    original: insertionCandidate.originalText,
                    edited: edited
                ) else {
                    pendingCorrection = nil
                    stableReads = 0
                    continue
                }

                if correction == pendingCorrection {
                    stableReads += 1
                } else {
                    pendingCorrection = correction
                    stableReads = 1
                }
                guard stableReads >= 2 else { continue }
                onCorrection(correction)
                return
            }
        }
    }

    func copyForRecovery(_ text: String) {
        copyToClipboard(text)
    }

    func clearOwnedRecoveryClipboard() {
        guard let ownedRecoveryClipboard else { return }
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == ownedRecoveryClipboard.changeCount,
           pasteboard.string(forType: .string) == ownedRecoveryClipboard.text {
            pasteboard.clearContents()
        }
        self.ownedRecoveryClipboard = nil
    }

    private func rememberInsertionCandidate(
        text: String,
        element: AXUIElement,
        applicationPID: pid_t,
        selectedRange: CFRange?
    ) {
        guard let selectedRange,
              selectedRange.location >= 0,
              selectedRange.length >= 0
        else {
            insertionCandidate = nil
            return
        }
        insertionCandidate = InsertionCandidate(
            applicationPID: applicationPID,
            element: element,
            range: CFRange(
                location: selectedRange.location,
                length: text.utf16.count
            ),
            originalText: text
        )
    }

    private func makeObservationSnapshot(
        for candidate: InsertionCandidate
    ) -> ObservationSnapshot? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.applicationPID,
              let characterCount = Self.numberOfCharacters(in: candidate.element)
        else { return nil }

        let prefixLength = min(12, candidate.range.location)
        let windowStart = candidate.range.location - prefixLength
        let desiredLength = prefixLength + candidate.range.length + 18
        let availableLength = max(0, characterCount - windowStart)
        let windowLength = min(desiredLength, availableLength)
        guard windowLength >= prefixLength + candidate.range.length,
              let value = Self.string(
                in: candidate.element,
                range: CFRange(location: windowStart, length: windowLength)
              ),
              let inserted = value.utf16Substring(
                from: prefixLength,
                length: candidate.range.length
              ),
              inserted == candidate.originalText,
              let prefix = value.utf16Substring(from: 0, length: prefixLength),
              let suffix = value.utf16Substring(
                from: prefixLength + candidate.range.length,
                length: windowLength - prefixLength - candidate.range.length
              )
        else { return nil }

        return ObservationSnapshot(
            candidate: candidate,
            windowStart: windowStart,
            prefix: prefix,
            suffix: suffix
        )
    }

    private func readInsertedText(using snapshot: ObservationSnapshot) -> String? {
        guard let characterCount = Self.numberOfCharacters(in: snapshot.candidate.element) else { return nil }
        let availableLength = max(0, characterCount - snapshot.windowStart)
        let desiredLength = snapshot.prefix.utf16.count
            + snapshot.candidate.range.length
            + snapshot.suffix.utf16.count
            + 64
        guard let value = Self.string(
            in: snapshot.candidate.element,
            range: CFRange(
                location: snapshot.windowStart,
                length: min(availableLength, desiredLength)
            )
        ),
              value.hasPrefix(snapshot.prefix)
        else { return nil }

        let afterPrefix = String(value.dropFirst(snapshot.prefix.count))
        guard !snapshot.suffix.isEmpty else { return afterPrefix }
        guard let suffixRange = afterPrefix.range(of: snapshot.suffix, options: .backwards) else { return nil }
        return String(afterPrefix[..<suffixRange.lowerBound])
    }

    private func insertWithAccessibility(_ text: String, element: AXUIElement) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let selectedResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return selectedResult == .success
    }

    private func attemptDelivery(
        to target: Target,
        expectedText: String,
        action: () -> Bool
    ) async -> Bool {
        let snapshot = Self.deliveryVerificationSnapshot(for: target.element)
        guard action() else { return false }

        let verification = await verifyDelivery(
            to: target,
            against: snapshot,
            expectedText: expectedText
        )
        if !TextDeliveryFallbackPolicy.shouldRetry(after: verification) {
            // Some custom editors intentionally expose no readable value. Once
            // the real OS event was dispatched, treating that state as success
            // is safer than retrying and potentially inserting duplicate text.
            return true
        }
        return false
    }

    private func targetIsStillFrontmost() -> Bool {
        guard let target,
              case let .editable(current) = currentTarget(),
              current.applicationPID == target.applicationPID
        else { return false }
        return CFEqual(current.element, target.element)
    }

    private func verifyDelivery(
        to target: Target,
        against snapshot: DeliveryVerificationSnapshot,
        expectedText: String
    ) async -> TextDeliveryVerification {
        guard snapshot.hasObservableState else { return .indeterminate }

        // Web editors apply native paste events asynchronously. Require two
        // stable unchanged reads before declaring failure; any unreadable or
        // changing state is treated as indeterminate to avoid a duplicate retry.
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(80))
            guard targetIsStillFrontmost(target) else { return .indeterminate }
            switch Self.compareCurrentState(
                of: target.element,
                with: snapshot,
                expectedText: expectedText
            ) {
            case .changed:
                return .changed
            case .indeterminate:
                return .indeterminate
            case .unchanged:
                continue
            }
        }
        return .unchanged
    }

    private func targetIsStillFrontmost(_ expected: Target) -> Bool {
        guard case let .editable(current) = currentTarget(),
              current.applicationPID == expected.applicationPID
        else { return false }
        return CFEqual(current.element, expected.element)
    }

    private func insertWithUnicodeEvents(_ text: String, applicationPID: pid_t) -> Bool {
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let chunks = text.utf16.chunked(into: 40)
        for chunk in chunks {
            let values = Array(chunk)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: values.count, unicodeString: values)
            up.keyboardSetUnicodeString(stringLength: values.count, unicodeString: values)
            down.postToPid(applicationPID)
            up.postToPid(applicationPID)
        }
        return true
    }

    private func pasteWithClipboard(_ text: String, applicationPID: pid_t) -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        let pasteboard = NSPasteboard.general
        let original = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            original.restore(to: pasteboard)
            return false
        }
        let insertedChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            if pasteboard.changeCount == insertedChangeCount { original.restore(to: pasteboard) }
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(applicationPID)
        up.postToPid(applicationPID)

        DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardRestorationPolicy.restoreDelay) {
            // Reading the pasteboard can change its count in some destination
            // apps. Restore by ownership of the temporary text instead. If the
            // user copied anything else in the meantime, leave it untouched.
            guard ClipboardRestorationPolicy.shouldRestore(
                temporaryText: text,
                currentText: pasteboard.string(forType: .string)
            ) else { return }
            original.restore(to: pasteboard)
        }
        return true
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            ownedRecoveryClipboard = (pasteboard.changeCount, text)
        } else {
            ownedRecoveryClipboard = nil
        }
    }

    private static let editableAncestorAttributes = [
        "AXEditableAncestor",
        "AXHighestEditableAncestor",
    ]
    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let hierarchyLimit = 12
    private static let descendantDepthLimit = 8
    private static let descendantNodeLimit = 160

    private static func resolveEditableElement(from focusedElement: AXUIElement) -> EditableElementResolution {
        let directResolution = resolveEditableElementAlongAncestors(from: focusedElement)
        guard case .notEditable = directResolution else { return directResolution }

        // Some web views focus their AXWebArea or a compositor group while a
        // nested editor retains the actual AXFocused flag. Descend only through
        // bounded, explicitly focused nodes; choosing an arbitrary editable
        // descendant could paste into a field the user did not select.
        for descendant in focusedDescendants(of: focusedElement) {
            let resolution = resolveEditableElementAlongAncestors(from: descendant)
            guard case .notEditable = resolution else { return resolution }
        }
        return .notEditable
    }

    private static func resolveEditableElementAlongAncestors(
        from focusedElement: AXUIElement
    ) -> EditableElementResolution {
        if hasProtectedAncestor(startingAt: focusedElement) {
            return .protectedOrReadOnly
        }

        // Web views and rich editors may focus a static descendant or expose
        // the contenteditable root as AXGroup. Their
        // editable-ancestor attributes are stronger evidence than the role.
        for attribute in editableAncestorAttributes {
            guard let candidate = elementAttribute(attribute, of: focusedElement) else { continue }
            switch EditableTargetPolicy.classify(evidence(for: candidate, reportedEditableAncestor: true)) {
            case .editable:
                return hasProtectedAncestor(startingAt: candidate)
                    ? .protectedOrReadOnly
                    : .editable(candidate)
            case .protectedOrReadOnly:
                return .protectedOrReadOnly
            case .notEditable:
                continue
            }
        }

        var candidate: AXUIElement? = focusedElement
        for _ in 0..<hierarchyLimit {
            guard let current = candidate else { break }
            switch EditableTargetPolicy.classify(evidence(for: current, reportedEditableAncestor: false)) {
            case .editable:
                return .editable(current)
            case .protectedOrReadOnly:
                return .protectedOrReadOnly
            case .notEditable:
                break
            }

            let role = stringAttribute(kAXRoleAttribute as String, of: current)
            if role == kAXWindowRole as String || role == kAXApplicationRole as String {
                break
            }
            candidate = elementAttribute(kAXParentAttribute as String, of: current)
        }
        return .notEditable
    }

    private static func focusedDescendants(of root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue = childElements(of: root).map { ($0, 1) }
        var visited = 0

        while !queue.isEmpty, visited < descendantNodeLimit {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if boolAttribute(kAXFocusedAttribute as String, of: element) == true {
                result.append(element)
            }
            if depth < descendantDepthLimit {
                queue.append(contentsOf: childElements(of: element).map { ($0, depth + 1) })
            }
        }
        return result
    }

    private static func evidence(
        for element: AXUIElement,
        reportedEditableAncestor: Bool
    ) -> EditableTargetEvidence {
        let attributes = attributeNames(of: element)
        let selectedText = kAXSelectedTextAttribute as String
        let selectedTextRange = kAXSelectedTextRangeAttribute as String
        let value = kAXValueAttribute as String
        return EditableTargetEvidence(
            role: stringAttribute(kAXRoleAttribute as String, of: element),
            subrole: stringAttribute(kAXSubroleAttribute as String, of: element),
            enabled: boolAttribute(kAXEnabledAttribute as String, of: element),
            selectedTextSupported: attributes.contains(selectedText),
            selectedTextSettable: isAttributeSettable(selectedText, on: element),
            selectedTextRangeSupported: attributes.contains(selectedTextRange),
            selectedTextRangeSettable: isAttributeSettable(selectedTextRange, on: element),
            selectedTextMarkerRangeSupported: attributes.contains(selectedTextMarkerRangeAttribute),
            selectedTextMarkerRangeSettable: isAttributeSettable(selectedTextMarkerRangeAttribute, on: element),
            valueSupported: attributes.contains(value),
            valueSettable: isAttributeSettable(value, on: element),
            reportedEditableAncestor: reportedEditableAncestor
        )
    }

    private static func hasProtectedAncestor(startingAt element: AXUIElement) -> Bool {
        var candidate: AXUIElement? = element
        for _ in 0..<hierarchyLimit {
            guard let current = candidate else { return false }
            if stringAttribute(kAXSubroleAttribute as String, of: current)
                == kAXSecureTextFieldSubrole as String {
                return true
            }
            if boolAttribute(kAXEnabledAttribute as String, of: current) == false {
                return true
            }
            candidate = elementAttribute(kAXParentAttribute as String, of: current)
        }
        return false
    }

    private static func processIdentity(for app: NSRunningApplication) -> ProcessIdentity {
        ProcessIdentity(
            processIdentifier: app.processIdentifier,
            launchDate: app.launchDate
        )
    }

    private static func currentProcessIdentity() -> ProcessIdentity? {
        NSWorkspace.shared.frontmostApplication.map(processIdentity(for:))
    }

    private static func exposesWebAccessibilityTree(_ applicationElement: AXUIElement) -> Bool {
        var queue = childElements(of: applicationElement).map { ($0, 1) }
        var visited = 0

        while !queue.isEmpty, visited < descendantNodeLimit {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let children = childElements(of: element)
            if stringAttribute(kAXRoleAttribute as String, of: element) == "AXWebArea",
               !children.isEmpty {
                return true
            }
            if depth < descendantDepthLimit {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return false
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        let childAttributes = [
            kAXChildrenAttribute as String,
            kAXContentsAttribute as String,
            "AXChildrenInNavigationOrder",
        ]
        var result: [AXUIElement] = []
        for attribute in childAttributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success,
                  let value,
                  CFGetTypeID(value) == CFArrayGetTypeID(),
                  let children = value as? [AXUIElement]
            else { continue }
            for child in children where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }
        return result
    }

    private static func attributeNames(of element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let values = names as? [String]
        else { return [] }
        return Set(values)
    }

    private static func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let number = value as? NSNumber
        else { return nil }
        return number.boolValue
    }

    private static func deliveryVerificationSnapshot(for element: AXUIElement) -> DeliveryVerificationSnapshot {
        DeliveryVerificationSnapshot(
            characterCount: numberOfCharacters(in: element),
            selectedRange: selectedTextRange(element)
        )
    }

    private static func compareCurrentState(
        of element: AXUIElement,
        with snapshot: DeliveryVerificationSnapshot,
        expectedText: String
    ) -> TextDeliveryVerification {
        var comparedCount = false
        var comparedRange = false

        if let previousCount = snapshot.characterCount {
            guard let currentCount = numberOfCharacters(in: element) else { return .indeterminate }
            comparedCount = true
            if currentCount != previousCount { return .changed }
        }

        if let previousRange = snapshot.selectedRange {
            guard let currentRange = selectedTextRange(element) else { return .indeterminate }
            comparedRange = true
            if currentRange.location != previousRange.location
                || currentRange.length != previousRange.length {
                return .changed
            }

            let probes = DeliveryVerificationProbePolicy.probes(
                in: previousRange,
                expectedText: expectedText
            )
            if !probes.isEmpty {
                var readAnyProbe = false
                for probe in probes {
                    guard let actual = string(in: element, range: probe.range) else {
                        return .indeterminate
                    }
                    readAnyProbe = true
                    if actual != probe.expectedText {
                        return comparedCount && comparedRange ? .unchanged : .indeterminate
                    }
                }
                if readAnyProbe { return .changed }
            }
        }

        return comparedCount && comparedRange ? .unchanged : .indeterminate
    }

    private static func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func numberOfCharacters(in element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        ) == .success,
              let number = value as? NSNumber
        else { return nil }
        return number.intValue
    }

    private static func string(in element: AXUIElement, range: CFRange) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success
        else { return nil }
        return value as? String
    }
}

private extension Collection {
    func chunked(into size: Int) -> [SubSequence] {
        var result: [SubSequence] = []
        var start = startIndex
        while start != endIndex {
            let end = self.index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[start..<end])
            start = end
        }
        return result
    }
}

private extension String {
    func utf16Substring(from offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0 else { return nil }
        let units = utf16
        guard let start = units.index(units.startIndex, offsetBy: offset, limitedBy: units.endIndex),
              let end = units.index(start, offsetBy: length, limitedBy: units.endIndex),
              let startIndex = String.Index(start, within: self),
              let endIndex = String.Index(end, within: self)
        else { return nil }
        return String(self[startIndex..<endIndex])
    }
}
