import SwiftUI

struct MediaPreferencesView: View {
    @ObservedObject var store: FillrStore
    @Environment(\.dismiss) private var dismiss
    @State private var policy: MediaPolicy
    @State private var extensions: String
    @State private var containers: String
    @State private var codecs: String
    @State private var width: String
    @State private var height: String
    @State private var frameRate: String
    @State private var aspectRatio: String
    @State private var inputError: String?
    @State private var folderCount: String
    @State private var folderPrefix: String
    @State private var hours: String
    @State private var minutes: String
    @State private var seconds: String

    init(store: FillrStore) {
        self.store = store
        let current = store.mediaPolicy
        let sort = store.sortSettings
        _folderCount = State(initialValue: String(sort.folder_count))
        _folderPrefix = State(initialValue: sort.folder_prefix)
        _hours = State(initialValue: String(sort.total_ms / 3_600_000))
        _minutes = State(initialValue: String(sort.total_ms / 60_000 % 60))
        _seconds = State(initialValue: String(sort.total_ms / 1000 % 60))
        _policy = State(initialValue: current)
        _extensions = State(initialValue: current.allowed_extensions.joined(separator: ", "))
        _containers = State(initialValue: current.allowed_containers.joined(separator: ", "))
        _codecs = State(initialValue: current.allowed_codecs.joined(separator: ", "))
        _width = State(initialValue: current.required_width.map(String.init) ?? "")
        _height = State(initialValue: current.required_height.map(String.init) ?? "")
        _frameRate = State(initialValue: current.frame_rate ?? "")
        _aspectRatio = State(initialValue: current.display_aspect_ratio ?? "")
    }

