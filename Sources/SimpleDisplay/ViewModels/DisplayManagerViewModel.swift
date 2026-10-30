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

/// The last visible (physical) display was just turned off. Unless the user
/// confirms within the countdown, it is turned back on.
struct HeadlessPending: Equatable {
    let uuid: String
    let id: CGDirectDisplayID
    let name: String
    var secondsLeft: Int
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

    /// Last-known info, keyed by UUID, for displays we disabled that have since
    /// dropped out of the online display list. A display disabled via
    /// `CGSConfigureDisplayEnabled` is removed from `CGGetOnlineDisplayList`
    /// entirely, so we synthesize a row from this cache to keep it visible and
    /// re-enableable rather than letting it silently disappear.
    private var disabledGhosts: [String: DisplayInfo] = [:]

    /// Countdown shown after the last visible display was turned off.
    var headlessPending: HeadlessPending?
    private var headlessTask: Task<Void, Never>?

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
        // Seed ghost rows for displays disabled in a previous session so they
        // remain re-enableable even if macOS never brought them back online.
        for entry in statePersistence.loadAll() where entry.isDisabled {
            if let id = entry.lastKnownID, let name = entry.name {
                disabledGhosts[entry.uuid] = .disabledPlaceholder(id: id, uuid: entry.uuid, name: name)
            }
        }
        refresh()
        displayService.fixDuplicateDisplayProfiles(displays: displays)
        Task {
            await settleAndRefresh()
            await applyPersistedState()
        }
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
        var result = physical.map { info in
            let isVirtual = vIDs.contains(info.id)
            let displayName = isVirtual ? (virtualDisplayNames[info.id] ?? info.name) : info.name
            return info.with(name: displayName, isVirtual: isVirtual)
        }

        // Re-attach rows for disabled displays that have left the online list,
        // so the user can still toggle them back on. A ghost is addressed by a
        // CGDirectDisplayID that macOS may have reassigned since it was disabled,
        // so each one is reconciled against the live list before it is shown.
        let verdicts = GhostReconciler.reconcile(
            ghosts: disabledGhosts.map { GhostReconciler.Ghost(uuid: $0.key, id: $0.value.id) },
            live: result.map { GhostReconciler.Live(uuid: $0.uuid, id: $0.id) },
            resolveID: { displayService.displayID(forUUID: $0) }
        )
        for (uuid, ghost) in disabledGhosts.sorted(by: { $0.value.name < $1.value.name }) {
            switch verdicts[uuid] {
            case .backOnline:
                // The display is live again; its real row replaces the ghost.
                disabledGhosts[uuid] = nil
            case .keep(let id):
                let row = ghost.id == id ? ghost : ghost.with(id: id)
                disabledGhosts[uuid] = row
                result.append(row)
            case .collided(let liveUUID):
                // Toggling this ghost would act on whichever display now owns its
                // ID. Drop the row but keep the persisted disabled flag, so the
                // display is disabled again (with a fresh ID) if it comes back.
                logger.warning("Dropping ghost row '\(ghost.name)' (\(uuid)): its retained ID \(ghost.id) now belongs to \(liveUUID ?? "a display without UUID")")
                disabledGhosts[uuid] = nil
            case nil:
                break
            }
        }

        // A display can be off with no ghost row: its ghost lost an ID
        // collision, or it was never disabled from this app. Show it anyway so
        // it can be turned back on.
        let shownUUIDs = Set(result.compactMap(\.uuid))
        let shownIDs = Set(result.map(\.id))
        let persisted = statePersistence.loadAll()
        for orphan in displayService.fetchDisabledDisplays() where !shownIDs.contains(orphan.id) {
            if let uuid = orphan.uuid, shownUUIDs.contains(uuid) { continue }
            let entry = persisted.first { $0.uuid == orphan.uuid } ?? persisted.first { $0.lastKnownID == orphan.id }
            result.append(orphan.with(name: entry?.name ?? orphan.name, isVirtual: false))
        }

        displays = result
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

