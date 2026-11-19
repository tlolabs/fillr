import Foundation
import XCTest
import CZlib
@testable import BackgroundPlanning

final class BackgroundPlanningTests: XCTestCase {
    private var temporary: URL!
    private var media: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("fillr-planning-\(UUID().uuidString)")
        media = temporary.appendingPathComponent("CNN Downloads")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for file in ["guide.jpg", "z-first.mpg", "a-second.mpg", "intro.mov"] {
            try Data("fixture".utf8).write(to: media.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testImporterPreservesCutOrderAndTrimsForXMLAndGzip() throws {
        for compressed in [false, true] {
            let project = temporary.appendingPathComponent("fixture.prproj")
            let xml = fixture()
            if compressed {
                let file = try XCTUnwrap(gzopen(project.path, "wb"))
                let result = xml.withCString { gzwrite(file, $0, UInt32(xml.utf8.count)) }
                XCTAssertEqual(result, Int32(xml.utf8.count))
                XCTAssertEqual(gzclose(file), Z_OK)
            } else { try Data(xml.utf8).write(to: project) }
            let sequence = try XCTUnwrap(PremiereProject.load(project: project, mediaRoot: media)["Comp 2"])
            XCTAssertEqual(sequence.cuts.map { $0.path.lastPathComponent }, ["z-first.mpg", "a-second.mpg"])
            XCTAssertEqual(sequence.cuts.map(\.frames), [2, 2])
            XCTAssertEqual(sequence.cuts[0].sourceInTicks, PremiereProject.frameTicks)
            XCTAssertEqual(sequence.cuts[1].sourceInSeconds, 3 * 1001 / 30000.0, accuracy: 1e-12)
        }
    }

    func testGapsOverlapsSubframesRetimingEffectsAndTransitionsAreRejected() throws {
        let ticks = PremiereProject.frameTicks
        let modifications: [(String, String)] = [
            ("<Start>0</Start>", "<Start>\(ticks)</Start>"),
            ("<End>\(ticks * 2)</End>", "<End>\(ticks * 3)</End>"),
            ("<OutPoint>\(ticks * 3)</OutPoint>", "<OutPoint>\(ticks * 2)</OutPoint>"),
            ("<DefaultMotion>true</DefaultMotion>", "<DefaultMotion>false</DefaultMotion>"),
            ("<TransitionItems/>", "<TransitionItems><TrackItem ObjectRef=\"transition\"/></TransitionItems>"),
            ("<IsMuted>false</IsMuted>", "<IsMuted>true</IsMuted>"),
            ("<FrameRate>\(ticks)</FrameRate>", "<FrameRate>\(ticks + 1)</FrameRate>"),
            ("<InPoint>\(ticks)</InPoint>", "<InPoint>\(ticks + 1)</InPoint>")
        ]
        for (before, after) in modifications {
            let project = try writeProject(fixture().replacingOccurrences(of: before, with: after))
            XCTAssertThrowsError(try PremiereProject.load(project: project, mediaRoot: media), "Must reject \(after)")
        }
    }

    func testPremiereOmittedZeroFieldsRemainValid() throws {
        let xml = fixture().replacingOccurrences(of: "<Start>0</Start>", with: "")
            .replacingOccurrences(of: "<InPoint>0</InPoint>", with: "")
            .replacingOccurrences(of: "<Index>0</Index>", with: "")
        let project = try writeProject(xml)
        let sequence = try XCTUnwrap(PremiereProject.load(project: project, mediaRoot: media)["Comp 2"])
        XCTAssertEqual(sequence.cuts[0].startTicks, 0)
        XCTAssertEqual(sequence.cuts.count, 2)
    }

    func testMissingAndEscapingMediaAreRejectedIncludingSymlinks() throws {
        for path in ["/unrelated/z-first.mpg", "/old/CNN Downloads/../outside.mpg", "/old/CNN Downloads/missing.mpg"] {
            let project = try writeProject(fixture().replacingOccurrences(of: "/old/CNN Downloads/z-first.mpg", with: path))
            XCTAssertThrowsError(try PremiereProject.load(project: project, mediaRoot: media))
        }
        let outside = temporary.appendingPathComponent("outside.mpg")
        try Data([0]).write(to: outside)
        let local = media.appendingPathComponent("z-first.mpg")
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: outside)
        let project = try writeProject(fixture())
        XCTAssertThrowsError(try PremiereProject.load(project: project, mediaRoot: media))
    }

    func testUnresolvedReferencesDuplicateObjectsAndInvalidGzipFail() throws {
        let broken = [
            fixture().replacingOccurrences(of: "ObjectRef=\"source-first\"", with: "ObjectRef=\"missing\""),
            fixture().replacingOccurrences(of: "</PremiereData>", with: "<Media ObjectID=\"group\"/></PremiereData>"),
            "<!DOCTYPE PremiereData [<!ENTITY injected 'text'>]><PremiereData><Name>&injected;</Name></PremiereData>"
        ]
        for xml in broken {
            let project = try writeProject(xml)
            XCTAssertThrowsError(try PremiereProject.load(project: project, mediaRoot: media))
        }
        let project = temporary.appendingPathComponent("bad.prproj")
        try Data([0x1f, 0x8b, 0, 1, 2]).write(to: project)
        XCTAssertThrowsError(try PremiereProject.load(project: project, mediaRoot: media))
    }

    func testGeometryAndIntroFrameValidation() throws {
        XCTAssertEqual(BackgroundProjectPlanner.layout.count, 15)
        XCTAssertNil(BackgroundProjectPlanner.layout[6])
        XCTAssertEqual(BackgroundProjectPlanner.geometry(1), ["width": 960, "height": 540, "x": 9, "y": 10, "visible_width": 940, "visible_height": 520])
        XCTAssertEqual(try BackgroundProjectPlanner.completeIntroFrames(["frame_count": 20, "frame_rate": "30000/1001"]), 20)
        XCTAssertEqual(try BackgroundProjectPlanner.completeIntroFrames(["frame_count": 0, "duration_seconds": 1.001, "frame_rate": "30000/1001"]), 30)
        XCTAssertEqual(try BackgroundProjectPlanner.completeIntroFrames(["streams": [["codec_type": "video", "duration": "1.001", "avg_frame_rate": "30000/1001"]]]), 30)
        XCTAssertThrowsError(try BackgroundProjectPlanner.completeIntroFrames(["frame_count": 20, "frame_rate": "25/1"]))
        XCTAssertThrowsError(try BackgroundProjectPlanner.completeIntroFrames(["frame_count": 0]))
        XCTAssertThrowsError(try BackgroundProjectPlanner.completeIntroFrames(["duration_seconds": Double.infinity]))
    }

    func testNativePSDReadsCachedPixelsAndRejectsMalformedData() throws {
        for compressed in [false, true] {
            let template = try PSDTemplate(data: psdFixture(rle: compressed))
            XCTAssertEqual(template.width, 2376)
            XCTAssertEqual(template.height, 32)
            XCTAssertEqual(template.dateText, "November 12, 2026")
            XCTAssertEqual(template.fontSize, 18)
            XCTAssertEqual(template.layers.count, 3)
            XCTAssertEqual(template.layers[0].image?.width, 200)
        }
        XCTAssertThrowsError(try PSDTemplate(data: Data(psdFixture().prefix(60))))
        XCTAssertThrowsError(try PSDTemplate(data: Data("bad PSD".utf8)))
    }

    func testNativeArtworkProducesTilesAndChangesOnlyGeneratedAssets() throws {
        let psd = temporary.appendingPathComponent("crawl.psd")
        let original = psdFixture()
        try original.write(to: psd)
        let work = temporary.appendingPathComponent("artwork")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let result = try BackgroundArtwork.prepare(psd: psd, showDate: date("2026-11-13"), workDirectory: work)
        XCTAssertEqual(result.bands.count, 2)
        XCTAssertEqual(result.bands[0]["source_height"] as? Int, 57)
        XCTAssertEqual(result.bands[1]["source_height"] as? Int, 102)
        XCTAssertEqual(result.metadata["date_changed"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: psd), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("small-tile.png").path))
        XCTAssertThrowsError(try BackgroundArtwork.prepare(psd: psd, showDate: date("2026-11-13"), workDirectory: work))
    }

