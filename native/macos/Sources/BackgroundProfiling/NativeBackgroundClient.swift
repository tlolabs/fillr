import CBackgroundEngine
import Darwin
import Foundation

public final class BackgroundCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() {
        lock.withLock {
            cancelled = true
            if let context { fillr_background_cancel(context) }
        }
    }
    func attach(_ value: OpaquePointer) {
        lock.withLock {
            context = value
            if cancelled { fillr_background_cancel(value) }
        }
    }
    func detach() { lock.withLock { context = nil } }
    func check() throws { if isCancelled { throw BackgroundProfilingError.cancelled } }
}

public struct NativeBackgroundReport: Codable, Sendable {
    public let jsonData: Data
    public let status: String
    public let error: String?
    public let completedFrames: Int
    public let elapsedSeconds: Double
    public let verificationSeconds: Double
    public let hardwareEncoder: Bool?
    public let hardwareDecodeSummary: String

    public init(jsonData: Data) throws {
        guard let value = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw BackgroundProfilingError.native("The native renderer returned an invalid report.")
        }
        self.jsonData = jsonData
        status = value["status"] as? String ?? "unknown"
        error = value["error"] as? String
        completedFrames = (value["completed_frames"] as? NSNumber)?.intValue ?? 0
        elapsedSeconds = (value["elapsed_seconds"] as? NSNumber)?.doubleValue ?? 0
        verificationSeconds = (value["verification_seconds"] as? NSNumber)?.doubleValue ?? 0
        hardwareEncoder = (value["encoder"] as? [String: Any])?["hardware"] as? Bool
        let sources = value["sources"] as? [[String: Any]] ?? []
        let cpuFrames = sources.reduce(0) { $0 + (($1["cpu_decoded_nv12_packed_frames"] as? NSNumber)?.intValue ?? 0) }
        let segments = sources.flatMap { $0["segments"] as? [[String: Any]] ?? [] }
        let queried = segments.compactMap { $0["reported_hardware_decoder"] as? Bool }
        if cpuFrames > 0 {
            hardwareDecodeSummary = "Includes CPU-decoded source frames; hardware decoding is codec dependent."
        } else if !segments.isEmpty && queried.count == segments.count && queried.allSatisfy({ $0 }) {
            hardwareDecodeSummary = "Hardware decoding confirmed by every active source decoder."
        } else {
            hardwareDecodeSummary = "Source decoder hardware attribution is incomplete; capability is not runtime confirmation."
        }
    }

    public var success: Bool {
        status == "complete" && error == nil && completedFrames > 0 && elapsedSeconds.isFinite && elapsedSeconds > 0
    }
    public var framesPerSecond: Double { success ? Double(completedFrames) / elapsedSeconds : 0 }
}

private final class NativeProgressBox {
    let progress: @Sendable (Int, Int) -> Void
    init(_ progress: @escaping @Sendable (Int, Int) -> Void) { self.progress = progress }
}

/// Calls the bundled native library directly. Render and probe operations are
/// blocking and must be scheduled away from the main actor by their caller.
public enum NativeBackgroundClient {
    public static func probe(_ url: URL) throws -> [String: Any] {
        let data = try url.path.withCString { try takeJSON(fillr_background_probe($0)) }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackgroundProfilingError.native("Invalid native media metadata.")
        }
        if let error = value["error"] as? String { throw BackgroundProfilingError.native(error) }
        return value
    }

    public static func makeTestJob(directory: URL, frames: Int) throws -> Data {
        guard (1...1_800).contains(frames) else { throw BackgroundProfilingError.invalidJob("Built-in test footage requires 1–1800 frames.") }
        // mkdir is exclusive even when NSFileManager would accept an existing
        // directory. Keep failed artifacts for diagnosis rather than replacing.
        guard directory.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: directory.path])
        }
        let data = try directory.path.withCString { try takeJSON(fillr_background_test_job($0, Int32(frames))) }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackgroundProfilingError.native("Invalid built-in benchmark job.")
        }
        if let error = value["error"] as? String { throw BackgroundProfilingError.native(error) }
        guard value["panels"] is [[String: Any]] else {
            throw BackgroundProfilingError.native("Built-in benchmark footage could not be prepared.")
        }
        return data
    }

    public static func render(job: Data, output: URL, settings: BackgroundAccelerationSettings,
                              cancellation: BackgroundCancellation = BackgroundCancellation(),
                              benchmark: Bool = false,
                              progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> NativeBackgroundReport {
        try cancellation.check()
        let options = try settings.nativeJSON(benchmark: benchmark)
        guard let jobString = String(data: job, encoding: .utf8),
              let optionsString = String(data: options, encoding: .utf8),
              let context = fillr_background_create() else {
            throw BackgroundProfilingError.native("Could not initialize the native background renderer.")
        }
        cancellation.attach(context)
        defer { cancellation.detach(); fillr_background_destroy(context) }
        let box = Unmanaged.passRetained(NativeProgressBox(progress))
        defer { box.release() }
        let data = try jobString.withCString { jobPointer in
            try output.path.withCString { outputPointer in
                try optionsString.withCString { optionsPointer in
                    try takeJSON(fillr_background_render(context, jobPointer, outputPointer, optionsPointer, {
                        user, frames, total in
                        guard let user else { return }
                        Unmanaged<NativeProgressBox>.fromOpaque(user).takeUnretainedValue().progress(Int(frames), Int(total))
                    }, box.toOpaque()))
                }
            }
        }
        try cancellation.check()
        return try NativeBackgroundReport(jsonData: data)
    }

    private static func takeJSON(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw BackgroundProfilingError.native("The native renderer returned no result.") }
        defer { fillr_background_free_string(pointer) }
        return Data(String(cString: pointer).utf8)
    }
}
