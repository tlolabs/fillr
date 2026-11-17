import Foundation
import CoreGraphics

/// Reads the limited 8-bit RGB PSD layer format used by the supplied crawl.
/// Cached layer pixels avoid changing static Photoshop text and bullet glyphs.
struct PSDTemplate {
    struct Layer {
        var name: String
        var left: Int
        var top: Int
        var width: Int
        var height: Int
        var channels: [(Int, Int)]
        var blocks: [String: Data]
        var image: CGImage?
    }
    let width: Int
    let height: Int
    var layers: [Layer]
    let dateText: String
    let fontSize: Double
    let tracking: Double
    let baseline: Double

    init(data: Data) throws {
        var reader = BinaryReader(data)
        guard try reader.ascii(4) == "8BPS", try reader.uint16() == 1 else { throw invalid("A version-1 PSD template is required") }
        try reader.skip(6)
        let channels = try reader.uint16()
        height = try reader.positive32()
        width = try reader.positive32()
        guard try reader.uint16() == 8, try reader.uint16() == 3, (3...4).contains(channels), width == 2376, height == 32 else {
            throw invalid("Expected the Chabot 2376×32, 8-bit RGB crawl PSD")
        }
        _ = try reader.section()
        _ = try reader.section()
        var mask = BinaryReader(try reader.section())
        var table = BinaryReader(try mask.section())
        let rawCount = try table.int16()
        let count = abs(Int(rawCount))
        guard (2...128).contains(count) else { throw invalid("Invalid PSD layer count") }
        var parsed: [Layer] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            let top = try table.int32(), left = try table.int32(), bottom = try table.int32(), right = try table.int32()
            let channelCount = try table.uint16()
            guard channelCount <= 8, bottom > top, right > left, right - left <= 16384, bottom - top <= 1024 else {
                throw invalid("Invalid PSD layer bounds or channels")
            }
            var layerChannels: [(Int, Int)] = []
            for _ in 0..<channelCount { layerChannels.append((Int(try table.int16()), try table.positive32())) }
            guard try table.ascii(4) == "8BIM", try table.ascii(4) == "norm" else { throw invalid("Unsupported PSD blend mode") }
            let opacity = try table.byte(), clipping = try table.byte(), flags = try table.byte()
            _ = try table.byte()
            var extra = BinaryReader(try table.section())
            let layerMask = try extra.section()
            _ = try extra.section()
            let nameLength = Int(try extra.byte())
            var name = String(data: try extra.take(nameLength), encoding: .macOSRoman) ?? ""
            try extra.skip((4 - (nameLength + 1) % 4) % 4)
            var blocks: [String: Data] = [:]
            while extra.remaining >= 12 {
                guard try extra.ascii(4) == "8BIM" else { throw invalid("Unsupported PSD additional-layer signature") }
                let key = try extra.ascii(4), value = try extra.section()
                blocks[key] = value
                try extra.skip(value.count % 2)
            }
            if let unicode = blocks["luni"] {
                var nameReader = BinaryReader(unicode)
                let characters = try nameReader.positive32()
                guard characters <= 4096, let decoded = String(data: try nameReader.take(characters * 2), encoding: .utf16BigEndian) else {
                    throw invalid("Invalid Unicode PSD layer name")
                }
                name = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            guard flags & 2 == 0, opacity == 255, clipping == 0, layerMask.isEmpty,
                  !["lfx2", "lrFX", "lsct", "lsdk"].contains(where: { blocks[$0] != nil }),
                  blocks["TySh"] != nil || name == "Background" else {
                throw invalid("Unsupported PSD visibility, effects, opacity, mask, or non-text layer: \(name)")
            }
            parsed.append(Layer(name: name, left: left, top: top, width: right - left, height: bottom - top,
                                channels: layerChannels, blocks: blocks, image: nil))
        }
        guard parsed.filter({ $0.name == "Background" }).count == 1,
              parsed.filter({ $0.name == "Show Date" }).count == 1,
              let background = parsed.first(where: { $0.name == "Background" }),
              background.left == 0, background.top == 0, background.width == width, background.height == height,
              let date = parsed.first(where: { $0.name == "Show Date" }), let type = date.blocks["TySh"] else {
            throw invalid("Expected one full-canvas Background and one Show Date PSD layer")
        }
        var transform = BinaryReader(type)
        guard try transform.uint16() == 1 else { throw invalid("Unsupported Photoshop text-tool version") }
        let xx = try transform.double(), xy = try transform.double(), yx = try transform.double(), yy = try transform.double()
        _ = try transform.double()
        baseline = try transform.double()
        guard zip([xx, xy, yx, yy], [1.0, 0.0, 0.0, 1.0]).allSatisfy({ abs($0 - $1) < 1e-9 }) else {
            throw invalid("The date text must be unscaled and unrotated")
        }
        dateText = try Self.text(type, token: "/Text").trimmingCharacters(in: CharacterSet(charactersIn: "\r\0"))
        fontSize = try Self.number(type, token: "/FontSize")
        tracking = try Self.number(type, token: "/Tracking")
        let typeText = String(decoding: type, as: UTF8.self)
        let whitePattern = #"/FillColor\s*<<\s*/Type\s+1\s*/Values\s*\[\s*1(?:\.0)?\s+1(?:\.0)?\s+1(?:\.0)?\s+1(?:\.0)?\s*\]"#
        guard fontSize > 0, fontSize <= 128, tracking.isFinite, baseline.isFinite,
              try Self.number(type, token: "/FontCaps") == 2, try Self.number(type, token: "/Font") == 0,
              typeText.range(of: whitePattern, options: .regularExpression) != nil,
              let fontSet = type.range(of: Data("/FontSet".utf8)),
              try Self.text(type.subdata(in: fontSet.lowerBound..<type.count), token: "/Name") == "Arial-BoldMT" else {
            throw invalid("Expected white, all-caps Arial Bold date text")
        }
        for index in parsed.indices {
            try Task.checkCancellation()
            parsed[index].image = try Self.readPixels(layer: parsed[index], reader: &table)
        }
        layers = parsed
    }

