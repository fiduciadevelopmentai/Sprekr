using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class WasapiAudioCaptureService : IAudioCaptureService
{
    private readonly WindowsPaths paths;
    private readonly object gate = new();
    private WasapiCapture? capture;
    private WaveFileWriter? writer;
    private TaskCompletionSource? stopped;
    private string? nativePath;
    private DateTimeOffset startedAt;
    private AudioRecording? cancelledRecording;
    private CancellationTokenSource? cancellationExpiry;

    public WasapiAudioCaptureService(WindowsPaths paths) => this.paths = paths;

    public bool IsRecording
    {
        get { lock (gate) return capture is not null; }
    }

    public IReadOnlyList<MicrophoneDevice> GetMicrophones()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID;
            return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
                .Select(device => new MicrophoneDevice(device.ID, device.FriendlyName, device.ID == defaultId))
                .ToArray();
        }
        catch (Exception exception)
        {
            throw new SprekrException("Geen beschikbare microfoon gevonden. Controleer Instellingen > Privacy en beveiliging > Microfoon.", exception);
        }
    }

    public Task StartAsync(string? microphoneId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (capture is not null) throw new SprekrException("Er loopt al een audio-opname.");
            paths.EnsureDirectories();
            using var enumerator = new MMDeviceEnumerator();
            var device = string.IsNullOrWhiteSpace(microphoneId)
                ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications)
                : enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
                    .FirstOrDefault(item => item.ID == microphoneId)
                    ?? throw new SprekrException("De gekozen microfoon is niet meer beschikbaar. Kies een ander apparaat in Instellingen.");

            nativePath = Path.Combine(paths.TemporaryAudio, $"capture-{Guid.NewGuid():N}.wav");
            capture = new WasapiCapture(device);
            writer = new WaveFileWriter(nativePath, capture.WaveFormat);
            stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            capture.DataAvailable += OnDataAvailable;
            capture.RecordingStopped += OnRecordingStopped;
            startedAt = DateTimeOffset.UtcNow;
            try
            {
                capture.StartRecording();
            }
            catch (Exception exception)
            {
                DisposeCapture();
                throw new SprekrException("De microfoon kon niet worden gestart. Controleer Windows-microfoontoegang en of een ander programma het apparaat exclusief gebruikt.", exception);
            }
        }
        return Task.CompletedTask;
    }

    public async Task<AudioRecording> StopAsync(CancellationToken cancellationToken = default)
    {
        Task wait;
        string source;
        TimeSpan duration;
        lock (gate)
        {
            if (capture is null || nativePath is null || stopped is null)
                throw new SprekrException("Er is geen actieve opname om te stoppen.");
            wait = stopped.Task;
            source = nativePath;
            duration = DateTimeOffset.UtcNow - startedAt;
            capture.StopRecording();
        }
        await wait.WaitAsync(cancellationToken).ConfigureAwait(false);

        var normalized = Path.Combine(paths.TemporaryAudio, $"recording-{Guid.NewGuid():N}.wav");
        try
        {
            using var reader = new WaveFileReader(source);
            using var resampler = new MediaFoundationResampler(reader, new WaveFormat(16_000, 16, 1))
            {
                ResamplerQuality = 60
            };
            WaveFileWriter.CreateWaveFile(normalized, resampler);
            return new AudioRecording(normalized, duration, 16_000);
        }
        catch (Exception exception)
        {
            throw new SprekrException("De opname kon niet naar 16 kHz mono worden verwerkt.", exception);
        }
        finally
        {
            if (File.Exists(source)) File.Delete(source);
        }
    }

    public async Task CancelAsync(bool retainForUndo, CancellationToken cancellationToken = default)
    {
        AudioRecording? recording = null;
        if (IsRecording) recording = await StopAsync(cancellationToken).ConfigureAwait(false);

        cancellationExpiry?.Cancel();
        cancellationExpiry?.Dispose();
        cancellationExpiry = null;

        if (retainForUndo && recording is not null)
        {
            cancelledRecording = recording;
            cancellationExpiry = new CancellationTokenSource();
            _ = ExpireCancelledRecordingAsync(cancellationExpiry.Token);
            return;
        }

        if (recording is not null) await RemoveTemporaryAsync(recording, cancellationToken).ConfigureAwait(false);
        if (cancelledRecording is not null)
        {
            await RemoveTemporaryAsync(cancelledRecording, cancellationToken).ConfigureAwait(false);
            cancelledRecording = null;
        }
    }

    public Task<AudioRecording?> UndoCancellationAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        cancellationExpiry?.Cancel();
        cancellationExpiry?.Dispose();
        cancellationExpiry = null;
        var result = cancelledRecording;
        cancelledRecording = null;
        return Task.FromResult(result);
    }

    public Task RemoveTemporaryAsync(AudioRecording recording, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var expectedRoot = Path.GetFullPath(paths.TemporaryAudio).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var target = Path.GetFullPath(recording.Path);
        if (!target.StartsWith(expectedRoot, StringComparison.OrdinalIgnoreCase))
            throw new SprekrException("Weigering om audio buiten de tijdelijke Sprekr-map te verwijderen.");
        if (File.Exists(target)) File.Delete(target);
        return Task.CompletedTask;
    }

    private async Task ExpireCancelledRecordingAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(6), cancellationToken).ConfigureAwait(false);
            var recording = cancelledRecording;
            cancelledRecording = null;
            if (recording is not null) await RemoveTemporaryAsync(recording, CancellationToken.None).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs eventArgs)
    {
        lock (gate) writer?.Write(eventArgs.Buffer, 0, eventArgs.BytesRecorded);
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs eventArgs)
    {
        lock (gate)
        {
            var completion = stopped;
            DisposeCapture();
            if (eventArgs.Exception is null) completion?.TrySetResult();
            else completion?.TrySetException(eventArgs.Exception);
        }
    }

    private void DisposeCapture()
    {
        if (capture is not null)
        {
            capture.DataAvailable -= OnDataAvailable;
            capture.RecordingStopped -= OnRecordingStopped;
            capture.Dispose();
        }
        writer?.Dispose();
        capture = null;
        writer = null;
        stopped = null;
        nativePath = null;
    }

    public async ValueTask DisposeAsync()
    {
        await CancelAsync(retainForUndo: false).ConfigureAwait(false);
        lock (gate) DisposeCapture();
    }
}
