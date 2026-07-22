import CryptoKit
import Foundation

struct PinnedModelManifest: Codable, Equatable, Sendable {
    struct FileEntry: Codable, Equatable, Sendable {
        let path: String
        let byteCount: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let repository: String
    let revision: String
    let license: String
    let localDirectory: String
    let files: [FileEntry]

    static func bundled() throws -> Self {
        guard let url = Bundle.module.url(
            forResource: "ParakeetV3ModelManifest",
            withExtension: "json"
        ) else {
            throw PinnedModelError.invalidManifest("The bundled model manifest is missing.")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    var totalByteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    func downloadURL(for entry: FileEntry) throws -> URL {
        try validate(entry: entry)
        guard let url = URL(
            string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(entry.path)"
        ), url.scheme == "https", url.host == "huggingface.co" else {
            throw PinnedModelError.invalidManifest("A pinned model URL is invalid.")
        }
        return url
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw PinnedModelError.invalidManifest("Unsupported schema version.")
        }
        guard repository == "FluidInference/parakeet-tdt-0.6b-v3-coreml",
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              license == "CC-BY-4.0",
              localDirectory == "parakeet-tdt-0.6b-v3",
              !files.isEmpty else {
            throw PinnedModelError.invalidManifest("Repository metadata is not pinned correctly.")
        }

        var paths = Set<String>()
        for entry in files {
            try validate(entry: entry)
            guard paths.insert(entry.path).inserted else {
                throw PinnedModelError.invalidManifest("Duplicate path: \(entry.path)")
            }
        }
    }

    private func validate(entry: FileEntry) throws {
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !entry.path.hasPrefix("/"),
              !entry.path.hasSuffix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              entry.path.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil,
              entry.byteCount >= 0,
              entry.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw PinnedModelError.invalidManifest("Unsafe model entry: \(entry.path)")
        }
    }
}

enum PinnedModelError: LocalizedError, Sendable {
    case invalidManifest(String)
    case offlineAndMissing
    case invalidResponse(String, Int)
    case invalidResumeResponse(String)
    case unexpectedFile(String)
    case invalidSize(String, expected: Int64, actual: Int64)
    case invalidHash(String)
    case integrityCheckFailed

    var errorDescription: String? {
        switch self {
        case let .invalidManifest(reason):
            "The bundled speech-model manifest is invalid: \(reason)"
        case .offlineAndMissing:
            "The pinned speech model is unavailable while network access is disabled."
        case let .invalidResponse(path, status):
            "The pinned model server returned HTTP \(status) for \(path)."
        case let .invalidResumeResponse(path):
            "The pinned model server returned an invalid resume response for \(path)."
        case let .unexpectedFile(path):
            "The model cache contains an unverified file: \(path)."
        case let .invalidSize(path, expected, actual):
            "The model file \(path) has \(actual) bytes; \(expected) were expected."
        case let .invalidHash(path):
            "The cryptographic check failed for model file \(path)."
        case .integrityCheckFailed:
            "The pinned speech model failed its integrity check after one safe retry."
        }
    }
}

struct ModelDownloadResponse: @unchecked Sendable {
    let temporaryFile: URL
    let statusCode: Int
    let contentRange: String?
    let removeTemporaryFileAfterUse: Bool

