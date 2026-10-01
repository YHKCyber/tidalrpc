import AppKit
import CoreGraphics

@MainActor final class Engine {
    let settings: Settings
    var onChange: (() -> Void)?
    private(set) var status = "Starting…" { didSet { if oldValue != status { onChange?() } } }
    private(set) var playback: Playback?
    private let rpc = DiscordIPC()
    private let metadata = Metadata()
    private var timer: Timer?
    private var lookup: Task<Void, Never>?
    private var revision = 0
    private var asleep = false
    private var observers: [NSObjectProtocol] = []
    private var powerObserver: NSObjectProtocol?
    private var retryMetadataAfter = Date.distantPast
    private var metadataComplete = false
    private var active = false
    private var permission = false
    static let permissionStatus = "Allow Screen Recording to read TIDAL titles"
    static let disconnectedStatus = "Waiting for Discord connection"
    init(settings: Settings) { self.settings = settings }
    // One recovery action, only when the user can do something about it.
    var attention: (message: String, action: String)? {
        switch status {
        case Engine.permissionStatus: return ("TidalRPC needs Screen Recording access to read TIDAL’s window title.", "allowTitles")
        case Engine.disconnectedStatus: return ("TidalRPC can’t reach Discord right now.", "refresh")
        default: return nil
        }
    }
    func start() {
        rpc.onStatus = { [weak self] text in self?.status = text }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let application = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      ["com.tidal.desktop", "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"].contains(application.bundleIdentifier ?? "") else { return }
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = true; self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = false; self?.refresh() }
        })
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    func refresh() {
        timer?.invalidate(); timer = nil
        let tidal = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tidal.desktop").isEmpty
        let discord = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"].contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        active = tidal && discord && settings.value.showPresence && !asleep
        if !active {
            revision += 1; lookup?.cancel(); lookup = nil; playback = nil
            rpc.setEnabled(false)
            status = asleep ? "Sleeping" : !settings.value.showPresence ? "Presence hidden" : !tidal ? "Waiting for TIDAL" : "Waiting for Discord"
            onChange?(); return
        }
        permission = CGPreflightScreenCaptureAccess()
        if !permission {
            revision += 1; lookup?.cancel(); lookup = nil; playback = nil
            rpc.setEnabled(false); status = Engine.permissionStatus
            onChange?(); return
        }
        rpc.setEnabled(true)
        poll()
    }
    func requestTitleAccess() {
        // Only invoked by an explicit user action. No screenshots are captured.
        if CGPreflightScreenCaptureAccess() { refresh(); return }
        // macOS prompts only once; afterwards the request returns false without UI.
        // An ad-hoc signed rebuild also invalidates an earlier grant while System
        // Settings still shows it switched on, so explain how to renew it.
        if !CGRequestScreenCaptureAccess() {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Allow TidalRPC to read TIDAL’s window title"
            alert.informativeText = "In Screen & System Audio Recording, turn TidalRPC on. If it already looks on, select it, remove it with the − button, then add it again and turn it on. TidalRPC notices the change the next time you open its menu."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        refresh()
    }
    // Cheap preflight used when the user looks at the app, so a new grant is
    // picked up without a restart and without any background polling.
    func recheckTitleAccess() {
        if status == Engine.permissionStatus && CGPreflightScreenCaptureAccess() { refresh() }
    }
    func stop() {
        active = false; timer?.invalidate(); lookup?.cancel(); rpc.setEnabled(false)
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }
    private func schedule(paused: Bool) {
        guard active else { return }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        let delay: Double = paused ? (low ? 10 : 5) : (low ? 4 : 2)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = delay * 0.2
    }
    private func title() -> String? {
        autoreleasepool { () -> String? in
            let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.tidal.desktop").map(\.processIdentifier))
            guard !pids.isEmpty,
                  let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
            // Filter by owner PID before accessing any window title.
            let candidate = windows.lazy.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
                .compactMap { $0[kCGWindowName as String] as? String }
                .first { $0.contains(" - ") && !$0.contains("MSCTFIME UI") && !$0.contains("Default IME") }
            return candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    private func poll() {
        timer?.invalidate(); timer = nil
        guard active else { return }
        let now = Date()
        guard let key = title(), !key.isEmpty else {
            if playback?.pausedAt == nil { playback?.pausedAt = now; onChange?() }
            revision += 1; lookup?.cancel(); lookup = nil
            rpc.update(nil)
            status = "TIDAL paused or idle"
            schedule(paused: true); return
        }
        if playback?.key != key {
            revision += 1; lookup?.cancel(); lookup = nil
            playback = Playback(key: key, song: Metadata.fallback(key), started: now)
            metadataComplete = false; retryMetadataAfter = .distantPast
            publish()
        } else if let paused = playback?.pausedAt {
            let resumedStart = playback!.started.addingTimeInterval(now.timeIntervalSince(paused))
            playback?.started = resumedStart
            playback?.pausedAt = nil; publish()
        } else if let p = playback, p.song.duration > 0, now.timeIntervalSince(p.end) >= 2 {
            // Window titles cannot expose seek/repeat position. Preserve the
            // original approximate timer behavior without refetching metadata.
            playback?.started = now; publish()
        }
        if !metadataComplete && lookup == nil && now >= retryMetadataAfter { fetch(key) }
        schedule(paused: false)
    }
    private func fetch(_ key: String) {
        let token = revision
        lookup = Task { [weak self, metadata] in
            do {
                let info = try await metadata.lookup(key)
                guard let self, !Task.isCancelled, self.revision == token, self.playback?.key == key else { return }
                self.playback?.song = info; self.metadataComplete = true; self.lookup = nil; self.publish()
            } catch {
                guard let self, self.revision == token, !Task.isCancelled else { return }
                self.lookup = nil; self.retryMetadataAfter = Date().addingTimeInterval(60)
                self.status = "Using track title; metadata unavailable"
            }
        }
    }
    func preferencesChanged() { settings.save(); refresh(); publish() }
    private func publish() {
        guard active, let p = playback, p.pausedAt == nil else { rpc.update(nil); onChange?(); return }
        let prefs = settings.value, layout = prefs.presenceLayout
        // Album falls back to the title until metadata arrives or when TIDAL has none.
        let values = ["app": layout.appText, "song": p.song.title, "artist": p.song.artist, "album": p.song.album ?? p.song.title]
        func text(_ field: String) -> String { String((values[field] ?? "Tidal").prefix(128)) }
        var activity: [String: Any] = ["type": 0, "name": text(layout.order[0]), "details": text(layout.order[1]),
            "state": text(layout.order[2]), "status_display_type": [0, 2, 1][layout.order.firstIndex(of: layout.statusField) ?? 0], "instance": false]
        activity["timestamps"] = p.song.duration > 0 ? ["end": Int(p.end.timeIntervalSince1970)] : ["start": Int(p.started.timeIntervalSince1970)]
        var assets: [String: String] = ["large_image": p.song.artwork ?? "logo"]
        if let album = p.song.album {
            assets["large_text"] = String((album + (prefs.albumPrefs == 1 ? p.song.year.map { " (\($0))" } ?? "" : "")).prefix(128))
        }
        activity["assets"] = assets
        if prefs.showButtons, let link = p.song.url, let url = URL(string: link), url.scheme == "https" {
            activity["buttons"] = [["label": "Play on Your Streaming Platform", "url": link + "?u"]]
        }
        rpc.update(activity); onChange?()
    }
    var editorSong: [String: Any]? {
        guard let p = playback, p.pausedAt == nil else { return nil }
        var result: [String: Any] = ["title": p.song.title, "artist": p.song.artist, "endTime": p.song.duration > 0 ? p.end.timeIntervalSince1970 : 0]
        if let artwork = p.song.artwork { result["artwork"] = artwork }
        if let album = p.song.album { result["album"] = album }
        return result
    }
}