    /// Polls the live display list until it stops changing (or a timeout), then
    /// refreshes once. Enabling or disabling a display triggers a global display
    /// reconfiguration in which *other* displays momentarily leave the online
    /// list. A single fixed-delay refresh can capture that partial snapshot and
    /// make an unrelated display's row vanish until the next system callback —
    /// which may never arrive. Waiting for the topology to stabilize avoids
    /// committing a half-finished state.
    private func settleAndRefresh(maxPolls: Int = 15) async {
        var previous: Set<CGDirectDisplayID> = []
        var stableHits = 0
        for _ in 0..<maxPolls {
            try? await Task.sleep(for: .milliseconds(200))
            let current = Set(displayService.fetchDisplays().map { $0.id })
            if current == previous {
                stableHits += 1
                if stableHits >= 2 { break }   // unchanged across ~400ms
            } else {
                stableHits = 0
                previous = current
            }
        }
        refresh()
        // Every topology change is a chance for macOS to swap a virtual display
        // into a remembered mode (it keeps one per identity and per set of
        // connected displays: turning a physical display off is a new set).
        enforceVirtualDisplayModes()
    }

    /// Re-applies a display mode after a display has been brought back online,
    /// since `CGSConfigureDisplayEnabled` can re-enable a display at a default
    /// (often non-HiDPI) mode. The display is looked up by UUID: re-enabling is
    /// a topology change, after which macOS may hand it a new CGDirectDisplayID.
    /// No-op if the display is not back yet or already has the mode.
    private func restoreMode(_ mode: DisplayMode, forUUID uuid: String) {
        guard let current = displays.first(where: { $0.uuid == uuid && $0.isActive }) else {
            logger.info("Skipping mode restore: display \(uuid) is not active yet")
            return
        }
        guard current.currentMode != mode else { return }
        // Match by size and scale; the exact refresh rate may not be offered any more.
        let target = current.availableModes.first { $0 == mode }
            ?? current.availableModes.filter { $0.width == mode.width && $0.height == mode.height && $0.isHiDPI == mode.isHiDPI }
                .min { abs($0.refreshRate - mode.refreshRate) < abs($1.refreshRate - mode.refreshRate) }
        guard let target else {
            logger.warning("Cannot restore \(mode.width)x\(mode.height) on '\(current.name)': mode not offered")
            return
        }
        do {
            try displayService.setDisplayMode(target, for: current.id, permanently: canCommitPermanently)
            logger.info("Restored mode \(target.width)x\(target.height)\(target.isHiDPI ? " HiDPI" : "") on '\(current.name)' (was \(current.currentMode.width)x\(current.currentMode.height))")
            refresh()
        } catch {
            logger.warning("Could not restore mode on '\(current.name)': \(error.localizedDescription)")
        }
    }

    /// Restore a mode and check it stuck: after a mirror is dissolved the window
    /// server applies its own remembered configuration a moment later and can
    /// undo ours, so settle and re-apply once if needed.
    private func restoreModeVerified(_ mode: DisplayMode, forUUID uuid: String) async {
        restoreMode(mode, forUUID: uuid)
        await settleAndRefresh()
        if let now = displays.first(where: { $0.uuid == uuid && $0.isActive }),
           now.currentMode.width != mode.width || now.currentMode.height != mode.height || now.currentMode.isHiDPI != mode.isHiDPI {
            logger.info("Mode of '\(now.name)' reverted to \(now.currentMode.width)x\(now.currentMode.height) after settling; re-applying once")
            restoreMode(mode, forUUID: uuid)
            await settleAndRefresh()
        }
    }

    /// macOS remembers a mode per display identity (vendor/product/serial) and
    /// brings a virtual display up in that mode instead of the configured one
    /// (seen live: configured 3440x1440, came up at 1720x720), and
    /// `CGVirtualDisplay.applySettings` does not switch the mode of the main
    /// display without a real configuration commit. So after creating or
    /// restoring virtual displays, re-apply the configured mode through
    /// `CGConfigureDisplayWithDisplayMode`; committed `.permanently`, it also
    /// becomes the mode macOS remembers from then on.
    private func enforceVirtualDisplayModes() {
        var changed = false
        for display in displays where display.isVirtual && display.isActive && !display.isMirrored {
            guard let config = virtualService.config(for: display.id) else { continue }
            let want = config.wantedMode
            let current = display.currentMode
            if current.width == want.width && current.height == want.height && current.isHiDPI == want.hiDPI {
                continue
            }
            guard let wanted = display.availableModes.first(where: {
                $0.width == want.width && $0.height == want.height && $0.isHiDPI == want.hiDPI
            }) else {
                logger.warning("Virtual display '\(display.name)' offers no \(want.width)x\(want.height)\(want.hiDPI ? " HiDPI" : "") mode to enforce")
                continue
            }
            do {
                try displayService.setDisplayMode(wanted, for: display.id, permanently: canCommitPermanently)
                changed = true
                logger.info("Re-applied configured mode \(wanted.width)x\(wanted.height)\(wanted.isHiDPI ? " HiDPI" : "") on virtual display '\(display.name)' (came up as \(current.width)x\(current.height))")
            } catch {
                logger.warning("Could not re-apply configured mode on '\(display.name)': \(error.localizedDescription)")
            }
        }
        if changed { refresh() }
    }

