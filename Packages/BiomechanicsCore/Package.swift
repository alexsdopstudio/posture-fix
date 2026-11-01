// swift-tools-version:5.10
import Foundation
import PackageDescription

// Resolve the active developer directory the same way `xcode-select` does.
// A Command Line Tools-only toolchain ships neither the SwiftData macro plugin
// nor a default search path for the Testing framework, so we adapt to it.
let developerDirectory: String = {
    if let explicit = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !explicit.isEmpty {
        return explicit
    }
    if let linked = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
        return linked
    }
    return FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        ? "/Applications/Xcode.app/Contents/Developer"
        : "/Library/Developer/CommandLineTools"
}()
let isCommandLineToolsOnly = developerDirectory.contains("CommandLineTools")

let coreSwiftSettings: [SwiftSetting] = isCommandLineToolsOnly
    ? [.define("FLOW_SWIFTDATA_MACROS_UNAVAILABLE")]
    : []

let testingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let testSwiftSettings: [SwiftSetting] = isCommandLineToolsOnly
    ? coreSwiftSettings + [.unsafeFlags(["-F", testingFrameworks])]
    : []
let testLinkerSettings: [LinkerSetting] = isCommandLineToolsOnly
    ? [.unsafeFlags([
        "-F", testingFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", testingFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", testingLibraries,
    ])]
    : []

let package = Package(
    name: "BiomechanicsCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BiomechanicsCore", targets: ["BiomechanicsCore"]),
    ],
    targets: [
        .target(
            name: "BiomechanicsCore",
            swiftSettings: coreSwiftSettings
        ),
        .testTarget(
            name: "BiomechanicsCoreTests",
            dependencies: ["BiomechanicsCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ],
    swiftLanguageVersions: [.v5]
)
