import AppKit
import BackgroundPlanning
import BackgroundProfiling
import Combine
import Foundation
import UniformTypeIdentifiers

/// Owns the GUI background job independently of folder allocation.
@MainActor
final class BackgroundController: ObservableObject {
    let profiler: BackgroundProfiler
    @Published private(set) var mediaRoot: URL?
    @Published private(set) var project: URL?
    @Published private(set) var intro: URL?
    @Published var showDate = Date()
    @Published private(set) var isRendering = false
    @Published private(set) var isPreparing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Choose the Chabot media folder and intro video."
    @Published private(set) var lastOutput: URL?
    @Published private(set) var lastBenchmarkDirectory: URL?
    @Published var presentsBuilder = false
    @Published var error: String?
    @Published private(set) var isBusy = false
    private let defaults: UserDefaults
    private let workRoot: URL?
    private var observation: AnyCancellable?
    private var cancellation: BackgroundCancellation?
    private var preparation: Task<Data, Error>?
    private var activeRenderID: UUID?
    private var benchmarkPreparationCancellation: BackgroundCancellation?

    var canBuild: Bool { mediaRoot != nil && project != nil && intro != nil && !isBusy }

    init(defaults: UserDefaults = .standard, workRoot: URL? = nil) {
        self.defaults = defaults
        self.workRoot = workRoot
        profiler = BackgroundProfiler(defaults: defaults)
        mediaRoot = defaults.string(forKey: "background.mediaRoot").map { URL(fileURLWithPath: $0) }
        project = defaults.string(forKey: "background.project").map { URL(fileURLWithPath: $0) }
        intro = defaults.string(forKey: "background.intro").map { URL(fileURLWithPath: $0) }
        observation = Publishers.CombineLatest3($isRendering, $isPreparing, profiler.$isBusy)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .sink { [weak self] busy in self?.isBusy = busy }
    }

    func useDownloadFolderIfNeeded(_ url: URL?) {
        guard mediaRoot == nil, let url else { return }
        setMediaRoot(url)
    }

