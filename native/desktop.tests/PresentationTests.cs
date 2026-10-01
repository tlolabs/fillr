using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Xunit;
using FILLR;
[assembly: AvaloniaTestApplication(typeof(TestAppBuilder))]
public class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UseHeadless(new AvaloniaHeadlessPlatformOptions());
}
public class PresentationTests
{
    internal sealed class Settings : ISettings
    {
        public string? Folder;
        public MediaPolicy Policy = new();
        public bool Fail;
        public string? LoadFolder() => Folder;
        public MediaPolicy LoadPolicy() => Policy;
        public void SaveFolder(string folder) { if (Fail) throw new IOException("disk full"); Folder = folder; }
        public void SavePolicy(MediaPolicy policy) { if (Fail) throw new IOException("disk full"); Policy = policy; }
    }
    internal sealed class Engine : IEngine
    {
        public bool Ready = true, Disposed;
        public int Builds, Polls;
        public MediaPolicy Policy = new();
        public ManualResetEventSlim? BuildWait;
        public JsonDocument Snapshot() { Polls++; return JsonDocument.Parse("""
            {"status":"READY","message":"Collecting","remaining_ms":1234,"available_ms":60000,"clips":[],"pending":[],"excluded":[],"rejection_log":[],"duplicate_log":[],"plan":{"assignments":[{"comp":2,"duration_ms":605000,"filenames":["clip.mpg"]}]}}
            """.Replace("READY", Ready ? "ready" : "collecting")); }
        public JsonDocument Build() { Builds++; BuildWait?.Wait(); return JsonDocument.Parse("""{"ok":true,"result":{"output_folder":"/test/export"}}"""); }
        public void Refresh() { }
        public void SetPolicy(MediaPolicy policy) => Policy = policy;
        public void Dispose() => Disposed = true;
    }
    internal sealed class Updates : IUpdates
    {
        public bool Supported => true;
        public bool Automatic { get; private set; } = true;
        public bool Fail;
        public int Checks, Installs;
        public Task SetAutomaticAsync(bool enabled) { if (Fail) throw new IOException("write failed"); Automatic = enabled; return Task.CompletedTask; }
        public Task<JsonElement> CheckAsync(bool manual) { Checks++; return Task.FromResult(JsonDocument.Parse("""{"available":true,"version":"1.0.0","notes_url":"https://github.com/tlolabs/fillr/releases/tag/v1.0.0"}""").RootElement.Clone()); }
        public Task<string> InstallAsync(string version) { Installs++; if (Fail) throw new IOException("invalid signature"); return Task.FromResult("Restart"); }
    }
    internal sealed class Interaction : IUserInteraction
    {
        public int Notifications;
        public bool Confirm = true;
        public TaskCompletionSource<MediaPolicy?>? Editor;
        public MediaPolicy? Policy;
        public Task<string?> ChooseFolderAsync() => Task.FromResult<string?>(null);
        public Task<MediaPolicy?> EditPolicyAsync(MediaPolicy policy) => Editor?.Task ?? Task.FromResult(Policy);
        public Task<bool> ConfirmAsync(string title, string message, string accept) => Task.FromResult(Confirm);
        public void NotifyReady() => Notifications++;
        public void ToggleOverlay() { }
        public void OpenFolder(string path) { }
        public void FinishUpdate() { }
    }
    private static (MainViewModel vm, Engine engine, Interaction ui, Updates updates, Settings settings) Setup()
    {
        var engine = new Engine(); var ui = new Interaction(); var updates = new Updates(); var settings = new Settings { Folder = "/test" };
        var vm = new MainViewModel(settings, ui, updates, (_, _) => engine); vm.Initialize(); vm.Poll();
        return (vm, engine, ui, updates, settings);
    }
    [Fact] public void SnapshotDisplaysPreviewCountsAndCountdown() { var t = Setup(); Assert.Equal("0:02", t.vm.Remaining); Assert.Contains("Comp 2: 10:05", t.vm.Preview); Assert.True(t.vm.Build.CanExecute(null)); }
    [Theory]
    [InlineData(0UL, "0:00")]
    [InlineData(1UL, "0:01")]
    [InlineData(60000UL, "1:00")]
    public void CountdownRoundsUp(ulong value, string expected) => Assert.Equal(expected, MainViewModel.Clock(value));
    [Fact] public void ReadyNotificationOccursOncePerTransition() { var t = Setup(); t.vm.Poll(); Assert.Equal(1, t.ui.Notifications); t.engine.Ready = false; t.vm.Poll(); t.engine.Ready = true; t.vm.Poll(); Assert.Equal(2, t.ui.Notifications); }
    [Fact]
    public async Task BuildLocksEngineWorkUpdatesAndClose()
    {
        var t = Setup(); using var wait = new ManualResetEventSlim(); t.engine.BuildWait = wait;
        var work = t.vm.Build.ExecuteAsync(); Assert.True(t.vm.Busy); Assert.False(t.vm.CanClose); Assert.False(t.vm.ChooseFolder.CanExecute(null));
        await t.vm.CheckAsync(true); Assert.Equal(0, t.updates.Checks); int polls = t.engine.Polls; t.vm.Poll(); Assert.Equal(polls, t.engine.Polls);
        Assert.Throws<InvalidOperationException>(t.vm.Dispose); wait.Set(); await work; Assert.True(t.vm.OpenOutput.CanExecute(null)); Assert.Equal(1, t.engine.Builds);
    }
    [Fact] public async Task UnsavedPreferencesBlockUpdateAndClose() { var t = Setup(); t.ui.Editor = new(); var editing = t.vm.Preferences.ExecuteAsync(); await t.vm.CheckAsync(true); Assert.False(t.vm.CanClose); Assert.Equal(0, t.updates.Checks); t.ui.Editor.SetResult(null); await editing; Assert.True(t.vm.CanClose); }
    [Fact] public async Task CancelPreferencesRetainsPolicy() { var t = Setup(); await t.vm.Preferences.ExecuteAsync(); Assert.Equal(1920, t.settings.Policy.required_width); }
    [Fact] public async Task SaveFailureRollsBackEnginePolicy() { var t = Setup(); t.ui.Policy = new() { required_width = 1280 }; t.settings.Fail = true; await t.vm.Preferences.ExecuteAsync(); Assert.Equal(1920, t.engine.Policy.required_width); Assert.Contains("disk full", t.vm.Error); }
    [Fact] public async Task FailedUpdateLeavesApplicationUsable() { var t = Setup(); t.updates.Fail = true; await t.vm.CheckAsync(true); Assert.Contains("invalid signature", t.vm.Error); Assert.True(t.vm.Build.CanExecute(null)); Assert.True(t.vm.CanClose); }
    [Fact] public async Task InstalledUpdateCannotLoopBeforeRestart() { var t = Setup(); await t.vm.CheckAsync(true); await t.vm.CheckAsync(true); Assert.Equal(1, t.updates.Checks); Assert.Equal(1, t.updates.Installs); }
    [Fact] public async Task AutomaticDiscoveryNeverInstalls() { var t = Setup(); await t.vm.CheckAsync(false); Assert.Equal(0, t.updates.Installs); Assert.Contains("available", t.vm.Error); }
    [Fact] public async Task LaterDoesNotInstall() { var t = Setup(); t.ui.Confirm = false; await t.vm.CheckAsync(true); Assert.Equal(0, t.updates.Installs); }
    [Fact] public async Task FailedPreferenceWriteRetainsVisibleAutomaticState() { var t = Setup(); t.updates.Fail = true; await t.vm.ToggleAutomatic.ExecuteAsync(); Assert.True(t.vm.Automatic); Assert.Contains("write failed", t.vm.Error); }
    [Fact] public void EditorPreservesEveryMediaField() { var p = new MediaPolicy(); var q = new PolicyEditor(p).Result(); Assert.Equal(JsonSerializer.Serialize(p), JsonSerializer.Serialize(q)); }
    [Theory]
    [InlineData("0")]
    [InlineData("-3")]
    [InlineData("abc")]
    public void InvalidDimensionsCannotSave(string value) { var editor = new PolicyEditor(new()) { Width = value }; Assert.Throws<ArgumentException>(() => editor.Result()); }
    [Theory]
    [InlineData("1/0")]
    [InlineData("NaN")]
    [InlineData("1/2/3")]
    public void InvalidRatiosCannotSave(string value) { var editor = new PolicyEditor(new()) { Rate = value }; Assert.Throws<ArgumentException>(() => editor.Result()); }
    [Fact] public void BlankMediaConstraintsRemainAny() { var p = new PolicyEditor(new()) { Width = "", Height = "", Rate = "", Aspect = "", Extensions = "" }.Result(); Assert.Null(p.required_width); Assert.Null(p.frame_rate); Assert.Empty(p.allowed_extensions); }
    [Fact]
    public void SettingsMigrateLegacyAndPersistWithoutChangingOtherFiles()
    {
        string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()); Directory.CreateDirectory(root);
        try { string old = Path.Combine(root, "old"), current = Path.Combine(root, "current"); Directory.CreateDirectory(old); File.WriteAllText(Path.Combine(old, "folder"), "/legacy"); var s = new SettingsStore(current, old); Assert.Equal("/legacy", s.LoadFolder()); s.SaveFolder("/new"); s.SavePolicy(new() { delete_rejected = false }); Assert.Equal("/new", s.LoadFolder()); Assert.False(s.LoadPolicy().delete_rejected); Assert.Equal("/legacy", File.ReadAllText(Path.Combine(old, "folder"))); Assert.Empty(Directory.GetFiles(current, "*.tmp")); }
        finally { Directory.Delete(root, true); }
    }
    [Fact]
    public void MalformedSettingsAreNotSilentlyReplacedWithDestructiveDefaults()
    {
        string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()); Directory.CreateDirectory(root);
        try { File.WriteAllText(Path.Combine(root, "media-policy.json"), "bad"); Assert.Throws<JsonException>(() => new SettingsStore(root).LoadPolicy()); }
        finally { Directory.Delete(root, true); }
    }
    [AvaloniaFact]
    public void SharedMainViewBindsAndRendersCommands()
    {
        var window = new MainWindow(new Settings(), new Updates(), (_, _) => new Engine()); window.Show(); Dispatcher.UIThread.RunJobs();
        Assert.True(window.FindControl<Button>("ChooseFolderButton")!.IsEnabled); Assert.False(window.FindControl<Button>("BuildButton")!.IsEffectivelyEnabled); Assert.Equal(3, window.KeyBindings.Count); window.Close();
    }
    [AvaloniaFact]
    public void InvalidEditorStaysOpenAndKeyboardTextBinds()
    {
        var model = new PolicyEditor(new()); var window = new PolicyWindow { DataContext = model }; window.Show();
        var field = window.FindControl<TextBox>("WidthField")!; field.Focus(); field.SelectAll(); window.KeyTextInput("invalid");
        window.FindControl<Button>("SaveButton")!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Dispatcher.UIThread.RunJobs();
        Assert.True(window.IsVisible); Assert.Contains("positive", model.Error); window.Close();
    }
    [AvaloniaFact]
    public void OverlayUsesSharedStateAndRemainsTopmost()
    {
        var t = Setup(); var window = new OverlayWindow { DataContext = t.vm }; window.Show(); Assert.True(window.Topmost); Assert.Same(t.vm, window.DataContext); window.Close();
    }
    [Fact]
    public async Task MacReferenceCannotReachProductionUpdater()
    {
        if (!OperatingSystem.IsMacOS()) return;
        var service = new UpdateService(); Assert.False(service.Supported); Assert.False(service.Automatic);
        await Assert.ThrowsAsync<PlatformNotSupportedException>(() => service.CheckAsync(true)); await Assert.ThrowsAsync<PlatformNotSupportedException>(() => service.InstallAsync("1.0.0"));
        Assert.Contains("FILLR-Avalonia-Internal", SettingsStore.DefaultRoot);
    }
    [Fact]
    public async Task SecondInstanceActivatesFirstWithoutOwningEngine()
    {
        string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var activated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            using var first = new InstanceLease(root, () => activated.TrySetResult());
            Assert.True(first.Acquired);
            using var second = new InstanceLease(root);
            Assert.False(second.Acquired);
            await activated.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        }
        finally { Directory.Delete(root, true); }
    }
    [AvaloniaFact]
    public void FailedAutomaticToggleRestoresCheckBox()
    {
        var window = new MainWindow(new Settings(), new Updates { Fail = true }, (_, _) => new Engine());
        window.Show();
        var toggle = window.FindControl<CheckBox>("AutomaticUpdates")!;
        toggle.Focus();
        window.KeyPress(Avalonia.Input.Key.Space, Avalonia.Input.RawInputModifiers.None, Avalonia.Input.PhysicalKey.Space, " ");
        window.KeyRelease(Avalonia.Input.Key.Space, Avalonia.Input.RawInputModifiers.None, Avalonia.Input.PhysicalKey.Space, " ");
        Dispatcher.UIThread.RunJobs();
        Assert.Contains("write failed", ((MainViewModel)window.DataContext!).Error);
        Assert.True(toggle.IsChecked);
        window.Close();
    }
}
