import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CZlib

public enum BackgroundPlanningError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct BackgroundCut: Equatable, Sendable {
    public let path: URL
    public let startTicks: Int64
    public let endTicks: Int64
    public let sourceInTicks: Int64
    public var frames: Int { Int((endTicks - startTicks) / PremiereProject.frameTicks) }
    public var sourceInSeconds: Double { Double(sourceInTicks) / Double(PremiereProject.ticksPerSecond) }
}

public struct BackgroundSequence: Equatable, Sendable {
    public let name: String
    public let cuts: [BackgroundCut]
}

/// Imports only the saved, contiguous cut-only timelines of the Chabot template.
/// References to footage are rebased under mediaRoot, including symlink checks.
public enum PremiereProject {
    public static let ticksPerSecond: Int64 = 254_016_000_000
    public static let frameTicks: Int64 = 8_475_667_200
    private static let maximumXMLBytes = 128 * 1024 * 1024

    public static func load(project: URL, mediaRoot: URL) throws -> [String: BackgroundSequence] {
        try Task.checkCancellation()
        let raw = try Data(contentsOf: project, options: .mappedIfSafe)
        guard raw.count <= maximumXMLBytes else { throw fail("Premiere project is too large") }
        let data = raw.starts(with: [0x1f, 0x8b]) ? try inflateGzip(raw) : raw
        let parser = XMLParser(data: data)
        let document = XMLTreeBuilder()
        parser.delegate = document
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = document.root, root.name == "PremiereData" else {
            throw fail("Invalid Premiere XML: \(document.failure ?? parser.parserError?.localizedDescription ?? "expected PremiereData")")
        }
        var ids: [String: XMLNode] = [:], uids: [String: XMLNode] = [:]
        for node in root.children {
            if let id = node.attributes["ObjectID"] {
                guard ids.updateValue(node, forKey: id) == nil else { throw fail("Duplicate project ObjectID") }
            }
            if let id = node.attributes["ObjectUID"] {
                guard uids.updateValue(node, forKey: id) == nil else { throw fail("Duplicate project ObjectUID") }
            }
        }
        func resolve(_ reference: XMLNode?, _ expected: String? = nil) throws -> XMLNode {
            guard let reference else { throw fail("A required project reference is missing") }
            let node = reference.attributes["ObjectRef"].flatMap { ids[$0] }
                ?? reference.attributes["ObjectURef"].flatMap { uids[$0] }
            guard let node, expected == nil || node.name == expected else {
                throw fail("Unresolved \(expected ?? "object") reference")
            }
            return node
        }
        func plainComponents(_ node: XMLNode, clip: Bool) throws {
            guard let chain = node.at("ComponentChain"), chain.children.allSatisfy({ $0.name == "Node" }),
                  !clip || (node.textAt("DefaultMotion") == "true" && node.textAt("DefaultOpacity") == "true") else {
                throw fail("Custom video effects or transforms are unsupported")
            }
        }
        let rootURL = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        var result: [String: BackgroundSequence] = [:]
        for sequence in root.children where sequence.name == "Sequence" {
            try Task.checkCancellation()
            let name = sequence.textAt("Name") ?? ""
            guard name.hasPrefix("Comp ") else { continue }
            guard result[name] == nil else { throw fail("Duplicate sequence name: \(name)") }
            let groupRefs = sequence.nodes("TrackGroups/TrackGroup").filter {
                $0.textAt("First") == "228cda18-3625-4d2d-951e-348879e4ed93"
            }
            guard groupRefs.count == 1 else { throw fail("\(name): expected one video track group") }
            let group = try resolve(groupRefs[0].at("Second"), "VideoTrackGroup")
            guard try group.integer("TrackGroup/FrameRate") == frameTicks else {
                throw fail("Only 30000/1001 sequences are supported")
            }
            try plainComponents(resolve(group.at("ComponentOwner/Components"), "VideoComponentChain"), clip: false)
            var tracks: [(Int64, [BackgroundCut])] = []
            for reference in group.nodes("TrackGroup/Tracks/Track") {
                let track = try resolve(reference, "VideoClipTrack")
                guard let clips = track.at("ClipTrack") else { throw fail("\(name): missing ClipTrack") }
                let index = try clips.integer("Track/Index", default: 0)
                guard clips.textAt("Track/IsMuted") == nil || clips.textAt("Track/IsMuted") == "false" else {
                    throw fail("Muted or unrecognized video track states are unsupported")
                }
                guard !clips.nodes("TransitionItems").contains(where: { $0.hasReferenceDescendant }) else {
                    throw fail("Video transitions are unsupported")
                }
                var cuts: [BackgroundCut] = []
                for reference in clips.nodes("ClipItems/TrackItems/TrackItem") {
                    let item = try resolve(reference, "VideoClipTrackItem")
                    let subclip = try resolve(item.at("ClipTrackItem/SubClip"), "SubClip")
                    let clip = try resolve(subclip.at("Clip"), "VideoClip")
                    let source = try resolve(clip.at("Clip/Source"), "VideoMediaSource")
                    let media = try resolve(source.at("MediaSource/Media"), "Media")
                    guard let storedPath = media.textAt("FilePath") else { throw fail("Clip has no file path") }
                    let local = try localMedia(storedPath, root: rootURL)
                    let start = try item.integer("ClipTrackItem/TrackItem/Start", default: 0)
                    let end = try item.integer("ClipTrackItem/TrackItem/End")
                    let sourceIn = try clip.integer("Clip/InPoint", default: 0)
                    let sourceOut = try clip.integer("Clip/OutPoint")
                    guard start >= 0, end > start, sourceIn >= 0, sourceOut > sourceIn,
                          end - start == sourceOut - sourceIn else { throw fail("Invalid or retimed clip: \(local.lastPathComponent)") }
                    guard start % frameTicks == 0, end % frameTicks == 0, sourceIn % frameTicks == 0 else {
                        throw fail("Subframe edits are unsupported")
                    }
                    try plainComponents(resolve(item.at("ClipTrackItem/ComponentOwner/Components"), "VideoComponentChain"), clip: true)
                    let stream = try resolve(media.at("VideoStream"), "VideoStream")
                    guard try stream.integer("FrameRate", default: frameTicks) == frameTicks else {
                        throw fail("Timeline and source frame rates differ")
                    }
                    cuts.append(BackgroundCut(path: local, startTicks: start, endTicks: end, sourceInTicks: sourceIn))
                }
                if !cuts.isEmpty { tracks.append((index, cuts.sorted { $0.startTicks < $1.startTicks })) }
            }
            tracks.sort { $0.0 < $1.0 }
            guard let selected = tracks.last, tracks.count <= 2 else { throw fail("\(name): unsupported active video tracks") }
            let stills = Set(["jpg", "jpeg", "png", "tif", "tiff", "psd"])
            guard tracks.dropLast().allSatisfy({ $0.1.allSatisfy { stills.contains($0.path.pathExtension.lowercased()) } }) else {
                throw fail("Multiple active video tracks require compositing")
            }
            var end: Int64 = 0
            for cut in selected.1 {
                guard cut.startTicks == end else { throw fail("\(name): timeline has a gap or overlapping clips") }
                end = cut.endTicks
            }
            result[name] = BackgroundSequence(name: name, cuts: selected.1)
        }
        guard !result.isEmpty else { throw fail("No Comp N sequences were found") }
        return result
    }

