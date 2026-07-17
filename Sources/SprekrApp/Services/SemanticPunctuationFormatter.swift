import Foundation

/// Adds punctuation only where the surrounding phrase makes the writer's
/// intent unambiguous. The pass is deterministic, local, and deliberately
/// avoids broad rewriting or remote language-model calls.
enum SemanticPunctuationFormatter {
    static func format(_ text: String, language: RecognitionLanguage) -> String {
        var result = text
        switch language {
        case .dutch:
            result = quoteDutchMeaningSubjects(in: result)
            result = addDutchLeadInColons(in: result)
        case .english:
            result = quoteEnglishMeaningSubjects(in: result)
            result = addEnglishLeadInColons(in: result)
        case .automatic:
            result = quoteDutchMeaningSubjects(in: result)
            result = quoteEnglishMeaningSubjects(in: result)
            result = addDutchLeadInColons(in: result)
            result = addEnglishLeadInColons(in: result)
        }
        return result
    }

    private static func quoteDutchMeaningSubjects(in text: String) -> String {
        replacingMeaningMatches(
            in: text,
            patterns: [
                #"\b(wat[ \t]+betekent)[ \t]+([^.!?\n]+)([.!?])"#,
                #"\b(wat[ \t]+betekent)[ \t]+([^.!?\n]+)$"#,
            ],
            subjectGroup: 2,
            labelPrefixes: ["het woord ", "de term ", "de zin ", "de uitdrukking ", "de frase "]
        ) { match, subject, label in
            let lead = match[1]
            return "\(lead) \(label)“\(subject)”?"
        }
    }

    private static func quoteEnglishMeaningSubjects(in text: String) -> String {
        var result = replacingMeaningMatches(
            in: text,
            patterns: [
                #"\b(what[ \t]+does)[ \t]+([^.!?\n]+?)[ \t]+(mean)([.!?])"#,
                #"\b(what[ \t]+does)[ \t]+([^.!?\n]+?)[ \t]+(mean)$"#,
            ],
            subjectGroup: 2,
            labelPrefixes: ["the word ", "the term ", "the sentence ", "the phrase "]
        ) { match, subject, label in
            "\(match[1]) \(label)“\(subject)” \(match[3])?"
        }
        result = replacingMeaningMatches(
            in: result,
            patterns: [
                #"\b(what[ \t]+is[ \t]+the[ \t]+meaning[ \t]+of)[ \t]+([^.!?\n]+)([.!?])"#,
                #"\b(what[ \t]+is[ \t]+the[ \t]+meaning[ \t]+of)[ \t]+([^.!?\n]+)$"#,
            ],
            subjectGroup: 2,
            labelPrefixes: ["the word ", "the term ", "the sentence ", "the phrase "]
        ) { match, subject, label in
            "\(match[1]) \(label)“\(subject)”?"
        }
        return result
    }

    private static func replacingMeaningMatches(
        in text: String,
        patterns: [String],
        subjectGroup: Int,
        labelPrefixes: [String],
        replacement: ([String], String, String) -> String
    ) -> String {
        var result = text
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let matches = expression.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result)
            )
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let subjectRange = Range(match.range(at: subjectGroup), in: result)
                else { continue }

                var subject = String(result[subjectRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let folded = subject.semanticFolded
                var label = ""
                for candidate in labelPrefixes where folded.hasPrefix(candidate) {
                    label = String(subject.prefix(candidate.count))
                    subject = String(subject.dropFirst(candidate.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                guard shouldQuote(subject, hasExplicitLabel: !label.isEmpty) else { continue }

                var groups: [String] = []
                for group in 0..<match.numberOfRanges {
                    guard let range = Range(match.range(at: group), in: result) else {
                        groups.append("")
                        continue
                    }
                    groups.append(String(result[range]))
                }
                result.replaceSubrange(fullRange, with: replacement(groups, subject, label))
            }
        }
        return result
    }

    private static func shouldQuote(_ subject: String, hasExplicitLabel: Bool) -> Bool {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("“"),
              !trimmed.hasPrefix("\"")
        else { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count <= 16 else { return false }
        if hasExplicitLabel { return true }

        let folded = trimmed.semanticFolded
        let blockedStarts = [
            "dit", "dat", "deze", "die", "het ", "er ", "zulke", "of ",
            "waarom ", "hoe ", "wanneer ", "waar ", "wie ", "welke ",
            "this", "that", "these", "those", "it ", "whether ", "why ",
            "how ", "when ", "where ", "who ", "which ",
        ]
        guard !blockedStarts.contains(where: {
            folded == $0.trimmingCharacters(in: .whitespaces)
                || folded.hasPrefix($0)
        }) else { return false }

        let contextualConnectors = [
            " voor ", " in de praktijk", " in dit geval", " voor onze ",
            " for ", " in practice", " in this case",
        ]
        return !contextualConnectors.contains(where: folded.contains)
    }

    private static func addDutchLeadInColons(in text: String) -> String {
        addLeadInColons(
            in: text,
            phrases: [
                "ik bedoel het volgende", "het gaat om het volgende",
                "ik wil het volgende zeggen", "ik wil het volgende beschrijven",
                "dit is wat ik bedoel", "mijn vraag is de volgende",
                "de uitleg is als volgt",
            ]
        )
    }

    private static func addEnglishLeadInColons(in text: String) -> String {
        addLeadInColons(
            in: text,
            phrases: [
                "i mean the following", "here is what i mean",
                "i want to say the following", "i want to describe the following",
                "my question is the following", "the explanation is as follows",
            ]
        )
    }

    private static func addLeadInColons(in text: String, phrases: [String]) -> String {
        let alternatives = phrases
            .map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(\#(alternatives))[ \t]*(?:[.,;:]|\n)[ \t\n]+(?=[\p{L}\p{N}“\"'])"#,
            options: [.caseInsensitive]
        ) else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1: "
        )
    }
}

private extension String {
    var semanticFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
