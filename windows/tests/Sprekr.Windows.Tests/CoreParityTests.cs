using System.Text.Json;
using Sprekr.Windows.Core;

namespace Sprekr.Windows.Tests;

public sealed class CoreParityTests
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    [Theory]
    [MemberData(nameof(GoldenFormattingCases))]
    public void FormatterMatchesSharedGoldenFixture(string input, RecognitionLanguage language, string expected) =>
        Assert.Equal(expected, TranscriptFormatter.Format(input, language));

    public static TheoryData<string, RecognitionLanguage, string> GoldenFormattingCases()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "fixtures", "formatter-golden.json");
        var fixtures = JsonSerializer.Deserialize<List<FormatterFixture>>(File.ReadAllText(path), JsonOptions)!;
        var data = new TheoryData<string, RecognitionLanguage, string>();
        foreach (var fixture in fixtures)
            data.Add(fixture.Input, Enum.Parse<RecognitionLanguage>(fixture.Language), fixture.Expected);
        return data;
    }

    [Fact]
    public void HoldStartsOnPressAndStopsOnRelease()
    {
        var machine = new DictationStateMachine();
        Assert.Equal(DictationAction.Start, machine.Press(DictationMode.Hold));
        Assert.Equal(DictationAction.StopAndProcess, machine.Release(DictationMode.Hold));
        Assert.Equal(DictationState.Processing, machine.State);
    }

    [Fact]
    public void ToggleIgnoresReleaseAndStopsOnSecondPress()
    {
        var machine = new DictationStateMachine();
        Assert.Equal(DictationAction.Start, machine.Press(DictationMode.Toggle));
        Assert.Equal(DictationAction.None, machine.Release(DictationMode.Toggle));
        Assert.Equal(DictationAction.StopAndProcess, machine.Press(DictationMode.Toggle));
    }

    [Fact]
    public void EscapeCreatesUndoWindow()
    {
        var machine = new DictationStateMachine();
        machine.Press(DictationMode.Hold);
        Assert.Equal(DictationAction.Cancel, machine.Escape());
        Assert.Equal(DictationState.CancelledUndoWindow, machine.State);
        Assert.Equal(DictationAction.UndoCancel, machine.Undo());
    }

    [Fact]
    public void ShortcutConflictsDoNotStartTwice()
    {
        var machine = new DictationStateMachine();
        Assert.Equal(DictationAction.Start, machine.Press(DictationMode.Hold));
        Assert.Equal(DictationAction.None, machine.Press(DictationMode.Hold));
    }

    [Fact]
    public void DictionaryAppliesAliasesAndCountsFixes()
    {
        var entry = new DictionaryEntry(Guid.NewGuid(), "Sprekr", ["spreker"], RecognitionLanguage.Automatic, true, 0, DateTimeOffset.UtcNow);
        var result = DictionaryCorrectionEngine.Apply([entry], "open spreker", RecognitionLanguage.Dutch);
        Assert.Equal("open Sprekr", result.Text);
        Assert.Equal(1, result.Fixes);
        Assert.Equal(1, result.Entries[0].AppliedCount);
    }

    [Fact]
    public void DictionaryHonorsLanguageAndActiveState()
    {
        var entry = new DictionaryEntry(Guid.NewGuid(), "microfoon", ["microfon"], RecognitionLanguage.Dutch, false, 0, DateTimeOffset.UtcNow);
        var result = DictionaryCorrectionEngine.Apply([entry], "microfon", RecognitionLanguage.English);
        Assert.Equal("microfon", result.Text);
        Assert.Equal(0, result.Fixes);
    }

    [Fact]
    public void InsightsRemainLocalAndDeterministic()
    {
        var records = new[]
        {
            new TranscriptRecord(Guid.NewGuid(), "een twee drie", new DateTimeOffset(2026, 7, 17, 12, 0, 0, TimeSpan.Zero), 2, 1),
            new TranscriptRecord(Guid.NewGuid(), "vier vijf", new DateTimeOffset(2026, 7, 16, 12, 0, 0, TimeSpan.Zero), 2, 2)
        };
        var result = InsightsService.Summarize(records, new DateTimeOffset(2026, 7, 17, 14, 0, 0, TimeSpan.Zero));
        Assert.Equal(5, result.TotalWords);
        Assert.Equal(75, result.AverageWordsPerMinute);
        Assert.Equal(2, result.CurrentStreak);
        Assert.Equal(3, result.DictionaryFixes);
    }

    [Theory]
    [InlineData(true, false, false, true, false, false, "uitgeschakeld")]
    [InlineData(false, true, false, true, false, false, "wachtwoord")]
    [InlineData(false, false, true, true, false, false, "alleen-lezen")]
    [InlineData(false, false, false, false, false, false, "geen bewerkbare")]
    [InlineData(false, false, false, true, true, false, "administrator")]
    public void UnsafeTargetsAreRefused(
        bool disabled, bool password, bool readOnly, bool editable, bool elevated, bool self, string expected)
    {
        var reason = TextDeliveryPolicy.RefusalReason(new TextTargetDescriptor(
            !disabled, password, readOnly, editable, elevated, self));
        Assert.Contains(expected, reason!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void EditableStandardTargetIsAllowed() =>
        Assert.Null(TextDeliveryPolicy.RefusalReason(new TextTargetDescriptor(true, false, false, true, false, false)));

    [Fact]
    public void IndeterminateWriteCanNeverBeRetried()
    {
        var guard = new DeliveryAttemptGuard();
        guard.BeginSingleWrite();
        Assert.False(guard.MayWrite);
        Assert.Throws<InvalidOperationException>(guard.BeginSingleWrite);
    }

    [Fact]
    public async Task ExplicitWindowsTranslationSafelyKeepsSourceText()
    {
        var service = new PassthroughTranslationService();
        var result = await service.TranslateAsync("Brontekst", RecognitionLanguage.English, TestContext.Current.CancellationToken);
        Assert.Equal("Brontekst", result.Text);
        Assert.NotNull(result.Notice);
        Assert.False(service.IsAvailable);
    }

    private sealed record FormatterFixture(string Input, string Language, string Expected);
}
