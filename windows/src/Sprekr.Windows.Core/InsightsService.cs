namespace Sprekr.Windows.Core;

public static class InsightsService
{
    public static InsightSummary Summarize(IReadOnlyList<TranscriptRecord> transcripts, DateTimeOffset? now = null)
    {
        var totalWords = transcripts.Sum(record => record.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length);
        var seconds = transcripts.Sum(record => record.AudioDurationSeconds);
        var wordsPerMinute = seconds > 0 ? (int)Math.Round(totalWords / seconds * 60, MidpointRounding.AwayFromZero) : 0;
        var days = transcripts.Select(record => record.CreatedAt.LocalDateTime.Date).Distinct().OrderDescending().ToArray();
        var today = (now ?? DateTimeOffset.Now).LocalDateTime.Date;
        var current = CurrentStreak(days, today);
        var longest = LongestStreak(days);
        return new InsightSummary(totalWords, wordsPerMinute, current, longest,
            transcripts.Sum(record => record.DictionaryFixes), days.Length);
    }

    private static int CurrentStreak(DateTime[] days, DateTime today)
    {
        if (days.Length == 0 || (today - days[0]).Days is < 0 or > 1) return 0;
        var cursor = days[0];
        var count = 0;
        foreach (var day in days)
        {
            if (day != cursor) break;
            count++;
            cursor = cursor.AddDays(-1);
        }
        return count;
    }

    private static int LongestStreak(DateTime[] descendingDays)
    {
        var days = descendingDays.Order().ToArray();
        var best = 0;
        var current = 0;
        DateTime? previous = null;
        foreach (var day in days)
        {
            current = previous is not null && (day - previous.Value).Days == 1 ? current + 1 : 1;
            best = Math.Max(best, current);
            previous = day;
        }
        return best;
    }
}