    private static func readPixels(layer: Layer, reader: inout BinaryReader) throws -> CGImage {
        let size = layer.width * layer.height
        var planes: [Int: [UInt8]] = [:]
        for (id, length) in layer.channels {
            var channel = BinaryReader(try reader.take(length))
            let compression = try channel.uint16()
            var output: [UInt8] = []
            if compression == 0 {
                output = Array(try channel.take(size))
            } else if compression == 1 {
                var rowSizes: [Int] = []
                for _ in 0..<layer.height { rowSizes.append(try channel.uint16()) }
                output.reserveCapacity(size)
                for bytes in rowSizes {
                    var row = BinaryReader(try channel.take(bytes)), decoded: [UInt8] = []
                    while row.remaining > 0 {
                        let marker = Int(Int8(bitPattern: try row.byte()))
                        if marker >= 0 { decoded.append(contentsOf: try row.take(marker + 1)) }
                        else if marker != -128 { decoded.append(contentsOf: repeatElement(try row.byte(), count: 1 - marker)) }
                        guard decoded.count <= layer.width else { throw invalid("PSD RLE row exceeds its width") }
                    }
                    guard decoded.count == layer.width else { throw invalid("Incomplete PSD RLE row") }
                    output.append(contentsOf: decoded)
                }
            } else { throw invalid("Unsupported PSD channel compression") }
            guard channel.remaining == 0, output.count == size, [-1, 0, 1, 2].contains(id), planes[id] == nil else {
                throw invalid("Invalid PSD layer channel")
            }
            planes[id] = output
        }
        guard let red = planes[0], let green = planes[1], let blue = planes[2] else { throw invalid("PSD layer lacks RGB channels") }
        let alpha = planes[-1]
        var rgba = [UInt8](repeating: 0, count: size * 4)
        for pixel in 0..<size {
            let a = Int(alpha?[pixel] ?? 255)
            rgba[pixel * 4] = UInt8((Int(red[pixel]) * a + 127) / 255)
            rgba[pixel * 4 + 1] = UInt8((Int(green[pixel]) * a + 127) / 255)
            rgba[pixel * 4 + 2] = UInt8((Int(blue[pixel]) * a + 127) / 255)
            rgba[pixel * 4 + 3] = UInt8(a)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: layer.width, height: layer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: layer.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw invalid("Cannot create cached PSD layer image")
        }
        return image
    }

