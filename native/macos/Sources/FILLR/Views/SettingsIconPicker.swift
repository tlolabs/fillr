import SwiftUI

struct SettingsIconPicker: View {
    @ObservedObject var store: FillrStore

    var body: some View {
        HStack(spacing: 12) {
            ForEach(DockIconStyle.allCases) { style in
                Button { store.setIconStyle(style) } label: {
                    VStack(spacing: 6) {
                        if let thumbnail = store.iconThumbnails[style] {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 76, height: 76)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 48))
                                .frame(width: 76, height: 76)
                                .accessibilityHidden(true)
                        }
                        Label(style.title, systemImage: store.iconStyle == style ? "checkmark.circle.fill" : "circle")
                            .font(.callout)
                            .foregroundStyle(store.iconStyle == style ? Color.fillrAccent : Color.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(store.iconStyle == style ? Color.fillrAccent.opacity(0.1) : Color.clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(store.iconStyle == style ? Color.fillrAccent : Color.secondary.opacity(0.3),
                                          lineWidth: store.iconStyle == style ? 2 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(style.title) app icon")
                .accessibilityValue(store.iconStyle == style ? "Selected" : "Not selected")
                .accessibilityAddTraits(store.iconStyle == style ? [.isSelected] : [])
                .help("Use the \(style.title) app icon")
            }
        }
    }
}
