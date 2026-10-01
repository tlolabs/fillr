using System.Diagnostics;
using System.Text.Json;
namespace FILLR;

internal sealed class UpdateService : IUpdates
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public bool Supported => !AppIdentity.InternalReference;
    public bool Automatic { get; private set; } = true;
    public UpdateService()
    {
        if (!Supported) { Automatic = false; return; }
        var root = OperatingSystem.IsWindows() ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            : Environment.GetEnvironmentVariable("XDG_CACHE_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cache");
        var path = Path.Combine(root, "fillr", "updates", "state.json");
        if (File.Exists(path))
        {
            try { using var doc = JsonDocument.Parse(File.ReadAllText(path)); Automatic = !doc.RootElement.GetProperty("disabled").GetBoolean(); }
            catch (Exception ex) when (ex is IOException or JsonException or InvalidOperationException or KeyNotFoundException) { Automatic = false; }
        }
    }
    public async Task SetAutomaticAsync(bool enabled) { await RunAsync(enabled ? "enable" : "disable"); Automatic = enabled; }
    public Task<JsonElement> CheckAsync(bool manual) => RunAsync(manual ? "check" : "check-auto");
    public async Task<string> InstallAsync(string version)
    {
        if (!Supported) throw new PlatformNotSupportedException("Internal reference builds cannot update.");
#if WINDOWS
        JsonElement? download = null;
        try {
            download = await RunAsync("download", version);
            await WindowsPackageInstaller.VerifyAndStageAsync(download.Value);
            await WindowsPackageInstaller.VerifyAndStageAsync(download.Value, install: true);
            return "Windows will complete registration when FILLR closes. Reopen FILLR from Start to use the new version.";
        }
        finally {
            if (download.HasValue) {
                var error = WindowsPackageInstaller.CleanupDownload(download.Value);
                if (error != null) Console.Error.WriteLine(error);
            }
        }
#else
        if (!OperatingSystem.IsLinux()) throw new PlatformNotSupportedException("No production installer on this platform.");
        var result = await RunAsync("install-appimage", version);
        if (result.GetProperty("status").GetString() != "installed") throw new IOException("The updater did not confirm installation.");
        return "Quit and reopen this AppImage to use the new version. Recovery copy: " + result.GetProperty("backup").GetString();
#endif
    }
    private async Task<JsonElement> RunAsync(string command, string? version = null)
    {
        if (!Supported) throw new PlatformNotSupportedException("Internal reference builds cannot contact production update channels.");
        await gate.WaitAsync();
        try
        {
            var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, OperatingSystem.IsWindows() ? "fillr-update.exe" : "fillr-update"))
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            start.ArgumentList.Add(command); if (version != null) start.ArgumentList.Add(version);
            using var process = Process.Start(start) ?? throw new IOException("Cannot start the updater.");
            var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(20));
            try { await process.WaitForExitAsync(timeout.Token); }
            catch { try { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); } catch (InvalidOperationException) { } throw; }
            if (process.ExitCode != 0) throw new IOException(await errors);
            using var doc = JsonDocument.Parse(await output); return doc.RootElement.Clone();
        }
        finally { gate.Release(); }
    }
}
