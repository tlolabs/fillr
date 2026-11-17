import BackgroundProfiling
import SwiftUI

struct BackgroundPreferencesView: View {
    @ObservedObject var controller: BackgroundController
    let downloadFolder: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Background footage") {
                    VStack(alignment: .leading, spacing: 10) {
                        BackgroundPathRow(title: "Media folder", url: controller.mediaRoot,
                                          action: controller.chooseMediaRoot)
                        Text("Benchmarks use your footage when available. Built-in test footage is used only when no footage is found.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(8)
                }
                BackgroundProfileControls(controller: controller, profiler: controller.profiler)
                if let error = controller.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }.padding(12)
        }
        .onAppear { controller.useDownloadFolderIfNeeded(downloadFolder) }
    }
}

struct BackgroundProfileControls: View {
    @ObservedObject var controller: BackgroundController
    @ObservedObject var profiler: BackgroundProfiler
    @State private var benchmarkMode = BackgroundBenchmarkMode.quick

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Mac hardware") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(profiler.hardwareSummary)
                        .font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Scan Hardware") { profiler.refreshHardware() }
                        .disabled(controller.isBusy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("Performance profile") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Use for background builds", selection: $profiler.selectedProfile) {
                        ForEach(BackgroundPerformanceProfile.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }.disabled(controller.isBusy)
                    Text(profiler.recommendationSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    settingsSummary
                    Text("Profile selections and overrides are saved immediately and used by Build Background. Output quality and format stay fixed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    overrides
                }.padding(8)
            }
            GroupBox("Measure this Mac") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Benchmark", selection: $benchmarkMode) {
                        ForEach(BackgroundBenchmarkMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented).disabled(controller.isBusy)
                    Text(benchmarkMode.explanation).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Run \(benchmarkMode.title) Benchmark") { controller.runBenchmark(benchmarkMode) }
                            .disabled(controller.isBusy)
                        if controller.isBusy {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { controller.cancel() }
                        }
                        Spacer()
                        if controller.lastBenchmarkDirectory != nil {
                            Button("Show Report") { controller.revealBenchmark() }
                        }
                    }
                    if controller.isPreparing { Text(controller.status).font(.caption) }
                    if profiler.isBusy { Text(profiler.status).font(.caption) }
                    Text(profiler.benchmarkSummary).font(.caption)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if profiler.benchmarkIsStale {
                        Text("These measurements are out of date. Run a new benchmark before relying on the measured recommendation.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let error = profiler.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding(8)
            }
        }
        .onAppear { if profiler.hardware == nil { profiler.refreshHardware() } }
    }

    private var settingsSummary: some View {
        let settings = profiler.effectiveSettings
        return VStack(alignment: .leading, spacing: 4) {
            Text("Metal composition · \(settings.hardwareDecode ? "hardware decoding where supported" : "CPU decoding")")
            Text("\(settings.hardwareEncode ? "Hardware" : "Software") H.264 · \(settings.decoderThreads) decoder thread(s) per panel")
            Text("\(settings.sourceQueueFrames) queued source frames per panel · \(settings.encoderInflightFrames) encoder frames")
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var overrides: some View {
        DisclosureGroup("Manual overrides") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Decode", selection: overrideBinding(\.hardwareDecode)) {
                    Text("Use profile").tag(Optional<Bool>.none)
                    Text("Hardware where supported").tag(Optional(true))
                    Text("CPU").tag(Optional(false))
                }
                Picker("H.264 encoder", selection: overrideBinding(\.hardwareEncode)) {
                    Text("Use profile").tag(Optional<Bool>.none)
                    Text("Require hardware").tag(Optional(true))
                    Text("Require software").tag(Optional(false))
                }
                integerOverride("Decoder threads per panel", keyPath: \.decoderThreads, values: [1, 2, 4, 8, 16])
                integerOverride("Queued source frames per panel", keyPath: \.sourceQueueFrames, values: [1, 2, 3, 4])
                integerOverride("Encoder frames", keyPath: \.encoderInflightFrames, values: Array(1...8))
                Button("Reset Overrides") { profiler.overrides = BackgroundSettingsOverrides() }
                    .disabled(profiler.overrides.isEmpty)
            }.padding(.top, 8).disabled(controller.isBusy)
        }
    }

    private func integerOverride(_ title: String,
        keyPath: WritableKeyPath<BackgroundSettingsOverrides, Int?>, values: [Int]) -> some View {
        Picker(title, selection: overrideBinding(keyPath)) {
            Text("Use profile").tag(Optional<Int>.none)
            ForEach(values, id: \.self) { value in Text(String(value)).tag(Optional(value)) }
        }
    }

    private func overrideBinding<T>(_ keyPath: WritableKeyPath<BackgroundSettingsOverrides, T>) -> Binding<T> {
        Binding(get: { profiler.overrides[keyPath: keyPath] }, set: { value in
            var overrides = profiler.overrides
            overrides[keyPath: keyPath] = value
            profiler.overrides = overrides
        })
    }
}

struct BackgroundPathRow: View {
    let title: String
    let url: URL?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(url?.path ?? "Not selected").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…", action: action).accessibilityLabel("Choose \(title)")
        }
    }
}
