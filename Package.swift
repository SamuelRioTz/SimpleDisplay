// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimpleDisplay",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "SimpleDisplayCore",
            path: "Sources/SimpleDisplayCore"
        ),
        .executableTarget(
            name: "SimpleDisplay",
            dependencies: ["VirtualDisplayBridge", "SimpleDisplayCore"],
            path: "Sources/SimpleDisplay",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "simpledisplayctl",
            dependencies: ["SimpleDisplayCore"],
            path: "Sources/simpledisplayctl"
        ),
        .testTarget(
            name: "SimpleDisplayCoreTests",
            dependencies: ["SimpleDisplayCore"],
            path: "Tests/SimpleDisplayCoreTests"
        ),
    ]
)
