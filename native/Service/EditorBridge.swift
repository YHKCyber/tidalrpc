import AppKit
import ServiceManagement

// The settings the editor may change. Launch at login travels separately
// because it is owned by SMAppService rather than stored preferences.
struct EditorSettings: Codable, Equatable {
    var layout: PresenceLayout
    var showButtons: Bool
    var includeYear: Bool
}

@MainActor enum LoginItem {
    static var state: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        default: return "disabled"
        }
    }
    static func set(_ enabled: Bool, settings: Settings) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        settings.value.autoStart = enabled; settings.save()
    }
}

// Newline-delimited JSON over the editor's stdin/stdout. Every save carries a
// request id; the reply echoes it so the editor never lets a stale
// acknowledgement replace newer edits.
@MainActor final class EditorBridge {
    private var generation = 0
    private var child: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var received = Data()
    private var lastSnapshot = Data()
    let engine: Engine
    init(engine: Engine) { self.engine = engine }
    func open() {
        // macOS uses cooperative activation: the menu-bar app activates in response to
        // the user's click, then yields so the editor can come to the front.
        NSApp.activate()
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: (Bundle.main.bundleIdentifier ?? "io.github.yhkcyber.tidalrpc") + ".PresenceEditor")
        if child?.isRunning == true { send("activate"); activateChild(); return }
        guard let resources = Bundle.main.resourceURL else { return }
        generation += 1; let token = generation
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = resources.appendingPathComponent("PresenceEditor.app/Contents/MacOS/PresenceEditor")
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        self.input = input; self.output = output; self.errors = errors; child = process
        received.removeAll(); lastSnapshot.removeAll()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in if self?.generation == token { self?.read(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in if self?.generation == token { self?.cleanup() } }
        }
        do { try process.run() } catch {
            cleanup()
            let alert = NSAlert(); alert.messageText = "Couldn’t open TidalRPC Settings"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    // Second path for focus: while this app is still active from the user's click,
    // it may activate the editor directly once the editor has checked in.
    private func activateChild() {
        guard let pid = child?.processIdentifier else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
    private func cleanup() {
        generation += 1
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        child = nil; input = nil; output = nil; errors = nil; received.removeAll(); lastSnapshot.removeAll()
    }
    func stop() { child?.terminate(); cleanup() }
    private func read(_ data: Data) {
        received.append(data)
        guard received.count < 65536 else { stop(); return }
        while let end = received.firstIndex(of: 10) {
            let line = received[..<end]; received.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "ready": send(); activateChild()
            case "save": save(object)
            case "login": login(object)
            case "openLoginSettings": SMAppService.openSystemSettingsLoginItems()
            case "allowTitles": engine.requestTitleAccess()
            case "refresh": engine.refresh()
            default: break
            }
            guard child != nil else { return }
        }
    }
    private func save(_ object: [String: Any]) {
        guard let id = object["id"] as? Int else { return }
        var failure: String?
        if let raw = object["settings"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(EditorSettings.self, from: data), decoded.layout.valid {
            let prefs = engine.settings.value
            if prefs.presenceLayout != decoded.layout || prefs.showButtons != decoded.showButtons || (prefs.albumPrefs == 1) != decoded.includeYear {
                engine.settings.value.presenceLayout = decoded.layout
                engine.settings.value.showButtons = decoded.showButtons
                engine.settings.value.albumPrefs = decoded.includeYear ? 1 : 0
                // Publishing stays change-only and rate limited in DiscordIPC.
                engine.preferencesChanged()
            }
        } else {
            failure = "TidalRPC couldn’t accept these settings."
        }
        reply(["type": "saved", "id": id, "ok": failure == nil, "error": failure ?? NSNull(), "settings": currentSettings])
    }
    private func login(_ object: [String: Any]) {
        guard let id = object["id"] as? Int, let enabled = object["enabled"] as? Bool else { return }
        var failure: String?
        do { try LoginItem.set(enabled, settings: engine.settings) } catch { failure = error.localizedDescription }
        reply(["type": "login", "id": id, "ok": failure == nil, "error": failure ?? NSNull(), "login": LoginItem.state])
    }
    private var currentSettings: Any {
        let prefs = engine.settings.value
        let value = EditorSettings(layout: prefs.presenceLayout, showButtons: prefs.showButtons, includeYear: prefs.albumPrefs == 1)
        guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }
    func send(_ type: String = "snapshot") {
        guard child?.isRunning == true else { return }
        var attention: Any = NSNull()
        if let item = engine.attention { attention = ["message": item.message, "action": item.action] }
        let object: [String: Any] = ["type": type, "settings": currentSettings, "login": LoginItem.state, "connection": engine.status,
                                     "attention": attention, "song": engine.editorSong as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        if type == "snapshot" && lastSnapshot == data { return }
        lastSnapshot = data; write(data)
    }
    private func reply(_ object: [String: Any]) {
        guard child?.isRunning == true, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        write(data)
    }
    private func write(_ data: Data) {
        guard let writer = input?.fileHandleForWriting else { return }
        do { try writer.write(contentsOf: data + Data([10])) } catch { cleanup() }
    }
}
