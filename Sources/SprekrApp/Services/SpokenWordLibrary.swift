import AppKit
import Foundation

/// Builds the Dictionary's word library from encrypted local History. Nothing
/// new is uploaded or stored in a second plaintext index: deleting History also
/// removes its derived observations the next time local data is reloaded.
enum SpokenWordLibrary {
    private struct Accumulator {
        var variants: [String: Int] = [:]
        var occurrenceCount = 0
        var lastUsedAt = Date.distantPast
        var languages = Set<DictionaryLanguage>()
        var isLikelyNameOrBrand = false
    }

    static func build(
        from transcripts: [TranscriptRecord],
        dictionaryEntries: [DictionaryEntry],
        isKnown: (String, DictionaryLanguage) -> Bool
    ) -> [SpokenWordObservation] {
        let coveredSpellings = Set(dictionaryEntries.flatMap { entry in
            ([entry.preferredSpelling] + entry.aliases).flatMap { term in
                [normalizedKey(term)] + tokens(in: term).map { normalizedKey($0.spelling) }
            }
        })
        var accumulators: [String: Accumulator] = [:]

        for transcript in transcripts {
            let language = dictionaryLanguage(for: transcript.language)
            for token in tokens(in: transcript.text) {
                let key = normalizedKey(token.spelling)
                guard !key.isEmpty, !coveredSpellings.contains(key) else { continue }
                // Common vocabulary never enters the accumulated model. This
                // keeps both controller memory and the SwiftUI list proportional
                // to useful exceptions rather than total History vocabulary.
                guard token.isLikelyNameOrBrand || !isKnown(token.spelling, language)
                else { continue }

                var accumulator = accumulators[key] ?? Accumulator()
                accumulator.variants[token.spelling, default: 0] += 1
                accumulator.occurrenceCount += 1
                accumulator.lastUsedAt = max(accumulator.lastUsedAt, transcript.createdAt)
                accumulator.languages.insert(language)
                accumulator.isLikelyNameOrBrand = accumulator.isLikelyNameOrBrand
                    || token.isLikelyNameOrBrand
                accumulators[key] = accumulator
            }
        }

        return accumulators.map { key, accumulator in
            let spelling = preferredVariant(in: accumulator.variants)
            let language = combinedLanguage(accumulator.languages)
            return SpokenWordObservation(
                id: key,
                spelling: spelling,
                occurrenceCount: accumulator.occurrenceCount,
                lastUsedAt: accumulator.lastUsedAt,
                language: language,
                isLikelyNameOrBrand: accumulator.isLikelyNameOrBrand
            )
        }
        .sorted {
            if $0.occurrenceCount != $1.occurrenceCount {
                return $0.occurrenceCount > $1.occurrenceCount
            }
            return $0.spelling.localizedCaseInsensitiveCompare($1.spelling) == .orderedAscending
        }
    }

    private struct Token {
        let spelling: String
        let isLikelyNameOrBrand: Bool
    }

    private static func tokens(in text: String) -> [Token] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{M}][\p{L}\p{M}’'\-]*"#
        ) else { return [] }

        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let spelling = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
            guard !spelling.isEmpty else { return nil }

            let prefix = text[..<range.lowerBound]
            let previousVisible = prefix.last(where: { !$0.isWhitespace })
            let isSentenceInitial = previousVisible == nil
                || previousVisible.map { ".!?…\n".contains($0) } == true
            let hasInternalCapital = spelling.dropFirst().contains(where: \.isUppercase)
            let beginsWithCapital = spelling.first?.isUppercase == true
            return Token(
                spelling: spelling,
                isLikelyNameOrBrand: hasInternalCapital || (beginsWithCapital && !isSentenceInitial)
            )
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredVariant(in variants: [String: Int]) -> String {
        variants.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            let lhsHasCapital = lhs.key.first?.isUppercase == true
            let rhsHasCapital = rhs.key.first?.isUppercase == true
            if lhsHasCapital != rhsHasCapital { return lhsHasCapital }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }.first?.key ?? ""
    }

    private static func dictionaryLanguage(for language: RecognitionLanguage) -> DictionaryLanguage {
        switch language {
        case .dutch: .dutch
        case .english: .english
        case .automatic: .both
        }
    }

    private static func combinedLanguage(_ languages: Set<DictionaryLanguage>) -> DictionaryLanguage {
        guard languages.count == 1, let language = languages.first else { return .both }
        return language
    }
}

@MainActor
final class SpokenWordClassifier {
    private var cache: [String: Bool] = [:]

    func isKnown(_ word: String, language: DictionaryLanguage) -> Bool {
        if word.count == 1 { return true }
        let key = word.lowercased() + "|" + language.rawValue
        if let cached = cache[key] { return cached }

        let checker = NSSpellChecker.shared
        let available = Set(checker.availableLanguages)
        let candidates: [String] = switch language {
        case .dutch: ["nl_NL", "nl"]
        case .english: ["en_GB", "en_US", "en"]
        case .both: ["nl_NL", "nl", "en_GB", "en_US", "en"]
        }
        let usable = candidates.filter(available.contains)
        let known = usable.contains { languageCode in
            checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: languageCode,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            ).location == NSNotFound
        }
        cache[key] = known
        return known
    }
}
