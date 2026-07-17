import Foundation

/// A conservative second-pass repair for repetition-heavy speech. It focuses
/// on the lexical "rough copy" left by sound, word, and short phrase repeats.
/// Common deliberate emphasis and grammatically meaningful doubles stay intact.
enum StutterCleanupFormatter {
    static func clean(_ text: String, language: RecognitionLanguage) -> String {
        var result = collapseEscalatingPartialWordRestarts(in: text)
        result = collapsePartialWordRestarts(in: result)
        result = replaceHesitatedAlternativeRestart(in: result, language: language)
        result = mergeQuestionBoundaryRestarts(in: result, language: language)
        result = collapseRepeatedWordRuns(in: result, language: language)
        return result
    }

    /// Parakeet can turn one progressively completed word into several words
    /// and even insert sentence punctuation between them: `Wa waar? Waarom`
    /// is one false start, not three questions. Requiring three strictly
    /// growing prefixes keeps a genuine transition such as `Waar? Waarom ...`
    /// untouched while repairing this high-confidence stutter shape.
    private static func collapseEscalatingPartialWordRestarts(in text: String) -> String {
        let ranges = wordRanges(in: text)
        guard ranges.count >= 3 else { return text }

        var repairs: [(range: NSRange, replacement: String)] = []
        var finalIndex = ranges.count - 1
        while finalIndex >= 2 {
            var chainStart = finalIndex
            var currentIndex = finalIndex

            while currentIndex > 0 {
                let previousRange = ranges[currentIndex - 1]
                let currentRange = ranges[currentIndex]
                let previous = String(text[previousRange]).foldedForStutterRepair
                let current = String(text[currentRange]).foldedForStutterRepair
                guard previous.count < current.count,
                      current.hasPrefix(previous),
                      isStutterSeparator(text[previousRange.upperBound..<currentRange.lowerBound])
                else { break }
                chainStart = currentIndex - 1
                currentIndex -= 1
            }

            let attemptCount = finalIndex - chainStart
            let first = String(text[ranges[chainStart]]).foldedForStutterRepair
            if attemptCount >= 2, (1...3).contains(first.count) {
                let repairRange = ranges[chainStart].lowerBound..<ranges[finalIndex].upperBound
                repairs.append((
                    NSRange(repairRange, in: text),
                    String(text[ranges[finalIndex]])
                ))
                finalIndex = chainStart - 1
            } else {
                finalIndex -= 1
            }
        }

        var result = text
        for repair in repairs {
            guard let range = Range(repair.range, in: result) else { continue }
            result.replaceSubrange(range, with: repair.replacement)
        }
        return result
    }

    /// A spoken false start can arrive as `…, of en <same opening again>`.
    /// Requiring the unnatural `of en` / `or and` bridge plus at least three
    /// repeated lexical words distinguishes it from a genuine alternative.
    private static func replaceHesitatedAlternativeRestart(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let bridge: String = switch language {
        case .dutch: #"of[ \t]+en"#
        case .english: #"or[ \t]+and"#
        case .automatic: #"(?:of[ \t]+en|or[ \t]+and)"#
        }
        guard let expression = try? NSRegularExpression(
            pattern: #"([^.!?\n]{2,240}),[ \t]*(?:\#(bridge))[ \t]+([^.!?\n]{2,220})([.!?]?)"#,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let leftRange = Range(match.range(at: 1), in: result),
                  let rightRange = Range(match.range(at: 2), in: result)
            else { continue }

            let left = String(result[leftRange])
            let right = String(result[rightRange])
            let fillers: Set<String> = ["ook", "also"]
            let leftWords = wordValues(in: left).filter { !fillers.contains($0) }
            let rightWords = wordValues(in: right).filter { !fillers.contains($0) }
            guard rightWords.count >= 3 else { continue }

            let maximum = min(6, rightWords.count)
            let hasRepeatedOpening = stride(from: maximum, through: 3, by: -1).contains { length in
                contains(Array(rightWords.prefix(length)), in: leftWords)
            }
            guard hasRepeatedOpening else { continue }

            let terminalRange = Range(match.range(at: 3), in: result)
            let terminal = terminalRange.map { String(result[$0]) } ?? ""
            let bridgeText = String(result[leftRange.upperBound..<rightRange.lowerBound])
                .foldedForStutterRepair
            let conjunction = bridgeText.contains("or") ? "and " : "en "
            result.replaceSubrange(
                fullRange,
                with: capitalizingFirstLetter(conjunction + right) + terminal
            )
        }
        return result
    }

