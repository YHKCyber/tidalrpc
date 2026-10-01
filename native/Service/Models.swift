import Foundation

struct PresenceLayout: Codable, Equatable {
    var order: [String]
    var statusField: String
    var appText: String
    init(order: [String] = ["app", "song", "artist"], statusField: String = "artist", appText: String = "Tidal") {
        self.order = order; self.statusField = statusField; self.appText = appText
    }
    private enum CodingKeys: String, CodingKey { case order, statusField, appText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decode([String].self, forKey: .order)
        statusField = try c.decode(String.self, forKey: .statusField)
        appText = try c.decodeIfPresent(String.self, forKey: .appText) ?? "Tidal"
    }
    // Each of the three rows may show any field, including repeats.
    static let fields: Set<String> = ["app", "song", "artist", "album"]
    var valid: Bool {
        order.count == 3 && order.allSatisfy(PresenceLayout.fields.contains) && order.contains(statusField) &&
        !appText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && appText.count <= 128
    }
}

struct Preferences: Codable {
    var presenceLayout = PresenceLayout()
    var showPresence = true
    var showButtons = true
    var autoStart = false
    var albumPrefs = 0
}
// Where encoded preferences live. The app uses UserDefaults; tests use memory.
protocol PreferenceStore: AnyObject {
    func load() -> Data?
    // Preferences saved by builds that used the previous bundle identifier.
    func loadLegacy() -> Data?
    func store(_ data: Data)
}
final class DefaultsStore: PreferenceStore {
    static let legacyDomain = "ririxidev.TidalRPC"
    func load() -> Data? { UserDefaults.standard.data(forKey: "nativePreferences") }
    func loadLegacy() -> Data? {
        guard Bundle.main.bundleIdentifier != DefaultsStore.legacyDomain else { return nil }
        return UserDefaults(suiteName: DefaultsStore.legacyDomain)?.data(forKey: "nativePreferences")
    }
    func store(_ data: Data) { UserDefaults.standard.set(data, forKey: "nativePreferences") }
}
@MainActor final class Settings {
    private let storage: PreferenceStore
    var value: Preferences
    // Parameters exist for tests; the app uses the standard locations.
    init(storage: PreferenceStore = DefaultsStore(), supportRoot: URL? = nil) {
        self.storage = storage
        func decode(_ data: Data?) -> Preferences? {
            guard let data, let decoded = try? JSONDecoder().decode(Preferences.self, from: data), decoded.presenceLayout.valid else { return nil }
            return decoded
        }
        if let current = decode(storage.load()) {
            value = current
        } else if let previous = decode(storage.loadLegacy()) {
            // One-time copy from the previous bundle identifier; the old domain is left untouched.
            value = previous; save()
        } else {
            value = Preferences()
            // Read only the predecessor's settings, never Discord's data.
            let root = supportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            for name in ["tidalrpc", "tidalRPC"] {
                if let data = try? Data(contentsOf: root.appendingPathComponent(name + "/config.json")),
                   let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    value.showPresence = old["showPresence"] as? Bool ?? true
                    value.showButtons = old["showButtons"] as? Bool ?? true
                    value.autoStart = old["autoStart"] as? Bool ?? false
                    value.albumPrefs = old["albumPrefs"] as? Int ?? 0
                    if let layout = old["presenceLayout"], let bytes = try? JSONSerialization.data(withJSONObject: layout),
                       let decoded = try? JSONDecoder().decode(PresenceLayout.self, from: bytes), decoded.valid { value.presenceLayout = decoded }
                    break
                }
            }
            save()
        }
    }
    func save() { if let data = try? JSONEncoder().encode(value) { storage.store(data) } }
}
struct SongInfo {
    var title: String
    var artist: String
    var album: String?
    var year: String?
    var duration: Double = 0
    var artwork: String?
    var url: String?
}
struct Playback {
    var key: String
    var song: SongInfo
    var started: Date
    var pausedAt: Date?
    var end: Date { started.addingTimeInterval(song.duration) }
}
