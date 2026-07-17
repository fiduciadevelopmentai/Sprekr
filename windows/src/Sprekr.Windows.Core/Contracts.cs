namespace Sprekr.Windows.Core;

public interface ITranscriptionEngine : IAsyncDisposable
{
    Task<TranscriptionResult> TranscribeAsync(AudioRecording recording, CancellationToken cancellationToken = default);
}

public interface IModelInstaller
{
    string ActiveModelDirectory { get; }
    Task<string> EnsureInstalledAsync(IProgress<double>? progress = null, CancellationToken cancellationToken = default);
    Task<bool> VerifyInstalledAsync(CancellationToken cancellationToken = default);
}

public interface IAudioCaptureService : IAsyncDisposable
{
    bool IsRecording { get; }
    IReadOnlyList<MicrophoneDevice> GetMicrophones();
    Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default);
    Task<AudioRecording> StopAsync(CancellationToken cancellationToken = default);
    Task CancelAsync(bool retainForUndo, CancellationToken cancellationToken = default);
    Task<AudioRecording?> UndoCancellationAsync(CancellationToken cancellationToken = default);
    Task RemoveTemporaryAsync(AudioRecording recording, CancellationToken cancellationToken = default);
}

public interface IAudioCuePlayer
{
    Task PlayStartAsync(CancellationToken cancellationToken = default);
    Task PlayCompletionAsync(CancellationToken cancellationToken = default);
}

public interface IHotkeyService : IDisposable
{
    event EventHandler? Pressed;
    event EventHandler? Released;
    event EventHandler? EscapePressed;
    event EventHandler? UndoPressed;
    void Start();
    void StopListening();
}

public interface ITextDeliveryService
{
    Task<DeliveryResult> DeliverAsync(string text, CancellationToken cancellationToken = default);
}

public interface IEncryptedStore<T>
{
    Task<T> LoadAsync(T fallback, CancellationToken cancellationToken = default);
    Task SaveAsync(T value, CancellationToken cancellationToken = default);
    Task RemoveAsync(CancellationToken cancellationToken = default);
}

public interface ITranscriptRepository
{
    Task<IReadOnlyList<TranscriptRecord>> GetAllAsync(CancellationToken cancellationToken = default);
    Task AppendAsync(TranscriptRecord record, CancellationToken cancellationToken = default);
    Task DeleteAsync(Guid id, CancellationToken cancellationToken = default);
    Task ClearAsync(CancellationToken cancellationToken = default);
}

public interface IDictionaryRepository
{
    Task<IReadOnlyList<DictionaryEntry>> GetAllAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(DictionaryEntry entry, CancellationToken cancellationToken = default);
    Task DeleteAsync(Guid id, CancellationToken cancellationToken = default);
    Task<(string Text, int Fixes)> ApplyAsync(string text, RecognitionLanguage language, CancellationToken cancellationToken = default);
}

public interface ILocalTranslationService
{
    bool IsAvailable { get; }
    Task<(string Text, string? Notice)> TranslateAsync(string text, RecognitionLanguage outputLanguage, CancellationToken cancellationToken = default);
}

public interface IStartupService
{
    bool IsEnabled { get; }
    void SetEnabled(bool enabled);
}

public interface IFlowBarController
{
    void SetState(FlowBarState state, string message = "");
}

public interface ISettingsStore
{
    Task<SprekrSettings> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(SprekrSettings settings, CancellationToken cancellationToken = default);
}
