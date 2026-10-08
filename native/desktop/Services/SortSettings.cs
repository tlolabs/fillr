namespace FILLR;

internal sealed class SortSettings
{
    public int folder_count { get; set; } = 14;
    public string folder_prefix { get; set; } = "Comp";
    public ulong total_ms { get; set; } = 8_470_000;

    public void Validate()
    {
        if (folder_count is < 1 or > 100) throw new ArgumentException("Folder count must be between 1 and 100.");
        if (total_ms == 0 || total_ms % 1000 != 0) throw new ArgumentException("Total time must be a positive whole number of seconds.");
        var prefix = folder_prefix?.Trim() ?? "";
        if (prefix.Length is < 1 or > 80 || prefix is "." or ".." || prefix.EndsWith('.') ||
            prefix.Any(c => char.IsControl(c) || "/\\:<>\"|?*".Contains(c)))
            throw new ArgumentException("Folder prefix must be a safe name of 1 to 80 characters.");
    }
}