    init(
        temporaryFile: URL,
        statusCode: Int,
        contentRange: String?,
        removeTemporaryFileAfterUse: Bool = false
    ) {
        self.temporaryFile = temporaryFile
        self.statusCode = statusCode
        self.contentRange = contentRange
        self.removeTemporaryFileAfterUse = removeTemporaryFileAfterUse
    }
}

struct ModelDownloadTransferProgress: Equatable, Sendable {
    let bytesReceived: Int64
    let statusCode: Int?
}

protocol ModelFileFetching: Sendable {
    func download(
        _ request: URLRequest,
        progress: (@Sendable (ModelDownloadTransferProgress) -> Void)?
    ) async throws -> ModelDownloadResponse
}

private final class HTTPSOnlySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

final class EphemeralModelFileFetcher: ModelFileFetching, @unchecked Sendable {
    private let delegate: HTTPSOnlySessionDelegate
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        delegate = HTTPSOnlySessionDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func download(
        _ request: URLRequest,
        progress: (@Sendable (ModelDownloadTransferProgress) -> Void)?
    ) async throws -> ModelDownloadResponse {
        let taskReference = ModelDownloadTaskReference()
        let progressTask: Task<Void, Never>? = if let progress {
            Task.detached(priority: .utility) {
                while true {
                    let snapshot = taskReference.snapshot()
                    progress(ModelDownloadTransferProgress(
                        bytesReceived: snapshot.bytesReceived,
                        statusCode: snapshot.statusCode
                    ))
                    if snapshot.isFinished { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else {
            nil
        }

        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<ModelDownloadResponse, Error>) in
                    let task = session.downloadTask(with: request) { temporaryFile, response, error in
                        if let error {
                            if (error as? URLError)?.code == .cancelled {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        guard let temporaryFile,
                              let response = response as? HTTPURLResponse else {
                            continuation.resume(throwing: PinnedModelError.invalidResponse(
                                request.url?.lastPathComponent ?? "model file",
                                -1
                            ))
                            return
                        }

                        let retainedFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                            "sprekr-model-download-\(UUID().uuidString).tmp"
                        )
                        do {
                            try FileManager.default.copyItem(at: temporaryFile, to: retainedFile)
                            try FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: retainedFile.path
                            )
                            continuation.resume(returning: ModelDownloadResponse(
                                temporaryFile: retainedFile,
                                statusCode: response.statusCode,
                                contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                                removeTemporaryFileAfterUse: true
                            ))
                        } catch {
                            try? FileManager.default.removeItem(at: retainedFile)
                            continuation.resume(throwing: error)
                        }
                    }
                    taskReference.install(task)
                    task.resume()
                }
            } onCancel: {
                taskReference.cancel()
            }
            await progressTask?.value
            return response
        } catch {
            await progressTask?.value
            throw error
        }
    }
}

private final class ModelDownloadTaskReference: @unchecked Sendable {
    struct Snapshot: Sendable {
        let bytesReceived: Int64
        let statusCode: Int?
        let isFinished: Bool
    }

    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancellationRequested = false

