import AppKit
import ServiceManagement
import Darwin

@MainActor final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let settings = Settings()
    private var engine: Engine!
    private var editor: EditorBridge!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let songLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recoveryItem = NSMenuItem(title: "", action: #selector(recover), keyEquivalent: "")
    private let showItem = NSMenuItem(title: "Show Rich Presence", action: #selector(togglePresence), keyEquivalent: "")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine = Engine(settings: settings); editor = EditorBridge(engine: engine)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "TidalRPC")
        statusItem.button?.toolTip = "TidalRPC"
        let menu = NSMenu(); menu.delegate = self
        menu.addItem(statusLine); menu.addItem(songLine)
        recoveryItem.target = self; menu.addItem(recoveryItem); menu.addItem(.separator())
        showItem.target = self; menu.addItem(showItem)
        add("Settings…", #selector(openEditor), to: menu, key: ",")
        menu.addItem(.separator())
        let help = NSMenu()
        add("Allow TIDAL Title Access…", #selector(allowTitles), to: help)
        add("Refresh Connection", #selector(refresh), to: help)
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: ""); helpItem.submenu = help; menu.addItem(helpItem)
        add("About TidalRPC", #selector(about), to: menu)
        menu.addItem(.separator()); add("Quit TidalRPC", #selector(quit), to: menu, key: "q")
        statusItem.menu = menu
        engine.onChange = { [weak self] in self?.updateMenu(); self?.editor.send() }
        engine.start(); updateMenu()
        // Preserve a previous opt-in; don't register login startup for new installs.
        if settings.value.autoStart && SMAppService.mainApp.status == .notRegistered {
            do { try SMAppService.mainApp.register() } catch { /* Settings reflects system registration status. */ }
        }
        if CommandLine.arguments.contains("--edit-presence") { editor.open() }
    }
    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    func menuWillOpen(_ menu: NSMenu) { engine.recheckTitleAccess(); updateMenu() }
    private func updateMenu() {
        statusLine.title = engine.status
        songLine.title = engine.playback.map { String(($0.song.artist + " — " + $0.song.title).prefix(100)) } ?? ""
        songLine.isHidden = engine.playback == nil
        let attention = engine.attention
        recoveryItem.title = attention?.action == "allowTitles" ? "Allow TIDAL Title Access…" : "Refresh Connection"
        recoveryItem.isHidden = attention == nil
        showItem.state = settings.value.showPresence ? .on : .off
    }
    @objc private func openEditor() { engine.recheckTitleAccess(); editor.open() }
    @objc private func togglePresence() { settings.value.showPresence.toggle(); engine.preferencesChanged() }
    @objc private func recover() { if engine.attention?.action == "allowTitles" { allowTitles() } else { refresh() } }
    @objc private func allowTitles() { engine.requestTitleAccess() }
    @objc private func refresh() { engine.refresh() }
    @objc private func about() {
        NSApp.activate()
        // Credits need explicit system attributes; a bare attributed string renders in Helvetica.
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let credits = NSAttributedString(string: "Shows what you’re playing in TIDAL on Discord.\nBased on rxri/tidalRPC.", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "TidalRPC", .credits: credits])
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { editor.open(); return false }
    func applicationWillTerminate(_ notification: Notification) { editor.stop(); engine.stop() }
}
@main enum NativeMain {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let identity = Bundle.main.bundleIdentifier ?? "io.github.yhkcyber.tidalrpc"
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: identity).first(where: { $0.processIdentifier != getpid() }) {
            other.activate(options: [.activateAllWindows]); return
        }
        let delegate = NativeAppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
