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
              pair.0.caseInsensitiveCompare(pair.1) != .orderedSame || pair.0 != pair.1
        else { return nil }

        return ImmediateSpellingCorrection(heard: pair.0, preferred: pair.1)
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
