using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Sprekr.Windows.Core;

public static class DictionaryCorrectionEngine
{
    public sealed record Result(string Text, int Fixes, IReadOnlyList<DictionaryEntry> Entries);

    public static Result Apply(IReadOnlyList<DictionaryEntry> source, string text, RecognitionLanguage language)
    {
        var entries = source.ToArray();
        var fixes = 0;
        var rules = entries
            .SelectMany((entry, index) => entry.IsActive && LanguageMatches(entry.Language, language)
                ? entry.Aliases.Append(entry.PreferredSpelling).Select(term => (Term: term, Index: index))
                : [])
            .Where(rule => !string.IsNullOrWhiteSpace(rule.Term))
            .OrderByDescending(rule => rule.Term.Length)
            .ToArray();

        foreach (var rule in rules)
        {
            var pattern = $@"(?<![\p{{L}}\p{{N}}]){Regex.Escape(rule.Term)}(?![\p{{L}}\p{{N}}])";
            text = Regex.Replace(text, pattern, match =>
            {
                if (string.Equals(match.Value, entries[rule.Index].PreferredSpelling, StringComparison.Ordinal))
                    return match.Value;
                fixes++;
                entries[rule.Index] = entries[rule.Index] with { AppliedCount = entries[rule.Index].AppliedCount + 1 };
                return entries[rule.Index].PreferredSpelling;
            }, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        return new Result(text, fixes, entries);
    }

    public static string NormalizedKey(string value)
    {
        var normalized = value.Trim().Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder();
        foreach (var character in normalized)
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark)
                builder.Append(char.ToLowerInvariant(character));
        return builder.ToString().Normalize(NormalizationForm.FormC);
    }

    private static bool LanguageMatches(RecognitionLanguage entry, RecognitionLanguage requested) =>
        entry == RecognitionLanguage.Automatic || requested == RecognitionLanguage.Automatic || entry == requested;
}
