using NAudio.Wave;
using Sprekr.Windows.Infrastructure;

namespace Sprekr.Windows.Tests;

public sealed class ModelIntegrationTests
{
    [Fact]
    [Trait("Category", "ModelIntegration")]
    public async Task PinnedModelTranscribesOnlyBundledSyntheticAudio()
    {
        if (Environment.GetEnvironmentVariable("SPREKR_RUN_MODEL_INTEGRATION") != "1") return;
        var paths = new WindowsPaths();
        using var installer = new ParakeetModelInstaller(paths);
        var cancellationToken = TestContext.Current.CancellationToken;
        var model = await installer.EnsureInstalledAsync(cancellationToken: cancellationToken);
        var syntheticAudio = Path.Combine(model, "test_wavs", "en.wav");
        Assert.True(File.Exists(syntheticAudio));
        using var reader = new WaveFileReader(syntheticAudio);
        var duration = reader.TotalTime;
        await using var engine = new SherpaTranscriptionEngine(model);
        var result = await engine.TranscribeAsync(new(syntheticAudio, duration, reader.WaveFormat.SampleRate), cancellationToken);
        Assert.NotEmpty(result.Text);
    }
}
