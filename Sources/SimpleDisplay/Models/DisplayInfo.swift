import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let currentMode: DisplayMode
    let availableModes: [DisplayMode]
    let isVirtual: Bool
    let isBuiltIn: Bool
    let isMain: Bool
    let isMirrored: Bool
    let mirroredToDisplayID: CGDirectDisplayID
    let physicalSize: CGSize
    let backingScaleFactor: Double

    var isActive: Bool { !isMirrored }

    func with(name: String, isVirtual: Bool) -> DisplayInfo {
        DisplayInfo(
            id: id, name: name, currentMode: currentMode,
            availableModes: availableModes, isVirtual: isVirtual,
            isBuiltIn: isBuiltIn, isMain: isMain, isMirrored: isMirrored,
            mirroredToDisplayID: mirroredToDisplayID,
            physicalSize: physicalSize, backingScaleFactor: backingScaleFactor
        )
    }
}

struct DisplayMode: Identifiable, Equatable, Hashable {
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
