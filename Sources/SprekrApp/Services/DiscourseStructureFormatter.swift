import Foundation

/// Recognizes high-confidence spoken structure without rewriting the user's
/// wording. Explicit numbered points become separate labelled paragraphs;
/// short parallel items become bullets only behind a clear list-intent cue.
enum DiscourseStructureFormatter {
    private struct PointMarker {
        let ordinal: Int
        let range: NSRange
        let displayLabel: String
    }

    private struct OrdinalMarker {
        let ordinal: Int
        let range: NSRange
        let displayLabel: String
    }

    private enum ListStartReason {
        case colon
        case preposition
        case listVerb
    }

    static func formatPointSections(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let markers = pointMarkers(in: text, language: language)
        guard let sequence = sequentialPointSequence(in: markers) else {
            return text
        }

        let source = text as NSString
        let prefix = source.substring(with: NSRange(
            location: 0,
            length: sequence[0].range.location
        )).trimmingCharacters(in: .whitespacesAndNewlines)

        var paragraphs: [String] = []
        if prefix.contains(where: { $0.isLetter || $0.isNumber }) {
            paragraphs.append(prefix)
        }

        for index in sequence.indices {
            let contentStart = NSMaxRange(sequence[index].range)
            let contentEnd = index + 1 < sequence.count
                ? sequence[index + 1].range.location
                : source.length
            guard contentEnd >= contentStart else { return text }

            let content = source.substring(with: NSRange(
                location: contentStart,
                length: contentEnd - contentStart
            )).trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.contains(where: { $0.isLetter || $0.isNumber }) else {
                return text
            }
            paragraphs.append("\(sequence[index].displayLabel): \(content)")
        }

        return paragraphs.joined(separator: "\n\n")
    }

    static func formatOrdinalSections(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let markers = ordinalMarkers(in: text, language: language)
        guard markers.count >= 2,
              markers[0].ordinal == 1,
              markers.indices.allSatisfy({ markers[$0].ordinal == $0 + 1 })
        else { return text }

        let source = text as NSString
        let rawIntro = source.substring(with: NSRange(
            location: 0,
            length: markers[0].range.location
        ))
        var paragraphs: [String] = []
        var trailingParagraph: String?
        if let intro = normalizedOrdinalIntro(rawIntro, language: language) {
            paragraphs.append(intro)
        }

        for index in markers.indices {
            let contentStart = NSMaxRange(markers[index].range)
            let contentEnd = index + 1 < markers.count
                ? markers[index + 1].range.location
                : source.length
            guard contentEnd >= contentStart else { return text }
            var rawContent = source.substring(with: NSRange(
                location: contentStart,
                length: contentEnd - contentStart
            ))
            if index == markers.indices.last {
                let split = splitTrailingOrdinalSuffix(rawContent, language: language)
                rawContent = split.content
                trailingParagraph = split.suffix
            }
            guard let content = finishedOrdinalContent(rawContent) else { return text }
            paragraphs.append(markers[index].displayLabel + " " + content)
        }
        if let trailingParagraph { paragraphs.append(trailingParagraph) }
        return paragraphs.joined(separator: "\n\n")
    }

    static func formatIntentLists(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        text.components(separatedBy: "\n\n")
            .map { formatIntentListParagraph($0, language: language) }
            .joined(separator: "\n\n")
    }

