using System.Globalization;
namespace FILLR;

internal sealed class PolicyEditor : Observable
{
    public bool Enabled { get; set; }
    public bool DeleteRejected { get; set; }
    public string Extensions { get; set; }
    public string Containers { get; set; }
    public string Codecs { get; set; }
    public string Width { get; set; }
    public string Height { get; set; }
    public string Rate { get; set; }
    public string Aspect { get; set; }
    public string Standard { get; set; }
    public string Scan { get; set; }
    public string Orientation { get; set; }
    public string FolderCount { get; set; }
    public string FolderPrefix { get; set; }
    public string Hours { get; set; }
    public string Minutes { get; set; }
    public string Seconds { get; set; }
    public string[] Standards { get; } = ["any", "ntsc", "pal"];
    public string[] Scans { get; } = ["any", "interlaced", "progressive"];
    public string[] Orientations { get; } = ["any", "horizontal", "vertical"];
    private string error = "";
    public string Error { get => error; set => Set(ref error, value); }
    public PolicyEditor(MediaPolicy p, SortSettings? sort = null)
    {
        sort ??= new();
        FolderCount = sort.folder_count.ToString(CultureInfo.InvariantCulture);
        FolderPrefix = sort.folder_prefix;
        var totalSeconds = sort.total_ms / 1000;
        Hours = (totalSeconds / 3600).ToString(CultureInfo.InvariantCulture);
        Minutes = (totalSeconds / 60 % 60).ToString(CultureInfo.InvariantCulture);
        Seconds = (totalSeconds % 60).ToString(CultureInfo.InvariantCulture);
        Enabled = p.enabled; DeleteRejected = p.delete_rejected;
        Extensions = string.Join(", ", p.allowed_extensions); Containers = string.Join(", ", p.allowed_containers); Codecs = string.Join(", ", p.allowed_codecs);
        Width = p.required_width?.ToString(CultureInfo.InvariantCulture) ?? ""; Height = p.required_height?.ToString(CultureInfo.InvariantCulture) ?? "";
        Rate = p.frame_rate ?? ""; Aspect = p.display_aspect_ratio ?? ""; Standard = p.television_standard; Scan = p.scan_type; Orientation = p.orientation;
    }
    public SortSettings ResultSort()
    {
        if (!int.TryParse(FolderCount, out var count) || count is < 1 or > 100 ||
            !ulong.TryParse(Hours, out var hours) || !ulong.TryParse(Minutes, out var minutes) || minutes > 59 ||
            !ulong.TryParse(Seconds, out var seconds) || seconds > 59)
            throw new ArgumentException("Enter 1–100 folders and a valid hours, minutes, seconds time.");
        ulong total;
        try { total = checked((hours * 3600 + minutes * 60 + seconds) * 1000); }
        catch (OverflowException) { throw new ArgumentException("Total time is too large."); }
        var result = new SortSettings { folder_count = count, folder_prefix = FolderPrefix, total_ms = total };
        result.Validate();
        return result;
    }
    private static int? Number(string text) => string.IsNullOrWhiteSpace(text) ? null : int.TryParse(text, out int n) && n > 0 ? n : throw new ArgumentException("Width and height must be positive whole numbers or blank.");
    private static string? Ratio(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var parts = text.Trim().Split('/', ':');
        if (parts.Length > 2 || parts.Any(p => !double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out double n) || !double.IsFinite(n) || n <= 0))
            throw new ArgumentException("Frame rate and aspect ratio must be positive numbers or ratios, such as 30000/1001 and 16:9.");
        return text.Trim();
    }
    public MediaPolicy Result() => new()
    {
        enabled = Enabled,
        delete_rejected = DeleteRejected,
        allowed_extensions = Extensions.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToList(),
        allowed_containers = Containers.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToList(),
        allowed_codecs = Codecs.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToList(),
        required_width = Number(Width),
        required_height = Number(Height),
        frame_rate = Ratio(Rate),
        display_aspect_ratio = Ratio(Aspect),
        television_standard = Standards.Contains(Standard) ? Standard : throw new ArgumentException("Invalid television standard"),
        scan_type = Scans.Contains(Scan) ? Scan : throw new ArgumentException("Invalid scan type"),
        orientation = Orientations.Contains(Orientation) ? Orientation : throw new ArgumentException("Invalid orientation")
    };
}
