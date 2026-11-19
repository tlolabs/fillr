import CBackgroundEngine
import Combine
import Darwin
import Foundation

struct DownloadFingerprint: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    func sameContentIdentity(as other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size
            && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }

    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else { throw downloadPOSIXError(url) }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw DownloadTranscodeError.message("Only regular, non-symlinked downloads can be converted.")
        }
        return Self(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                    modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
}

enum DownloadTranscodeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

private func downloadPOSIXError(_ url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
}

final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true; if let context { fillr_background_cancel(context) } } }
    func attach(_ value: OpaquePointer) { lock.withLock { context = value; if cancelled { fillr_background_cancel(value) } } }
    func detach() { lock.withLock { context = nil } }
    func whileActive<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard !cancelled else { throw DownloadTranscodeError.message("Conversion cancelled.") }
            return try operation()
        }
    }
}

/// A single serial worker owns observations and native jobs. MPEG originals
/// reach Trash only after a verified copy has been published and rechecked.
final class DownloadTranscodeWorker: @unchecked Sendable {
    typealias Transcode = @Sendable (URL, URL, DownloadCancellation) throws -> String
    struct Observation { let fingerprint: DownloadFingerprint; let since: TimeInterval }
    struct Receipt: Codable { let source: DownloadFingerprint; let output: DownloadFingerprint; let outputName: String; let sourceCodec: String; var trashedSource: String? }
    private struct Completion {
        let source: DownloadFingerprint
        let output: DownloadFingerprint
    }
    // CNN downloads are MPEG files. Intro MOVs and existing project assets in
    // the selected folder must never enter the news-footage collection.
    static let extensions: Set<String> = ["mpg", "mpeg", "m2v"]
    static let temporaryMarkers = ["#work_file#", "#chkpt_file#", ".crdownload", ".download", ".partial", ".part", ".tmp"]
    let root: URL
    let output: URL
    let cancellation = DownloadCancellation()
    let settleSeconds: TimeInterval
    let now: @Sendable () -> TimeInterval
    let closed: @Sendable (URL) throws -> Bool
    let transcode: Transcode
    let trash: @Sendable (URL) throws -> String
    private var observed: [String: Observation] = [:]
    private var completed: [String: Completion] = [:]
    private var retryAfter: [String: TimeInterval] = [:]
    private var failures: [String: String] = [:]

    init(root: URL, settleSeconds: TimeInterval = 30,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         closed: @escaping @Sendable (URL) throws -> Bool = { try DownloadTranscodeWorker.isClosed($0) },
         transcode: @escaping Transcode = { try DownloadTranscodeWorker.nativeTranscode($0, $1, $2) },
         trash: @escaping @Sendable (URL) throws -> String = { try DownloadTranscodeWorker.trashSource($0) }) {
        self.root = root.standardizedFileURL
        output = DownloadTranscodeController.collectionFolder(for: root).standardizedFileURL
        self.settleSeconds = settleSeconds
        self.now = now
        self.closed = closed
        self.transcode = transcode
        self.trash = trash
    }

