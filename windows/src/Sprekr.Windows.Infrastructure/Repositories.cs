namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class TranscriptRepository(IEncryptedStore<List<TranscriptRecord>> store) : ITranscriptRepository
{
    public async Task<IReadOnlyList<TranscriptRecord>> GetAllAsync(CancellationToken cancellationToken = default) =>
        (await store.LoadAsync([], cancellationToken).ConfigureAwait(false)).OrderByDescending(item => item.CreatedAt).ToArray();

    public async Task AppendAsync(TranscriptRecord record, CancellationToken cancellationToken = default)
    {
        var records = (await store.LoadAsync([], cancellationToken).ConfigureAwait(false)).ToList();
        records.RemoveAll(item => item.Id == record.Id);
        records.Add(record);
        await store.SaveAsync(records.OrderByDescending(item => item.CreatedAt).ToList(), cancellationToken).ConfigureAwait(false);
    }

    public async Task DeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var records = (await store.LoadAsync([], cancellationToken).ConfigureAwait(false)).Where(item => item.Id != id).ToList();
        await store.SaveAsync(records, cancellationToken).ConfigureAwait(false);
    }

    public Task ClearAsync(CancellationToken cancellationToken = default) => store.RemoveAsync(cancellationToken);
}

public sealed class DictionaryRepository(IEncryptedStore<List<DictionaryEntry>> store) : IDictionaryRepository
{
    public async Task<IReadOnlyList<DictionaryEntry>> GetAllAsync(CancellationToken cancellationToken = default) =>
        (await store.LoadAsync([], cancellationToken).ConfigureAwait(false))
            .OrderBy(item => item.PreferredSpelling, StringComparer.CurrentCultureIgnoreCase).ToArray();

    public async Task SaveAsync(DictionaryEntry entry, CancellationToken cancellationToken = default)
    {
        var entries = (await store.LoadAsync([], cancellationToken).ConfigureAwait(false)).ToList();
        entries.RemoveAll(item => item.Id == entry.Id);
        entries.Add(entry);
        await store.SaveAsync(entries, cancellationToken).ConfigureAwait(false);
    }

    public async Task DeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var entries = (await store.LoadAsync([], cancellationToken).ConfigureAwait(false)).Where(item => item.Id != id).ToList();
        await store.SaveAsync(entries, cancellationToken).ConfigureAwait(false);
    }

    public async Task<(string Text, int Fixes)> ApplyAsync(
        string text, RecognitionLanguage language, CancellationToken cancellationToken = default)
    {
        var entries = (await store.LoadAsync([], cancellationToken).ConfigureAwait(false)).ToList();
        var result = DictionaryCorrectionEngine.Apply(entries, text, language);
        if (result.Fixes > 0) await store.SaveAsync(result.Entries.ToList(), cancellationToken).ConfigureAwait(false);
        return (result.Text, result.Fixes);
    }
}
