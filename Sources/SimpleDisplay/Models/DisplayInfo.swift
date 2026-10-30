import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let uuid: String?
    let name: String
    let currentMode: DisplayMode
    let availableModes: [DisplayMode]
    let isVirtual: Bool
    let isBuiltIn: Bool
    let isMain: Bool
    /// True when the display is active on the desktop. False when it has been
    /// disabled via `CGSConfigureDisplayEnabled`. On current macOS a disabled
    /// display drops out of the online list entirely, so `false` is mostly seen
    /// on ghost rows the view model synthesizes from retained identity.
    let isEnabled: Bool
    /// The display this one mirrors, or `kCGNullDirectDisplay` when it shows its
    /// own desktop. Mirroring is a separate, reversible state from disabling: a
    /// mirrored display is still enabled and visible, it just duplicates another.
    let mirroredToDisplayID: CGDirectDisplayID
    let physicalSize: CGSize
    let backingScaleFactor: Double

    var isActive: Bool { isEnabled }
    var isMirrored: Bool { mirroredToDisplayID != kCGNullDirectDisplay }

    func with(name: String, isVirtual: Bool) -> DisplayInfo {
        DisplayInfo(
            id: id, uuid: uuid, name: name, currentMode: currentMode,
            availableModes: availableModes, isVirtual: isVirtual,
            isBuiltIn: isBuiltIn, isMain: isMain, isEnabled: isEnabled,
            mirroredToDisplayID: mirroredToDisplayID,
            physicalSize: physicalSize, backingScaleFactor: backingScaleFactor
        )
    }

    /// A copy addressed by a different `CGDirectDisplayID`. Used when a ghost's
    /// UUID resolves to a fresh ID after a topology change.
    func with(id: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(
            id: id, uuid: uuid, name: name, currentMode: currentMode,
            availableModes: availableModes, isVirtual: isVirtual,
            isBuiltIn: isBuiltIn, isMain: isMain, isEnabled: isEnabled,
            mirroredToDisplayID: mirroredToDisplayID,
            physicalSize: physicalSize, backingScaleFactor: backingScaleFactor
        )
    }

    /// A copy marked disabled, retaining the live mode/name info. Used to keep a
    /// row visible after a disabled display drops out of the online list.
    func asDisabledGhost() -> DisplayInfo {
        DisplayInfo(
            id: id, uuid: uuid, name: name, currentMode: currentMode,
            availableModes: availableModes, isVirtual: isVirtual,
            isBuiltIn: isBuiltIn, isMain: false, isEnabled: false,
            mirroredToDisplayID: kCGNullDirectDisplay,
            physicalSize: physicalSize, backingScaleFactor: backingScaleFactor
        )
    }

    /// Minimal disabled row reconstructed from persisted identity alone, when no
    /// live CoreGraphics info is available (e.g. a display disabled in a prior
    /// session that never came back online). `currentMode` is a 0×0 sentinel.
    static func disabledPlaceholder(id: CGDirectDisplayID, uuid: String?, name: String) -> DisplayInfo {
        DisplayInfo(
            id: id, uuid: uuid, name: name,
            currentMode: DisplayMode(width: 0, height: 0, pixelWidth: 0, pixelHeight: 0, refreshRate: 0, isHiDPI: false),
            availableModes: [], isVirtual: false, isBuiltIn: false,
            isMain: false, isEnabled: false, mirroredToDisplayID: kCGNullDirectDisplay,
            physicalSize: .zero, backingScaleFactor: 1.0
        )
    }

    /// True for a reconstructed placeholder row that has no real mode info.
    var isPlaceholder: Bool { isEnabled == false && currentMode.width == 0 }

    /// The modes this display offers, one entry per size and scale, with the
    /// refresh rates each comes in. HiDPI ("looks like") sizes first, then
    /// native ones; within each, largest first, as CoreGraphics lists them.
    var modeGroups: [ModeGroup] {
        var groups: [ModeGroup] = []
        for mode in availableModes {
            if let idx = groups.firstIndex(where: { $0.width == mode.width && $0.height == mode.height && $0.isHiDPI == mode.isHiDPI }) {
                if !groups[idx].modes.contains(where: { abs($0.refreshRate - mode.refreshRate) < 0.1 }) {
                    groups[idx].modes.append(mode)
                }
            } else {
                groups.append(ModeGroup(width: mode.width, height: mode.height, isHiDPI: mode.isHiDPI, modes: [mode]))
            }
        }
        return groups.sorted {
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.height > $1.height
        }
    }
}

/// One size-and-scale a display can run at, with its refresh rates (highest first).
struct ModeGroup: Identifiable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    var modes: [DisplayMode]

    var id: String { "\(width)x\(height)_\(isHiDPI ? "hi" : "lo")" }
    var sizeString: String { "\(width) x \(height)" }
    /// The mode to use when the user picks the size without a rate: the current
    /// display's rate if this size offers it, else the highest.
    func preferredMode(near current: DisplayMode) -> DisplayMode {
        modes.first { abs($0.refreshRate - current.refreshRate) < 0.1 } ?? modes.max { $0.refreshRate < $1.refreshRate } ?? modes[0]
    }
}

struct DisplayMode: Identifiable, Equatable, Hashable, Codable {
    var id: String { "\(width)x\(height)@\(refreshRate)_\(isHiDPI ? "hi" : "lo")" }
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool

    var resolutionString: String {
        if isHiDPI {
            return "\(width) x \(height) (HiDPI) @ \(formattedRefreshRate)"
        }
        return "\(width) x \(height) @ \(formattedRefreshRate)"
    }

    func localizedResolutionString(_ locale: LocaleManager) -> String {
        let refresh = localizedRefreshRate(locale)
        if isHiDPI {
            return "\(width) x \(height) \(locale.t("hidpi_suffix")) @ \(refresh)"
        }
        return "\(width) x \(height) @ \(refresh)"
    }

    var shortString: String {
        "\(width) x \(height)"
    }

    var formattedRefreshRate: String {
        if refreshRate == 0 { return "default" }
        if refreshRate.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(refreshRate)) Hz"
        }
        return String(format: "%.1f Hz", refreshRate)
    }

    func localizedRefreshRate(_ locale: LocaleManager) -> String {
        if refreshRate == 0 { return locale.t("refresh_default") }
        if refreshRate.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(refreshRate)) Hz"
        }
        return String(format: "%.1f Hz", refreshRate)
    }
}
