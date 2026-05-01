import Foundation
import os

private let logger = Logger(subsystem: "app.simpledisplay", category: "DisplayStatePersistence")

struct PersistedDisplayState: Codable {
    let uuid: String
    var isDisabled: Bool
    var isMain: Bool
}

@MainActor
final class DisplayStatePersistence {

    private let persistenceKey = "com.simpledisplay.displayState"

    func loadAll() -> [PersistedDisplayState] {
        loadConfigs()
    }

    func state(forUUID uuid: String) -> PersistedDisplayState? {
        loadConfigs().first { $0.uuid == uuid }
    }

    func recordDisabled(uuid: String) {
        upsert(uuid: uuid) { $0.isDisabled = true }
    }

    func recordEnabled(uuid: String) {
        upsert(uuid: uuid) { $0.isDisabled = false }
    }

    /// Marks `uuid` as main and clears the flag on every other entry.
    func recordMain(uuid: String) {
        var configs = loadConfigs()
        for idx in configs.indices {
            configs[idx].isMain = (configs[idx].uuid == uuid)
        }
        if !configs.contains(where: { $0.uuid == uuid }) {
            configs.append(PersistedDisplayState(uuid: uuid, isDisabled: false, isMain: true))
        }
        writeConfigs(configs)
    }

    func clearAll() {
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }

    // MARK: - Private

    private func upsert(uuid: String, mutate: (inout PersistedDisplayState) -> Void) {
        var configs = loadConfigs()
        if let idx = configs.firstIndex(where: { $0.uuid == uuid }) {
            mutate(&configs[idx])
        } else {
            var entry = PersistedDisplayState(uuid: uuid, isDisabled: false, isMain: false)
            mutate(&entry)
            configs.append(entry)
        }
        writeConfigs(configs)
    }

    private func loadConfigs() -> [PersistedDisplayState] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return [] }
        do {
            return try JSONDecoder().decode([PersistedDisplayState].self, from: data)
        } catch {
            logger.error("Failed to decode display state: \(error.localizedDescription)")
            return []
        }
    }

    private func writeConfigs(_ configs: [PersistedDisplayState]) {
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to encode display state: \(error.localizedDescription)")
        }
    }
}
