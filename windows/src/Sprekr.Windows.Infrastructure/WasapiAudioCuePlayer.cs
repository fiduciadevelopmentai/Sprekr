using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class WasapiAudioCuePlayer : IAudioCuePlayer
{
    private readonly string startPath = Path.Combine(AppContext.BaseDirectory, "Resources", "SprekrStart.aiff");
    private readonly string completionPath = Path.Combine(AppContext.BaseDirectory, "Resources", "SprekrCompletion.aiff");

    public Task PlayStartAsync(CancellationToken cancellationToken = default) => PlayAsync(startPath, cancellationToken);
    public Task PlayCompletionAsync(CancellationToken cancellationToken = default) => PlayAsync(completionPath, cancellationToken);

    private static async Task PlayAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return;
        using var reader = new AiffFileReader(path);
        using var output = new WasapiOut(AudioClientShareMode.Shared, useEventSync: true, latency: 80);
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        output.PlaybackStopped += (_, args) =>
        {
            if (args.Exception is null) completion.TrySetResult();
            else completion.TrySetException(args.Exception);
        };
        output.Init(reader);
        output.Play();
        await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }
}
