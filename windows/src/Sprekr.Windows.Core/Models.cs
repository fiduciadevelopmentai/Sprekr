namespace Sprekr.Windows.Core;

public enum DictationMode { Hold, Toggle }
public enum RecognitionLanguage { Automatic, Dutch, English }
public enum FlowBarState { Hidden, Ready, Listening, Processing, Cancelled, Error }
public enum DeliveryOutcome { Delivered, Refused, Indeterminate }

public sealed record AudioRecording(string Path, TimeSpan Duration, int SampleRate = 16_000);

public sealed record TranscriptionResult(
    string Text,
    string? DetectedLanguage,
    TimeSpan ProcessingTime);

public sealed record DeliveryResult(DeliveryOutcome Outcome, string? Message = null)
{
    public static DeliveryResult Delivered() => new(DeliveryOutcome.Delivered);
    public static DeliveryResult Refused(string message) => new(DeliveryOutcome.Refused, message);
    public static DeliveryResult Indeterminate(string message) => new(DeliveryOutcome.Indeterminate, message);
}

public sealed record MicrophoneDevice(string Id, string Name, bool IsDefault);

public sealed record TranscriptRecord(
    Guid Id,
    string Text,
    DateTimeOffset CreatedAt,
    double AudioDurationSeconds,
    int DictionaryFixes,
    string? DetectedLanguage = null);

public sealed record DictionaryEntry(
    Guid Id,
    string PreferredSpelling,
    IReadOnlyList<string> Aliases,
    RecognitionLanguage Language,
    bool IsActive,
    int AppliedCount,
    DateTimeOffset CreatedAt);

public sealed record InsightSummary(
    int TotalWords,
    int AverageWordsPerMinute,
    int CurrentStreak,
    int LongestStreak,
    int DictionaryFixes,
    int ActiveDays);

public sealed record SprekrSettings
{
    public bool OnboardingCompleted { get; init; }
    public bool LaunchAtLogin { get; init; } = true;
    public bool ShowFlowBar { get; init; } = true;
    public bool SoundsEnabled { get; init; } = true;
    public DictationMode DictationMode { get; init; } = DictationMode.Hold;
    public RecognitionLanguage RecognitionLanguage { get; init; } = RecognitionLanguage.Automatic;
    public string? MicrophoneId { get; init; }
    public bool SmartFormatting { get; init; } = true;
    public bool LearnFromCorrections { get; init; } = true;
}

public sealed class SprekrException(string message, Exception? innerException = null)
    : Exception(message, innerException);
