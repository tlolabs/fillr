using System.Text.Json;
namespace FILLR;

internal interface IEngine : IDisposable
{
    JsonDocument Snapshot();
    JsonDocument Build();
    void Refresh();
    void SetPolicy(MediaPolicy policy);
}
internal interface ISettings
{
    string? LoadFolder();
    MediaPolicy LoadPolicy();
    void SaveFolder(string folder);
    void SavePolicy(MediaPolicy policy);
}
internal interface IUserInteraction
{
    Task<string?> ChooseFolderAsync();
    Task EditPolicyAsync(MediaPolicy policy, Action<MediaPolicy> save);
    Task<bool> ConfirmAsync(string title, string message, string accept);
    void NotifyReady();
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
