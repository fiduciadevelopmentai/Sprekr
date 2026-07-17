using NAudio.Wave;
using SherpaOnnx;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class SherpaTranscriptionEngine(string modelDirectory) : ITranscriptionEngine
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private OfflineRecognizer? recognizer;

    public async Task<TranscriptionResult> TranscribeAsync(AudioRecording recording, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var activeRecognizer = recognizer ??= CreateRecognizer();
            using var reader = new AudioFileReader(recording.Path);
            var samples = new float[checked((int)(reader.Length / sizeof(float)))];
            var count = reader.Read(samples, 0, samples.Length);
            if (count != samples.Length) Array.Resize(ref samples, count);

            using var stream = activeRecognizer.CreateStream();
            stream.AcceptWaveform(reader.WaveFormat.SampleRate, samples);
            var started = DateTimeOffset.UtcNow;
            await Task.Run(() => activeRecognizer.Decode(stream), cancellationToken).ConfigureAwait(false);
            return new TranscriptionResult(stream.Result.Text.Trim(), null, DateTimeOffset.UtcNow - started);
        }
        catch (DllNotFoundException exception)
        {
            throw new SprekrException("De native sherpa-onnx Windows x64-runtime ontbreekt. Voer install-windows.ps1 opnieuw uit.", exception);
        }
        catch (BadImageFormatException exception)
        {
            throw new SprekrException("De sherpa-onnx-runtime past niet bij Windows x64. Installeer de win-x64 build.", exception);
        }
        finally
        {
            gate.Release();
        }
    }

    private OfflineRecognizer CreateRecognizer()
    {
        string Required(string name)
        {
            var path = Path.Combine(modelDirectory, name);
            return File.Exists(path) ? path : throw new SprekrException($"Modelbestand ontbreekt: {name}. Download het model opnieuw via Sprekr.");
        }

        var config = new OfflineRecognizerConfig();
        config.FeatConfig.SampleRate = 16_000;
        config.FeatConfig.FeatureDim = 80;
        config.ModelConfig.Tokens = Required("tokens.txt");
        config.ModelConfig.Transducer.Encoder = Required("encoder.int8.onnx");
        config.ModelConfig.Transducer.Decoder = Required("decoder.int8.onnx");
        config.ModelConfig.Transducer.Joiner = Required("joiner.int8.onnx");
        config.ModelConfig.ModelType = "nemo_transducer";
        config.ModelConfig.Provider = "cpu";
        config.ModelConfig.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
        config.ModelConfig.Debug = 0;
        config.DecodingMethod = "greedy_search";
        return new OfflineRecognizer(config);
    }

    public ValueTask DisposeAsync()
    {
        recognizer?.Dispose();
        gate.Dispose();
        return ValueTask.CompletedTask;
    }
}