    func testCompletePlannerLoopsIntroAndPreservesAllPanels() throws {
        let template = media.appendingPathComponent("Chabot News Backgrounds")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try psdFixture().write(to: template.appendingPathComponent("Text Crawl.psd"))
        let one = fixture()
        let body = one.replacingOccurrences(of: "<PremiereData>", with: "").replacingOccurrences(of: "</PremiereData>", with: "")
        // Objects are unique by comp; stored media names stay canonical.
        let comps = BackgroundProjectPlanner.layout.keys.sorted().filter { $0 != 1 }
        let all = comps.map { comp in
            let id = "c\(comp)-"
            return body.replacingOccurrences(of: "Comp 2", with: "Comp \(comp)")
                .replacingOccurrences(of: "ObjectID=\"", with: "ObjectID=\"\(id)")
                .replacingOccurrences(of: "ObjectUID=\"", with: "ObjectUID=\"\(id)")
                .replacingOccurrences(of: "ObjectRef=\"", with: "ObjectRef=\"\(id)")
                .replacingOccurrences(of: "ObjectURef=\"", with: "ObjectURef=\"\(id)")
        }.joined()
        let project = try writeProject("<PremiereData>\(all)</PremiereData>")
        let work = temporary.appendingPathComponent("job")
        let data = try BackgroundProjectPlanner.prepare(project: project, mediaRoot: media, intro: media.appendingPathComponent("intro.mov"),
                                                        showDate: date("2026-11-13"), workDirectory: work, frames: 4,
                                                        probe: { _ in ["frame_count": 3, "frame_rate": "30000/1001"] })
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let panels = try XCTUnwrap(job["panels"] as? [[String: Any]])
        XCTAssertEqual(panels.count, 15)
        XCTAssertEqual((panels[0]["segments"] as? [[String: Any]])?.compactMap { $0["frames"] as? Int }, [3, 1])
        XCTAssertEqual(job["frame_rate"] as? String, "30000/1001")
        XCTAssertEqual(try Data(contentsOf: work.appendingPathComponent("job.json")), data)
        XCTAssertThrowsError(try BackgroundProjectPlanner.prepare(project: project, mediaRoot: media, intro: media.appendingPathComponent("intro.mov"),
                                                                  showDate: date("2026-11-13"), workDirectory: work, frames: 4,
                                                                  probe: { _ in ["frame_count": 3] }))
    }

