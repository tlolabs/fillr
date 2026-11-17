import Combine
import Foundation

@MainActor
public final class BackgroundProfiler: ObservableObject {
    @Published public private(set) var hardware: BackgroundHardwareScan?
    @Published public private(set) var benchmark: BackgroundBenchmarkReport?
    @Published public private(set) var isBusy = false
    @Published public private(set) var status = "Ready to scan hardware."
    @Published public private(set) var error: String?
    @Published public private(set) var workloadChanged = false
    @Published public var selectedProfile: BackgroundPerformanceProfile = .fastest { didSet { save() } }
    @Published public var overrides = BackgroundSettingsOverrides() {
        didSet {
            if (try? overrides.applying(to: baseSettings)) == nil {
                overrides = oldValue
                error = BackgroundProfilingError.invalidSettings.localizedDescription
            } else { save() }
        }
    }
    private let defaults: UserDefaults
    private let hardwareProvider: () -> BackgroundHardwareScan
    private var cancellation: BackgroundCancellation?
    private static let preferenceKey = "backgroundHardwareProfile.v1"
    private struct SavedState: Codable {
        let version: Int
        let selectedProfile: BackgroundPerformanceProfile
        let overrides: BackgroundSettingsOverrides
        let benchmark: BackgroundBenchmarkReport?
        let workloadChanged: Bool?
    }

    public init(defaults: UserDefaults = .standard,
                hardwareProvider: @escaping () -> BackgroundHardwareScan = { BackgroundHardwareScanner.scan() }) {
        self.defaults = defaults; self.hardwareProvider = hardwareProvider
        if let data = defaults.data(forKey: Self.preferenceKey),
           let state = try? JSONDecoder().decode(SavedState.self, from: data), state.version == 1,
           (try? state.overrides.applying(to: BackgroundAccelerationSettings())) != nil {
            selectedProfile = state.selectedProfile; overrides = state.overrides; benchmark = state.benchmark
            workloadChanged = state.workloadChanged ?? false
        }
        refreshHardware()
    }

    public var benchmarkIsStale: Bool {
        guard let benchmark, let hardware else { return false }
        return workloadChanged || benchmark.isStale(for: hardware)
    }
    private var baseSettings: BackgroundAccelerationSettings {
        if !benchmarkIsStale, let measured = benchmark?.recommendation(for: selectedProfile) { return measured.settings }
        return hardware?.proposedSettings(for: selectedProfile) ?? BackgroundAccelerationSettings()
    }
    public var effectiveSettings: BackgroundAccelerationSettings {
        (try? overrides.applying(to: baseSettings)) ?? baseSettings
    }
    public var hardwareSummary: String {
        guard let hardware else { return "Hardware has not been scanned." }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(hardware.memoryBytes), countStyle: .memory)
        let metal = hardware.metalDevices.isEmpty ? "Metal unavailable" : hardware.metalDevices.joined(separator: ", ")
        return "\(hardware.processor) · \(hardware.logicalCPUs) logical CPUs · \(memory) memory\n\(metal)\nHardware H.264 encoding: \(hardware.hardwareH264Encode ? "available" : "not advertised"). Scan results describe capabilities; benchmarks confirm the active encoder."
    }
    public var recommendationSummary: String {
        let source: String
        if benchmarkIsStale {
            source = "Previous measurements are stale after a hardware, app, OS, or footage change. Using hardware scan defaults until you benchmark again."
        } else if let measured = benchmark?.recommendation(for: selectedProfile) {
            source = "Measured \(String(format: "%.1f", measured.medianFramesPerSecond)) frames/sec in \(measured.samples) sample\(measured.samples == 1 ? "" : "s")."
        } else {
            source = "Hardware scan recommendation; performance has not been measured successfully."
        }
        let profile: String
        switch selectedProfile {
        case .fastest: profile = "Uses the fastest verified configuration when measurements are available."
        case .balanced: profile = "Prefers smaller decoder queues within 10% of the measured fastest configuration."
        case .responsive: profile = "Limits decoder threads and queued frames; responsiveness and energy use are not directly measured."
        }
        return [source, profile, overrides.isEmpty ? nil : "Manual overrides take precedence over this profile."].compactMap { $0 }.joined(separator: " ")
    }
    public var benchmarkSummary: String {
        guard let benchmark else { return "No benchmark results yet." }
        let failures = benchmark.trials.filter { !$0.eligible }.count
        let completion = benchmark.cancelled ? "Cancelled; partial results are not applied."
            : benchmark.isComplete ? "\(benchmark.successfulConfigurations.count) verified configurations."
            : "Incomplete; results are not applied."
        return "\(benchmark.mode.title) · \(benchmark.source.title). \(completion) \(failures) failed or unconfirmed samples. Sample timing excludes preparation and output verification; it is not a full ten-minute build measurement."
    }

    public func refreshHardware() {
        guard !isBusy else { return }
        hardware = hardwareProvider()
        status = hardware?.canRender == true ? "Hardware scan complete." : "Metal is unavailable. Background rendering needs a Metal-capable Mac."
    }
    public func markWorkloadChanged() { workloadChanged = true; save() }
    public func resetOverrides() { overrides = BackgroundSettingsOverrides() }
    public func clearError() { error = nil }
    public func cancel() {
        guard isBusy else { return }
        status = "Cancelling benchmark…"
        cancellation?.cancel()
    }

    public func runBenchmark(job: Data? = nil, sourceDirectory: URL? = nil,
                             mode: BackgroundBenchmarkMode, workDirectory: URL) async {
        guard !isBusy else { return }
        refreshHardware()
        guard let scan = hardware, scan.canRender else {
            error = "A Metal-capable GPU is required to benchmark the native background compositor."
            return
        }
        let token = BackgroundCancellation()
        cancellation = token; isBusy = true; error = nil; status = "Preparing \(mode.title.lowercased()) benchmark…"
        defer { isBusy = false; cancellation = nil }
        let update: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.isBusy, self.cancellation === token else { return }
                self.status = message
            }
        }
        do {
            let report = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try BackgroundBenchmarkRunner.run(job: job, sourceDirectory: sourceDirectory, mode: mode,
                        workDirectory: workDirectory, hardware: scan, cancellation: token, progress: update)
                }.value
            } onCancel: { token.cancel() }
            benchmark = report; workloadChanged = false; save()
            if report.cancelled { status = "Benchmark cancelled. Partial results were retained." }
            else if report.successfulConfigurations.isEmpty {
                status = "Benchmark finished without a verified configuration."
                error = BackgroundProfilingError.noSuccessfulMeasurements.localizedDescription
            } else { status = "\(mode.title) benchmark complete. The selected profile is ready for background builds." }
        } catch {
            self.error = error.localizedDescription
            status = token.isCancelled ? "Benchmark cancelled." : "Benchmark could not complete."
        }
    }

    private func save() {
        let state = SavedState(version: 1, selectedProfile: selectedProfile, overrides: overrides,
            benchmark: benchmark, workloadChanged: workloadChanged)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.preferenceKey) }
    }
}
