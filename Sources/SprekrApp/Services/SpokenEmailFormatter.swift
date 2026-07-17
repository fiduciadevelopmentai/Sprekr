import Foundation

/// Repairs high-confidence spoken email addresses after symbol commands have
/// been applied. The parser is deliberately bounded and requires either an
/// actual `@` or a narrow spoken-at variant plus a plausible dotted domain.
enum SpokenEmailFormatter {
    struct TranslationProtection: Equatable {
        struct Literal: Equatable {
            let placeholder: String
            let value: String
        }

        let text: String
        fileprivate let literals: [Literal]

        func restore(in translated: String) -> String? {
            var result = translated
            for literal in literals {
                let pieces = result.components(separatedBy: literal.placeholder)
                guard pieces.count == 2 else { return nil }
                result = pieces.joined(separator: literal.value)
            }
            return result
        }
    }

    private struct LocalCandidate {
        let range: NSRange
        let value: String
    }

    private struct DomainCandidate {
        let range: NSRange
        let value: String
    }

    private struct Replacement {
        let range: NSRange
        let value: String
    }

    private static let providers = [
        "gmail", "live", "hotmail", "outlook", "icloud", "yahoo", "protonmail", "ziggo",
    ]

    private static let providerAliases = [
        "laif": "live",
        "lijf": "live",
        "life": "live",
        "lijve": "live",
    ]

    private static let topLevelDomainAliases = [
        "om": "com",
        "kom": "com",
        "nel": "nl",
        "enel": "nl",
    ]

    static func format(_ transcript: String, language: RecognitionLanguage) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = canonicalizeExistingAddresses(in: result)
        let existingRanges = validEmailRanges(in: result)
        let cues = atCueRanges(in: result, language: language)
        guard !cues.isEmpty else { return stripTerminalPeriodFromWholeAddress(result) }

        var replacements: [Replacement] = []
        var occupied: [NSRange] = existingRanges
        let source = result as NSString

