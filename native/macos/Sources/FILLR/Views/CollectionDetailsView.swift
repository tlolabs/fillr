import SwiftUI

struct CollectionDetailsView: View {
    @ObservedObject var store: FillrStore
    let mini: Bool
    @SceneStorage("fillr.details.expanded") private var detailsExpanded = false
    @SceneStorage("fillr.folders.expanded") private var foldersExpanded = false
    @SceneStorage("fillr.downloads.expanded") private var downloadsExpanded = false
    @SceneStorage("fillr.notes.expanded") private var notesExpanded = false

    private var snapshot: EngineSnapshot? { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if mini {
                    DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                        detailRows.padding(.top, 6)
                    }
                } else {
                    detailRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 2)
        }
        .font(.system(size: 12))
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $downloadsExpanded) {
                DownloadSpeedView(downloads: snapshot?.downloads ?? []).padding(.top, 4)
            } label: {
                HStack {
                    Text("Downloads")
                    Spacer(minLength: 4)
                    Text(downloadSummary).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            DisclosureGroup(isExpanded: $foldersExpanded) {
                folderPreview.padding(.top, 4)
            } label: {
                HStack {
                    Text("Folder preview")
                    Spacer(minLength: 4)
                    Text(snapshot?.plan == nil ? "Available when ready" : "\(store.sortSettings.folder_count) folders verified")
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot, !snapshot.excluded.isEmpty || !snapshot.duplicate_log.isEmpty || !snapshot.rejection_log.isEmpty {
                DisclosureGroup(isExpanded: $notesExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snapshot.excluded) { item in Text("\(item.filename): \(item.reason)") }
                        ForEach(Array(snapshot.duplicate_log.enumerated()), id: \.offset) { _, message in Text(message) }
                        ForEach(Array(snapshot.rejection_log.enumerated()), id: \.offset) { _, message in Text(message) }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("File notes")
                        Text("\(snapshot.excluded.count) excluded · \(snapshot.rejection_log.count) rejected deleted · \(snapshot.duplicate_log.count) duplicates deleted")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var downloadSummary: String {
        let downloads = snapshot?.downloads ?? []
        guard let first = downloads.first else { return "Waiting for file growth" }
        if downloads.count > 1 { return "\(downloads.count) files · estimates" }
        let label = first.completed ? "Last average" : "Average"
        return "\(label) \(downloadSpeedText(first.average_bytes_per_second)) (est.)"
    }

    @ViewBuilder private var folderPreview: some View {
        if let assignments = snapshot?.plan?.assignments {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(assignments) { comp in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(store.sortSettings.folder_prefix) \(comp.comp)").fontWeight(.medium)
                        Text("\(clockText(comp.duration_ms)) · \(comp.filenames.count) clips")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text("A verified \(store.sortSettings.folder_count)-folder layout will appear when enough footage is ready.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
