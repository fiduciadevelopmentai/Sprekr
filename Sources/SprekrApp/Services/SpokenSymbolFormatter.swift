import Foundation

/// Converts explicit spoken symbol names into their written characters.
///
/// This pass is deliberately separate from Smart formatting: symbol commands
/// are direct dictation input, so they remain available when paragraph and
/// rewriting assistance is disabled.
enum SpokenSymbolFormatter {
    private enum Safety: Equatable {
        case always
        case dash
        case dot
        case bareOperator
        case percentage
    }

    private enum Token: Int, CaseIterable {
        case at
        case slash
        case backslash
        case joiningHyphen
        case joiningUnderscore
        case period
        case joiningDot
        case comma
        case colon
        case semicolon
        case questionMark
        case exclamationMark
        case ellipsis
        case percent
        case euro
        case dollar
        case pound
        case yen
        case plus
        case minus
        case equals
        case lessThan
        case greaterThan
        case ampersand
        case hash
        case asterisk
        case pipe
        case tilde
        case caret
        case backtick
        case degree
        case copyright
        case registered
        case trademark
        case openingQuote
        case closingQuote
        case apostrophe
        case openingParenthesis
        case closingParenthesis
        case openingBracket
        case closingBracket
        case openingBrace
        case closingBrace

        var marker: String {
            String(UnicodeScalar(0xE100 + rawValue)!)
        }

        var symbol: String {
            switch self {
            case .at: "@"
            case .slash: "/"
            case .backslash: "\\"
            case .joiningHyphen, .minus: "-"
            case .joiningUnderscore: "_"
            case .period, .joiningDot: "."
            case .comma: ","
            case .colon: ":"
            case .semicolon: ";"
            case .questionMark: "?"
            case .exclamationMark: "!"
            case .ellipsis: "…"
            case .percent: "%"
            case .euro: "€"
            case .dollar: "$"
            case .pound: "£"
            case .yen: "¥"
            case .plus: "+"
            case .equals: "="
            case .lessThan: "<"
            case .greaterThan: ">"
            case .ampersand: "&"
            case .hash: "#"
            case .asterisk: "*"
            case .pipe: "|"
            case .tilde: "~"
            case .caret: "^"
            case .backtick: "`"
            case .degree: "°"
            case .copyright: "©"
            case .registered: "®"
            case .trademark: "™"
            case .openingQuote: "“"
            case .closingQuote: "”"
            case .apostrophe: "’"
            case .openingParenthesis: "("
            case .closingParenthesis: ")"
            case .openingBracket: "["
            case .closingBracket: "]"
            case .openingBrace: "{"
            case .closingBrace: "}"
            }
        }
    }

    private struct Command {
        let token: Token
        let safety: Safety
        let aliases: [String]
    }

    private struct Candidate {
        let range: NSRange
        let command: Command
        let alias: String
    }

    static func format(_ transcript: String, language: RecognitionLanguage) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let quoted = formatShortQuotes(in: trimmed, language: language)
        let candidates = findCandidates(in: quoted, language: language)
        let containsStrongCue = candidates.contains { $0.command.safety == .always }
        let resolved = resolveCandidates(
            candidates,
            in: quoted,
            containsStrongCue: containsStrongCue
        )

        guard !resolved.isEmpty || quoted != trimmed else { return trimmed }

