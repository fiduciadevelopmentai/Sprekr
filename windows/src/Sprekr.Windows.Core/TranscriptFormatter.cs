using System.Text.RegularExpressions;

namespace Sprekr.Windows.Core;

public static partial class TranscriptFormatter
{
    public static string Format(string transcript, RecognitionLanguage language)
    {
        if (string.IsNullOrWhiteSpace(transcript)) return string.Empty;

        var text = transcript.Trim();
        text = ReplaceSpokenEmails(text, language);
        text = ReplaceSymbols(text, language);
        text = ReplaceLayoutCommands(text, language);
        text = ReplaceTerminalPunctuation(text, language);
        text = InferQuestionMark(text, language);
        text = NormalizeSpacing(text);
        return text;
    }

    private static string ReplaceLayoutCommands(string text, RecognitionLanguage language)
    {
        var paragraphs = language switch
        {
            RecognitionLanguage.Dutch => @"\b(nieuwe alinea|volgende alinea|begin een nieuwe alinea|start een nieuwe alinea|sla een regel over)\b",
            RecognitionLanguage.English => @"\b(new paragraph|next paragraph|start a new paragraph|skip a line)\b",
            _ => @"\b(nieuwe alinea|volgende alinea|begin een nieuwe alinea|start een nieuwe alinea|sla een regel over|new paragraph|next paragraph|start a new paragraph|skip a line)\b"
        };
        var lines = language switch
        {
            RecognitionLanguage.Dutch => @"\b(nieuwe regel|volgende regel|regelafbreking)\b",
            RecognitionLanguage.English => @"\b(new line|next line|line break)\b",
            _ => @"\b(nieuwe regel|volgende regel|regelafbreking|new line|next line|line break)\b"
        };
        var bullets = language switch
        {
            RecognitionLanguage.Dutch => @"\b(opsommingsteken|bullet point)\b",
            RecognitionLanguage.English => @"\b(bullet point|bullet)\b",
            _ => @"\b(opsommingsteken|bullet point|bullet)\b"
        };

        text = Regex.Replace(text, paragraphs, "\n\n", Options);
        text = Regex.Replace(text, lines, "\n", Options);
        return Regex.Replace(text, bullets, "\n• ", Options);
    }

    private static string ReplaceTerminalPunctuation(string text, RecognitionLanguage language)
    {
        var alternatives = language switch
        {
            RecognitionLanguage.Dutch => new[] { ("vraagteken", "?"), ("uitroepteken", "!") },
            RecognitionLanguage.English => new[] { ("question mark", "?"), ("exclamation mark", "!"), ("full stop", ".") },
            _ => new[] { ("vraagteken|question mark", "?"), ("uitroepteken|exclamation mark", "!"), ("full stop", ".") }
        };
        foreach (var (phrase, punctuation) in alternatives)
            text = Regex.Replace(text, $@"\s+(?:{phrase})[\s.?!]*$", punctuation, Options);
        return text;
    }

    private static string ReplaceSymbols(string text, RecognitionLanguage language)
    {
        var replacements = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["apenstaartje"] = "@", ["at sign"] = "@", ["hashtag"] = "#",
            ["procent"] = "%", ["percent"] = "%", ["ampersand"] = "&"
        };
        foreach (var pair in replacements)
            text = Regex.Replace(text, $@"\b{Regex.Escape(pair.Key)}\b", pair.Value, Options);
        return text;
    }

    private static string ReplaceSpokenEmails(string text, RecognitionLanguage language)
    {
        var at = language == RecognitionLanguage.Dutch ? "apenstaartje" :
            language == RecognitionLanguage.English ? "at" : "apenstaartje|at";
        var dot = language == RecognitionLanguage.Dutch ? "punt" :
            language == RecognitionLanguage.English ? "dot" : "punt|dot";
        return Regex.Replace(
            text,
            $@"\b([\p{{L}}0-9._%+-]+)\s+(?:{at})\s+([\p{{L}}0-9-]+)\s+(?:{dot})\s+([\p{{L}}]{{2,}})\b",
            match => $"{match.Groups[1].Value}@{match.Groups[2].Value}.{match.Groups[3].Value}".ToLowerInvariant(),
            Options);
    }

    private static string InferQuestionMark(string text, RecognitionLanguage language)
    {
        if (text.EndsWith('?') || text.EndsWith('!') || text.Contains("\n• ", StringComparison.Ordinal)) return text;
        var starters = language switch
        {
            RecognitionLanguage.Dutch => "wie|wat|waar|wanneer|waarom|hoe|welke|welk|kan|kun|is|zijn|heb|heeft|wil|zou|mag|moet",
            RecognitionLanguage.English => "who|what|where|when|why|how|which|can|could|is|are|do|does|did|will|would|should|may",
            _ => "wie|wat|waar|wanneer|waarom|hoe|welke|welk|kan|kun|is|zijn|heb|heeft|wil|zou|mag|moet|who|what|where|when|why|how|which|can|could|are|do|does|did|will|would|should|may"
        };
        if (!Regex.IsMatch(text, $@"^(?:{starters})\b", Options)) return text;
        return text.EndsWith('.') ? text[..^1] + "?" : text + "?";
    }

    private static string NormalizeSpacing(string text)
    {
        text = Regex.Replace(text, @"[ \t]+([,.!?;:])", "$1");
        text = Regex.Replace(text, @"[ \t]*\r?\n[ \t]*", "\n");
        text = Regex.Replace(text, @"\n+[ \t]*(?=•)", "\n\n");
        text = Regex.Replace(text, @"\n•[ \t]+", "\n• ");
        text = Regex.Replace(text, @"\n{3,}", "\n\n");
        return text.Trim();
    }

    private const RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
}
