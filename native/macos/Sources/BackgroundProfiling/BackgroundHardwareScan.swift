import CryptoKit
import Foundation
import Metal
import VideoToolbox

public struct BackgroundHardwareScan: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let model: String
    public let processor: String
    public let logicalCPUs: Int
    public let memoryBytes: UInt64
    public let architecture: String
    public let translated: Bool
    public let operatingSystem: String
    public let applicationVersion: String
    public let metalDevices: [String]
    public let unifiedMemory: Bool
    public let hardwareH264Encode: Bool
    public let hardwareDecodeCodecs: [String]
    public let lowPowerMode: Bool
    public let thermalState: String

    public init(capturedAt: Date = Date(), model: String, processor: String, logicalCPUs: Int,
                memoryBytes: UInt64, architecture: String, translated: Bool = false,
                operatingSystem: String, applicationVersion: String, metalDevices: [String],
                unifiedMemory: Bool, hardwareH264Encode: Bool, hardwareDecodeCodecs: [String],
                lowPowerMode: Bool = false, thermalState: String = "normal") {
        self.capturedAt = capturedAt; self.model = model; self.processor = processor
        self.logicalCPUs = logicalCPUs; self.memoryBytes = memoryBytes
        self.architecture = architecture; self.translated = translated
        self.operatingSystem = operatingSystem; self.applicationVersion = applicationVersion
        self.metalDevices = metalDevices; self.unifiedMemory = unifiedMemory
        self.hardwareH264Encode = hardwareH264Encode; self.hardwareDecodeCodecs = hardwareDecodeCodecs
        self.lowPowerMode = lowPowerMode; self.thermalState = thermalState
    }

    public var canRender: Bool { !metalDevices.isEmpty }
    public var fingerprint: String {
        // Deliberately excludes serial numbers and transient load/power state.
        let stable = [model, processor, String(logicalCPUs), String(memoryBytes), architecture,
                      operatingSystem, applicationVersion, metalDevices.joined(separator: ","),
                      String(hardwareH264Encode), hardwareDecodeCodecs.sorted().joined(separator: ","),
                      "native-background-profile-v1"].joined(separator: "\n")
        return SHA256.hash(data: Data(stable.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func proposedSettings(for profile: BackgroundPerformanceProfile) -> BackgroundAccelerationSettings {
        switch profile {
        case .fastest:
            return BackgroundAccelerationSettings(hardwareDecode: !hardwareDecodeCodecs.isEmpty,
                hardwareEncode: hardwareH264Encode, decoderThreads: 1,
                sourceQueueFrames: memoryBytes < 8 * 1024 * 1024 * 1024 ? 1 : 2,
                encoderInflightFrames: 8)
        case .balanced:
            return BackgroundAccelerationSettings(hardwareDecode: !hardwareDecodeCodecs.isEmpty,
                hardwareEncode: hardwareH264Encode, sourceQueueFrames: 1, encoderInflightFrames: 4)
        case .responsive:
            return BackgroundAccelerationSettings(hardwareDecode: !hardwareDecodeCodecs.isEmpty,
                hardwareEncode: hardwareH264Encode, sourceQueueFrames: 1, encoderInflightFrames: 2)
        }
    }
}

public enum BackgroundHardwareScanner {
    public static func scan(bundle: Bundle = .main) -> BackgroundHardwareScan {
        let process = ProcessInfo.processInfo
        let devices = MTLCopyAllDevices()
        var encoders: CFArray?
        let status = VTCopyVideoEncoderList(nil, &encoders)
        let list = status == noErr ? encoders as? [[String: Any]] ?? [] : []
        let hardwareEncoder = list.contains { encoder in
            (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_H264
                && (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool == true)
        }
        let codecs: [(String, CMVideoCodecType)] = [
            ("H.264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC),
            ("MPEG-2", kCMVideoCodecType_MPEG2Video),
            ("ProRes 422", kCMVideoCodecType_AppleProRes422),
            ("ProRes LT", kCMVideoCodecType_AppleProRes422LT),
            ("ProRes Proxy", kCMVideoCodecType_AppleProRes422Proxy)
        ]
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "normal"
        case .fair: thermal = "warm"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        return BackgroundHardwareScan(model: sysctlString("hw.model") ?? "Unknown Mac",
            processor: sysctlString("machdep.cpu.brand_string") ?? architecture,
            logicalCPUs: process.processorCount, memoryBytes: process.physicalMemory,
            architecture: architecture, translated: sysctlInt("sysctl.proc_translated") == 1,
            operatingSystem: process.operatingSystemVersionString,
            applicationVersion: "\(version) (\(build))", metalDevices: devices.map(\.name),
            unifiedMemory: devices.contains(where: \.hasUnifiedMemory), hardwareH264Encode: hardwareEncoder,
            hardwareDecodeCodecs: codecs.filter { VTIsHardwareDecodeSupported($0.1) }.map(\.0),
            lowPowerMode: process.isLowPowerModeEnabled, thermalState: thermal)
    }

    private static func sysctlString(_ key: String) -> String? {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &bytes, &length, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
    private static func sysctlInt(_ key: String) -> Int32? {
        var value: Int32 = 0, length = MemoryLayout<Int32>.size
        return sysctlbyname(key, &value, &length, nil, 0) == 0 ? value : nil
    }
}
