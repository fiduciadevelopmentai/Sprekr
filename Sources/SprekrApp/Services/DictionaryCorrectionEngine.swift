import Foundation

/// Applies saved Dictionary corrections to the completed transcript in one
/// deterministic pass. Exact phrases win over shorter overlaps; conservative
/// fuzzy matching is limited to single-word aliases the user has already
/// taught Sprekr.
enum DictionaryCorrectionEngine {
    struct Result: Equatable {
        let text: String
        let fixes: Int
        let entries: [DictionaryEntry]
    }

    private struct TermRule {
        let term: String
        let entryIndex: Int
    }

    private struct Replacement {
        let range: NSRange
        let entryIndex: Int
        let text: String
        let changesText: Bool
    }

    static func apply(
        entries originalEntries: [DictionaryEntry],
        to text: String,
        language: RecognitionLanguage
    ) -> Result {
        guard !text.isEmpty else {
            return Result(text: text, fixes: 0, entries: originalEntries)
        }

        var entries = originalEntries
        let eligibleIndices = entries.indices.filter {
            entries[$0].isActive && languageMatches(entries[$0].language, language)
        }
        guard !eligibleIndices.isEmpty else {
            return Result(text: text, fixes: 0, entries: entries)
        }

        let exactRules = unambiguousExactRules(entries: entries, indices: eligibleIndices)
        var replacements: [Replacement] = []
        var occupiedRanges: [NSRange] = []

        for rule in exactRules {
            for range in wholeTermRanges(of: rule.term, in: text) {
                guard !occupiedRanges.contains(where: { rangesOverlap($0, range) }),
                      !isProtectedIdentifier(range, in: text)
                else { continue }
                let preferred = replacementText(
                    entries[rule.entryIndex].preferredSpelling,
                    for: range,
                    in: text
                )
                let original = (text as NSString).substring(with: range)
                replacements.append(Replacement(
                    range: range,
                    entryIndex: rule.entryIndex,
                    text: preferred,
                    changesText: original != preferred
                ))
                occupiedRanges.append(range)
            }
        }

        for token in alphabeticTokenRanges(in: text) {
            guard !occupiedRanges.contains(where: { rangesOverlap($0, token) }),
                  !isProtectedIdentifier(token, in: text),
                  !isInsideDottedIdentifier(token, in: text)
            else { continue }
            let original = (text as NSString).substring(with: token)
            guard let entryIndex = uniqueFuzzyEntry(
                for: original,
                entries: entries,
                indices: eligibleIndices
            ) else { continue }

            let preferred = replacementText(
                entries[entryIndex].preferredSpelling,
                for: token,
                in: text
            )
            replacements.append(Replacement(
                range: token,
                entryIndex: entryIndex,
                text: preferred,
                changesText: original != preferred
            ))
            occupiedRanges.append(token)
        }

        var result = text
        var fixes = 0
        for replacement in replacements
            .filter(\.changesText)
            .sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(replacement.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement.text)
            fixes += 1
            entries[replacement.entryIndex].appliedCount += 1
        }

