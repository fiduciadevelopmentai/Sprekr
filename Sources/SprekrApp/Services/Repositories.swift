import Foundation

enum HistoryExportPolicy {
    static let warning = "This JSON export is readable plaintext and is not encrypted. Anyone with the file can read every exported transcript."
}

actor TranscriptRepository {
    private let store = EncryptedJSONStore<[TranscriptRecord]>(
        filename: "history.enc",
        keyAccount: "history.encryption.key"
    )

    func all(allowingKeychainInteraction: Bool = true) throws -> [TranscriptRecord] {
        try store.load(
            default: [],
            allowingKeychainInteraction: allowingKeychainInteraction
        ).sorted { $0.createdAt > $1.createdAt }
    }

    func append(_ transcript: TranscriptRecord) throws {
        var records = try all()
        records.append(transcript)
        try store.save(records.sorted { $0.createdAt > $1.createdAt })
    }

    func save(_ transcript: TranscriptRecord) throws {
        var records = try all()
        if let index = records.firstIndex(where: { $0.id == transcript.id }) {
            records[index] = transcript
        } else {
            records.append(transcript)
        }
        try store.save(records.sorted { $0.createdAt > $1.createdAt })
    }

    func delete(_ id: UUID) throws {
        try store.save(all().filter { $0.id != id })
    }

    func clear() throws {
        try store.remove()
    }

    func export(to url: URL) throws {
        let data = try JSONEncoder.sprekr.encode(all())
        try data.write(to: url, options: [.atomic])
        try PrivateFilePermissions.secureFile(url)
    }
}

actor DictionaryRepository {
    private let store = EncryptedJSONStore<[DictionaryEntry]>(
        filename: "dictionary.enc",
        keyAccount: "dictionary.encryption.key"
    )

    func all() throws -> [DictionaryEntry] {
        try store.load(default: []).sorted { $0.preferredSpelling.localizedCaseInsensitiveCompare($1.preferredSpelling) == .orderedAscending }
    }

    func save(_ entry: DictionaryEntry) throws {
        var entries = try all()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try store.save(entries)
    }

    func delete(_ id: UUID) throws {
        try store.save(all().filter { $0.id != id })
    }

    func clear() throws {
        try store.remove()
    }

    func apply(to text: String, language: RecognitionLanguage) throws -> (text: String, fixes: Int) {
        let correction = DictionaryCorrectionEngine.apply(
            entries: try all(),
            to: text,
            language: language
        )
        if correction.fixes > 0 { try store.save(correction.entries) }
        return (correction.text, correction.fixes)
    }
}

enum InsightsService {
    static func summary(
        for transcripts: [TranscriptRecord],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> InsightSummary {
        let totalWords = transcripts.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let totalDuration = transcripts.reduce(0) { $0 + $1.audioDuration }
        let wpm = totalDuration > 0 ? Int(((Double(totalWords) / totalDuration) * 60).rounded()) : 0
        let days = Set(transcripts.map { calendar.startOfDay(for: $0.createdAt) })
        let orderedDays = days.sorted(by: >)
        let currentStreak = streak(from: orderedDays, calendar: calendar, now: now)
        let longestStreak = longest(in: orderedDays, calendar: calendar)
        let fixes = transcripts.reduce(0) { $0 + $1.dictionaryFixes }
        return InsightSummary(
            totalWords: totalWords,
            averageWordsPerMinute: wpm,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            dictionaryFixes: fixes,
            activeDays: days
        )
    }

    private static func streak(from days: [Date], calendar: Calendar, now: Date) -> Int {
        guard let latest = days.first else { return 0 }
        let today = calendar.startOfDay(for: now)
        let age = calendar.dateComponents([.day], from: latest, to: today).day ?? Int.max
        guard (0...1).contains(age) else { return 0 }

        var cursor = latest
        var count = 0
        for day in days {
            if calendar.isDate(day, inSameDayAs: cursor) {
                count += 1
                cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            } else { break }
        }
        return count
    }

    private static func longest(in days: [Date], calendar: Calendar) -> Int {
        var best = 0
        var run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }
}
