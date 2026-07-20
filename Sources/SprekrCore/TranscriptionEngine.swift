import AVFoundation
import Foundation
@preconcurrency import FluidAudio

public enum TranscriptionLanguage: String, Sendable, CaseIterable {
    case automatic
    case english
    case dutch

    fileprivate var fluidAudioLanguage: Language? {
        switch self {
        case .automatic: nil
        case .english: .english
        case .dutch: .dutch
        }
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let audioDuration: TimeInterval
    public let transcriptionDuration: TimeInterval

    public init(text: String, audioDuration: TimeInterval, transcriptionDuration: TimeInterval) {
        self.text = text
        self.audioDuration = audioDuration
        self.transcriptionDuration = transcriptionDuration
    }
}

public struct ModelPreparation: Sendable, Equatable {
    public let modelBytes: Int64
    public let preparationDuration: TimeInterval
    public let usedExistingModel: Bool

    public init(modelBytes: Int64, preparationDuration: TimeInterval, usedExistingModel: Bool) {
        self.modelBytes = modelBytes
        self.preparationDuration = preparationDuration
        self.usedExistingModel = usedExistingModel
    }
}

public enum ModelPreparationProgress: Sendable, Equatable {
    case downloading(fraction: Double, currentFile: Int, totalFiles: Int)
    case verifying
    case loading
}

public protocol TranscriptionEngine: Sendable {
    func prepare() async throws -> ModelPreparation
    func transcribe(audioURL: URL, language: TranscriptionLanguage) async throws -> TranscriptionResult
}

public enum TranscriptionEngineError: LocalizedError, Sendable {
    case modelNotPrepared

    public var errorDescription: String? {
        switch self {
        case .modelNotPrepared:
            "The local speech model has not been prepared."
        }
    }
}

/// The sole FluidAudio boundary. App views depend on `TranscriptionEngine` instead.
public actor LocalParakeetEngine: TranscriptionEngine {
    public static let modelRoot: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(
            SprekrIdentity.Compatibility.applicationSupportDirectoryName,
            isDirectory: true
        )
        .appendingPathComponent("Models", isDirectory: true)

    private let modelRoot: URL
    private let loaderDirectory: URL
    private var manager: AsrManager?
    private var networkAllowed = true

    public init(modelRoot: URL = LocalParakeetEngine.modelRoot) {
        self.modelRoot = modelRoot
        // FluidAudio stores its repository beside the supplied loader directory.
        // Keeping this one level down preserves the legacy data root so an
        // existing verified model remains available after the Sprekr rebrand.
        self.loaderDirectory = modelRoot.appendingPathComponent("runtime-v3-int8", isDirectory: true)
    }

    public func setOfflineModeForTesting(_ enabled: Bool) {
        networkAllowed = !enabled
        ModelHub.offlineMode = true
    }

    public func installedModelExists() -> Bool {
        guard let manifest = try? PinnedModelManifest.bundled() else { return false }
        return PinnedModelInstaller.containsExpectedLayout(at: modelRoot, manifest: manifest)
    }

    public func isPrepared() -> Bool {
        manager != nil
    }

    public func prepare() async throws -> ModelPreparation {
        try await prepare(progress: nil)
    }

    public func prepare(
        progress: (@Sendable (ModelPreparationProgress) -> Void)?
    ) async throws -> ModelPreparation {
        try await prepare(allowNetwork: networkAllowed, progress: progress)
    }

    public func prepare(
        allowNetwork: Bool,
        progress: (@Sendable (ModelPreparationProgress) -> Void)?
    ) async throws -> ModelPreparation {
        let startedAt = Date()
        let manifest = try PinnedModelManifest.bundled()
        let installer = PinnedModelInstaller(modelRoot: modelRoot, manifest: manifest)
        let usedExistingModel = try await installer.ensureInstalled(
            allowNetwork: allowNetwork,
            progress: progress
        )

        // FluidAudio remains the inference and Core ML loading boundary, but
        // all of its network paths are disabled after Sprekr has verified
        // every byte against the bundled, commit-pinned manifest.
        ModelHub.offlineMode = true
        progress?(.loading)
        let models = try await AsrModels.load(
            from: loaderDirectory,
            version: .v3,
            encoderPrecision: .int8
        )
        manager = AsrManager(config: .default, models: models)

        return ModelPreparation(
            modelBytes: Self.recursiveByteCount(at: modelRoot),
            preparationDuration: Date().timeIntervalSince(startedAt),
            usedExistingModel: usedExistingModel
        )
    }

    public func transcribe(
        audioURL: URL,
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        guard let manager else { throw TranscriptionEngineError.modelNotPrepared }

        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let startedAt = Date()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: language.fluidAudioLanguage
        )

        return TranscriptionResult(
            text: result.text,
            audioDuration: audioDuration,
            transcriptionDuration: Date().timeIntervalSince(startedAt)
        )
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    private nonisolated static func recursiveByteCount(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

/// Test-only and preview-safe engine proving the runtime can be swapped.
public actor FakeTranscriptionEngine: TranscriptionEngine {
    private let result: TranscriptionResult

    public init(result: TranscriptionResult = .init(
        text: "A local test transcript.",
        audioDuration: 1,
        transcriptionDuration: 0
    )) {
        self.result = result
    }

    public func prepare() async throws -> ModelPreparation {
        ModelPreparation(modelBytes: 0, preparationDuration: 0, usedExistingModel: true)
    }

    public func transcribe(
        audioURL: URL,
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        result
    }
}
