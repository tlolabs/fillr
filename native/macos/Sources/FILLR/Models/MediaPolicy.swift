import Foundation

struct MediaPolicy: Codable {
    var enabled = true
    var delete_rejected = true
    var allowed_extensions = ["mpg", "mov"]
    var allowed_containers = ["mpeg", "mov"]
    var allowed_codecs = ["mpeg2video", "prores"]
    var required_width: Int? = 1920
    var required_height: Int? = 1080
    var television_standard = "ntsc"
    var frame_rate: String? = "30000/1001"
    var scan_type = "interlaced"
    var orientation = "horizontal"
    var display_aspect_ratio: String? = "16:9"

    // The converter publishes only verified ProRes MOVs. Keep user profile
    // constraints, while allowing these outputs even with a saved MPG preset.
    var proResCollectionPolicy: MediaPolicy {
        var policy = self
        policy.delete_rejected = false
        if !policy.allowed_extensions.isEmpty && !policy.allowed_extensions.contains("mov") {
            policy.allowed_extensions.append("mov")
        }
        if !policy.allowed_containers.isEmpty && !policy.allowed_containers.contains("mov") {
            policy.allowed_containers.append("mov")
        }
        if !policy.allowed_codecs.isEmpty && !policy.allowed_codecs.contains("prores") {
            policy.allowed_codecs.append("prores")
        }
        return policy
    }

    // Conversion changes the container and codec, but preserves the source's
    // video profile. Count those matching MPEG downloads before conversion.
    var downloadProgressPolicy: MediaPolicy {
        var policy = self
        policy.delete_rejected = false
        policy.allowed_extensions = ["mpg", "mpeg", "m2v"]
        policy.allowed_containers = []
        policy.allowed_codecs = ["mpeg2video", "prores"]
        // The ingest codec/extension limits apply even when optional profile
        // filtering is off. Unsupported inputs cannot become ProRes copies.
        policy.enabled = true
        if !enabled {
            policy.required_width = nil
            policy.required_height = nil
            policy.television_standard = "any"
            policy.frame_rate = nil
            policy.scan_type = "any"
            policy.orientation = "any"
            policy.display_aspect_ratio = nil
        }
        return policy
    }
}
