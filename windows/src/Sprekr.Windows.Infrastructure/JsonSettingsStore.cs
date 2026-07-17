using System.Text.Json;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class JsonSettingsStore : ISettingsStore, IDisposable
{
    private readonly WindowsPaths paths;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly JsonSerializerOptions options = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public JsonSettingsStore(WindowsPaths paths) => this.paths = paths;

    public async Task<SprekrSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!File.Exists(paths.Settings)) return new SprekrSettings();
            await using var stream = File.OpenRead(paths.Settings);
            return await JsonSerializer.DeserializeAsync<SprekrSettings>(stream, options, cancellationToken).ConfigureAwait(false)
                ?? new SprekrSettings();
        }
        finally { gate.Release(); }
    }

    public async Task SaveAsync(SprekrSettings settings, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            paths.EnsureDirectories();
            var temporary = paths.Settings + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    await JsonSerializer.SerializeAsync(stream, settings, options, cancellationToken).ConfigureAwait(false);
                File.Move(temporary, paths.Settings, overwrite: true);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
        finally { gate.Release(); }
    }

    public void Dispose() => gate.Dispose();
}
