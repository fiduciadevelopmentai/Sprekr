import Foundation

/// Product naming and the deliberately retained identifiers that keep an
/// existing Klim Talks installation's encrypted data and macOS identity usable
/// after the visible Sprekr rebrand.
public enum SprekrIdentity {
    public static let displayName = "Sprekr"
    public static let executableName = "Sprekr"

    public enum Compatibility {
        public static let bundleIdentifier = "com.klimtalks.app"
        public static let developmentBundleIdentifier = "com.klimtalks.app.development"
        public static let keychainService = "com.klimtalks.app"
        public static let settingsKey = "com.klimtalks.app.settings"
        public static let applicationSupportDirectoryName = "Klim Talks"
        public static let legacyApplicationName = "Klim Talks"
        public static let legacyWindowFrameName = "Klim Talks Main Window"
        public static let legacySigningLabel = "Fiducia Development Klim Talks Local Source"
    }
}
