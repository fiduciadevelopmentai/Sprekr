import AppKit
import CoreServices
import Foundation

/// The presentation policy for the first process launch only.
///
/// `SMAppService.mainApp` launches the main application at login. AppKit
/// exposes that fact on its initial `kAEOpenApplication` Apple event through
/// `keyAEPropData == keyAELaunchedAsLogInItem`. This intentionally describes
/// how the process was launched, rather than whether launch-at-login is
/// currently enabled in System Settings.
enum InitialLaunchContext: Equatable {
    case interactive
    case loginItem

    var startsQuietly: Bool { self == .loginItem }

    static func classify(initialAppleEvent event: NSAppleEventDescriptor?) -> InitialLaunchContext {
        guard event?.eventClass == AEEventClass(kCoreEventClass),
              event?.eventID == AEEventID(kAEOpenApplication),
              event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == AEKeyword(keyAELaunchedAsLogInItem) else {
            return .interactive
        }
        return .loginItem
    }
}
