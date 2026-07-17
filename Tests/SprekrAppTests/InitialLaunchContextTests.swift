import AppKit
import CoreServices
import Testing
@testable import SprekrApp

@Suite("Initial login launch context")
struct InitialLaunchContextTests {
    @Test
    func loginItemOpenApplicationEventStartsQuietly() {
        let event = openApplicationEvent()
        event.setParam(
            NSAppleEventDescriptor(enumCode: AEKeyword(keyAELaunchedAsLogInItem)),
            forKeyword: AEKeyword(keyAEPropData)
        )

        #expect(InitialLaunchContext.classify(initialAppleEvent: event) == .loginItem)
    }

    @Test
    func ordinaryOpenApplicationEventIsInteractive() {
        #expect(InitialLaunchContext.classify(initialAppleEvent: openApplicationEvent()) == .interactive)
    }

    @Test
    func loginMarkerOnAnotherEventDoesNotSuppressTheWindow() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(enumCode: AEKeyword(keyAELaunchedAsLogInItem)),
            forKeyword: AEKeyword(keyAEPropData)
        )

        #expect(InitialLaunchContext.classify(initialAppleEvent: event) == .interactive)
    }

    private func openApplicationEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }
}
