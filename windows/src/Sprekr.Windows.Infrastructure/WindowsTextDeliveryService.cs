using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class WindowsTextDeliveryService : ITextDeliveryService
{
    public async Task<DeliveryResult> DeliverAsync(string text, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(text)) return DeliveryResult.Refused("Er is geen tekst om in te voegen.");
        cancellationToken.ThrowIfCancellationRequested();

        var window = GetForegroundWindow();
        if (window == IntPtr.Zero) return DeliveryResult.Refused("Er is geen actief doelvenster.");
        if (GetWindowThreadProcessId(window, out var processId) == 0)
            return DeliveryResult.Refused("Het actieve doelproces kon niet veilig worden vastgesteld.");
        AutomationElement target;
        try { target = AutomationElement.FocusedElement; }
        catch (ElementNotAvailableException) { return DeliveryResult.Refused("Het actieve invoerveld is niet meer beschikbaar."); }

        var classification = Classify(target, processId);
        if (classification is not null) return DeliveryResult.Refused(classification);

        var attempt = new DeliveryAttemptGuard();
        attempt.BeginSingleWrite();
        var inputs = BuildUnicodeInputs(text);
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length)
            return DeliveryResult.Indeterminate("Windows bevestigde de tekstinvoer niet volledig. Sprekr probeert niet opnieuw om dubbele tekst te voorkomen.");

        await Task.Delay(25, cancellationToken).ConfigureAwait(false);
        var verification = VerifyBoundedSuffix(target, text);
        return verification switch
        {
            false => DeliveryResult.Indeterminate("De begrensde invoercontrole kwam niet overeen. Sprekr probeert niet opnieuw; de tekst staat veilig in History."),
            _ => DeliveryResult.Delivered()
        };
    }

    private static string? Classify(AutomationElement target, uint processId)
    {
        try
        {
            var isReadOnly = target.TryGetCurrentPattern(ValuePattern.Pattern, out var valueObject) &&
                valueObject is ValuePattern valuePattern && valuePattern.Current.IsReadOnly;
            var supportsValue = target.TryGetCurrentPattern(ValuePattern.Pattern, out _);
            var supportsText = target.TryGetCurrentPattern(TextPattern.Pattern, out _);
            return TextDeliveryPolicy.RefusalReason(new TextTargetDescriptor(
                BooleanProperty(target, AutomationElement.IsEnabledProperty, fallback: true),
                BooleanProperty(target, AutomationElement.IsPasswordProperty, fallback: false),
                isReadOnly,
                supportsValue || supportsText,
                IsElevated(processId),
                processId == (uint)Environment.ProcessId));
        }
        catch (ElementNotAvailableException)
        {
            return "Het actieve invoerveld is niet meer beschikbaar.";
        }
    }

    private static bool BooleanProperty(AutomationElement target, AutomationProperty property, bool fallback)
    {
        var value = target.GetCurrentPropertyValue(property, true);
        return value is bool boolean ? boolean : fallback;
    }

    private static bool? VerifyBoundedSuffix(AutomationElement target, string expected)
    {
        try
        {
            if (!target.TryGetCurrentPattern(TextPattern.Pattern, out var patternObject) || patternObject is not TextPattern pattern)
                return null;
            var selection = pattern.GetSelection();
            if (selection.Length != 1) return null;
            var range = selection[0].Clone();
            var maximum = Math.Min(64, expected.Length);
            var moved = -range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -maximum);
            if (moved <= 0) return null;
            var bounded = range.GetText(Math.Min(64, moved));
            var suffix = expected[^Math.Min(expected.Length, moved)..];
            return bounded.EndsWith(suffix, StringComparison.Ordinal);
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException)
        {
            return null;
        }
    }

    private static Input[] BuildUnicodeInputs(string text)
    {
        var inputs = new Input[text.Length * 2];
        for (var index = 0; index < text.Length; index++)
        {
            inputs[index * 2] = Input.Keyboard(text[index], KeyeventfUnicode);
            inputs[index * 2 + 1] = Input.Keyboard(text[index], KeyeventfUnicode | KeyeventfKeyup);
        }
        return inputs;
    }

    private static bool IsElevated(uint processId)
    {
        var process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero) return true;
        try
        {
            if (!OpenProcessToken(process, TokenQuery, out var token)) return true;
            try
            {
                var elevation = new TokenElevation();
                var size = Marshal.SizeOf<TokenElevation>();
                return GetTokenInformation(token, TokenInformationClass.TokenElevation, ref elevation, size, out _)
                    ? elevation.TokenIsElevated != 0
                    : true;
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }

    private const uint InputKeyboard = 1;
    private const uint KeyeventfKeyup = 0x0002;
    private const uint KeyeventfUnicode = 0x0004;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint TokenQuery = 0x0008;

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Data;

        public static Input Keyboard(char character, uint flags) => new()
        {
            Type = InputKeyboard,
            Data = new InputUnion { Keyboard = new KeyboardInput { Scan = character, Flags = flags } }
        };
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public HardwareInput Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort Scan;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HardwareInput { public uint Message; public ushort ParameterLow; public ushort ParameterHigh; }

    private enum TokenInformationClass { TokenUser = 1, TokenElevation = 20 }
    [StructLayout(LayoutKind.Sequential)] private struct TokenElevation { public int TokenIsElevated; }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, TokenInformationClass informationClass, ref TokenElevation information, int length, out int returnLength);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
