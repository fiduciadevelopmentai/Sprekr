import SwiftUI

struct InsightsView: View {
    @ObservedObject var controller: SprekrAppController

    private let metricColumns = [
        GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 28, alignment: .topLeading),
    ]

    nonisolated static func dayCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "day" : "days")"
    }

    var body: some View {
        let summary = controller.insights
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Speaking, in context.").sprekrHeading(40)
                    Text("These numbers are calculated from local dictation duration and transcript words. Sprekr never classifies other apps.")
                        .sprekrBody()
                        .frame(maxWidth: 560, alignment: .leading)
                }

                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 30) {
                    Metric(label: "Total words", value: "\(summary.totalWords)")
                    Metric(label: "Words per minute", value: "\(summary.averageWordsPerMinute)")
                    Metric(label: "Current streak", value: Self.dayCountLabel(summary.currentStreak))
                    Metric(label: "Longest streak", value: Self.dayCountLabel(summary.longestStreak))
                    Metric(label: "Dictionary fixes", value: "\(summary.dictionaryFixes)")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Activity")
                            .font(SprekrTypography.body(12, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(SprekrPalette.secondaryText)
                        ActivityCalendar(activeDays: summary.activeDays)
                    }
                }
                .padding(.vertical, 24)
                .overlay(alignment: .top) { Divider().overlay(SprekrPalette.line) }
                .overlay(alignment: .bottom) { Divider().overlay(SprekrPalette.line) }

                Text("A streak counts a local dictation day in Europe/Amsterdam time. It is not a productivity score.")
                    .sprekrSmall()
            }
            .padding(36)
        }
        .scrollIndicators(.hidden)
    }
}

private struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(SprekrTypography.body(12, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(SprekrPalette.secondaryText)
            Text(value)
                .font(SprekrTypography.heading(36, relativeTo: .title2))
                .tracking(-0.8)
                .foregroundStyle(SprekrPalette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityCalendar: View {
    let activeDays: Set<Date>

    private var days: [Date] {
        let calendar = Calendar.sprekrAmsterdam
        return (0..<20).compactMap { calendar.date(byAdding: .day, value: -$0, to: .now) }.reversed()
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(days, id: \.self) { day in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(activeDays.contains(Calendar.sprekrAmsterdam.startOfDay(for: day)) ? SprekrPalette.accent : SprekrPalette.line.opacity(0.65))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }
}
