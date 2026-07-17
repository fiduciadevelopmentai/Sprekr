using System.Drawing;
using System.Windows;
using Microsoft.Win32;
using Sprekr.Windows.Core;
using Sprekr.Windows.Infrastructure;
using Forms = System.Windows.Forms;

namespace Sprekr.Windows.App;

public partial class App : System.Windows.Application, IDisposable
{
    private LowLevelHotkeyService? hotkeys;
    private DictationCoordinator? coordinator;
    private MainWindow? mainWindow;
    private FlowBarWindow? flowBarWindow;
    private Forms.NotifyIcon? trayIcon;
    private SprekrSettings settings = new();

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var paths = new WindowsPaths();
            paths.EnsureDirectories();
            var settingsStore = new JsonSettingsStore(paths);
            settings = await settingsStore.LoadAsync().ConfigureAwait(true);

            var modelInstaller = new ParakeetModelInstaller(paths);
            var capture = new WasapiAudioCaptureService(paths);
            var historyStore = new EncryptedJsonStore<List<TranscriptRecord>>(paths, "history.enc", "history.encryption.key");
            var dictionaryStore = new EncryptedJsonStore<List<DictionaryEntry>>(paths, "dictionary.enc", "dictionary.encryption.key");
            var history = new TranscriptRepository(historyStore);
            var dictionary = new DictionaryRepository(dictionaryStore);
            var startup = new WindowsStartupService();

            flowBarWindow = new FlowBarWindow();
            var flowBar = new WpfFlowBarController(flowBarWindow, () => settings.ShowFlowBar);
            coordinator = new DictationCoordinator(
                capture,
                new WasapiAudioCuePlayer(),
                new SherpaTranscriptionEngine(modelInstaller.ActiveModelDirectory),
                modelInstaller,
                new WindowsTextDeliveryService(),
                history,
                dictionary,
                new PassthroughTranslationService(),
                flowBar,
                () => settings);

            mainWindow = new MainWindow(paths, settingsStore, modelInstaller, capture, history, dictionary, startup,
                () => settings, updated => settings = updated);
            mainWindow.Closed += (_, _) => mainWindow = null;
            CreateTrayIcon();

            hotkeys = new LowLevelHotkeyService();
            hotkeys.Pressed += async (_, _) => await coordinator.PressAsync().ConfigureAwait(false);
            hotkeys.Released += async (_, _) => await coordinator.ReleaseAsync().ConfigureAwait(false);
            hotkeys.EscapePressed += async (_, _) => await coordinator.EscapeAsync().ConfigureAwait(false);
            hotkeys.UndoPressed += async (_, _) => await coordinator.UndoAsync().ConfigureAwait(false);
            hotkeys.Start();

            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            SystemEvents.SessionSwitch += OnSessionSwitch;

            if (!e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase)) ShowMainWindow();
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(exception.Message, "Sprekr kon niet starten", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private void CreateTrayIcon()
    {
        trayIcon = new Forms.NotifyIcon
        {
            Text = "Sprekr — offline spraak-naar-tekst",
            Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!),
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip()
        };
        trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMainWindow);
        trayIcon.ContextMenuStrip.Items.Add("Open Sprekr", null, (_, _) => Dispatcher.Invoke(ShowMainWindow));
        trayIcon.ContextMenuStrip.Items.Add("Afsluiten", null, (_, _) => Dispatcher.Invoke(() =>
        {
            mainWindow?.AllowShutdown();
            Shutdown();
        }));
    }

    private void ShowMainWindow()
    {
        if (mainWindow is null) return;
        mainWindow.Show();
        if (mainWindow.WindowState == WindowState.Minimized) mainWindow.WindowState = WindowState.Normal;
        mainWindow.Activate();
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs eventArgs)
    {
        if (eventArgs.Mode == PowerModes.Resume) RestartHooks();
    }

    private void OnSessionSwitch(object sender, SessionSwitchEventArgs eventArgs)
    {
        if (eventArgs.Reason == SessionSwitchReason.SessionUnlock) RestartHooks();
    }

    private void RestartHooks() => Dispatcher.Invoke(() =>
    {
        hotkeys?.StopListening();
        hotkeys?.Start();
    });

    protected override void OnExit(ExitEventArgs e)
    {
        Dispose();
        base.OnExit(e);
    }

    public void Dispose()
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        hotkeys?.Dispose();
        hotkeys = null;
        trayIcon?.Dispose();
        trayIcon = null;
        if (flowBarWindow is not null) { flowBarWindow.Close(); flowBarWindow = null; }
        if (coordinator is not null)
        {
            coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult();
            coordinator = null;
        }
        GC.SuppressFinalize(this);
    }
}
