namespace FILLR;

internal sealed class MediaPolicy
{
    public bool enabled { get; set; } = true;
    public bool delete_rejected { get; set; } = true;
    public List<string> allowed_extensions { get; set; } = ["mpg"];
    public List<string> allowed_containers { get; set; } = ["mpeg"];
    public List<string> allowed_codecs { get; set; } = ["mpeg2video"];
    public int? required_width { get; set; } = 1920;
    public int? required_height { get; set; } = 1080;
    public string television_standard { get; set; } = "ntsc";
    public string? frame_rate { get; set; } = "30000/1001";
    public string scan_type { get; set; } = "interlaced";
    public string orientation { get; set; } = "horizontal";
    public string? display_aspect_ratio { get; set; } = "16:9";
}
