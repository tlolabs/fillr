import AppKit

// Run against the staged app's resources, exercising the artwork shipped to users.
@main
struct DockIconChecks {
    @MainActor
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let artwork = DockIconArtwork(directory: resources.appendingPathComponent("DockIcon")) else {
            fatalError("Packaged DockIcon artwork is missing")
        }
        precondition(DockIconArtwork(directory: resources.appendingPathComponent("missing")) == nil)
        precondition(DockIconController.progress(available: 0, total: 100) == 0)
        precondition(DockIconController.progress(available: 50, total: 100) == 0.5)
        precondition(DockIconController.progress(available: 200, total: 100) == 1)
        precondition(DockIconController.progress(available: 100, total: 0) == 0)
        precondition(DockIconController.progress(available: .max, total: .max) == 1)
        var frames: [NSBitmapImageRep] = []
        for (name, progress) in [("empty", 0.0), ("half", 0.5), ("full", 1.0)] {
            let image = artwork.image(progress: progress)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            frames.append(bitmap)
        }
        let width = frames[0].pixelsWide
        let height = frames[0].pixelsHigh
        var changed = 0
        for y in 0..<height {
            for x in 0..<width {
                let colors = frames.map { $0.colorAt(x: x, y: y)! }
                if colors[0] != colors[1] || colors[0] != colors[2] { changed += 1 }
                // The upper-left FILLR label and outer housing must never rotate.
                if x < width * 2 / 5 && y < height / 4 {
                    precondition(colors[0] == colors[1] && colors[0] == colors[2], "Background moved")
                }
            }
        }
        precondition(changed > 1000, "Needle did not move")
        func wait(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
        }
        func png(_ image: NSImage) -> Data {
            NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        }
        func checkNeedle(progress: Double) {
            // AppKit may expand the application icon to 1024 pixels. Check its
            // visible needle position independently of that backing resolution.
            let bitmap = NSBitmapImageRep(data: NSApplication.shared.applicationIconImage.tiffRepresentation!)!
            let angle = artwork.rotationDegrees(progress: progress) * Double.pi / 180
            let dx = artwork.probePoint.x - artwork.pivot.x
            let dy = artwork.probePoint.y - artwork.pivot.y
            let x = artwork.pivot.x + cos(angle) * dx - sin(angle) * dy
            let y = artwork.pivot.y + sin(angle) * dx + cos(angle) * dy
            let color = bitmap.colorAt(x: Int(x / 1024 * Double(bitmap.pixelsWide)),
                                       y: Int(y / 1024 * Double(bitmap.pixelsHigh)))!.usingColorSpace(.deviceRGB)!
            precondition(color.redComponent > 0.65 && color.greenComponent > 0.65 && color.blueComponent > 0.65,
                         "Live needle did not reach \(progress)")
        }
        let controller = DockIconController(resourceURL: resources)
        var openingFinished = false
        controller.start { openingFinished = true }
        controller.update(available: 50, total: 100)
        wait(0.1)
        checkNeedle(progress: 0)
        precondition(!openingFinished, "Initial footage poll interrupted the opening sweep")
        wait(4.9)
        precondition(openingFinished, "Opening animation did not finish")
        try png(NSApplication.shared.applicationIconImage).write(to: output.appendingPathComponent("live-half.png"))
        checkNeedle(progress: 0.5)
        controller.start { fatalError("Opening animation replayed") }
        wait(0.1)
        checkNeedle(progress: 0.5)
        var finished = false
        controller.preview { finished = true }
        wait(2)
        controller.update(available: 25, total: 100)
        wait(3)
        precondition(finished, "Preview did not finish")
        checkNeedle(progress: 0.25)
        controller.update(available: 75, total: 100)
        wait(0.8)
        checkNeedle(progress: 0.75)
        NSApplication.shared.applicationIconImage = nil
        print("Packaged artwork, opening sweep, one-time startup, live progress, and preview restore passed; \(changed) pixels change during the sweep.")
    }
}
