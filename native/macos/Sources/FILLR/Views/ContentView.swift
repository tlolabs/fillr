import SwiftUI

struct ContentView: View {
    @ObservedObject var store: FillrStore

    private var snapshot: EngineSnapshot? { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FILLR").font(.title2.bold())
                    Text(store.folder?.path ?? "Choose the folder where CNN MPG files arrive")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Choose Folder…") { store.chooseFolder() }.disabled(store.isBuilding)
            }

            statusCard

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Remaining to \(clockText(store.sortSettings.total_ms))").foregroundStyle(.secondary)
                    Text(clockText(snapshot?.remaining_ms ?? store.sortSettings.total_ms))
                        .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Unique footage").foregroundStyle(.secondary)
                    Text(clockText(snapshot?.available_ms ?? 0)).font(.title2.monospacedDigit())
                    Text("\(snapshot?.clips.count ?? 0) usable clips · \(snapshot?.pending.count ?? 0) pending")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(min(snapshot?.available_ms ?? 0, store.sortSettings.total_ms)), total: Double(store.sortSettings.total_ms))

            HStack {
                Button(store.isBuilding ? "Building…" : "Build Folders") { store.build() }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot?.status != "ready" || store.isBuilding)
                Button("Refresh") { store.refresh() }.disabled(store.folder == nil || store.isBuilding)
                Button(store.overlayVisible ? "Hide Overlay" : "Show Overlay") { store.toggleOverlay() }
                Spacer()
                if store.lastOutput != nil { Button("Open Last Export") { store.openLastOutput() } }
            }

            GroupBox("Folder preview") {
                if let assignments = snapshot?.plan?.assignments {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                            ForEach(assignments) { comp in
                                VStack(alignment: .leading) {
                                    Text("\(store.sortSettings.folder_prefix) \(comp.comp)").fontWeight(.semibold)
                                    Text(clockText(comp.duration_ms)).monospacedDigit()
                                    Text("\(comp.filenames.count) clips").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                        }
                    }
                } else {
                    Text("A verified \(store.sortSettings.folder_count)-folder layout will appear here when enough footage is ready.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }

            if let snapshot, !snapshot.excluded.isEmpty || !snapshot.duplicate_log.isEmpty || !snapshot.rejection_log.isEmpty {
                DisclosureGroup("File notes (\(snapshot.excluded.count) excluded, \(snapshot.rejection_log.count) rejected deleted, \(snapshot.duplicate_log.count) duplicates deleted)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(snapshot.excluded) { item in Text("\(item.filename): \(item.reason)") }
                            ForEach(snapshot.duplicate_log, id: \.self) { Text($0) }
                            ForEach(snapshot.rejection_log, id: \.self) { Text($0) }
                        }
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
            }
        }
        .padding(20)
        .alert("FILLR", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    private var statusCard: some View {
        let ready = snapshot?.status == "ready"
        return HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "video.badge.waveform")
                .font(.title2).foregroundStyle(ready ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(ready ? "Ready — you can stop downloading" : (snapshot?.message ?? "Choose a download folder"))
                    .font(.headline)
                Text(ready ? "Click Build to move selected videos into \(store.sortSettings.folder_count) folders." : "Only stable, unique MPG clips count toward the total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
