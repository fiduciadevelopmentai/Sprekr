namespace Sprekr.Windows.Core;

public sealed record TextTargetDescriptor(
    bool IsEnabled,
    bool IsPassword,
    bool IsReadOnly,
    bool SupportsEditableText,
    bool IsElevated,
    bool IsSprekr);

public static class TextDeliveryPolicy
{
    public static string? RefusalReason(TextTargetDescriptor target)
    {
        if (target.IsSprekr) return "Kies eerst een bewerkbaar veld buiten Sprekr.";
        if (target.IsElevated) return "Invoer in een als administrator gestart programma wordt door Windows geblokkeerd. Start Sprekr niet als administrator.";
        if (!target.IsEnabled) return "Het actieve veld is uitgeschakeld.";
        if (target.IsPassword) return "Sprekr voert nooit tekst in een wachtwoord- of beveiligd veld in.";
        if (target.IsReadOnly) return "Het actieve veld is alleen-lezen.";
        if (!target.SupportsEditableText) return "Het actieve doel ondersteunt geen bewerkbare tekstinvoer.";
        return null;
    }
}

public sealed class DeliveryAttemptGuard
{
    public bool WriteAttempted { get; private set; }
    public bool MayWrite => !WriteAttempted;

    public void BeginSingleWrite()
    {
        if (WriteAttempted) throw new InvalidOperationException("Een onbepaalde tekstinvoer mag nooit opnieuw worden uitgevoerd.");
        WriteAttempted = true;
    }
}
