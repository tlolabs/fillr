using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
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
    private string? lastOutput;
    private readonly string settingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FILLR", "folder.txt");
    private readonly string legacySettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChabotBackgrounder", "folder.txt");

    public MainWindow()
    {
        InitializeComponent();
        timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(1);
        timer.Tick += (_, _) => Poll();
        timer.Start();
        Closed += (_, _) => { timer.Stop(); overlay?.Close(); engine?.Dispose(); };
        try { AppNotificationManager.Default.Register(); } catch { /* In-app banner remains authoritative. */ }
        string previous = File.Exists(settingsPath) ? settingsPath : legacySettingsPath;
        if (File.Exists(previous)) OpenFolder(File.ReadAllText(previous).Trim());
    }

    internal static string ClockText(ulong milliseconds)
    {
        ulong seconds = (milliseconds + 999) / 1000;
        return $"{seconds / 60}:{seconds % 60:00}";
    }

    private async void ChooseFolder_Click(object sender, RoutedEventArgs args)
    {
        if (isBuilding) return;
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder != null) OpenFolder(folder.Path);
    }

    private void OpenFolder(string path)
    {
        try
        {
            var next = new EngineHost(path);
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
            BuildButton.IsEnabled = ready && !isBuilding;
            FolderButton.IsEnabled = !isBuilding;
            var preview = new List<string>();
            if (state.TryGetProperty("plan", out var plan) && plan.ValueKind == JsonValueKind.Object)
            {
                foreach (var comp in plan.GetProperty("assignments").EnumerateArray())
                    preview.Add($"Comp {comp.GetProperty("comp").GetInt32()}: {ClockText(comp.GetProperty("duration_ms").GetUInt64())} · {comp.GetProperty("filenames").GetArrayLength()} clips");
            }
            CompList.ItemsSource = preview;
            int excluded = state.GetProperty("excluded").GetArrayLength();
            int duplicates = state.GetProperty("duplicate_log").GetArrayLength();
            NotesText.Text = $"{excluded} excluded files · {duplicates} exact duplicates deleted";
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
        if (isBuilding || engine == null) return;
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
