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
    /// Highest refresh rate a virtual display may be created with.
    ///
    /// This used to be 60 Hz, on the belief that `CGVirtualDisplay` could not do
    /// better. That belief is wrong: the private API honours whatever refresh rate
    /// the mode asks for, and the window server drives the virtual display at that
    /// rate. Verified on an M1 Mac mini (macOS 26): a 1920x1080 mode requested at
    /// 120 Hz is reported as 120 Hz by `CGDisplayCopyAllDisplayModes` and a
    /// `CVDisplayLink` fires ~120 times/s. The observed ceiling is ~488 Hz
    /// (pixel-clock bound), so 240 Hz is well within range and is the supported
    /// ceiling here.
    public static let maxRefreshRate = 240.0
    /// Default when the caller does not ask for a specific rate.
    public static let defaultRefreshRate = 60.0
    public static let maxNameLength = 64

    public init(
        name: String = "Virtual Display",
        width: Int = 1920,
        height: Int = 1080,
        refreshRate: Double = 60.0,   // see `defaultRefreshRate`
        hiDPI: Bool = false
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }
}
