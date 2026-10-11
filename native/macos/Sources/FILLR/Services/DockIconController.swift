import AppKit

/// The file icon stays static; AppKit displays these frames while FILLR is running.
@MainActor
final class DockIconController {
    private let artwork: DockIconArtwork?
    private var timer: Timer?
    private var displayedProgress = 0.0
    private var footageProgress = 0.0
    private var previewing = false
    private var openingAnimationPlayed = false

    init(resourceURL: URL? = Bundle.main.resourceURL) {
        artwork = resourceURL.flatMap {
            DockIconArtwork(directory: $0.appendingPathComponent("DockIcon"))
        }
        if artwork == nil { NSLog("FILLR: animated Dock icon artwork is missing") }
        display(0)
    }

    func update(available: UInt64, total: UInt64) {
        let next = Self.progress(available: available, total: total)
        guard next != footageProgress else { return }
        footageProgress = next
        if !previewing { animate(to: next, duration: 0.6) }
    }

    static func progress(available: UInt64, total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return Double(min(available, total)) / Double(total)
    }

    /// Begin before restoring the watched folder so its first poll cannot
    /// interrupt the opening sweep. Additional windows must not replay it.
    func start(completion: @escaping () -> Void) {
        guard !openingAnimationPlayed else { return }
        openingAnimationPlayed = true
        preview(completion: completion)
    }

    /// Exercise the real Dock renderer, then restore the latest engine progress.
    func preview(completion: @escaping () -> Void) {
        guard !previewing else { return }
        previewing = true
        animate(to: 0, duration: 0.3) { [weak self] in
            self?.animate(to: 1, duration: 1.8) { [weak self] in
                self?.animate(to: 0, duration: 1.8) { [weak self] in
                    guard let self else { return }
                    self.animate(to: self.footageProgress, duration: 0.6) { [weak self] in
                        guard let self else { return }
                        self.previewing = false
                        // A poll may have arrived while the needle was returning.
                        if self.displayedProgress != self.footageProgress {
                            self.animate(to: self.footageProgress, duration: 0.6)
                        }
                        completion()
                    }
                }
            }
        }
    }

    private func animate(to target: Double, duration: TimeInterval, completion: (() -> Void)? = nil) {
        timer?.invalidate()
        let start = displayedProgress
        let began = ProcessInfo.processInfo.systemUptime
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || start == target {
            display(target)
            // Preserve the preview's endpoint pauses even when movement is disabled.
            if completion == nil { return }
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let fraction = min(1, elapsed / duration)
                let eased = fraction * fraction * (3 - 2 * fraction)
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.display(start + (target - start) * eased)
                }
                if fraction >= 1 {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.display(target)
                    completion?()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func display(_ progress: Double) {
        displayedProgress = progress
        guard let artwork else { return }
        NSApplication.shared.applicationIconImage = artwork.image(progress: progress)
    }
}

/// Composite the original artwork, rotating only the needle about its axle.
struct DockIconArtwork {
    private let background: NSImage
    private let needle: NSImage
    private static let names = [
        "01-housing", "02-inner-face", "03-bezel-edges", "04-status-scale",
        "05-gauge-ticks", "06-gauge-labels", "07-fuel-label", "08-pump", "09-pivot"
    ]

    init?(directory: URL) {
        let layers = Self.names.compactMap { NSImage(contentsOf: directory.appendingPathComponent($0 + ".png")) }
        guard layers.count == Self.names.count,
              let needle = NSImage(contentsOf: directory.appendingPathComponent("10-needle.png")) else { return nil }
        self.needle = needle
        background = NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { rect in
            for layer in layers {
                layer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return true
        }
    }

    func image(progress: Double) -> NSImage {
        let background = background
        let needle = needle
        let progress = progress.isFinite ? min(1, max(0, progress)) : 0
        return NSImage(size: NSSize(width: 512, height: 512), flipped: true) { rect in
            background.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.width * 338 / 1024, yBy: rect.height * 527 / 1024)
            // The artwork rests at empty (about +40 degrees); full is -47 degrees.
            transform.rotate(byDegrees: CGFloat(-87 * progress))
            transform.translateX(by: -rect.width * 338 / 1024, yBy: -rect.height * 527 / 1024)
            transform.concat()
            needle.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}
