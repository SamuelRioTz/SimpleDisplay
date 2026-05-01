import AppKit
import ColorSync
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "app.simpledisplay", category: "DisplayService")

@MainActor
final class DisplayService {

    // MARK: - Enumerate Displays

    /// Fetches all online displays (including mirrored/disabled ones)
    func fetchDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let nameMap: [CGDirectDisplayID: String] = NSScreen.screens.reduce(into: [:]) { dict, screen in
            if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                dict[screenID] = screen.localizedName
            }
        }

        let scaleMap: [CGDirectDisplayID: Double] = NSScreen.screens.reduce(into: [:]) { dict, screen in
            if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                dict[screenID] = screen.backingScaleFactor
            }
        }

        return ids.compactMap { displayID in
            buildDisplayInfo(displayID: displayID, nameMap: nameMap, scaleMap: scaleMap)
        }
    }

    private func buildDisplayInfo(
        displayID: CGDirectDisplayID,
        nameMap: [CGDirectDisplayID: String],
        scaleMap: [CGDirectDisplayID: Double]
    ) -> DisplayInfo? {
        guard let currentCGMode = CGDisplayCopyDisplayMode(displayID) else { return nil }

        let mirrorOf = CGDisplayMirrorsDisplay(displayID)
        let isMirrored = mirrorOf != kCGNullDirectDisplay

        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let allModes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() }
            .map { cgMode in
                DisplayMode(
                    width: cgMode.width,
                    height: cgMode.height,
                    pixelWidth: cgMode.pixelWidth,
                    pixelHeight: cgMode.pixelHeight,
                    refreshRate: cgMode.refreshRate,
                    isHiDPI: cgMode.pixelWidth != cgMode.width
                )
            }
            .sorted { ($0.width, $0.height, $0.refreshRate) > ($1.width, $1.height, $1.refreshRate) }

        let currentMode = DisplayMode(
            width: currentCGMode.width,
            height: currentCGMode.height,
            pixelWidth: currentCGMode.pixelWidth,
            pixelHeight: currentCGMode.pixelHeight,
            refreshRate: currentCGMode.refreshRate,
            isHiDPI: currentCGMode.pixelWidth != currentCGMode.width
        )

        return DisplayInfo(
            id: displayID,
            uuid: uuid(for: displayID),
            name: nameMap[displayID] ?? "Display \(displayID)",
            currentMode: currentMode,
            availableModes: allModes,
            isVirtual: false,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            isMain: CGDisplayIsMain(displayID) != 0,
            isMirrored: isMirrored,
            mirroredToDisplayID: mirrorOf,
            physicalSize: CGDisplayScreenSize(displayID),
            backingScaleFactor: scaleMap[displayID] ?? 1.0
        )
    }

    /// Stable per-display UUID string usable across launches and reboots.
    /// `CGDirectDisplayID` itself is reassigned on topology changes; this UUID is not.
    func uuid(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    // MARK: - Change Resolution

    func setDisplayMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID) throws {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            throw DisplayError.modesUnavailable
        }

        guard let targetMode = modes.first(where: {
            $0.width == mode.width &&
            $0.height == mode.height &&
            $0.pixelWidth == mode.pixelWidth &&
            abs($0.refreshRate - mode.refreshRate) < 0.1 &&
            $0.isUsableForDesktopGUI()
        }) else {
            throw DisplayError.modeNotFound
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw DisplayError.configurationFailed("Could not begin configuration")
        }

        let configureErr = CGConfigureDisplayWithDisplayMode(config, displayID, targetMode, nil)
        guard configureErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.configurationFailed("Configure failed: \(configureErr)")
        }

        let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.configurationFailed("Complete failed: \(completeErr)")
        }
    }

    // MARK: - Set Main Display

    func setMainDisplay(_ displayID: CGDirectDisplayID) throws {
        let currentMain = CGMainDisplayID()
        guard displayID != currentMain else { return }

        let targetBounds = CGDisplayBounds(displayID)
        let offsetX = Int32(targetBounds.origin.x)
        let offsetY = Int32(targetBounds.origin.y)

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw DisplayError.configurationFailed("Could not begin configuration")
        }

        for id in ids {
            let bounds = CGDisplayBounds(id)
            let newX = Int32(bounds.origin.x) - offsetX
            let newY = Int32(bounds.origin.y) - offsetY
            CGConfigureDisplayOrigin(config, id, newX, newY)
        }

        let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.configurationFailed("Failed to set main display")
        }
    }

    // MARK: - Enable / Disable Display (via mirroring)

    /// Disables a display by mirroring it to another active display.
    /// Uses .forSession so mirroring auto-reverts on logout/reboot as a safety net.
    func disableDisplay(_ displayID: CGDirectDisplayID, allDisplays: [DisplayInfo]) throws {
        let mainDisplay = CGMainDisplayID()
        let isMain = displayID == mainDisplay

        // Find the best next active display: prefer built-in, then physical, then virtual
        let candidates = allDisplays.filter { $0.isActive && $0.id != displayID }
        let otherActive = candidates.first(where: { $0.isBuiltIn })
            ?? candidates.first(where: { !$0.isVirtual })
            ?? candidates.first

        if isMain {
            guard let newMain = otherActive else {
                throw DisplayError.configurationFailed("No other display available to transfer main")
            }

            // Step 1: Transfer main to the other display
            try setMainDisplay(newMain.id)

            // Step 2: Now mirror the old main (no longer main) to the new main
            var config2: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config2) == .success else {
                throw DisplayError.configurationFailed("Could not begin mirror configuration")
            }

            let mirrorErr = CGConfigureDisplayMirrorOfDisplay(config2, displayID, newMain.id)
            guard mirrorErr == .success else {
                CGCancelDisplayConfiguration(config2)
                throw DisplayError.configurationFailed("Mirror failed: \(mirrorErr)")
            }

            // .forSession: auto-reverts on logout/reboot if app crashes while display is disabled
            let completeErr = CGCompleteDisplayConfiguration(config2, .forSession)
            guard completeErr == .success else {
                CGCancelDisplayConfiguration(config2)
                throw DisplayError.configurationFailed("Failed to disable main display")
            }
        } else {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else {
                throw DisplayError.configurationFailed("Could not begin configuration")
            }

            let err = CGConfigureDisplayMirrorOfDisplay(config, displayID, mainDisplay)
            guard err == .success else {
                CGCancelDisplayConfiguration(config)
                throw DisplayError.configurationFailed("Mirror configuration failed: \(err)")
            }

            let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
            guard completeErr == .success else {
                CGCancelDisplayConfiguration(config)
                throw DisplayError.configurationFailed("Complete failed: \(completeErr)")
            }
        }
    }

    /// Enables a display by removing its mirror relationship
    func enableDisplay(_ displayID: CGDirectDisplayID) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw DisplayError.configurationFailed("Could not begin configuration")
        }

        let err = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.configurationFailed("Unmirror configuration failed: \(err)")
        }

        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        guard completeErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.configurationFailed("Complete failed: \(completeErr)")
        }
    }

    /// Counts currently active (non-mirrored) displays
    func activeDisplayCount() -> Int {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        return Int(count)
    }

    // MARK: - ColorSync Deadlock Fix

    /// Assigns sRGB profiles to duplicate physical displays to prevent colorsync deadlock.
    /// macOS Sequoia bug: identical monitors (same EDID) cause colorsync.useragent
    /// to deadlock when both try to rewrite their ICC profile simultaneously.
    /// Assigning a known profile via ColorSync API breaks the cycle without admin privileges.
    func fixDuplicateDisplayProfiles(displays: [DisplayInfo]) {
        // Find physical displays with duplicate names (identical monitors)
        let physicalDisplays = displays.filter { !$0.isVirtual && !$0.isMirrored }
        let nameCount = physicalDisplays.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        let duplicateNames = nameCount.filter { $0.value > 1 }.map { $0.key }
        guard !duplicateNames.isEmpty else { return }

        let duplicateIDs = physicalDisplays
            .filter { duplicateNames.contains($0.name) }
            .map { $0.id }

        for displayID in duplicateIDs {
            assignSRGBProfile(to: displayID)
        }
        logger.info("Applied sRGB profiles to \(duplicateIDs.count) duplicate displays")
    }

    private func assignSRGBProfile(to displayID: CGDirectDisplayID) {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return }
        guard let profileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue() else { return }
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue() else { return }

        let srgbPath = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
        let profileURL = URL(fileURLWithPath: srgbPath) as CFURL

        let profileInfo: [CFString: Any] = [
            profileKey: profileURL
        ]

        ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            cfUUID,
            profileInfo as CFDictionary
        )
    }

    // MARK: - Live Updates

    func registerDisplayChangeCallback(
        _ callback: @escaping @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void
    ) -> DisplayChangeToken {
        let token = DisplayChangeToken(callback: callback)
        token.register()
        return token
    }

    /// Registers for NSApplication screen change notifications as a fallback
    /// (CGDisplayReconfigurationCallback may stop firing on macOS Tahoe+)
    func registerScreenChangeNotification(_ handler: @escaping @MainActor () -> Void) -> Any {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }
}

