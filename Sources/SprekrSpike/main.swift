import Darwin
import Foundation
import SprekrCore

@main
struct SprekrSpike {
    static func main() async {
        let errorSink = SanitizedStandardError()
        do {
            let arguments = try Arguments.parse(CommandLine.arguments.dropFirst())
            let engine = LocalParakeetEngine()
            await engine.setOfflineModeForTesting(arguments.offline)

            let preparation = try await engine.prepare()
            print("MODEL_BYTES=\(preparation.modelBytes)")
            print("MODEL_PREPARATION_SECONDS=\(format(preparation.preparationDuration))")
            print("MODEL_WAS_CACHED=\(preparation.usedExistingModel)")
            print("OFFLINE_MODE=\(arguments.offline)")

            let result = try await engine.transcribe(
                audioURL: arguments.audioURL,
                language: arguments.language
            )
            print("AUDIO_SECONDS=\(format(result.audioDuration))")
            print("TRANSCRIPTION_SECONDS=\(format(result.transcriptionDuration))")
            print("TRANSCRIPT_CHARACTERS=\(result.text.count)")
            if arguments.expectNonempty,
               result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw EmptyTranscriptError()
            }
            if arguments.printTranscript {
                print("TRANSCRIPT=\(result.text)")
            }
            await engine.unload()
        } catch {
            errorSink.write("Sprekr spike failed: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }
}

/// FluidAudio's debug logger includes local cache paths. The development CLI
/// deliberately suppresses dependency stderr and emits only its own sanitized
/// failure message through the saved descriptor.
private final class SanitizedStandardError {
    private let originalDescriptor: Int32

    init() {
        originalDescriptor = dup(STDERR_FILENO)
        let nullDescriptor = open("/dev/null", O_WRONLY)
        if nullDescriptor >= 0 {
            _ = dup2(nullDescriptor, STDERR_FILENO)
            close(nullDescriptor)
        }
    }

    deinit {
        if originalDescriptor >= 0 { close(originalDescriptor) }
    }

    func write(_ message: String) {
        guard originalDescriptor >= 0 else { return }
        let data = Data(message.utf8)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = Darwin.write(originalDescriptor, baseAddress, bytes.count)
        }
    }
}

private func format(_ seconds: TimeInterval) -> String {
    String(format: "%.3f", seconds)
}

private struct Arguments {
    let audioURL: URL
    let language: TranscriptionLanguage
    let offline: Bool
    let printTranscript: Bool
    let expectNonempty: Bool

    static func parse(_ rawArguments: ArraySlice<String>) throws -> Arguments {
        var arguments = Array(rawArguments)
        var offline = false
        var printTranscript = false
        var expectNonempty = false

        for option in ["--offline", "--print-transcript", "--expect-nonempty"] {
            while let index = arguments.firstIndex(of: option) {
                switch option {
                case "--offline": offline = true
                case "--print-transcript": printTranscript = true
                case "--expect-nonempty": expectNonempty = true
                default: break
                }
                arguments.remove(at: index)
            }
        }

        guard arguments.count == 2,
              let language = language(for: arguments[0]) else {
            throw UsageError()
        }

        return Arguments(
            audioURL: URL(fileURLWithPath: arguments[1]),
            language: language,
            offline: offline,
            printTranscript: printTranscript,
            expectNonempty: expectNonempty
        )
    }

    private static func language(for argument: String) -> TranscriptionLanguage? {
        switch argument.lowercased() {
        case "auto": .automatic
        case "en", "english": .english
        case "nl", "dutch": .dutch
        default: nil
        }
    }
}

private struct UsageError: LocalizedError {
    var errorDescription: String? {
        "Usage: sprekr-spike [--offline] [--expect-nonempty] [--print-transcript] <auto|en|nl> <audio-file>"
    }
}

private struct EmptyTranscriptError: LocalizedError {
    var errorDescription: String? {
        "The synthetic integration fixture produced an empty transcript."
    }
}
