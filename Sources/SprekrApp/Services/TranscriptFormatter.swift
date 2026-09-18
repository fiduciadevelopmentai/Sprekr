import Foundation

/// Small, deterministic formatting pass that stays fully offline. Parakeet
/// remains responsible for the words and most punctuation; this layer only
/// handles high-confidence speech repairs, patterns, and explicit layout phrases.
enum TranscriptFormatter {
    struct Options {
        /// Only differs from the spoken language when the transcript will be
        /// translated; number grouping and decimals follow the delivered text.
        var outputLanguage: RecognitionLanguage?
        /// Owns the built-in term lexicon and the spell-checked word repair.
        var vocabularyAssist = true
        /// Local spelling knowledge. Word repair is skipped when absent, which
        /// keeps the pass off any thread that must not touch `NSSpellChecker`.
        var speller: LexicalRepairFormatter.Speller?
        /// Spellings the user already owns, so word repair leaves them alone.
        var protectedTerms: Set<String> = []

        init() {}
    }

    static func format(
        _ transcript: String,
        language: RecognitionLanguage,
        options: Options = Options()
    ) -> String {
        let numbered = SpokenNumberFormatter.format(
            transcript,
            spokenLanguage: language,
            outputLanguage: options.outputLanguage ?? language
        )
        let symbolized = SpokenSymbolFormatter.format(numbered, language: language)
        var text = SpokenEmailFormatter.format(symbolized, language: language)
        guard !text.isEmpty else { return "" }

        text = SelfCorrectionFormatter.clean(text, language: language)
        if options.vocabularyAssist {
            text = TermLexicon.normalize(text)
            if let speller = options.speller {
                text = LexicalRepairFormatter.repair(
                    text,
                    language: language,
                    speller: speller,
                    protectedTerms: options.protectedTerms
                )
            }
        }
        text = SentenceBoundaryFormatter.restore(text, language: language)
        text = ConversationalPunctuationFormatter.soften(text, language: language)
        text = replaceLayoutCommands(in: text, language: language)
        text = replaceTerminalPunctuationCommands(in: text, language: language)
        text = SemanticPunctuationFormatter.format(text, language: language)
        text = DiscourseStructureFormatter.formatPointSections(in: text, language: language)
        text = DiscourseStructureFormatter.formatOrdinalSections(in: text, language: language)
        text = LongFormParagraphFormatter.structure(text, language: language)
        // Question inference stays ahead of list building on purpose: a spoken
        // request such as "zou jij ... over poesjes, over leeuwen en over
        // honden" is a question that then becomes a list, and it keeps its mark.
        text = inferQuestionMark(in: text, language: language)
        text = DiscourseStructureFormatter.formatIntentLists(in: text, language: language)
        text = SentenceCaseFormatter.apply(text)
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

        // A layout phrase preceded by a determiner or preposition is a noun
        // phrase about a line or bullet ("op een nieuwe regel", "the bullet
        // point"), not an instruction to insert one.
        let notAfterDeterminer = #"(?<!(?:^|[^\p{L}])(?:een|de|die|deze|elke|iedere|per|a|an|the|this|that|each|every|my|our|your|these|those)[ \t])"#
        let commands: [(String, String)] = {
            switch language {
            case .dutch:
                return [
                    (#"\#(notAfterDeterminer)\b(?:nieuwe alinea|volgende alinea|begin een nieuwe alinea|start een nieuwe alinea|sla een regel over)\b"#, "\n\n"),
                    (#"\#(notAfterDeterminer)\b(?:nieuwe regel|volgende regel|regelafbreking)\b"#, "\n"),
                    (#"\#(notAfterDeterminer)\b(?:opsommingsteken|bullet point)\b"#, "\n• "),
                ]
            case .english:
                return [
                    (#"\#(notAfterDeterminer)\b(?:new paragraph|next paragraph|start a new paragraph|skip a line)\b"#, "\n\n"),
                    (#"\#(notAfterDeterminer)\b(?:new line|next line|line break)\b"#, "\n"),
                    (#"\#(notAfterDeterminer)\b(?:bullet point)\b"#, "\n• "),
                ]
            case .automatic:
                return [
                    (#"\#(notAfterDeterminer)\b(?:nieuwe alinea|volgende alinea|begin een nieuwe alinea|start een nieuwe alinea|sla een regel over|new paragraph|next paragraph|start a new paragraph|skip a line)\b"#, "\n\n"),
                    (#"\#(notAfterDeterminer)\b(?:nieuwe regel|volgende regel|regelafbreking|new line|next line|line break)\b"#, "\n"),
                    (#"\#(notAfterDeterminer)\b(?:opsommingsteken|bullet point)\b"#, "\n• "),
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

    /// Restores the question mark Parakeet tends to drop together with the
    /// capital. Every sentence is judged on its own, so a closing question after
    /// a statement is found and an opening statement is never rewritten because
    /// the dictation as a whole started with a question word.
    ///
    /// A sentence only counts as a question when it shows inversion: a question
    /// word followed by a finite verb ("Waarom werkt dit", "Hoe laat begint"),
    /// or an auxiliary followed by its subject ("Kun je", "Is de microfoon",
    /// "Heeft Anna"). "Wat een dag", "Wat ik bedoel", "Is goed" and "Kan
    /// gebeuren" all fail that test and stay statements.
    private static func inferQuestionMark(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let updated = paragraphs.map { paragraph -> String in
            guard !paragraph.hasPrefix("• ") else { return paragraph }
            return markQuestionSentences(in: paragraph, language: language)
        }
        return updated.joined(separator: "\n\n")
    }

    private static func markQuestionSentences(
        in paragraph: String,
        language: RecognitionLanguage
    ) -> String {
        // A terminal only closes a sentence when whitespace or the end follows,
        // so "2.5" and "sprekr.nl" never split one.
        guard let sentenceExpression = try? NSRegularExpression(
            pattern: #"(?:[^.!?…\n]|[.!?…](?![\s]|$))+(?:[.!?…]+(?=\s|$)|(?=\n)|$)"#
        ) else { return paragraph }

        let source = paragraph as NSString
        let matches = sentenceExpression.matches(
            in: paragraph,
            range: NSRange(paragraph.startIndex..., in: paragraph)
        )
        var result = paragraph
        for match in matches.reversed() {
            let sentence = source.substring(with: match.range)
            let leading = String(sentence.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(sentence.reversed().prefix { $0 == " " || $0 == "\t" })
            let core = sentence.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { continue }
            // Anything already closed by "?", "!" or an ellipsis is settled.
            let terminalTail = String(core.reversed().prefix { ".!?…".contains($0) }.reversed())
            guard terminalTail.count <= 1, !terminalTail.contains(where: { "?!…".contains($0) }) else { continue }
            guard isDirectQuestion(core, language: language) else { continue }
            guard let range = Range(match.range, in: result) else { continue }

            let body = String(core.dropLast(terminalTail.count))
            result.replaceSubrange(range, with: leading + body + "?" + trailing)
        }
        return result
    }

    private static func isDirectQuestion(_ sentence: String, language: RecognitionLanguage) -> Bool {
        let opening = sentence
            .trimmingCharacters(in: .whitespaces)
            .drop { "\"“'‘([„".contains($0) }
        let words = opening
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(3)
            .map { word in
                String(word.trimmingCharacters(in: CharacterSet(charactersIn: ",;:\"“”'‘’()[]")))
            }
        guard words.count >= 2 else { return false }
        let first = words[0].lowercased()
        let second = words[1].lowercased()
        let tables = questionTables(for: language)

        if tables.fixedStatements.contains(where: { opening.lowercased().hasPrefix($0) }) {
            return false
        }

        if tables.questionWords.contains(first) {
            // "Wat ik bedoel", "Hoe jij dat doet", "Wat een dag", "What a day":
            // an embedded clause or exclamation, never a direct question.
            if tables.subjectPronouns.contains(second) || tables.exclamativeFollowers.contains(second) {
                return false
            }
            // A direct question puts its finite verb right after the question
            // word or after one qualifier ("Hoe laat begint", "Welke versie
            // gebruik je"). "Wat extra intelligentie aan het geven" has none.
            let verbs = tables.auxiliaries
                .union(tables.contentVerbs)
                .union(SentenceBoundaryFormatter.finiteVerbs(for: language))
            return words.dropFirst().contains { verbs.contains($0.lowercased()) }
        }

        if tables.auxiliaries.contains(first) {
            // "Kan ik doen.", "Heb ik gedaan.", "Zou ik ook doen.": a short
            // inverted first-person clause is an elliptical reply, not a question.
            if second == "ik", sentenceWordCount(sentence) <= 4 {
                return false
            }
            if tables.subjectPronouns.contains(second) || tables.determiners.contains(second) {
                return true
            }
            // "Heeft Anna gebeld", "Is Sprekr klaar": a name as the subject.
            if let initial = words[1].first, initial.isUppercase, words.count >= 3 {
                return true
            }
        }
        return false
    }

    private static func sentenceWordCount(_ sentence: String) -> Int {
        sentence.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.count
    }

    private struct QuestionTables {
        let questionWords: Set<String>
        let auxiliaries: Set<String>
        let contentVerbs: Set<String>
        let subjectPronouns: Set<String>
        let determiners: Set<String>
        let exclamativeFollowers: Set<String>
        let fixedStatements: [String]
    }

    private static func questionTables(for language: RecognitionLanguage) -> QuestionTables {
        let dutchQuestionWords: Set<String> = ["wie", "wat", "waar", "wanneer", "waarom", "hoe", "hoeveel", "welke", "welk", "waarmee", "waarvoor", "waarom"]
        let englishQuestionWords: Set<String> = ["who", "what", "where", "when", "why", "how", "which", "whom", "whose"]
        let dutchAuxiliaries: Set<String> = [
            "kan", "kun", "kunnen", "is", "zijn", "ben", "bent", "heb", "hebt", "heeft", "hebben", "had",
            "wil", "wilt", "willen", "zou", "zouden", "zal", "zul", "zullen", "mag", "mogen", "moet", "moeten",
            "ga", "gaat", "gaan", "weet", "weten", "denk", "denkt", "denken", "vind", "vindt", "vinden",
            "lukt", "klopt", "werkt", "doe", "doet", "doen", "was", "waren", "kom", "komt", "komen",
            "zie", "ziet", "zien", "hoef", "hoeft", "hoeven", "durf", "durft",
        ]
        let englishAuxiliaries: Set<String> = [
            "can", "could", "is", "are", "am", "was", "were", "do", "does", "did", "will", "would", "should",
            "may", "might", "must", "have", "has", "had", "shall", "don't", "doesn't", "didn't", "isn't",
            "aren't", "can't", "won't", "wouldn't", "couldn't", "shouldn't", "haven't", "hasn't",
        ]
        let dutchContentVerbs: Set<String> = [
            "betekent", "betekenen", "kost", "kosten", "duurt", "duren", "begint", "beginnen", "start",
            "heet", "heten", "staat", "staan", "zit", "zitten", "ligt", "liggen", "loopt", "lopen",
            "past", "passen", "gebeurt", "gebeuren", "bedoel", "bedoelt", "vraag", "vraagt",
            "hoor", "hoort", "lijkt", "lijken", "voelt", "bedoelen", "verwacht", "verwachten",
        ]
        let englishContentVerbs: Set<String> = [
            "mean", "means", "cost", "costs", "happen", "happens", "happened", "start", "starts",
            "matter", "matters", "look", "looks", "sound", "sounds", "feel", "feels",
        ]
        let dutchPronouns: Set<String> = [
            "ik", "je", "jij", "u", "we", "wij", "jullie", "hij", "zij", "ze", "het", "dat", "dit", "er",
            "die", "deze", "iemand", "iedereen", "men", "mij", "me", "ons", "hem", "haar", "hun", "jou",
        ]
        let englishPronouns: Set<String> = [
            "i", "you", "we", "they", "he", "she", "it", "this", "that", "there", "these", "those",
            "someone", "anyone", "everyone", "me", "us", "him", "her", "them",
        ]
        let dutchDeterminers: Set<String> = [
            "de", "het", "een", "mijn", "jouw", "je", "uw", "onze", "jullie", "hun", "haar", "zijn", "elke", "iedere", "alle",
        ]
        let englishDeterminers: Set<String> = [
            "the", "a", "an", "my", "your", "our", "their", "his", "her", "its", "every", "each", "all", "any", "some",
        ]
        let dutchExclamative: Set<String> = ["een", "de", "het"]
        let englishExclamative: Set<String> = ["a", "an", "the"]
        let dutchFixed = ["hoe dan ook", "wat betreft", "wat mij betreft", "wat ons betreft", "hoe het ook zij", "wat er ook gebeurt", "hoe langer", "hoe meer", "hoe minder", "wat voor mij"]
        let englishFixed = ["what a ", "what an ", "how about that", "whatever", "however", "whenever", "wherever", "whoever"]

        switch language {
        case .dutch:
            return QuestionTables(
                questionWords: dutchQuestionWords,
                auxiliaries: dutchAuxiliaries,
                contentVerbs: dutchContentVerbs,
                subjectPronouns: dutchPronouns,
                determiners: dutchDeterminers,
                exclamativeFollowers: dutchExclamative,
                fixedStatements: dutchFixed
            )
        case .english:
            return QuestionTables(
                questionWords: englishQuestionWords,
                auxiliaries: englishAuxiliaries,
                contentVerbs: englishContentVerbs,
                subjectPronouns: englishPronouns,
                determiners: englishDeterminers,
                exclamativeFollowers: englishExclamative,
                fixedStatements: englishFixed
            )
        case .automatic:
            return QuestionTables(
                questionWords: dutchQuestionWords.union(englishQuestionWords),
                auxiliaries: dutchAuxiliaries.union(englishAuxiliaries),
                contentVerbs: dutchContentVerbs.union(englishContentVerbs),
                subjectPronouns: dutchPronouns.union(englishPronouns),
                determiners: dutchDeterminers.union(englishDeterminers),
                exclamativeFollowers: dutchExclamative.union(englishExclamative),
                fixedStatements: dutchFixed + englishFixed
            )
        }
    }

    private static func normalizeSpacing(in text: String) -> String {
        // Clock times dictated with a spoken colon close up completely; a
        // smiley keeps the space in front of it.
        var result = replacing(#"(?<=\b\d{1,2})[ \t]*:[ \t]*(?=\d{2}\b)"#, in: text, with: ":")
        result = replacing(#"[ \t]+([,.!?;])"#, in: result, with: "$1")
        result = replacing(#"[ \t]+(:)(?![()DPp\-])"#, in: result, with: "$1")
        // A spoken command next to the recognizer's own punctuation leaves a
        // doubled terminal behind; the real ellipsis stays intact.
        result = replacing(#"([?!])\.(?!\.)"#, in: result, with: "$1")
        result = replacing(#",\.(?!\.)"#, in: result, with: ".")
        result = replacing(#"(?<![.…])\.\.(?!\.)"#, in: result, with: ".")
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
