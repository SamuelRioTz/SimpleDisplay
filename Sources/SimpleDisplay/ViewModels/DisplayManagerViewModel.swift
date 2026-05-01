import AppKit
import CoreGraphics
import Foundation
import Observation
import os
import SimpleDisplayCore

private let logger = Logger(subsystem: "app.simpledisplay", category: "ViewModel")

// MARK: - Navigation State

enum NavigationState: Equatable {
    case displayList
    case settings
    case addVirtualDisplay
    case configuringDisplay(CGDirectDisplayID)
}

@MainActor
@Observable
final class DisplayManagerViewModel {
    var displays: [DisplayInfo] = []
    var virtualDisplayIDs: Set<CGDirectDisplayID> = []
    /// Custom names for virtual displays (macOS assigns generic names like "Display 25")
    var virtualDisplayNames: [CGDirectDisplayID: String] = [:]
    var errorMessage: String?
    var isLoading: Bool = false

    /// True while an async display operation is in progress
    var isBusy: Bool = false
    /// Human-readable status of the current operation
    var busyMessage: String?

    var navigationState: NavigationState = .displayList
    /// True briefly during navigation transitions to prevent rapid clicks
    var isNavigating: Bool = false
    var newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig()

    /// Reference to locale manager for localized messages
    var locale: LocaleManager?

    private let displayService = DisplayService()
    private let virtualService = VirtualDisplayService()
    private let statePersistence = DisplayStatePersistence()
    private var changeToken: DisplayChangeToken?
    private var screenChangeObserver: Any?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var debounceRefreshTask: Task<Void, Never>?

    /// Tracks displays that were mirrored (disabled) before sleep, to re-mirror after wake
    private var mirroredBeforeSleep: [CGDirectDisplayID] = []

    init() {
        virtualService.onDisplayTerminated = { [weak self] id in
            self?.virtualDisplayIDs.remove(id)
            self?.debouncedRefresh()
        }
        let restored = virtualService.restoreSavedDisplays()
        for entry in restored {
            virtualDisplayIDs.insert(entry.id)
            virtualDisplayNames[entry.id] = entry.name
        }
        refresh()
        displayService.fixDuplicateDisplayProfiles(displays: displays)
        Task { await applyPersistedState() }
        registerForDisplayChanges()
        registerForSleepWake()
    }

    private func t(_ key: String) -> String {
        locale?.t(key) ?? key
    }

    private func t(_ key: String, _ args: any CVarArg...) -> String {
        locale?.t(key, args) ?? key
    }

    // MARK: - Navigation

