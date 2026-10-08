using Avalonia.Controls;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using System.Diagnostics;
namespace FILLR;

public partial class MainWindow : Window, IUserInteraction
{
    private readonly MainViewModel model;
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer update = new() { Interval = TimeSpan.FromHours(1) };
    private OverlayWindow? overlay;
    public MainWindow() : this(SettingsStore.Create(), new UpdateService(), null) { }
    internal MainWindow(ISettings settings, IUpdates updates, Func<string, MediaPolicy, IEngine>? factory)
    {
        InitializeComponent();
        model = new(settings, this, updates, factory ?? ((path, policy) => new EngineHost(path, policy, settings.LoadSortSettings())));
        DataContext = model;
        Opened += async (_, _) => { model.Initialize(); model.Poll(); poll.Start(); update.Start(); await model.CheckAsync(false); };
        poll.Tick += (_, _) => model.Poll();
        update.Tick += async (_, _) => await model.CheckAsync(false);
        Closing += (_, args) => { if (!model.CanClose) args.Cancel = true; };
        Closed += (_, _) => { poll.Stop(); update.Stop(); overlay?.Close(); model.Dispose(); };
    }
    async Task<string?> IUserInteraction.ChooseFolderAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new() { Title = "Choose CNN download folder", AllowMultiple = false });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
    }
    Task IUserInteraction.EditPolicyAsync(MediaPolicy policy, Action<MediaPolicy> save) => new PolicyWindow { DataContext = new PolicyEditor(policy), SavePolicy = save }.ShowDialog(this);
    Task IUserInteraction.EditSettingsAsync(MediaPolicy policy, SortSettings sort, Action<MediaPolicy, SortSettings> save) =>
        new PolicyWindow { DataContext = new PolicyEditor(policy, sort), SaveSettings = save }.ShowDialog(this);
    async Task<bool> IUserInteraction.ConfirmAsync(string title, string message, string accept)
    {
        var dialog = new Window { Title = title, Width = 520, SizeToContent = SizeToContent.Height, MaxHeight = 600, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var cancel = new Button { Content = "Later", IsCancel = true };
        var confirm = new Button { Content = accept, IsDefault = true };
        cancel.Click += (_, _) => dialog.Close(false); confirm.Click += (_, _) => dialog.Close(true);
        dialog.Content = new StackPanel
        {
            Margin = new Avalonia.Thickness(20),
            Spacing = 16,
            Children = {
            new TextBlock { Text = message, TextWrapping = Avalonia.Media.TextWrapping.Wrap },
            new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, Children = { cancel, confirm } }
        }
        };
        return await dialog.ShowDialog<bool>(this);
    }
    void IUserInteraction.NotifyReady() => DesktopNotifications.Ready();
    void IUserInteraction.NotifyReady(int folderCount) => DesktopNotifications.Ready(folderCount);
    void IUserInteraction.ToggleOverlay()
    {
        if (overlay != null) { overlay.Close(); return; }
        overlay = new() { DataContext = model };
        overlay.Closed += (_, _) => overlay = null;
        overlay.Show(this);
    }
    void IUserInteraction.OpenFolder(string path)
    {
        var start = OperatingSystem.IsWindows() ? new ProcessStartInfo(path) { UseShellExecute = true }
            : new ProcessStartInfo(OperatingSystem.IsMacOS() ? "/usr/bin/open" : "xdg-open") { UseShellExecute = false };
        if (!OperatingSystem.IsWindows()) start.ArgumentList.Add(path);
        using var process = Process.Start(start);
    }
    void IUserInteraction.FinishUpdate() => Dispatcher.UIThread.Post(() =>
    {
        if (OperatingSystem.IsLinux()) Program.RestartImage = Environment.GetEnvironmentVariable("APPIMAGE");
        Close();
    });
}
