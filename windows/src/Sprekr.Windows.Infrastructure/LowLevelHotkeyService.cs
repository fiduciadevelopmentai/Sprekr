using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Sprekr.Windows.Infrastructure;

using Sprekr.Windows.Core;

public sealed class LowLevelHotkeyService : IHotkeyService
{
    private const int WhKeyboardLl = 13;
    private const int WhMouseLl = 14;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const int WmXbuttonDown = 0x020B;
    private const int WmXbuttonUp = 0x020C;
    private const uint LlkhfInjected = 0x10;
    private const uint LlmhfInjected = 0x01;
    private const uint VkF8 = 0x77;
    private const uint VkEscape = 0x1B;
    private const uint VkZ = 0x5A;
    private const int VkControl = 0x11;

    private readonly HookProcedure keyboardProcedure;
    private readonly HookProcedure mouseProcedure;
    private Thread? thread;
    private uint threadId;
    private IntPtr keyboardHook;
    private IntPtr mouseHook;
    private readonly ManualResetEventSlim ready = new(false);
    private Exception? startupError;
    private volatile bool f8Down;
    private volatile bool mouseDown;

    public LowLevelHotkeyService()
    {
        keyboardProcedure = KeyboardHook;
        mouseProcedure = MouseHook;
    }

    public event EventHandler? Pressed;
    public event EventHandler? Released;
    public event EventHandler? EscapePressed;
    public event EventHandler? UndoPressed;

    public void Start()
    {
        if (thread is not null) return;
        ready.Reset();
        startupError = null;
        thread = new Thread(MessageLoop) { IsBackground = true, Name = "Sprekr input hook" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!ready.Wait(TimeSpan.FromSeconds(5))) throw new SprekrException("De globale Sprekr-sneltoets kon niet worden gestart.");
        if (startupError is not null)
        {
            thread = null;
            throw new SprekrException("De globale keyboard- of muisknop-hook ontbreekt. Herstart Sprekr als normale gebruiker.", startupError);
        }
    }

    public void StopListening()
    {
        if (thread is null) return;
        PostThreadMessage(threadId, 0x0012, UIntPtr.Zero, IntPtr.Zero);
        thread.Join(TimeSpan.FromSeconds(2));
        thread = null;
        threadId = 0;
        f8Down = false;
        mouseDown = false;
    }

    private void MessageLoop()
    {
        threadId = GetCurrentThreadId();
        keyboardHook = SetWindowsHookEx(WhKeyboardLl, keyboardProcedure, GetModuleHandle(null), 0);
        mouseHook = SetWindowsHookEx(WhMouseLl, mouseProcedure, GetModuleHandle(null), 0);
        if (keyboardHook == IntPtr.Zero || mouseHook == IntPtr.Zero)
        {
            startupError = new Win32Exception(Marshal.GetLastWin32Error());
            ready.Set();
            CleanupHooks();
            return;
        }
        ready.Set();
        while (GetMessage(out var message, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
        CleanupHooks();
    }

    private IntPtr KeyboardHook(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0)
        {
            var input = Marshal.PtrToStructure<KeyboardHookData>(data);
            if ((input.Flags & LlkhfInjected) == 0)
            {
                var down = message == (IntPtr)WmKeyDown || message == (IntPtr)WmSysKeyDown;
                var up = message == (IntPtr)WmKeyUp || message == (IntPtr)WmSysKeyUp;
                if (input.VirtualKey == VkF8 && down && !f8Down) { f8Down = true; Pressed?.Invoke(this, EventArgs.Empty); }
                if (input.VirtualKey == VkF8 && up && f8Down) { f8Down = false; Released?.Invoke(this, EventArgs.Empty); }
                if (input.VirtualKey == VkEscape && down) EscapePressed?.Invoke(this, EventArgs.Empty);
                if (input.VirtualKey == VkZ && down && (GetAsyncKeyState(VkControl) & 0x8000) != 0) UndoPressed?.Invoke(this, EventArgs.Empty);
            }
        }
        return CallNextHookEx(keyboardHook, code, message, data);
    }

    private IntPtr MouseHook(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && (message == (IntPtr)WmXbuttonDown || message == (IntPtr)WmXbuttonUp))
        {
            var input = Marshal.PtrToStructure<MouseHookData>(data);
            var xButton = (input.MouseData >> 16) & 0xffff;
            if ((input.Flags & LlmhfInjected) == 0 && xButton == 1)
            {
                if (message == (IntPtr)WmXbuttonDown && !mouseDown) { mouseDown = true; Pressed?.Invoke(this, EventArgs.Empty); }
                if (message == (IntPtr)WmXbuttonUp && mouseDown) { mouseDown = false; Released?.Invoke(this, EventArgs.Empty); }
            }
        }
        return CallNextHookEx(mouseHook, code, message, data);
    }

    private void CleanupHooks()
    {
        if (keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
        if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
        keyboardHook = mouseHook = IntPtr.Zero;
    }

    public void Dispose()
    {
        StopListening();
        ready.Dispose();
    }

    private delegate IntPtr HookProcedure(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardHookData { public uint VirtualKey; public uint ScanCode; public uint Flags; public uint Time; public UIntPtr ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseHookData { public Point Point; public uint MouseData; public uint Flags; public uint Time; public UIntPtr ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct Message { public IntPtr Window; public uint Value; public UIntPtr WParam; public IntPtr LParam; public uint Time; public Point Point; public uint Private; }

    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int hook, HookProcedure procedure, IntPtr module, uint threadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern int GetMessage(out Message message, IntPtr window, uint minimum, uint maximum);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref Message message);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint threadId, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? moduleName);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
}
