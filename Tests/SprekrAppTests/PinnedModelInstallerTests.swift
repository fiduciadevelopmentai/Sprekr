import CryptoKit
import Foundation
import Testing
@testable import SprekrCore

@Suite("Pinned model installer")
struct PinnedModelInstallerTests {
    @Test
    func bundledManifestUsesTheReviewedRevisionAndFixedHTTPSURL() throws {
        let manifest = try PinnedModelManifest.bundled()
        #expect(manifest.revision == "aed02740059203c4a87495924f685de3722ae9ce")
        #expect(manifest.repository == "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        #expect(manifest.license == "CC-BY-4.0")
        #expect(manifest.files.count == 23)
        let entry = try #require(manifest.files.first)
        let url = try manifest.downloadURL(for: entry)
        #expect(url.scheme == "https")
        #expect(url.host == "huggingface.co")
        #expect(url.absoluteString.contains(manifest.revision))
        #expect(!url.absoluteString.contains("/main/"))
    }

    @Test
    func manifestRejectsTraversalAndURLControlCharacters() {
        for unsafePath in ["../model.bin", "/model.bin", "folder//model.bin", "model.bin?download=1"] {
            let manifest = PinnedModelManifest(
                schemaVersion: 1,
                repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                revision: String(repeating: "a", count: 40),
                license: "CC-BY-4.0",
                localDirectory: "parakeet-tdt-0.6b-v3",
                files: [.init(path: unsafePath, byteCount: 1, sha256: String(repeating: "a", count: 64))]
            )
            #expect(throws: PinnedModelError.self) { try manifest.validate() }
        }
    }

    @Test
    func full200DownloadActivatesOnlyAfterHashVerification() async throws {
        let fixture = Data("verified fixture".utf8)
        let environment = try TestEnvironment()
        defer { environment.cleanup() }
        let responseFile = try environment.write(fixture, named: "response.bin")
        let fetcher = RecordingModelFetcher { request, _ in
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return ModelDownloadResponse(
                temporaryFile: responseFile,
                statusCode: 200,
                contentRange: nil
            )
        }
        let manifest = makeManifest(data: fixture)
        let installer = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: manifest,
            fetcher: fetcher
        )

