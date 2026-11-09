import Foundation

enum WindowLayout: String, CaseIterable, Identifiable {
    case compactPanel = "compact-panel"
    case horizontalConsole = "horizontal-console"
    case miniMonitor = "mini-monitor"

    static let preferenceKey = "mainWindowLayout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compactPanel: return "Compact Panel"
        case .horizontalConsole: return "Horizontal Console"
        case .miniMonitor: return "Mini Monitor"
        }
    }

    var minimumSize: CGSize {
        switch self {
        case .compactPanel: return CGSize(width: 500, height: 330)
        case .horizontalConsole: return CGSize(width: 760, height: 250)
        case .miniMonitor: return CGSize(width: 340, height: 260)
        }
    }

    var preferredSize: CGSize {
        switch self {
        case .compactPanel: return CGSize(width: 540, height: 350)
        case .horizontalConsole: return CGSize(width: 800, height: 280)
        case .miniMonitor: return CGSize(width: 360, height: 290)
        }
    }
}
