import Foundation

struct ImmediateSpellingCorrection: Equatable, Sendable {
    let heard: String
    let preferred: String
}

enum ImmediateCorrectionEngine {
    private static let wordPattern = #"[\p{L}\p{N}][\p{L}\p{N}'’]*"#

    static func detect(original: String, edited: String) -> ImmediateSpellingCorrection? {
        let originalWords = words(in: original)
        let editedWords = words(in: edited)
        guard originalWords.count == editedWords.count,
              !originalWords.isEmpty
        else { return nil }

        let changed = zip(originalWords, editedWords).filter { heard, preferred in
            heard != preferred
        }
        guard changed.count == 1,
              let pair = changed.first,
              pair.0.count >= 2,
              pair.1.count >= 2,
              pair.0.count <= 64,
              pair.1.count <= 64,
              isPlausibleSpellingFix(heard: pair.0, preferred: pair.1)
        else { return nil }

        return ImmediateSpellingCorrection(heard: pair.0, preferred: pair.1)
    }

    /// Only a respelling of the same word is learned. Replacing "microfoon"
    /// with "camera" is an edit of meaning, and a case-only change is a style
    /// choice for that one sentence; neither should become a permanent alias.
    static func isPlausibleSpellingFix(heard: String, preferred: String) -> Bool {
        let heardKey = DictionaryEntryPolicy.normalizedKey(heard)
        let preferredKey = DictionaryEntryPolicy.normalizedKey(preferred)
        guard heardKey != preferredKey,
              let heardFirst = heardKey.first,
              let preferredFirst = preferredKey.first,
              heardFirst == preferredFirst
        else { return false }

        let heardCharacters = Array(heardKey)
        let preferredCharacters = Array(preferredKey)
        let longest = max(heardCharacters.count, preferredCharacters.count)
        let maximumDistance = longest <= 7 ? 2 : 3
        let distance = DictionaryCorrectionEngine.damerauLevenshteinDistance(
            heardCharacters,
            preferredCharacters,
            limit: maximumDistance
        )
        return distance <= maximumDistance
    }

    private static func words(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: wordPattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
