using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class EncryptedJsonStore<T> : IEncryptedStore<T>, IDisposable
{
    private static readonly byte[] Magic = "SPK1"u8.ToArray();
    private readonly string dataPath;
    private readonly string keyPath;
    private readonly byte[] associatedData;
    private readonly JsonSerializerOptions jsonOptions;
    private readonly SemaphoreSlim gate = new(1, 1);

    public EncryptedJsonStore(WindowsPaths paths, string filename, string keyAccount)
    {
        paths.EnsureDirectories();
        dataPath = Path.Combine(paths.Stores, filename);
        keyPath = Path.Combine(paths.Keys, keyAccount + ".dpapi");
        associatedData = Encoding.UTF8.GetBytes("FiduciaDevelopment.Sprekr:" + filename);
        jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = false };
    }

    public async Task<T> LoadAsync(T fallback, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!File.Exists(dataPath)) return fallback;
            var key = LoadKey(ciphertextExists: true);
            var envelope = await File.ReadAllBytesAsync(dataPath, cancellationToken).ConfigureAwait(false);
            if (envelope.Length < Magic.Length + 12 + 16 || !envelope.AsSpan(0, Magic.Length).SequenceEqual(Magic))
                throw new SprekrException("De versleutelde Sprekr-opslag heeft een onbekend of beschadigd formaat.");

            var nonce = envelope.AsSpan(4, 12);
            var tag = envelope.AsSpan(16, 16);
            var ciphertext = envelope.AsSpan(32);
            var plaintext = new byte[ciphertext.Length];
            try
            {
                using var aes = new AesGcm(key, 16);
                aes.Decrypt(nonce, ciphertext, tag, plaintext, associatedData);
                return JsonSerializer.Deserialize<T>(plaintext, jsonOptions)
                    ?? throw new SprekrException("De ontsleutelde Sprekr-opslag bevat geen geldige gegevens.");
            }
            catch (CryptographicException exception)
            {
                throw new SprekrException("History of Dictionary kon niet worden ontsleuteld. De bestaande gegevens en sleutel blijven onaangeroerd.", exception);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(key);
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task SaveAsync(T value, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var key = LoadKey(ciphertextExists: File.Exists(dataPath));
            var plaintext = JsonSerializer.SerializeToUtf8Bytes(value, jsonOptions);
            var nonce = RandomNumberGenerator.GetBytes(12);
            var tag = new byte[16];
            var ciphertext = new byte[plaintext.Length];
            try
            {
                using var aes = new AesGcm(key, 16);
                aes.Encrypt(nonce, plaintext, ciphertext, tag, associatedData);
                var envelope = new byte[4 + nonce.Length + tag.Length + ciphertext.Length];
                Magic.CopyTo(envelope, 0);
                nonce.CopyTo(envelope, 4);
                tag.CopyTo(envelope, 16);
                ciphertext.CopyTo(envelope, 32);
                await AtomicWriteAsync(dataPath, envelope, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(key);
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task RemoveAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (File.Exists(dataPath)) File.Delete(dataPath);
        }
        finally
        {
            gate.Release();
        }
    }

    private byte[] LoadKey(bool ciphertextExists)
    {
        if (File.Exists(keyPath))
        {
            try { return Dpapi.Unprotect(File.ReadAllBytes(keyPath)); }
            catch (Exception exception) when (exception is not SprekrException)
            {
                throw new SprekrException("De DPAPI-sleutel van Sprekr kon niet voor deze Windows-gebruiker worden geopend.", exception);
            }
        }
        if (ciphertextExists)
            throw new SprekrException("Versleutelde Sprekr-gegevens bestaan, maar de DPAPI-sleutel ontbreekt. Er wordt geen vervangende sleutel gemaakt.");

        var key = RandomNumberGenerator.GetBytes(32);
        var protectedKey = Dpapi.Protect(key);
        var temporary = keyPath + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllBytes(temporary, protectedKey);
        try { File.Move(temporary, keyPath, overwrite: false); }
        catch
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            CryptographicOperations.ZeroMemory(key);
            throw;
        }
        return key;
    }

    private static async Task AtomicWriteAsync(string path, byte[] data, CancellationToken cancellationToken)
    {
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllBytesAsync(temporary, data, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public void Dispose() => gate.Dispose();
}
