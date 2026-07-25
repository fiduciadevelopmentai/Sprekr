import AppKit
import Foundation

/// Repairs single words that the recognizer rendered as a non-word, such as
/// "insproken" for "ingesproken". This is the same conservatism as the
/// Dictionary's fuzzy pass, but the candidates come from the local macOS
/// dictionaries instead of the user's own aliases.
///
/// A word is only rewritten when every gate passes, so anything the recognizer
/// may legitimately have heard is left exactly as dictated.
enum LexicalRepairFormatter {
    /// Local spelling knowledge, injected so the pass stays testable and so the
    /// main-thread-bound `NSSpellChecker` is never touched from a background
    /// context. When no speller is supplied the pass is skipped entirely.
    struct Speller {
        let isKnown: (String, RecognitionLanguage) -> Bool
        let guesses: (String, RecognitionLanguage) -> [String]

        init(
            isKnown: @escaping (String, RecognitionLanguage) -> Bool,
            guesses: @escaping (String, RecognitionLanguage) -> [String]
        ) {
            self.isKnown = isKnown
            self.guesses = guesses
        }
    }

    static func repair(
        _ text: String,
        language: RecognitionLanguage,
        speller: Speller,
        protectedTerms: Set<String> = []
    ) -> String {
        guard !text.isEmpty, let expression = wordExpression else { return text }

        let source = text as NSString
        let emailRanges = SpokenEmailFormatter.validEmailRanges(in: text)
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )

        var result = text
        for match in matches.reversed() {
            let word = source.substring(with: match.range)
            guard isEligible(word, protectedTerms: protectedTerms) else { continue }
            guard !isProtected(match.range, in: source, emailRanges: emailRanges) else { continue }
            guard !speller.isKnown(word, language) else { continue }
            guard let corrected = uniqueCorrection(
                for: word,
                language: language,
                speller: speller
            ) else { continue }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: preservingWordCase(of: word, in: corrected))
        }
        return result
    }

    // MARK: - Gates

    private static func isEligible(_ word: String, protectedTerms: Set<String>) -> Bool {
        // A capital signals a name the recognizer may have heard correctly, and
        // the local dictionaries have no opinion on personal names.
        guard word.count >= minimumWordLength,
              !word.contains(where: { $0.isUppercase || $0.isNumber }),
              word.allSatisfy({ $0.isLetter })
        else { return false }
        guard !TermLexicon.isKnownTerm(word) else { return false }
        return !protectedTerms.contains(normalizedKey(word))
    }

    private static func isProtected(
        _ range: NSRange,
        in source: NSString,
        emailRanges: [NSRange]
    ) -> Bool {
        let insideEmail = emailRanges.contains { emailRange in
            range.location >= emailRange.location && NSMaxRange(range) <= NSMaxRange(emailRange)
        }
        if insideEmail { return true }

        var start = range.location
        while start > 0, !isTokenSeparator(source.character(at: start - 1)) {
            start -= 1
        }
        var end = NSMaxRange(range)
        while end < source.length, !isTokenSeparator(source.character(at: end)) {
            end += 1
        }
        let token = source.substring(with: NSRange(location: start, length: end - start))
        return token.contains("/") || token.contains("\\") || token.contains("@")
    }

    private static func isTokenSeparator(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Accepts a correction only when the local dictionary offers exactly one
    /// close candidate. Anything ambiguous stays as dictated.
    private static func uniqueCorrection(
        for word: String,
        language: RecognitionLanguage,
        speller: Speller
    ) -> String? {
        let characters = Array(word)
        let maximumDistance = characters.count >= longWordLength ? 2 : 1

        var best: (candidate: String, distance: Int)?
        var isAmbiguous = false

        for candidate in speller.guesses(word, language) {
            guard candidate.count >= minimumWordLength,
                  candidate.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
                  !candidate.contains(where: \.isUppercase)
            else { continue }

            let candidateCharacters = Array(candidate)
            guard characters.first == candidateCharacters.first else { continue }

            let distance = DictionaryCorrectionEngine.damerauLevenshteinDistance(
                characters,
                candidateCharacters,
                limit: maximumDistance
            )
            guard distance > 0, distance <= maximumDistance else { continue }

            if let current = best {
                if distance < current.distance {
                    best = (candidate, distance)
                    isAmbiguous = false
                } else if distance == current.distance, candidate != current.candidate {
                    isAmbiguous = true
                }
            } else {
                best = (candidate, distance)
            }
        }

        guard !isAmbiguous else { return nil }
        return best?.candidate
    }

    private static func preservingWordCase(of source: String, in replacement: String) -> String {
        guard source.first?.isUppercase == true, let first = replacement.first else {
            return replacement
        }
        return String(first).uppercased() + replacement.dropFirst()
    }

    private static func normalizedKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static let minimumWordLength = 5
    private static let longWordLength = 8

    private static let wordExpression = try? NSRegularExpression(
        pattern: #"[\p{L}\p{M}]+"#
    )
}

// MARK: - System speller

extension LexicalRepairFormatter.Speller {
    /// Wraps the local macOS dictionaries. Must be built and used on the main
    /// actor, which is where the dictation pipeline already runs.
    @MainActor
    static func system() -> Self {
        let checker = NSSpellChecker.shared
        let available = Set(checker.availableLanguages)
        var knownCache: [String: Bool] = [:]
        var guessCache: [String: [String]] = [:]

        func codes(for language: RecognitionLanguage) -> [String] {
            let candidates: [String] = switch language {
            case .dutch: ["nl_NL", "nl"]
            case .english: ["en_GB", "en_US", "en"]
            case .automatic: ["nl_NL", "nl", "en_GB", "en_US", "en"]
            }
            return candidates.filter(available.contains)
        }

        // A word is only a candidate for repair when neither language knows it.
        // This is what keeps an English term spoken inside Dutch dictation from
        // being "corrected" into the nearest Dutch word.
        let allCodes = codes(for: .automatic)

        return LexicalRepairFormatter.Speller(
            isKnown: { word, _ in
                // Without an installed dictionary nothing can be judged unknown,
                // so treat every word as known and make the pass a no-op.
                guard !allCodes.isEmpty else { return true }
                let key = word.lowercased()
                if let cached = knownCache[key] { return cached }
                let known = allCodes.contains { code in
                    checker.checkSpelling(
                        of: word,
                        startingAt: 0,
                        language: code,
                        wrap: false,
                        inSpellDocumentWithTag: 0,
                        wordCount: nil
                    ).location == NSNotFound
                }
                knownCache[key] = known
                return known
            },
            guesses: { word, language in
                let usable = codes(for: language)
                guard !usable.isEmpty else { return [] }
                let key = word.lowercased() + "|" + language.rawValue
                if let cached = guessCache[key] { return cached }
                let range = NSRange(location: 0, length: (word as NSString).length)
                var collected: [String] = []
                for code in usable {
                    let suggestions = checker.guesses(
                        forWordRange: range,
                        in: word,
                        language: code,
                        inSpellDocumentWithTag: 0
                    ) ?? []
                    collected.append(contentsOf: suggestions)
                }
                let deduplicated = Array(Set(collected))
                guessCache[key] = deduplicated
                return deduplicated
            }
        )
    }
}