    /// Navigate with a brief cooldown to prevent rapid double-clicks
    func navigate(to state: NavigationState) {
        guard !isNavigating else { return }
        isNavigating = true
        navigationState = state
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            isNavigating = false
        }
    }

    // MARK: - Data Loading

    func refresh() {
        isLoading = true
        let physical = displayService.fetchDisplays()
        let vIDs = virtualDisplayIDs
        displays = physical.map { info in
            let isVirtual = vIDs.contains(info.id)
            let displayName = isVirtual ? (virtualDisplayNames[info.id] ?? info.name) : info.name
            return info.with(name: displayName, isVirtual: isVirtual)
        }
        isLoading = false
    }

    /// Debounced refresh to coalesce rapid display change callbacks
    private func debouncedRefresh() {
        debounceRefreshTask?.cancel()
        debounceRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: - Resolution Change

    func changeResolution(of display: DisplayInfo, to mode: DisplayMode) {
        do {
            try displayService.setDisplayMode(mode, for: display.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Set Main Display

    func setAsMainDisplay(_ display: DisplayInfo) {
        guard display.isActive, !display.isMain, !isBusy else { return }
        isBusy = true
        busyMessage = t("setting_main")
        Task {
            defer { isBusy = false; busyMessage = nil }
            do {
                try displayService.setMainDisplay(display.id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            if let uuid = display.uuid {
                statePersistence.recordMain(uuid: uuid)
            }
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }

    // MARK: - Enable / Disable Display

    var activeDisplays: [DisplayInfo] {
        displays.filter { $0.isActive }
    }

    func toggleDisplay(_ display: DisplayInfo) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = display.isMirrored
            ? t("enabling_format", display.name)
            : t("disabling_format", display.name)
        Task {
            defer { isBusy = false; busyMessage = nil }

            if display.isMirrored {
                do { try displayService.enableDisplay(display.id) } catch {
                    errorMessage = error.localizedDescription
                    return
                }
                if let uuid = display.uuid {
                    statePersistence.recordEnabled(uuid: uuid)
                }
            } else {
                do { try displayService.disableDisplay(display.id, allDisplays: displays) } catch {
                    errorMessage = error.localizedDescription
                    return
                }
                if let uuid = display.uuid {
                    statePersistence.recordDisabled(uuid: uuid)
                }
            }

            try? await Task.sleep(for: .milliseconds(500))
            refresh()

            // Safety: re-enable a display if all got disabled
            if !display.isMirrored {
                let active = displays.filter { $0.isActive }
                if active.isEmpty {
                    let fallback = displays.first(where: { $0.isBuiltIn }) ?? displays.first
                    if let target = fallback {
                        busyMessage = t("re_enabling_format", target.name)
                        do {
                            try displayService.enableDisplay(target.id)
                            if let uuid = target.uuid {
                                statePersistence.recordEnabled(uuid: uuid)
                            }
                            try? await Task.sleep(for: .milliseconds(500))
                            refresh()
                        } catch {
                            errorMessage = t("all_disabled_error", error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Virtual Display Management

    func createVirtualDisplay() {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = t("creating_virtual")
        Task {
            defer { isBusy = false; busyMessage = nil }
            do {
                let id = try virtualService.createVirtualDisplay(config: newDisplayConfig)
                virtualDisplayIDs.insert(id)
                virtualDisplayNames[id] = newDisplayConfig.name
                newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig()
                navigationState = .displayList
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }

    func removeVirtualDisplay(_ display: DisplayInfo) {
        guard !isBusy else { return }
        virtualService.removeVirtualDisplay(id: display.id)
        virtualDisplayIDs.remove(display.id)
        virtualDisplayNames.removeValue(forKey: display.id)
        refresh()
    }

    /// Reconfigure a virtual display by recreating it with new settings.
    func reconfigureVirtualDisplay(_ display: DisplayInfo, width: Int, height: Int, refreshRate: Double = 60, hiDPI: Bool = false, name: String? = nil) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = t("reconfiguring")
        Task {
            defer { isBusy = false; busyMessage = nil }
            let displayName = name ?? display.name
            virtualService.removeVirtualDisplay(id: display.id)
            virtualDisplayIDs.remove(display.id)
            virtualDisplayNames.removeValue(forKey: display.id)

            let config = VirtualDisplayService.VirtualDisplayConfig(
                name: displayName,
                width: width, height: height,
                refreshRate: refreshRate, hiDPI: hiDPI
            )
            do {
                let newID = try virtualService.createVirtualDisplay(config: config)
                virtualDisplayIDs.insert(newID)
                virtualDisplayNames[newID] = displayName
            } catch {
                errorMessage = error.localizedDescription
                return
            }

            navigationState = .displayList
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }

    // MARK: - URL Scheme

    /// Dispatches a parsed `simpledisplay://` command to the appropriate
    /// existing public method. Side-effects (toast, refresh, nav) are
    /// intentionally identical to what happens when the user clicks the
    /// equivalent button — this is just another entry point, not a shadow
    /// execution path.
    func execute(urlCommand command: URLCommand) {
        switch command {
        case .open:
            navigate(to: .displayList)
            NSApp.activate(ignoringOtherApps: true)

        case .create(let request):
            newDisplayConfig = VirtualDisplayService.VirtualDisplayConfig(
                name: request.name,
                width: request.width,
                height: request.height,
                refreshRate: request.refreshRate,
                hiDPI: request.hiDPI
            )
            createVirtualDisplay()

        case .remove(.id(let rawID)):
            let id = CGDirectDisplayID(rawID)
            guard let display = displays.first(where: { $0.id == id && $0.isVirtual }) else {
                errorMessage = t("unknown_virtual_display_id", rawID as CVarArg)
                return
            }
            removeVirtualDisplay(display)

        case .remove(.name(let name)):
            guard let display = displays.first(where: { $0.isVirtual && $0.name == name }) else {
                errorMessage = t("unknown_virtual_display_name", name as CVarArg)
                return
            }
            removeVirtualDisplay(display)

        case .reconfigure(let rawID, let request):
            let id = CGDirectDisplayID(rawID)
            guard let display = displays.first(where: { $0.id == id && $0.isVirtual }) else {
                errorMessage = t("unknown_virtual_display_id", rawID as CVarArg)
                return
            }
            // Only propagate a rename if the caller actually passed one.
            let explicitName = request.name == VirtualDisplayRequest().name ? nil : request.name
            reconfigureVirtualDisplay(
                display,
                width: request.width,
                height: request.height,
                refreshRate: request.refreshRate,
                hiDPI: request.hiDPI,
                name: explicitName
            )
        }
    }

    // MARK: - Color Profile Fix

    /// Re-applies sRGB profiles to all displays to prevent ColorSync CPU loop.
    /// Called after cleaning the display cache.
    func fixColorProfiles() {
        refresh()
        displayService.fixDuplicateDisplayProfiles(displays: displays)
    }

    // MARK: - Display Change Monitoring

    private func registerForDisplayChanges() {
        changeToken = displayService.registerDisplayChangeCallback { [weak self] _, flags in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Task { @MainActor in
                self?.debouncedRefresh()
            }
        }
        // Fallback: NSNotification (CGDisplayReconfigurationCallback may not fire on macOS Tahoe+)
        screenChangeObserver = displayService.registerScreenChangeNotification { [weak self] in
            self?.debouncedRefresh()
        }
    }

    // MARK: - Sleep / Wake Handling

    private func registerForSleepWake() {
        let ws = NSWorkspace.shared.notificationCenter

        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSleep()
            }
        }

        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Delay to let macOS settle display state after wake
                try? await Task.sleep(for: .seconds(3))
                self?.handleWake()
            }
        }
    }

    /// Before sleep: unmirror all mirrored displays to prevent freeze on wake
    private func handleSleep() {
        isBusy = false
        busyMessage = nil

        mirroredBeforeSleep = displays.filter { $0.isMirrored }.map { $0.id }
        for id in mirroredBeforeSleep {
            try? displayService.enableDisplay(id)
        }
        if !mirroredBeforeSleep.isEmpty {
            logger.info("Sleep: temporarily enabled \(self.mirroredBeforeSleep.count) mirrored displays")
        }
    }

    /// After wake: re-mirror displays that were disabled before sleep
    private func handleWake() {
        refresh()
        guard !mirroredBeforeSleep.isEmpty else { return }

        let toRemirror = mirroredBeforeSleep
        mirroredBeforeSleep = []

        for id in toRemirror {
            guard let display = displays.first(where: { $0.id == id && $0.isActive }) else { continue }
            try? displayService.disableDisplay(id, allDisplays: displays)
            logger.info("Wake: re-disabled display '\(display.name)'")
        }
        refresh()
    }

    // MARK: - Persisted State Restore

    /// Re-apply previously-saved disable/main flags to whatever physical displays
    /// are currently online. Runs once at startup, in an async Task so it can
    /// pause between CG operations — `disableDisplay` reconfigures the
    /// display tree and the system needs a moment to settle before the next
    /// call uses fresh CG state.
    ///
    /// Mirroring still uses `.forSession` as a crash-recovery safety net; this
    /// async re-application is what makes the user's choice survive logout/reboot.
    private func applyPersistedState() async {
        let saved = statePersistence.loadAll()
        guard !saved.isEmpty else { return }

        let savedByUUID = Dictionary(uniqueKeysWithValues: saved.map { ($0.uuid, $0) })

        // Step 1: restore the saved main display first. Doing this before the
        // disables avoids a chain reaction where `disableDisplay` of the current
        // main forces an arbitrary main-transfer that we'd then have to undo.
        if let savedMain = saved.first(where: { $0.isMain }),
           let target = displays.first(where: { $0.uuid == savedMain.uuid }),
           target.isActive,
           !target.isMain {
            do {
                try displayService.setMainDisplay(target.id)
                logger.info("Restored main display '\(target.name)'")
                try? await Task.sleep(for: .milliseconds(400))
                refresh()
            } catch {
                logger.warning("Could not restore main display: \(error.localizedDescription)")
            }
        }

        // Step 2: disable each saved-disabled display, one at a time, refreshing
        // between calls so each `disableDisplay` sees live state. Skip if the
        // operation would leave zero active displays.
        let toDisableUUIDs: [String] = displays.compactMap { display in
            guard
                let uuid = display.uuid,
                let entry = savedByUUID[uuid],
                entry.isDisabled,
                !display.isMirrored
            else { return nil }
            return uuid
        }

        for uuid in toDisableUUIDs {
            guard let display = displays.first(where: { $0.uuid == uuid }), !display.isMirrored else {
                continue
            }
            let activeCount = displays.filter { $0.isActive }.count
            guard activeCount > 1 else {
                logger.info("Skipping persisted disable of '\(display.name)' — would leave zero active")
                continue
            }
            do {
                try displayService.disableDisplay(display.id, allDisplays: displays)
                logger.info("Restored disabled state on '\(display.name)'")
                try? await Task.sleep(for: .milliseconds(400))
                refresh()
            } catch {
                logger.warning("Could not restore disabled state on '\(display.name)': \(error.localizedDescription)")
            }
        }
    }

}
