using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using Sprekr.Windows.Core;
using Sprekr.Windows.Infrastructure;

namespace Sprekr.Windows.App;

public partial class MainWindow : Window
{
    private readonly ISettingsStore settingsStore;
    private readonly IModelInstaller modelInstaller;
    private readonly IAudioCaptureService audioCapture;
    private readonly ITranscriptRepository history;
    private readonly IDictionaryRepository dictionary;
    private readonly IStartupService startup;
    private readonly Func<SprekrSettings> currentSettings;
    private readonly Action<SprekrSettings> updateSettings;
    private bool initialized;
    private bool allowClose;

    public MainWindow(
        WindowsPaths paths,
        ISettingsStore settingsStore,
        IModelInstaller modelInstaller,
        IAudioCaptureService audioCapture,
        ITranscriptRepository history,
        IDictionaryRepository dictionary,
        IStartupService startup,
        Func<SprekrSettings> currentSettings,
        Action<SprekrSettings> updateSettings)
    {
        _ = paths;
        this.settingsStore = settingsStore;
        this.modelInstaller = modelInstaller;
        this.audioCapture = audioCapture;
        this.history = history;
        this.dictionary = dictionary;
        this.startup = startup;
        this.currentSettings = currentSettings;
        this.updateSettings = updateSettings;
        InitializeComponent();
        Loaded += OnLoaded;
        Closing += OnClosing;
    }

    public void AllowShutdown() => allowClose = true;

    private async void OnLoaded(object sender, RoutedEventArgs eventArgs)
    {
        ModeCombo.ItemsSource = Enum.GetValues<DictationMode>();
        LanguageCombo.ItemsSource = Enum.GetValues<RecognitionLanguage>();
        var settings = currentSettings();
        ModeCombo.SelectedItem = settings.DictationMode;
        LanguageCombo.SelectedItem = settings.RecognitionLanguage;
        FlowBarCheck.IsChecked = settings.ShowFlowBar;
        SoundsCheck.IsChecked = settings.SoundsEnabled;
        FormattingCheck.IsChecked = settings.SmartFormatting;
        StartupCheck.IsChecked = startup.IsEnabled;
        RefreshMicrophones();
        initialized = true;
        await RefreshDataAsync();
        await RefreshModelStatusAsync();
    }

    private void OnClosing(object? sender, CancelEventArgs eventArgs)
    {
        if (allowClose) return;
        eventArgs.Cancel = true;
        Hide();
    }

    private async void DownloadModel_Click(object sender, RoutedEventArgs eventArgs)
    {
        DownloadModelButton.IsEnabled = false;
        ModelProgress.Visibility = Visibility.Visible;
        try
        {
            var progress = new Progress<double>(value => ModelProgress.Value = value * 100);
            await modelInstaller.EnsureInstalledAsync(progress);
            StatusText.Text = "Het offline model is gecontroleerd en klaar voor gebruik.";
        }
        catch (Exception exception) { ShowError(exception); }
        finally
        {
            DownloadModelButton.IsEnabled = true;
            ModelProgress.Visibility = Visibility.Collapsed;
            await RefreshModelStatusAsync();
        }
    }

    private async Task RefreshModelStatusAsync()
    {
        var installed = await modelInstaller.VerifyInstalledAsync();
        ModelStatusText.Text = installed
            ? "Geïnstalleerd en lokaal beschikbaar."
            : "Nog niet geïnstalleerd — download circa 487 MB; houd minimaal 1,5 GB vrij.";
        DownloadModelButton.Content = installed ? "Model opnieuw controleren" : "Download en verifieer model";
    }

    private void RefreshMicrophones_Click(object sender, RoutedEventArgs eventArgs) => RefreshMicrophones();

    private void RefreshMicrophones()
    {
        try
        {
            var devices = audioCapture.GetMicrophones();
            MicrophoneCombo.ItemsSource = devices;
            MicrophoneCombo.SelectedItem = devices.FirstOrDefault(item => item.Id == currentSettings().MicrophoneId)
                ?? devices.FirstOrDefault(item => item.IsDefault)
                ?? (devices.Count > 0 ? devices[0] : null);
        }
        catch (Exception exception) { ShowError(exception); }
    }

    private async void Settings_Changed(object sender, SelectionChangedEventArgs eventArgs) => await SaveSettingsAsync();
    private async void Settings_Changed(object sender, RoutedEventArgs eventArgs) => await SaveSettingsAsync();

    private async Task SaveSettingsAsync()
    {
        if (!initialized) return;
        var microphone = MicrophoneCombo.SelectedItem as MicrophoneDevice;
        var updated = currentSettings() with
        {
            DictationMode = ModeCombo.SelectedItem is DictationMode mode ? mode : DictationMode.Hold,
            RecognitionLanguage = LanguageCombo.SelectedItem is RecognitionLanguage language ? language : RecognitionLanguage.Automatic,
            MicrophoneId = microphone?.Id,
            ShowFlowBar = FlowBarCheck.IsChecked == true,
            SoundsEnabled = SoundsCheck.IsChecked == true,
            SmartFormatting = FormattingCheck.IsChecked == true,
            LaunchAtLogin = StartupCheck.IsChecked == true
        };
        try
        {
            updateSettings(updated);
            await settingsStore.SaveAsync(updated);
            startup.SetEnabled(updated.LaunchAtLogin);
            StatusText.Text = "Instellingen lokaal opgeslagen.";
        }
        catch (Exception exception) { ShowError(exception); }
    }

    private async void RefreshData_Click(object sender, RoutedEventArgs eventArgs) => await RefreshDataAsync();

    private async Task RefreshDataAsync()
    {
        try
        {
            var records = await history.GetAllAsync();
            HistoryList.ItemsSource = records;
            var insights = InsightsService.Summarize(records);
            TotalWordsText.Text = insights.TotalWords.ToString("N0", CultureInfo.CurrentCulture);
            WpmText.Text = insights.AverageWordsPerMinute.ToString("N0", CultureInfo.CurrentCulture);
            StreakText.Text = insights.CurrentStreak.ToString("N0", CultureInfo.CurrentCulture);
            LongestStreakText.Text = insights.LongestStreak.ToString("N0", CultureInfo.CurrentCulture);
            FixesText.Text = insights.DictionaryFixes.ToString("N0", CultureInfo.CurrentCulture);
            ActiveDaysText.Text = insights.ActiveDays.ToString("N0", CultureInfo.CurrentCulture);
            DictionaryList.ItemsSource = await dictionary.GetAllAsync();
        }
        catch (Exception exception) { ShowError(exception); }
    }

    private async void AddDictionary_Click(object sender, RoutedEventArgs eventArgs)
    {
        var preferred = PreferredText.Text.Trim();
        if (preferred.Length == 0) { StatusText.Text = "Vul een voorkeursspelling in."; return; }
        var aliases = AliasesText.Text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        try
        {
            await dictionary.SaveAsync(new DictionaryEntry(
                Guid.NewGuid(), preferred, aliases, RecognitionLanguage.Automatic, true, 0, DateTimeOffset.Now));
            PreferredText.Clear();
            AliasesText.Clear();
            await RefreshDataAsync();
            StatusText.Text = "Dictionary-item versleuteld opgeslagen.";
        }
        catch (Exception exception) { ShowError(exception); }
    }

    private void ShowError(Exception exception)
    {
        StatusText.Text = exception.Message;
        System.Windows.MessageBox.Show(exception.Message, "Sprekr", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}
