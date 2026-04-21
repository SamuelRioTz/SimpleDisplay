import Foundation

/// A dependency-free description of a virtual display configuration. Lives
/// in `SimpleDisplayCore` so the CLI and the app can share the same schema
/// without either pulling in AppKit / CoreGraphics / the private bridge.
///
/// Ranges mirror the limits enforced by `VirtualDisplayService.VirtualDisplayConfig`
/// inside the app — kept in sync intentionally. `URLCommandParser` clamps and
/// rejects out-of-range values before the app ever sees them.
public struct VirtualDisplayRequest: Equatable, Sendable {
    public var name: String
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    public var hiDPI: Bool

    public static let minDimension = 100
    public static let maxDimension = 8192
    public static let maxRefreshRate = 60.0
    public static let maxNameLength = 64

    public init(
        name: String = "Virtual Display",
        width: Int = 1920,
        height: Int = 1080,
        refreshRate: Double = 60.0,
        hiDPI: Bool = false
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }
}
