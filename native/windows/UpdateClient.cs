using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using Windows.Management.Deployment;

namespace FILLR;

internal static class UpdateClient
{
    private static readonly SemaphoreSlim CommandGate = new(1, 1);
    internal static async Task<JsonElement> RunAsync(string command, string? version = null)
    {
        await CommandGate.WaitAsync();
        try {
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "fillr-update.exe")) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        start.ArgumentList.Add(command);
        if (version != null) start.ArgumentList.Add(version);
        using var process = Process.Start(start) ?? throw new IOException("Cannot start the updater.");
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(20));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch { try { process.Kill(entireProcessTree: true); } catch { } throw; }
        if (process.ExitCode != 0) throw new IOException(await errors);
        using var json = JsonDocument.Parse(await output);
        return json.RootElement.Clone();
        } finally { CommandGate.Release(); }
    }

    // Windows' MSIX deployment service verifies the package signature and publisher trust
    // while staging. It does not register the package, terminate the app, or launch code.
    internal static async Task<string> VerifyAndStageAsync(JsonElement download, bool install = false)
    {
        // Keep the existing app usable on Windows 1809, but never call newer
        // deferred-registration APIs there (the release contract also filters it).
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
            throw new PlatformNotSupportedException("Automatic MSIX installation requires Windows 10 version 2004 or later.");
        string path = download.GetProperty("path").GetString()!;
        string publisher = download.GetProperty("identity").GetString()!;
        string version = download.GetProperty("version").GetString()!;
        if (!Path.IsPathFullyQualified(path) || !path.EndsWith(".msix", StringComparison.OrdinalIgnoreCase)
            || publisher == "UNCONFIGURED") throw new IOException("Unsupported update package.");
        // Deny writers/deletion while validating and handing bytes to the Windows service.
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        string digest = Convert.ToHexString(await SHA256.HashDataAsync(file)).ToLowerInvariant();
        if (digest != download.GetProperty("sha256").GetString()) throw new IOException("Update changed after download.");
        file.Position = 0;
        using (var archive = new ZipArchive(file, ZipArchiveMode.Read, leaveOpen: true))
        {
            var entries = archive.Entries.Where(e => e.FullName == "AppxManifest.xml").ToArray();
            if (entries.Length != 1 || entries[0].Length > 1024 * 1024) throw new IOException("Invalid MSIX manifest.");
            using var xml = XmlReader.Create(entries[0].Open(), new XmlReaderSettings {
                DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, CloseInput = true, MaxCharactersInDocument = 1024 * 1024
            });
            var document = XDocument.Load(xml);
            XNamespace ns = "http://schemas.microsoft.com/appx/manifest/foundation/windows10";
            var identity = document.Root?.Element(ns + "Identity") ?? throw new IOException("Missing package identity.");
            string arch = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
            if ((string?)identity.Attribute("Name") != "TLOLabs.FILLR"
                || (string?)identity.Attribute("Publisher") != publisher
                || (string?)identity.Attribute("Version") != version + ".0"
                || (string?)identity.Attribute("ProcessorArchitecture") != arch)
                throw new IOException("Update package identity, version, publisher, or architecture mismatch.");
        }
        var manager = new PackageManager();
        var result = install
            ? await manager.AddPackageByUriAsync(new Uri(path), new AddPackageOptions { DeferRegistrationWhenPackagesAreInUse = true })
            : await manager.StagePackageAsync(new Uri(path), null, DeploymentOptions.None);
        if (result.ExtendedErrorCode != null && result.ExtendedErrorCode.HResult < 0)
            throw new IOException("Windows rejected the signed update: " + result.ErrorText, result.ExtendedErrorCode);
        return path;
    }

    // Native deployment has consumed the package before its awaited operation
    // completes. Remove only this helper-owned file/directory, never recursively.
    internal static string? CleanupDownload(JsonElement download)
    {
        try {
            string path = Path.GetFullPath(download.GetProperty("path").GetString()!);
            var directory = new DirectoryInfo(Path.GetDirectoryName(path)!);
            string cache = Path.GetFullPath(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "fillr", "updates"));
            if (directory.Parent == null || !string.Equals(directory.Parent.FullName, cache, StringComparison.OrdinalIgnoreCase)
                || !directory.Name.StartsWith("download-", StringComparison.Ordinal)
                || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                return "The update cache path was unexpected; no files were removed.";
            File.Delete(path);
            Directory.Delete(directory.FullName, recursive: false);
            return null;
        } catch (Exception error) {
            return "The update completed its current step, but its temporary download could not be removed: " + error.Message;
        }
    }

}
