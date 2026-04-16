import ColorSync
import CoreGraphics
import Foundation
import os
import VirtualDisplayBridge

private let logger = Logger(subsystem: "app.simpledisplay", category: "VirtualDisplayService")

@MainActor
final class VirtualDisplayService {

    private var activeDisplays: [CGDirectDisplayID: VirtualDisplayWrapper] = [:]
    private var displayConfigMap: [CGDirectDisplayID: UUID] = [:]
    var onDisplayTerminated: ((CGDirectDisplayID) -> Void)?

    private let persistenceKey = "com.simpledisplay.virtualDisplays"

    // MARK: - Config

    struct VirtualDisplayConfig: Codable {
        var configID: UUID
        var name: String
        var width: Int
        var height: Int
        var refreshRate: Double
        var hiDPI: Bool
        var physicalWidthMM: Double
        var physicalHeightMM: Double
        var vendorID: UInt32
        var productID: UInt32

        /// Maximum supported refresh rate for CGVirtualDisplay
        static let maxRefreshRate: Double = 60.0
        /// Minimum resolution dimension
        static let minDimension: Int = 100
        /// Maximum resolution dimension
        static let maxDimension: Int = 8192

        init(
            configID: UUID = UUID(),
            name: String = "Virtual Display",
            width: Int = 1920,
            height: Int = 1080,
            refreshRate: Double = 60.0,
            hiDPI: Bool = false,
            physicalWidthMM: Double = 527,
            physicalHeightMM: Double = 296,
            vendorID: UInt32 = 0x1234,
            productID: UInt32 = 0x5678
        ) {
            self.configID = configID
            self.name = name
            self.width = width.clamped(to: Self.minDimension...Self.maxDimension)
            self.height = height.clamped(to: Self.minDimension...Self.maxDimension)
            self.refreshRate = min(refreshRate, Self.maxRefreshRate)
            self.hiDPI = hiDPI
            self.physicalWidthMM = physicalWidthMM
            self.physicalHeightMM = physicalHeightMM
            self.vendorID = vendorID
            self.productID = productID
        }

