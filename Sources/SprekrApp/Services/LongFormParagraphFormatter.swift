import Foundation

/// Adds paragraphs only when the local transcript contains a high-confidence
/// structural boundary. Explicit spoken commands are handled upstream; this
/// pass keeps short dictations untouched and never calls a remote model.
enum LongFormParagraphFormatter {
    private struct SentenceUnit {
        let text: String
        let wordCount: Int
        let contentWords: Set<String>
    }

    static func structure(_ text: String, language: RecognitionLanguage) -> String {
        text.components(separatedBy: "\n\n")
            .map { structureParagraph($0, language: language) }
            .joined(separator: "\n\n")
    }

    private static func structureParagraph(
        _ paragraph: String,
        language: RecognitionLanguage
    ) -> String {
        guard !paragraph.contains("\n• ") else { return paragraph }
        let sentences = sentenceUnits(in: paragraph, language: language)
        let totalWords = sentences.reduce(0) { $0 + $1.wordCount }
        guard sentences.count >= 2, totalWords >= 40 else { return paragraph }

        var paragraphs: [String] = []
        var paragraphStart = 0

        while paragraphStart < sentences.count {
            guard let boundary = nextBoundary(
                in: sentences,
                after: paragraphStart,
                language: language
            ) else {
                paragraphs.append(join(sentences[paragraphStart..<sentences.count]))
                break
            }
            paragraphs.append(join(sentences[paragraphStart..<boundary]))
            paragraphStart = boundary
        }

        return paragraphs.joined(separator: "\n\n")
    }

    private static func nextBoundary(
        in sentences: [SentenceUnit],
        after paragraphStart: Int,
        language: RecognitionLanguage
    ) -> Int? {
        guard paragraphStart + 1 < sentences.count else { return nil }
        let remainingWords = sentences[paragraphStart..<sentences.count]
            .reduce(0) { $0 + $1.wordCount }

        for boundary in (paragraphStart + 1)..<sentences.count {
            let precedingWords = sentences[paragraphStart..<boundary]
                .reduce(0) { $0 + $1.wordCount }
            let followingWords = sentences[boundary..<sentences.count]
                .reduce(0) { $0 + $1.wordCount }
            if precedingWords >= 20,
               followingWords >= 18,
               beginsWithTopicTransition(sentences[boundary].text, language: language) {
                return boundary
            }
        }

        if remainingWords >= 70, paragraphStart + 3 < sentences.count {
            for boundary in (paragraphStart + 2)...(sentences.count - 2) {
                let precedingWords = sentences[paragraphStart..<boundary]
                    .reduce(0) { $0 + $1.wordCount }
                let followingWords = sentences[boundary..<sentences.count]
                    .reduce(0) { $0 + $1.wordCount }
                if precedingWords >= 24,
                   followingWords >= 24,
                   hasCohesiveTopicShift(in: sentences, at: boundary) {
                    return boundary
                }
            }
        }

        guard remainingWords >= 85 else { return nil }
        let readableTarget = 70
        var bestBoundary: Int?
        var bestDistance = Int.max
        for boundary in (paragraphStart + 1)..<sentences.count {
            let precedingWords = sentences[paragraphStart..<boundary]
                .reduce(0) { $0 + $1.wordCount }
            let followingWords = remainingWords - precedingWords
            guard precedingWords >= 20, followingWords >= 20 else { continue }
            let distance = abs(readableTarget - precedingWords)
            if distance < bestDistance {
                bestDistance = distance
                bestBoundary = boundary
            }
        }
        return bestBoundary
    }

