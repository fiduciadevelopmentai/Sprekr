using Sprekr.Windows.Core;
using Sprekr.Windows.Infrastructure;

namespace Sprekr.Windows.Tests;

public sealed class SecurityAndStorageTests : IDisposable
{
    private readonly string testRoot = Path.Combine(Path.GetTempPath(), "SprekrTests-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void ModelIdentityIsPinned()
    {
        Assert.Equal(487_170_055, ParakeetModelInstaller.ArchiveSize);
        Assert.Equal("5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf", ParakeetModelInstaller.ArchiveSha256);
        Assert.Equal("https", ParakeetModelInstaller.ArchiveUri.Scheme);
        Assert.Equal("github.com", ParakeetModelInstaller.ArchiveUri.Host);
    }

    [Fact]
    public void ArchiveTraversalIsRefused()
    {
        var root = Path.Combine(testRoot, "extract");
        Directory.CreateDirectory(root);
        Assert.Throws<SprekrException>(() => ParakeetModelInstaller.ResolveArchiveEntry(root, "../escape.txt"));
        Assert.Throws<SprekrException>(() => ParakeetModelInstaller.ResolveArchiveEntry(root, "folder/../../escape.txt"));
    }

    [Fact]
    public void SafeArchivePathStaysInsideExtractionRoot()
    {
        var root = Path.Combine(testRoot, "extract");
        Directory.CreateDirectory(root);
        var resolved = ParakeetModelInstaller.ResolveArchiveEntry(root, "model/tokens.txt");
        Assert.StartsWith(Path.GetFullPath(root), resolved, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AesGcmAndDpapiRoundTripForCurrentUser()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var paths = new WindowsPaths(testRoot);
        var store = new EncryptedJsonStore<List<string>>(paths, "test.enc", "test.key");
        await store.SaveAsync(["lokaal", "versleuteld"], cancellationToken);
        Assert.Equal(["lokaal", "versleuteld"], await store.LoadAsync([], cancellationToken));
        var ciphertext = await File.ReadAllBytesAsync(Path.Combine(paths.Stores, "test.enc"), cancellationToken);
        Assert.False(Convert.ToHexString(ciphertext).Contains(Convert.ToHexString("lokaal"u8), StringComparison.Ordinal));
    }

    [Fact]
    public async Task MissingKeyNeverCreatesReplacementWhenCiphertextExists()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var paths = new WindowsPaths(testRoot);
        var store = new EncryptedJsonStore<List<string>>(paths, "history.enc", "history.key");
        await store.SaveAsync(["geheim"], cancellationToken);
        var keyPath = Path.Combine(paths.Keys, "history.key.dpapi");
        File.Delete(keyPath);
        var error = await Assert.ThrowsAsync<SprekrException>(() => store.LoadAsync([], cancellationToken));
        Assert.Contains("geen vervangende sleutel", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(File.Exists(keyPath));
    }

    [Fact]
    public async Task CorruptCiphertextIsPreservedAndRejected()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var paths = new WindowsPaths(testRoot);
        var store = new EncryptedJsonStore<List<string>>(paths, "history.enc", "history.key");
        await store.SaveAsync(["geheim"], cancellationToken);
        var dataPath = Path.Combine(paths.Stores, "history.enc");
        var data = await File.ReadAllBytesAsync(dataPath, cancellationToken);
        data[^1] ^= 0xff;
        await File.WriteAllBytesAsync(dataPath, data, cancellationToken);
        await Assert.ThrowsAsync<SprekrException>(() => store.LoadAsync([], cancellationToken));
        Assert.True(File.Exists(dataPath));
    }

    [Fact]
    public void PathsStayUnderLocalAppDataRoot()
    {
        var paths = new WindowsPaths(testRoot);
        Assert.StartsWith(testRoot, paths.Models, StringComparison.OrdinalIgnoreCase);
        Assert.StartsWith(testRoot, paths.TemporaryAudio, StringComparison.OrdinalIgnoreCase);
        Assert.StartsWith(testRoot, paths.Stores, StringComparison.OrdinalIgnoreCase);
    }

    public void Dispose()
    {
        if (Directory.Exists(testRoot)) Directory.Delete(testRoot, recursive: true);
    }
}
