namespace Sprekr.Windows.Infrastructure;

public sealed class WindowsPaths
{
    public WindowsPaths(string? localAppData = null)
    {
        var baseDirectory = localAppData ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(baseDirectory))
            throw new InvalidOperationException("%LOCALAPPDATA% is niet beschikbaar voor deze Windows-gebruiker.");

        Root = Path.Combine(baseDirectory, "Sprekr");
        Models = Path.Combine(Root, "Models");
        TemporaryAudio = Path.Combine(Root, "Temporary Audio");
        Stores = Path.Combine(Root, "Stores");
        Keys = Path.Combine(Root, "Keys");
        Downloads = Path.Combine(Root, "Downloads");
        Settings = Path.Combine(Root, "settings.json");
    }

    public string Root { get; }
    public string Models { get; }
    public string TemporaryAudio { get; }
    public string Stores { get; }
    public string Keys { get; }
    public string Downloads { get; }
    public string Settings { get; }

    public void EnsureDirectories()
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(Models);
        Directory.CreateDirectory(TemporaryAudio);
        Directory.CreateDirectory(Stores);
        Directory.CreateDirectory(Keys);
        Directory.CreateDirectory(Downloads);
    }
}