    static func hasCompanion(_ source: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).contains { name in
            name != source.lastPathComponent && name.localizedCaseInsensitiveContains(source.lastPathComponent)
                && temporaryMarkers.contains(where: { name.lowercased().contains($0) })
        }
    }

    static func isClosed(_ source: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-Fpf", "--", source.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        // Merge diagnostics so one draining reader cannot deadlock on the
        // other pipe. A diagnostic fails closed just like an open handle.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return false }
        guard process.terminationStatus == 1, outputData.isEmpty else {
            throw DownloadTranscodeError.message("Cannot confirm that \(source.lastPathComponent) is closed; conversion deferred.")
        }
        return true
    }

    static func nativeTranscode(_ source: URL, _ target: URL, _ cancellation: DownloadCancellation) throws -> String {
        guard let context = fillr_background_create() else {
            throw DownloadTranscodeError.message("Cannot initialize the built-in ProRes LT encoder.")
        }
        cancellation.attach(context)
        defer { cancellation.detach(); fillr_background_destroy(context) }
        let pointer = source.path.withCString { input in
            target.path.withCString { output in fillr_download_transcode(context, input, output) }
        }
        guard let pointer else { throw DownloadTranscodeError.message("The built-in encoder returned no result.") }
        defer { fillr_background_free_string(pointer) }
        let data = Data(String(cString: pointer).utf8)
        guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["status"] as? String == "complete", report["error"] == nil else {
            let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw DownloadTranscodeError.message(report?["error"] as? String ?? "Built-in ProRes LT conversion failed.")
        }
        return report["source_codec"] as? String ?? "unknown"
    }

    static func trashSource(_ source: URL) throws -> String {
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        return destination?.path ?? "Moved to Trash"
    }

    private func discardVerifiedMPEG(_ source: URL, target: URL, receipt: URL, saved: Receipt) throws {
        guard saved.sourceCodec == "mpeg2video", ["mpg", "mpeg", "m2v"].contains(source.pathExtension.lowercased()) else { return }
        guard try DownloadFingerprint.read(target) == saved.output else {
            throw DownloadTranscodeError.message("Converted output changed; MPG original retained.")
        }
        guard try sourceIsReady(source, expected: saved.source) else {
            throw DownloadTranscodeError.message("MPG source changed or reopened; original retained.")
        }
        // lsof and other completion checks may take time: recheck the verified
        // output immediately before authorizing deletion.
        guard try DownloadFingerprint.read(target) == saved.output else {
            throw DownloadTranscodeError.message("Converted output changed; MPG original retained.")
        }
        try cancellation.whileActive {
            // lsof is deliberately outside this short lock. Repeat identity and
            // companion checks after that slow call, immediately before Trash.
            guard try DownloadFingerprint.read(target) == saved.output,
                  try DownloadFingerprint.read(source) == saved.source,
                  try !Self.hasCompanion(source) else {
                throw DownloadTranscodeError.message("Source or converted output changed; MPG original retained.")
            }
            // Trash remains recoverable. This call never overwrites another file.
            var updated = saved
            updated.trashedSource = try trash(source)
            try JSONEncoder().encode(updated).write(to: receipt, options: .atomic)
        }
    }

    private func directoryIsSafe(_ url: URL) throws {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else { throw downloadPOSIXError(url) }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw DownloadTranscodeError.message("The download and ProRes LT folders must be real directories, not symlinks.")
        }
    }

    func prepare() throws {
        try directoryIsSafe(root)
        // Never follow an existing symlink while creating the collection folder.
        var value = stat()
        if output.path.withCString({ lstat($0, &value) }) != 0 {
            guard errno == ENOENT else { throw downloadPOSIXError(output) }
            guard output.path.withCString({ mkdir($0, 0o755) }) == 0 || errno == EEXIST else { throw downloadPOSIXError(output) }
        }
        try directoryIsSafe(output)
    }

    private func sourceIsReady(_ url: URL, expected: DownloadFingerprint) throws -> Bool {
        guard try DownloadFingerprint.read(url) == expected, try !Self.hasCompanion(url), try closed(url) else { return false }
        // A downloader may change the file or create a companion while lsof is
        // running. Its result never validates an earlier fingerprint.
        return try DownloadFingerprint.read(url) == expected && !Self.hasCompanion(url)
    }

    private static func isMissing(_ url: URL) -> Bool {
        var value = stat()
        return url.path.withCString({ lstat($0, &value) }) != 0 && errno == ENOENT
    }

    /// A receipt-backed conversion that was removed or moved is a collection
    /// edit, not a request to recreate the output from an unchanged original.
    /// Progress observers can use this read-only check to ignore that original.
    static func hasRetiredOutput(for source: URL, outputRoot: URL) -> Bool {
        let name = source.lastPathComponent
        let targetName = name + ".ProResLT.mov"
        let receipt = outputRoot.appendingPathComponent("." + name + ".ProResLT.receipt.json")
        guard let saved = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt)),
              saved.outputName == targetName,
              (try? DownloadFingerprint.read(source)) == saved.source else { return false }
        return Self.isMissing(outputRoot.appendingPathComponent(targetName))
    }

    static func retiredSourceNames(root: URL, sources: [ClipInfo]) -> Set<String> {
        let outputRoot = DownloadTranscodeController.collectionFolder(for: root)
        return Set(sources.compactMap { clip in
            let name = clip.filename
            guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"),
                  Self.extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()),
                  Self.hasRetiredOutput(for: root.appendingPathComponent(name), outputRoot: outputRoot) else { return nil }
            return name
        })
    }

    private func forget(_ name: String) {
        observed.removeValue(forKey: name)
        completed.removeValue(forKey: name)
        failures.removeValue(forKey: name)
        retryAfter.removeValue(forKey: name)
    }

    private func retainState(for names: Set<String>) {
        observed = observed.filter { names.contains($0.key) }
        completed = completed.filter { names.contains($0.key) }
        failures = failures.filter { names.contains($0.key) }
        retryAfter = retryAfter.filter { names.contains($0.key) }
    }

    /// The main-actor handshake reserves activity only when an actual native
    /// encode or receipt-backed Trash operation is ready to begin. Idle scans
    /// never claim busy, and a folder build can invalidate a pending handshake.
    func scan(beginActive: @Sendable () -> Bool = { true },
              endActive: @Sendable () -> Void = {},
              event: @Sendable (String, Bool) -> Void) throws {
        guard !cancellation.isCancelled else { return }
        try prepare()
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let candidates = entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).compactMap { source -> (URL, DownloadFingerprint)? in
            let name = source.lastPathComponent
            guard !name.hasPrefix("."), Self.extensions.contains(source.pathExtension.lowercased()),
                  !Self.temporaryMarkers.contains(where: { name.lowercased().contains($0) }),
                  let stamp = try? DownloadFingerprint.read(source), stamp.size > 0 else { return nil }
            return (source, stamp)
        }
        let presentNames = Set(candidates.map { $0.0.lastPathComponent })
        retainState(for: presentNames)
        var waiting = 0
        for (source, stamp) in candidates {
            if cancellation.isCancelled { return }
            let name = source.lastPathComponent
            let target = output.appendingPathComponent(name + ".ProResLT.mov")
            let receipt = output.appendingPathComponent("." + name + ".ProResLT.receipt.json")
            var publishedOutputExpected = false
            do {
                if let done = completed[name], done.source == stamp {
                    if (try? DownloadFingerprint.read(target)) == done.output { continue }
                    // Published outputs that were deliberately removed or moved
                    // into a folder build must not be recreated automatically.
                    if Self.isMissing(target) {
                        failures.removeValue(forKey: name)
                        retryAfter.removeValue(forKey: name)
                        continue
                    }
                    completed.removeValue(forKey: name)
                }
                let savedReceipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt))
                if let saved = savedReceipt, saved.source == stamp,
                   saved.outputName == target.lastPathComponent, Self.isMissing(target) {
                    // Detect removal before retry delays or slow open-file
                    // checks so an old Trash failure stops being reported.
                    completed[name] = Completion(source: stamp, output: saved.output)
                    failures.removeValue(forKey: name)
                    retryAfter.removeValue(forKey: name)
                    continue
                }
                let time = now()
                let changed = observed[name]?.fingerprint != stamp
                // New or changed downloads must settle regardless of companion files.
                if try changed || Self.hasCompanion(source) {
                    if changed {
                        failures.removeValue(forKey: name)
                        retryAfter.removeValue(forKey: name)
                    }
                    observed[name] = Observation(fingerprint: stamp, since: time)
                    waiting += 1
                    continue
                }
                guard let observation = observed[name], time - observation.since >= settleSeconds else { waiting += 1; continue }
                guard time >= retryAfter[name, default: 0] else { waiting += 1; continue }
                guard try sourceIsReady(source, expected: stamp) else { waiting += 1; continue }
                if let saved = savedReceipt, saved.source == stamp {
                    // Never use a receipt alone as permission to delete: the
                    // converted output must still match its verified identity.
                    if (try? DownloadFingerprint.read(target)) == saved.output {
                        publishedOutputExpected = true
                        if saved.sourceCodec == "mpeg2video" {
                            guard beginActive() else { return }
                            defer { endActive() }
                            try discardVerifiedMPEG(source, target: target, receipt: receipt, saved: saved)
                        }
                        completed[name] = Completion(source: stamp, output: saved.output)
                        failures.removeValue(forKey: name)
                        retryAfter.removeValue(forKey: name)
                        continue
                    }
                    if Self.isMissing(target) {
                        completed[name] = Completion(source: stamp, output: saved.output)
                        failures.removeValue(forKey: name)
                        retryAfter.removeValue(forKey: name)
                        continue
                    }
                }
                var targetStat = stat()
                guard target.path.withCString({ lstat($0, &targetStat) }) != 0, errno == ENOENT else {
                    throw DownloadTranscodeError.message("Existing output left untouched: \(target.lastPathComponent)")
                }
                let work = output.appendingPathComponent(".fillr-transcode-" + UUID().uuidString, isDirectory: true)
                guard work.path.withCString({ mkdir($0, 0o700) }) == 0 else { throw downloadPOSIXError(work) }
                defer { try? FileManager.default.removeItem(at: work) }
                let provisional = work.appendingPathComponent("verified.mov")
                guard beginActive() else { return }
                defer { endActive() }
                event("Converting \(name) to ProRes LT…", true)
                let sourceCodec = try transcode(source, provisional, cancellation)
                guard try sourceIsReady(source, expected: stamp) else {
                    observed.removeValue(forKey: name)
                    throw DownloadTranscodeError.message("\(name) changed or reopened; provisional conversion discarded.")
                }
                try directoryIsSafe(root)
                try directoryIsSafe(output)
                let verifiedIdentity = try DownloadFingerprint.read(provisional)
                try cancellation.whileActive {
                    guard provisional.path.withCString({ from in target.path.withCString { link(from, $0) } }) == 0 else {
                        throw downloadPOSIXError(target)
                    }
                    publishedOutputExpected = true
                    // Unlinking the provisional hard link changes ctime. Record
                    // the final fingerprint only after that known operation.
                    try FileManager.default.removeItem(at: provisional)
                    let publishedIdentity = try DownloadFingerprint.read(target)
                    guard verifiedIdentity.sameContentIdentity(as: publishedIdentity) else {
                        throw DownloadTranscodeError.message("Published output changed; MPG original retained.")
                    }
                    let saved = Receipt(source: stamp, output: publishedIdentity, outputName: target.lastPathComponent, sourceCodec: sourceCodec)
                    do {
                        try JSONEncoder().encode(saved).write(to: receipt, options: .atomic)
                    } catch {
                        // Keep a fully verified conversion even if the receipt
                        // cannot be written. A later run reports its conflict.
                        completed[name] = Completion(source: stamp, output: publishedIdentity)
                        throw error
                    }
                }
                let saved = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt))
                try discardVerifiedMPEG(source, target: target, receipt: receipt, saved: saved)
                completed[name] = Completion(source: stamp, output: saved.output)
                failures.removeValue(forKey: name)
                retryAfter.removeValue(forKey: name)
                event("ProRes LT ready: \(target.lastPathComponent). Verified MPG originals moved to Trash.", false)
            } catch {
                if cancellation.isCancelled { return }
                if Self.isMissing(source) {
                    // Deleting an extra download is a normal collection edit.
                    // The provisional file is removed by its scoped cleanup.
                    forget(name)
                    continue
                }
                if publishedOutputExpected && Self.isMissing(target) {
                    // Never trash the original after its verified copy was
                    // removed. A receipt-backed completion stays retired;
                    // an unpublished attempt may be retried on a later scan.
                    completed.removeValue(forKey: name)
                    failures.removeValue(forKey: name)
                    retryAfter.removeValue(forKey: name)
                    continue
                }
                retryAfter[name] = now() + 60
                failures[name] = error.localizedDescription
                event(error.localizedDescription, false)
            }
        }
        // Another candidate's encode can take long enough for earlier files to
        // be removed. Do not keep their diagnostic or completion cache alive.
        retainState(for: Set(presentNames.filter { !Self.isMissing(root.appendingPathComponent($0)) }))
        if let name = failures.keys.sorted().first, let failure = failures[name] { event(failure, false) }
        else if waiting > 0 { event("Waiting for \(waiting) download\(waiting == 1 ? "" : "s") to settle before ProRes LT conversion…", false) }
        else { event("Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash.", false) }
    }
}


