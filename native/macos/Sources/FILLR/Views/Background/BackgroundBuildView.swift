import BackgroundProfiling
import SwiftUI

struct BackgroundBuildButton: View {
    @ObservedObject var controller: BackgroundController
    let downloadFolder: URL?
    let compact: Bool
    let folderBuildRunning: Bool

    var body: some View {
        Button {
            controller.useDownloadFolderIfNeeded(downloadFolder)
            controller.presentsBuilder = true
        } label: {
            if compact {
                Label("Build Background…", systemImage: "film.stack").labelStyle(.iconOnly)
            } else {
                Text(controller.isRendering ? "Background…" : "Build Background…")
            }
        }
        .help("Build the Chabot background using the shortest balanced footage folder")
        .disabled(folderBuildRunning)
        .sheet(isPresented: $controller.presentsBuilder) {
            BackgroundBuildView(controller: controller, profiler: controller.profiler)
        }
    }
}

struct BackgroundBuildView: View {
    @ObservedObject var controller: BackgroundController
    @ObservedObject var profiler: BackgroundProfiler
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build Chabot Background").font(.title2).fontWeight(.semibold)
            Text("TriCaster set · 1920 × 1080 · 29.97 fps · \(controller.useAllFootage ? "shortest folder duration" : "10 minutes") · silent H.264")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Sources") {
                VStack(spacing: 14) {
                    BackgroundPathRow(title: "Media folder", url: controller.mediaRoot, action: controller.chooseMediaRoot)
                    if let plan = controller.footagePlan {
                        Text("Using \(plan.assignments.count) balanced footage folders from the current collection.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if controller.collectionSelected {
                        Text("Waiting for a verified 14-folder footage layout. The background uses the current collection once it is ready.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    BackgroundPathRow(title: "Premiere project (optional with collected footage)", url: controller.project, action: controller.chooseProject)
                    if !controller.collectionSelected {
                        Button("Use current collected footage") { controller.useCurrentCollection() }
                            .font(.caption)
                    }
                    BackgroundPathRow(title: "Comp 1 intro video", url: controller.intro, action: controller.chooseIntro)
                    DatePicker("Show date", selection: $controller.showDate, displayedComponents: .date)
                }.padding(10).disabled(controller.isBusy)
            }
            Picker("Performance profile", selection: $profiler.selectedProfile) {
                ForEach(BackgroundPerformanceProfile.allCases) { profile in Text(profile.title).tag(profile) }
            }.disabled(controller.isBusy)
            Text(profiler.recommendationSummary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hardware scanning, benchmarks, and manual overrides are in Settings → Background.")
                .font(.caption).foregroundStyle(.secondary)
            if controller.isRendering {
                ProgressView(value: controller.progress)
            }
            Text(controller.status).font(.callout).textSelection(.enabled)
            if let error = controller.error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    .frame(maxHeight: 100)
            }
            HStack {
                if controller.lastOutput != nil {
                    Button("Show Background") { controller.revealOutput() }
                }
                Spacer()
                if controller.isBusy {
                    Button("Cancel Job") { controller.cancel() }
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Build Background…") { controller.chooseOutputAndBuild() }
                        .buttonStyle(.borderedProminent).disabled(!controller.canBuild)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 600)
        .interactiveDismissDisabled(controller.isBusy)
        .onAppear { if profiler.hardware == nil { profiler.refreshHardware() } }
    }
}