    func chooseMediaRoot() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Chabot media folder"
        panel.message = "Choose the CNN Downloads folder containing the Chabot background project and footage."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = mediaRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setMediaRoot(url)
    }

    private func setMediaRoot(_ url: URL) {
        if mediaRoot?.standardizedFileURL != url.standardizedFileURL { profiler.markWorkloadChanged() }
        mediaRoot = url
        defaults.set(url.path, forKey: "background.mediaRoot")
        let candidate = url.appendingPathComponent("Chabot News Backgrounds/CC 2027/Footage.prproj")
        if FileManager.default.fileExists(atPath: candidate.path) {
            project = candidate
            defaults.set(candidate.path, forKey: "background.project")
        } else {
            project = nil
            defaults.removeObject(forKey: "background.project")
        }
    }

    func chooseProject() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Chabot Footage Premiere project"
        panel.allowedContentTypes = [UTType(filenameExtension: "prproj") ?? .data]
        panel.directoryURL = mediaRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if project?.standardizedFileURL != url.standardizedFileURL { profiler.markWorkloadChanged() }
        project = url
        defaults.set(url.path, forKey: "background.project")
    }

    func chooseIntro() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Comp 1 intro video"
        panel.allowedContentTypes = [.movie, .mpeg, .mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = mediaRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if intro?.standardizedFileURL != url.standardizedFileURL { profiler.markWorkloadChanged() }
        intro = url
        defaults.set(url.path, forKey: "background.intro")
    }

    func runBenchmark(_ mode: BackgroundBenchmarkMode) {
        guard !isBusy else { return }
        isPreparing = true
        error = nil
        status = "Preparing benchmark footage…"
        let inputs = captureInputs()
        let token = BackgroundCancellation()
        benchmarkPreparationCancellation = token
        Task {
            defer { preparation = nil; benchmarkPreparationCancellation = nil; isPreparing = false }
            do {
                guard !token.isCancelled else { throw CancellationError() }
                let directory = try Self.makeWorkDirectory(category: "Benchmarks", root: workRoot)
                var job: Data?
                if let inputs, [inputs.project, inputs.mediaRoot, inputs.intro].allSatisfy({
                    FileManager.default.fileExists(atPath: $0.path)
                }) {
                    let task = Task.detached(priority: .userInitiated) {
                        try Self.prepare(inputs, directory: directory.appendingPathComponent("artwork"))
                    }
                    preparation = task
                    job = try await task.value
                }
                guard !token.isCancelled else { throw CancellationError() }
                preparation = nil
                lastBenchmarkDirectory = directory
                status = "Benchmark running…"
                await profiler.runBenchmark(job: job, sourceDirectory: mediaRoot, mode: mode, workDirectory: directory)
                status = profiler.status
            } catch {
                self.error = token.isCancelled ? nil : error.localizedDescription
                status = token.isCancelled ? "Benchmark cancelled." : "Benchmark preparation stopped."
            }
        }
    }

    func chooseOutputAndBuild() {
        guard canBuild else { return }
        let panel = NSSavePanel()
        panel.title = "Build Chabot Background"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Chabot News Background \(Self.dateString(showDate)).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let output = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            error = "Choose a new filename. Existing background movies are preserved."
            return
        }
        build(to: output)
    }

    func build(to output: URL) {
        guard canBuild, let inputs = captureInputs() else { return }
        isRendering = true
        progress = 0
        error = nil
        status = "Preparing the Chabot background…"
        let token = BackgroundCancellation()
        let renderID = UUID()
        activeRenderID = renderID
        cancellation = token
        let settings = profiler.effectiveSettings
        Task {
            defer { activeRenderID = nil; isRendering = false; cancellation = nil; preparation = nil }
            do {
                let directory = try Self.makeWorkDirectory(category: "Renders", root: workRoot)
                let task = Task.detached(priority: .userInitiated) {
                    try Self.prepare(inputs, directory: directory.appendingPathComponent("artwork"))
                }
                preparation = task
                let job = try await task.value
                guard !token.isCancelled else { throw CancellationError() }
                try job.write(to: directory.appendingPathComponent("job.json"), options: .atomic)
                status = "Rendering 10-minute Chabot background…"
                let progressHandler: @Sendable (Int, Int) -> Void = { [self] completed, total in
                    Task { @MainActor [self] in
                        guard self.activeRenderID == renderID else { return }
                        self.progress = total > 0 ? Double(completed) / Double(total) : 0
                        self.status = completed >= total
                            ? "Verifying the complete background…"
                            : "Rendering frame \(completed.formatted()) of \(total.formatted())…"
                    }
                }
                let report = try await Task.detached(priority: .userInitiated) {
                    try NativeBackgroundClient.render(job: job, output: output, settings: settings,
                        cancellation: token, progress: progressHandler)
                }.value
                try report.jsonData.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
                guard report.success else {
                    throw BackgroundProfilingError.native(report.error ?? "The background did not pass complete output verification.")
                }
                lastOutput = output
                progress = 1
                status = "Background complete and verified."
            } catch {
                self.error = error is CancellationError ? nil : error.localizedDescription
                status = token.isCancelled ? "Background build cancelled." : "Background build failed."
            }
        }
    }

    func cancel() {
        benchmarkPreparationCancellation?.cancel()
        preparation?.cancel()
        cancellation?.cancel()
        profiler.cancel()
    }

    func revealOutput() {
        if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) }
    }

    func revealBenchmark() {
        if let lastBenchmarkDirectory { NSWorkspace.shared.open(lastBenchmarkDirectory) }
    }

    private struct Inputs: Sendable {
        let project: URL
        let mediaRoot: URL
        let intro: URL
        let date: Date
    }

    private func captureInputs() -> Inputs? {
        guard let project, let mediaRoot, let intro else { return nil }
        return Inputs(project: project, mediaRoot: mediaRoot, intro: intro, date: showDate)
    }

    nonisolated private static func prepare(_ inputs: Inputs, directory: URL) throws -> Data {
        try Task.checkCancellation()
        let data = try BackgroundProjectPlanner.prepare(project: inputs.project, mediaRoot: inputs.mediaRoot,
            intro: inputs.intro, showDate: inputs.date, workDirectory: directory, frames: 17_982,
            probe: { try NativeBackgroundClient.probe($0) })
        try Task.checkCancellation()
        return data
    }

    nonisolated private static func makeWorkDirectory(category: String, root: URL?) throws -> URL {
        let root = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("FILLR/Background/\(category)/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
