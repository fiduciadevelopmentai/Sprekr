import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

struct DictationLanguagePlan: Equatable {
    let sourceLanguage: RecognitionLanguage
    let outputLanguage: RecognitionLanguage
    let requiresTranslation: Bool

    static func resolve(
        text: String,
        outputPreference: RecognitionLanguage
    ) -> DictationLanguagePlan {
        make(
            detectedSource: SpokenLanguageDetector.detect(in: text),
            outputPreference: outputPreference
        )
    }

    static func make(
        detectedSource: RecognitionLanguage?,
        outputPreference: RecognitionLanguage
    ) -> DictationLanguagePlan {
        guard outputPreference != .automatic else {
            return DictationLanguagePlan(
                sourceLanguage: detectedSource ?? .automatic,
                outputLanguage: detectedSource ?? .automatic,
                requiresTranslation: false
            )
        }

        let fallbackSource: RecognitionLanguage = outputPreference == .dutch ? .english : .dutch
        let sourceLanguage = detectedSource ?? fallbackSource
        return DictationLanguagePlan(
            sourceLanguage: sourceLanguage,
            outputLanguage: outputPreference,
            requiresTranslation: sourceLanguage != outputPreference
        )
    }
}

enum SpokenLanguageDetector {
    static func detect(in text: String) -> RecognitionLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .dutch: return RecognitionLanguage.dutch
        case .english: return RecognitionLanguage.english
        default: return nil
        }
    }
}

enum LocalTranslationError: LocalizedError {
    case unavailable
    case superseded
    case emptyResult
    case protectedLiteralChanged

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Local translation requires macOS 15 or newer."
        case .superseded:
            "A newer translation replaced this request."
        case .emptyResult:
            "The local translator returned no text."
        case .protectedLiteralChanged:
            "The local translator changed a protected email address."
        }
    }
}

/// Bridges the app's global dictation pipeline to Apple's on-device Translation
/// framework. The SwiftUI host lives in the always-available Flow Bar panel so
/// the system can safely present one-time language-download approval when needed.
@MainActor
final class LocalTranslationService: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id: UUID
        let text: String
        let sourceLanguage: RecognitionLanguage
        let targetLanguage: RecognitionLanguage
        let emailProtection: SpokenEmailFormatter.TranslationProtection
    }

    @Published fileprivate var pendingRequest: Request?
    private var continuation: CheckedContinuation<String, any Error>?

    func translate(_ text: String, using plan: DictationLanguagePlan) async throws -> String {
        guard plan.requiresTranslation else { return text }
        guard #available(macOS 15.0, *) else { throw LocalTranslationError.unavailable }
        let emailProtection = SpokenEmailFormatter.protectForTranslation(text)

        if #available(macOS 26.0, *) {
            let source = plan.sourceLanguage.localeLanguage
            let target = plan.outputLanguage.localeLanguage
            let availability = await LanguageAvailability().status(from: source, to: target)
            if availability == .installed {
                let session = TranslationSession(installedSource: source, target: target)
                let response = try await session.translate(emailProtection.text)
                guard let restored = emailProtection.restore(in: response.targetText) else {
                    throw LocalTranslationError.protectedLiteralChanged
                }
                let translated = restored.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translated.isEmpty else { throw LocalTranslationError.emptyResult }
                return translated
            }
        }

        if let continuation {
            continuation.resume(throwing: LocalTranslationError.superseded)
            self.continuation = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            pendingRequest = Request(
                id: UUID(),
                text: emailProtection.text,
                sourceLanguage: plan.sourceLanguage,
                targetLanguage: plan.outputLanguage,
                emailProtection: emailProtection
            )
        }
    }

    @available(macOS 15.0, *)
    fileprivate func performPending(using session: TranslationSession) async {
        guard let request = pendingRequest else { return }
        do {
            try await session.prepareTranslation()
            guard pendingRequest?.id == request.id else { return }
            let response = try await session.translate(request.text)
            guard let restored = request.emailProtection.restore(in: response.targetText) else {
                throw LocalTranslationError.protectedLiteralChanged
            }
            let translated = restored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { throw LocalTranslationError.emptyResult }
            finish(requestID: request.id, result: .success(translated))
        } catch {
            finish(requestID: request.id, result: .failure(error))
        }
    }

    private func finish(requestID: UUID, result: Result<String, any Error>) {
        guard pendingRequest?.id == requestID else { return }
        pendingRequest = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

@available(macOS 15.0, *)
private struct LocalTranslationHost: ViewModifier {
    @ObservedObject var service: LocalTranslationService
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: service.pendingRequest?.id, initial: true) { _, _ in
                refreshConfiguration()
            }
            .translationTask(configuration) { session in
                await service.performPending(using: session)
            }
    }

    private func refreshConfiguration() {
        guard let request = service.pendingRequest else {
            configuration = nil
            return
        }

        let source = request.sourceLanguage.localeLanguage
        let target = request.targetLanguage.localeLanguage
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

extension View {
    @ViewBuilder
    func sprekrLocalTranslationHost(_ service: LocalTranslationService) -> some View {
        if #available(macOS 15.0, *) {
            modifier(LocalTranslationHost(service: service))
        } else {
            self
        }
    }
}

private extension RecognitionLanguage {
    var localeLanguage: Locale.Language {
        switch self {
        case .dutch: Locale.Language(identifier: "nl")
        case .english: Locale.Language(identifier: "en")
        case .automatic: Locale.Language(identifier: "en")
        }
    }
}