/// Download speeds are observations of file growth, independent of conversion
/// eligibility. The first file size is a baseline, never downloaded bytes.
struct DownloadSpeedObservation: Sendable {
    let filename: String
    let fingerprint: DownloadFingerprint
    let temporary: Bool
    let hasCompanion: Bool
}

struct DownloadSpeedTracker {
    private struct Transfer {
        var fingerprint: DownloadFingerprint
        var initialSize: Int64
        var size: Int64
        var started: TimeInterval
        var observed: TimeInterval
        var lastGrowth: TimeInterval
        var lastChange: TimeInterval
        var temporary: Bool
        var ended: TimeInterval?

        init(_ sample: DownloadSpeedObservation, now: TimeInterval) {
            fingerprint = sample.fingerprint
            initialSize = sample.fingerprint.size
            size = sample.fingerprint.size
            started = now
            observed = now
            lastGrowth = now
            lastChange = now
            temporary = sample.temporary
        }

        var active: Bool { ended == nil && (temporary || size > initialSize) }
        func progress(name: String, now: TimeInterval) -> DownloadInfo? {
            let bytes = size - initialSize
            let elapsed = (ended ?? now) - started
            guard bytes > 0, elapsed >= (ended == nil ? 1 : 0.1), elapsed.isFinite else { return nil }
            return DownloadInfo(filename: name, size_bytes: UInt64(max(0, size)), observed_bytes: UInt64(bytes),
                elapsed_ms: UInt64(min(elapsed * 1000, Double(UInt64.max - 2048))),
                average_bytes_per_second: Double(bytes) / elapsed, completed: ended != nil)
        }
    }
    private var transfers: [String: Transfer] = [:]
    private var lastCompleted: (TimeInterval, DownloadInfo)?

