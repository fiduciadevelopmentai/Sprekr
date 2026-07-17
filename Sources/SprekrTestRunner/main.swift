import Foundation
import SprekrCore

@main
struct SprekrTestRunner {
    static func main() async {
        do {
            let expected = TranscriptionResult(
                text: "Sprekr remains local.",
                audioDuration: 2,
                transcriptionDuration: 0.01
            )
            let engine: any TranscriptionEngine = FakeTranscriptionEngine(result: expected)
            let preparation = try await engine.prepare()
            let result = try await engine.transcribe(
                audioURL: URL(fileURLWithPath: "/tmp/fixture.wav"),
                language: .english
            )

            guard preparation.modelBytes == 0, result == expected else {
                throw TestFailure("Fake engine no longer conforms to the replacement contract.")
            }
            print("PASS: Fake TranscriptionEngine contract")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
