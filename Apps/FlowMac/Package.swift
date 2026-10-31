// swift-tools-version:5.10
import Foundation
import PackageDescription

// The executable embeds its Info.plist (NSMotionUsageDescription, LSUIElement) in the
// __TEXT,__info_plist section so CoreMotion can ask for headphone motion access
// even when launched straight from `swift run`.
let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/FlowMac/Info.plist")
    .path

let package = Package(
    name: "FlowMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/BiomechanicsCore"),
    ],
    targets: [
        .executableTarget(
            name: "FlowMac",
            dependencies: [
                .product(name: "BiomechanicsCore", package: "BiomechanicsCore"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath,
                ]),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