    func testReadyCollectionRendersBeyondTenMinutesWithoutPremiereAndTrimsOnlyFinalCuts() throws {
        let (plan, counts) = try footageFixture()
        let originals = try Dictionary(uniqueKeysWithValues: plan.assignments.flatMap(\.sources).map { ($0, try Data(contentsOf: $0)) })
        let work = temporary.appendingPathComponent("long-ready-job")
        let data = try BackgroundProjectPlanner.prepare(project: nil, mediaRoot: media,
            intro: media.appendingPathComponent("intro.mov"), showDate: date("2026-11-13"), workDirectory: work,
            useAllFootage: true, footagePlan: plan,
            probe: { source in ["frame_count": source.lastPathComponent == "intro.mov" ? 777 : counts[source]!, "frame_rate": "30000/1001"] })
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(job["frames"] as? Int, 20_000)
        XCTAssertEqual(job["duration_seconds"] as? Double ?? 0, 20_000 * 1001 / 30000.0, accuracy: 1e-9)
        XCTAssertEqual(job["footage_source"] as? String, "ready_collection")
        XCTAssertNil(job["project"])
        XCTAssertNil(job["project_sha256"])
        let panels = try XCTUnwrap(job["panels"] as? [[String: Any]])
        XCTAssertEqual(panels.count, 15)
        for panel in panels {
            let comp = try XCTUnwrap(panel["comp"] as? Int)
            let segments = try XCTUnwrap(panel["segments"] as? [[String: Any]])
            XCTAssertEqual(segments.compactMap { $0["frames"] as? Int }.reduce(0, +), 20_000)
            XCTAssertTrue(segments.allSatisfy { $0["source_in_seconds"] as? Int == 0 })
            if comp == 1 {
                XCTAssertEqual(segments.count, 26)
                XCTAssertEqual(segments.last?["frames"] as? Int, 575)
            } else {
                XCTAssertEqual(segments.count, 2)
                for (index, segment) in segments.enumerated() {
                    let source = URL(fileURLWithPath: try XCTUnwrap(segment["path"] as? String))
                    let used = try XCTUnwrap(segment["frames"] as? Int)
                    XCTAssertGreaterThan(used, 0)
                    XCTAssertLessThanOrEqual(used, counts[source]!)
                    if index == 0 { XCTAssertEqual(used, counts[source]!) }
                }
            }
        }
        for (source, bytes) in originals { XCTAssertEqual(try Data(contentsOf: source), bytes) }
    }

