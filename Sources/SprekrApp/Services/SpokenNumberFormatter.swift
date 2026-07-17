import Foundation

/// Deterministically converts spoken cardinal numbers into locale-appropriate
/// digits. This is direct dictation input, so it is intentionally independent
/// of Smart formatting.
enum SpokenNumberFormatter {
    private enum Lexeme: Equatable {
        case value(Int64)
        case hundred
        case scale(Int64)
        case conjunction
        case decimal
        case negative
    }

    private struct WordToken {
        let range: NSRange
        let original: String
        let folded: String
        let lexemes: [Lexeme]
    }

    private struct ParsedNumber {
        let value: Int64
        let fraction: String?
        let isNegative: Bool
    }

    private struct Replacement {
        let range: NSRange
        let text: String
    }

    private static let protectedContextCues = [
        "telefoonnummer", "phone number", "pincode", "pin code", "postcode",
        "postal code", "zip code", "security code", "beveiligingscode", "code",
        "ip adres", "ip address", "versie", "version", "datum", "date",
        "rekeningnummer", "account number",
    ]

    static func format(
        _ transcript: String,
        spokenLanguage: RecognitionLanguage,
        outputLanguage: RecognitionLanguage
    ) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let locale = resolvedOutputLanguage(outputLanguage, fallback: spokenLanguage)
        let words = wordTokens(in: trimmed, language: spokenLanguage)
        let replacements = wordReplacements(
            in: trimmed,
            tokens: words,
            spokenLanguage: spokenLanguage,
            outputLanguage: locale
        )

