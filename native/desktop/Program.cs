using Avalonia;

namespace FILLR;

internal static class Program
{
    internal static string? RestartImage { get; set; }
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--version")) { Console.WriteLine(AppIdentity.Version); return 0; }
        if (OperatingSystem.IsMacOS() && System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture != System.Runtime.InteropServices.Architecture.Arm64)
            throw new PlatformNotSupportedException("The internal reference app supports Apple Silicon only.");
        int result;
        using (var instance = new InstanceLease(SettingsStore.DefaultRoot, App.ActivateExisting))
        {
            if (!instance.Acquired) return 1;
            result = BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        if (RestartImage != null)
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(RestartImage) { UseShellExecute = false }); }
            catch (Exception error) { Console.Error.WriteLine("Restart failed. Reopen the AppImage manually: " + error.Message); return 1; }
        }
        return result;
    }
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace();
}
internal static class AppIdentity
{
    public static bool InternalReference => OperatingSystem.IsMacOS();
    public static string Version => typeof(AppIdentity).Assembly.GetName().Version!.ToString(3);
    public static string Title => InternalReference ? "FILLR — Internal Avalonia Reference" : "FILLR";
}