    private static func localMedia(_ source: String, root: URL) throws -> URL {
        let parts = source.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let anchor = parts.firstIndex(of: "CNN Downloads"), anchor + 1 < parts.count else {
            throw fail("Media is outside the CNN Downloads asset tree")
        }
        let relative = parts[(anchor + 1)...]
        guard relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw fail("Invalid relative media path") }
        let local = relative.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard local.path.hasPrefix(root.path + "/") else { throw fail("Media resolves outside the asset tree") }
        guard (try? local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw fail("Missing media: \(local.path)")
        }
        return local
    }

    private static func inflateGzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw fail("Cannot initialize Premiere gzip decoder")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data(), chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let status = chunk.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                guard output.count + produced <= maximumXMLBytes else { throw fail("Expanded Premiere project is too large") }
                output.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw fail("Trailing data after Premiere gzip stream") }
                    return output
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { throw fail("Truncated or invalid Premiere gzip stream") }
            }
        }
    }

    private static func fail(_ text: String) -> BackgroundPlanningError { .invalid(text) }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func at(_ path: String) -> XMLNode? { nodes(path).first }
    func nodes(_ path: String) -> [XMLNode] {
        path.split(separator: "/").reduce([self]) { nodes, name in nodes.flatMap { $0.children.filter { $0.name == name } } }
    }
    func textAt(_ path: String) -> String? { at(path)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func integer(_ path: String, default fallback: Int64? = nil) throws -> Int64 {
        if let text = textAt(path), let value = Int64(text) { return value }
        if at(path) == nil, let fallback { return fallback }
        throw BackgroundPlanningError.invalid("Invalid integer at \(name)/\(path)")
    }
    var hasReferenceDescendant: Bool {
        attributes["ObjectRef"] != nil || attributes["ObjectURef"] != nil || children.contains { $0.hasReferenceDescendant }
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var failure: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if stack.count >= 128 { failure = "XML nesting is too deep"; parser.abortParsing(); return }
        let node = XMLNode(elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { failure = "XML entities are unsupported"; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { failure = "External XML entities are unsupported"; parser.abortParsing() }
}