    private static func pointMarkers(
        in text: String,
        language: RecognitionLanguage
    ) -> [PointMarker] {
        let kind: String
        let qualifier: String
        let numbers: String
        let connectors: String

        switch language {
        case .dutch:
            kind = "punt"
            qualifier = "nummer"
            numbers = "10|[1-9]|een|één|twee|drie|vier|vijf|zes|zeven|acht|negen|tien"
            connectors = "en|maar|dus"
        case .english:
            kind = "point"
            qualifier = "number"
            numbers = "10|[1-9]|one|two|three|four|five|six|seven|eight|nine|ten"
            connectors = "and|but|so"
        case .automatic:
            kind = "punt|point"
            qualifier = "nummer|number"
            numbers = "10|[1-9]|een|één|twee|drie|vier|vijf|zes|zeven|acht|negen|tien|one|two|three|four|five|six|seven|eight|nine|ten"
            connectors = "en|maar|dus|and|but|so"
        }

        let pattern = #"(?<![\p{L}\p{N}])(?:(?:\#(connectors))[ \t]+)?(?<label>(?<kind>\#(kind))[ \t]+(?:(?<qualifier>\#(qualifier))[ \t]+)?(?<number>\#(numbers)))\b[ \t]*(?:[.:,;\-][ \t]*)?"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return [] }

        let source = text as NSString
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            let numberRange = match.range(withName: "number")
            let kindRange = match.range(withName: "kind")
            guard numberRange.location != NSNotFound,
                  kindRange.location != NSNotFound,
                  let ordinal = pointOrdinal(source.substring(with: numberRange))
            else { return nil }

            let rawKind = source.substring(with: kindRange).discourseFolded
            let displayKind = rawKind == "point" ? "Point" : "Punt"
            let qualifierRange = match.range(withName: "qualifier")
            let displayQualifier: String
            if qualifierRange.location == NSNotFound {
                displayQualifier = ""
            } else {
                displayQualifier = rawKind == "point" ? " number" : " nummer"
            }
            let rawNumber = source.substring(with: numberRange)
            let displayNumber = rawNumber.allSatisfy(\.isNumber)
                ? rawNumber
                : rawNumber.lowercased()

            return PointMarker(
                ordinal: ordinal,
                range: match.range,
                displayLabel: displayKind + displayQualifier + " " + displayNumber
            )
        }
    }

    private static func sequentialPointSequence(
        in markers: [PointMarker]
    ) -> [PointMarker]? {
        guard markers.count >= 2, markers[0].ordinal == 1 else { return nil }
        for index in markers.indices where markers[index].ordinal != index + 1 {
            return nil
        }
        return markers
    }

    private static func pointOrdinal(_ value: String) -> Int? {
        switch value.discourseFolded {
        case "1", "een", "one": 1
        case "2", "twee", "two": 2
        case "3", "drie", "three": 3
        case "4", "vier", "four": 4
        case "5", "vijf", "five": 5
        case "6", "zes", "six": 6
        case "7", "zeven", "seven": 7
        case "8", "acht", "eight": 8
        case "9", "negen", "nine": 9
        case "10", "tien", "ten": 10
        default: nil
        }
    }

    private static func formatIntentListParagraph(
        _ paragraph: String,
        language: RecognitionLanguage
    ) -> String {
        guard !paragraph.contains("\n• "),
              let cue = listIntentCue(in: paragraph, language: language)
        else { return paragraph }

        let source = paragraph as NSString
        let tailStart = NSMaxRange(cue)
        guard tailStart < source.length else { return paragraph }
        let tail = source.substring(from: tailStart)
        let separators = listSeparators(in: tail, language: language)
        guard separators.count >= 2 else { return paragraph }

        let tailSource = tail as NSString
        var rawSegments: [String] = []
        var segmentStart = 0
        for separator in separators {
            guard separator.location >= segmentStart else { return paragraph }
            rawSegments.append(tailSource.substring(with: NSRange(
                location: segmentStart,
                length: separator.location - segmentStart
            )))
            segmentStart = NSMaxRange(separator)
        }
        rawSegments.append(tailSource.substring(from: segmentStart))
        guard (3...10).contains(rawSegments.count),
              let firstSegment = rawSegments.first,
              let listStart = listStart(
                in: firstSegment,
                followingSegments: Array(rawSegments.dropFirst()),
                language: language
              )
        else { return paragraph }

        let firstSource = firstSegment as NSString
        let firstItem = firstSource.substring(from: listStart.offset)
        var items = [firstItem] + Array(rawSegments.dropFirst())
        items = items.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard validIntentListItems(items, reason: listStart.reason) else {
            return paragraph
        }

        let introEnd = tailStart + listStart.offset
        var intro = source.substring(with: NSRange(location: 0, length: introEnd))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: " \t,;:.!?")) + ":"
        let bullets = items.map { "• \($0)" }.joined(separator: "\n\n")
        return intro + "\n\n" + bullets
    }

    private static func ordinalMarkers(
        in text: String,
        language: RecognitionLanguage
    ) -> [OrdinalMarker] {
        let ordinals: [(Int, String, String)] = {
            let dutch = [
                (1, "ten eerste", "Ten eerste"), (2, "ten tweede", "Ten tweede"),
                (3, "ten derde", "Ten derde"), (4, "ten vierde", "Ten vierde"),
                (5, "ten vijfde", "Ten vijfde"),
            ]
            let english = [
                (1, "first", "First"), (2, "second", "Second"),
                (3, "third", "Third"), (4, "fourth", "Fourth"),
                (5, "fifth", "Fifth"),
            ]
            switch language {
            case .dutch: return dutch
            case .english: return english
            case .automatic: return dutch + english
            }
        }()
        let connectors: String = switch language {
        case .dutch: "en|maar|dus"
        case .english: "and|but|so"
        case .automatic: "en|maar|dus|and|but|so"
        }
        let source = text as NSString
        var result: [OrdinalMarker] = []

        for (ordinal, phrase, display) in ordinals {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = #"(?<![\p{L}\p{N}])(?:(?<noise>dus[ \t]+en|so[ \t]+and)[ \t]+|(?<connector>\#(connectors))[ \t]+)?(?<marker>\#(escaped))\b[ \t]*(?:[,;:][ \t]*)?"#
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            for match in expression.matches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ) {
                let connectorRange = match.range(withName: "connector")
                let connector: String
                if connectorRange.location == NSNotFound {
                    connector = ""
                } else {
                    let raw = source.substring(with: connectorRange).discourseFolded
                    connector = raw.prefix(1).uppercased() + raw.dropFirst() + " "
                }
                result.append(OrdinalMarker(
                    ordinal: ordinal,
                    range: match.range,
                    displayLabel: connector + (connector.isEmpty
                        ? display
                        : display.prefix(1).lowercased() + display.dropFirst())
                ))
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    private static func normalizedOrdinalIntro(
        _ value: String,
        language: RecognitionLanguage
    ) -> String? {
        var intro = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard intro.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if let terminal = intro.last, ".?!:…".contains(terminal) { return intro }
        intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: " \t,;"))
        let cues: [String] = switch language {
        case .dutch: ["dingen", "punten", "onderwerpen", "onderdelen", "verbeteringen"]
        case .english: ["things", "points", "topics", "subjects", "improvements", "items"]
        case .automatic: [
            "dingen", "punten", "onderwerpen", "onderdelen", "verbeteringen",
            "things", "points", "topics", "subjects", "improvements", "items",
        ]
        }
        let folded = intro.discourseFolded
        return intro + (cues.contains(where: { folded.contains($0) }) ? ":" : ".")
    }

    private static func finishedOrdinalContent(_ value: String) -> String? {
        var content = value.trimmingCharacters(in: .whitespacesAndNewlines)
        content = content.trimmingCharacters(in: CharacterSet(charactersIn: " \t,;"))
        guard content.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if let terminal = content.last, ".?!:…".contains(terminal) { return content }
        return content + "."
    }

    private static func splitTrailingOrdinalSuffix(
        _ value: String,
        language: RecognitionLanguage
    ) -> (content: String, suffix: String?) {
        let transitions: [String] = switch language {
        case .dutch:
            ["daarna", "vervolgens", "daarnaast", "overigens", "kortom", "tot slot", "ten slotte"]
        case .english:
            ["after that", "next", "additionally", "furthermore", "finally", "lastly"]
        case .automatic:
            [
                "daarna", "vervolgens", "daarnaast", "overigens", "kortom", "tot slot", "ten slotte",
                "after that", "next", "additionally", "furthermore", "finally", "lastly",
            ]
        }
        let alternatives = transitions.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: #"[.!?][ \t]+(?=(?:\#(alternatives))\b)"#,
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) else { return (value, nil) }

        let source = value as NSString
        let punctuationEnd = match.range.location + 1
        let content = source.substring(to: punctuationEnd)
        let suffix = source.substring(from: NSMaxRange(match.range))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (content, suffix.isEmpty ? nil : suffix)
    }

    private static func listIntentCue(
        in text: String,
        language: RecognitionLanguage
    ) -> NSRange? {
        let dutch = [
            "de volgende punten", "volgende punten", "deze punten",
            "een aantal punten", "de volgende onderwerpen", "volgende onderwerpen",
            "de volgende onderdelen", "volgende onderdelen",
        ]
        let english = [
            "the following points", "following points", "these points",
            "several points", "the following topics", "following topics",
            "the following subjects", "following subjects",
        ]
        let phrases: [String] = switch language {
        case .dutch: dutch
        case .english: english
        case .automatic: dutch + english
        }
        let alternatives = phrases
            .map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(?:\#(alternatives))\b"#,
            options: [.caseInsensitive]
        ) else { return nil }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )?.range
    }

    private static func listSeparators(
        in tail: String,
        language: RecognitionLanguage
    ) -> [NSRange] {
        guard let punctuation = try? NSRegularExpression(pattern: #"[;,][ \t]*"#) else {
            return []
        }
        var separators = punctuation.matches(
            in: tail,
            range: NSRange(tail.startIndex..., in: tail)
        ).map(\.range)

        let conjunctions: String = switch language {
        case .dutch: "en|of"
        case .english: "and|or"
        case .automatic: "en|of|and|or"
        }
        if let expression = try? NSRegularExpression(
            pattern: #"[ \t]+(?:\#(conjunctions))[ \t]+"#,
            options: [.caseInsensitive]
        ), let firstPunctuation = separators.first {
            let conjunction = expression.matches(
                in: tail,
                range: NSRange(tail.startIndex..., in: tail)
            ).last { $0.range.location > firstPunctuation.location }
            if let conjunction { separators.append(conjunction.range) }
        }

        separators.sort { $0.location < $1.location }
        return separators
    }

    private static func listStart(
        in firstSegment: String,
        followingSegments: [String],
        language: RecognitionLanguage
    ) -> (offset: Int, reason: ListStartReason)? {
        let source = firstSegment as NSString
        let colon = source.range(of: ":", options: [.backwards])
        if colon.location != NSNotFound, NSMaxRange(colon) < source.length {
            return (NSMaxRange(colon), .colon)
        }

        let prepositions: [String] = switch language {
        case .dutch: ["over", "voor", "met", "zonder", "van", "naar"]
        case .english: ["about", "for", "with", "without", "on"]
        case .automatic: [
            "over", "voor", "met", "zonder", "van", "naar",
            "about", "for", "with", "without", "on",
        ]
        }
        let alternatives = prepositions
            .map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
        if let expression = try? NSRegularExpression(
            pattern: #"\b(?:\#(alternatives))\b"#,
            options: [.caseInsensitive]
        ), let match = expression.matches(
            in: firstSegment,
            range: NSRange(firstSegment.startIndex..., in: firstSegment)
        ).last {
            let candidate = source.substring(from: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let laterAreShort = followingSegments.allSatisfy {
                (1...5).contains(wordCount(in: $0))
            }
            if (1...5).contains(wordCount(in: candidate)), laterAreShort {
                return (match.range.location, .preposition)
            }
        }

        let verbs: String = switch language {
        case .dutch: "zijn|is|omvatten|omvat|bevatten|bevat|bestaan[ \\t]+uit|bestaat[ \\t]+uit"
        case .english: "are|is|include|includes|consist[ \\t]+of|consists[ \\t]+of"
        case .automatic: "zijn|is|omvatten|omvat|bevatten|bevat|bestaan[ \\t]+uit|bestaat[ \\t]+uit|are|include|includes|consist[ \\t]+of|consists[ \\t]+of"
        }
        if let expression = try? NSRegularExpression(
            pattern: #"\b(?:\#(verbs))\b[ \t]+"#,
            options: [.caseInsensitive]
        ), let match = expression.matches(
            in: firstSegment,
            range: NSRange(firstSegment.startIndex..., in: firstSegment)
        ).last, NSMaxRange(match.range) < source.length {
            return (NSMaxRange(match.range), .listVerb)
        }

        return nil
    }

    private static func validIntentListItems(
        _ items: [String],
        reason: ListStartReason
    ) -> Bool {
        guard (3...10).contains(items.count) else { return false }
        let blockedStarts = [
            "maar", "omdat", "want", "terwijl", "hoewel",
            "but", "because", "while", "although",
        ]

        for (index, item) in items.enumerated() {
            let count = wordCount(in: item)
            guard (1...12).contains(count) else { return false }
            let folded = item.discourseFolded
            guard !blockedStarts.contains(where: {
                folded == $0 || folded.hasPrefix($0 + " ")
            }) else { return false }

            let terminalCount = item.filter { ".!?".contains($0) }.count
            if index < items.count - 1 {
                guard terminalCount == 0 else { return false }
            } else {
                guard terminalCount <= 1 else { return false }
                if terminalCount == 1,
                   let terminal = item.firstIndex(where: { ".!?".contains($0) }),
                   item[item.index(after: terminal)...].contains(where: { $0.isLetter || $0.isNumber }) {
                    return false
                }
            }
        }

        if reason == .preposition { return true }
        return items.allSatisfy { wordCount(in: $0) <= 8 }
    }

    private static func wordCount(in text: String) -> Int {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}][\p{L}\p{N}’'\-]*"#
        ) else { return 0 }
        return expression.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
    }
}

private extension String {
    var discourseFolded: String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