// MARK: - Supporting Types

enum DisplayError: LocalizedError {
    case modesUnavailable
    case modeNotFound
    case configurationFailed(String)
    case virtualDisplayUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modesUnavailable: return "Could not retrieve display modes."
        case .modeNotFound: return "The requested display mode was not found."
        case .configurationFailed(let msg): return "Display configuration failed: \(msg)"
        case .virtualDisplayUnavailable(let msg): return "Virtual display unavailable: \(msg)"
        }
    }
}

/// Token that manages a CGDisplayReconfigurationCallback registration.
/// Uses passRetained to prevent use-after-free race conditions.
final class DisplayChangeToken: @unchecked Sendable {
    private let callback: @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void
    private var isRegistered = false

    private static let cCallback: CGDisplayReconfigurationCallBack = { displayID, flags, context in
        guard let context else { return }
        let token = Unmanaged<DisplayChangeToken>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            token.callback(displayID, flags)
        }
    }

    init(callback: @escaping @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void) {
        self.callback = callback
    }

    func register() {
        guard !isRegistered else { return }
        // passRetained: prevents deallocation while callback is registered
        CGDisplayRegisterReconfigurationCallback(Self.cCallback, Unmanaged.passRetained(self).toOpaque())
        isRegistered = true
    }

    deinit {
        if isRegistered {
            let ptr = Unmanaged.passUnretained(self).toOpaque()
            CGDisplayRemoveReconfigurationCallback(Self.cCallback, ptr)
            // Balance the passRetained from register()
            Unmanaged<DisplayChangeToken>.fromOpaque(ptr).release()
        }
    }
}
