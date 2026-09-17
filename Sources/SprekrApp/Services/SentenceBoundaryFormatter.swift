import Foundation
import NaturalLanguage

/// Restores sentence boundaries in a long run that the recognizer delivered
/// without any terminal punctuation at all. The other paragraph and list passes
/// all need at least two sentences before they can act, so without this a very
/// long dictation arrives as one unbroken block.
///
/// This only ever splits at an explicit discourse marker that opens a clause
/// with its own finite verb, so ordinary long sentences stay intact.
///
/// `NLTagger` only offers `.lexicalClass` for English, so the finite-verb check
/// uses a closed list in both languages and takes the tagger as an extra signal
/// where it is actually available.
enum SentenceBoundaryFormatter {
    static func restore(_ text: String, language: RecognitionLanguage) -> String {
        let source = text as NSString
        let words = wordRanges(in: text)
        guard words.count >= minimumRunWords else { return text }

        let cues = cueWords(for: language)
        let blockedFollowers = blockedFollowingWords(for: language)
        let verbs = finiteVerbs(for: language)

        var edits: [(gap: NSRange, word: NSRange)] = []
        var appendTerminalPeriod = false

        for run in runs(of: words, in: source) {
            let runLength = run.count
            guard runLength >= minimumRunWords else { continue }

            let maximumInsertions = runLength / boundaryDensity
            guard maximumInsertions > 0 else { continue }

            var insertions = 0
            var lastBoundary = 0

            for index in 1..<runLength {
                guard insertions < maximumInsertions,
                      index - lastBoundary >= minimumWordsBefore,
                      runLength - index >= minimumWordsAfter
                else { continue }

                let word = source.substring(with: run[index]).lowercased()
                guard cues.contains(word) else { continue }

                let follower = source.substring(with: run[index + 1]).lowercased()
                guard !blockedFollowers.contains(follower) else { continue }

                let fragment = run[index..<min(index + lookaheadWords, runLength)]
                guard containsFiniteVerb(fragment, in: source, verbs: verbs, language: language)
                else { continue }

                let previousEnd = NSMaxRange(run[index - 1])
                let gap = NSRange(
                    location: previousEnd,
                    length: run[index].location - previousEnd
                )
                // Only rewrite a plain whitespace gap; anything else already
                // carries punctuation this pass must not disturb.
                let separator = source.substring(with: gap)
                guard !separator.isEmpty,
                      separator.allSatisfy({ $0 == " " || $0 == "\t" })
                else { continue }

                edits.append((gap: gap, word: run[index]))
                insertions += 1
                lastBoundary = index
            }

            // A run that gained sentences but trails off unpunctuated now looks
            // unfinished next to them, so close it.
            if insertions > 0, let last = run.last {
                let tail = source.substring(from: NSMaxRange(last))
                appendTerminalPeriod = !tail.contains { ".!?…".contains($0) }
            }
        }

        guard !edits.isEmpty else { return text }

        var result = text
        for edit in edits.reversed() {
            if let wordRange = Range(edit.word, in: result) {
                let word = String(result[wordRange])
                result.replaceSubrange(wordRange, with: capitalizingFirstLetter(word))
            }
            if let gapRange = Range(edit.gap, in: result) {
                result.replaceSubrange(gapRange, with: ". ")
            }
        }
        if appendTerminalPeriod {
            result = result.trimmingCharacters(in: .whitespacesAndNewlines) + "."
        }
        return result
    }

    // MARK: - Runs

