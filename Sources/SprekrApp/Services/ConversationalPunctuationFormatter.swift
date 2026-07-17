import Foundation

/// Softens recognizer-inserted full stops only where the next short fragment
/// is grammatically dependent on the previous thought. It intentionally avoids
/// broad sentence rewriting, so complete new sentences remain separate.
enum ConversationalPunctuationFormatter {
    static func soften(_ text: String, language: RecognitionLanguage) -> String {
        let starters: [String] = switch language {
        case .dutch:
            ["dat", "die", "dit", "want", "maar", "dus", "omdat", "terwijl", "en ook"]
        case .english:
            ["that", "because", "but", "so", "while", "and also"]
        case .automatic:
            [
                "dat", "die", "dit", "want", "maar", "dus", "omdat", "terwijl", "en ook",
                "that", "because", "but", "so", "while", "and also",
            ]
        }
        let alternatives = starters.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: #"([\p{L}\p{N}“\"'][^.!?\n]{0,279})\.[ \t]+((?:\#(alternatives))\b[^.!?\n]{1,180})([.!?])"#,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        for _ in 0..<4 {
            let matches = expression.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result)
            )
            var changed = false
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let leftRange = Range(match.range(at: 1), in: result),
                      let rightRange = Range(match.range(at: 2), in: result),
                      let terminalRange = Range(match.range(at: 3), in: result)
                else { continue }

                let left = String(result[leftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(result[rightRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard (4...36).contains(wordCount(in: left)),
                      (2...10).contains(wordCount(in: right))
                else { continue }

                let replacement = left + ", " + lowercasingFirstLetter(right)
                    + String(result[terminalRange])
                result.replaceSubrange(fullRange, with: replacement)
                changed = true
            }
            guard changed else { break }
        }
        return result
    }

    private static func wordCount(in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#) else { return 0 }
        return expression.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
    }

    private static func lowercasingFirstLetter(_ value: String) -> String {
        guard let firstLetter = value.firstIndex(where: \.isLetter) else { return value }
        var result = value
        let next = result.index(after: firstLetter)
        result.replaceSubrange(firstLetter..<next, with: String(result[firstLetter]).lowercased())
        return result
    }
}