        for cue in cues {
            guard !occupied.contains(where: { rangesOverlap($0, cue) }),
                  isEligibleAtCue(cue, in: result),
                  let local = localCandidate(before: cue, in: result, language: language),
                  let domain = domainCandidate(after: cue, in: result, language: language)
            else { continue }

            var fullRange = NSRange(
                location: local.range.location,
                length: NSMaxRange(domain.range) - local.range.location
            )
            guard fullRange.length > 0,
                  !occupied.contains(where: { rangesOverlap($0, fullRange) })
            else { continue }

            let email = local.value + "@" + domain.value
            guard isValidEmail(email) else { continue }

            let prefix = source.substring(to: fullRange.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffixStart = NSMaxRange(fullRange)
            let suffix = source.substring(from: suffixStart)
            if prefix.isEmpty,
               suffix.range(of: #"^[ \t]*\.[ \t]*$"#, options: .regularExpression) != nil {
                fullRange.length = source.length - fullRange.location
            }

            replacements.append(Replacement(range: fullRange, value: email))
            occupied.append(fullRange)
        }

        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement.value)
        }

        return stripTerminalPeriodFromWholeAddress(
            canonicalizeExistingAddresses(in: result)
        )
    }

    static func validEmailRanges(in text: String) -> [NSRange] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let source = text as NSString
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            let candidate = source.substring(with: match.range)
            return isValidEmail(candidate) ? match.range : nil
        }
    }

    static func containsDictionaryRange(_ range: NSRange, inEmailWithin text: String) -> Bool {
        validEmailRanges(in: text).contains { emailRange in
            range.location >= emailRange.location && NSMaxRange(range) <= NSMaxRange(emailRange)
        }
    }

    static func protectForTranslation(_ text: String) -> TranslationProtection {
        let ranges = validEmailRanges(in: text)
        guard !ranges.isEmpty else { return TranslationProtection(text: text, literals: []) }

        let source = text as NSString
        let literals = ranges.enumerated().map { index, range in
            TranslationProtection.Literal(
                placeholder: "\u{E200}KTEMAIL\(index)\u{E201}",
                value: source.substring(with: range)
            )
        }
        var protected = text
        for (range, literal) in zip(ranges, literals).reversed() {
            guard let swiftRange = Range(range, in: protected) else { continue }
            protected.replaceSubrange(swiftRange, with: literal.placeholder)
        }
        return TranslationProtection(text: protected, literals: literals)
    }

    private static func canonicalizeExistingAddresses(in text: String) -> String {
        let source = text as NSString
        var result = text
        for range in validEmailRanges(in: text).reversed() {
            let lowercased = source.substring(with: range).lowercased()
            guard let swiftRange = Range(range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: lowercased)
        }
        return result
    }

    private static func stripTerminalPeriodFromWholeAddress(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".") else { return trimmed }
        let withoutPeriod = String(trimmed.dropLast())
        let ranges = validEmailRanges(in: withoutPeriod)
        guard ranges.count == 1,
              ranges[0].location == 0,
              ranges[0].length == (withoutPeriod as NSString).length
        else { return trimmed }
        return withoutPeriod
    }

    private static func atCueRanges(
        in text: String,
        language: RecognitionLanguage
    ) -> [NSRange] {
        let dutch = [
            "apenstaartje", "apen staartje", "apestaartje", "apenstaart",
            "abstartje", "at teken", "at-teken",
        ]
        let english = ["at sign"]
        let aliases: [String] = switch language {
        case .dutch: dutch
        case .english: english
        case .automatic: dutch + english
        }
        let alternatives = aliases.map(aliasPattern).joined(separator: "|")
        let pattern = alternatives.isEmpty
            ? #"@"#
            : #"@|(?<![\p{L}\p{N}_])(?:\#(alternatives))(?![\p{L}\p{N}_])"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        ) else { return [] }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).map(\.range)
    }

    private static func localCandidate(
        before cue: NSRange,
        in text: String,
        language: RecognitionLanguage
    ) -> LocalCandidate? {
        let source = text as NSString
        guard cue.location > 0 else { return nil }
        let rawPrefix = source.substring(to: cue.location)
        var windowStart = lastLocalBoundary(in: rawPrefix)
        windowStart = max(windowStart, lastEmailLeadInEnd(in: rawPrefix, language: language))

        let windowRange = NSRange(location: windowStart, length: cue.location - windowStart)
        let window = source.substring(with: windowRange)
        guard !window.contains("@"), let expression = localTokenExpression else { return nil }
        var matches = expression.matches(
            in: window,
            range: NSRange(window.startIndex..., in: window)
        )
        guard !matches.isEmpty else { return nil }

        let windowSource = window as NSString
        let contentIndices = matches.indices.filter { index in
            !isLocalSeparatorToken(windowSource.substring(with: matches[index].range))
        }
        guard !contentIndices.isEmpty else { return nil }
        if contentIndices.count > 6 {
            let firstKept = contentIndices[contentIndices.count - 6]
            matches = Array(matches[firstKept...])
        }

        guard let first = matches.first, let last = matches.last else { return nil }
        var cursor = first.range.location
        for match in matches {
            guard match.range.location >= cursor else { return nil }
            let gap = windowSource.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            guard gap.range(of: #"^[ \t]*$"#, options: .regularExpression) != nil else {
                return nil
            }
            cursor = NSMaxRange(match.range)
        }
        let trailing = windowSource.substring(from: NSMaxRange(last.range))
        guard trailing.range(of: #"^[ \t,]*$"#, options: .regularExpression) != nil else {
            return nil
        }

        var local = ""
        for match in matches {
            let token = windowSource.substring(with: match.range)
            if let separator = localSeparator(for: token) {
                local.append(separator)
            } else {
                local += asciiFolded(token)
            }
        }
        guard isValidLocalPart(local) else { return nil }

        let globalStart = windowStart + first.range.location
        return LocalCandidate(
            range: NSRange(location: globalStart, length: cue.location - globalStart),
            value: local
        )
    }

    private static func domainCandidate(
        after cue: NSRange,
        in text: String,
        language: RecognitionLanguage
    ) -> DomainCandidate? {
        let source = text as NSString
        let start = NSMaxRange(cue)
        guard start < source.length else { return nil }
        let suffix = source.substring(from: start)

        let label = #"[\p{L}\p{N}]+(?:[ \t]*(?:-|streepje|koppelteken|hyphen|dash)[ \t]*[\p{L}\p{N}]+|[ \t]+[\p{L}\p{N}]+){0,2}?"#
        let patterns = [
            #"^[ \t]*(\#(label))[ \t]+(?:punt|puntje|dot)[ \t-]*([\p{L}]{2,24})\b"#,
            #"^[ \t]*(\#(label))[ \t]*\.[ \t]*([\p{L}]{2,24})\b"#,
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .useUnicodeWordBoundaries]
            ), let match = expression.firstMatch(
                in: suffix,
                range: NSRange(suffix.startIndex..., in: suffix)
            ), match.numberOfRanges >= 3
            else { continue }

            let suffixSource = suffix as NSString
            guard let normalizedLabel = normalizeDomainLabel(
                suffixSource.substring(with: match.range(at: 1))
            ), let normalizedTLD = normalizeTopLevelDomains(
                suffixSource.substring(with: match.range(at: 2))
            ) else { continue }

            let domain = correctedProvider(normalizedLabel) + "." + normalizedTLD
            guard isValidDomain(domain) else { continue }
            return DomainCandidate(
                range: NSRange(location: start, length: match.range.length),
                value: domain
            )
        }
        return nil
    }

    private static func lastLocalBoundary(in prefix: String) -> Int {
        guard let expression = try? NSRegularExpression(
            pattern: #"[!?;:\n]|\.(?=[ \t]+\p{Lu})"#
        ) else { return 0 }
        return expression.matches(
            in: prefix,
            range: NSRange(prefix.startIndex..., in: prefix)
        ).last.map { NSMaxRange($0.range) } ?? 0
    }

    private static func isEligibleAtCue(_ cue: NSRange, in text: String) -> Bool {
        let source = text as NSString
        guard source.substring(with: cue) == "@" else { return true }

        // A literal @ inside an already valid address is handled before this
        // check. For a repaired spoken address, require separation on the
        // domain side; `@username` and `@username.example` remain social text.
        let next = NSMaxRange(cue)
        guard next < source.length else { return false }
        return source.substring(with: NSRange(location: next, length: 1))
            .rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func lastEmailLeadInEnd(
        in prefix: String,
        language: RecognitionLanguage
    ) -> Int {
        let dutch = #"(?:\b(?:e-?mail(?:adres)?|mailadres|adres)\b[ \t]*(?:is|wordt)?[ \t]+|\b(?:naar|via)[ \t]+)"#
        let english = #"(?:\b(?:e-?mail[ \t]+address|email|address)\b[ \t]*(?:is)?[ \t]+|\b(?:to|via)[ \t]+)"#
        let pattern: String = switch language {
        case .dutch: dutch
        case .english: english
        case .automatic: "(?:\(dutch)|\(english))"
        }
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        ) else { return 0 }
        return expression.matches(
            in: prefix,
            range: NSRange(prefix.startIndex..., in: prefix)
        ).last.map { NSMaxRange($0.range) } ?? 0
    }

    private static var localTokenExpression: NSRegularExpression? {
        try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}]+|[._+'-]"#,
            options: [.useUnicodeWordBoundaries]
        )
    }

    private static func isLocalSeparatorToken(_ token: String) -> Bool {
        localSeparator(for: token) != nil
    }

    private static func localSeparator(for token: String) -> Character? {
        switch asciiFolded(token) {
        case ".", "punt", "puntje", "dot": "."
        case "-", "streepje", "koppelteken", "hyphen", "dash": "-"
        case "_", "underscore": "_"
        case "+", "plus", "plusteken": "+"
        case "'", "apostrof", "apostrophe": "'"
        default: nil
        }
    }

    private static func normalizeDomainLabel(_ value: String) -> String? {
        guard let expression = localTokenExpression else { return nil }
        let source = value as NSString
        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        guard !matches.isEmpty else { return nil }

        var result = ""
        for match in matches {
            let token = source.substring(with: match.range)
            let folded = asciiFolded(token)
            switch folded {
            case "-", "streepje", "koppelteken", "hyphen", "dash":
                result.append("-")
            default:
                result += folded
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func normalizeTopLevelDomains(_ value: String) -> String? {
        let components = value
            .split(separator: ".")
            .map { asciiFolded(String($0)) }
        guard !components.isEmpty else { return nil }
        let normalized = components.map { topLevelDomainAliases[$0] ?? $0 }
        guard normalized.allSatisfy({ component in
            (2...24).contains(component.count) && component.allSatisfy(\.isLetter)
        }) else { return nil }
        return normalized.joined(separator: ".")
    }

    private static func correctedProvider(_ value: String) -> String {
        if let alias = providerAliases[value] { return alias }
        guard !value.contains("-"), value.count >= 5 else { return value }
        let matches = providers.compactMap { provider -> (String, Int)? in
            let distance = editDistance(value, provider, limit: 1)
            return distance <= 1 ? (provider, distance) : nil
        }
        guard let best = matches.map(\.1).min() else { return value }
        let winners = matches.filter { $0.1 == best }.map(\.0)
        return winners.count == 1 ? winners[0] : value
    }

    private static func isValidEmail(_ value: String) -> Bool {
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        return isValidLocalPart(String(pieces[0])) && isValidDomain(String(pieces[1]))
    }

    private static func isValidLocalPart(_ value: String) -> Bool {
        let normalized = value.lowercased()
        guard (1...64).contains(normalized.count),
              normalized.first != ".",
              normalized.last != ".",
              !normalized.contains("..")
        else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+-/=?^_`{|}~")
        return normalized.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidDomain(_ value: String) -> Bool {
        guard value.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              let tld = labels.last,
              (2...24).contains(tld.count),
              tld.allSatisfy(\.isLetter)
        else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count),
                  label.first != "-",
                  label.last != "-"
            else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let source = Array(lhs)
        let target = Array(rhs)
        guard abs(source.count - target.count) <= limit else { return limit + 1 }
        var previous = Array(0...target.count)
        for sourceIndex in 1...source.count {
            var current = Array(repeating: 0, count: target.count + 1)
            current[0] = sourceIndex
            for targetIndex in 1...target.count {
                current[targetIndex] = min(
                    previous[targetIndex] + 1,
                    current[targetIndex - 1] + 1,
                    previous[targetIndex - 1]
                        + (source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[target.count]
    }

    private static func aliasPattern(_ alias: String) -> String {
        alias.split { $0 == " " || $0 == "-" }
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"[ \t-]+"#)
    }

    private static func asciiFolded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }
}
