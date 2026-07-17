import SwiftUI

struct DictionaryView: View {
    @ObservedObject var controller: SprekrAppController
    @State private var query = ""
    @State private var editorTarget: DictionaryEditorTarget?
    @State private var entryToDelete: DictionaryEntry?
    @FocusState private var searchIsFocused: Bool

    private var corrections: [DictionaryEntry] {
        controller.dictionaryEntries.filter(matchesQuery)
    }

    private var uncommonWords: [SpokenWordObservation] {
        controller.spokenWords.filter(matchesQuery)
    }

    private var hasAnyWords: Bool {
        !controller.dictionaryEntries.isEmpty || !controller.spokenWords.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header

                if hasAnyWords {
                    summary

                    if !uncommonWords.isEmpty {
                        dictionarySection(
                            title: "Uncommon words",
                            detail: "Names, brands, and spellings Sprekr cannot confidently verify.",
                            count: uncommonWords.count
                        ) {
                            LazyVStack(spacing: 0) {
                                ForEach(uncommonWords) { word in
                                    SpokenWordRow(word: word) {
                                        editorTarget = .observation(word)
                                    }
                                    if word.id != uncommonWords.last?.id { sectionDivider }
                                }
                            }
                        }
                    }

                    if !corrections.isEmpty {
                        dictionarySection(
                            title: "Saved corrections",
                            detail: "These spellings replace matching words or phrases in future dictations.",
                            count: corrections.count
                        ) {
                            LazyVStack(spacing: 0) {
                                ForEach(corrections) { entry in
                                    DictionaryRow(
                                        entry: entry,
                                        onSave: controller.saveDictionaryEntry,
                                        onEdit: { editorTarget = .entry(entry) }
                                    )
                                    .contextMenu {
                                        Button("Edit") { editorTarget = .entry(entry) }
                                        Button("Delete…", role: .destructive) { entryToDelete = entry }
                                    }
                                    if entry.id != corrections.last?.id { sectionDivider }
                                }
                            }
                        }
                    }

                    if corrections.isEmpty && uncommonWords.isEmpty {
                        searchEmptyState
                    }
                } else {
                    firstUseState
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 52)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                DictionaryEditor(entry: nil, observation: nil) { entry in
                    controller.saveDictionaryCorrection(entry)
                    editorTarget = nil
                }
            case let .entry(entry):
                DictionaryEditor(entry: entry, observation: nil) { updated in
                    controller.saveDictionaryCorrection(updated)
                    editorTarget = nil
                }
            case let .observation(observation):
                DictionaryEditor(entry: nil, observation: observation) { entry in
                    controller.saveDictionaryCorrection(entry)
                    editorTarget = nil
                }
            }
        }
        .confirmationDialog(
            "Delete “\(entryToDelete?.preferredSpelling ?? "this term")”?",
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { if !$0 { entryToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete dictionary term", role: .destructive) {
                if let entryToDelete { controller.deleteDictionaryEntry(entryToDelete.id) }
                entryToDelete = nil
            }
            Button("Cancel", role: .cancel) { entryToDelete = nil }
        } message: {
            Text("Sprekr will stop applying this spelling and its aliases.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your uncommon words.").sprekrHeading(40)
                    Text("Common vocabulary stays out of the way. Review unfamiliar names and teach Sprekr the spelling you want.")
                        .sprekrBody()
                        .frame(maxWidth: 680, alignment: .leading)
                }
                Spacer(minLength: 20)
                Button("Add correction") { editorTarget = .new }
                    .buttonStyle(SprekrPrimaryButtonStyle())
            }

            dictionarySearchField
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            DictionarySummaryMetric(
                value: uncommonWords.count,
                label: "Uncommon words"
            )
            summaryDivider
            DictionarySummaryMetric(
                value: controller.dictionaryEntries.count,
                label: "Corrections"
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(SprekrPalette.line.opacity(0.7))
            .frame(width: 1, height: 34)
            .padding(.horizontal, 22)
    }

    private func dictionarySection<Content: View>(
        title: String,
        detail: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            DictionarySectionHeader(title: title, detail: detail, count: count)
            content()
                .padding(14)
                .background(SprekrPalette.surface.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SprekrPalette.line.opacity(0.62), lineWidth: 1)
                }
        }
    }

    private var dictionarySearchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SprekrPalette.icon)

            TextField("Search uncommon words and corrections", text: $query)
                .textFieldStyle(.plain)
                .font(SprekrTypography.body(14, relativeTo: .body))
                .focused($searchIsFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                    // The clear button removes itself after this update. Give
                    // focus back after that render so keyboard editing and the
                    // standard Command-A/C/V shortcuts keep working.
                    Task { @MainActor in
                        await Task.yield()
                        searchIsFocused = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SprekrPalette.icon)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(SprekrHoverButtonStyle(cornerRadius: 8))
                .help("Clear dictionary search")
                .accessibilityLabel("Clear dictionary search")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 420, minHeight: 38)
        .background(SprekrPalette.surface.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(SprekrPalette.line.opacity(0.72), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var firstUseState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(SprekrPalette.icon)
            Text("Nothing unusual to review.").sprekrHeading(34)
            Text("Common words are intentionally hidden. Names, brands, and uncommon spellings appear here automatically when Sprekr finds them in local History.")
                .sprekrBody()
                .frame(maxWidth: 620, alignment: .leading)
        }
        .padding(.top, 92)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var searchEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matching words.").sprekrHeading(30)
            Text("Try a different spelling or clear the search.").sprekrBody()
        }
        .padding(.vertical, 52)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(SprekrPalette.line.opacity(0.56))
            .frame(height: 1)
            .padding(.leading, 48)
    }

    private func matchesQuery(_ entry: DictionaryEntry) -> Bool {
        guard !query.isEmpty else { return true }
        return entry.preferredSpelling.localizedCaseInsensitiveContains(query)
            || entry.aliases.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    private func matchesQuery(_ word: SpokenWordObservation) -> Bool {
        query.isEmpty || word.spelling.localizedCaseInsensitiveContains(query)
    }
}

