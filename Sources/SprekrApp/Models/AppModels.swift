import ApplicationServices
import Foundation

extension Calendar {
    static var sprekrAmsterdam: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current
        return calendar
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case insights = "Insights"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }
}

enum AppearanceChoice: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum DictationMode: String, Codable, CaseIterable, Identifiable {
    case hold = "Hold to talk"
    case toggle = "Toggle to talk"

    var id: String { rawValue }
}

enum RecognitionLanguage: String, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case dutch = "Dutch"
    case english = "English"

    var id: String { rawValue }

    var flowBarCode: String {
        switch self {
        case .automatic: "AUTO"
        case .dutch: "NL"
        case .english: "EN"
        }
    }

    var outputDisplayName: String {
        switch self {
        case .automatic: "Keep spoken language"
        case .dutch: "Nederlands"
        case .english: "English"
        }
    }

    var nextOutputLanguage: RecognitionLanguage {
        switch self {
        case .automatic: .dutch
        case .dutch: .english
        case .english: .automatic
        }
    }
}

enum DictionaryLanguage: String, Codable, CaseIterable, Identifiable, Hashable {
    case dutch = "Dutch"
    case english = "English"
    case both = "Both"

    var id: String { rawValue }
}

struct ShortcutConfiguration: Codable, Equatable, Hashable {
    private static let mouseButtonKeyCodeBase: UInt16 = 0xF000

    var keyCode: UInt16
    var modifierFlags: UInt64
    var displayName: String

    static let fnGlobe = ShortcutConfiguration(
        keyCode: 63,
        modifierFlags: CGEventFlags.maskSecondaryFn.rawValue,
        displayName: "Fn / Globe"
    )

    static let standard = fnGlobe

    static let optionSpace = ShortcutConfiguration(
        keyCode: 49,
        modifierFlags: CGEventFlags.maskAlternate.rawValue,
        displayName: "Option + Space"
    )

    static let controlReturn = ShortcutConfiguration(
        keyCode: 36,
        modifierFlags: CGEventFlags.maskControl.rawValue,
        displayName: "Control + Return"
    )

    static func mouseButton(_ buttonNumber: Int) -> ShortcutConfiguration {
        let safeButtonNumber = max(2, min(buttonNumber, Int(UInt16.max - mouseButtonKeyCodeBase)))
        return ShortcutConfiguration(
            keyCode: mouseButtonKeyCodeBase + UInt16(safeButtonNumber),
            modifierFlags: 0,
            displayName: "Mouse \(safeButtonNumber + 1)"
        )
    }

    var mouseButtonNumber: Int? {
        guard keyCode >= Self.mouseButtonKeyCodeBase else { return nil }
        return Int(keyCode - Self.mouseButtonKeyCodeBase)
    }

    var isMouseButton: Bool { mouseButtonNumber != nil }

    var isFnGlobe: Bool {
        keyCode == Self.fnGlobe.keyCode && modifierFlags == Self.fnGlobe.modifierFlags
    }

    var modifierOnlyFlag: CGEventFlags? {
        switch keyCode {
        case 63 where modifierFlags == CGEventFlags.maskSecondaryFn.rawValue:
            .maskSecondaryFn
        case 58 where modifierFlags == CGEventFlags.maskAlternate.rawValue,
             61 where modifierFlags == CGEventFlags.maskAlternate.rawValue:
            .maskAlternate
        case 59 where modifierFlags == CGEventFlags.maskControl.rawValue,
             62 where modifierFlags == CGEventFlags.maskControl.rawValue:
            .maskControl
        case 56 where modifierFlags == CGEventFlags.maskShift.rawValue,
             60 where modifierFlags == CGEventFlags.maskShift.rawValue:
            .maskShift
        case 54 where modifierFlags == CGEventFlags.maskCommand.rawValue,
             55 where modifierFlags == CGEventFlags.maskCommand.rawValue:
            .maskCommand
        default:
            nil
        }
    }

    func matches(_ other: ShortcutConfiguration) -> Bool {
        keyCode == other.keyCode && modifierFlags == other.modifierFlags
    }
}

enum TalkKeyPreset: String, CaseIterable, Identifiable {
    case function = "Fn / Globe"
    case optionSpace = "Option + Space"
    case controlReturn = "Control + Return"

    var id: String { rawValue }

    var configuration: ShortcutConfiguration {
        switch self {
        case .function:
            .fnGlobe
        case .optionSpace:
            .optionSpace
        case .controlReturn:
            .controlReturn
        }
    }

    static func matching(_ configuration: ShortcutConfiguration) -> TalkKeyPreset? {
        allCases.first { preset in
            preset.configuration.keyCode == configuration.keyCode
                && preset.configuration.modifierFlags == configuration.modifierFlags
        }
    }
}

struct SprekrSettings: Codable, Equatable {
    var onboardingCompleted = false
    var launchAtLogin = true
    var showFlowBar = true
    var showInDock = true
    var soundsEnabled = true
    var appearance: AppearanceChoice = .system
    var dictationMode: DictationMode = .hold
    var recognitionLanguage: RecognitionLanguage = .automatic
    var holdShortcut: ShortcutConfiguration = .fnGlobe
    var toggleShortcut: ShortcutConfiguration = .optionSpace
    var microphoneUID: String?
    var smartFormatting = true
    var learnFromCorrections = true

