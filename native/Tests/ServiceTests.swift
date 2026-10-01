import Foundation

// Compiled with native/Service sources except Main.swift.
final class MemoryStore: PreferenceStore {
    var data: Data?
    var legacy: Data?
    func load() -> Data? { data }
    func loadLegacy() -> Data? { legacy }
    func store(_ data: Data) { self.data = data }
}
@main enum ServiceTests {
    @MainActor static func main() {
        let base = PresenceLayout()
        check(base.valid, "default layout is valid")
        check(PresenceLayout(order: ["song", "song", "album"], statusField: "album").valid, "repeats and album are valid")
        check(PresenceLayout(order: ["song", "song", "song"], statusField: "song").valid, "one field in every row is valid")
        check(!PresenceLayout(order: ["song", "song", "album"], statusField: "artist").valid, "status must be a shown field")
        check(!PresenceLayout(order: ["song", "lyrics", "album"], statusField: "song").valid, "unknown field is invalid")
        check(!PresenceLayout(order: ["song", "album"], statusField: "song").valid, "exactly three rows")
        check(!PresenceLayout(appText: " \n ").valid, "blank app text is invalid")
        check(PresenceLayout(appText: String(repeating: "🎵", count: 128)).valid, "128 characters is valid")
        check(!PresenceLayout(appText: String(repeating: "a", count: 129)).valid, "129 characters is invalid")

        // Layouts saved before custom app text existed still decode.
        let legacy = #"{"order":["artist","song","app"],"statusField":"app"}"#
        let decoded = try? JSONDecoder().decode(PresenceLayout.self, from: Data(legacy.utf8))
        check(decoded?.appText == "Tidal" && decoded?.valid == true, "legacy layout migrates to Tidal")

        let settings = EditorSettings(layout: PresenceLayout(order: ["album", "song", "artist"], statusField: "song", appText: "TIDAL"),
                                      showButtons: false, includeYear: true)
        let round = (try? JSONEncoder().encode(settings)).flatMap { try? JSONDecoder().decode(EditorSettings.self, from: $0) }
        check(round == settings, "editor settings round-trip")

        // Preferences migrate once from the predecessor's config.json, then persist natively.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidalrpc-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("tidalrpc"), withIntermediateDirectories: true)
        let old = #"{"showPresence":false,"showButtons":false,"autoStart":true,"albumPrefs":1,"presenceLayout":{"order":["song","artist","app"],"statusField":"song"}}"#
        try? Data(old.utf8).write(to: root.appendingPathComponent("tidalrpc/config.json"))
        let memory = MemoryStore()
        let migrated = Settings(storage: memory, supportRoot: root).value
        check(!migrated.showPresence && !migrated.showButtons && migrated.autoStart && migrated.albumPrefs == 1, "old preferences migrate")
        check(migrated.presenceLayout == PresenceLayout(order: ["song", "artist", "app"], statusField: "song"), "old layout migrates")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("tidalrpc"))
        check(Settings(storage: memory, supportRoot: root).value.presenceLayout.order == ["song", "artist", "app"], "migrated preferences persist natively")
        let fresh = Settings(storage: MemoryStore(), supportRoot: root).value
        check(fresh.presenceLayout == PresenceLayout() && fresh.showPresence, "new installs get defaults")
        let renamed = MemoryStore()
        var previous = Preferences(); previous.presenceLayout = PresenceLayout(order: ["artist", "song", "app"], statusField: "artist", appText: "TIDAL"); previous.autoStart = true
        renamed.legacy = try? JSONEncoder().encode(previous)
        let copied = Settings(storage: renamed, supportRoot: root).value
        check(copied.presenceLayout == previous.presenceLayout && copied.autoStart, "preferences copy from the previous bundle identifier")
        check(renamed.data != nil, "copied preferences are saved under the new identifier")
        memory.data = Data("{}".utf8)
        check(Settings(storage: memory, supportRoot: root).value.presenceLayout == PresenceLayout(), "corrupt preferences fall back to defaults")
        try? FileManager.default.removeItem(at: root)

        check(Engine.permissionStatus != Engine.disconnectedStatus, "attention states are distinct")
        finish("Service")
    }
}
