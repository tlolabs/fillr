using System.Runtime.InteropServices;
using System.Text.Json;

namespace FILLR;

internal static partial class FillrNative
{
    [LibraryImport("fillr_core", EntryPoint = "fillr_api_version")]
    internal static partial uint ApiVersion();

    [LibraryImport("fillr_core", EntryPoint = "fillr_create", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial nint Create(string folder, string ffprobe);

    [LibraryImport("fillr_core", EntryPoint = "fillr_snapshot")]
    internal static partial nint Snapshot(nint engine);

    [LibraryImport("fillr_core", EntryPoint = "fillr_build")]
    internal static partial nint Build(nint engine);

    [LibraryImport("fillr_core", EntryPoint = "fillr_refresh")]
    internal static partial void Refresh(nint engine);

    [LibraryImport("fillr_core", EntryPoint = "fillr_last_error")]
    internal static partial nint LastError();

    [LibraryImport("fillr_core", EntryPoint = "fillr_free_string")]
    internal static partial void FreeString(nint value);

    [LibraryImport("fillr_core", EntryPoint = "fillr_destroy")]
    internal static partial void Destroy(nint engine);

    internal static string TakeString(nint pointer)
    {
        if (pointer == 0) return "Unknown engine error";
        string result = Marshal.PtrToStringUTF8(pointer) ?? "";
        FreeString(pointer);
        return result;
    }
}

internal sealed class EngineHost : IDisposable
{
    private nint handle;

    public EngineHost(string folder)
    {
        if (FillrNative.ApiVersion() != 1) throw new InvalidOperationException("Incompatible Rust engine");
        string probe = Path.Combine(AppContext.BaseDirectory, "ffprobe.exe");
        handle = FillrNative.Create(folder, File.Exists(probe) ? probe : "ffprobe");
        if (handle == 0) throw new InvalidOperationException(FillrNative.TakeString(FillrNative.LastError()));
    }

    public JsonDocument Snapshot() => Parse(FillrNative.Snapshot(handle));
    public JsonDocument Build() => Parse(FillrNative.Build(handle));
    public void Refresh() => FillrNative.Refresh(handle);

    private static JsonDocument Parse(nint pointer)
    {
        if (pointer == 0) throw new InvalidOperationException(FillrNative.TakeString(FillrNative.LastError()));
        return JsonDocument.Parse(FillrNative.TakeString(pointer));
    }

    public void Dispose()
    {
        if (handle != 0) { FillrNative.Destroy(handle); handle = 0; }
    }
}
