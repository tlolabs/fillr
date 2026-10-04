// swift-tools-version: 5.9
import Foundation
import PackageDescription

let rustLibrary = ProcessInfo.processInfo.environment["RUST_LIB_DIR"] ?? "../../target/release"

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
        .executableTarget(
            name: "FILLR",
            dependencies: ["CFillr", "AppPreferences", "UpdatePolicy", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/FILLR",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibrary, "-lfillr_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
