import AppKit
import CoreGraphics
import Foundation
import Observation
import os

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

    private let displayService = DisplayService()
    private let virtualService = VirtualDisplayService()
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
        registerForDisplayChanges()
        registerForSleepWake()
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
        busyMessage = "Setting main display..."
        Task {
            defer { isBusy = false; busyMessage = nil }
            do {
                try displayService.setMainDisplay(display.id)
            } catch {
                errorMessage = error.localizedDescription
                return
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
        busyMessage = display.isMirrored ? "Enabling \(display.name)..." : "Disabling \(display.name)..."
        Task {
            defer { isBusy = false; busyMessage = nil }

            if display.isMirrored {
                do { try displayService.enableDisplay(display.id) } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            } else {
                do { try displayService.disableDisplay(display.id, allDisplays: displays) } catch {
                    errorMessage = error.localizedDescription
                    return
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
                        busyMessage = "Re-enabling \(target.name)..."
                        do {
                            try displayService.enableDisplay(target.id)
                            try? await Task.sleep(for: .milliseconds(500))
                            refresh()
                        } catch {
                            errorMessage = "All displays disabled. Failed to re-enable: \(error.localizedDescription)"
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
        busyMessage = "Creating virtual display..."
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
        busyMessage = "Reconfiguring display..."
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

}
