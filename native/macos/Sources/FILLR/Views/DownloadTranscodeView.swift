import SwiftUI

struct DownloadTranscodeStatusView: View {
    @ObservedObject var controller: DownloadTranscodeController

    var body: some View {
        if controller.enabled {
            Label(controller.status, systemImage: controller.isBusy ? "gearshape.2" : "film.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(controller.status)
                .accessibilityLabel("ProRes LT: \(controller.status)")
        }
    }
}

struct DownloadTranscodePreferencesView: View {
    @ObservedObject var store: FillrStore
    @ObservedObject var controller: DownloadTranscodeController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Convert MPEG downloads to ProRes LT", isOn: Binding(
                get: { controller.enabled }, set: { store.setDownloadTranscoding($0) }))
                .disabled(store.isBuilding || store.isBackgroundBusy)
            Text("Applies immediately. Completed MPG, MPEG, and M2V downloads are compared and verified before originals move to Trash. FILLR collects the copies in ProRes LT. Intro MOV files stay outside the collection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
