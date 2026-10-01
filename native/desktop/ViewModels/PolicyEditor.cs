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
    public string[] Standards { get; } = ["any", "ntsc", "pal"];
    public string[] Scans { get; } = ["any", "interlaced", "progressive"];
    public string[] Orientations { get; } = ["any", "horizontal", "vertical"];
    private string error = "";
    public string Error { get => error; set => Set(ref error, value); }
    public PolicyEditor(MediaPolicy p)
    {
        Enabled = p.enabled; DeleteRejected = p.delete_rejected;
        Extensions = string.Join(", ", p.allowed_extensions); Containers = string.Join(", ", p.allowed_containers); Codecs = string.Join(", ", p.allowed_codecs);
        Width = p.required_width?.ToString(CultureInfo.InvariantCulture) ?? ""; Height = p.required_height?.ToString(CultureInfo.InvariantCulture) ?? "";
        Rate = p.frame_rate ?? ""; Aspect = p.display_aspect_ratio ?? ""; Standard = p.television_standard; Scan = p.scan_type; Orientation = p.orientation;
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