    /// Groups words into stretches that carry no terminal punctuation or line
    /// break between them.
    private static func runs(of words: [NSRange], in source: NSString) -> [[NSRange]] {
        var result: [[NSRange]] = []
        var current: [NSRange] = []

        for (index, word) in words.enumerated() {
            if index > 0 {
                let previousEnd = NSMaxRange(words[index - 1])
                let gap = source.substring(
                    with: NSRange(location: previousEnd, length: word.location - previousEnd)
                )
                if gap.contains(where: { ".!?\n…".contains($0) }) {
                    result.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        result.append(current)
        return result.filter { !$0.isEmpty }
    }

    private static func containsFiniteVerb(
        _ fragment: ArraySlice<NSRange>,
        in source: NSString,
        verbs: Set<String>,
        language: RecognitionLanguage
    ) -> Bool {
        let words = fragment.map { source.substring(with: $0) }
        if words.contains(where: { verbs.contains($0.lowercased()) }) { return true }
        guard language != .dutch else { return false }
        return containsTaggedVerb(in: words.joined(separator: " "))
    }

    /// `.lexicalClass` is only offered for English, so this stays a supplement
    /// to the closed list rather than the primary signal.
    private static func containsTaggedVerb(in fragment: String) -> Bool {
        guard NLTagger.availableTagSchemes(for: .word, language: .english).contains(.lexicalClass)
        else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = fragment
        tagger.setLanguage(.english, range: fragment.startIndex..<fragment.endIndex)
        var found = false
        tagger.enumerateTags(
            in: fragment.startIndex..<fragment.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            if tag == .verb {
                found = true
                return false
            }
            return true
        }
        return found
    }

    private static func capitalizingFirstLetter(_ value: String) -> String {
        guard let first = value.first, first.isLowercase else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    private static func wordRanges(in text: String) -> [NSRange] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#
        ) else { return [] }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).map(\.range)
    }

    // MARK: - Thresholds

    /// A run shorter than this is left alone; the recognizer simply chose not to
    /// punctuate a single long thought.
    private static let minimumRunWords = 25
    private static let minimumWordsBefore = 5
    private static let minimumWordsAfter = 4
    /// Global density cap, so even a very long run cannot be shredded.
    private static let boundaryDensity = 12
    private static let lookaheadWords = 12

    private static func cueWords(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = [
            "dus", "oké", "okee", "oke", "vervolgens", "daarna", "kortom",
            "bovendien", "daarnaast", "trouwens", "verder", "sowieso",
        ]
        let english: Set<String> = [
            "so", "okay", "then", "next", "besides", "moreover",
            "anyway", "finally", "lastly", "additionally",
        ]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    /// A cue directly followed by one of these opens a subordinate clause
    /// ("dus dat", "so that") rather than a new sentence.
    private static func blockedFollowingWords(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = ["dat", "die", "wat", "als", "om", "te", "ook"]
        let english: Set<String> = ["that", "which", "if", "to", "as", "much", "many", "far"]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }

    /// Shared with the question inference in `TranscriptFormatter`, which
    /// needs the same closed list to tell "Hoe laat begint" from "Wat extra".
    static func finiteVerbs(for language: RecognitionLanguage) -> Set<String> {
        let dutch: Set<String> = [
            "ben", "bent", "is", "zijn", "was", "waren", "heb", "hebt", "heeft", "hebben",
            "had", "hadden", "doe", "doet", "doen", "deed", "deden",
            "kan", "kunt", "kun", "kunnen", "kon", "konden",
            "wil", "wilt", "willen", "wou", "wilde", "wilden",
            "zal", "zult", "zullen", "zou", "zouden",
            "mag", "mogen", "mocht", "mochten", "moet", "moeten", "moest", "moesten",
            "ga", "gaat", "gaan", "ging", "gingen", "kom", "komt", "komen", "kwam", "kwamen",
            "maak", "maakt", "maken", "maakte", "werk", "werkt", "werken", "werkte",
            "kijk", "kijkt", "kijken", "keek", "zie", "ziet", "zien", "zag", "zagen",
            "laat", "laten", "liet", "lieten", "geef", "geeft", "geven", "gaf",
            "zeg", "zegt", "zeggen", "zei", "weet", "weten", "wist",
            "denk", "denkt", "denken", "dacht", "vind", "vindt", "vinden", "vond",
            "neem", "neemt", "nemen", "nam", "krijg", "krijgt", "krijgen", "kreeg",
            "stuur", "stuurt", "sturen", "schrijf", "schrijft", "schrijven",
            "gebruik", "gebruikt", "gebruiken", "begrijp", "begrijpt", "begrijpen",
            "blijf", "blijft", "blijven", "bleef", "word", "wordt", "worden", "werd", "werden",
        ]
        let english: Set<String> = [
            "am", "are", "is", "was", "were", "have", "has", "had",
            "do", "does", "did", "can", "could", "will", "would", "should", "shall",
            "may", "might", "must", "go", "goes", "went", "come", "comes", "came",
            "make", "makes", "made", "work", "works", "worked", "look", "looks",
            "see", "sees", "saw", "let", "give", "gives", "gave", "say", "says", "said",
            "know", "knows", "knew", "think", "thinks", "thought", "find", "finds", "found",
            "take", "takes", "took", "get", "gets", "got", "send", "sends", "sent",
            "write", "writes", "wrote", "use", "uses", "used", "keep", "keeps", "kept",
            "need", "needs", "want", "wants", "become", "becomes", "became",
        ]
        switch language {
        case .dutch: return dutch
        case .english: return english
        case .automatic: return dutch.union(english)
        }
    }
}
