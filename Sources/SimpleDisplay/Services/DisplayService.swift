import AppKit
import ColorSync
import CoreGraphics
import Foundation
import VirtualDisplayBridge
import os

private let logger = Logger(subsystem: "app.simpledisplay", category: "DisplayService")

@MainActor
final class DisplayService {

    /// Last-known friendly name per display UUID. A disabled display drops out
    /// of `NSScreen.screens`, so without this cache its row would revert to a
    /// generic "Display N" label while disabled.
    private var nameCache: [String: String] = [:]

    // MARK: - Enumerate Displays

    /// Fetches every display in `CGGetOnlineDisplayList`. A display disabled via
    /// `CGSConfigureDisplayEnabled` normally drops out of that list entirely, so
    /// it is *not* returned here; the view model keeps a ghost row for it.
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

    /// Connected physical displays that are off at the window-server level.
    /// They are absent from `CGGetOnlineDisplayList`, and the view model only
    /// shows them while it holds a ghost row; a display whose ghost was lost
    /// (two identical monitors persisted under one ID, a monitor power cycle)
    /// would otherwise stay dark with no way to turn it back on.
    func fetchDisabledDisplays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGSGetDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { displayID in
            // Vendor 0 is a slot left by an unplugged display; an offline
            // built-in display is a closed lid.
            guard CGDisplayIsOnline(displayID) == 0,
                  CGDisplayIsBuiltin(displayID) == 0,
                  CGDisplayVendorNumber(displayID) != 0
            else { return nil }
            // CGDisplayCreateUUIDFromDisplayID returns nil for a disabled
            // display (seen on macOS 26), so the row may only have its ID.
            let displayUUID = uuid(for: displayID)
            let name = displayUUID.flatMap { nameCache[$0] } ?? "Display \(displayID)"
            return .disabledPlaceholder(id: displayID, uuid: displayUUID, name: name)
        }
    }

    private func buildDisplayInfo(
        displayID: CGDirectDisplayID,
        nameMap: [CGDirectDisplayID: String],
        scaleMap: [CGDirectDisplayID: Double]
    ) -> DisplayInfo? {
        // A display disabled via CGSConfigureDisplayEnabled normally leaves the
        // online list altogether. Should one still be listed, CGDisplayIsActive
        // is what tells it apart from an active display.
        // A mirror slave is not "active" for CoreGraphics (in a hardware mirror
        // set only the primary is), yet it is on and showing content, so it
        // counts as enabled here. Mirroring is tracked separately.
        let mirrorOf = CGDisplayMirrorsDisplay(displayID)
        let isEnabled = CGDisplayIsActive(displayID) != 0 || mirrorOf != kCGNullDirectDisplay

        let displayUUID = uuid(for: displayID)

        // Resolve a friendly name. A disabled display is absent from
        // NSScreen.screens, so fall back to the last name we saw for this UUID.
        let resolvedName: String
        if let liveName = nameMap[displayID] {
            resolvedName = liveName
            if let displayUUID { nameCache[displayUUID] = liveName }
        } else if let displayUUID, let cached = nameCache[displayUUID] {
            resolvedName = cached
        } else {
            resolvedName = "Display \(displayID)"
        }

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

        // CGDisplayCopyDisplayMode can return nil for a disabled display. Keep
        // the row alive with a placeholder so the user can re-enable it; an
        // active display with no mode is genuinely unusable, so drop it.
        let currentMode: DisplayMode
        if let currentCGMode = CGDisplayCopyDisplayMode(displayID) {
            currentMode = DisplayMode(
                width: currentCGMode.width,
                height: currentCGMode.height,
                pixelWidth: currentCGMode.pixelWidth,
                pixelHeight: currentCGMode.pixelHeight,
                refreshRate: currentCGMode.refreshRate,
                isHiDPI: currentCGMode.pixelWidth != currentCGMode.width
            )
        } else if !isEnabled, let fallback = allModes.first {
            currentMode = fallback
        } else if !isEnabled {
            currentMode = DisplayMode(width: 0, height: 0, pixelWidth: 0, pixelHeight: 0, refreshRate: 0, isHiDPI: false)
        } else {
            return nil
        }

        return DisplayInfo(
            id: displayID,
            uuid: displayUUID,
            name: resolvedName,
            currentMode: currentMode,
            availableModes: allModes,
            isVirtual: false,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            isMain: CGDisplayIsMain(displayID) != 0,
            isEnabled: isEnabled,
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

    /// Resolves a display UUID back to the `CGDirectDisplayID` macOS assigns it
    /// right now, or nil when the window server does not know the display
    /// (unplugged, or never seen this session). Anything that outlives a
    /// reconfiguration (ghost rows, mode restore) must go through this instead
    /// of reusing an old ID.
    func displayID(forUUID uuidString: String) -> CGDirectDisplayID? {
        guard let cfUUID = CFUUIDCreateFromString(nil, uuidString as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(cfUUID)
        return id == kCGNullDirectDisplay ? nil : id
    }

    // MARK: - Change Resolution

    /// `permanently` writes the whole current configuration to macOS's display
    /// preferences, mirror sets included: a permanent commit while a display is
    /// mirrored makes macOS re-create that mirror on its own the next time the
    /// same set of displays shows up (seen on the test VM). Callers pass false
    /// while any mirror is active.
    func setDisplayMode(_ mode: DisplayMode, for displayID: CGDirectDisplayID, permanently: Bool = true) throws {
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

        let completeErr = CGCompleteDisplayConfiguration(config, permanently ? .permanently : .forSession)
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

    // MARK: - Enable / Disable Display

    /// Disables a display for real via the private `CGSConfigureDisplayEnabled`
    /// API — the display goes dark and leaves the desktop entirely, rather than
    /// mirroring another screen. If the target is the current main display, main
    /// is first transferred to another active display so macOS doesn't pick one
    /// arbitrarily.
    ///
    /// Callers must dissolve any mirror set the display takes part in first
    /// and let the topology settle: chaining display configurations without a
    /// settle in between has been seen to leave the window server with zero
    /// active displays (see docs/real-disable-vm).
    func disableDisplay(_ displayID: CGDirectDisplayID, allDisplays: [DisplayInfo]) throws {
        if displayID == CGMainDisplayID() {
            guard let newMain = bestNewMain(excluding: displayID, in: allDisplays) else {
                throw DisplayError.configurationFailed("No other display available to transfer main")
            }
            try setMainDisplay(newMain)
        }
        try setDisplayEnabled(displayID, enabled: false)
    }

    /// Best candidate to take over main: prefer built-in, then physical, then
    /// virtual. A mirror slave cannot be main.
    func bestNewMain(excluding displayID: CGDirectDisplayID, in allDisplays: [DisplayInfo]) -> CGDirectDisplayID? {
        let candidates = allDisplays.filter { $0.isActive && !$0.isMirrored && $0.id != displayID }
        return (candidates.first(where: { $0.isBuiltIn })
            ?? candidates.first(where: { !$0.isVirtual })
            ?? candidates.first)?.id
    }

    /// Re-enables a previously disabled display.
    func enableDisplay(_ displayID: CGDirectDisplayID) throws {
        try setDisplayEnabled(displayID, enabled: true)
    }

    /// Toggles a display's active state through a CG configuration transaction.
    /// Uses `.forSession` so the change auto-reverts on logout/reboot if the app
    /// crashes mid-operation; the persisted-state restore on launch is what makes
    /// the user's choice durable across reboots.
    private func setDisplayEnabled(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw DisplayError.configurationFailed("Could not begin configuration")
        }

        let err = CGSConfigureDisplayEnabled(config, displayID, enabled)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.configurationFailed("CGSConfigureDisplayEnabled failed: \(err.rawValue)")
        }

        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        guard completeErr == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.configurationFailed("Complete failed: \(completeErr)")
        }
    }

    // MARK: - Mirroring

    /// Mirrors `displayID` onto `target`. Mirroring is a separate, reversible
    /// state from disabling: the panel stays on and shows a copy of another
    /// desktop. `displayID` must not be main when this is called: the caller
    /// transfers main first and lets the topology settle, because doing both in
    /// back-to-back transactions left the window server with zero displays.
    func mirrorDisplay(_ displayID: CGDirectDisplayID, onto target: CGDirectDisplayID) throws {
        guard target != displayID else {
            throw DisplayError.configurationFailed("A display cannot mirror itself")
        }
        guard displayID != CGMainDisplayID() else {
            throw DisplayError.configurationFailed("Transfer main away from the display before mirroring it")
        }
        try setMirror(of: displayID, to: target)
    }

    /// Stops mirroring `displayID`; it gets its own desktop back.
    func unmirrorDisplay(_ displayID: CGDirectDisplayID) throws {
        try setMirror(of: displayID, to: kCGNullDirectDisplay)
    }

    /// `.forSession` so a crash mid-operation reverts on logout; the persisted
    /// state restore on launch is what makes the choice durable.
    private func setMirror(of displayID: CGDirectDisplayID, to target: CGDirectDisplayID) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw DisplayError.configurationFailed("Could not begin configuration")
        }
        let err = CGConfigureDisplayMirrorOfDisplay(config, displayID, target)
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
        let physicalDisplays = displays.filter { !$0.isVirtual && $0.isActive && !$0.isMirrored }
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
