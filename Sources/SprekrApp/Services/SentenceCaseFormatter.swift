import Foundation

/// Capitalizes the word after an internal sentence boundary. Parakeet normally
/// handles this itself, but it drops the capital whenever it also drops the
/// terminal punctuation.
///
/// Two deliberate omissions keep the pass safe:
///
/// - The first word of the transcript is never raised, because Sprekr inserts
///   at the caret and the dictation may continue a sentence already on screen.
/// - A paragraph or bullet start is never raised, since those layouts are
///   produced by passes that already own their casing.
///
/// The pass only ever raises a letter. It never lowercases anything, so a word
/// the recognizer or the Dictionary deliberately capitalized stays as it is.
enum SentenceCaseFormatter {
    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let source = text as NSString
        let emailRanges = SpokenEmailFormatter.validEmailRanges(in: text)
        var result = text

        for range in sentenceStartWordRanges(in: text).reversed() {
            let word = source.substring(with: range)
            guard let first = word.first, first.isLowercase else { continue }
            guard !TermLexicon.isCaseLocked(word) else { continue }
            guard !isProtected(range, in: source, emailRanges: emailRanges) else { continue }
            guard let wordRange = Range(range, in: result) else { continue }
            result.replaceSubrange(
                wordRange,
                with: String(first).uppercased() + word.dropFirst()
            )
        }
        return result
    }

    /// The word opening a sentence that follows another one on the same line.
    /// Whitespace after the terminal punctuation is required, so `github.com`
    /// and `3.5` are never mistaken for a boundary.
    private static func sentenceStartWordRanges(in text: String) -> [NSRange] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<=[.!?…])[ \t]+(?:["“'‘(\[]+[ \t]*)?([\p{L}\p{M}][\p{L}\p{M}'’]*)"#
        ) else { return [] }

        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : range
        }
    }

    /// Never touches a word that belongs to an address, URL or file path, where
    /// casing is part of the identifier.
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
}