    var body: some View {
        VStack(spacing: 14) {
            TabView {
                generalPreferences
                    .tabItem { Label("General", systemImage: "gearshape") }
                mediaPreferences
                    .tabItem { Label("Media", systemImage: "film") }
            }
            if let inputError {
                Text(inputError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Error: \(inputError)")
                    .accessibilityAddTraits(.isStaticText)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    loadFromStore()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Preferences") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .tint(.fillrAccent)
        .padding(20)
        .frame(width: 620, height: 640)
        .onAppear { loadFromStore() }
    }

    private var generalPreferences: some View {
        ScrollView {
            VStack(spacing: 18) {
                GroupBox("Sorting") {
                    VStack(alignment: .leading, spacing: 14) {
                        settingsRow("Number of folders", detail: "1–100") {
                            TextField("Number of folders", text: $folderCount)
                                .labelsHidden()
                                .frame(width: 80)
                        }
                        settingsRow("Folder name prefix") {
                            TextField("Folder name prefix", text: $folderPrefix).labelsHidden()
                        }
                        settingsRow("Total footage time") {
                            HStack(alignment: .top, spacing: 12) {
                                timeField("Hours", text: $hours)
                                timeField("Minutes", text: $minutes)
                                timeField("Seconds", text: $seconds)
                            }
                        }
                    }
                    .padding(10)
                }
                GroupBox("Appearance") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("App icon").font(.headline)
                        SettingsIconPicker(store: store)
                        Text("Icon changes apply immediately. Progress colors follow the selected icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                }
            }
            .padding(12)
        }
    }

    private var mediaPreferences: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("The NTSC 1080i preset is on by default. Rejected downloads are deleted only after their final name is present and the file has remained unchanged for 10 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GroupBox("Media filtering") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Filter media", isOn: $policy.enabled)
                        Toggle("Delete rejected completed downloads", isOn: $policy.delete_rejected)
                            .disabled(!policy.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                GroupBox("Accepted media") {
                    VStack(spacing: 14) {
                        settingsRow("File extensions", detail: "Comma separated") {
                            TextField("Allowed extensions", text: $extensions).labelsHidden()
                        }
                        settingsRow("Containers", detail: "ffprobe names") {
                            TextField("Allowed containers", text: $containers).labelsHidden()
                        }
                        settingsRow("Video codecs") {
                            TextField("Allowed video codecs", text: $codecs).labelsHidden()
                        }
                        settingsRow("Width", detail: "Blank allows any") {
                            TextField("Required width", text: $width).labelsHidden()
                        }
                        settingsRow("Height", detail: "Blank allows any") {
                            TextField("Required height", text: $height).labelsHidden()
                        }
                        settingsRow("TV standard") {
                            Picker("TV standard", selection: $policy.television_standard) {
                                Text("Any").tag("any")
                                Text("NTSC").tag("ntsc")
                                Text("PAL").tag("pal")
                            }.labelsHidden()
                        }
                        settingsRow("Frame rate", detail: "Blank allows any") {
                            TextField("Frame rate", text: $frameRate).labelsHidden()
                        }
                        settingsRow("Scan type") {
                            Picker("Scan type", selection: $policy.scan_type) {
                                Text("Any").tag("any")
                                Text("Interlaced").tag("interlaced")
                                Text("Progressive").tag("progressive")
                            }.labelsHidden()
                        }
                        settingsRow("Orientation") {
                            Picker("Orientation", selection: $policy.orientation) {
                                Text("Any").tag("any")
                                Text("Horizontal").tag("horizontal")
                                Text("Vertical").tag("vertical")
                            }.labelsHidden()
                        }
                        settingsRow("Display aspect ratio", detail: "Blank allows any") {
                            TextField("Display aspect ratio", text: $aspectRatio).labelsHidden()
                        }
                    }
                    .padding(10)
                    .disabled(!policy.enabled)
                }
            }
            .padding(12)
        }
    }

    private func settingsRow<Content: View>(_ title: String, detail: String? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 156, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .labelsHidden()
                .monospacedDigit()
                .accessibilityLabel("Total footage \(title.lowercased())")
                .accessibilityIdentifier("footage-\(title.lowercased())")
        }
        .frame(width: 72)
    }

    private func loadFromStore() {
        let current = store.mediaPolicy
        let sort = store.sortSettings
        folderCount = String(sort.folder_count)
        folderPrefix = sort.folder_prefix
        hours = String(sort.total_ms / 3_600_000)
        minutes = String(sort.total_ms / 60_000 % 60)
        seconds = String(sort.total_ms / 1000 % 60)
        policy = current
        extensions = current.allowed_extensions.joined(separator: ", ")
        containers = current.allowed_containers.joined(separator: ", ")
        codecs = current.allowed_codecs.joined(separator: ", ")
        width = current.required_width.map(String.init) ?? ""
        height = current.required_height.map(String.init) ?? ""
        frameRate = current.frame_rate ?? ""
        aspectRatio = current.display_aspect_ratio ?? ""
        inputError = nil
    }

    private func save() {
        let fc = folderCount.trimmingCharacters(in: .whitespaces)
        let hStr = hours.trimmingCharacters(in: .whitespaces)
        let mStr = minutes.trimmingCharacters(in: .whitespaces)
        let sStr = seconds.trimmingCharacters(in: .whitespaces)
        guard let count = Int(fc), let timeHours = UInt64(hStr), let m = UInt64(mStr), let s = UInt64(sStr),
              (1...100).contains(count), m < 60, s < 60,
              timeHours <= (UInt64.max / 1000 - m * 60 - s) / 3600 else {
            inputError = "Enter 1–100 folders and a valid hours, minutes, seconds time."
            return
        }
        let sort = SortSettings(folder_count: count, folder_prefix: folderPrefix, total_ms: (timeHours * 3600 + m * 60 + s) * 1000)
        let w = width.trimmingCharacters(in: .whitespaces)
        let h = height.trimmingCharacters(in: .whitespaces)
        guard (w.isEmpty || Int(w).is_somePositive), (h.isEmpty || Int(h).is_somePositive) else {
            inputError = "Width and height must be positive whole numbers."
            return
        }
        func list(_ value: String) -> [String] {
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        policy.allowed_extensions = list(extensions)
        policy.allowed_containers = list(containers)
        policy.allowed_codecs = list(codecs)
        policy.required_width = Int(w)
        policy.required_height = Int(h)
        policy.frame_rate = frameRate.trimmingCharacters(in: .whitespaces).nilIfEmpty
        policy.display_aspect_ratio = aspectRatio.trimmingCharacters(in: .whitespaces).nilIfEmpty
        do {
            try EngineBridge.validate(settings: sort)
            try EngineBridge.validate(policy: policy)
        } catch {
            inputError = error.localizedDescription
            return
        }
        if store.updateSettings(policy: policy, sort: sort) { dismiss() }
    }
}

private extension Optional where Wrapped == Int {
    var is_somePositive: Bool { self.map { $0 > 0 } ?? false }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
