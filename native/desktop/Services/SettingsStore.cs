using System.Text.Json;
namespace FILLR;

internal sealed class SettingsStore(string root, string? legacy = null, bool windows = false) : ISettings
{
    public static string DefaultRoot => OperatingSystem.IsMacOS()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TLOLabs", "FILLR-Avalonia-Internal")
        : OperatingSystem.IsWindows()
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FILLR")
            : Path.Combine(Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config"), "fillr");
    public static SettingsStore Create() => new(DefaultRoot,
        OperatingSystem.IsWindows() ? Path.Combine(Path.GetDirectoryName(DefaultRoot)!, "ChabotBackgrounder") :
        OperatingSystem.IsLinux() ? Path.Combine(Path.GetDirectoryName(DefaultRoot)!, "chabot-backgrounder") : null,
        OperatingSystem.IsWindows());
    private string FolderFile => windows ? "folder.txt" : "folder";
    public string? LoadFolder()
    {
        var path = Path.Combine(root, FolderFile);
        if (!File.Exists(path) && legacy != null) path = Path.Combine(legacy, FolderFile);
        return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
    }
    public MediaPolicy LoadPolicy()
    {
        var path = Path.Combine(root, "media-policy.json");
        return File.Exists(path) ? JsonSerializer.Deserialize<MediaPolicy>(File.ReadAllText(path)) ?? throw new IOException("Empty media preferences") : new();
    }
    public void SaveFolder(string folder) => Write("" + FolderFile, folder);
    public void SavePolicy(MediaPolicy policy) => Write("media-policy.json", JsonSerializer.Serialize(policy));
    private void Write(string name, string data)
    {
        Directory.CreateDirectory(root);
        string path = Path.Combine(root, name), temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, data); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
