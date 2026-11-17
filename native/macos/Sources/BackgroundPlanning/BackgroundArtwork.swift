import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum BackgroundArtwork {
    struct Result {
        let bands: [[String: Any]]
        let metadata: [String: Any]
    }

    static func prepare(psd: URL, showDate: Date, workDirectory: URL) throws -> Result {
        try Task.checkCancellation()
        let sourceData = try Data(contentsOf: psd, options: .mappedIfSafe)
        guard sourceData.count <= 32 * 1024 * 1024 else { throw error("Crawl PSD is too large") }
        var template = try PSDTemplate(data: sourceData)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MMMM d, yyyy"
        let displayedDate = formatter.string(from: showDate)
        let originalDate = template.dateText
        let changed = displayedDate.caseInsensitiveCompare(originalDate) != .orderedSame
        let flattened: CGImage
        var gap: Double?
        if changed {
            let rendered = try dateImage(displayedDate.uppercased(), pointSize: template.fontSize, tracking: template.tracking)
            guard let dateIndex = template.layers.firstIndex(where: { $0.name == "Show Date" }) else { throw error("Missing date layer") }
            let elements = template.layers.filter { $0.name != "Background" }
            guard let left = elements.map(\.left).min(), let right = elements.map({ $0.left + $0.width }).max() else {
                throw error("Missing crawl elements")
            }
            template.layers[dateIndex].image = rendered.image
            template.layers[dateIndex].width = rendered.image.width
            template.layers[dateIndex].height = rendered.image.height
            template.layers[dateIndex].top = Int((template.baseline - rendered.top).rounded(.toNearestOrEven))
            var sorted = template.layers.indices.filter { template.layers[$0].name != "Background" }
            sorted.sort { template.layers[$0].left < template.layers[$1].left }
            guard sorted.count >= 2 else { throw error("At least two crawl elements are required") }
            let sum = sorted.reduce(0) { $0 + template.layers[$1].width }
            let spacing = Double(right - left - sum) / Double(sorted.count - 1)
            guard spacing >= 0 else { throw error("The date is too wide to fit without overlapping crawl elements") }
            var cursor = Double(left)
            for index in sorted {
                template.layers[index].left = Int(cursor.rounded(.toNearestOrEven))
                cursor += Double(template.layers[index].width) + spacing
            }
            gap = spacing
            let context = try canvas(width: template.width, height: template.height)
            // PSD stores topmost layers first. Draw from the bottom upward.
            for layer in template.layers.reversed() {
                guard let image = layer.image else { throw error("Missing cached PSD layer") }
                context.draw(image, in: CGRect(x: layer.left, y: template.height - layer.top - layer.height,
                                              width: layer.width, height: layer.height))
            }
            guard let image = context.makeImage() else { throw error("Cannot flatten crawl") }
            flattened = image
        } else {
            // ImageIO reads the PSD's saved merged image without rerasterizing text.
            guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
                  image.width == template.width, image.height == template.height else {
                throw error("Cannot read the PSD's saved flattened preview")
            }
            let context = try canvas(width: template.width, height: template.height)
            context.draw(image, in: CGRect(x: 0, y: 0, width: template.width, height: template.height))
            guard let opaque = context.makeImage() else { throw error("Cannot flatten crawl") }
            flattened = opaque
        }
        try writePNG(flattened, to: workDirectory.appendingPathComponent("crawl-flattened.png"))
        let animationEnd = 14_384_800.0 / 23_976
        var bands: [[String: Any]] = []
        for (name, scale, px, py, endX, offsets) in [
            ("small", 0.89, 1062.0, 411.0, -21840.0, [0.0, 2110] + (2..<12).map { Double(2124 * $0) }),
            ("big", 1.6, 1083.0, 777.0, -11212.0, (0..<7).map { Double(3800 * $0) })
        ] {
            try Task.checkCancellation()
            let width = Int((2376 * scale * 2).rounded(.toNearestOrEven))
            let height = Int((32 * scale * 2).rounded(.toNearestOrEven))
            let tileContext = try canvas(width: width, height: height)
            tileContext.interpolationQuality = .high
            tileContext.draw(flattened, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let tile = tileContext.makeImage() else { throw error("Cannot create crawl tile") }
            let tileURL = workDirectory.appendingPathComponent("\(name)-tile.png")
            try writePNG(tile, to: tileURL)
            let left = (px - 1188 * scale) * 0.5
            let top = 539 + (py - 16 * scale) * 0.5
            // The renderer reconstructs copies in Metal, avoiding enormous banners.
            bands.append(["name": name, "path": tileURL.path, "tile_path": tileURL.path,
                          "height": max(1, Int((Double(height) / 4).rounded(.toNearestOrEven))), "source_height": height,
                          "y": Int(top.rounded(.toNearestOrEven)), "start_x": (10 - left) * 4,
                          "speed": (px - endX) / animationEnd * 2, "copy_offsets": offsets.map { $0 * 2 }])
        }
        var metadata: [String: Any] = ["date": displayedDate, "original_date": originalDate,
                                      "date_changed": changed, "width": template.width, "height": template.height,
                                      "opaque": true, "antialiasing_approximation": changed,
                                      "fidelity_note": changed
                                      ? "Native CoreText draws only the changed date; static text and bullets retain cached Photoshop pixels."
                                      : "The PSD's saved flattened pixels are preserved without rerasterizing text."]
        if let gap { metadata["spacing_gap_px"] = gap }
        return Result(bands: bands, metadata: metadata)
    }

    private static func dateImage(_ text: String, pointSize: Double, tracking: Double) throws -> (image: CGImage, top: Double) {
        let font = CTFontCreateWithName("Arial-BoldMT" as CFString, pointSize, nil)
        guard CTFontCopyPostScriptName(font) as String == "Arial-BoldMT" else { throw error("Arial Bold is required to change the show date") }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTKernAttributeName as String): tracking * pointSize / 1000
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).integral
        guard bounds.width > 0, bounds.width <= 4096, bounds.height > 0, bounds.height <= 512 else {
            throw error("Invalid date glyph bounds")
        }
        let context = try canvas(width: Int(bounds.width), height: Int(bounds.height), opaque: false)
        context.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw error("Cannot draw show date") }
        return (image, bounds.maxY)
    }

    private static func canvas(width: Int, height: Int, opaque: Bool = true) throws -> CGContext {
        guard width > 0, height > 0, width <= 16384, height <= 4096,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw error("Cannot allocate native artwork canvas")
        }
        if opaque {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let buffer = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw error("Cannot create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw error("Cannot encode PNG") }
        try (buffer as Data).write(to: url, options: .withoutOverwriting)
    }

    private static func error(_ text: String) -> BackgroundPlanningError { .invalid(text) }
}
