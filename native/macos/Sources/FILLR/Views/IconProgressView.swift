import SwiftUI

extension Color {
    static let fillrAccent = Color(red: 0x61 / 255.0, green: 0xBB / 255.0, blue: 0x46 / 255.0)
}

/// The same equal-width bands and narrow transitions as the icon's gauge.
/// Values come from assets/icons/status-scale-palettes.json.
struct IconProgressPalette {
    let bands: [UInt32]
    static let transitionWidth = 0.06

    init(style: DockIconStyle) {
        switch style {
        case .clean: bands = [0x61BB46]
        case .classic: bands = [0xE03A3E, 0xF5821F, 0xFDB827, 0x61BB46]
        case .macOS: bands = [0x009DDC, 0x963D97, 0xE03A3E, 0xF5821F, 0xFDB827, 0x61BB46]
        }
    }

    var gradient: Gradient {
        var stops = [Gradient.Stop(color: color(bands[0]), location: 0)]
        for index in 1..<bands.count {
            let boundary = Double(index) / Double(bands.count)
            let start = boundary - Self.transitionWidth / 2
            stops.append(.init(color: color(bands[index - 1]), location: start))
            // Small linear segments reproduce the smoothstep blend used in the artwork.
            for step in 1...8 {
                let fraction = Double(step) / 8
                let blend = fraction * fraction * (3 - 2 * fraction)
                let previous = components(bands[index - 1])
                let next = components(bands[index])
                stops.append(.init(color: Color(
                    red: previous.0 + (next.0 - previous.0) * blend,
                    green: previous.1 + (next.1 - previous.1) * blend,
                    blue: previous.2 + (next.2 - previous.2) * blend),
                    location: start + Self.transitionWidth * fraction))
            }
        }
        stops.append(.init(color: color(bands[bands.count - 1]), location: 1))
        return Gradient(stops: stops)
    }

    private func components(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private func color(_ hex: UInt32) -> Color {
        let rgb = components(hex)
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

struct IconProgressView: View {
    let value: UInt64
    let total: UInt64
    let style: DockIconStyle

    var body: some View {
        ProgressView(value: Double(min(value, total)), total: Double(max(total, 1)))
            .progressViewStyle(IconProgressStyle(iconStyle: style))
    }
}

struct IconProgressStyle: ProgressViewStyle {
    let iconStyle: DockIconStyle

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    // Keep the gradient mapped to the entire track, revealing it
                    // as footage arrives rather than compressing every color into the fill.
                    LinearGradient(gradient: IconProgressPalette(style: iconStyle).gradient,
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                        }
                }
                .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}
