import Foundation

/// Small, deterministic formatting pass that stays fully offline. Parakeet
/// remains responsible for the words and most punctuation; this layer only
/// handles high-confidence speech repairs, patterns, and explicit layout phrases.
enum TranscriptFormatter {
    static func format(_ transcript: String, language: RecognitionLanguage) -> String {
        let numbered = SpokenNumberFormatter.format(
            transcript,
            spokenLanguage: language,
            outputLanguage: language
        )
        let symbolized = SpokenSymbolFormatter.format(numbered, language: language)
        var text = SpokenEmailFormatter.format(symbolized, language: language)
        guard !text.isEmpty else { return "" }

        text = SelfCorrectionFormatter.clean(text, language: language)
        text = ConversationalPunctuationFormatter.soften(text, language: language)
        text = replaceLayoutCommands(in: text, language: language)
        text = replaceTerminalPunctuationCommands(in: text, language: language)
        text = SemanticPunctuationFormatter.format(text, language: language)
        text = DiscourseStructureFormatter.formatPointSections(in: text, language: language)
        text = DiscourseStructureFormatter.formatOrdinalSections(in: text, language: language)
        text = LongFormParagraphFormatter.structure(text, language: language)
        text = inferQuestionMark(in: text, language: language)
        text = DiscourseStructureFormatter.formatIntentLists(in: text, language: language)
        return normalizeSpacing(in: text)
    }

    private static func replaceLayoutCommands(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        var result = text
        let numberedParagraphCommand: String = {
            switch language {
            case .dutch:
                return #"(?:alinea|paragraaf)[ \t]+(?:(?:nummer)[ \t]+)?(?:\d{1,2}|een|één|twee|drie|vier|vijf|zes|zeven|acht|negen|tien)"#
            case .english:
                return #"paragraph[ \t]+(?:(?:number)[ \t]+)?(?:\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten)"#
            case .automatic:
                return #"(?:(?:alinea|paragraaf)[ \t]+(?:(?:nummer)[ \t]+)?(?:\d{1,2}|een|één|twee|drie|vier|vijf|zes|zeven|acht|negen|tien)|paragraph[ \t]+(?:(?:number)[ \t]+)?(?:\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten))"#
            }
        }()
        result = replacing(
            #"(?:^|(?<=[.!?]))[ \t]*(?:\#(numberedParagraphCommand))[ \t]*(?:[.:,;\-][ \t]*)?"#,
            in: result,
            with: "\n\n"
        )

        let commands: [(String, String)] = {
            switch language {
            case .dutch:
                return [
                    (#"\b(?:nieuwe alinea|volgende alinea|begin een nieuwe alinea|start een nieuwe alinea|sla een regel over)\b"#, "\n\n"),
                    (#"\b(?:nieuwe regel|volgende regel|regelafbreking)\b"#, "\n"),
                    (#"\b(?:opsommingsteken|bullet point)\b"#, "\n• "),
                ]
            case .english:
                return [
                    (#"\b(?:new paragraph|next paragraph|start a new paragraph|skip a line)\b"#, "\n\n"),
                    (#"\b(?:new line|next line|line break)\b"#, "\n"),
                    (#"\b(?:bullet point|bullet)\b"#, "\n• "),
                ]
            case .automatic:
                return [
                    (#"\b(?:nieuwe alinea|volgende alinea|begin een nieuwe alinea|start een nieuwe alinea|sla een regel over|new paragraph|next paragraph|start a new paragraph|skip a line)\b"#, "\n\n"),
                    (#"\b(?:nieuwe regel|volgende regel|regelafbreking|new line|next line|line break)\b"#, "\n"),
                    (#"\b(?:opsommingsteken|bullet point|bullet)\b"#, "\n• "),
                ]
            }
        }()
        for (pattern, replacement) in commands {
            result = replacing(pattern, in: result, with: replacement)
        }
        return result
    }

    private static func replaceTerminalPunctuationCommands(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let alternatives: [(String, String)] = {
            switch language {
            case .dutch:
                [("vraagteken", "?"), ("uitroepteken", "!")]
            case .english:
                [("question mark", "?"), ("exclamation mark", "!"), ("full stop", ".")]
            case .automatic:
                [
                    ("vraagteken|question mark", "?"),
                    ("uitroepteken|exclamation mark", "!"),
                    ("full stop", "."),
                ]
            }
        }()

        var result = text
        for (phrase, punctuation) in alternatives {
            result = replacing(
                #"\s+(?:\#(phrase))[\s.?!]*$"#,
                in: result,
                with: punctuation
            )
        }
        return result
    }

    private static func inferQuestionMark(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        guard !text.hasSuffix("?"), !text.hasSuffix("!"), !text.contains("\n• ") else { return text }
        if let firstParagraph = text.components(separatedBy: "\n\n").first,
           firstParagraph.hasSuffix("?") {
            return text
        }
        let starters: [String] = {
            switch language {
            case .dutch:
                ["wie", "wat", "waar", "wanneer", "waarom", "hoe", "welke", "welk", "kan", "kun", "is", "zijn", "heb", "heeft", "wil", "zou", "mag", "moet"]
            case .english:
                ["who", "what", "where", "when", "why", "how", "which", "can", "could", "is", "are", "do", "does", "did", "will", "would", "should", "may"]
            case .automatic:
                [
                    "wie", "wat", "waar", "wanneer", "waarom", "hoe", "welke", "welk", "kan", "kun", "is", "zijn", "heb", "heeft", "wil", "zou", "mag", "moet",
                    "who", "what", "where", "when", "why", "how", "which", "can", "could", "are", "do", "does", "did", "will", "would", "should", "may",
                ]
            }
        }()
        let alternation = starters.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard text.range(of: #"^(?:\#(alternation))\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return text
        }
        return text.hasSuffix(".") ? String(text.dropLast()) + "?" : text + "?"
    }

    private static func normalizeSpacing(in text: String) -> String {
        var result = replacing(#"[ \t]+([,.!?;:])"#, in: text, with: "$1")
        result = replacing(#"[ \t]*\n[ \t]*"#, in: result, with: "\n")
        result = replacing(#"\n+[ \t]*(?=•)"#, in: result, with: "\n\n")
        result = replacing(#"\n•[ \t]+"#, in: result, with: "\n• ")
        result = replacing(#"\n{3,}"#, in: result, with: "\n\n")
        result = replacing(#"(?:\n•\s*){2,}"#, in: result, with: "\n• ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