    private static func sentenceUnits(
        in paragraph: String,
        language: RecognitionLanguage
    ) -> [SentenceUnit] {
        var result: [SentenceUnit] = []
        let ignoredWords = stopWords(for: language)
        paragraph.enumerateSubstrings(
            in: paragraph.startIndex..<paragraph.endIndex,
            options: .bySentences
        ) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty
            else { return }
            let words = words(in: sentence)
            result.append(SentenceUnit(
                text: sentence,
                wordCount: words.count,
                contentWords: Set(words.filter { !ignoredWords.contains($0) })
            ))
        }
        return result
    }

    private static func hasCohesiveTopicShift(
        in sentences: [SentenceUnit],
        at boundary: Int
    ) -> Bool {
        guard boundary >= 2, boundary + 1 < sentences.count else { return false }
        let previousFirst = sentences[boundary - 2].contentWords
        let previousSecond = sentences[boundary - 1].contentWords
        let nextFirst = sentences[boundary].contentWords
        let nextSecond = sentences[boundary + 1].contentWords
        guard previousFirst.count >= 3,
              previousSecond.count >= 3,
              nextFirst.count >= 3,
              nextSecond.count >= 3,
              !previousFirst.isDisjoint(with: previousSecond),
              !nextFirst.isDisjoint(with: nextSecond)
        else { return false }

        let previousTopic = previousFirst.union(previousSecond)
        let nextTopic = nextFirst.union(nextSecond)
        return previousTopic.isDisjoint(with: nextTopic)
    }

    private static func beginsWithTopicTransition(
        _ sentence: String,
        language: RecognitionLanguage
    ) -> Bool {
        let dutch = [
            "allereerst", "om te beginnen", "vervolgens", "daarna",
            "daarnaast", "overigens", "wat betreft", "een ander punt",
            "het volgende punt", "dan is er nog", "aan de andere kant",
            "nu over", "dan nog iets anders", "ten slotte", "tot slot",
            "wat ik ook wil toevoegen", "wat ik verder wil bespreken",
        ]
        let english = [
            "first of all", "to begin with", "next", "after that",
            "additionally", "furthermore", "as for", "regarding",
            "another point", "the next point", "there is also",
            "on the other hand", "now about", "moving on", "finally",
            "lastly", "what i also want to add", "what i want to discuss next",
        ]
        let markers: [String] = {
            switch language {
            case .dutch: dutch
            case .english: english
            case .automatic: dutch + english
            }
        }()
        var normalized = sentence
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'“”‘’()[]{}"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let connectors: [String] = switch language {
        case .dutch: ["en", "maar", "dus"]
        case .english: ["and", "but", "so"]
        case .automatic: ["en", "maar", "dus", "and", "but", "so"]
        }
        for connector in connectors where normalized.hasPrefix(connector + " ") {
            normalized.removeFirst(connector.count + 1)
            break
        }
        return markers.contains { marker in
            normalized == marker
                || normalized.hasPrefix(marker + " ")
                || normalized.hasPrefix(marker + ",")
                || normalized.hasPrefix(marker + ":")
        }
    }

    private static func words(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}][\p{L}\p{N}’'\-]*"#
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        }
    }

    private static func stopWords(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = [
            "aan", "als", "bij", "dan", "dat", "de", "deze", "die", "dit",
            "door", "dus", "een", "en", "er", "geen", "heb", "hebben", "heeft",
            "het", "hij", "hoe", "hun", "ik", "in", "is", "je", "jij", "kan",
            "kunnen", "maar", "met", "mijn", "moet", "naar", "niet", "nog", "nu",
            "of", "om", "onze", "ook", "op", "over", "te", "van", "voor", "was",
            "we", "wel", "wij", "wil", "worden", "wordt", "zijn", "zij", "zou",
        ]
        let english: Set<String> = [
            "a", "about", "also", "am", "an", "and", "are", "as", "at", "be",
            "been", "but", "by", "can", "could", "did", "do", "does", "for",
            "from", "had", "has", "have", "he", "her", "his", "how", "i", "if",
            "in", "is", "it", "its", "me", "my", "no", "not", "of", "on", "or",
            "our", "she", "should", "so", "that", "the", "their", "them", "then",
            "there", "these", "they", "this", "to", "was", "we", "were", "what",
            "when", "where", "which", "who", "will", "with", "would", "you", "your",
        ]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    private static func join(_ sentences: ArraySlice<SentenceUnit>) -> String {
        sentences.map(\.text).joined(separator: " ")
    }
}