    func testReadyCollectionKeepsRequestedLegacyDurationWhenUseAllIsOff() throws {
        let (plan, counts) = try footageFixture()
        let data = try BackgroundProjectPlanner.prepare(project: nil, mediaRoot: media,
            intro: media.appendingPathComponent("intro.mov"), showDate: date("2026-11-13"),
            workDirectory: temporary.appendingPathComponent("legacy-ready-job"), frames: 17_982,
            useAllFootage: false, footagePlan: plan,
            probe: { source in ["frame_count": source.lastPathComponent == "intro.mov" ? 777 : counts[source]!, "frame_rate": "30000/1001"] })
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(job["frames"] as? Int, 17_982)
        XCTAssertEqual(job["use_all_footage"] as? Bool, false)
    }

    func testReadyCollectionRejectsMissingDuplicateEscapingAndWrongRateSources() throws {
        let (plan, counts) = try footageFixture()
        let first = plan.assignments[0]
        let outside = temporary.appendingPathComponent("outside.mov")
        try Data("outside".utf8).write(to: outside)
        let escaping = media.appendingPathComponent("escaping.mov")
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: outside)
        var wrongComp = plan.assignments
        wrongComp[0] = BackgroundFootageAssignment(comp: 6, sources: first.sources)
        let cases: [(BackgroundFootagePlan, String)] = [
            (BackgroundFootagePlan(assignments: Array(plan.assignments.dropLast())), "missing-comp"),
            (BackgroundFootagePlan(assignments: wrongComp), "wrong-comp"),
            (replacingFirstSources(plan, [media.appendingPathComponent("missing.mov")]), "missing-file"),
            (replacingFirstSources(plan, [outside]), "outside-file"),
            (replacingFirstSources(plan, [escaping]), "symlink-escape"),
            (replacingFirstSources(plan, [first.sources[0], first.sources[0]]), "duplicate-source")
        ]
        for (invalid, label) in cases {
            let work = temporary.appendingPathComponent(label)
            XCTAssertThrowsError(try BackgroundProjectPlanner.prepare(project: nil, mediaRoot: media,
                intro: media.appendingPathComponent("intro.mov"), showDate: date("2026-11-13"), workDirectory: work,
                useAllFootage: true, footagePlan: invalid,
                probe: { source in ["frame_count": counts[source] ?? 777, "frame_rate": "30000/1001"] }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        }
        for rate in ["25/1", "0/0", "unknown"] {
            let work = temporary.appendingPathComponent("bad-rate-\(UUID().uuidString)")
            XCTAssertThrowsError(try BackgroundProjectPlanner.prepare(project: nil, mediaRoot: media,
                intro: media.appendingPathComponent("intro.mov"), showDate: date("2026-11-13"), workDirectory: work,
                useAllFootage: true, footagePlan: plan,
                probe: { source in ["frame_count": counts[source] ?? 777, "frame_rate": rate] }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        }
    }

    func testReadyCollectionRejectsMetadataMutationAndExcessiveLength() throws {
        let (plan, counts) = try footageFixture()
        let changed = plan.assignments[0].sources[0]
        let work = temporary.appendingPathComponent("changed-ready-job")
        XCTAssertThrowsError(try BackgroundProjectPlanner.prepare(project: nil, mediaRoot: media,
            intro: media.appendingPathComponent("intro.mov"), showDate: date("2026-11-13"), workDirectory: work,
            useAllFootage: true, footagePlan: plan, probe: { source in
                if source == changed { try Data("changed bytes".utf8).write(to: source) }
                return ["frame_count": counts[source] ?? 777, "frame_rate": "30000/1001"]
            }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertThrowsError(try BackgroundProjectPlanner.prepare(project: nil, mediaRoot: media,
            intro: media.appendingPathComponent("intro.mov"), showDate: date("2026-11-13"),
            workDirectory: temporary.appendingPathComponent("too-long-ready-job"), useAllFootage: true, footagePlan: plan,
            probe: { _ in ["frame_count": BackgroundProjectPlanner.maximumFrames + 1, "frame_rate": "30000/1001"] }))
    }

    func testExportJournalRestoresRenamedFootageForAllFourteenComps() throws {
        for version in [2, 3] {
            let (root, journal) = try exportFixture(version: version)
            let plan = try BackgroundFootagePlan.loadExport(at: root)
            XCTAssertEqual(plan.assignments.map(\.comp), [2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
            XCTAssertEqual(plan.assignments.count, 14)
            XCTAssertTrue(plan.assignments.allSatisfy { $0.sources.count == 1 })
            let folders = try XCTUnwrap(journal["folder_names"] as? [String])
            for (index, assignment) in plan.assignments.enumerated() {
                XCTAssertEqual(assignment.sources[0].deletingLastPathComponent().lastPathComponent, folders[index])
                XCTAssertEqual(assignment.sources[0].lastPathComponent, String(format: "%08d.mov", index))
            }
        }
    }

    func testExportJournalRejectsInvalidLayoutPathsMissingMediaAndSymlinks() throws {
        for mode in ["version", "folders", "traversal", "duplicate", "missing", "symlink", "unknown-folder"] {
            let (root, original) = try exportFixture(version: 3)
            var journal = original
            var moves = try XCTUnwrap(journal["moves"] as? [[String: Any]])
            let firstPath = try XCTUnwrap(moves[0]["destination"] as? String)
            let source = root.appendingPathComponent(firstPath)
            switch mode {
            case "version": journal["version"] = 999
            case "folders": journal["folder_names"] = ["Scene 1"]
            case "traversal": moves[0]["destination"] = "../outside.mov"
            case "duplicate": moves.append(moves[0])
            case "missing": try FileManager.default.removeItem(at: source)
            case "symlink":
                let outside = temporary.appendingPathComponent("outside-export.mov")
                try Data("outside".utf8).write(to: outside)
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            default: moves[0]["destination"] = "Unexpected/clip.mov"
            }
            journal["moves"] = moves
            try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent("journal.json"))
            XCTAssertThrowsError(try BackgroundFootagePlan.loadExport(at: root), "Must reject \(mode)")
        }
    }

    private func exportFixture(version: Int) throws -> (URL, [String: Any]) {
        let root = temporary.appendingPathComponent("export-\(UUID().uuidString)")
        let folders = (1...14).map { "Custom News \($0)" }
        var moves: [[String: Any]] = []
        for (index, folder) in folders.enumerated() {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = String(format: "%08d.mov", index)
            try Data("export-source-\(index)".utf8).write(to: directory.appendingPathComponent(name))
            moves.append(["source_name": "CNN-\(index).mpg.ProResLT.mov", "destination": "\(folder)/\(name)", "duration_ms": 20_000])
        }
        moves.append(["source_name": "extra.mov", "destination": "Unused/extra.mov", "duration_ms": 1_000])
        let journal: [String: Any] = ["version": version, "seed": 42, "folder_names": folders, "moves": moves]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent("journal.json"))
        return (root, journal)
    }

    private func footageFixture() throws -> (BackgroundFootagePlan, [URL: Int]) {
        let template = media.appendingPathComponent("Chabot News Backgrounds")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try psdFixture().write(to: template.appendingPathComponent("Text Crawl.psd"))
        let converted = media.appendingPathComponent("ProRes LT")
        try FileManager.default.createDirectory(at: converted, withIntermediateDirectories: true)
        var counts: [URL: Int] = [:]
        let assignments = try BackgroundProjectPlanner.layout.keys.sorted().filter { $0 != 1 }.map { comp in
            let sources = [converted.appendingPathComponent("comp-\(comp)-first.mov"), converted.appendingPathComponent("comp-\(comp)-tail.mov")]
            for (index, source) in sources.enumerated() {
                try Data("source-\(comp)-\(index)".utf8).write(to: source)
                counts[source] = index == 0 ? 12_000 : (comp == 2 ? 8_000 : 8_003)
            }
            return BackgroundFootageAssignment(comp: comp, sources: sources)
        }
        return (BackgroundFootagePlan(assignments: assignments), counts)
    }

    private func replacingFirstSources(_ plan: BackgroundFootagePlan, _ sources: [URL]) -> BackgroundFootagePlan {
        var assignments = plan.assignments
        assignments[0] = BackgroundFootageAssignment(comp: assignments[0].comp, sources: sources)
        return BackgroundFootagePlan(assignments: assignments)
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text)!
    }

    private func writeProject(_ xml: String) throws -> URL {
        let url = temporary.appendingPathComponent("fixture.prproj")
        try Data(xml.utf8).write(to: url)
        return url
    }

    private func fixture() -> String {
        let t = PremiereProject.frameTicks
        func clip(_ id: String, _ file: String, _ start: Int64, _ count: Int64, _ sourceIn: Int64) -> String {
            """
            <VideoClipTrackItem ObjectID="item-\(id)"><ClipTrackItem><ComponentOwner><Components ObjectRef="effects-\(id)"/></ComponentOwner><TrackItem><Start>\(start * t)</Start><End>\((start + count) * t)</End></TrackItem><SubClip ObjectRef="subclip-\(id)"/></ClipTrackItem></VideoClipTrackItem>
            <SubClip ObjectID="subclip-\(id)"><Name>\(file)</Name><Clip ObjectRef="clip-\(id)"/></SubClip>
            <VideoClip ObjectID="clip-\(id)"><Clip><Source ObjectRef="source-\(id)"/><InPoint>\(sourceIn * t)</InPoint><OutPoint>\((sourceIn + count) * t)</OutPoint></Clip></VideoClip>
            <VideoMediaSource ObjectID="source-\(id)"><MediaSource><Media ObjectURef="media-\(id)"/></MediaSource></VideoMediaSource>
            <Media ObjectUID="media-\(id)"><FilePath>/old/CNN Downloads/\(file)</FilePath><VideoStream ObjectRef="stream-\(id)"/></Media>
            <VideoStream ObjectID="stream-\(id)"><FrameRate>\(t)</FrameRate></VideoStream>
            <VideoComponentChain ObjectID="effects-\(id)"><DefaultMotion>true</DefaultMotion><DefaultOpacity>true</DefaultOpacity><ComponentChain/></VideoComponentChain>
            """
        }
        return """
        <PremiereData>
        <Sequence ObjectUID="sequence"><Name>Comp 2</Name><TrackGroups><TrackGroup><First>228cda18-3625-4d2d-951e-348879e4ed93</First><Second ObjectRef="group"/></TrackGroup></TrackGroups></Sequence>
        <VideoTrackGroup ObjectID="group"><TrackGroup><FrameRate>\(t)</FrameRate><Tracks><Track ObjectURef="background"/><Track ObjectURef="video"/></Tracks></TrackGroup><ComponentOwner><Components ObjectRef="group-effects"/></ComponentOwner></VideoTrackGroup>
        <VideoComponentChain ObjectID="group-effects"><ComponentChain/></VideoComponentChain>
        <VideoClipTrack ObjectUID="background"><ClipTrack><Track><Index>0</Index></Track><ClipItems><TrackItems><TrackItem ObjectRef="item-bg"/></TrackItems></ClipItems></ClipTrack></VideoClipTrack>
        <VideoClipTrack ObjectUID="video"><ClipTrack><Track><Index>1</Index><IsMuted>false</IsMuted></Track><ClipItems><TrackItems><TrackItem ObjectRef="item-second"/><TrackItem ObjectRef="item-first"/></TrackItems></ClipItems><TransitionItems/></ClipTrack></VideoClipTrack>
        \(clip("bg", "guide.jpg", 0, 4, 0))
        \(clip("second", "a-second.mpg", 2, 2, 3))
        \(clip("first", "z-first.mpg", 0, 2, 1))
        </PremiereData>
        """
    }

    private func psdFixture(rle: Bool = false) -> Data {
        func uint(_ value: UInt64, _ count: Int) -> Data {
            Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func section(_ value: Data) -> Data { uint(UInt64(value.count), 4) + value }
        func text(_ string: String) -> Data { Data([0xfe, 0xff]) + string.data(using: .utf16BigEndian)! }
        func plane(_ width: Int, _ height: Int, _ value: UInt8) -> Data {
            if !rle { return uint(0, 2) + Data(repeating: value, count: width * height) }
            var row = Data(), remaining = width
            while remaining > 0 {
                let n = min(remaining, 128)
                row += Data([UInt8(truncatingIfNeeded: 1 - n), value]); remaining -= n
            }
            return uint(1, 2) + (0..<height).reduce(Data()) { result, _ in result + uint(UInt64(row.count), 2) }
                + (0..<height).reduce(Data()) { result, _ in result + row }
        }
        var type = uint(1, 2)
        for double in [1.0, 0, 0, 1, 100, 25] { type += uint(double.bitPattern, 8) }
        type += Data("/Text (".utf8) + text("November 12, 2026") + Data(") /FontSize 18 /Tracking 0 /FontCaps 2 /Font 0 /FillColor << /Type 1 /Values [1 1 1 1] >> /FontSet /Name (".utf8)
        type += text("Arial-BoldMT") + Data(")".utf8)
        var records = Data(), pixels = Data()
        for (name, width, height, left, top, value) in [("Show Date", 200, 20, 100, 5, UInt8(255)), ("Label", 100, 20, 500, 5, UInt8(255)), ("Background", 2376, 32, 0, 0, UInt8(0))] {
            let channels = [plane(width, height, value), plane(width, height, value), plane(width, height, value)]
            records += uint(UInt64(top), 4) + uint(UInt64(left), 4) + uint(UInt64(top + height), 4) + uint(UInt64(left + width), 4) + uint(3, 2)
            for id in 0..<3 { records += uint(UInt64(id), 2) + uint(UInt64(channels[id].count), 4) }
            records += Data("8BIMnorm".utf8) + Data([255, 0, 0, 0])
            var nameData = Data([UInt8(name.utf8.count)]) + Data(name.utf8)
            while nameData.count % 4 != 0 { nameData.append(0) }
            var extra = uint(0, 4) + uint(0, 4) + nameData
            if name != "Background" {
                extra += Data("8BIMTySh".utf8) + section(type)
                if type.count % 2 != 0 { extra.append(0) }
            }
            records += section(extra)
            pixels += channels.reduce(Data(), +)
        }
        var info = uint(3, 2) + records + pixels
        if info.count % 2 != 0 { info.append(0) }
        let mask = section(info) + uint(0, 4)
        var result = Data("8BPS".utf8)
        for field in [uint(1, 2), Data(repeating: 0, count: 6), uint(3, 2), uint(32, 4), uint(2376, 4),
                      uint(8, 2), uint(3, 2), uint(0, 4), uint(0, 4), section(mask), uint(0, 2)] { result += field }
        result += Data(repeating: 0, count: 2376 * 32 * 3)
        return result
    }
}
