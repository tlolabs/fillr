// swift-tools-version: 5.9
import Foundation
import PackageDescription

let rustLibrary = ProcessInfo.processInfo.environment["RUST_LIB_DIR"] ?? "../../target/release"

// XCTest loads its bundle outside the packaged app's Frameworks layout.
// Resolve only the test runtime lookup against this package, not the runner cwd.
let testRustLibrary = URL(
    fileURLWithPath: rustLibrary,
    relativeTo: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
).standardizedFileURL.path

// Background rendering links the pinned, locally compiled FFmpeg libraries.
// Build them with script/build_background_ffmpeg_macos.sh before SwiftPM.
let backgroundFFmpeg = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../target/background-ffmpeg").standardizedFileURL.path

let package = Package(
    name: "FILLR",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FILLR", targets: ["FILLR"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "AppPreferences"),
        .testTarget(name: "AppPreferencesTests", dependencies: ["AppPreferences"]),
        .target(name: "UpdatePolicy"),
        .testTarget(name: "UpdatePolicyTests", dependencies: ["UpdatePolicy"]),
        .systemLibrary(name: "CFillr", path: "Sources/CFillr"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "CBackgroundEngine",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17", "-fobjc-arc", "-I", "\(backgroundFFmpeg)/include"])],
            linkerSettings: [
                .unsafeFlags(["-L", "\(backgroundFFmpeg)/lib"]),
                .linkedLibrary("avformat"), .linkedLibrary("avcodec"),
                .linkedLibrary("avutil"), .linkedLibrary("swscale"),
                .linkedFramework("Foundation"), .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"), .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"), .linkedFramework("Metal"),
                .linkedFramework("MetalKit"), .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"), .linkedFramework("CoreGraphics"),
                .linkedFramework("MetalPerformanceShaders")
            ]
        ),
        .target(name: "BackgroundPlanning", dependencies: ["CZlib"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ImageIO"),
            .linkedFramework("CoreGraphics"), .linkedFramework("CoreText")
        ]),
        .testTarget(name: "BackgroundEngineTests", dependencies: ["CBackgroundEngine"], linkerSettings: [.linkedFramework("Metal")]),
        .testTarget(name: "BackgroundPlanningTests", dependencies: ["BackgroundPlanning"]),
        .target(name: "BackgroundProfiling", dependencies: ["CBackgroundEngine"], linkerSettings: [
            .linkedFramework("Metal"), .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia")
        ]),
        .testTarget(name: "BackgroundProfilingTests", dependencies: ["BackgroundProfiling"]),
        .testTarget(name: "BackgroundIntegrationTests", dependencies: ["BackgroundPlanning", "BackgroundProfiling"]),
        .executableTarget(
            name: "FILLR",
            dependencies: ["CFillr", "AppPreferences", "UpdatePolicy", "BackgroundPlanning", "BackgroundProfiling", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/FILLR",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibrary, "-lfillr_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "FILLRTests",
            dependencies: ["FILLR"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", testRustLibrary])
            ]
        )
    ]
)
