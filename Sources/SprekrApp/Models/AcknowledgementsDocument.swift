import Foundation

struct AcknowledgementEntry: Identifiable, Equatable {
    let component: String
    let use: String
    let license: String

    var id: String { component }
}

struct AcknowledgementsDocument: Equatable {
    let entries: [AcknowledgementEntry]
    let closingNote: String?

    static func bundled(in bundle: Bundle = .main) -> AcknowledgementsDocument {
        guard let url = bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return AcknowledgementsDocument(entries: [], closingNote: nil)
        }
        return parse(source)
    }

    static func parse(_ source: String) -> AcknowledgementsDocument {
        let lines = source.components(separatedBy: .newlines)
        let entries = lines.compactMap(parseTableRow)
        let closingNote = lines
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("|") && !$0.hasPrefix("#") }

        return AcknowledgementsDocument(entries: entries, closingNote: closingNote)
    }

    private static func parseTableRow(_ line: String) -> AcknowledgementEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }

        let cells = trimmed
            .dropFirst()
            .dropLast()
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cells.count == 3,
              cells[0] != "Component",
              !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" || $0.isWhitespace } })
        else { return nil }

        return AcknowledgementEntry(
            component: cells[0],
            use: cells[1],
            license: cells[2]
        )
    }
}
