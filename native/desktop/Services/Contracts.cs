using System.Text.Json;
namespace FILLR;

internal interface IEngine : IDisposable
{
    JsonDocument Snapshot();
    JsonDocument Build();
    void Refresh();
    void SetPolicy(MediaPolicy policy);
    void SetSettings(SortSettings settings) { }
}
internal interface ISettings
{
    string? LoadFolder();
    MediaPolicy LoadPolicy();
    void SaveFolder(string folder);
    void SavePolicy(MediaPolicy policy);
    SortSettings LoadSortSettings() => new();
    void SaveSortSettings(SortSettings settings) { }
}
internal interface IUserInteraction
{
    Task<string?> ChooseFolderAsync();
    Task EditPolicyAsync(MediaPolicy policy, Action<MediaPolicy> save);
    Task EditSettingsAsync(MediaPolicy policy, SortSettings settings, Action<MediaPolicy, SortSettings> save) =>
        EditPolicyAsync(policy, next => save(next, settings));
    Task<bool> ConfirmAsync(string title, string message, string accept);
    void NotifyReady();
    void NotifyReady(int folderCount) => NotifyReady();
    void ToggleOverlay();
    void OpenFolder(string path);
    void FinishUpdate();
}
internal interface IUpdates
{
    bool Supported { get; }
    bool Automatic { get; }
    Task SetAutomaticAsync(bool enabled);
    Task<JsonElement> CheckAsync(bool manual);
    Task<string> InstallAsync(string version);
}
