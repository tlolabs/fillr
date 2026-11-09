import SwiftUI

struct ContentView: View {
    @ObservedObject var store: FillrStore
    let layout: WindowLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FolderSelectionRow(store: store, compact: layout == .miniMonitor)

            switch layout {
            case .compactPanel:
                compactPanel
            case .horizontalConsole:
                horizontalConsole
            case .miniMonitor:
                miniMonitor
            }

            Divider()
            actionBar
        }
        .padding(12)
        .font(.system(size: 12))
        .controlSize(.small)
        .tint(.fillrAccent)
        .alert("FILLR", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK") { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    private var compactPanel: some View {
        Group {
            CollectionStatusView(store: store)
            HStack(alignment: .firstTextBaseline) {
                remainingMetric
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Unique footage").foregroundStyle(.secondary)
                    Text("\(clockText(store.snapshot?.available_ms ?? 0)) / \(clockText(store.sortSettings.total_ms))")
                        .font(.system(size: 18, weight: .medium)).monospacedDigit()
                }
            }
            FootageProgressView(store: store)
            clipCounts
            CollectionDetailsView(store: store, mini: false)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var horizontalConsole: some View {
        Group {
            HStack(alignment: .center, spacing: 16) {
                CollectionStatusView(store: store)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 46)
                remainingMetric
                Divider().frame(height: 46)
                metric("Unique footage", value: clockText(store.snapshot?.available_ms ?? 0))
                Divider().frame(height: 46)
                metric("Target", value: clockText(store.sortSettings.total_ms))
                Divider().frame(height: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(store.snapshot?.clips.count ?? 0) usable").fontWeight(.medium)
                    Text("\(store.snapshot?.pending.count ?? 0) pending").foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            FootageProgressView(store: store)
            CollectionDetailsView(store: store, mini: false)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var miniMonitor: some View {
        Group {
            CollectionStatusView(store: store)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(clockText(store.snapshot?.remaining_ms ?? store.sortSettings.total_ms))
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .accessibilityLabel("Footage remaining, \(clockText(store.snapshot?.remaining_ms ?? store.sortSettings.total_ms))")
                Text("Footage remaining").foregroundStyle(.secondary)
            }
            FootageProgressView(store: store)
            HStack {
                Text("\(clockText(store.snapshot?.available_ms ?? 0)) of \(clockText(store.sortSettings.total_ms))")
                    .monospacedDigit()
                Spacer(minLength: 6)
                clipCounts
            }
            CollectionDetailsView(store: store, mini: true)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var remainingMetric: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(clockText(store.snapshot?.remaining_ms ?? store.sortSettings.total_ms))
                .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("Footage remaining").foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit()
            Text(title).foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var clipCounts: some View {
        Text("\(store.snapshot?.clips.count ?? 0) usable · \(store.snapshot?.pending.count ?? 0) pending")
            .foregroundStyle(.secondary)
            .font(.system(size: 11))
            .fixedSize()
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { store.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .help("Refresh")
            .disabled(store.folder == nil || store.isBuilding)

            Button { store.toggleOverlay() } label: {
                Label(store.overlayVisible ? "Hide Overlay" : "Show Overlay", systemImage: "pip")
                    .labelStyle(.iconOnly)
            }
            .help(store.overlayVisible ? "Hide progress overlay" : "Show progress overlay")

            if store.lastOutput != nil {
                Button { store.openLastOutput() } label: {
                    Label("Open Last Export", systemImage: "folder.badge.gearshape").labelStyle(.iconOnly)
                }
                .help("Open last export")
            }

            Spacer(minLength: 8)
            Button(store.isBuilding ? "Building…" : "Build Folders") { store.build() }
                .buttonStyle(.borderedProminent)
                .disabled(store.snapshot?.status != "ready" || store.isBuilding)
                .help("Move selected clips into \(store.sortSettings.folder_count) folders when the layout is ready")
        }
    }
}