        return Result(text: result, fixes: fixes, entries: entries)
    }

    private static func replacementText(
        _ preferredSpelling: String,
        for range: NSRange,
        in text: String
    ) -> String {
        if SpokenEmailFormatter.containsDictionaryRange(range, inEmailWithin: text)
            || isInsideDottedIdentifier(range, in: text) {
            return preferredSpelling.lowercased()
        }
        // Sentence case has already run, so a lowercase preferred spelling
        // that replaces the capitalized first word of a sentence keeps that
        // capital. Brands with their own casing ("iPhone", "npm") are left as
        // saved.
        let source = text as NSString
        let original = source.substring(with: range)
        guard let originalFirst = original.first, originalFirst.isUppercase,
              let preferredFirst = preferredSpelling.first, preferredFirst.isLowercase,
              !preferredSpelling.dropFirst().contains(where: \.isUppercase),
              !TermLexicon.isCaseLocked(preferredSpelling),
              isSentenceStart(range, in: source)
        else { return preferredSpelling }
        return String(preferredFirst).uppercased() + preferredSpelling.dropFirst()
    }

    private static func isSentenceStart(_ range: NSRange, in source: NSString) -> Bool {
        let prefix = source.substring(to: range.location)
        return prefix.range(
            of: #"(?:^|[.!?…]|\n|•)[ \t\n]*[\"“'‘(\[]*$"#,
            options: .regularExpression
        ) != nil
    }

    /// URLs, paths, hashtags and hostnames are identifiers; a Dictionary
    /// spelling never rewrites part of one, except inside a mail address
    /// where the lowercase preferred form is expected.
    private static func isProtectedIdentifier(_ range: NSRange, in text: String) -> Bool {
        let token = surroundingToken(of: range, in: text as NSString)
        if token.contains("/") || token.contains("\\") || token.contains("#") { return true }
        if token.contains("@") {
            return !SpokenEmailFormatter.containsDictionaryRange(range, inEmailWithin: text)
        }
        return false
    }

    private static func isInsideDottedIdentifier(_ range: NSRange, in text: String) -> Bool {
        guard !SpokenEmailFormatter.containsDictionaryRange(range, inEmailWithin: text) else { return false }
        let source = text as NSString
        let token = surroundingToken(of: range, in: source)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"“”'‘’()[]"))
        guard (token as NSString).length > range.length else { return false }
        return token.range(of: #"[\p{L}\p{N}]\.[\p{L}\p{N}]"#, options: .regularExpression) != nil
    }

    private static func surroundingToken(of range: NSRange, in source: NSString) -> String {
        func isSeparator(_ character: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(character) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        var start = range.location
        while start > 0, !isSeparator(source.character(at: start - 1)) { start -= 1 }
        var end = NSMaxRange(range)
        while end < source.length, !isSeparator(source.character(at: end)) { end += 1 }
        return source.substring(with: NSRange(location: start, length: end - start))
    }

    private static func unambiguousExactRules(
        entries: [DictionaryEntry],
        indices: [Int]
    ) -> [TermRule] {
        var grouped: [String: [TermRule]] = [:]
        for index in indices {
            for term in DictionaryEntryPolicy.uniqueTerms(
                [entries[index].preferredSpelling] + entries[index].aliases
            ) where !term.isEmpty {
                grouped[DictionaryEntryPolicy.normalizedKey(term), default: []]
                    .append(TermRule(term: term, entryIndex: index))
            }
        }

        return grouped.values.compactMap { rules in
            let desiredSpellings = Set(rules.map {
                DictionaryEntryPolicy.normalizedKey(entries[$0.entryIndex].preferredSpelling)
            })
            guard desiredSpellings.count == 1 else { return nil }

            let chosen = rules.min { lhs, rhs in
                let leftEntry = entries[lhs.entryIndex]
                let rightEntry = entries[rhs.entryIndex]
                if leftEntry.createdAt != rightEntry.createdAt {
                    return leftEntry.createdAt < rightEntry.createdAt
                }
                return lhs.entryIndex < rhs.entryIndex
            }
            return chosen
        }
        .sorted {
            let leftCount = $0.term.count
            let rightCount = $1.term.count
            if leftCount != rightCount { return leftCount > rightCount }
            return $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
        }
    }

    private static func wholeTermRanges(of term: String, in text: String) -> [NSRange] {
        let source = text as NSString
        var result: [NSRange] = []
        var searchLocation = 0

        while searchLocation < source.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let match = source.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            if isWholeTerm(match, in: text) { result.append(match) }
            searchLocation = max(NSMaxRange(match), match.location + 1)
        }
        return result
    }

    private static func isWholeTerm(_ range: NSRange, in text: String) -> Bool {
        guard let swiftRange = Range(range, in: text) else { return false }
        let before = swiftRange.lowerBound == text.startIndex
            ? nil
            : text[..<swiftRange.lowerBound].last
        let after = swiftRange.upperBound == text.endIndex
            ? nil
            : text[swiftRange.upperBound...].first
        // A hyphen binds: "well" is not a whole term inside "well-known".
        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-"
        }
        return before.map { !isWordCharacter($0) } ?? true
            && after.map { !isWordCharacter($0) } ?? true
    }

    private static func alphabeticTokenRanges(in text: String) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{M}]+"#) else {
            return []
        }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).map(\.range)
    }

    private static func uniqueFuzzyEntry(
        for token: String,
        entries: [DictionaryEntry],
        indices: [Int]
    ) -> Int? {
        let normalizedToken = DictionaryEntryPolicy.normalizedKey(token)
        let characters = Array(normalizedToken)
        guard characters.count >= 5,
              characters.allSatisfy({ $0.isLetter })
        else { return nil }

        let maximumDistance = characters.count <= 7 ? 1 : 2
        var bestByEntry: [Int: Int] = [:]

        for index in indices where !entries[index].aliases.isEmpty {
            for alias in entries[index].aliases {
                let normalizedAlias = DictionaryEntryPolicy.normalizedKey(alias)
                let aliasCharacters = Array(normalizedAlias)
                guard aliasCharacters.count >= 5,
                      aliasCharacters.allSatisfy({ $0.isLetter }),
                      abs(aliasCharacters.count - characters.count) <= maximumDistance
                else { continue }

                let distance = damerauLevenshteinDistance(
                    characters,
                    aliasCharacters,
                    limit: maximumDistance
                )
                guard distance > 0, distance <= maximumDistance else { continue }
                if maximumDistance == 2,
                   characters.first != aliasCharacters.first,
                   characters.last != aliasCharacters.last {
                    continue
                }
                bestByEntry[index] = min(bestByEntry[index] ?? Int.max, distance)
            }
        }

        guard let bestDistance = bestByEntry.values.min() else { return nil }
        let winners = bestByEntry.filter { $0.value == bestDistance }.map(\.key)
        return winners.count == 1 ? winners[0] : nil
    }

    static func damerauLevenshteinDistance(
        _ source: [Character],
        _ target: [Character],
        limit: Int
    ) -> Int {
        guard abs(source.count - target.count) <= limit else { return limit + 1 }
        if source == target { return 0 }
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previousPrevious = Array(0...target.count)
        var previous = Array(0...target.count)

        for sourceIndex in 1...source.count {
            var current = Array(repeating: 0, count: target.count + 1)
            current[0] = sourceIndex

            for targetIndex in 1...target.count {
                let cost = source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1
                current[targetIndex] = min(
                    previous[targetIndex] + 1,
                    current[targetIndex - 1] + 1,
                    previous[targetIndex - 1] + cost
                )
                if sourceIndex > 1,
                   targetIndex > 1,
                   source[sourceIndex - 1] == target[targetIndex - 2],
                   source[sourceIndex - 2] == target[targetIndex - 1] {
                    current[targetIndex] = min(
                        current[targetIndex],
                        previousPrevious[targetIndex - 2] + 1
                    )
                }
            }

            previousPrevious = previous
            previous = current
        }
        return previous[target.count]
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func languageMatches(
        _ entryLanguage: DictionaryLanguage,
        _ recognitionLanguage: RecognitionLanguage
    ) -> Bool {
        entryLanguage == .both
            || recognitionLanguage == .automatic
            || (entryLanguage == .english && recognitionLanguage == .english)
            || (entryLanguage == .dutch && recognitionLanguage == .dutch)
    }
}

