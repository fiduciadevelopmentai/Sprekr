namespace Sprekr.Windows.Core;

public sealed class PassthroughTranslationService : ILocalTranslationService
{
    public bool IsAvailable => false;

    public Task<(string Text, string? Notice)> TranslateAsync(
        string text,
        RecognitionLanguage outputLanguage,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var notice = outputLanguage == RecognitionLanguage.Automatic
            ? null
            : "Lokale vertaling is nog niet beschikbaar op Windows; de brontekst is behouden.";
        return Task.FromResult((text, notice));
    }
}
