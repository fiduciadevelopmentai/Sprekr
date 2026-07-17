namespace Sprekr.Windows.Core;

public sealed class DictationCoordinator : IAsyncDisposable
{
    private readonly DictationStateMachine stateMachine = new();
    private readonly IAudioCaptureService audioCapture;
    private readonly IAudioCuePlayer cuePlayer;
    private readonly ITranscriptionEngine transcriptionEngine;
    private readonly IModelInstaller modelInstaller;
    private readonly ITextDeliveryService textDelivery;
    private readonly ITranscriptRepository transcripts;
    private readonly IDictionaryRepository dictionary;
    private readonly ILocalTranslationService translation;
    private readonly IFlowBarController flowBar;
    private readonly Func<SprekrSettings> settings;
    private readonly SemaphoreSlim operationGate = new(1, 1);

    public DictationCoordinator(
        IAudioCaptureService audioCapture,
        IAudioCuePlayer cuePlayer,
        ITranscriptionEngine transcriptionEngine,
        IModelInstaller modelInstaller,
        ITextDeliveryService textDelivery,
        ITranscriptRepository transcripts,
        IDictionaryRepository dictionary,
        ILocalTranslationService translation,
        IFlowBarController flowBar,
        Func<SprekrSettings> settings)
    {
        this.audioCapture = audioCapture;
        this.cuePlayer = cuePlayer;
        this.transcriptionEngine = transcriptionEngine;
        this.modelInstaller = modelInstaller;
        this.textDelivery = textDelivery;
        this.transcripts = transcripts;
        this.dictionary = dictionary;
        this.translation = translation;
        this.flowBar = flowBar;
        this.settings = settings;
    }

    public Task PressAsync(CancellationToken cancellationToken = default) =>
        ExecuteActionAsync(stateMachine.Press(settings().DictationMode), cancellationToken);

    public Task ReleaseAsync(CancellationToken cancellationToken = default) =>
        ExecuteActionAsync(stateMachine.Release(settings().DictationMode), cancellationToken);

    public Task EscapeAsync(CancellationToken cancellationToken = default) =>
        ExecuteActionAsync(stateMachine.Escape(), cancellationToken);

    public Task UndoAsync(CancellationToken cancellationToken = default) =>
        ExecuteActionAsync(stateMachine.Undo(), cancellationToken);

    private async Task ExecuteActionAsync(DictationAction action, CancellationToken cancellationToken)
    {
        if (action == DictationAction.None) return;
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            switch (action)
            {
                case DictationAction.Start:
                    await StartAsync(cancellationToken).ConfigureAwait(false);
                    break;
                case DictationAction.StopAndProcess:
                    await ProcessAsync(await audioCapture.StopAsync(cancellationToken).ConfigureAwait(false), cancellationToken)
                        .ConfigureAwait(false);
                    break;
                case DictationAction.Cancel:
                    await audioCapture.CancelAsync(retainForUndo: true, cancellationToken).ConfigureAwait(false);
                    flowBar.SetState(FlowBarState.Cancelled, "Geannuleerd — Ctrl+Z binnen 6 seconden om te herstellen");
                    _ = ExpireUndoWindowAsync();
                    break;
                case DictationAction.UndoCancel:
                    var restored = await audioCapture.UndoCancellationAsync(cancellationToken).ConfigureAwait(false);
                    if (restored is not null) await ProcessAsync(restored, cancellationToken).ConfigureAwait(false);
                    else stateMachine.Complete();
                    break;
            }
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            stateMachine.Complete();
            flowBar.SetState(FlowBarState.Error, exception.Message);
        }
        finally
        {
            operationGate.Release();
        }
    }

    private async Task StartAsync(CancellationToken cancellationToken)
    {
        await modelInstaller.EnsureInstalledAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        await audioCapture.StartAsync(settings().MicrophoneId, cancellationToken).ConfigureAwait(false);
        if (settings().SoundsEnabled) await cuePlayer.PlayStartAsync(cancellationToken).ConfigureAwait(false);
        flowBar.SetState(FlowBarState.Listening, "Luisteren…");
    }

    private async Task ProcessAsync(AudioRecording recording, CancellationToken cancellationToken)
    {
        try
        {
            flowBar.SetState(FlowBarState.Processing, "Lokaal verwerken…");
            var recognition = await transcriptionEngine.TranscribeAsync(recording, cancellationToken).ConfigureAwait(false);
            var formatted = settings().SmartFormatting
                ? TranscriptFormatter.Format(recognition.Text, settings().RecognitionLanguage)
                : recognition.Text.Trim();
            var corrected = await dictionary.ApplyAsync(formatted, settings().RecognitionLanguage, cancellationToken).ConfigureAwait(false);
            var translated = await translation.TranslateAsync(corrected.Text, settings().RecognitionLanguage, cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(translated.Text)) return;

            await transcripts.AppendAsync(new TranscriptRecord(
                Guid.NewGuid(), translated.Text, DateTimeOffset.Now, recording.Duration.TotalSeconds,
                corrected.Fixes, recognition.DetectedLanguage), cancellationToken).ConfigureAwait(false);

            var delivery = await textDelivery.DeliverAsync(translated.Text, cancellationToken).ConfigureAwait(false);
            if (delivery.Outcome != DeliveryOutcome.Delivered)
                throw new SprekrException(delivery.Message ?? "Tekst kon niet veilig worden ingevoegd.");

            if (settings().SoundsEnabled) await cuePlayer.PlayCompletionAsync(cancellationToken).ConfigureAwait(false);
            flowBar.SetState(FlowBarState.Ready, translated.Notice ?? "Gereed");
        }
        finally
        {
            await audioCapture.RemoveTemporaryAsync(recording, CancellationToken.None).ConfigureAwait(false);
            stateMachine.Complete();
        }
    }

    private async Task ExpireUndoWindowAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(6)).ConfigureAwait(false);
        if (stateMachine.State == DictationState.CancelledUndoWindow)
        {
            await audioCapture.CancelAsync(retainForUndo: false).ConfigureAwait(false);
            stateMachine.Complete();
            flowBar.SetState(FlowBarState.Ready);
        }
    }

    public async ValueTask DisposeAsync()
    {
        operationGate.Dispose();
        await transcriptionEngine.DisposeAsync().ConfigureAwait(false);
        await audioCapture.DisposeAsync().ConfigureAwait(false);
    }
}
