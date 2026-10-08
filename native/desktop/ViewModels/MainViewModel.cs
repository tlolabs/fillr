using System.Text.Json;
namespace FILLR;

internal sealed class MainViewModel : Observable, IDisposable
{
    private readonly ISettings settings;
    private readonly IUserInteraction ui;
    private readonly IUpdates updates;
    private readonly Func<string, MediaPolicy, IEngine> createEngine;
    private IEngine? engine;
    private MediaPolicy policy = new();
    private SortSettings sort = new();
    private bool ready, busy, disposed, installed;
    private string status = "Choose a download folder", folder = "Choose the folder where CNN MPG files arrive", error = "", remaining = "141:10", available = "0:00", counts = "0 usable clips", notes = "", preview = "The 14-Comp layout will appear when enough footage is ready.";
    private string? output;
    private double progress;
    public string Title => AppIdentity.Title;
    public string VersionLabel => $"Version {AppIdentity.Version}" + (AppIdentity.InternalReference ? " · INTERNAL ONLY · production updates disabled" : "");
    public string Folder => folder;
    public string Status => status;
    public string Error { get => error; private set => Set(ref error, value); }
    public string Remaining => remaining;
    public string Available => available;
    public string Counts => counts;
    public string Notes => notes;
    public string Preview => preview;
    public double Progress => progress;
    public bool Ready => ready;
    public bool Busy => busy;
    public bool CanClose => !busy;
    public bool UpdatesSupported => updates.Supported;
    public bool Automatic => updates.Automatic;
    public string OverlayStatus => ready ? "Ready to build" : "Footage remaining";
    public string TargetLabel => $"Remaining to {Clock(sort.total_ms)}";
    public double TargetMilliseconds => sort.total_ms;
    public string ReadyLabel => $"Ready — you can stop downloading. Build the {sort.folder_count} folders.";
    public string SettingsMenuLabel => OperatingSystem.IsWindows() ? "Settings…" : "Preferences…";
    public UiCommand ChooseFolder { get; }
    public UiCommand Preferences { get; }
    public UiCommand Refresh { get; }
    public UiCommand Build { get; }
    public UiCommand OpenOutput { get; }
    public UiCommand Overlay { get; }
    public UiCommand CheckUpdates { get; }
    public UiCommand ToggleAutomatic { get; }
    private IEnumerable<UiCommand> Commands => [ChooseFolder, Preferences, Refresh, Build, OpenOutput, CheckUpdates, ToggleAutomatic];
    public MainViewModel(ISettings settings, IUserInteraction ui, IUpdates updates, Func<string, MediaPolicy, IEngine> createEngine)
    {
        this.settings = settings; this.ui = ui; this.updates = updates; this.createEngine = createEngine;
        ChooseFolder = new(() => Guard(async () => { var path = await ui.ChooseFolderAsync(); if (path != null) Open(path); }), () => !busy);
        Preferences = new(() => Guard(() => ui.EditSettingsAsync(
            JsonSerializer.Deserialize<MediaPolicy>(JsonSerializer.Serialize(policy))!,
            JsonSerializer.Deserialize<SortSettings>(JsonSerializer.Serialize(sort))!, (next, nextSort) =>
            {
                nextSort.Validate();
                engine?.SetSettings(nextSort);
                try {
                    engine?.SetPolicy(next);
                    settings.SaveSortSettings(nextSort);
                    settings.SavePolicy(next);
                }
                catch {
                    try { settings.SaveSortSettings(sort); } catch { }
                    engine?.SetSettings(sort); engine?.SetPolicy(policy);
                    throw;
                }
                policy = next; sort = nextSort;
                remaining = Clock(sort.total_ms);
                preview = $"The {sort.folder_count}-folder layout will appear when enough footage is ready.";
                ready = false;
                Changed(nameof(TargetLabel)); Changed(nameof(TargetMilliseconds)); Changed(nameof(ReadyLabel)); Changed(nameof(Remaining)); Changed(nameof(Preview)); Changed(nameof(Ready));
            })), () => !busy);
        Refresh = new(() => Guard(() => { engine?.Refresh(); return Task.CompletedTask; }), () => !busy && engine != null);
        Build = new(() => Guard(async () =>
        {
            var current = engine!;
            using var result = await Task.Run(current.Build);
            var root = result.RootElement;
            if (!root.GetProperty("ok").GetBoolean()) throw new IOException(root.GetProperty("error").GetString());
            output = root.GetProperty("result").GetProperty("output_folder").GetString();
        }), () => ready && !busy && engine != null);
        OpenOutput = new(() => Guard(() => { ui.OpenFolder(output!); return Task.CompletedTask; }), () => output != null && !busy);
        Overlay = new(() => { ui.ToggleOverlay(); return Task.CompletedTask; });
        CheckUpdates = new(() => CheckAsync(true), () => updates.Supported && !busy);
        ToggleAutomatic = new(() => Guard(async () => { try { await updates.SetAutomaticAsync(!updates.Automatic); } finally { Changed(nameof(Automatic)); } }), () => updates.Supported && !busy);
    }
    public void Initialize()
    {
        try { policy = settings.LoadPolicy(); sort = settings.LoadSortSettings(); remaining = Clock(sort.total_ms); preview = $"The {sort.folder_count}-folder layout will appear when enough footage is ready."; Changed(nameof(TargetLabel)); Changed(nameof(TargetMilliseconds)); Changed(nameof(Remaining)); Changed(nameof(Preview)); var path = settings.LoadFolder(); if (!string.IsNullOrWhiteSpace(path)) Open(path); }
        catch (Exception ex) { Error = "Could not restore settings: " + ex.Message; }
    }
    private void Open(string path)
    {
        var next = createEngine(path, policy);
        try { settings.SaveFolder(path); } catch { next.Dispose(); throw; }
        engine?.Dispose(); engine = next; folder = path; ready = false; Changed(nameof(Folder));
    }
    public async Task OpenFolderAsync(string path) => await Guard(() => { Open(path); return Task.CompletedTask; });
    private async Task Guard(Func<Task> action, bool clearError = true)
    {
        if (busy || disposed) return;
        busy = true; if (clearError) Error = ""; Changed(nameof(Busy)); RefreshCommands();
        try { await action(); }
        catch (Exception ex) { Error = ex.Message; }
        finally { busy = false; Changed(nameof(Busy)); Poll(); RefreshCommands(); }
    }
    private void RefreshCommands() { foreach (var command in Commands) command.Refresh(); }
    public void Poll()
    {
        // Never overlap a C ABI call or dispose the engine during a build.
        if (busy || disposed || engine == null) return;
        try
        {
            using var doc = engine.Snapshot(); var state = doc.RootElement;
            bool wasReady = ready;
            ready = state.GetProperty("status").GetString() == "ready";
            status = state.GetProperty("message").GetString() ?? "";
            remaining = Clock(state.GetProperty("remaining_ms").GetUInt64());
            available = Clock(state.GetProperty("available_ms").GetUInt64());
            progress = Math.Min(state.GetProperty("available_ms").GetUInt64(), sort.total_ms);
            counts = $"{state.GetProperty("clips").GetArrayLength()} usable clips · {state.GetProperty("pending").GetArrayLength()} pending";
            notes = $"{state.GetProperty("excluded").GetArrayLength()} excluded files · {state.GetProperty("rejection_log").GetArrayLength()} rejected deleted · {state.GetProperty("duplicate_log").GetArrayLength()} exact duplicates deleted";
            preview = state.TryGetProperty("plan", out var plan) && plan.ValueKind == JsonValueKind.Object
                ? string.Join(Environment.NewLine, plan.GetProperty("assignments").EnumerateArray().Select(comp => $"{sort.folder_prefix} {comp.GetProperty("comp").GetInt32()}: {Clock(comp.GetProperty("duration_ms").GetUInt64())} · {comp.GetProperty("filenames").GetArrayLength()} clips"))
                : $"The {sort.folder_count}-folder layout will appear when enough footage is ready.";
            foreach (var name in new[] { nameof(Status), nameof(Remaining), nameof(Available), nameof(Progress), nameof(Counts), nameof(Notes), nameof(Preview), nameof(Ready), nameof(OverlayStatus) }) Changed(name);
            RefreshCommands();
            if (ready && !wasReady) ui.NotifyReady(sort.folder_count);
        }
        catch (Exception ex) { Error = ex.Message; }
    }
    public Task CheckAsync(bool manual) => !updates.Supported || (!manual && !updates.Automatic) ? Task.CompletedTask : Guard(async () =>
    {
        if (!updates.Supported) return;
        if (installed) { Error = "An update is installed. Restart FILLR before checking again."; return; }
        var result = await updates.CheckAsync(manual);
        if (!result.TryGetProperty("available", out var value) || !value.GetBoolean()) { if (manual) Error = "No newer compatible stable update is available."; return; }
        if (!manual) { Error = "A stable FILLR update is available. Choose Check for Updates to install it."; return; }
        string version = result.GetProperty("version").GetString()!;
        if (!await ui.ConfirmAsync($"Update FILLR to {version}?", "The signed package will be authenticated before installation. Media and settings are retained.\nRelease notes: " + result.GetProperty("notes_url").GetString(), "Download and Install")) return;
        status = "Downloading, verifying and installing update…"; Changed(nameof(Status));
        string instructions = await updates.InstallAsync(version);
        installed = true;
        if (await ui.ConfirmAsync("Update installed", instructions, OperatingSystem.IsLinux() ? "Restart FILLR" : "Close FILLR"))
        {
            // Defer shutdown until the guard has released; the view queues this on its dispatcher.
            ui.FinishUpdate();
        }
        else Error = "Update installed. Quit and reopen FILLR to use the new version.";
    }, clearError: manual);
    public static string Clock(ulong milliseconds) { var seconds = milliseconds / 1000 + (milliseconds % 1000 == 0 ? 0UL : 1UL); return $"{seconds / 60}:{seconds % 60:00}"; }
    public void Dispose() { if (busy) throw new InvalidOperationException("Cannot close during active work"); disposed = true; engine?.Dispose(); engine = null; }
}