    func install(_ task: URLSessionDownloadTask) {
        lock.withLock {
            self.task = task
            if cancellationRequested { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
            task?.cancel()
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            guard let task else {
                return Snapshot(bytesReceived: 0, statusCode: nil, isFinished: false)
            }
            return Snapshot(
                bytesReceived: max(0, task.countOfBytesReceived),
                statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                isFinished: task.state == .completed
            )
        }
    }
}

actor PinnedModelInstaller {
    typealias ProgressHandler = @Sendable (ModelPreparationProgress) -> Void

    private let modelRoot: URL
    private let manifest: PinnedModelManifest
    private let fetcher: any ModelFileFetching
    private let fileManager: FileManager

    init(
        modelRoot: URL,
        manifest: PinnedModelManifest,
        fetcher: any ModelFileFetching = EphemeralModelFileFetcher(),
        fileManager: FileManager = .default
    ) {
        self.modelRoot = modelRoot
        self.manifest = manifest
        self.fetcher = fetcher
        self.fileManager = fileManager
    }

    var installedDirectory: URL {
        modelRoot.appendingPathComponent(manifest.localDirectory, isDirectory: true)
    }

    nonisolated static func containsExpectedLayout(
        at modelRoot: URL,
        manifest: PinnedModelManifest
    ) -> Bool {
        let directory = modelRoot.appendingPathComponent(manifest.localDirectory, isDirectory: true)
        return manifest.files.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.path).path)
        }
    }

    func ensureInstalled(
        allowNetwork: Bool,
        progress: ProgressHandler?
    ) async throws -> Bool {
        try Self.ensurePrivateDirectory(modelRoot)
        let target = installedDirectory
        if fileManager.fileExists(atPath: target.path) {
            progress?(.verifying)
            if (try? Self.validateDirectory(target, manifest: manifest)) == true {
                try Self.enforcePrivatePermissions(at: target)
                return true
            }
        }

        // A read-only refresh must never remove a questionable cache or turn
        // itself into an implicit network download. Only the explicit install
        // action is allowed to repair the model directory.
        guard allowNetwork else { throw PinnedModelError.offlineAndMissing }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }

        var lastFailure: Error?
        for attempt in 1...2 {
            do {
                try Task.checkCancellation()
                let stagingParent = modelRoot.appendingPathComponent(
                    ".download-\(manifest.revision)",
                    isDirectory: true
                )
                let staging = stagingParent.appendingPathComponent(
                    manifest.localDirectory,
                    isDirectory: true
                )
                try Self.ensurePrivateDirectory(stagingParent)
                try Self.ensurePrivateDirectory(staging)
                try await downloadAll(to: staging, progress: progress)
                try Task.checkCancellation()
                progress?(.verifying)
                guard try Self.validateDirectory(staging, manifest: manifest) else {
                    throw PinnedModelError.integrityCheckFailed
                }
                try Self.enforcePrivatePermissions(at: staging)
                try fileManager.moveItem(at: staging, to: target)
                try Self.enforcePrivatePermissions(at: target)
                return false
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error
                if attempt == 2 { break }
            }
        }

        if let lastFailure { throw lastFailure }
        throw PinnedModelError.integrityCheckFailed
    }

    func validateInstalled() throws -> Bool {
        try Self.validateDirectory(installedDirectory, manifest: manifest)
    }

    private func downloadAll(to staging: URL, progress: ProgressHandler?) async throws {
        var completedBytes: Int64 = 0
        for (index, entry) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(entry.path)
            if try Self.validateFile(destination, entry: entry) {
                completedBytes += entry.byteCount
                progress?(.downloading(
                    fraction: Double(completedBytes) / Double(manifest.totalByteCount),
                    currentFile: index + 1,
                    totalFiles: manifest.files.count
                ))
                continue
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try Self.ensurePrivateDirectory(destination.deletingLastPathComponent())
            let part = destination.appendingPathExtension("part")
            let completedBeforeFile = completedBytes
            let totalModelBytes = manifest.totalByteCount
            let totalFiles = manifest.files.count
            try await download(entry, to: part) { currentFileBytes in
                let totalDownloaded = completedBeforeFile
                    + min(max(currentFileBytes, 0), entry.byteCount)
                progress?(.downloading(
                    fraction: Double(totalDownloaded) / Double(totalModelBytes),
                    currentFile: index + 1,
                    totalFiles: totalFiles
                ))
            }
            guard try Self.validateFile(part, entry: entry) else {
                if fileManager.fileExists(atPath: part.path) {
                    try fileManager.removeItem(at: part)
                }
                throw PinnedModelError.invalidHash(entry.path)
            }
            try fileManager.moveItem(at: part, to: destination)
            try Self.setPermissions(0o600, at: destination)
            completedBytes += entry.byteCount
            progress?(.downloading(
                fraction: Double(completedBytes) / Double(manifest.totalByteCount),
                currentFile: index + 1,
                totalFiles: manifest.files.count
            ))
        }
    }

    private func download(
        _ entry: PinnedModelManifest.FileEntry,
        to part: URL,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        let existingBytes = Self.fileSize(at: part) ?? 0
        if existingBytes > entry.byteCount {
            try fileManager.removeItem(at: part)
        }
        let resumeOffset = Self.fileSize(at: part) ?? 0
        if resumeOffset == entry.byteCount {
            if try Self.validateFile(part, entry: entry) { return }
            try fileManager.removeItem(at: part)
        }

        var request = URLRequest(url: try manifest.downloadURL(for: entry))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let finalOffset = Self.fileSize(at: part) ?? 0
        progress?(finalOffset)
        if finalOffset > 0 {
            request.setValue("bytes=\(finalOffset)-", forHTTPHeaderField: "Range")
        }

        let response = try await fetcher.download(request) { transfer in
            let currentFileBytes = switch transfer.statusCode {
            case 206:
                finalOffset + transfer.bytesReceived
            case nil:
                max(finalOffset, transfer.bytesReceived)
            default:
                transfer.bytesReceived
            }
            progress?(currentFileBytes)
        }
        defer {
            if response.removeTemporaryFileAfterUse {
                try? fileManager.removeItem(at: response.temporaryFile)
            }
        }
        try Task.checkCancellation()
        switch response.statusCode {
        case 200:
            if fileManager.fileExists(atPath: part.path) {
                try fileManager.removeItem(at: part)
            }
            try fileManager.copyItem(at: response.temporaryFile, to: part)
        case 206:
            guard finalOffset > 0,
                  response.contentRange?.hasPrefix("bytes \(finalOffset)-") == true else {
                throw PinnedModelError.invalidResumeResponse(entry.path)
            }
            try Self.append(contentsOf: response.temporaryFile, to: part)
        case 416:
            guard finalOffset == entry.byteCount,
                  try Self.validateFile(part, entry: entry) else {
                throw PinnedModelError.invalidResumeResponse(entry.path)
            }
            return
        default:
            throw PinnedModelError.invalidResponse(entry.path, response.statusCode)
        }
        try Self.setPermissions(0o600, at: part)

        let actual = Self.fileSize(at: part) ?? 0
        guard actual == entry.byteCount else {
            throw PinnedModelError.invalidSize(entry.path, expected: entry.byteCount, actual: actual)
        }
        guard try Self.validateFile(part, entry: entry) else {
            try fileManager.removeItem(at: part)
            throw PinnedModelError.invalidHash(entry.path)
        }
    }

    private nonisolated static func validateDirectory(
        _ directory: URL,
        manifest: PinnedModelManifest
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        let expected = Set(manifest.files.map(\.path))
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let resolvedDirectoryPath = directory.resolvingSymlinksInPath().path
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw PinnedModelError.unexpectedFile(item.lastPathComponent)
                }
                guard values.isRegularFile == true else { continue }
                let resolvedItemPath = item.resolvingSymlinksInPath().path
                guard resolvedItemPath.hasPrefix(resolvedDirectoryPath + "/") else {
                    throw PinnedModelError.unexpectedFile(item.lastPathComponent)
                }
                let relative = String(resolvedItemPath.dropFirst(resolvedDirectoryPath.count + 1))
                guard expected.contains(relative) else {
                    throw PinnedModelError.unexpectedFile(relative)
                }
            }
        }

        for entry in manifest.files {
            guard try validateFile(directory.appendingPathComponent(entry.path), entry: entry) else {
                return false
            }
        }
        return true
    }

    private nonisolated static func validateFile(
        _ url: URL,
        entry: PinnedModelManifest.FileEntry
    ) throws -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return false }
        guard fileSize(at: url) == entry.byteCount else { return false }
        return try sha256(of: url) == entry.sha256
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func append(contentsOf source: URL, to destination: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        try writer.seekToEnd()
        while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty {
            try writer.write(contentsOf: data)
        }
        try writer.synchronize()
    }

    private nonisolated static func fileSize(at url: URL) -> Int64? {
        guard let number = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return number.int64Value
    }

    private nonisolated static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, at: url)
    }

    private nonisolated static func enforcePrivatePermissions(at directory: URL) throws {
        try setPermissions(0o700, at: directory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else { return }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try setPermissions(0o700, at: item)
            } else if values.isRegularFile == true {
                try setPermissions(0o600, at: item)
            }
        }
    }

    private nonisolated static func setPermissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