    static func number(_ data: Data, token: String) throws -> Double {
        let string = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: token) + #"\s+(-?[0-9.]+)"#)
        guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string), let value = Double(string[range]), value.isFinite else {
            throw invalid("PSD text property \(token) is missing or invalid")
        }
        return value
    }

    static func text(_ data: Data, token: String) throws -> String {
        let bytes = Array(data), tokenBytes = Array(token.utf8)
        guard let found = data.range(of: Data(tokenBytes)) else { throw invalid("PSD text property \(token) is missing") }
        var position = found.upperBound
        while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        guard position < bytes.count, bytes[position] == 40 else { throw invalid("Invalid PSD text string") }
        position += 1
        var output: [UInt8] = [], depth = 1
        while position < bytes.count {
            var value = bytes[position]; position += 1
            if value == 92 {
                guard position < bytes.count else { break }
                value = bytes[position]; position += 1
                if (48...55).contains(value) {
                    var octal = Int(value - 48), count = 1
                    while count < 3, position < bytes.count, (48...55).contains(bytes[position]) {
                        octal = octal * 8 + Int(bytes[position] - 48); position += 1; count += 1
                    }
                    guard octal <= 255 else { throw invalid("Invalid PSD text escape") }; value = UInt8(octal)
                } else if value == 10 || value == 13 {
                    if value == 13, position < bytes.count, bytes[position] == 10 { position += 1 }
                    continue
                } else { value = [110: 10, 114: 13, 116: 9, 98: 8, 102: 12][value] ?? value }
            } else if value == 40 { depth += 1 }
            else if value == 41 {
                depth -= 1
                if depth == 0 {
                    let raw = Data(output)
                    guard raw.starts(with: [0xfe, 0xff]) || raw.starts(with: [0xff, 0xfe]),
                          let decoded = String(data: raw, encoding: .utf16) else { throw invalid("PSD text must contain a Unicode byte-order marker") }
                    return decoded
                }
            }
            output.append(value)
        }
        throw invalid("Unterminated PSD text string")
    }
}

private func invalid(_ text: String) -> BackgroundPlanningError { .invalid(text) }

private struct BinaryReader {
    let data: Data
    var position = 0
    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - position }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw invalid("Truncated or invalid PSD layer data") }
        defer { position += count }
        return data.subdata(in: position..<(position + count))
    }
    mutating func skip(_ count: Int) throws { _ = try take(count) }
    mutating func byte() throws -> UInt8 { try take(1).first! }
    mutating func uint16() throws -> Int { try take(2).reduce(0) { ($0 << 8) | Int($1) } }
    mutating func int16() throws -> Int16 { Int16(bitPattern: UInt16(try uint16())) }
    mutating func int32() throws -> Int { Int(Int32(bitPattern: UInt32(try unsigned(4)))) }
    mutating func positive32() throws -> Int { Int(try unsigned(4)) }
    mutating func unsigned(_ count: Int) throws -> UInt64 { try take(count).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func double() throws -> Double { Double(bitPattern: try unsigned(8)) }
    mutating func ascii(_ count: Int) throws -> String { String(decoding: try take(count), as: UTF8.self) }
    mutating func section() throws -> Data { let count = try positive32(); return try take(count) }
}