        var marked = quoted
        for candidate in resolved.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(candidate.range, in: marked) else { continue }
            marked.replaceSubrange(range, with: candidate.command.token.marker)
        }

        return render(marked)
    }

    private static func findCandidates(
        in text: String,
        language: RecognitionLanguage
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for command in commands(for: language) {
            for alias in command.aliases {
                let pattern = #"(?<![\p{L}\p{N}_])(?:\#(aliasPattern(alias)))(?![\p{L}\p{N}_])"#
                guard let expression = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive, .useUnicodeWordBoundaries]
                ) else { continue }
                let fullRange = NSRange(text.startIndex..., in: text)
                candidates.append(contentsOf: expression.matches(
                    in: text,
                    range: fullRange
                ).map { Candidate(range: $0.range, command: command, alias: alias) })
            }
        }
        return candidates
    }

    private static func resolveCandidates(
        _ candidates: [Candidate],
        in text: String,
        containsStrongCue: Bool
    ) -> [Candidate] {
        let sorted = candidates.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var accepted: [Candidate] = []
        var acceptedEnd = 0
        for candidate in sorted {
            guard candidate.range.location >= acceptedEnd,
                  isSafe(candidate, in: text, containsStrongCue: containsStrongCue)
            else { continue }
            if candidate.command.safety == .dot, isDomainDot(candidate, in: text) {
                accepted.append(Candidate(
                    range: candidate.range,
                    command: Command(
                        token: .joiningDot,
                        safety: .always,
                        aliases: candidate.command.aliases
                    ),
                    alias: candidate.alias
                ))
            } else {
                accepted.append(candidate)
            }
            acceptedEnd = NSMaxRange(candidate.range)
        }
        return accepted
    }

    private static func isSafe(
        _ candidate: Candidate,
        in text: String,
        containsStrongCue: Bool
    ) -> Bool {
        switch candidate.command.safety {
        case .always:
            return true
        case .dash:
            return !isProtectedDashPhrase(candidate, in: text)
        case .dot:
            return isDomainDot(candidate, in: text) || isTerminalPunctuation(candidate, in: text)
        case .bareOperator:
            return containsStrongCue
                || hasNumericOperands(candidate, in: text)
                || isWholeUtterance(candidate, in: text)
        case .percentage:
            return isWholeSentenceCommand(candidate, in: text, optionalLeadIns: ["of", "or"])
        }
    }

    private static func isProtectedDashPhrase(_ candidate: Candidate, in text: String) -> Bool {
        let source = text as NSString
        let start = max(0, candidate.range.location - 12)
        let end = min(source.length, NSMaxRange(candidate.range) + 12)
        let context = source.substring(with: NSRange(location: start, length: end - start)).symbolFolded
        return context.range(
            of: #"(?:een|a)[ \t]+streepje[ \t]+voor|streepje[ \t]+door|dash[ \t]+of[ \t]+colour"#,
            options: .regularExpression
        ) != nil
    }

    private static func isDomainDot(_ candidate: Candidate, in text: String) -> Bool {
        let source = text as NSString
        let suffix = source.substring(from: NSMaxRange(candidate.range)).symbolFolded
        let prefix = source.substring(to: candidate.range.location).symbolFolded
        let topLevelDomains = #"(?:com|nl|org|net|io|dev|app|ai|be|de|eu|co|uk)\b"#
        guard suffix.range(of: #"^[ \t]+\#(topLevelDomains)"#, options: .regularExpression) != nil else {
            return false
        }
        return prefix.range(of: #"[\p{L}\p{N}]\s*$"#, options: .regularExpression) != nil
    }

    private static func isTerminalPunctuation(_ candidate: Candidate, in text: String) -> Bool {
        let source = text as NSString
        let suffix = source.substring(from: NSMaxRange(candidate.range))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.isEmpty else { return false }

        let prefix = source.substring(to: candidate.range.location).symbolFolded
        let protectedDeterminer = #"(?:een|het|dit|dat|mijn|jouw|a|the|this|that|my|your)[ \t]+$"#
        return prefix.range(of: protectedDeterminer, options: .regularExpression) == nil
    }

    private static func hasNumericOperands(_ candidate: Candidate, in text: String) -> Bool {
        let source = text as NSString
        let prefix = source.substring(to: candidate.range.location)
        let suffix = source.substring(from: NSMaxRange(candidate.range))
        return prefix.range(of: #"\d[ \t]*$"#, options: .regularExpression) != nil
            && suffix.range(of: #"^[ \t]*\d"#, options: .regularExpression) != nil
    }

    private static func isWholeUtterance(_ candidate: Candidate, in text: String) -> Bool {
        candidate.range.location == 0 && NSMaxRange(candidate.range) == (text as NSString).length
    }

    private static func isWholeSentenceCommand(
        _ candidate: Candidate,
        in text: String,
        optionalLeadIns: [String]
    ) -> Bool {
        let source = text as NSString
        var start = candidate.range.location
        while start > 0, !isSentenceBoundary(source.character(at: start - 1)) {
            start -= 1
        }
        var end = NSMaxRange(candidate.range)
        while end < source.length, !isSentenceBoundary(source.character(at: end)) {
            end += 1
        }
        let sentence = source.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .symbolFolded
        let leadIns = optionalLeadIns.map(aliasPattern).joined(separator: "|")
        let command = aliasPattern(candidate.alias)
        let pattern = #"^(?:(?:\#(leadIns))[ \t]+)?(?:\#(command))$"#
        return sentence.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isSentenceBoundary(_ character: unichar) -> Bool {
        character == 46 || character == 33 || character == 63 || character == 10
    }

    private static func formatShortQuotes(
        in text: String,
        language: RecognitionLanguage
    ) -> String {
        let aliases: [String] = {
            switch language {
            case .dutch:
                ["tussen aanhalingstekens"]
            case .english:
                ["in quotation marks", "in quotes"]
            case .automatic:
                ["tussen aanhalingstekens", "in quotation marks", "in quotes"]
            }
        }()
        let alternatives = aliases.map(aliasPattern).joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_])(?:\#(alternatives))[ \t]+([^.!?\n]+)(?=[.!?]|$)"#,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        ) else { return text }

        var result = text
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let contentRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result)
            else { continue }
            let content = result[contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = content.split { !$0.isLetter && !$0.isNumber }.count
            guard (1...12).contains(wordCount) else { continue }
            result.replaceSubrange(fullRange, with: "“\(content)”")
        }
        return result
    }

    private static func render(_ markedText: String) -> String {
        var result = markedText

        // URL schemes are the only common place where a colon and two slashes
        // must all bind even though no alphanumeric character separates them.
        result = replacing(
            #"\b(https?|ftp)[ \t]*\#(Token.colon.marker)[ \t]*\#(Token.slash.marker)[ \t]*\#(Token.slash.marker)[ \t]*"#,
            in: result,
            with: "$1\(Token.colon.marker)\(Token.slash.marker)\(Token.slash.marker)"
        )

        for token in [Token.at, .slash, .backslash, .joiningHyphen, .joiningUnderscore, .joiningDot] {
            let marker = NSRegularExpression.escapedPattern(for: token.marker)
            result = replacing(
                #"(?<=[\p{L}\p{N}])[ \t]*\#(marker)[ \t]*(?=[\p{L}\p{N}])"#,
                in: result,
                with: token.marker
            )
        }

        let slashCount = result.components(separatedBy: Token.slash.marker).count - 1
        if slashCount >= 2 {
            result = replacing(
                #"\#(NSRegularExpression.escapedPattern(for: Token.slash.marker))[ \t]+(?=[\p{L}\p{N}])"#,
                in: result,
                with: Token.slash.marker
            )
        }
        let backslashCount = result.components(separatedBy: Token.backslash.marker).count - 1
        if backslashCount >= 2 {
            result = replacing(
                #"\#(NSRegularExpression.escapedPattern(for: Token.backslash.marker))[ \t]+(?=[\p{L}\p{N}])"#,
                in: result,
                with: Token.backslash.marker
            )
        }

        for token in [Token.plus, .minus, .equals, .lessThan, .greaterThan] {
            let marker = NSRegularExpression.escapedPattern(for: token.marker)
            result = replacing(#"[ \t]*\#(marker)[ \t]*"#, in: result, with: " \(token.marker) ")
        }

        for token in [Token.period, .comma, .colon, .semicolon, .questionMark, .exclamationMark, .ellipsis] {
            let marker = NSRegularExpression.escapedPattern(for: token.marker)
            result = replacing(#"[ \t]+\#(marker)"#, in: result, with: token.marker)
            result = replacing(
                #"\#(marker)[ \t]*(?=[\p{L}\p{N}“\(\[\{])"#,
                in: result,
                with: "\(token.marker) "
            )
        }

        for token in [Token.percent, .degree] {
            let marker = NSRegularExpression.escapedPattern(for: token.marker)
            result = replacing(
                #"(?<=[\p{N}])[ \t]+\#(marker)"#,
                in: result,
                with: token.marker
            )
        }

        for token in [Token.euro, .dollar, .pound, .yen] {
            let marker = NSRegularExpression.escapedPattern(for: token.marker)
            result = replacing(
                #"\#(marker)[ \t]*(?=[\p{L}\p{N}])"#,
                in: result,
                with: "\(token.marker) "
            )
        }

        for token in [Token.openingQuote, .openingParenthesis, .openingBracket, .openingBrace] {
            let marker = NSRegularExpression.escapedPattern(for: token.marker)
            result = replacing(#"\#(marker)[ \t]+"#, in: result, with: token.marker)
        }
        for token in [Token.closingQuote, .closingParenthesis, .closingBracket, .closingBrace] {
            let marker = NSRegularExpression.escapedPattern(for: token.marker)
            result = replacing(#"[ \t]+\#(marker)"#, in: result, with: token.marker)
        }

        for token in Token.allCases {
            result = result.replacingOccurrences(of: token.marker, with: token.symbol)
        }
        result = replacing(#"[ \t]+([,.!?;:])"#, in: result, with: "$1")
        result = replacing(#"[ \t]{2,}"#, in: result, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commands(for language: RecognitionLanguage) -> [Command] {
        let shared = [
            Command(token: .slash, safety: .always, aliases: ["slash", "forward slash"]),
            Command(token: .backslash, safety: .always, aliases: ["backslash"]),
            Command(token: .joiningUnderscore, safety: .always, aliases: ["underscore"]),
            Command(token: .ampersand, safety: .always, aliases: ["ampersand"]),
            Command(token: .hash, safety: .always, aliases: ["hashtag"]),
            Command(token: .asterisk, safety: .always, aliases: ["asterisk"]),
            Command(token: .pipe, safety: .always, aliases: ["pipe"]),
            Command(token: .tilde, safety: .always, aliases: ["tilde"]),
            Command(token: .caret, safety: .always, aliases: ["caret"]),
            Command(token: .backtick, safety: .always, aliases: ["backtick", "back tick"]),
        ]

        let dutch = [
            Command(token: .at, safety: .always, aliases: ["apenstaartje", "at teken"]),
            Command(token: .slash, safety: .always, aliases: ["schuine streep"]),
            Command(token: .backslash, safety: .always, aliases: ["omgekeerde schuine streep"]),
            Command(token: .joiningHyphen, safety: .dash, aliases: ["streepje", "koppelteken"]),
            Command(token: .minus, safety: .always, aliases: ["minteken"]),
            Command(token: .minus, safety: .bareOperator, aliases: ["min"]),
            Command(token: .plus, safety: .always, aliases: ["plusteken"]),
            Command(token: .plus, safety: .bareOperator, aliases: ["plus"]),
            Command(token: .equals, safety: .always, aliases: ["is gelijk teken", "isgelijkteken", "gelijkteken"]),
            Command(token: .period, safety: .dot, aliases: ["punt"]),
            Command(token: .comma, safety: .always, aliases: ["komma"]),
            Command(token: .colon, safety: .always, aliases: ["dubbele punt"]),
            Command(token: .semicolon, safety: .always, aliases: ["puntkomma"]),
            Command(token: .questionMark, safety: .always, aliases: ["vraagteken"]),
            Command(token: .exclamationMark, safety: .always, aliases: ["uitroepteken"]),
            Command(token: .ellipsis, safety: .always, aliases: ["drie puntjes", "beletselteken"]),
            Command(token: .percent, safety: .always, aliases: ["procentteken", "percentageteken"]),
            Command(token: .percent, safety: .percentage, aliases: ["percentage"]),
            Command(token: .euro, safety: .always, aliases: ["euroteken"]),
            Command(token: .dollar, safety: .always, aliases: ["dollarteken"]),
            Command(token: .pound, safety: .always, aliases: ["pondteken", "Brits pondteken"]),
            Command(token: .yen, safety: .always, aliases: ["yenteken"]),
            Command(token: .ampersand, safety: .always, aliases: ["en teken"]),
            Command(token: .hash, safety: .always, aliases: ["hekje", "hash teken"]),
            Command(token: .asterisk, safety: .always, aliases: ["sterretje"]),
            Command(token: .pipe, safety: .always, aliases: ["verticale streep"]),
            Command(token: .caret, safety: .always, aliases: ["caretteken"]),
            Command(token: .lessThan, safety: .always, aliases: ["kleiner dan teken"]),
            Command(token: .greaterThan, safety: .always, aliases: ["groter dan teken"]),
            Command(token: .degree, safety: .always, aliases: ["gradenteken"]),
            Command(token: .copyright, safety: .always, aliases: ["copyrightteken"]),
            Command(token: .registered, safety: .always, aliases: ["geregistreerd handelsmerkteken", "registered teken"]),
            Command(token: .trademark, safety: .always, aliases: ["handelsmerkteken", "trademark teken"]),
            Command(token: .openingQuote, safety: .always, aliases: ["open aanhalingstekens", "open aanhalingsteken"]),
            Command(token: .closingQuote, safety: .always, aliases: ["sluit aanhalingstekens", "sluit aanhalingsteken"]),
            Command(token: .apostrophe, safety: .always, aliases: ["apostrof"]),
            Command(token: .openingParenthesis, safety: .always, aliases: ["open haakje", "open ronde haak"]),
            Command(token: .closingParenthesis, safety: .always, aliases: ["sluit haakje", "sluit ronde haak"]),
            Command(token: .openingBracket, safety: .always, aliases: ["open vierkante haak", "open blokhaak"]),
            Command(token: .closingBracket, safety: .always, aliases: ["sluit vierkante haak", "sluit blokhaak"]),
            Command(token: .openingBrace, safety: .always, aliases: ["open accolade"]),
            Command(token: .closingBrace, safety: .always, aliases: ["sluit accolade"]),
        ]

        let english = [
            Command(token: .at, safety: .always, aliases: ["at sign"]),
            Command(token: .joiningHyphen, safety: .dash, aliases: ["hyphen", "dash"]),
            Command(token: .minus, safety: .always, aliases: ["minus sign"]),
            Command(token: .minus, safety: .bareOperator, aliases: ["minus"]),
            Command(token: .plus, safety: .always, aliases: ["plus sign"]),
            Command(token: .plus, safety: .bareOperator, aliases: ["plus"]),
            Command(token: .equals, safety: .always, aliases: ["equals sign", "equal sign"]),
            Command(token: .period, safety: .dot, aliases: ["dot", "period"]),
            Command(token: .period, safety: .always, aliases: ["full stop"]),
            Command(token: .comma, safety: .always, aliases: ["comma"]),
            Command(token: .colon, safety: .always, aliases: ["colon"]),
            Command(token: .semicolon, safety: .always, aliases: ["semicolon"]),
            Command(token: .questionMark, safety: .always, aliases: ["question mark"]),
            Command(token: .exclamationMark, safety: .always, aliases: ["exclamation mark"]),
            Command(token: .ellipsis, safety: .always, aliases: ["ellipsis", "three dots"]),
            Command(token: .percent, safety: .always, aliases: ["percent sign", "percentage sign"]),
            Command(token: .percent, safety: .percentage, aliases: ["percentage"]),
            Command(token: .euro, safety: .always, aliases: ["euro sign"]),
            Command(token: .dollar, safety: .always, aliases: ["dollar sign"]),
            Command(token: .pound, safety: .always, aliases: ["British pound sign", "pound sterling sign"]),
            Command(token: .yen, safety: .always, aliases: ["yen sign"]),
            Command(token: .ampersand, safety: .always, aliases: ["and sign"]),
            Command(token: .hash, safety: .always, aliases: ["hash sign", "number sign"]),
            Command(token: .asterisk, safety: .always, aliases: ["star symbol"]),
            Command(token: .pipe, safety: .always, aliases: ["vertical bar"]),
            Command(token: .caret, safety: .always, aliases: ["caret symbol"]),
            Command(token: .lessThan, safety: .always, aliases: ["less than sign"]),
            Command(token: .greaterThan, safety: .always, aliases: ["greater than sign"]),
            Command(token: .degree, safety: .always, aliases: ["degree sign"]),
            Command(token: .copyright, safety: .always, aliases: ["copyright sign"]),
            Command(token: .registered, safety: .always, aliases: ["registered trademark sign", "registered sign"]),
            Command(token: .trademark, safety: .always, aliases: ["trademark sign"]),
            Command(token: .openingQuote, safety: .always, aliases: ["open quotation mark", "open quotes", "open quote"]),
            Command(token: .closingQuote, safety: .always, aliases: ["close quotation mark", "close quotes", "close quote"]),
            Command(token: .apostrophe, safety: .always, aliases: ["apostrophe"]),
            Command(token: .openingParenthesis, safety: .always, aliases: ["open parenthesis", "left parenthesis"]),
            Command(token: .closingParenthesis, safety: .always, aliases: ["close parenthesis", "right parenthesis"]),
            Command(token: .openingBracket, safety: .always, aliases: ["open square bracket", "left square bracket"]),
            Command(token: .closingBracket, safety: .always, aliases: ["close square bracket", "right square bracket"]),
            Command(token: .openingBrace, safety: .always, aliases: ["open brace", "left brace"]),
            Command(token: .closingBrace, safety: .always, aliases: ["close brace", "right brace"]),
        ]

        switch language {
        case .dutch: return shared + dutch
        case .english: return shared + english
        case .automatic: return shared + dutch + english
        }
    }

    /// Expands Latin letters into small diacritic-insensitive character
    /// classes while accepting spaces and hyphens between spoken words.
    private static func aliasPattern(_ alias: String) -> String {
        alias.split { $0 == " " || $0 == "-" }
            .map { part in part.map(letterPattern).joined() }
            .joined(separator: #"[ \t-]+"#)
    }

    private static func letterPattern(_ character: Character) -> String {
        switch String(character).lowercased() {
        case "a": "[aàáâãäåāăą]"
        case "c": "[cçćĉċč]"
        case "e": "[eèéêëēĕėęě]"
        case "i": "[iìíîïĩīĭįı]"
        case "n": "[nñńņň]"
        case "o": "[oòóôõöøōŏő]"
        case "s": "[sśŝşš]"
        case "u": "[uùúûüũūŭůűų]"
        case "y": "[yýÿŷ]"
        case "z": "[zźżž]"
        default: NSRegularExpression.escapedPattern(for: String(character))
        }
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }
}

private extension String {
    var symbolFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
