import Foundation
import SprekrCore

enum ModelDownloadPolicy {
    static func storageFailureMessage(
        availableBytes: Int64?,
        requiredBytes: Int64 = ModelManager.requiredFreeSpace
    ) -> String? {
        guard let availableBytes, availableBytes < requiredBytes else { return nil }
        return SprekrError.insufficientDiskSpace(
            required: requiredBytes,
            available: availableBytes
        ).localizedDescription
    }
}

@MainActor
final class ModelManager: ObservableObject {
    nonisolated static let modelDisplayName = "NVIDIA Parakeet TDT 0.6B v3 · INT8"
    nonisolated static let expectedDownloadBytes: Int64 = 483_000_000
    nonisolated static let requiredFreeSpace: Int64 = 1_000_000_000

    @Published private(set) var state: ModelInstallState = .checking
    @Published private(set) var lastError: String?

    private let engine = LocalParakeetEngine()

    func refresh() async {
        state = .checking
        lastError = nil
        guard await engine.installedModelExists() else {
            state = .notInstalled
            return
        }
        do {
            let preparation = try await engine.prepare()
            state = .installed(bytes: preparation.modelBytes)
        } catch {
            let message = error.localizedDescription
            state = .failed(message: message)
            lastError = message
        }
    }

    func installOrLoad() async {
        let available = Self.availableDiskSpace()
        if let message = ModelDownloadPolicy.storageFailureMessage(
            availableBytes: available
        ) {
            state = .failed(message: message)
            lastError = message
            return
        }

        state = .downloading(progress: 0, detail: "Preparing model download")
        lastError = nil
        do {
            let result = try await engine.prepare { [weak self] fraction, detail in
                Task { @MainActor in self?.state = .downloading(progress: fraction, detail: detail) }
            }
            state = .installed(bytes: result.modelBytes)
        } catch {
            let message = error.localizedDescription
            lastError = message
            state = .failed(message: message)
        }
    }

    func removeModel() async {
        await engine.unload()
        let root = LocalParakeetEngine.modelRoot
        try? FileManager.default.removeItem(at: root)
        state = .notInstalled
    }

    func validateInstalledModel() async -> Bool {
        await refresh()
        if case .installed = state { return true }
        return false
    }

    func transcribe(audioURL: URL, language: RecognitionLanguage) async throws -> TranscriptionResult {
        if case .installed = state, await engine.isPrepared() {
            return try await engine.transcribe(audioURL: audioURL, language: language.transcriptionLanguage)
        }
        await installOrLoad()
        guard case .installed = state else {
            throw NSError(domain: "Sprekr.Model", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError ?? "Model installation failed."])
        }
        return try await engine.transcribe(audioURL: audioURL, language: language.transcriptionLanguage)
    }

    static func availableDiskSpace() -> Int64? {
        var probe = LocalParakeetEngine.modelRoot
        while !FileManager.default.fileExists(atPath: probe.path),
              probe.path != probe.deletingLastPathComponent().path {
            probe.deleteLastPathComponent()
        }
        if let capacity = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: probe.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

private extension RecognitionLanguage {
    var transcriptionLanguage: TranscriptionLanguage {
        switch self {
        case .automatic: .automatic
        case .english: .english
        case .dutch: .dutch
        }
    }
}