    /// Saved config of a virtual display (panel size, zoom, chosen mode).
    func virtualConfig(for display: DisplayInfo) -> VirtualDisplayService.VirtualDisplayConfig? {
        display.isVirtual ? virtualService.config(for: display.id) : nil
    }

    // MARK: - Resolution Change

    /// Switches a display to one of the modes it offers. For a virtual display
    /// the pick is saved with its config, so it survives topology changes and
    /// relaunches (see `enforceVirtualDisplayModes`).
    func changeResolution(of display: DisplayInfo, to mode: DisplayMode) {
        guard !isBusy, display.isActive else { return }
        isBusy = true
        busyMessage = t("changing_mode_format", display.name)
        Task {
            defer { isBusy = false; busyMessage = nil }
            do {
                try displayService.setDisplayMode(mode, for: display.id, permanently: canCommitPermanently)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            if display.isVirtual {
                virtualService.setChosenMode(id: display.id, width: mode.width, height: mode.height, hiDPI: mode.isHiDPI)
            }
            await settleAndRefresh()
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
            await settleAndRefresh()
        }
    }

    // MARK: - Enable / Disable Display

    var activeDisplays: [DisplayInfo] {
        displays.filter { $0.isActive }
    }

    /// Displays that currently put pixels on a physical panel. A mirrored
    /// physical display counts (it shows a copy); a virtual display never does.
    var visibleDisplays: [DisplayInfo] {
        displays.filter { $0.isActive && !$0.isVirtual }
    }

    /// True when turning `display` off would leave this Mac with no visible
    /// screen: only virtual displays would remain. That is the dead state the
    /// headless countdown guards against.
    func wouldLeaveNoVisibleDisplay(_ display: DisplayInfo) -> Bool {
        display.isActive && !display.isVirtual && !visibleDisplays.contains { $0.id != display.id }
    }

    /// Mode changes are written to macOS's display preferences only while no
    /// mirror is active; a permanent commit would bake the mirror set into the
    /// preferences and macOS would re-create it later by itself.
    private var canCommitPermanently: Bool {
        !displays.contains { $0.isMirrored }
    }

    func displayName(for id: CGDirectDisplayID) -> String {
        displays.first { $0.id == id }?.name ?? "Display \(id)"
    }

    /// Turns a display off (for real) or back on. `headless: true` confirms up
    /// front that turning off the last visible display is intended (scripted or
    /// remote use); otherwise that case runs a revert countdown.
    func toggleDisplay(_ display: DisplayInfo, headless: Bool = false) {
        guard !isBusy else { return }
        let wasEnabled = display.isActive
        let uuid = display.uuid
        // Turning this one off would leave only virtual displays: nothing visible.
        let goesHeadless = wasEnabled && wouldLeaveNoVisibleDisplay(display)
        // A ghost is a disabled display that has left the online list; its row
        // is synthesized from retained identity rather than live CG state.
        let wasGhost = !wasEnabled && uuid.map { disabledGhosts[$0] != nil } ?? false
        // When re-enabling, macOS brings the display back at a default mode that
        // can drop HiDPI. Remember the mode it had so we can restore it; a row
        // rebuilt after a relaunch has no live mode, so use the persisted one.
        let modeToRestore: DisplayMode? = !wasEnabled
            ? (display.isPlaceholder ? uuid.flatMap { statePersistence.state(forUUID: $0)?.lastMode } : display.currentMode)
            : nil
        isBusy = true
        busyMessage = wasEnabled
            ? t("disabling_format", display.name)
            : t("enabling_format", display.name)
        Task {
            defer { isBusy = false; busyMessage = nil }

            if wasEnabled {
                // A member of a mirror set must leave it before being disabled,
                // in its own settled transaction.
                await dissolveMirrors(involving: display)
                do { try displayService.disableDisplay(display.id, allDisplays: displays) } catch {
                    errorMessage = error.localizedDescription
                    return
                }
                // Retain identity so the row survives the display leaving the
                // online list (both in-session and across an app restart).
                if let uuid {
                    disabledGhosts[uuid] = display.asDisabledGhost()
                    // Only a confirmed headless disable may be re-applied on launch.
                    statePersistence.recordDisabled(
                        uuid: uuid, id: display.id, name: display.name,
                        headless: goesHeadless && headless, lastMode: display.currentMode
                    )
                    if goesHeadless && !headless {
                        startHeadlessCountdown(uuid: uuid, id: display.id, name: display.name)
                    }
                }
            } else {
                // Re-enabling by hand mid-countdown is the same as reverting.
                if let uuid, headlessPending?.uuid == uuid {
                    headlessTask?.cancel()
                    headlessPending = nil
                }
                // Prefer the ID macOS assigns the UUID right now; the retained one
                // is the fallback for when the UUID does not resolve while disabled.
                let targetID = uuid.flatMap { displayService.displayID(forUUID: $0) } ?? display.id
                do { try displayService.enableDisplay(targetID) } catch {
                    if wasGhost, let uuid, displayService.displayID(forUUID: uuid) == nil {
                        // The window server does not know this display any more
                        // (unplugged and never returned). Its toggle could only
                        // ever fail, so forget it instead of leaving a dead row.
                        disabledGhosts[uuid] = nil
                        statePersistence.recordEnabled(uuid: uuid)
                        refresh()
                        errorMessage = t("display_unreachable_forgotten_format", display.name)
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    return
                }
                // Record the user's intent right away, but leave the ghost row in
                // place: refresh() drops it once the display is actually back in
                // the online list, so the row cannot vanish if the display takes
                // longer than the settle window to reappear.
                if let uuid {
                    statePersistence.recordEnabled(uuid: uuid)
                }
            }

            await settleAndRefresh()

            // Restore the pre-disable mode if re-enabling reset it (e.g. HiDPI → non-HiDPI).
            if let modeToRestore, let uuid {
                restoreMode(modeToRestore, forUUID: uuid)
            }

            // Safety: nothing visible left and no countdown handling it (defensive;
            // disabling the very last display already fails at the main transfer).
            if wasEnabled && !goesHeadless && visibleDisplays.isEmpty {
                let fallback = displays.first(where: { $0.isBuiltIn && !$0.isActive })
                    ?? displays.first(where: { !$0.isVirtual && !$0.isActive })
                do {
                    if let target = fallback {
                        busyMessage = t("re_enabling_format", target.name)
                        let targetID = target.uuid.flatMap { displayService.displayID(forUUID: $0) } ?? target.id
                        try displayService.enableDisplay(targetID)
                        if let uuid = target.uuid {
                            statePersistence.recordEnabled(uuid: uuid)
                        }
                        await settleAndRefresh()
                    }
                } catch {
                    errorMessage = t("all_disabled_error", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Headless Countdown

    private static let headlessCountdownSeconds = 15

    private func startHeadlessCountdown(uuid: String, id: CGDirectDisplayID, name: String) {
        headlessTask?.cancel()
        headlessPending = HeadlessPending(uuid: uuid, id: id, name: name, secondsLeft: Self.headlessCountdownSeconds)
        headlessTask = Task { [weak self] in
            for _ in 0..<Self.headlessCountdownSeconds {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.headlessPending != nil else { return }
                self.headlessPending?.secondsLeft -= 1
            }
            guard !Task.isCancelled, let self else { return }
            self.revertHeadless()
        }
    }

    /// The user, typically from a remote session, wants this Mac to stay
    /// without a visible screen. Persisted as confirmed so launch re-applies it.
    func confirmHeadless() {
        guard let pending = headlessPending else { return }
        headlessTask?.cancel()
        headlessPending = nil
        statePersistence.recordDisabled(uuid: pending.uuid, id: pending.id, name: pending.name, headless: true)
        logger.info("Headless confirmed for '\(pending.name)'")
    }

    /// Countdown expired, or the user asked for the screen back.
    func revertHeadless() {
        guard let pending = headlessPending else { return }
        headlessTask?.cancel()
        headlessPending = nil
        Task { await bringBack(pending) }
    }

    private func bringBack(_ pending: HeadlessPending) async {
        // Do not overlap CG transactions with an operation still in flight.
        while isBusy { try? await Task.sleep(for: .milliseconds(200)) }
        isBusy = true
        busyMessage = t("enabling_format", pending.name)
        defer { isBusy = false; busyMessage = nil }
        let targetID = displayService.displayID(forUUID: pending.uuid) ?? pending.id
        let lastMode = statePersistence.state(forUUID: pending.uuid)?.lastMode
        do {
            try displayService.enableDisplay(targetID)
            statePersistence.recordEnabled(uuid: pending.uuid)
            logger.info("Headless countdown reverted: '\(pending.name)' is back on")
        } catch {
            errorMessage = error.localizedDescription
        }
        await settleAndRefresh()
        if let lastMode { restoreMode(lastMode, forUUID: pending.uuid) }
    }

    // MARK: - Mirror

    /// Mirrors `display` onto the main display, or stops mirroring it. A
    /// separate action from on/off: the panel stays on and shows a copy, which
    /// some users prefer to a dark screen, and it still counts as visible.
    /// Only physical displays may be mirror slaves: mirroring a virtual display
    /// onto anything crashes the window server on macOS 26 (verified in
    /// docs/real-disable-vm, both onto a physical and onto another virtual).
    /// A physical display mirroring a virtual one is fine and is the remote
    /// desktop use case.
    func toggleMirror(_ display: DisplayInfo) {
        guard !isBusy, display.isActive else { return }
        guard !display.isVirtual else {
            errorMessage = t("mirror_virtual_unsupported")
            return
        }
        isBusy = true
        busyMessage = display.isMirrored
            ? t("unmirroring_format", display.name)
            : t("mirroring_format", display.name)
        Task {
            defer { isBusy = false; busyMessage = nil }
            if display.isMirrored {
                let lastMode = display.uuid.flatMap { statePersistence.state(forUUID: $0)?.lastMode }
                do { try displayService.unmirrorDisplay(display.id) } catch {
                    errorMessage = error.localizedDescription
                    return
                }
                if let uuid = display.uuid { statePersistence.recordUnmirror(uuid: uuid) }
                await settleAndRefresh()
                // A mirror slave ran at the master's mode; give it its own back.
                if let lastMode, let uuid = display.uuid { await restoreModeVerified(lastMode, forUUID: uuid) }
            } else {
                await mirror(display, onto: nil)
            }
        }
    }

    /// Mirrors `display` onto `target` (main when nil) as separate, settled
    /// steps: transfer main away from the display if needed, wait, then mirror,
    /// wait, then verify the window server still reports active displays.
    /// Back-to-back transactions left it with none (docs/real-disable-vm).
    private func mirror(_ display: DisplayInfo, onto target: CGDirectDisplayID?) async {
        // Hard stop, whatever the caller: a virtual mirror slave kills the window server.
        guard !display.isVirtual else {
            logger.error("Refusing to mirror virtual display '\(display.name)'")
            errorMessage = t("mirror_virtual_unsupported")
            return
        }
        var targetID = target ?? CGMainDisplayID()
        if display.isMain {
            guard let newMain = target ?? displayService.bestNewMain(excluding: display.id, in: displays) else {
                errorMessage = t("all_disabled_error", "no other display to mirror onto")
                return
            }
            do { try displayService.setMainDisplay(newMain) } catch {
                errorMessage = error.localizedDescription
                return
            }
            await settleAndRefresh()
            targetID = newMain
            guard displays.contains(where: { $0.id == display.id && $0.isActive }),
                  displays.contains(where: { $0.id == targetID && $0.isActive }) else {
                errorMessage = t("all_disabled_error", "displays did not settle after moving main")
                return
            }
        }
        do { try displayService.mirrorDisplay(display.id, onto: targetID) } catch {
            errorMessage = error.localizedDescription
            return
        }
        await settleAndRefresh()
        guard displayService.activeDisplayCount() > 0 else {
            // The window server lost every display: undo immediately rather than
            // leave the Mac blind.
            logger.error("Mirroring '\(display.name)' left zero active displays; undoing")
            try? displayService.unmirrorDisplay(display.id)
            await settleAndRefresh()
            errorMessage = t("all_disabled_error", "mirror left no active display; reverted")
            return
        }
        if let uuid = display.uuid, let targetUUID = displayService.uuid(for: targetID) {
            statePersistence.recordMirror(uuid: uuid, of: targetUUID, lastMode: display.currentMode)
        }
    }

    /// Breaks every mirror relationship `display` takes part in (as source or
    /// as target), one settled transaction each. Persisted mirror choices are
    /// kept unless `forget` is set: turning a display off is not a change of
    /// mind about mirroring.
    private func dissolveMirrors(involving display: DisplayInfo, forget: Bool = false) async {
        var released: [(uuid: String, lastMode: DisplayMode?)] = []
        for slave in displays where slave.mirroredToDisplayID == display.id {
            if (try? displayService.unmirrorDisplay(slave.id)) != nil, let uuid = slave.uuid {
                released.append((uuid, statePersistence.state(forUUID: uuid)?.lastMode))
                if forget { statePersistence.recordUnmirror(uuid: uuid) }
            }
        }
        if display.isMirrored, (try? displayService.unmirrorDisplay(display.id)) != nil, let uuid = display.uuid {
            released.append((uuid, statePersistence.state(forUUID: uuid)?.lastMode))
            if forget { statePersistence.recordUnmirror(uuid: uuid) }
        }
        guard !released.isEmpty else { return }
        await settleAndRefresh()
        // Former slaves ran at their master's mode; give each its own back.
        for item in released {
            if let lastMode = item.lastMode { await restoreModeVerified(lastMode, forUUID: item.uuid) }
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
            await settleAndRefresh()
        }
    }

    func removeVirtualDisplay(_ display: DisplayInfo) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = t("removing_format", display.name)
        Task {
            defer { isBusy = false; busyMessage = nil }
            await forgetDisabledState(of: display)
            virtualService.removeVirtualDisplay(id: display.id)
            virtualDisplayIDs.remove(display.id)
            virtualDisplayNames.removeValue(forKey: display.id)
            refresh()
        }
    }

    /// A virtual display about to be destroyed must not leave a disabled
    /// footprint behind. Destroying a `CGVirtualDisplay` while it is disabled
    /// leaves a phantom in the window server that the next display created with
    /// the same serial inherits, mode included (seen on macOS 26: a 1600x900
    /// HiDPI display came back as the destroyed one's 1280x720). So: re-enable
    /// it first and wait for the topology to settle, drop its ghost row, and
    /// forget its persisted flags, since its UUID derives from a reusable serial
    /// slot and stale flags would apply to whichever display inherits the slot.
    private func forgetDisabledState(of display: DisplayInfo) async {
        if display.isActive {
            // A display about to be destroyed leaves its mirror set first.
            await dissolveMirrors(involving: display, forget: true)
        }
        if !display.isActive {
            let targetID = display.uuid.flatMap { displayService.displayID(forUUID: $0) } ?? display.id
            do {
                try displayService.enableDisplay(targetID)
                await settleAndRefresh()
            } catch {
                logger.warning("Could not re-enable '\(display.name)' before removing it: \(error.localizedDescription)")
            }
        }
        if let uuid = display.uuid {
            disabledGhosts[uuid] = nil
            statePersistence.forget(uuid: uuid)
        }
    }

    /// Reconfigure a virtual display by recreating it with new settings.
    func reconfigureVirtualDisplay(_ display: DisplayInfo, width: Int, height: Int, refreshRate: Double = 60, hiDPI: Bool = false, name: String? = nil) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = t("reconfiguring")
        Task {
            defer { isBusy = false; busyMessage = nil }
            let displayName = name ?? display.name
            // Keep the display's identity (serial) across the recreate, so
            // ColorSync and macOS's per-display mode memory see the same device.
            let serial = virtualService.serial(for: display.id)
            await forgetDisabledState(of: display)
            virtualService.removeVirtualDisplay(id: display.id)
            virtualDisplayIDs.remove(display.id)
            virtualDisplayNames.removeValue(forKey: display.id)

            let config = VirtualDisplayService.VirtualDisplayConfig(
                name: displayName,
                width: width, height: height,
                refreshRate: refreshRate, hiDPI: hiDPI,
                serial: serial
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
            await settleAndRefresh()
        }
    }

    // MARK: - URL Scheme

    /// Dispatches a parsed `simpledisplay://` command to the appropriate
    /// existing public method. Side-effects (toast, refresh, nav) are
    /// intentionally identical to what happens when the user clicks the
    /// equivalent button — this is just another entry point, not a shadow
    /// execution path.
    func execute(urlCommand command: URLCommand) {
        // ColorSyncUnregisterDevice -> AuthorizationCreate hace XPC sincronico que se
        // deadlockea dentro del handler de Apple Events (GURL). Diferir el comando al
        // siguiente ciclo del runloop para ejecutarlo fuera de ese contexto.
        DispatchQueue.main.async { self.executeNow(urlCommand: command) }
    }

    private func executeNow(urlCommand command: URLCommand) {
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
            // remotedesk: matching robusto — por displays activos O por el mapa de nombres
            if let display = displays.first(where: { $0.isVirtual && $0.name == name }) {
                removeVirtualDisplay(display)
            } else {
                let ids = virtualDisplayNames.filter { $0.value == name }.map { $0.key }
                if ids.isEmpty {
                    errorMessage = t("unknown_virtual_display_name", name as CVarArg)
                    return
                }
                for id in ids {
                    virtualService.removeVirtualDisplay(id: id)
                    virtualDisplayIDs.remove(id)
                    virtualDisplayNames.removeValue(forKey: id)
                }
                refresh()
            }

        case .setEnabled(let target, let enabled, let headless):
            refresh()
            guard let display = firstDisplay(matching: target) else {
                errorMessage = "No display matches \(String(describing: target))"
                return
            }
            if display.isActive != enabled {
                toggleDisplay(display, headless: headless)
            }

        case .setMirrored(let target, let mirrored):
            refresh()
            guard let display = firstDisplay(matching: target) else {
                errorMessage = "No display matches \(String(describing: target))"
                return
            }
            if display.isMirrored != mirrored {
                toggleMirror(display)
            }

        case .setMode(let target, let width, let height, let hiDPI, let refreshRate):
            refresh()
            guard let display = firstDisplay(matching: target) else {
                errorMessage = "No display matches \(String(describing: target))"
                return
            }
            let wantHiDPI = hiDPI ?? display.currentMode.isHiDPI
            let candidates = display.availableModes.filter {
                $0.width == width && $0.height == height && $0.isHiDPI == wantHiDPI
            }
            let wantRefresh = refreshRate ?? display.currentMode.refreshRate
            guard let mode = candidates.min(by: { abs($0.refreshRate - wantRefresh) < abs($1.refreshRate - wantRefresh) }) else {
                errorMessage = t("mode_unavailable_format", display.name, width as CVarArg, height as CVarArg)
                return
            }
            if mode != display.currentMode {
                changeResolution(of: display, to: mode)
            }

        case .status:
            writeStatusSnapshot()

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

    private func firstDisplay(matching target: RemoveTarget) -> DisplayInfo? {
        switch target {
        case .id(let rawID): return displays.first { $0.id == CGDirectDisplayID(rawID) }
        case .name(let name): return displays.first { $0.name == name }
        }
    }

    /// Snapshot of every display for remote controllers. Written to a fixed
    /// path so an SSH caller can `open simpledisplay://status` and read it.
    private func writeStatusSnapshot() {
        refresh()
        let items: [[String: Any]] = displays.map { d in
            [
                "id": Int(d.id),
                "name": d.name,
                "virtual": d.isVirtual,
                "on": d.isActive,
                "main": d.isMain,
                "builtin": d.isBuiltIn,
                "width": d.currentMode.width,
                "height": d.currentMode.height,
                "hidpi": d.currentMode.isHiDPI,
                "mirrorOf": Int(d.mirroredToDisplayID),
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/simpledisplay-status.json"))
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

    /// Before sleep: clear in-flight state, settle a pending headless countdown
    /// by turning the screen back on, and dissolve mirror sets (a mirrored
    /// display could freeze on wake; the choice stays persisted and is
    /// re-applied by `handleWake`). A display disabled via
    /// CGSConfigureDisplayEnabled survives sleep as is.
    private func handleSleep() {
        isBusy = false
        busyMessage = nil
        revertHeadless()
        for display in displays where display.isMirrored {
            try? displayService.unmirrorDisplay(display.id)
        }
    }

    /// After wake: refresh, then re-apply persisted state in case macOS
    /// re-activated a display that the user had disabled.
    private func handleWake() {
        refresh()
        Task { await applyPersistedState() }
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

        // Virtual displays restored at launch, and displays re-attached on wake,
        // can take a moment to show up in the online list. Deciding on a partial
        // snapshot would silently skip them, so wait for the topology to settle.
        await settleAndRefresh()

        let savedByUUID = Dictionary(uniqueKeysWithValues: saved.map { ($0.uuid, $0) })

        // Mirrors we never asked for: macOS restores mirror sets from its display
        // preferences (they get there through permanent commits made while a
        // mirror was active). Left alone, but logged, so the trail is visible.
        for display in displays where display.isMirrored && savedByUUID[display.uuid ?? ""]?.mirrorOf == nil {
            logger.warning("'\(display.name)' is mirroring display \(display.mirroredToDisplayID) without a persisted choice (restored by macOS from its display preferences)")
        }

        // Recovery: this Mac has no visible screen and nobody confirmed that
        // (the app quit during the countdown, or an older build persisted it).
        // Bring the disabled physical displays back rather than keep the dead state.
        if visibleDisplays.isEmpty {
            for (uuid, ghost) in disabledGhosts where !ghost.isVirtual && savedByUUID[uuid]?.headless != true {
                let targetID = displayService.displayID(forUUID: uuid) ?? ghost.id
                let lastMode = savedByUUID[uuid]?.lastMode
                do {
                    try displayService.enableDisplay(targetID)
                    statePersistence.recordEnabled(uuid: uuid)
                    logger.warning("Recovered '\(ghost.name)': it was off with no visible display left and headless was never confirmed")
                    await settleAndRefresh()
                    if let lastMode { restoreMode(lastMode, forUUID: uuid) }
                } catch {
                    logger.warning("Could not recover '\(ghost.name)': \(error.localizedDescription)")
                }
            }
        }

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
                await settleAndRefresh()
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
                display.isActive
            else { return nil }
            return uuid
        }

        for uuid in toDisableUUIDs {
            guard let display = displays.first(where: { $0.uuid == uuid }), display.isActive else {
                continue
            }
            guard displays.filter({ $0.isActive }).count > 1 else {
                logger.info("Skipping persisted disable of '\(display.name)' — would leave zero displays")
                continue
            }
            let confirmedHeadless = savedByUUID[uuid]?.headless == true
            if wouldLeaveNoVisibleDisplay(display) && !confirmedHeadless {
                // Never re-create the dead state on launch: an unconfirmed
                // headless disable is dropped so logout/reboot always recovers.
                logger.info("Dropping persisted disable of '\(display.name)' — would leave no visible display and headless was not confirmed")
                statePersistence.recordEnabled(uuid: uuid)
                continue
            }
            do {
                try displayService.disableDisplay(display.id, allDisplays: displays)
                // Capture identity before the display leaves the online list, and
                // refresh persisted id/name in case they were missing.
                disabledGhosts[uuid] = display.asDisabledGhost()
                statePersistence.recordDisabled(uuid: uuid, id: display.id, name: display.name, headless: confirmedHeadless, lastMode: display.currentMode)
                logger.info("Restored disabled state on '\(display.name)'")
                await settleAndRefresh()
            } catch {
                logger.warning("Could not restore disabled state on '\(display.name)': \(error.localizedDescription)")
            }
        }

        // Step 3: re-apply mirrors. Both ends must be live and enabled, neither
        // may already be a mirror slave, and the slave must be physical.
        for entry in saved where entry.mirrorOf != nil && !entry.isDisabled {
            guard
                let display = displays.first(where: { $0.uuid == entry.uuid }),
                display.isActive, !display.isMirrored, !display.isVirtual,
                let target = displays.first(where: { $0.uuid == entry.mirrorOf }),
                target.isActive, !target.isMirrored, target.id != display.id
            else { continue }
            await mirror(display, onto: target.id)
            if displays.contains(where: { $0.id == display.id && $0.isMirrored }) {
                logger.info("Restored mirror of '\(display.name)' onto '\(target.name)'")
            } else {
                logger.warning("Could not restore mirror of '\(display.name)' onto '\(target.name)'")
            }
        }
    }

}
