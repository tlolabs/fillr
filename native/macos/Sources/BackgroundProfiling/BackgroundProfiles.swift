import Foundation

public struct BackgroundAccelerationSettings: Codable, Hashable, Sendable {
    public var hardwareDecode: Bool
    public var hardwareEncode: Bool
    public var decoderThreads: Int
    public var sourceQueueFrames: Int
    public var encoderInflightFrames: Int

    public init(hardwareDecode: Bool = true, hardwareEncode: Bool = true,
                decoderThreads: Int = 1, sourceQueueFrames: Int = 2,
                encoderInflightFrames: Int = 8) {
        self.hardwareDecode = hardwareDecode
        self.hardwareEncode = hardwareEncode
        self.decoderThreads = decoderThreads
        self.sourceQueueFrames = sourceQueueFrames
        self.encoderInflightFrames = encoderInflightFrames
    }

    enum CodingKeys: String, CodingKey {
        case hardwareDecode = "hardware_decode", hardwareEncode = "hardware_encode"
        case decoderThreads = "decoder_threads", sourceQueueFrames = "source_queue_frames"
        case encoderInflightFrames = "encoder_inflight_frames"
    }

    public func validate() throws {
        guard (1...16).contains(decoderThreads), (1...4).contains(sourceQueueFrames),
              (1...8).contains(encoderInflightFrames) else {
            throw BackgroundProfilingError.invalidSettings
        }
    }

    public func nativeJSON(benchmark: Bool = false) throws -> Data {
        try validate()
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        value["benchmark"] = benchmark
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    // A comparison of bounded decoder/queue resources, not an energy measurement.
    var resourceCost: Int { decoderThreads * 15 + sourceQueueFrames * 15 + encoderInflightFrames }
}

public enum BackgroundPerformanceProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case fastest, balanced, responsive
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fastest: return "Fastest build"
        case .balanced: return "Balanced"
        case .responsive: return "Keep Mac responsive"
        }
    }
}

public enum BackgroundBenchmarkMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case quick, thorough
    public var id: String { rawValue }
    public var title: String { self == .quick ? "Quick" : "Thorough" }
    public var framesPerSample: Int { self == .quick ? 60 : 300 }
    public var repetitions: Int { self == .quick ? 1 : 3 }
    public var explanation: String {
        self == .quick ? "Compares short samples of three configurations."
            : "Compares more configurations at the beginning, middle, and end of the footage."
    }
}

public struct BackgroundSettingsOverrides: Codable, Equatable, Sendable {
    public var hardwareDecode: Bool?
    public var hardwareEncode: Bool?
    public var decoderThreads: Int?
    public var sourceQueueFrames: Int?
    public var encoderInflightFrames: Int?
    public init(hardwareDecode: Bool? = nil, hardwareEncode: Bool? = nil,
                decoderThreads: Int? = nil, sourceQueueFrames: Int? = nil,
                encoderInflightFrames: Int? = nil) {
        self.hardwareDecode = hardwareDecode; self.hardwareEncode = hardwareEncode
        self.decoderThreads = decoderThreads; self.sourceQueueFrames = sourceQueueFrames
        self.encoderInflightFrames = encoderInflightFrames
    }
    public var isEmpty: Bool { self == Self() }
    public func applying(to base: BackgroundAccelerationSettings) throws -> BackgroundAccelerationSettings {
        let settings = BackgroundAccelerationSettings(
            hardwareDecode: hardwareDecode ?? base.hardwareDecode,
            hardwareEncode: hardwareEncode ?? base.hardwareEncode,
            decoderThreads: decoderThreads ?? base.decoderThreads,
            sourceQueueFrames: sourceQueueFrames ?? base.sourceQueueFrames,
            encoderInflightFrames: encoderInflightFrames ?? base.encoderInflightFrames)
        try settings.validate()
        return settings
    }
}

public enum BackgroundProfilingError: LocalizedError {
    case invalidSettings, invalidJob(String), native(String), cancelled, noSuccessfulMeasurements
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: return "Decoder threads must be 1–16, source queues 1–4, and encoder frames 1–8."
        case .invalidJob(let message): return "Background benchmark job: \(message)"
        case .native(let message): return message
        case .cancelled: return "Background operation cancelled."
        case .noSuccessfulMeasurements: return "No configuration completed a verified benchmark. Failed attempts are retained in the report."
        }
    }
}