        var result = trimmed
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement.text)
        }
        return normalizeWrittenNumbers(in: result, outputLanguage: locale)
    }

    private static func resolvedOutputLanguage(
        _ output: RecognitionLanguage,
        fallback: RecognitionLanguage
    ) -> RecognitionLanguage {
        if output != .automatic { return output }
        return fallback == .automatic ? .dutch : fallback
    }

    private static func wordTokens(
        in text: String,
        language: RecognitionLanguage
    ) -> [WordToken] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}][\p{L}’']*"#,
            options: [.useUnicodeWordBoundaries]
        ) else { return [] }
        let source = text as NSString
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            let original = source.substring(with: match.range)
            let folded = original.numberFolded
            guard let lexemes = lexemes(for: folded, language: language) else { return nil }
            return WordToken(range: match.range, original: original, folded: folded, lexemes: lexemes)
        }
    }

    private static func wordReplacements(
        in text: String,
        tokens: [WordToken],
        spokenLanguage: RecognitionLanguage,
        outputLanguage: RecognitionLanguage
    ) -> [Replacement] {
        guard !tokens.isEmpty else { return [] }
        let source = text as NSString
        var replacements: [Replacement] = []
        var index = 0

        while index < tokens.count {
            var runEnd = index
            while runEnd + 1 < tokens.count {
                let gapStart = NSMaxRange(tokens[runEnd].range)
                let gapEnd = tokens[runEnd + 1].range.location
                guard gapEnd >= gapStart else { break }
                let gap = source.substring(with: NSRange(location: gapStart, length: gapEnd - gapStart))
                guard gap.range(of: #"^[ \t-]+$"#, options: .regularExpression) != nil else { break }
                runEnd += 1
            }

            var accepted: (end: Int, parsed: ParsedNumber)?
            if !startsWithConnector(tokens[index].lexemes) {
                let fullCandidate = Array(tokens[index...runEnd])
                let fullLexemes = fullCandidate.flatMap(\.lexemes)
                var previousWasScale = false
                let hasStackedScales = fullLexemes.contains { lexeme in
                    defer {
                        switch lexeme {
                        case .scale:
                            previousWasScale = true
                        case .value, .hundred, .conjunction, .decimal, .negative:
                            previousWasScale = false
                        }
                    }
                    if case .scale = lexeme { return previousWasScale }
                    return false
                }
                if hasStackedScales, parse(fullCandidate) == nil {
                    // Never turn just the valid prefix of an overflowing or
                    // otherwise unsupported stacked-scale phrase into digits.
                    index = runEnd + 1
                    continue
                }
                for end in stride(from: runEnd, through: index, by: -1) {
                    let candidate = Array(tokens[index...end])
                    guard let parsed = parse(candidate),
                          safeNumberSpan(candidate, allTokens: tokens, in: text)
                    else { continue }
                    accepted = (end, parsed)
                    break
                }
            }

            if let accepted {
                let range = NSRange(
                    location: tokens[index].range.location,
                    length: NSMaxRange(tokens[accepted.end].range) - tokens[index].range.location
                )
                replacements.append(Replacement(
                    range: range,
                    text: render(accepted.parsed, language: outputLanguage)
                ))
                index = accepted.end + 1
            } else {
                index += 1
            }
        }
        return replacements
    }

    private static func startsWithConnector(_ lexemes: [Lexeme]) -> Bool {
        lexemes.first == .conjunction || lexemes.first == .decimal
    }

    private static func parse(_ tokens: [WordToken]) -> ParsedNumber? {
        var lexemes = tokens.flatMap(\.lexemes)
        var isNegative = false
        if lexemes.first == .negative {
            isNegative = true
            lexemes.removeFirst()
        }
        guard !lexemes.isEmpty, !lexemes.contains(.negative) else { return nil }

        if let decimalIndex = lexemes.firstIndex(of: .decimal) {
            guard lexemes.lastIndex(of: .decimal) == decimalIndex else { return nil }
            let integerLexemes = Array(lexemes[..<decimalIndex])
            let fractionLexemes = Array(lexemes[lexemes.index(after: decimalIndex)...])
            guard let integer = parseInteger(integerLexemes),
                  let fraction = parseFraction(fractionLexemes)
            else { return nil }
            return ParsedNumber(value: integer, fraction: fraction, isNegative: isNegative)
        }

        guard let integer = parseInteger(lexemes) else { return nil }
        return ParsedNumber(value: integer, fraction: nil, isNegative: isNegative)
    }

    private static func parseInteger(_ lexemes: [Lexeme]) -> Int64? {
        guard !lexemes.isEmpty,
              lexemes.first != .conjunction,
              lexemes.last != .conjunction
        else { return nil }

        var total: Int64 = 0
        var group: [Lexeme] = []
        var previousScale = Int64.max

        for lexeme in lexemes {
            if case let .scale(scale) = lexeme {
                guard scale < previousScale,
                      let multiplier = group.isEmpty ? 1 : parseSubThousand(group),
                      multiplier > 0,
                      multiplier <= Int64.max / scale,
                      total <= Int64.max - multiplier * scale
                else { return nil }
                total += multiplier * scale
                previousScale = scale
                group.removeAll(keepingCapacity: true)
            } else {
                guard lexeme != .decimal, lexeme != .negative else { return nil }
                group.append(lexeme)
            }
        }

        guard let remainder = group.isEmpty ? 0 : parseSubThousand(group),
              total <= Int64.max - remainder
        else { return nil }
        return total + remainder
    }

    private static func parseSubThousand(_ lexemes: [Lexeme]) -> Int64? {
        let hundredIndices = lexemes.indices.filter { lexemes[$0] == .hundred }
        guard hundredIndices.count <= 1 else { return nil }
        if let hundredIndex = hundredIndices.first {
            let prefix = Array(lexemes[..<hundredIndex])
            var suffix = Array(lexemes[lexemes.index(after: hundredIndex)...])
            if suffix.first == .conjunction { suffix.removeFirst() }
            let multiplier: Int64
            if prefix.isEmpty {
                multiplier = 1
            } else {
                guard let parsedPrefix = parseBelowHundred(prefix), (1...99).contains(parsedPrefix) else {
                    return nil
                }
                multiplier = parsedPrefix
            }
            guard suffix.isEmpty || suffix.first != .conjunction,
                  let remainder = suffix.isEmpty ? 0 : parseBelowHundred(suffix),
                  multiplier <= Int64.max / 100
            else { return nil }
            return multiplier * 100 + remainder
        }
        return parseBelowHundred(lexemes)
    }

    private static func parseBelowHundred(_ lexemes: [Lexeme]) -> Int64? {
        func value(_ lexeme: Lexeme) -> Int64? {
            if case let .value(number) = lexeme { return number }
            return nil
        }

        switch lexemes.count {
        case 1:
            guard let number = value(lexemes[0]), (0...99).contains(number) else { return nil }
            return number
        case 2:
            guard let first = value(lexemes[0]), let second = value(lexemes[1]) else { return nil }
            if first >= 20, first.isMultiple(of: 10), (1...9).contains(second) { return first + second }
            return nil
        case 3:
            guard lexemes[1] == .conjunction,
                  let first = value(lexemes[0]), let third = value(lexemes[2])
            else { return nil }
            if (1...9).contains(first), third >= 20, third.isMultiple(of: 10) { return first + third }
            if first >= 20, first.isMultiple(of: 10), (1...9).contains(third) { return first + third }
            return nil
        default:
            return nil
        }
    }

    private static func parseFraction(_ lexemes: [Lexeme]) -> String? {
        guard !lexemes.isEmpty,
              !lexemes.contains(.hundred),
              !lexemes.contains(where: {
                  if case .scale = $0 { return true }
                  return $0 == .decimal || $0 == .negative
              })
        else { return nil }

        let withoutConjunctions = lexemes.filter { $0 != .conjunction }
        let individualDigits = withoutConjunctions.compactMap { lexeme -> Int64? in
            guard case let .value(value) = lexeme, (0...9).contains(value) else { return nil }
            return value
        }
        if individualDigits.count == withoutConjunctions.count {
            return individualDigits.map(String.init).joined()
        }
        guard let value = parseBelowHundred(lexemes), value >= 0 else { return nil }
        return String(value)
    }

    private static func safeNumberSpan(
        _ candidate: [WordToken],
        allTokens: [WordToken],
        in text: String
    ) -> Bool {
        guard let first = candidate.first, let last = candidate.last else { return false }
        let source = text as NSString
        let contextStart = max(0, first.range.location - 28)
        let contextEnd = min(source.length, NSMaxRange(last.range) + 28)
        let context = source.substring(with: NSRange(
            location: contextStart,
            length: contextEnd - contextStart
        )).numberFolded
        let sentence = sentenceContext(containing: first.range.location, in: source).numberFolded

        if protectedContextCues.contains(where: sentence.contains) { return false }

        let protectedIdioms = [
            "een voor een", "een van de", "het een en het ander", "op een dag", "een paar",
            "one by one", "one of the", "the one", "one another",
        ]
        if protectedIdioms.contains(where: context.contains) { return false }

        let immediatePrefix = source.substring(with: NSRange(
            location: max(0, first.range.location - 40),
            length: first.range.location - max(0, first.range.location - 40)
        )).numberFolded
        let immediateSuffix = source.substring(with: NSRange(
            location: NSMaxRange(last.range),
            length: min(source.length, NSMaxRange(last.range) + 18) - NSMaxRange(last.range)
        )).numberFolded
        let months = [
            "januari", "februari", "maart", "april", "mei", "juni", "juli",
            "augustus", "september", "oktober", "november", "december",
            "january", "february", "march", "april", "may", "june", "july",
            "august", "september", "october", "november", "december",
        ]
        let monthPattern = months.joined(separator: "|")
        if immediateSuffix.range(
            of: #"^(?:\#(monthPattern))\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil || immediatePrefix.range(
            of: #"\b(?:\#(monthPattern))$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil || monthStartsNumericDate(in: immediatePrefix, monthPattern: monthPattern) {
            return false
        }
        if immediatePrefix.range(of: #"(?:\bom|\bat)$"#, options: .regularExpression) != nil,
           immediateSuffix.range(of: #"^(?:uur|o'clock)\b"#, options: .regularExpression) != nil {
            return false
        }

        if candidate.count == 1,
           first.folded == "een",
           !hasAcuteOne(first.original),
           !unaccentedOneHasNumericContext(first, allTokens: allTokens, in: text) {
            return false
        }

        if candidate.count == 1, first.folded == "a" { return false }
        return true
    }

    private static func monthStartsNumericDate(
        in prefix: String,
        monthPattern: String
    ) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:^|\s)(?:\#(monthPattern))\s+([\p{L}\s-]+)$"#,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        ), let match = expression.firstMatch(
            in: prefix,
            range: NSRange(prefix.startIndex..., in: prefix)
        ) else { return false }

        let continuation = (prefix as NSString).substring(with: match.range(at: 1))
            .replacingOccurrences(of: "-", with: " ")
        return continuation.split(whereSeparator: { $0.isWhitespace }).allSatisfy { word in
            guard let pieces = lexemes(for: String(word), language: .automatic) else { return false }
            return pieces.allSatisfy { lexeme in
                switch lexeme {
                case .value, .hundred, .scale, .conjunction:
                    return true
                case .decimal, .negative:
                    return false
                }
            }
        }
    }

    private static func unaccentedOneHasNumericContext(
        _ token: WordToken,
        allTokens: [WordToken],
        in text: String
    ) -> Bool {
        let source = text as NSString
        let prefixStart = max(0, token.range.location - 18)
        let prefix = source.substring(with: NSRange(
            location: prefixStart,
            length: token.range.location - prefixStart
        )).numberFolded
        let suffixEnd = min(source.length, NSMaxRange(token.range) + 18)
        let suffix = source.substring(with: NSRange(
            location: NSMaxRange(token.range),
            length: suffixEnd - NSMaxRange(token.range)
        )).numberFolded

        let cues = ["punt", "nummer", "getal", "alinea", "point", "number", "paragraph"]
        if cues.contains(where: { prefix.range(of: #"\b\#($0)$"#, options: .regularExpression) != nil }) {
            return true
        }
        let units = [
            "euro", "dollar", "pond", "yen", "procent", "percent", "meter", "kilometer",
            "centimeter", "millimeter", "kilo", "gram", "liter", "jaar", "year", "maand",
            "month", "week", "dag", "day", "uur", "hour", "minuut", "minute", "seconde",
            "second", "graad", "graden", "degree", "degrees",
        ]
        if units.contains(where: { suffix.range(of: #"^\#($0)\b"#, options: .regularExpression) != nil }) {
            return true
        }

        guard let index = allTokens.firstIndex(where: { $0.range == token.range }) else { return false }
        if index > 0,
           isValueBearing(allTokens[index - 1]),
           containsOnlySequenceSeparators(
               source.substring(with: NSRange(
                   location: NSMaxRange(allTokens[index - 1].range),
                   length: token.range.location - NSMaxRange(allTokens[index - 1].range)
               ))
           ) { return true }
        if index + 1 < allTokens.count,
           isValueBearing(allTokens[index + 1]),
           containsOnlySequenceSeparators(
               source.substring(with: NSRange(
                   location: NSMaxRange(token.range),
                   length: allTokens[index + 1].range.location - NSMaxRange(token.range)
               ))
           ) { return true }
        return false
    }

    private static func isValueBearing(_ token: WordToken) -> Bool {
        token.lexemes.contains { lexeme in
            if case .value = lexeme { return true }
            if case .hundred = lexeme { return true }
            if case .scale = lexeme { return true }
            return false
        }
    }

    private static func containsOnlySequenceSeparators(_ value: String) -> Bool {
        value.range(of: #"^[ \t,;:-]*(?:(?:en|and)[ \t]*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func sentenceContext(containing location: Int, in source: NSString) -> String {
        var start = location
        while start > 0 {
            let character = source.character(at: start - 1)
            if character == 46 || character == 33 || character == 63 || character == 10 { break }
            start -= 1
        }
        var end = location
        while end < source.length {
            let character = source.character(at: end)
            if character == 46 || character == 33 || character == 63 || character == 10 { break }
            end += 1
        }
        return source.substring(with: NSRange(location: start, length: end - start))
    }

    private static func hasAcuteOne(_ value: String) -> Bool {
        value.lowercased().contains("é") || value.unicodeScalars.contains { scalar in
            scalar.value == 0x301
        }
    }

    private static func render(_ parsed: ParsedNumber, language: RecognitionLanguage) -> String {
        let groupingSeparator = language == .english ? "," : "."
        let decimalSeparator = language == .english ? "." : ","
        let digits = groupedDigits(parsed.value.magnitude, separator: groupingSeparator)
        let sign = parsed.isNegative && (parsed.value != 0 || parsed.fraction != nil) ? "-" : ""
        if let fraction = parsed.fraction {
            return sign + digits + decimalSeparator + fraction
        }
        return sign + digits
    }

    private static func groupedDigits(_ value: UInt64, separator: String) -> String {
        let digits = String(value)
        guard digits.count >= 5 else { return digits }
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.append(digits[start..<end])
            end = start
        }
        return groups.reversed().joined(separator: separator)
    }

    private static func normalizeWrittenNumbers(
        in text: String,
        outputLanguage: RecognitionLanguage
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_])([+-]?)(\d{5,})(?:([.,])(\d+))?(?![\p{L}\p{N}_])"#
        ) else { return text }
        let source = text as NSString
        var result = text
        for match in expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).reversed() {
            let sentence = sentenceContext(containing: match.range.location, in: source).numberFolded
            if protectedContextCues.contains(where: sentence.contains) { continue }
            let integer = source.substring(with: match.range(at: 2))
            guard !integer.hasPrefix("0"), let value = UInt64(integer) else { continue }
            let sign = source.substring(with: match.range(at: 1))
            let fractionRange = match.range(at: 4)
            let fraction = fractionRange.location == NSNotFound ? nil : source.substring(with: fractionRange)
            let decimal = outputLanguage == .english ? "." : ","
            var replacement = sign + groupedDigits(
                value,
                separator: outputLanguage == .english ? "," : "."
            )
            if let fraction { replacement += decimal + fraction }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func lexemes(
        for word: String,
        language: RecognitionLanguage
    ) -> [Lexeme]? {
        switch language {
        case .dutch:
            return dutchLexemes(word)
        case .english:
            return englishLexemes(word)
        case .automatic:
            return dutchLexemes(word) ?? englishLexemes(word)
        }
    }

    private static func dutchLexemes(_ word: String) -> [Lexeme]? {
        if let direct = dutchVocabulary[word] { return [direct] }
        var memo: [String: [Lexeme]?] = [:]
        func segment(_ remainder: String) -> [Lexeme]? {
            if remainder.isEmpty { return [] }
            if let cached = memo[remainder] { return cached }
            for key in dutchVocabulary.keys.sorted(by: { $0.count > $1.count }) where remainder.hasPrefix(key) {
                let suffix = String(remainder.dropFirst(key.count))
                if let tail = segment(suffix), let lexeme = dutchVocabulary[key] {
                    let result = [lexeme] + tail
                    memo[remainder] = result
                    return result
                }
            }
            memo[remainder] = nil
            return nil
        }
        return segment(word)
    }

    private static func englishLexemes(_ word: String) -> [Lexeme]? {
        englishVocabulary[word].map { [$0] }
    }

    private static let dutchVocabulary: [String: Lexeme] = [
        "nul": .value(0), "een": .value(1), "twee": .value(2), "drie": .value(3),
        "vier": .value(4), "vijf": .value(5), "zes": .value(6), "zeven": .value(7),
        "acht": .value(8), "negen": .value(9), "tien": .value(10), "elf": .value(11),
        "twaalf": .value(12), "dertien": .value(13), "veertien": .value(14),
        "vijftien": .value(15), "zestien": .value(16), "zeventien": .value(17),
        "achttien": .value(18), "negentien": .value(19), "twintig": .value(20),
        "dertig": .value(30), "veertig": .value(40), "vijftig": .value(50),
        "zestig": .value(60), "zeventig": .value(70), "tachtig": .value(80),
        "negentig": .value(90), "honderd": .hundred, "duizend": .scale(1_000),
        "miljoen": .scale(1_000_000), "miljard": .scale(1_000_000_000),
        "biljoen": .scale(1_000_000_000_000), "en": .conjunction,
        "komma": .decimal, "min": .negative, "minus": .negative,
    ]

    private static let englishVocabulary: [String: Lexeme] = [
        "zero": .value(0), "one": .value(1), "two": .value(2), "three": .value(3),
        "four": .value(4), "five": .value(5), "six": .value(6), "seven": .value(7),
        "eight": .value(8), "nine": .value(9), "ten": .value(10), "eleven": .value(11),
        "twelve": .value(12), "thirteen": .value(13), "fourteen": .value(14),
        "fifteen": .value(15), "sixteen": .value(16), "seventeen": .value(17),
        "eighteen": .value(18), "nineteen": .value(19), "twenty": .value(20),
        "thirty": .value(30), "forty": .value(40), "fifty": .value(50),
        "sixty": .value(60), "seventy": .value(70), "eighty": .value(80),
        "ninety": .value(90), "hundred": .hundred, "thousand": .scale(1_000),
        "million": .scale(1_000_000), "billion": .scale(1_000_000_000),
        "trillion": .scale(1_000_000_000_000), "and": .conjunction,
        "point": .decimal, "minus": .negative, "negative": .negative,
    ]
}

private extension String {
    var numberFolded: String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