    /// `f-f-format` / `for for format` → `format`. Requiring at least two
    /// identical fragments plus a longer word that starts with that fragment
    /// avoids treating ordinary hyphenated compounds or spelled initials as a
    /// repair.
    private static func collapsePartialWordRestarts(in text: String) -> String {
        let fragment = #"[\p{L}]{1,3}"#
        let fullWord = #"[\p{L}][\p{L}’'\-]{3,}"#
        let separator = #"(?:[ \t]*[-–—][ \t]*|[ \t]+)"#
        let pattern = #"(?<![\p{L}\p{N}])(\#(fragment))(?:\#(separator)\1){1,}\#(separator)(\#(fullWord))(?![\p{L}\p{N}])"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range, in: result),
                  let fragmentRange = Range(match.range(at: 1), in: result),
                  let wordRange = Range(match.range(at: 2), in: result)
            else { continue }

            let repeatedFragment = String(result[fragmentRange]).foldedForStutterRepair
            let finalWord = String(result[wordRange])
            guard finalWord.foldedForStutterRepair.hasPrefix(repeatedFragment) else { continue }
            result.replaceSubrange(wholeRange, with: finalWord)
        }
        return result
    }

    /// Collapses adjacent lexical echoes even when Parakeet has inserted comma
    /// or sentence punctuation between them: `hoe? Hoe? Hoe doe` → `hoe doe`,
    /// `format, format, format` → `format`, and `ik ik` → `ik`.
    private static func collapseRepeatedWordRuns(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let word = #"[\p{L}\p{N}][\p{L}\p{N}’'\-]*"#
        let separator = #"(?:[ \t]*[,;:.!?…][ \t]*|[ \t]+)"#
        let pattern = #"(?<![\p{L}\p{N}])(\#(word))(?:\#(separator)\1)+(?![\p{L}\p{N}])"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard let runRange = Range(match.range, in: result),
                  let firstRange = Range(match.range(at: 1), in: result)
            else { continue }

            let original = String(result[firstRange])
            let folded = original.foldedForStutterRepair
            let occurrenceCount = wordRanges(in: String(result[runRange])).count
            guard occurrenceCount >= 2,
                  !protectedDeliberateRepetitions(for: language).contains(folded)
            else { continue }

            // These doubles are valid constructions without punctuation, for
            // example “I had had enough” or “Ik weet dat dat werkt.” Three or
            // more copies, or a punctuated restart, remain safe to collapse.
            let run = String(result[runRange])
            let containsRepairPunctuation = run.contains { ",;:.!?…".contains($0) }
            if occurrenceCount == 2,
               !containsRepairPunctuation,
               grammaticalDoubles(for: language).contains(folded) {
                continue
            }

            if occurrenceCount == 2 {
                let containsSentenceBoundary = run.contains { ".!?…".contains($0) }
                if containsSentenceBoundary {
                    let nextCharacter = result[runRange.upperBound...]
                        .first(where: { !$0.isWhitespace })
                    let repeatedWordIsStandalone = nextCharacter.map { ".!?…".contains($0) } ?? true
                    guard repeatedWordIsStandalone
                            || likelyDisfluentSingleWords(for: language).contains(folded)
                    else { continue }
                } else if original.first?.isUppercase == true,
                          !likelyDisfluentSingleWords(for: language).contains(folded) {
                    // Repeated names and acronyms are often deliberate calls or
                    // labels, so two capitalized copies need stronger evidence.
                    continue
                }
            }

            result.replaceSubrange(runRange, with: original)
        }
        return result
    }

    /// Repairs a short question that was split at a repeated boundary word:
    /// `Hoe doe jij? Jij het volgende.` → `Hoe doe jij het volgende?`. A normal
    /// following sentence such as `Jij werkt hier.` contains its own finite
    /// verb and therefore remains separate.
    private static func mergeQuestionBoundaryRestarts(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"([^.!?\n]{1,100})\?\s+([^.!?\n]{1,70})([.!?])"#,
            options: []
        ) else { return text }

        var result = text
        for _ in 0..<4 {
            let fullRange = NSRange(result.startIndex..., in: result)
            let matches = expression.matches(in: result, range: fullRange)
            var changed = false

            for match in matches.reversed() {
                guard let wholeRange = Range(match.range, in: result),
                      let leftRange = Range(match.range(at: 1), in: result),
                      let rightRange = Range(match.range(at: 2), in: result)
                else { continue }

                let left = String(result[leftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(result[rightRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let leftWords = wordValues(in: left)
                let rightWordRanges = wordRanges(in: right)
                let rightWords = rightWordRanges.map { String(right[$0]).foldedForStutterRepair }

                guard (2...8).contains(leftWords.count),
                      (2...6).contains(rightWords.count),
                      questionStarters(for: language).contains(leftWords[0]),
                      leftWords.last == rightWords.first,
                      let firstRightRange = rightWordRanges.first
                else { continue }

                let suffix = String(right[firstRightRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffixWords = wordValues(in: suffix)
                guard !suffix.isEmpty,
                      suffixWords.allSatisfy({ !finiteVerbs(for: language).contains($0) })
                else { continue }

                let joinedSuffix = lowercasingLeadingFunctionWord(
                    in: suffix,
                    language: language
                )
                result.replaceSubrange(wholeRange, with: left + " " + joinedSuffix + "?")
                changed = true
            }

            guard changed else { break }
        }
        return result
    }

    private static func wordRanges(in value: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}][\p{L}\p{N}’'\-]*"#
        ) else { return [] }
        return expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ).compactMap { Range($0.range, in: value) }
    }

    private static func wordValues(in value: String) -> [String] {
        wordRanges(in: value).map { String(value[$0]).foldedForStutterRepair }
    }

    private static func isStutterSeparator(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isWhitespace || ",;:.!?…-–—".contains(character)
        }
    }

    private static func contains(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            Array(haystack[start..<(start + needle.count)]) == needle
        }
    }

    private static func capitalizingFirstLetter(_ value: String) -> String {
        guard let firstLetter = value.firstIndex(where: \.isLetter) else { return value }
        var result = value
        let next = result.index(after: firstLetter)
        result.replaceSubrange(firstLetter..<next, with: String(result[firstLetter]).uppercased())
        return result
    }

    private static func protectedDeliberateRepetitions(
        for language: RecognitionLanguage
    ) -> Set<String> {
        let dutch: Set<String> = [
            "heel", "echt", "erg", "zo", "nooit", "altijd", "ja", "nee", "ho", "stop",
        ]
        let english: Set<String> = [
            "very", "really", "so", "never", "always", "yes", "no", "go", "bye", "stop", "wow",
        ]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    private static func grammaticalDoubles(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = ["dat"]
        let english: Set<String> = ["that", "had", "is", "was"]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    private static func likelyDisfluentSingleWords(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = [
            "ik", "jij", "je", "u", "hij", "zij", "we", "wij", "ze", "dit", "deze", "die",
            "wie", "wat", "waar", "wanneer", "waarom", "hoe", "welke", "welk",
            "de", "het", "een", "en", "of", "maar", "als", "dan", "kan", "kun", "wil", "zou", "moet", "mag",
        ]
        let english: Set<String> = [
            "i", "you", "he", "she", "we", "they", "this", "these", "those",
            "who", "what", "where", "when", "why", "how", "which",
            "the", "a", "an", "and", "or", "but", "if", "then", "can", "could", "will", "would", "should", "may",
        ]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    private static func questionStarters(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = [
            "wie", "wat", "waar", "wanneer", "waarom", "hoe", "welke", "welk", "kan", "kun", "is", "zijn", "wil", "zou", "mag", "moet",
        ]
        let english: Set<String> = [
            "who", "what", "where", "when", "why", "how", "which", "can", "could", "is", "are", "will", "would", "should", "may",
        ]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    private static func finiteVerbs(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = [
            "ben", "bent", "is", "zijn", "was", "waren", "heb", "hebt", "heeft", "hebben", "had", "hadden",
            "doe", "doet", "doen", "kan", "kunt", "kun", "kunnen", "wil", "wilt", "willen", "zal", "zult", "zullen",
            "werk", "werkt", "werken", "maak", "maakt", "maken", "ga", "gaat", "gaan", "kom", "komt", "komen",
        ]
        let english: Set<String> = [
            "am", "are", "is", "was", "were", "have", "has", "had", "do", "does", "did", "can", "could", "will", "would", "should",
            "work", "works", "make", "makes", "go", "goes", "come", "comes", "want", "wants", "need", "needs",
        ]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    private static func lowercasingLeadingFunctionWord(
        in value: String,
        language: RecognitionLanguage
    ) -> String {
        guard let firstRange = wordRanges(in: value).first else { return value }
        let first = String(value[firstRange])
        let folded = first.foldedForStutterRepair
        let dutch: Set<String> = ["de", "het", "een", "dit", "dat", "die", "deze", "mijn", "jouw", "zijn", "haar", "ons", "onze"]
        let english: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "our"]
        let canLowercase: Bool = {
            switch language {
            case .dutch: dutch.contains(folded)
            case .english: english.contains(folded)
            case .automatic: dutch.union(english).contains(folded)
            }
        }()
        guard canLowercase else { return value }

        var result = value
        result.replaceSubrange(firstRange, with: first.lowercased())
        return result
    }
}

private extension String {
    var foldedForStutterRepair: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
