import AppKit
import SwiftUI

struct FolderSelectionRow: View {
    @ObservedObject var store: FillrStore
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(store.folder?.lastPathComponent ?? "Choose download folder")
                .fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
                .help(store.folder?.path ?? "Choose the folder where CNN MPG files arrive")
                .accessibilityLabel(store.folder?.path ?? "No download folder selected")
            Spacer(minLength: 4)
            if compact {
                Button { store.chooseFolder() } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus").labelStyle(.iconOnly)
                }
                .disabled(store.isBuilding)
                .help("Choose download folder")
            } else {
                Button("Choose…") { store.chooseFolder() }.disabled(store.isBuilding)
                    .help("Choose download folder")
            }
            settingsButton.disabled(store.isBuilding)
        }
    }

    @ViewBuilder private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .help("Settings")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings…", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .help("Settings")
        }
    }
}

struct CollectionStatusView: View {
    @ObservedObject var store: FillrStore

    private var ready: Bool { store.snapshot?.status == "ready" }
    private var status: String {
        if store.isBuilding { return "Building folders…" }
        switch store.folderOpenState {
        case .opening: return "Opening download folder…"
        case .failed(let message): return "Couldn’t open folder: \(message)"
        case .idle: break
        }
        if ready { return "Ready — you can stop downloading" }
        return store.snapshot?.message ?? (store.folder == nil ? "Choose a download folder" : "Scanning footage…")
    }

    var body: some View {
        Label {
            Text(status).fontWeight(.medium).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ready ? "checkmark.circle.fill" : "video.badge.waveform")
                .foregroundStyle(Color.fillrAccent)
                .accessibilityHidden(true)
        }
        .help(status)
        .accessibilityElement(children: .combine)
    }
}

struct FootageProgressView: View {
    @ObservedObject var store: FillrStore

    var body: some View {
        IconProgressView(value: store.snapshot?.available_ms ?? 0,
                         total: store.sortSettings.total_ms, style: store.iconStyle)
            .accessibilityLabel("Footage collected")
            .accessibilityValue("\(clockText(store.snapshot?.available_ms ?? 0)) of \(clockText(store.sortSettings.total_ms))")
    }
}
