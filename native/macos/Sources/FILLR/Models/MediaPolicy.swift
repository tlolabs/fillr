import Foundation

struct MediaPolicy: Codable {
    var enabled = true
    var delete_rejected = true
    var allowed_extensions = ["mpg"]
    var allowed_containers = ["mpeg"]
    var allowed_codecs = ["mpeg2video"]
    var required_width: Int? = 1920
    var required_height: Int? = 1080
    var television_standard = "ntsc"
    var frame_rate: String? = "30000/1001"
    var scan_type = "interlaced"
    var orientation = "horizontal"
    var display_aspect_ratio: String? = "16:9"
}
