import Foundation

/// A deliberate quit may discard a Settings draft, but never interrupt file moves.
enum QuitPolicy {
    enum Decision: Equatable {
        case quitNow
        case confirm
        case waitForBuild
    }

    static func decision(building: Bool, openEditors: Int, confirmed: Bool) -> Decision {
        if building { return confirmed ? .waitForBuild : .confirm }
        if openEditors > 0 && !confirmed { return .confirm }
        return .quitNow
    }
}

struct QuitHold {
    static let duration: TimeInterval = 1.25
    let startedAt: TimeInterval

    func progress(at time: TimeInterval) -> Double {
        min(1, max(0, (time - startedAt) / Self.duration))
    }
}