    mutating func sample(_ samples: [DownloadSpeedObservation], now: TimeInterval,
                         settleSeconds: TimeInterval = 30) -> [DownloadInfo] {
        let names = Set(samples.map(\.filename))
        transfers = transfers.filter { names.contains($0.key) }
        for sample in samples {
            var transfer = transfers[sample.filename] ?? Transfer(sample, now: now)
            if transfer.fingerprint.device != sample.fingerprint.device || transfer.fingerprint.inode != sample.fingerprint.inode
                || sample.fingerprint.size < transfer.size {
                transfer = Transfer(sample, now: now)
            }
            if sample.fingerprint != transfer.fingerprint { transfer.lastChange = now }
            if sample.fingerprint.size > transfer.size {
                if transfer.ended != nil {
                    // A resumed final file starts from the last observed size
                    // and time, excluding the prior completed transfer's idle gap.
                    transfer.initialSize = transfer.size
                    transfer.started = transfer.observed
                    transfer.ended = nil
                }
                transfer.size = sample.fingerprint.size
                transfer.lastGrowth = now
            }
            transfer.fingerprint = sample.fingerprint
            transfer.temporary = sample.temporary
            if sample.temporary || sample.hasCompanion { transfer.ended = nil }
            else if transfer.ended == nil && now - transfer.lastChange >= settleSeconds {
                // Settling is a completion observation, not network-transfer
                // time. Keep pauses during growth, exclude the final wait.
                transfer.ended = transfer.lastGrowth
            }
            transfer.observed = now
            if let ended = transfer.ended, let progress = transfer.progress(name: sample.filename, now: now),
               lastCompleted == nil || ended >= lastCompleted!.0 {
                lastCompleted = (ended, progress)
            }
            transfers[sample.filename] = transfer
        }
        if transfers.values.contains(where: \.active) {
            return transfers.keys.sorted().compactMap { name in
                guard let transfer = transfers[name], transfer.active else { return nil }
                return transfer.progress(name: name, now: now)
            }
        }
        return lastCompleted.map { [$0.1] } ?? []
    }
}

