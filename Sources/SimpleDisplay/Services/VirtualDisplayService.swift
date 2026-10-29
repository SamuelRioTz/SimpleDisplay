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

    // MARK: - Stable serial numbers (the real ColorSync fix)
    //
    // ColorSync identifies a display by vendorID/productID/serialNumber. With a
    // RANDOM serial every CGVirtualDisplay is a brand-new device: macOS generates a
    // fresh .icc in /Library/ColorSync/Profiles/Displays (root-owned, we can't
    // delete it) and re-validates the growing pile forever — that is the
    // colorsyncd/displayservices CPU loop and the "56 profiles after 100 displays"
    // leak. Reusing a small pool of STABLE serials makes a virtual display the
    // same device every time, so macOS reuses its profile: the profile count is
    // bounded by the max number of simultaneous displays.
    //
    // The serial is persisted with the display's config, so a display keeps its
    // identity across launches even when another one was removed in between.
    // Identity matters beyond ColorSync: macOS also remembers per-identity mode
    // preferences, and a display that inherited another one's slot after a
    // relaunch came back in the other one's mode (1600x900 HiDPI -> 1280x720,
    // see docs/real-disable-vm).
    private var usedSerials: Set<UInt32> = []
    private var serialByDisplay: [CGDirectDisplayID: UInt32] = [:]
    private static let maxSerialSlots: UInt32 = 4095

    /// A config that already owns a serial keeps it; otherwise the lowest slot
    /// that is neither live nor owned by another persisted config.
    private func allocateSerial(preferred: UInt32?) -> UInt32 {
        if let preferred, (1..<Self.maxSerialSlots).contains(preferred), !usedSerials.contains(preferred) {
            usedSerials.insert(preferred)
            return preferred
        }
        let reserved = Set(loadConfigs().compactMap(\.serial))
        var serial: UInt32 = 1
        while (usedSerials.contains(serial) || reserved.contains(serial)) && serial < Self.maxSerialSlots {
            serial += 1
        }
        usedSerials.insert(serial)
        return serial
    }

    /// The serial slot a live virtual display was created with.
    func serial(for displayID: CGDirectDisplayID) -> UInt32? {
        serialByDisplay[displayID]
    }

    /// The saved config of a live virtual display.
    func config(for displayID: CGDirectDisplayID) -> VirtualDisplayConfig? {
        guard let configID = displayConfigMap[displayID] else { return nil }
        return loadConfigs().first { $0.configID == configID }
    }

    private func releaseSerial(for displayID: CGDirectDisplayID) {
        if let serial = serialByDisplay.removeValue(forKey: displayID) {
            usedSerials.remove(serial)
        }
    }

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
        /// Serial slot this display was created with (see `allocateSerial`).
        /// Nil until first created; optional for configs saved by older versions.
        var serial: UInt32?
        /// The mode the user picked among those macOS derives from the panel size
        /// (`width` x `height`, `hiDPI`): a "zoom" level or a smaller resolution.
        /// Nil means the panel's own mode. Re-applied whenever the topology
        /// changes, because macOS keeps a remembered mode per identity and per
        /// set of connected displays.
        var modeWidth: Int?
        var modeHeight: Int?
        var modeHiDPI: Bool?

        /// Highest refresh rate a virtual display may be configured with.
        /// `CGVirtualDisplay` honours the requested rate (verified up to ~488 Hz on
        /// an M1 Mac mini); 240 is the intended ceiling here.
        static let maxRefreshRate: Double = 240.0
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
            productID: UInt32 = 0x5678,
            serial: UInt32? = nil
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
            self.serial = serial
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
            serial = try container.decodeIfPresent(UInt32.self, forKey: .serial)
            modeWidth = try container.decodeIfPresent(Int.self, forKey: .modeWidth)
            modeHeight = try container.decodeIfPresent(Int.self, forKey: .modeHeight)
            modeHiDPI = try container.decodeIfPresent(Bool.self, forKey: .modeHiDPI)
        }

        /// The mode this display should be running: the chosen one, else the panel's.
        var wantedMode: (width: Int, height: Int, hiDPI: Bool) {
            (modeWidth ?? width, modeHeight ?? height, modeHiDPI ?? hiDPI)
        }
    }

    // MARK: - Restore on Launch

    func restoreSavedDisplays() -> [(id: CGDirectDisplayID, name: String)] {
        var configs = loadConfigs()
        var restored: [(id: CGDirectDisplayID, name: String)] = []
        for idx in configs.indices {
            do {
                let id = try createVirtualDisplay(config: configs[idx], persist: false)
                restored.append((id: id, name: configs[idx].name))
                // Configs saved by older versions have no serial: pin the one
                // they got so it stays theirs from now on.
                configs[idx].serial = serialByDisplay[id]
            } catch {
                logger.warning("Failed to restore virtual display '\(configs[idx].name)': \(error.localizedDescription)")
            }
        }
        // Re-save to persist stable configIDs and serials (migrates old configs)
        writeConfigs(configs)
        return restored
    }

    // MARK: - Create

    @discardableResult
    func createVirtualDisplay(config: VirtualDisplayConfig, persist: Bool = true) throws -> CGDirectDisplayID {
        // Stable serial (see `allocateSerial`), never random. The config keeps it.
        var config = config
        let serial = allocateSerial(preferred: config.serial)
        config.serial = serial

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
            usedSerials.remove(serial)
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
            wrapper.invalidate()
            usedSerials.remove(serial)
            throw DisplayError.virtualDisplayUnavailable("Failed to apply initial display settings.")
        }

        activeDisplays[displayID] = wrapper
        displayConfigMap[displayID] = config.configID
        serialByDisplay[displayID] = serial


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
            // A new panel size derives a new mode list; the old pick is meaningless.
            configs[idx].modeWidth = nil
            configs[idx].modeHeight = nil
            configs[idx].modeHiDPI = nil
        }
        writeConfigs(configs)
    }

    /// Remembers the mode the user picked for a live virtual display, so it is
    /// re-applied after topology changes and on the next launch.
    func setChosenMode(id: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool) {
        guard let configID = displayConfigMap[id] else { return }
        var configs = loadConfigs()
        guard let idx = configs.firstIndex(where: { $0.configID == configID }) else { return }
        let c = configs[idx]
        if width == c.width && height == c.height && hiDPI == c.hiDPI {
            configs[idx].modeWidth = nil; configs[idx].modeHeight = nil; configs[idx].modeHiDPI = nil
        } else {
            configs[idx].modeWidth = width; configs[idx].modeHeight = height; configs[idx].modeHiDPI = hiDPI
        }
        writeConfigs(configs)
    }

    // MARK: - Remove

    func removeVirtualDisplay(id: CGDirectDisplayID) {
        let name = displayConfigMap[id].flatMap { configID in
            loadConfigs().first { $0.configID == configID }?.name
        }
        // No ColorSync cleanup on purpose:
        // - ColorSyncUnregisterDevice -> AuthorizationCreate does synchronous XPC that
        //   can hang forever and froze the whole app (seen on macOS 26), and queues a
        //   password dialog otherwise.
        // - Deleting the display's .icc (root-owned anyway) only forces macOS to
        //   regenerate it on the next create. With stable serials (`allocateSerial`)
        //   the same slot reuses the same profile, so nothing accumulates.
        if let wrapper = activeDisplays.removeValue(forKey: id) {
            wrapper.invalidate()
        }
        releaseSerial(for: id)
        removeConfigMatching(id: id)
        logger.info("Removed virtual display\(name.map { " '\($0)'" } ?? "") (ID \(id))")
    }

    func removeAll() {
        for wrapper in activeDisplays.values {
            wrapper.invalidate()
        }
        activeDisplays.removeAll()
        displayConfigMap.removeAll()
        usedSerials.removeAll()
        serialByDisplay.removeAll()
        clearConfigs()
    }

    var activeVirtualDisplayIDs: Set<CGDirectDisplayID> {
        Set(activeDisplays.keys)
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
            activeDisplays.removeValue(forKey: id)
            displayConfigMap.removeValue(forKey: id)
            releaseSerial(for: id)
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
