using System.Net;
using System.Net.Http.Headers;
using System.Net.Http;
using System.Security.Cryptography;
using SharpCompress.Archives;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class ParakeetModelInstaller : IModelInstaller, IDisposable
{
    public const string ModelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8";
    public const long ArchiveSize = 487_170_055;
    public const string ArchiveSha256 = "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf";
    public static readonly Uri ArchiveUri = new(
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2");

    private static readonly string[] RequiredFiles =
        ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"];

    private readonly WindowsPaths paths;
    private readonly HttpClient client;
    private readonly bool ownsClient;
    private readonly SemaphoreSlim installGate = new(1, 1);

    public ParakeetModelInstaller(WindowsPaths paths, HttpClient? client = null)
    {
        this.paths = paths;
        this.client = client ?? new HttpClient { Timeout = TimeSpan.FromHours(2) };
        ownsClient = client is null;
    }

    public string ActiveModelDirectory => Path.Combine(paths.Models, ModelName);

    public async Task<string> EnsureInstalledAsync(IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        await installGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            paths.EnsureDirectories();
            if (await VerifyInstalledAsync(cancellationToken).ConfigureAwait(false)) return ActiveModelDirectory;
            EnsureDiskSpace();

            var partial = Path.Combine(paths.Downloads, ModelName + ".tar.bz2.partial");
            for (var attempt = 1; attempt <= 2; attempt++)
            {
                try
                {
                    await DownloadResumableAsync(partial, progress, cancellationToken).ConfigureAwait(false);
                    await VerifyArchiveAsync(partial, cancellationToken).ConfigureAwait(false);
                    ActivateArchive(partial);
                    if (!await VerifyInstalledAsync(cancellationToken).ConfigureAwait(false))
                        throw new SprekrException("Het uitgepakte Parakeet-model is onvolledig.");
                    File.Delete(partial);
                    return ActiveModelDirectory;
                }
                catch when (attempt == 1 && !cancellationToken.IsCancellationRequested)
                {
                    if (File.Exists(partial)) File.Delete(partial);
                }
            }
            throw new SprekrException("De modeldownload mislukte na één veilige herhaling. Controleer de internetverbinding en vrije schijfruimte.");
        }
        finally
        {
            installGate.Release();
        }
    }

    public Task<bool> VerifyInstalledAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(RequiredFiles.All(name =>
        {
            var file = Path.Combine(ActiveModelDirectory, name);
            return File.Exists(file) && new FileInfo(file).Length > 0;
        }));
    }

    private void EnsureDiskSpace()
    {
        var root = Path.GetPathRoot(paths.Root) ?? throw new SprekrException("Het lokale opslagstation kon niet worden bepaald.");
        var drive = new DriveInfo(root);
        if (drive.AvailableFreeSpace < 1_500_000_000)
            throw new SprekrException("Minimaal 1,5 GB vrije ruimte is nodig om het offline spraakmodel veilig te installeren.");
    }

    private async Task DownloadResumableAsync(string destination, IProgress<double>? progress, CancellationToken cancellationToken)
    {
        var existing = File.Exists(destination) ? new FileInfo(destination).Length : 0;
        using var request = new HttpRequestMessage(HttpMethod.Get, ArchiveUri);
        if (existing > 0) request.Headers.Range = new RangeHeaderValue(existing, null);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);

        var append = existing > 0 && response.StatusCode == HttpStatusCode.PartialContent;
        if (!append) existing = 0;
        response.EnsureSuccessStatusCode();

        await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var output = new FileStream(destination, append ? FileMode.Append : FileMode.Create,
            FileAccess.Write, FileShare.None, 1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var buffer = new byte[1024 * 1024];
        long written = existing;
        int read;
        while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            written += read;
            progress?.Report(Math.Min(1, (double)written / ArchiveSize));
        }
        await output.FlushAsync(cancellationToken).ConfigureAwait(false);
        if (written != ArchiveSize)
            throw new SprekrException($"De modeldownload is onvolledig ({written:N0} van {ArchiveSize:N0} bytes).");
    }

    public static async Task VerifyArchiveAsync(string archivePath, CancellationToken cancellationToken = default)
    {
        var length = new FileInfo(archivePath).Length;
        if (length != ArchiveSize)
            throw new SprekrException($"Onverwachte modelgrootte: {length:N0} bytes.");
        await using var stream = File.OpenRead(archivePath);
        var digest = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false)).ToLowerInvariant();
        if (!CryptographicOperations.FixedTimeEquals(
                Convert.FromHexString(digest), Convert.FromHexString(ArchiveSha256)))
            throw new SprekrException("De SHA-256-controle van het model is mislukt; het archief wordt niet gebruikt.");
    }

    private void ActivateArchive(string archivePath)
    {
        var extractionRoot = Path.Combine(paths.Models, $".{ModelName}.extract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(extractionRoot);
        try
        {
            using var archive = ArchiveFactory.OpenArchive(archivePath);
            foreach (var entry in archive.Entries.Where(entry => !entry.IsDirectory))
            {
                if (string.IsNullOrWhiteSpace(entry.Key)) continue;
                var target = ResolveArchiveEntry(extractionRoot, entry.Key);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                using var source = entry.OpenEntryStream();
                using var destination = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                source.CopyTo(destination);
            }

            var sourceDirectory = Directory.GetDirectories(extractionRoot, ModelName, SearchOption.AllDirectories).SingleOrDefault()
                ?? (RequiredFiles.All(name => File.Exists(Path.Combine(extractionRoot, name))) ? extractionRoot : null)
                ?? throw new SprekrException("Het modelarchief bevat niet de verwachte mapstructuur.");
            if (!RequiredFiles.All(name => File.Exists(Path.Combine(sourceDirectory, name))))
                throw new SprekrException("Het modelarchief mist een vereist ONNX- of tokenbestand.");

            var staging = Path.Combine(paths.Models, $".{ModelName}.staging-{Guid.NewGuid():N}");
            Directory.Move(sourceDirectory, staging);
            var backup = Path.Combine(paths.Models, $".{ModelName}.previous-{Guid.NewGuid():N}");
            var hadPrevious = Directory.Exists(ActiveModelDirectory);
            if (hadPrevious) Directory.Move(ActiveModelDirectory, backup);
            try
            {
                Directory.Move(staging, ActiveModelDirectory);
                if (hadPrevious && Directory.Exists(backup))
                {
                    try { Directory.Delete(backup, recursive: true); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
            }
            catch
            {
                if (!Directory.Exists(ActiveModelDirectory) && Directory.Exists(backup))
                    Directory.Move(backup, ActiveModelDirectory);
                throw;
            }
        }
        finally
        {
            if (Directory.Exists(extractionRoot)) Directory.Delete(extractionRoot, recursive: true);
        }
    }

    public static string ResolveArchiveEntry(string root, string entryKey)
    {
        var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var target = Path.GetFullPath(Path.Combine(normalizedRoot, entryKey.Replace('/', Path.DirectorySeparatorChar)));
        if (!target.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            throw new SprekrException("Onveilig pad in modelarchief geweigerd.");
        return target;
    }

    public void Dispose()
    {
        installGate.Dispose();
        if (ownsClient) client.Dispose();
    }
}