/// This read-only observer has its own queue so an hours-long native encode
/// cannot stop the one-second size samples of other arriving downloads.
final class DownloadSpeedObserver: @unchecked Sendable {
    let root: URL
    private var tracker = DownloadSpeedTracker()
    init(root: URL) { self.root = root }

    static func name(_ filename: String) -> (String, Bool)? {
        guard !filename.hasPrefix("."), !filename.lowercased().hasPrefix("#chkpt_file#") else { return nil }
        var name = filename
        var temporary = false
        if name.lowercased().hasPrefix("#work_file#") {
            name = String(name.dropFirst("#work_file#".count))
            temporary = true
        }
        for suffix in [".crdownload", ".download", ".partial", ".part", ".tmp"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            temporary = true
            break
        }
        guard !name.hasPrefix("."), !name.hasPrefix("#"),
              DownloadTranscodeWorker.extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { return nil }
        return (name, temporary)
    }

    func sample(now: TimeInterval) throws -> [DownloadInfo] {
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw DownloadTranscodeError.message("Cannot observe source download speeds.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var entries: [String: (URL, DownloadFingerprint, Bool)] = [:]
        var companions = Set<String>()
        for file in files {
            let raw = file.lastPathComponent
            if raw.lowercased().hasPrefix("#chkpt_file#") {
                let base = String(raw.dropFirst("#chkpt_file#".count))
                companions.insert(base)
            }
            guard let (name, temporary) = Self.name(raw), let fingerprint = try? DownloadFingerprint.read(file) else { continue }
            if temporary { companions.insert(name) }
            // When a final placeholder and Signiant work file coexist, report
            // work-file growth rather than the placeholder's preallocation.
            if entries[name] == nil || temporary { entries[name] = (file, fingerprint, temporary) }
        }
        let samples = entries.keys.sorted().compactMap { name -> DownloadSpeedObservation? in
            guard let (_, fingerprint, temporary) = entries[name] else { return nil }
            return DownloadSpeedObservation(filename: name, fingerprint: fingerprint, temporary: temporary,
                                            hasCompanion: companions.contains(name))
        }
        return tracker.sample(samples, now: now)
    }
}

@MainActor
final class DownloadTranscodeController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var downloadSpeeds: [DownloadInfo] = []
    @Published private(set) var status = "Choose a download folder for automatic ProRes LT conversion."
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.tlolabs.fillr.download-transcode", qos: .utility)
    private var worker: DownloadTranscodeWorker?
    private let speedQueue = DispatchQueue(label: "com.tlolabs.fillr.download-speed", qos: .utility)
    private var speedObserver: DownloadSpeedObserver?
    private var speedScanning = false
    private var timer: Timer?
    private var epoch = UUID()
    private var scanning = false
    private var folder: URL?
    private var paused = false
    private var busyEpoch: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "downloads.transcodeEnabled") == nil || defaults.bool(forKey: "downloads.transcodeEnabled")
    }

    nonisolated static func collectionFolder(for source: URL) -> URL { source.appendingPathComponent("ProRes LT", isDirectory: true) }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: "downloads.transcodeEnabled")
        start(folder: folder)
    }

    func start(folder: URL?) {
        let changedFolder = self.folder?.standardizedFileURL != folder?.standardizedFileURL
        cancel()
        if changedFolder || !enabled || folder == nil { speedObserver = nil; downloadSpeeds = [] }
        self.folder = folder
        guard enabled, let folder else {
            status = enabled ? "Choose a download folder for automatic ProRes LT conversion." : "Automatic ProRes LT conversion is off."
            return
        }
        worker = DownloadTranscodeWorker(root: folder)
        if speedObserver == nil { speedObserver = DownloadSpeedObserver(root: folder) }
        status = "Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash."
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollSpeeds(); self?.poll() }
        }
        pollSpeeds()
        poll()
    }

    func setPaused(_ value: Bool) {
        paused = value
        if !value { poll() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        worker?.cancellation.cancel()
        worker = nil
        epoch = UUID()
        scanning = false
        speedScanning = false
    }

    private func pollSpeeds() {
        guard !speedScanning, let observer = speedObserver else { return }
        speedScanning = true
        let currentEpoch = epoch
        speedQueue.async { [weak self] in
            let result = try? observer.sample(now: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == currentEpoch else { return }
                self.speedScanning = false
                self.downloadSpeeds = result ?? []
            }
        }
    }

    private func poll() {
        guard !scanning, !paused, let worker else { return }
        scanning = true
        let currentEpoch = epoch
        queue.async { [weak self] in
            do {
                try worker.scan(beginActive: { [weak self] in
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            guard let self, self.epoch == currentEpoch, !self.paused,
                                  !worker.cancellation.isCancelled else { return false }
                            self.busyEpoch = currentEpoch
                            self.isBusy = true
                            return true
                        }
                    }
                }, endActive: { [weak self] in
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            guard let self, self.busyEpoch == currentEpoch else { return }
                            self.isBusy = false
                            self.busyEpoch = nil
                        }
                    }
                }) { [weak self] message, _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.epoch == currentEpoch else { return }
                        self.status = message
                        // Activity state is controlled by the synchronous
                        // begin/end handshake, never by delayed status events.
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.epoch == currentEpoch else { return }
                    self.status = message
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.epoch == currentEpoch { self.scanning = false }
                if self.busyEpoch == currentEpoch { self.isBusy = false; self.busyEpoch = nil }
            }
        }
    }
}