enum DictionaryEntryPolicy {
    static func normalizedKey(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueTerms(_ values: [String], excluding preferred: String? = nil) -> [String] {
        let excluded = preferred.map(normalizedKey)
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedKey(cleaned)
            guard !cleaned.isEmpty, key != excluded, seen.insert(key).inserted else { continue }
            result.append(cleaned)
        }
        return result.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func preparedEntry(
        original: DictionaryEntry?,
        preferredSpelling: String,
        suppliedAliases: [String],
        observedSpelling: String?,
        language: DictionaryLanguage
    ) -> DictionaryEntry {
        let preferred = preferredSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
        var aliases = suppliedAliases
        if let observedSpelling { aliases.append(observedSpelling) }
        if let original, normalizedKey(original.preferredSpelling) != normalizedKey(preferred) {
            aliases.append(original.preferredSpelling)
        }

        var entry = original ?? DictionaryEntry(preferredSpelling: preferred)
        entry.preferredSpelling = preferred
        entry.aliases = uniqueTerms(aliases, excluding: preferred)
        entry.language = language
        return entry
    }

    static func defaultLanguage(for observation: SpokenWordObservation?) -> DictionaryLanguage {
        if observation?.isLikelyNameOrBrand == true { return .both }
        return observation?.language ?? .both
    }
}
