import SwiftUI

struct DownloadSpeedView: View {
    let downloads: [DownloadInfo]

    private var title: String {
        downloads.first?.completed == true
            ? "Last download average (estimated)"
            : "Average download speed (estimated)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if downloads.isEmpty {
                Text("Waiting for file growth…").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(downloads) { download in
                            HStack {
                                Text(download.filename)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(download.filename)
                                Spacer()
                                Text(downloadSpeedText(download.average_bytes_per_second))
                                    .monospacedDigit().fixedSize()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(download.filename), \(title), \(downloadSpeedText(download.average_bytes_per_second))")
                        }
                    }
                    .font(.caption)
                }
                .frame(height: CGFloat(min(downloads.count, 4)) * 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Estimated from file growth while FILLR watches this folder. Bytes already present when monitoring starts are excluded. Disk buffering and preallocated files can affect the estimate.")
    }
}

func downloadSpeedText(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
    let units = ["B/s", "kB/s", "MB/s", "GB/s"]
    var value = bytesPerSecond
    var unit = 0
    while value >= 1000 && unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    return value.formatted(.number.precision(.fractionLength(unit == 0 ? 0 : 1))) + " " + units[unit]
}
