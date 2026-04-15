// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimpleDisplay",
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
        .executableTarget(
            name: "SimpleDisplay",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/SimpleDisplay",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