private enum DictionaryEditorTarget: Identifiable {
    case new
    case entry(DictionaryEntry)
    case observation(SpokenWordObservation)

    var id: String {
        switch self {
        case .new: "new"
        case let .entry(entry): "entry-\(entry.id.uuidString)"
        case let .observation(word): "word-\(word.id)"
        }
    }
}

private struct DictionarySummaryMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.custom("CrimsonText-Regular", size: 29, relativeTo: .title2))
                .monospacedDigit()
            Text(label.uppercased())
                .font(SprekrTypography.body(10, weight: .semibold, relativeTo: .caption))
                .tracking(1.15)
                .foregroundStyle(SprekrPalette.secondaryText)
        }
    }
}

private struct DictionarySectionHeader: View {
    let title: String
    let detail: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SprekrTypography.body(17, weight: .semibold, relativeTo: .headline))
                Text(detail)
                    .font(SprekrTypography.body(13, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            Spacer()
            Text("\(count)")
                .font(SprekrTypography.body(12, weight: .semibold, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(SprekrPalette.secondaryText)
        }
    }
}

private struct SpokenWordRow: View {
    let word: SpokenWordObservation
    let onCorrect: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: word.isLikelyNameOrBrand ? "person.text.rectangle" : "text.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SprekrPalette.icon)
                .frame(width: 28, height: 28)
                .background(SprekrPalette.accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(word.spelling)
                    .font(SprekrTypography.body(15, weight: .medium, relativeTo: .body))
                Text(word.isLikelyNameOrBrand ? "Possible name or brand" : "Uncommon spelling")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.icon)
            }
            Spacer()
            Text("\(word.occurrenceCount)× heard")
                .font(SprekrTypography.body(12, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(SprekrPalette.secondaryText)
            Button(action: onCorrect) {
                Text("Correct")
                    .font(SprekrTypography.body(13, weight: .semibold, relativeTo: .body))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
            }
            .buttonStyle(SprekrHoverButtonStyle(
                baseFill: SprekrPalette.primaryText.opacity(0.055),
                cornerRadius: 9
            ))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 9)
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onSave: (DictionaryEntry) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Toggle("", isOn: Binding(get: { entry.isActive }, set: { enabled in
                var changed = entry
                changed.isActive = enabled
                onSave(changed)
            }))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.preferredSpelling)
                    .font(SprekrTypography.body(14, weight: .medium, relativeTo: .body))
                Text(entry.aliases.isEmpty
                    ? "Keep this spelling"
                    : "When heard as: \(entry.aliases.joined(separator: ", "))")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            Spacer()
            Text(entry.language.rawValue)
                .font(SprekrTypography.body(12, relativeTo: .caption))
                .foregroundStyle(SprekrPalette.secondaryText)
            if entry.appliedCount > 0 {
                Text("\(entry.appliedCount) fixes")
                    .font(SprekrTypography.body(12, relativeTo: .caption))
                    .foregroundStyle(SprekrPalette.secondaryText)
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(SprekrPalette.icon)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(SprekrHoverButtonStyle(cornerRadius: 8))
            .help("Edit term")
            .accessibilityLabel("Edit \(entry.preferredSpelling)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
    }
}

private struct DictionaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var spelling: String
    @State private var aliases: String
    @State private var language: DictionaryLanguage
    private let original: DictionaryEntry?
    private let observedSpelling: String?
    let onSave: (DictionaryEntry) -> Void

    init(
        entry: DictionaryEntry?,
        observation: SpokenWordObservation?,
        onSave: @escaping (DictionaryEntry) -> Void
    ) {
        original = entry
        observedSpelling = observation?.spelling
        self.onSave = onSave
        _spelling = State(initialValue: entry?.preferredSpelling ?? observation?.spelling ?? "")
        _aliases = State(initialValue: entry?.aliases.joined(separator: ", ") ?? "")
        let initialLanguage = entry?.language
            ?? DictionaryEntryPolicy.defaultLanguage(for: observation)
        _language = State(initialValue: initialLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(original == nil ? "Teach Sprekr a spelling" : "Edit correction")
                    .sprekrHeading(34)
                if let observedSpelling {
                    Text("Sprekr heard “\(observedSpelling)”. Change the preferred spelling below; the heard version becomes an alias automatically.")
                        .sprekrBody()
                } else {
                    Text("Use aliases for the versions speech recognition may produce.")
                        .sprekrBody()
                }
            }

            Form {
                TextField("Preferred spelling", text: $spelling)
                TextField("Other versions heard, separated by commas", text: $aliases)
                Picker("Language", selection: $language) {
                    ForEach(DictionaryLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save correction") { save() }
                    .buttonStyle(SprekrPrimaryButtonStyle())
                    .disabled(cleanSpelling.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 500)
    }

    private var cleanSpelling: String {
        spelling.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let parsedAliases = aliases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let entry = DictionaryEntryPolicy.preparedEntry(
            original: original,
            preferredSpelling: cleanSpelling,
            suppliedAliases: parsedAliases,
            observedSpelling: observedSpelling,
            language: language
        )
        onSave(entry)
    }
}
