using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace FILLR;

public sealed partial class MainWindow : Window
{
    private readonly DispatcherQueueTimer timer;
    private EngineHost? engine;
    private OverlayWindow? overlay;
    private bool wasReady;
    private bool isBuilding;
    private bool updateBusy;
    private bool checkingUpdates;
    private bool editingPreferences;
    private bool choosingFolder;
    private bool savingUpdatePreference;
    private bool allowUpdateClose;
    private readonly DispatcherQueueTimer updateTimer;
    private string? lastOutput;
    private MediaPolicy mediaPolicy = new();
    private readonly string settingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FILLR", "folder.txt");
    private readonly string legacySettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChabotBackgrounder", "folder.txt");
    private string policyPath => Path.Combine(Path.GetDirectoryName(settingsPath)!, "media-policy.json");

    public MainWindow()
    {
        InitializeComponent();
        AppIcon.Apply(this);
        AppWindow.Closing += (_, args) => {
            if (!allowUpdateClose && (isBuilding || updateBusy || checkingUpdates || editingPreferences || choosingFolder)) {
                args.Cancel = true;
                ErrorText.Text = "Finish the current build, update, or open dialog before closing FILLR.";
            }
        };
        timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(1);
        timer.Tick += (_, _) => Poll();
        timer.Start();
        updateTimer = DispatcherQueue.CreateTimer();
        updateTimer.Interval = TimeSpan.FromHours(1);
        updateTimer.Tick += async (_, _) => await CheckUpdatesAsync(false);
        var updateState = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "fillr", "updates", "state.json");
        if (File.Exists(updateState)) {
            try { using var preferences = JsonDocument.Parse(File.ReadAllText(updateState)); AutomaticUpdates.IsOn = !preferences.RootElement.GetProperty("disabled").GetBoolean(); }
            catch { /* The helper reports malformed state without enabling installation. */ }
        }
        updateTimer.Start();
        _ = CheckUpdatesAsync(false);
        Closed += (_, _) => { timer.Stop(); updateTimer.Stop(); overlay?.Close(); engine?.Dispose(); };
        try { AppNotificationManager.Default.Register(); } catch { /* In-app banner remains authoritative. */ }
        if (File.Exists(policyPath))
        {
            try { mediaPolicy = JsonSerializer.Deserialize<MediaPolicy>(File.ReadAllText(policyPath)) ?? new(); }
            catch { mediaPolicy = new(); }
        }
        string previous = File.Exists(settingsPath) ? settingsPath : legacySettingsPath;
        if (File.Exists(previous)) OpenFolder(File.ReadAllText(previous).Trim());
    }

    private async void CheckUpdates_Click(object sender, RoutedEventArgs args) => await CheckUpdatesAsync(true);
    private async void AutomaticUpdates_Toggled(object sender, RoutedEventArgs args)
    {
        if (AutomaticUpdates == null || !AutomaticUpdates.IsLoaded || savingUpdatePreference) return;
        savingUpdatePreference = true;
        AutomaticUpdates.IsEnabled = false;
        bool requested = AutomaticUpdates.IsOn;
        try { await UpdateClient.RunAsync(requested ? "enable" : "disable"); }
        catch (Exception error) { AutomaticUpdates.IsOn = !requested; ErrorText.Text = error.Message; }
        finally { savingUpdatePreference = false; AutomaticUpdates.IsEnabled = true; }
    }
    private async Task CheckUpdatesAsync(bool manual)
    {
        if (isBuilding || updateBusy || checkingUpdates || editingPreferences || choosingFolder) return;
        checkingUpdates = true;
        JsonElement? downloaded = null;
        try
        {
            var check = await UpdateClient.RunAsync(manual ? "check" : "check-auto");
            if (!check.TryGetProperty("available", out var available) || !available.GetBoolean())
            {
                if (manual) ErrorText.Text = "No newer compatible stable update is available.";
                return;
            }
            if (!manual) { ErrorText.Text = "A FILLR update is available. Choose Check for Updates to install it."; return; }
            if (isBuilding || editingPreferences || choosingFolder) { ErrorText.Text = "An update is available. Finish the current work or dialog before installing."; return; }
            updateBusy = true;
            BuildButton.IsEnabled = false;
            var version = check.GetProperty("version").GetString()!;
            var confirmation = new ContentDialog {
                XamlRoot = Content.XamlRoot, Title = "Update FILLR to " + version + "?",
                Content = "FILLR will download and verify the signed package. Windows will securely stage and install the package. Your media and settings are retained. Release notes: " + check.GetProperty("notes_url").GetString(),
                PrimaryButtonText = "Download Update", CloseButtonText = "Later"
            };
            if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
            var download = await UpdateClient.RunAsync("download", version);
            downloaded = download;
            await UpdateClient.VerifyAndStageAsync(download);
            // The work gate has remained held throughout download, validation, and consent.
            var install = new ContentDialog {
                XamlRoot = Content.XamlRoot, Title = "Update verified",
                Content = "Windows will finish registering the update when FILLR closes. Reopen FILLR from Start to use the new version.",
                PrimaryButtonText = "Install and Close FILLR", CloseButtonText = "Later"
            };
            if (await install.ShowAsync() == ContentDialogResult.Primary) {
                await UpdateClient.VerifyAndStageAsync(download, install: true);
                overlay?.Close();
                allowUpdateClose = true;
                Close();
            }
        }
        catch (Exception error) { if (manual) ErrorText.Text = "Update unavailable: " + error.Message; }
        finally {
            if (downloaded is JsonElement completedDownload) {
                string? cleanupError = UpdateClient.CleanupDownload(completedDownload);
                if (cleanupError != null) ErrorText.Text = cleanupError;
            }
            checkingUpdates = false; updateBusy = false; Poll();
        }
    }

    internal static string ClockText(ulong milliseconds)
    {
        ulong seconds = (milliseconds + 999) / 1000;
        return $"{seconds / 60}:{seconds % 60:00}";
    }

    private async void ChooseFolder_Click(object sender, RoutedEventArgs args)
    {
        if (isBuilding || updateBusy || editingPreferences || choosingFolder) return;
        choosingFolder = true;
        try {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (folder != null && !isBuilding && !updateBusy) OpenFolder(folder.Path);
        }
        catch (Exception error) { ErrorText.Text = error.Message; }
        finally { choosingFolder = false; Poll(); }
    }

    private void OpenFolder(string path)
    {
        try
        {
            var next = new EngineHost(path, mediaPolicy);
            engine?.Dispose();
            engine = next;
            wasReady = false;
            FolderText.Text = path;
            Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
            File.WriteAllText(settingsPath, path);
            ErrorText.Text = "";
            Poll();
        }
        catch (Exception error) { ErrorText.Text = error.Message; }
    }

    private void Poll()
    {
        if (engine == null) return;
        try
        {
            using var document = engine.Snapshot();
            var state = document.RootElement;
            bool ready = state.GetProperty("status").GetString() == "ready";
            ulong remaining = state.GetProperty("remaining_ms").GetUInt64();
            ulong available = state.GetProperty("available_ms").GetUInt64();
            ReadyBar.IsOpen = ready;
            StatusText.Text = state.GetProperty("message").GetString() ?? "";
            RemainingText.Text = ClockText(remaining);
            AvailableText.Text = ClockText(available);
            FootageProgress.Value = Math.Min(available, 8_470_000UL);
            int clips = state.GetProperty("clips").GetArrayLength();
            int pending = state.GetProperty("pending").GetArrayLength();
            ClipCountText.Text = $"{clips} usable clips · {pending} pending";
            BuildButton.IsEnabled = ready && !isBuilding && !updateBusy;
            FolderButton.IsEnabled = !isBuilding && !updateBusy;
            var preview = new List<string>();
            if (state.TryGetProperty("plan", out var plan) && plan.ValueKind == JsonValueKind.Object)
            {
                foreach (var comp in plan.GetProperty("assignments").EnumerateArray())
                    preview.Add($"Comp {comp.GetProperty("comp").GetInt32()}: {ClockText(comp.GetProperty("duration_ms").GetUInt64())} · {comp.GetProperty("filenames").GetArrayLength()} clips");
            }
            CompList.ItemsSource = preview;
            int excluded = state.GetProperty("excluded").GetArrayLength();
            int duplicates = state.GetProperty("duplicate_log").GetArrayLength();
            int rejected = state.GetProperty("rejection_log").GetArrayLength();
            NotesText.Text = $"{excluded} excluded files · {rejected} rejected deleted · {duplicates} exact duplicates deleted";
            overlay?.Update(remaining, ready);
            if (ready && !wasReady)
            {
                try {
                    AppNotificationManager.Default.Show(new AppNotificationBuilder()
                        .AddText("Chabot News footage is ready")
                        .AddText("You can stop downloading and build the 14 Comp folders.").BuildNotification());
                } catch { /* In-app banner remains authoritative. */ }
            }
            wasReady = ready;
        }
        catch (Exception error) { ErrorText.Text = error.Message; }
    }

    private void Refresh_Click(object sender, RoutedEventArgs args) { engine?.Refresh(); Poll(); }

    private async void MediaPreferences_Click(object sender, RoutedEventArgs args)
    {
        if (isBuilding || updateBusy || editingPreferences || choosingFolder) return;
        var enabled = new CheckBox { Content = "Filter media", IsChecked = mediaPolicy.enabled };
        var delete = new CheckBox { Content = "Delete rejected completed downloads", IsChecked = mediaPolicy.delete_rejected };
        TextBox Field(string header, string value) => new() { Header = header, Text = value };
        var extensions = Field("Allowed extensions (comma separated)", string.Join(", ", mediaPolicy.allowed_extensions));
        var containers = Field("Allowed containers", string.Join(", ", mediaPolicy.allowed_containers));
        var codecs = Field("Allowed video codecs", string.Join(", ", mediaPolicy.allowed_codecs));
        var width = Field("Required width (blank = any)", mediaPolicy.required_width?.ToString() ?? "");
        var height = Field("Required height (blank = any)", mediaPolicy.required_height?.ToString() ?? "");
        var rate = Field("Frame rate (blank = any)", mediaPolicy.frame_rate ?? "");
        var aspect = Field("Display aspect ratio (blank = any)", mediaPolicy.display_aspect_ratio ?? "");
        ComboBox Choice(string header, string selected, params string[] choices)
        {
            var box = new ComboBox { Header = header };
            foreach (var choice in choices) box.Items.Add(choice);
            box.SelectedItem = selected;
            return box;
        }
        var standard = Choice("TV standard", mediaPolicy.television_standard, "any", "ntsc", "pal");
        var scan = Choice("Scan type", mediaPolicy.scan_type, "any", "interlaced", "progressive");
        var orientation = Choice("Orientation", mediaPolicy.orientation, "any", "horizontal", "vertical");
        var fields = new StackPanel { Spacing = 8 };
        fields.Children.Add(new TextBlock { Text = "NTSC 1080i is the default. FILLR waits for a final name and 10 unchanged seconds before deleting rejected media.", TextWrapping = TextWrapping.Wrap });
        foreach (var field in new UIElement[] { enabled, delete, extensions, containers, codecs, width, height, standard, rate, scan, orientation, aspect }) fields.Children.Add(field);
        var dialog = new ContentDialog { Title = "Media preferences", Content = new ScrollViewer { Content = fields, MaxHeight = 540 },
            PrimaryButtonText = "Save", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot };
        editingPreferences = true;
        try {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        catch (Exception error) { ErrorText.Text = error.Message; return; }
        finally { editingPreferences = false; }
        int? Number(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            if (int.TryParse(text, out int value) && value > 0) return value;
            throw new InvalidOperationException("Width and height must be positive whole numbers.");
        }
        List<string> ParseList(string text) => text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToList();
        try
        {
            var next = new MediaPolicy {
                enabled = enabled.IsChecked == true, delete_rejected = delete.IsChecked == true,
                allowed_extensions = ParseList(extensions.Text), allowed_containers = ParseList(containers.Text),
                allowed_codecs = ParseList(codecs.Text), required_width = Number(width.Text), required_height = Number(height.Text),
                television_standard = standard.SelectedItem?.ToString() ?? "any", frame_rate = string.IsNullOrWhiteSpace(rate.Text) ? null : rate.Text.Trim(),
                scan_type = scan.SelectedItem?.ToString() ?? "any", orientation = orientation.SelectedItem?.ToString() ?? "any",
                display_aspect_ratio = string.IsNullOrWhiteSpace(aspect.Text) ? null : aspect.Text.Trim()
            };
            engine?.SetPolicy(next);
            mediaPolicy = next;
            Directory.CreateDirectory(Path.GetDirectoryName(policyPath)!);
            File.WriteAllText(policyPath, JsonSerializer.Serialize(next));
            ErrorText.Text = "";
            Poll();
        }
        catch (Exception error) { ErrorText.Text = error.Message; }
    }

    private void ToggleOverlay_Click(object sender, RoutedEventArgs args)
    {
        if (overlay == null)
        {
            overlay = new OverlayWindow();
            overlay.Closed += (_, _) => { overlay = null; OverlayButton.Content = "Show Overlay"; };
            overlay.Activate();
            OverlayButton.Content = "Hide Overlay";
            Poll();
        }
        else { overlay.Close(); overlay = null; OverlayButton.Content = "Show Overlay"; }
    }

    private async void Build_Click(object sender, RoutedEventArgs args)
    {
        if (isBuilding || updateBusy || editingPreferences || choosingFolder || engine == null) return;
        var current = engine;
        isBuilding = true;
        BuildButton.IsEnabled = false;
        FolderButton.IsEnabled = false;
        ErrorText.Text = "";
        try
        {
            string json = await Task.Run(() => { using var result = current.Build(); return result.RootElement.GetRawText(); });
            using var result = JsonDocument.Parse(json);
            var root = result.RootElement;
            if (!root.GetProperty("ok").GetBoolean()) throw new InvalidOperationException(root.GetProperty("error").GetString());
            lastOutput = root.GetProperty("result").GetProperty("output_folder").GetString();
            OpenOutputButton.IsEnabled = lastOutput != null;
        }
        catch (Exception error) { ErrorText.Text = error.Message; }
        finally { isBuilding = false; Poll(); }
    }

    private void OpenOutput_Click(object sender, RoutedEventArgs args)
    {
        if (lastOutput != null) Process.Start(new ProcessStartInfo(lastOutput) { UseShellExecute = true });
    }
}