        // Backward-compatible decoding: old configs without configID get a new UUID
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            configID = try container.decodeIfPresent(UUID.self, forKey: .configID) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Virtual Display"
            let rawWidth = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1920
            let rawHeight = try container.decodeIfPresent(Int.self, forKey: .height) ?? 1080
            width = rawWidth.clamped(to: Self.minDimension...Self.maxDimension)
            height = rawHeight.clamped(to: Self.minDimension...Self.maxDimension)
            let rawRefresh = try container.decodeIfPresent(Double.self, forKey: .refreshRate) ?? 60.0
            refreshRate = min(rawRefresh, Self.maxRefreshRate)
            hiDPI = try container.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? false
            physicalWidthMM = try container.decodeIfPresent(Double.self, forKey: .physicalWidthMM) ?? 527
            physicalHeightMM = try container.decodeIfPresent(Double.self, forKey: .physicalHeightMM) ?? 296
            vendorID = try container.decodeIfPresent(UInt32.self, forKey: .vendorID) ?? 0x1234
            productID = try container.decodeIfPresent(UInt32.self, forKey: .productID) ?? 0x5678
        }
    }

    // MARK: - Restore on Launch

    func restoreSavedDisplays() -> [(id: CGDirectDisplayID, name: String)] {
        let configs = loadConfigs()
        var restored: [(id: CGDirectDisplayID, name: String)] = []
        for config in configs {
            do {
                let id = try createVirtualDisplay(config: config, persist: false)
                restored.append((id: id, name: config.name))
            } catch {
                logger.warning("Failed to restore virtual display '\(config.name)': \(error.localizedDescription)")
            }
        }
        // Re-save to persist stable configIDs (migrates old configs without UUIDs)
        writeConfigs(configs)
        return restored
    }

    // MARK: - Create

    @discardableResult
    func createVirtualDisplay(config: VirtualDisplayConfig, persist: Bool = true) throws -> CGDirectDisplayID {
        let serial = UInt32.random(in: 1...UInt32.max)

        // Use large maxPixels so we can reconfigure later without recreating
        let maxW: UInt = 8192
        let maxH: UInt = 8192

        let wrapper = VirtualDisplayWrapper.create(
            withName: config.name,
            vendorID: config.vendorID,
            productID: config.productID,
            serialNumber: serial,
            sizeInMillimeters: CGSize(width: config.physicalWidthMM, height: config.physicalHeightMM),
            maxPixelsWide: maxW,
            maxPixelsHigh: maxH,
            terminationQueue: .main,
            terminationHandler: { [weak self] in
                Task { @MainActor in
                    self?.pruneTerminatedDisplays()
                }
            }
        )

        guard let wrapper, wrapper.displayID != 0 else {
            throw DisplayError.virtualDisplayUnavailable(
                "CGVirtualDisplay creation failed. This may require the app to be signed " +
                "with the virtual-display-service entitlement, or may not be supported on this system."
            )
        }

        let displayID = wrapper.displayID

        // Clamp refresh rate to safe maximum
        let safeRefreshRate = min(config.refreshRate, VirtualDisplayConfig.maxRefreshRate)

        let applied = wrapper.applyWidth(
            UInt(config.width),
            height: UInt(config.height),
            refreshRate: safeRefreshRate,
            hiDPI: config.hiDPI
        )
        guard applied else {
            throw DisplayError.virtualDisplayUnavailable("Failed to apply initial display settings.")
        }

        activeDisplays[displayID] = wrapper
        displayConfigMap[displayID] = config.configID

        // Assign sRGB profile to reduce colorsync CPU churn
        assignSRGBProfile(to: displayID)

        if persist {
            saveConfig(config)
        }

        logger.info("Created virtual display '\(config.name)' (\(config.width)x\(config.height)) → ID \(displayID)")
        return displayID
    }

    // MARK: - Reconfigure (without destroying)

    func reconfigureDisplay(id: CGDirectDisplayID, width: Int, height: Int, refreshRate: Double, hiDPI: Bool) throws {
        guard let wrapper = activeDisplays[id] else {
            throw DisplayError.virtualDisplayUnavailable("Virtual display not found.")
        }

        let safeWidth = width.clamped(to: VirtualDisplayConfig.minDimension...VirtualDisplayConfig.maxDimension)
        let safeHeight = height.clamped(to: VirtualDisplayConfig.minDimension...VirtualDisplayConfig.maxDimension)
        let safeRefreshRate = min(refreshRate, VirtualDisplayConfig.maxRefreshRate)

        let applied = wrapper.applyWidth(
            UInt(safeWidth),
            height: UInt(safeHeight),
            refreshRate: safeRefreshRate,
            hiDPI: hiDPI
        )
        guard applied else {
            throw DisplayError.virtualDisplayUnavailable("Failed to apply new settings.")
        }

        updatePersistedConfig(id: id, width: safeWidth, height: safeHeight, refreshRate: safeRefreshRate, hiDPI: hiDPI)
    }

    private func updatePersistedConfig(id: CGDirectDisplayID, width: Int, height: Int, refreshRate: Double, hiDPI: Bool) {
        guard let configID = displayConfigMap[id] else { return }
        var configs = loadConfigs()
        if let idx = configs.firstIndex(where: { $0.configID == configID }) {
            configs[idx].width = width
            configs[idx].height = height
            configs[idx].refreshRate = refreshRate
            configs[idx].hiDPI = hiDPI
        }
        writeConfigs(configs)
    }

    // MARK: - Remove

    func removeVirtualDisplay(id: CGDirectDisplayID) {
        let name = displayConfigMap[id].flatMap { configID in
            loadConfigs().first { $0.configID == configID }?.name
        }
        unregisterColorSyncDevice(for: id)
        if let wrapper = activeDisplays.removeValue(forKey: id) {
            wrapper.invalidate()
        }
        removeConfigMatching(id: id)
        removeICCProfile(for: id)
        logger.info("Removed virtual display\(name.map { " '\($0)'" } ?? "") (ID \(id))")
    }

    func removeAll() {
        for (id, wrapper) in activeDisplays {
            unregisterColorSyncDevice(for: id)
            wrapper.invalidate()
            removeICCProfile(for: id)
        }
        activeDisplays.removeAll()
        displayConfigMap.removeAll()
        clearConfigs()
    }

    var activeVirtualDisplayIDs: Set<CGDirectDisplayID> {
        Set(activeDisplays.keys)
    }

    // MARK: - Color Profile

    /// Unregister a virtual display from the ColorSync device registry.
    /// Without this, removed displays leave ghost entries in the registry
    /// that accumulate over time and cause ColorSync daemons to loop.
    private func unregisterColorSyncDevice(for displayID: CGDirectDisplayID) {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return }
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue() else { return }
        if ColorSyncUnregisterDevice(deviceClass, cfUUID) {
            logger.info("Unregistered ColorSync device for display \(displayID)")
        }
    }

    /// Assign sRGB profile to a virtual display to prevent colorsync CPU loop.
    /// macOS generates custom profiles for virtual displays and continuously validates them,
    /// causing high CPU. Assigning a known system profile (sRGB) stops this.
    private func assignSRGBProfile(to displayID: CGDirectDisplayID) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return }
        guard let profileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue() else { return }
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue() else { return }

        let srgbPath = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
        let profileURL = URL(fileURLWithPath: srgbPath) as CFURL

        let profileInfo: [CFString: Any] = [
            profileKey: profileURL
        ]

        ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            uuid,
            profileInfo as CFDictionary
        )
    }

    /// Remove orphaned ICC profile for a virtual display.
    /// Files in /Library/ColorSync/Profiles/Displays are owned by root,
    /// so we first try without privileges, then escalate via osascript if needed.
    private func removeICCProfile(for displayID: CGDirectDisplayID) {
        let profilesDir = "/Library/ColorSync/Profiles/Displays"
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return }
        let uuidString = CFUUIDCreateString(nil, cfUUID) as String? ?? ""
        guard !uuidString.isEmpty else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else { return }
        var pathsToRemove: [String] = []
        for file in files where file.hasSuffix(".icc") && file.contains(uuidString) {
            pathsToRemove.append("\(profilesDir)/\(file)")
        }
        guard !pathsToRemove.isEmpty else { return }

        // Try unprivileged removal first
        var needsEscalation: [String] = []
        for path in pathsToRemove {
            do {
                try FileManager.default.removeItem(atPath: path)
                logger.info("Cleaned up ICC profile: \(path)")
            } catch {
                needsEscalation.append(path)
            }
        }

        guard !needsEscalation.isEmpty else { return }

        // Escalate to root via osascript — shows the standard macOS password dialog
        let escaped = needsEscalation.map { "\\\"" + $0 + "\\\"" }.joined(separator: " ")
        let script = "do shell script \"rm -f \(escaped)\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            logger.warning("Failed to remove ICC profiles with admin privileges: \(error)")
        } else {
            logger.info("Removed \(needsEscalation.count) ICC profile(s) with admin privileges")
        }
    }

    // MARK: - Persistence

    private func saveConfig(_ config: VirtualDisplayConfig) {
        var configs = loadConfigs()
        configs.append(config)
        writeConfigs(configs)
    }

    private func removeConfigMatching(id: CGDirectDisplayID) {
        guard let configID = displayConfigMap.removeValue(forKey: id) else { return }
        var configs = loadConfigs()
        configs.removeAll { $0.configID == configID }
        writeConfigs(configs)
    }

    private func loadConfigs() -> [VirtualDisplayConfig] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return [] }
        do {
            return try JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
        } catch {
            logger.error("Failed to decode virtual display configs: \(error.localizedDescription)")
            return []
        }
    }

    private func writeConfigs(_ configs: [VirtualDisplayConfig]) {
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to encode virtual display configs: \(error.localizedDescription)")
        }
    }

    private func clearConfigs() {
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }

    // MARK: - Private

    private func pruneTerminatedDisplays() {
        let toRemove = activeDisplays.filter { $0.value.displayID == 0 }
        for (id, _) in toRemove {
            unregisterColorSyncDevice(for: id)
            activeDisplays.removeValue(forKey: id)
            displayConfigMap.removeValue(forKey: id)
            onDisplayTerminated?(id)
        }
    }
}

// MARK: - Helpers

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