    var shortcut: ShortcutConfiguration {
        get { dictationMode == .hold ? holdShortcut : toggleShortcut }
        set {
            if dictationMode == .hold {
                holdShortcut = newValue
            } else {
                toggleShortcut = newValue
            }
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted
        case launchAtLogin
        case showFlowBar
        case showInDock
        case soundsEnabled
        case appearance
        case dictationMode
        case recognitionLanguage
        case shortcut
        case holdShortcut
        case toggleShortcut
        case microphoneUID
        case smartFormatting
        case learnFromCorrections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        showFlowBar = try container.decodeIfPresent(Bool.self, forKey: .showFlowBar) ?? true
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? true
        soundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? true
        appearance = try container.decodeIfPresent(AppearanceChoice.self, forKey: .appearance) ?? .system
        dictationMode = try container.decodeIfPresent(DictationMode.self, forKey: .dictationMode) ?? .hold
        recognitionLanguage = try container.decodeIfPresent(RecognitionLanguage.self, forKey: .recognitionLanguage) ?? .automatic
        let legacyShortcut = try container.decodeIfPresent(ShortcutConfiguration.self, forKey: .shortcut) ?? .standard
        let migratedAlternative = legacyShortcut.matches(.fnGlobe) ? ShortcutConfiguration.optionSpace : .fnGlobe
        if let decodedHold = try container.decodeIfPresent(ShortcutConfiguration.self, forKey: .holdShortcut),
           let decodedToggle = try container.decodeIfPresent(ShortcutConfiguration.self, forKey: .toggleShortcut) {
            holdShortcut = decodedHold
            toggleShortcut = decodedToggle
        } else if dictationMode == .hold {
            holdShortcut = legacyShortcut
            toggleShortcut = migratedAlternative
        } else {
            holdShortcut = migratedAlternative
            toggleShortcut = legacyShortcut
        }
        microphoneUID = try container.decodeIfPresent(String.self, forKey: .microphoneUID)
        smartFormatting = try container.decodeIfPresent(Bool.self, forKey: .smartFormatting) ?? true
        learnFromCorrections = try container.decodeIfPresent(Bool.self, forKey: .learnFromCorrections) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(showFlowBar, forKey: .showFlowBar)
        try container.encode(showInDock, forKey: .showInDock)
        try container.encode(soundsEnabled, forKey: .soundsEnabled)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(dictationMode, forKey: .dictationMode)
        try container.encode(recognitionLanguage, forKey: .recognitionLanguage)
        try container.encode(shortcut, forKey: .shortcut)
        try container.encode(holdShortcut, forKey: .holdShortcut)
        try container.encode(toggleShortcut, forKey: .toggleShortcut)
        try container.encodeIfPresent(microphoneUID, forKey: .microphoneUID)
        try container.encode(smartFormatting, forKey: .smartFormatting)
        try container.encode(learnFromCorrections, forKey: .learnFromCorrections)
    }
}

struct TranscriptRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    var audioDuration: TimeInterval
    var language: RecognitionLanguage
    var wasInserted: Bool
    var dictionaryFixes: Int

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = .now,
        audioDuration: TimeInterval,
        language: RecognitionLanguage,
        wasInserted: Bool,
        dictionaryFixes: Int
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.audioDuration = audioDuration
        self.language = language
        self.wasInserted = wasInserted
        self.dictionaryFixes = dictionaryFixes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration) ?? 0
        language = try container.decodeIfPresent(RecognitionLanguage.self, forKey: .language) ?? .automatic
        wasInserted = try container.decodeIfPresent(Bool.self, forKey: .wasInserted) ?? false
        dictionaryFixes = try container.decodeIfPresent(Int.self, forKey: .dictionaryFixes) ?? 0
    }
}

struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var preferredSpelling: String
    var aliases: [String]
    var language: DictionaryLanguage
    var isActive: Bool
    var createdAt: Date
    var appliedCount: Int

    init(
        id: UUID = UUID(),
        preferredSpelling: String,
        aliases: [String] = [],
        language: DictionaryLanguage = .both,
        isActive: Bool = true,
        createdAt: Date = .now,
        appliedCount: Int = 0
    ) {
        self.id = id
        self.preferredSpelling = preferredSpelling
        self.aliases = aliases
        self.language = language
        self.isActive = isActive
        self.createdAt = createdAt
        self.appliedCount = appliedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        preferredSpelling = try container.decode(String.self, forKey: .preferredSpelling)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        language = try container.decodeIfPresent(DictionaryLanguage.self, forKey: .language) ?? .both
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        appliedCount = try container.decodeIfPresent(Int.self, forKey: .appliedCount) ?? 0
    }
}

struct SpokenWordObservation: Identifiable, Equatable {
    let id: String
    let spelling: String
    let occurrenceCount: Int
    let lastUsedAt: Date
    let language: DictionaryLanguage
    let isLikelyNameOrBrand: Bool
}

enum FlowBarState: Equatable {
    case idle
    case listening
    case transcribing
    case undo(deadline: Date)
    case success
    case recovery(message: String, deadline: Date)
    case error(message: String, deadline: Date)
}

enum ModelInstallState: Equatable {
    case notInstalled
    case checking
    case preparing(detail: String)
    case downloading(progress: Double, detail: String)
    case installed(bytes: Int64)
    case failed(message: String)
}

struct InsightSummary: Equatable {
    let totalWords: Int
    let averageWordsPerMinute: Int
    let currentStreak: Int
    let longestStreak: Int
    let dictionaryFixes: Int
    let activeDays: Set<Date>
}

enum SprekrError: LocalizedError {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case noMicrophonePermission
    case audioCaptureUnavailable
    case noSpeechDetected
    case invalidShortcut

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            "Download failed. Your Mac doesn’t have enough free storage. Free at least 1 GB and try again."
        case .noMicrophonePermission:
            "Microphone access is needed to start dictation."
        case .audioCaptureUnavailable:
            "The selected microphone is not available."
        case .noSpeechDetected:
            "No speech was detected. Nothing was copied."
        case .invalidShortcut:
            "Choose a key and at least one modifier for the global shortcut."
        }
    }
}