        #expect(try await installer.ensureInstalled(allowNetwork: true, progress: nil) == false)
        #expect(try Data(contentsOf: environment.installedFile) == fixture)
        #expect(fetcher.requestCount == 1)
        #expect(try await installer.ensureInstalled(allowNetwork: false, progress: nil))
        #expect(fetcher.requestCount == 1)
    }

    @Test
    func resumeUses206AndTheExactStablePartOffset() async throws {
        let fixture = Data("abcdefgh".utf8)
        let environment = try TestEnvironment()
        defer { environment.cleanup() }
        try environment.preparePart(Data("abcd".utf8))
        let responseFile = try environment.write(Data("efgh".utf8), named: "remainder.bin")
        let fetcher = RecordingModelFetcher { request, _ in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4-")
            return ModelDownloadResponse(
                temporaryFile: responseFile,
                statusCode: 206,
                contentRange: "bytes 4-7/8"
            )
        }
        let installer = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: makeManifest(data: fixture),
            fetcher: fetcher
        )

        _ = try await installer.ensureInstalled(allowNetwork: true, progress: nil)
        #expect(try Data(contentsOf: environment.installedFile) == fixture)
        #expect(fetcher.requestCount == 1)
    }

    @Test
    func server200FallbackReplacesAPartialFileInsteadOfAppending() async throws {
        let fixture = Data("abcdefgh".utf8)
        let environment = try TestEnvironment()
        defer { environment.cleanup() }
        try environment.preparePart(Data("abcd".utf8))
        let responseFile = try environment.write(fixture, named: "full.bin")
        let fetcher = RecordingModelFetcher { request, _ in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4-")
            return ModelDownloadResponse(
                temporaryFile: responseFile,
                statusCode: 200,
                contentRange: nil
            )
        }
        let installer = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: makeManifest(data: fixture),
            fetcher: fetcher
        )

        _ = try await installer.ensureInstalled(allowNetwork: true, progress: nil)
        #expect(try Data(contentsOf: environment.installedFile) == fixture)
    }

    @Test
    func equalSizeCorruptionRetriesOnceAndNeverDeletesOutsideTheModelSubpath() async throws {
        let fixture = Data("correct!".utf8)
        let corrupt = Data("corrupt!".utf8)
        let environment = try TestEnvironment()
        defer { environment.cleanup() }
        let responseFile = try environment.write(corrupt, named: "corrupt.bin")
        let sentinel = try environment.write(Data("keep".utf8), named: "outside-model-sentinel")
        let fetcher = RecordingModelFetcher { _, _ in
            ModelDownloadResponse(
                temporaryFile: responseFile,
                statusCode: 200,
                contentRange: nil
            )
        }
        let installer = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: makeManifest(data: fixture),
            fetcher: fetcher
        )

        await #expect(throws: PinnedModelError.self) {
            _ = try await installer.ensureInstalled(allowNetwork: true, progress: nil)
        }
        #expect(fetcher.requestCount == 2)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(!FileManager.default.fileExists(atPath: environment.installedFile.path))
    }

    @Test
    func corruptInstalledCacheIsReplacedWithoutTouchingItsSibling() async throws {
        let fixture = Data("correct!".utf8)
        let environment = try TestEnvironment()
        defer { environment.cleanup() }
        try FileManager.default.createDirectory(
            at: environment.installedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("corrupt!".utf8).write(to: environment.installedFile)
        let sentinel = try environment.write(Data("keep".utf8), named: "sibling-sentinel")
        let responseFile = try environment.write(fixture, named: "valid.bin")
        let fetcher = RecordingModelFetcher { _, _ in
            ModelDownloadResponse(temporaryFile: responseFile, statusCode: 200, contentRange: nil)
        }
        let installer = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: makeManifest(data: fixture),
            fetcher: fetcher
        )

        _ = try await installer.ensureInstalled(allowNetwork: true, progress: nil)
        #expect(try Data(contentsOf: environment.installedFile) == fixture)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test
    func missingRemoteFileRetriesOnceAndNeverActivatesAPartialModel() async throws {
        let fixture = Data("fixture".utf8)
        let environment = try TestEnvironment()
        defer { environment.cleanup() }
        let responseFile = try environment.write(Data(), named: "missing.bin")
        let fetcher = RecordingModelFetcher { _, _ in
            ModelDownloadResponse(temporaryFile: responseFile, statusCode: 404, contentRange: nil)
        }
        let installer = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: makeManifest(data: fixture),
            fetcher: fetcher
        )

        await #expect(throws: PinnedModelError.self) {
            _ = try await installer.ensureInstalled(allowNetwork: true, progress: nil)
        }
        #expect(fetcher.requestCount == 2)
        #expect(!FileManager.default.fileExists(atPath: environment.installedFile.path))
    }

    @Test
    func cancellationKeepsAResumablePartAndOfflineModeNeverFetches() async throws {
        let fixture = Data("abcdefgh".utf8)
        let environment = try TestEnvironment()
        defer { environment.cleanup() }
        try environment.preparePart(Data("abcd".utf8))
        let fetcher = RecordingModelFetcher { _, _ in throw CancellationError() }
        let installer = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: makeManifest(data: fixture),
            fetcher: fetcher
        )

        await #expect(throws: CancellationError.self) {
            _ = try await installer.ensureInstalled(allowNetwork: true, progress: nil)
        }
        #expect(try Data(contentsOf: environment.partFile) == Data("abcd".utf8))

        let offlineFetcher = RecordingModelFetcher { _, _ in
            Issue.record("Offline validation attempted a network request")
            throw CancellationError()
        }
        let offlineInstaller = PinnedModelInstaller(
            modelRoot: environment.modelRoot,
            manifest: makeManifest(data: fixture),
            fetcher: offlineFetcher
        )
        await #expect(throws: PinnedModelError.self) {
            _ = try await offlineInstaller.ensureInstalled(allowNetwork: false, progress: nil)
        }
        #expect(offlineFetcher.requestCount == 0)
    }

    private func makeManifest(data: Data) -> PinnedModelManifest {
        PinnedModelManifest(
            schemaVersion: 1,
            repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            localDirectory: "parakeet-tdt-0.6b-v3",
            files: [.init(
                path: "model.bin",
                byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )]
        )
    }
}

private final class RecordingModelFetcher: ModelFileFetching, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> ModelDownloadResponse

    private let lock = NSLock()
    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func download(_ request: URLRequest) async throws -> ModelDownloadResponse {
        let index = lock.withLock {
            requests.append(request)
            return requests.count
        }
        return try handler(request, index)
    }
}

private struct TestEnvironment {
    let root: URL
    let modelRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprekr-model-test-\(UUID().uuidString)", isDirectory: true)
        modelRoot = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
    }

    var stagingDirectory: URL {
        modelRoot
            .appendingPathComponent(".download-\(String(repeating: "a", count: 40))", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    var partFile: URL { stagingDirectory.appendingPathComponent("model.bin.part") }
    var installedFile: URL {
        modelRoot
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
            .appendingPathComponent("model.bin")
    }

    func preparePart(_ data: Data) throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try data.write(to: partFile)
    }

    func write(_ data: Data, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
