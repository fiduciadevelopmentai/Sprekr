import Foundation

/// Removes only high-confidence speech repairs. This stays deterministic and
/// fully local: no transcript is sent to a language model or cloud service.
enum SelfCorrectionFormatter {
    static func clean(_ transcript: String, language: RecognitionLanguage) -> String {
        var text = transcript
        text = normalizeKnownBrands(in: text)
        text = normalizeCommonCodeSwitches(in: text)
        text = removeTruncatedTrailingEcho(in: text)
        text = collapseExcessiveTrailingWordRun(in: text)
        text = applySpellingInstructions(in: text, language: language)
        text = collapseImmediateRestarts(in: text)
        text = applyExplicitRepairMarkers(in: text, language: language)
        text = replaceConflictingScalarClauses(in: text, language: language)
        text = StutterCleanupFormatter.clean(text, language: language)
        return text
    }

    /// Sprekr can safely know its own canonical spelling. Keep this narrow
    /// so personal names and brands remain owned by the editable Dictionary.
    private static func normalizeKnownBrands(in text: String) -> String {
        guard let exactExpression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])sprekr(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        ) else { return text }
        var result = exactExpression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "Sprekr"
        )

        // Parakeet commonly hears the stylized name as the ordinary Dutch word
        // "spreker". Correct that ambiguous form only beside an explicit app
        // noun or a high-confidence launch/use action; normal prose stays intact.
        let contextualPatterns: [(String, String)] = [
            (
                #"\b((?:open|start|gebruik|gebruiken|gebruikte|use|using|launch)[ \t]+(?:de[ \t]+)?)spreker\b"#,
                "$1Sprekr"
            ),
            (
                #"\b((?:app|applicatie|application)[ \t]+)spreker\b"#,
                "$1Sprekr"
            ),
            (
                #"\bspreker(?=[ \t-]+(?:app|applicatie|application)\b)"#,
                "Sprekr"
            ),
        ]
        for (pattern, replacement) in contextualPatterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .useUnicodeWordBoundaries]
            ) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }
        return result
    }

    /// Corrects a deliberately small set of common Dutch/English code-switch
    /// spellings. These are high-confidence orthographic fixes, not language
    /// guesses; the user's editable Dictionary still runs afterwards and can
    /// override the final preferred spelling.
    private static func normalizeCommonCodeSwitches(in text: String) -> String {
        let replacements = [
            "getweekt": "getweakt",
            "tweeken": "tweaken",
            "tweeking": "tweaking",
            "tweeked": "tweaked",
            "tweekt": "tweakt",
            "tweek": "tweak",
        ]
        var result = text

        for (source, replacement) in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            guard let expression = try? NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#,
                options: [.caseInsensitive]
            ) else { continue }

            let matches = expression.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result)
            )
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let original = String(result[range])
                result.replaceSubrange(
                    range,
                    with: preservingWordCase(of: original, in: replacement)
                )
            }
        }
        return result
    }

    /// Parakeet can occasionally end a cut-off recording with an echo such as
    /// "gehad gehad gehad geh". Two complete equal words followed by a strict
    /// prefix of that word are a strong truncation signal, so the entire noisy
    /// tail is removed. Ordinary repetitions elsewhere remain untouched.
    private static func removeTruncatedTrailingEcho(in text: String) -> String {
        let ranges = wordRanges(in: text)
        guard ranges.count >= 3,
              let fragmentRange = ranges.last
        else { return text }

        let trailing = text[fragmentRange.upperBound...]
        guard trailing.allSatisfy({ $0.isWhitespace || ".!?…".contains($0) }) else {
            return text
        }

        let fragment = String(text[fragmentRange]).foldedForRepair
        let repeatedRange = ranges[ranges.count - 2]
        let repeated = String(text[repeatedRange]).foldedForRepair
        guard !fragment.isEmpty,
              fragment.count < repeated.count,
              repeated.hasPrefix(fragment)
        else { return text }

        var firstRepeatedIndex = ranges.count - 2
        var repeatedCount = 1
        while firstRepeatedIndex > 0 {
            let candidateIndex = firstRepeatedIndex - 1
            let candidateRange = ranges[candidateIndex]
            let separator = text[candidateRange.upperBound..<ranges[firstRepeatedIndex].lowerBound]
            guard separator.allSatisfy({ $0.isWhitespace || ",;:".contains($0) }),
                  String(text[candidateRange]).foldedForRepair == repeated
            else { break }
            firstRepeatedIndex = candidateIndex
            repeatedCount += 1
        }
        guard repeatedCount >= 2 else { return text }

        let prefix = text[..<ranges[firstRepeatedIndex].lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = trailing.first(where: { ".!?…".contains($0) })
        guard let terminal else { return prefix }
        return prefix + String(terminal)
    }

    /// Without a final fragment, three or more copies of a longer word at the
    /// very end are collapsed to one. Short interjections and common emphasis
    /// words are explicitly preserved.
    private static func collapseExcessiveTrailingWordRun(in text: String) -> String {
        let word = #"[\p{L}\p{N}][\p{L}\p{N}’'\-]{3,}"#
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(\#(word))(?:[ \t,;:]+\1){2,}(?=[ \t]*[.!?…]*[ \t]*$)"#,
            options: [.caseInsensitive]
        ) else { return text }

        let protectedEmphasis: Set<String> = [
            "echt", "heel", "zeker", "very", "really", "stop", "wow",
        ]
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
              let runRange = Range(match.range, in: text),
              let wordRange = Range(match.range(at: 1), in: text)
        else { return text }

        let original = String(text[wordRange])
        guard !protectedEmphasis.contains(original.foldedForRepair) else { return text }
        var result = text
        result.replaceSubrange(runRange, with: original)
        return result
    }

    private static func preservingWordCase(of source: String, in replacement: String) -> String {
        if source == source.uppercased() {
            return replacement.uppercased()
        }
        guard source.first?.isUppercase == true,
              let first = replacement.first
        else { return replacement.lowercased() }
        return String(first).uppercased() + replacement.dropFirst().lowercased()
    }

    /// Treats a standalone phrase such as "creatives is met een K" as an
    /// editing instruction, not dictated content. It may be the final sentence
    /// or sit between two dictated sentences. The instruction is consumed only
    /// when that exact target word occurs earlier and the requested spelling
    /// can be applied without guessing its position.
    private static func applySpellingInstructions(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let instruction: String = {
            switch language {
            case .dutch:
                #"(?:is|schrijf je|spel je)[ \t]+met"#
            case .english:
                #"(?:is|is spelled|you spell)[ \t]+with"#
            case .automatic:
                #"(?:(?:is|schrijf je|spel je)[ \t]+met|(?:is|is spelled|you spell)[ \t]+with)"#
            }
        }()
        let word = #"[\p{L}][\p{L}’'\-]*"#
        let spelledLetters = #"[\p{L}](?:[ \t-]*[\p{L}]){0,3}"#
        let pattern = #"(?:^|(?<=[.!?]))[ \t]*(?:\b(?:en|and)[ \t]+)?(\#(word))[ \t]+\#(instruction)[ \t]+(?:(?:een|de|a|an|the)[ \t]+)?(?:(?:letter|letters)[ \t]+)?(\#(spelledLetters))[ \t]*(?:[.!?](?=[ \t]|$)|$)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        for _ in 0..<4 {
            let fullRange = NSRange(result.startIndex..., in: result)
            let matches = expression.matches(in: result, range: fullRange)
            var appliedInstruction = false

            for match in matches {
                guard let instructionRange = Range(match.range, in: result),
                      let targetRange = Range(match.range(at: 1), in: result),
                      let spellingRange = Range(match.range(at: 2), in: result),
                      let spelling = normalizedSpelling(String(result[spellingRange]))
                else { continue }

                let target = String(result[targetRange])
                let body = String(result[..<instructionRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty,
                      let correctedBody = replacingEarlierWord(target, with: spelling, in: body)
                else { continue }

                let continuation = String(result[instructionRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result = continuation.isEmpty
                    ? correctedBody
                    : correctedBody + " " + continuation
                appliedInstruction = true
                break
            }

            guard appliedInstruction else { break }
        }
        return result
    }

    private static func replacingEarlierWord(
        _ target: String,
        with spelling: String,
        in text: String
    ) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: target)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        ) else { return nil }

        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return nil }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let occurrence = String(result[range])
            guard let corrected = applying(spelling: spelling, to: occurrence) else {
                return nil
            }
            result.replaceSubrange(range, with: corrected)
        }
        return result
    }

    private static func applying(spelling: String, to word: String) -> String? {
        guard !spelling.isEmpty else { return nil }
        let requested = spelling.foldedForRepair

        if requested.count == 1 {
            guard let first = word.first else { return nil }
            let replacement = cased(spelling, like: first, wholeWord: word)
            return replacement + word.dropFirst()
        }

        if word.foldedForRepair.contains(requested) {
            return word
        }

        guard let requestedFirst = requested.first,
              let insertionIndex = word.firstIndex(where: {
                  String($0).foldedForRepair.first == requestedFirst
              })
        else { return nil }

        let replacement = cased(spelling, like: word[insertionIndex], wholeWord: word)
        var result = word
        let nextIndex = result.index(after: insertionIndex)
        result.replaceSubrange(insertionIndex..<nextIndex, with: replacement)
        return result
    }

    private static func normalizedSpelling(_ spoken: String) -> String? {
        let letters = spoken.filter(\.isLetter).lowercased()
        let aliases = [
            "ka": "k", "kaa": "k", "kay": "k",
            "cee": "c", "see": "c",
        ]
        let normalized = aliases[letters] ?? letters
        guard (1...4).contains(normalized.count) else { return nil }
        return normalized
    }

    private static func cased(_ spelling: String, like character: Character, wholeWord: String) -> String {
        if wholeWord == wholeWord.uppercased() {
            return spelling.uppercased()
        }
        guard character.isUppercase, let first = spelling.first else { return spelling.lowercased() }
        return String(first).uppercased() + spelling.dropFirst().lowercased()
    }

    /// "ik wil graag ik wil graag een afspraak" →
    /// "ik wil graag een afspraak". Requiring at least two repeated words
    /// avoids touching ordinary single-word emphasis. A recognizer-inserted
    /// comma or sentence stop between both rough copies is accepted as well.
    private static func collapseImmediateRestarts(in text: String) -> String {
        let word = #"[\p{L}\p{N}][\p{L}\p{N}’'\-]*"#
        let pattern = #"\b((?:\#(word)[ \t]+){1,5}\#(word))[ \t]*[,;:.!?]?[ \t]+\1\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        for _ in 0..<4 {
            let range = NSRange(result.startIndex..., in: result)
            let updated = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1"
            )
            guard updated != result else { break }
            result = updated
        }
        return result
    }

    /// Spoken repair markers make intent explicit. A short replacement keeps
    /// the stable beginning of the sentence ("Ik kom dinsdag, nee woensdag"
    /// becomes "Ik kom woensdag"); a fully restated clause replaces it.
    private static func applyExplicitRepairMarkers(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let markers: String = {
            switch language {
            case .dutch:
                #"nee|sorry|(?<!wat[ \t])ik bedoel|of beter|correctie"#
            case .english:
                #"no|sorry|(?<!what[ \t])i mean|rather|correction"#
            case .automatic:
                #"nee|no|sorry|(?<!wat[ \t])ik bedoel|(?<!what[ \t])i mean|of beter|rather|correctie|correction"#
            }
        }()
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(?:\#(markers))\b"#,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        for _ in 0..<4 {
            let fullRange = NSRange(result.startIndex..., in: result)
            guard let match = expression.firstMatch(in: result, range: fullRange),
                  let markerRange = Range(match.range, in: result)
            else { break }

            let leftBoundary = result[..<markerRange.lowerBound].lastIndex {
                ".!?\n".contains($0)
            }.map { result.index(after: $0) } ?? result.startIndex

            guard result[leftBoundary..<markerRange.lowerBound].contains(where: { $0.isLetter || $0.isNumber }) else {
                break
            }

            let rightBoundary = result[markerRange.upperBound...].firstIndex {
                ".!?\n".contains($0)
            } ?? result.endIndex
            let terminal = rightBoundary < result.endIndex ? String(result[rightBoundary]) : ""

            let left = trimmedRepairFragment(String(result[leftBoundary..<markerRange.lowerBound]))
            let right = trimmedRepairFragment(String(result[markerRange.upperBound..<rightBoundary]))
            guard !left.isEmpty, !right.isEmpty else { break }

            let merged = mergeExplicitRepair(left: left, right: right) + terminal
            let replacementEnd = rightBoundary < result.endIndex
                ? result.index(after: rightBoundary)
                : rightBoundary
            result.replaceSubrange(leftBoundary..<replacementEnd, with: merged)
        }
        return result
    }

    private static func mergeExplicitRepair(left: String, right: String) -> String {
        let leftWords = wordRanges(in: left)
        let rightWords = wordRanges(in: right)
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return right }

        let leftValues = leftWords.map { String(left[$0]).foldedForRepair }
        let rightValues = rightWords.map { String(right[$0]).foldedForRepair }
        let sharedPrefix = zip(leftValues, rightValues).prefix { $0 == $1 }.count

        if sharedPrefix >= 2 {
            return preservingInitialCapitalization(of: left, in: right)
        }

        if rightWords.count <= 4, rightWords.count < leftWords.count {
            let replacementWord = leftWords[leftWords.count - rightWords.count]
            let prefix = String(left[..<replacementWord.lowerBound])
            return prefix + right
        }

        return preservingInitialCapitalization(of: left, in: right)
    }

    /// A repeated grammatical frame followed by two different numeric values
    /// is a strong correction signal: "ik ben 20 en ik ben 18 jaar" keeps 18.
    /// Non-numeric repeated clauses remain untouched because they may be an
    /// intentional list ("ik koop appels en ik koop peren").
    private static func replaceConflictingScalarClauses(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let numberWords: String = {
            let dutch = [
                "nul", "een", "één", "twee", "drie", "vier", "vijf", "zes", "zeven", "acht", "negen",
                "tien", "elf", "twaalf", "dertien", "veertien", "vijftien", "zestien", "zeventien",
                "achttien", "negentien", "twintig", "dertig", "veertig", "vijftig", "zestig", "zeventig",
                "tachtig", "negentig", "honderd", "duizend",
            ]
            let english = [
                "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
                "hundred", "thousand",
            ]
            switch language {
            case .dutch: return dutch.joined(separator: "|")
            case .english: return english.joined(separator: "|")
            case .automatic: return (dutch + english).joined(separator: "|")
            }
        }()
        let units: String = {
            switch language {
            case .dutch:
                #"jaar|jaren|euro|procent|uur|uren|minuut|minuten|seconde|seconden|kilo|kilometer|kilometers"#
            case .english:
                #"year|years|years old|dollar|dollars|percent|hour|hours|minute|minutes|second|seconds|kilo|kilometer|kilometers"#
            case .automatic:
                #"jaar|jaren|year|years|years old|euro|dollar|dollars|procent|percent|uur|uren|hour|hours|minuut|minuten|minute|minutes|seconde|seconden|second|seconds|kilo|kilometer|kilometers"#
            }
        }()
        let word = #"[\p{L}][\p{L}’'\-]*"#
        let number = #"(?:\d+(?:[.,]\d+)?|\#(numberWords))"#
        let scalar = #"\#(number)(?:[ \t]+(?:\#(units)))?"#
        let pattern = #"\b(\#(word)(?:[ \t]+\#(word)){1,3})[ \t]+\#(scalar)[ \t]+(?:en|and|maar|but)[ \t]+\1[ \t]+(\#(scalar))\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        for _ in 0..<4 {
            let range = NSRange(result.startIndex..., in: result)
            let updated = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1 $2"
            )
            guard updated != result else { break }
            result = updated
        }
        return result
    }

    private static func trimmedRepairFragment(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",;:")
        ))
    }

    private static func wordRanges(in value: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}][\p{L}\p{N}’'\-]*"#
        ) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value)
        }
    }

    private static func preservingInitialCapitalization(of source: String, in replacement: String) -> String {
        guard source.first?.isUppercase == true,
              let first = replacement.first,
              first.isLowercase
        else { return replacement }
        return String(first).uppercased() + replacement.dropFirst()
    }
}

private extension String {
    var foldedForRepair: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
