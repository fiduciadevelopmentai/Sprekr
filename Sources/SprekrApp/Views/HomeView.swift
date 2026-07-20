import SwiftUI

struct HomeView: View {
    @ObservedObject var controller: SprekrAppController
    @ObservedObject private var audioCapture: AudioCaptureService
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var transcriptToDelete: TranscriptRecord?
    @FocusState private var searchIsFocused: Bool

    init(controller: SprekrAppController) {
        self.controller = controller
        _audioCapture = ObservedObject(wrappedValue: controller.audioCapture)
    }

    private var filtered: [TranscriptRecord] {
        guard !searchText.isEmpty else { return controller.transcripts }
        return controller.transcripts.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Dictation, kept here.").sprekrHeading(40)
                    Text("Your recent words stay on this Mac. Click any transcript to copy it.").sprekrBody()
                }
                Spacer()
                Button(audioCapture.isRecording ? "Stop" : "Talk") { controller.toggleDictation() }
                    .buttonStyle(SprekrPrimaryButtonStyle())
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 25)

            if let historyLoadError = controller.historyLoadError {
                historyErrorState(historyLoadError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.transcripts.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    historyList(relativeTo: timeline.date)
                }
            }
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: Binding(
                get: { transcriptToDelete != nil },
                set: { if !$0 { transcriptToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete transcript", role: .destructive) {
                if let transcriptToDelete { controller.deleteTranscript(transcriptToDelete.id) }
                transcriptToDelete = nil
            }
            Button("Cancel", role: .cancel) { transcriptToDelete = nil }
        } message: {
            Text("This permanently removes this saved transcript from this Mac.")
        }
    }

    private func historyList(relativeTo now: Date) -> some View {
        let dayGroups = TranscriptDayGrouper.groups(
            for: filtered,
            relativeTo: now,
            calendar: .sprekrAmsterdam
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                // Keep the actual TextField outside the filtered ForEach. If a
                // query moves the first result to another day—or to no result
                // at all—the field now keeps the same SwiftUI identity and
                // therefore remains AppKit's first responder for Delete and
                // Command-A/C/V.
                VStack(alignment: .leading, spacing: 10) {
                    historyHeader(dayGroups.first?.title ?? "History")

                    if let firstGroup = dayGroups.first {
                        transcriptListCard(firstGroup)
                    } else {
                        noSearchResults
                    }
                }

                ForEach(Array(dayGroups.dropFirst())) { group in
                    historySection(group)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 38)
        }
        .scrollIndicators(.never)
    }

    private func historyHeader(_ title: String) -> some View {
        HStack(spacing: 12) {
            Text(title.uppercased())
                .sprekrLabel()

            Spacer(minLength: 12)

            historySearchControl
        }
    }

    private func historySection(_ group: TranscriptDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title.uppercased())
                .sprekrLabel()

            transcriptListCard(group)
        }
    }

    private func transcriptListCard(_ group: TranscriptDayGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(group.transcripts.enumerated()), id: \.element.id) { index, transcript in
                if index > 0 {
                    Divider()
                        .overlay(SprekrPalette.line.opacity(0.68))
                }

                Button {
                    controller.copyTranscript(transcript.text)
                } label: {
                    TranscriptRow(transcript: transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SprekrHoverButtonStyle(
                    cornerRadius: 0,
                    hoverOpacity: 0.055,
                    pressedOpacity: 0.09,
                    pressedScale: 0.997
                ))
                .accessibilityHint("Copies this transcript")
                .contextMenu {
                    Button("Copy") { controller.copyTranscript(transcript.text) }
                    Button("Delete…", role: .destructive) { transcriptToDelete = transcript }
                }
            }
        }
        .background(SprekrPalette.surface.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SprekrPalette.line.opacity(0.70), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var historySearchControl: some View {
        if isSearching {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SprekrPalette.icon)

                TextField("Search history", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(SprekrTypography.body(13, relativeTo: .body))
                    .focused($searchIsFocused)

                Button {
                    searchText = ""
                    isSearching = false
                    searchIsFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SprekrPalette.icon)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(SprekrHoverButtonStyle(cornerRadius: 8))
                .help("Close search")
                .accessibilityLabel("Close history search")
            }
            .padding(.horizontal, 10)
            .frame(width: 230, height: 32)
            .background(SprekrPalette.surface.opacity(0.84))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(SprekrPalette.line.opacity(0.72), lineWidth: 1))
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isSearching = true
                }
                // Wait for the conditional TextField to exist before assigning
                // focus; setting it in the same render transaction is racy.
                Task { @MainActor in
                    await Task.yield()
                    searchIsFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SprekrPalette.icon)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SprekrHoverButtonStyle(cornerRadius: 10))
            .help("Search history")
            .accessibilityLabel("Search history")
        }
    }

    private var noSearchResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No matching dictations")
                .font(SprekrTypography.body(17, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(SprekrPalette.primaryText)
            Text("Try a different word or close search to see your full history.")
                .sprekrBody()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SprekrPalette.surface.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(SprekrPalette.icon)
            Text("Your first thought can start anywhere.")
                .sprekrHeading(34)
            Text(firstDictationInstruction)
                .sprekrBody()
                .frame(maxWidth: 440, alignment: .leading)
            Button("Start a dictation") { controller.startDictation() }
                .buttonStyle(SprekrPrimaryButtonStyle())
                .padding(.top, 6)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func historyErrorState(_ technicalMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(SprekrPalette.icon)
            Text(controller.historyNeedsKeychainUnlock ? "Unlock your history." : "Your history is still on this Mac.")
                .sprekrHeading(34)
            Text(controller.historyNeedsKeychainUnlock
                ? "After a local app update, macOS may ask you to allow Keychain access again. Your encrypted transcripts are untouched."
                : "Sprekr couldn’t unlock it just now. Nothing was deleted. Try loading it again.")
                .sprekrBody()
                .frame(maxWidth: 460, alignment: .leading)
            Button(controller.historyNeedsKeychainUnlock ? "Unlock history" : "Try again") {
                Task { await controller.reloadLocalData(allowingKeychainInteraction: true) }
            }
            .buttonStyle(SprekrPrimaryButtonStyle())
            .help(technicalMessage)
            .padding(.top, 6)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var firstDictationInstruction: String {
        let holdKey = controller.settings.values.holdShortcut.displayName
        let toggleKey = controller.settings.values.toggleShortcut.displayName
        return "Place your cursor in a text field. Hold \(holdKey) while speaking, or tap \(toggleKey) once to start and again to stop. Sprekr returns the transcript and keeps a local copy here."
    }

}

struct TranscriptDayGroup: Identifiable {
    let day: Date
    let title: String
    let transcripts: [TranscriptRecord]

    var id: Date { day }
}

enum TranscriptDayGrouper {
    static func groups(
        for transcripts: [TranscriptRecord],
        relativeTo now: Date = Date(),
        calendar: Calendar = .sprekrAmsterdam
    ) -> [TranscriptDayGroup] {
        let grouped = Dictionary(grouping: transcripts) {
            calendar.startOfDay(for: $0.createdAt)
        }

        return grouped.keys.sorted(by: >).map { day in
            TranscriptDayGroup(
                day: day,
                title: title(for: day, relativeTo: now, calendar: calendar),
                transcripts: grouped[day, default: []].sorted { $0.createdAt > $1.createdAt }
            )
        }
    }

    static func title(
        for day: Date,
        relativeTo now: Date,
        calendar: Calendar = .sprekrAmsterdam
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }

        let startOfToday = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: day)
    }
}

private struct TranscriptRow: View {
    let transcript: TranscriptRecord

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(formattedTime)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(SprekrPalette.secondaryText)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(transcript.text)
                    .font(SprekrTypography.body())
                    .lineSpacing(7)
                    .foregroundStyle(SprekrPalette.primaryText)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text("\(Int(transcript.audioDuration.rounded())) sec")
                    if transcript.dictionaryFixes > 0 { Text("\(transcript.dictionaryFixes) dictionary fixes") }
                    if !transcript.wasInserted { Text("Copied for recovery") }
                }
                .font(SprekrTypography.body(11, weight: .medium, relativeTo: .caption))
                .foregroundStyle(SprekrPalette.secondaryText)
            }
        }
        .padding(.vertical, 7)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.calendar = .sprekrAmsterdam
        formatter.timeZone = Calendar.sprekrAmsterdam.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: transcript.createdAt)
    }
}
