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
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2.bold())
            Text("The NTSC 1080i preset is on by default. Rejected files are deleted only after the final download name is present and the file has remained unchanged for 10 seconds.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Section("Sorting") {
                    TextField("Number of folders (1–100)", text: $folderCount)
                    TextField("Folder name prefix", text: $folderPrefix)
                    HStack {
                        Text("Total footage time")
                        TextField("Hours", text: $hours).frame(width: 75)
                        Text(":")
                        TextField("Minutes", text: $minutes).frame(width: 60)
                        Text(":")
                        TextField("Seconds", text: $seconds).frame(width: 60)
                    }
                }
                Section("Media Preferences") {
                Toggle("Filter media", isOn: $policy.enabled)
                Toggle("Delete rejected completed downloads", isOn: $policy.delete_rejected)
                    .disabled(!policy.enabled)
                TextField("Allowed extensions (comma separated)", text: $extensions)
                TextField("Allowed containers (ffprobe names)", text: $containers)
                TextField("Allowed video codecs", text: $codecs)
                TextField("Required width (blank = any)", text: $width)
                TextField("Required height (blank = any)", text: $height)
                Picker("TV standard", selection: $policy.television_standard) {
                    Text("Any").tag("any")
                    Text("NTSC").tag("ntsc")
                    Text("PAL").tag("pal")
                }
                TextField("Frame rate (blank = any)", text: $frameRate)
                Picker("Scan type", selection: $policy.scan_type) {
                    Text("Any").tag("any")
                    Text("Interlaced").tag("interlaced")
                    Text("Progressive").tag("progressive")
                }
                Picker("Orientation", selection: $policy.orientation) {
                    Text("Any").tag("any")
                    Text("Horizontal").tag("horizontal")
                    Text("Vertical").tag("vertical")
                }
                TextField("Display aspect ratio (blank = any)", text: $aspectRatio)
                }
            }
            if let inputError { Text(inputError).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Preferences") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 570, height: 750)
    }

    private func save() {
        guard let count = Int(folderCount), let timeHours = UInt64(hours), let m = UInt64(minutes), let s = UInt64(seconds),
              (1...100).contains(count), m < 60, s < 60,
              timeHours <= (UInt64.max / 1000 - m * 60 - s) / 3600 else {
            inputError = "Enter 1–100 folders and a valid hours, minutes, seconds time."
            return
        }
        let sort = SortSettings(folder_count: count, folder_prefix: folderPrefix, total_ms: (timeHours * 3600 + m * 60 + s) * 1000)
        do { try sort.validate() } catch { inputError = error.localizedDescription; return }
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
        if store.updateSettings(policy: policy, sort: sort) { dismiss() }
    }
}

private extension Optional where Wrapped == Int {
    var is_somePositive: Bool { self.map { $0 > 0 } ?? false }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
