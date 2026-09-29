// swift-tools-version: 5.9
import Foundation
import PackageDescription

let rustLibrary = ProcessInfo.processInfo.environment["RUST_LIB_DIR"] ?? "../../target/release"

let package = Package(
    name: "FILLR",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FILLR", targets: ["FILLR"])],
    targets: [
        .systemLibrary(name: "CFillr", path: "Sources/CFillr"),
        .executableTarget(
            name: "FILLR",
            dependencies: ["CFillr"],
            path: "Sources/FILLR",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibrary, "-lfillr_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
