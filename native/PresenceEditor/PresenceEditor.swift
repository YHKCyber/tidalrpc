import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The editor is a short-lived native process. It has no background timer or
// connection to Discord: the menu-bar app supplies its own playback metadata
// and persists every change the editor sends.
enum PresenceField: String, CaseIterable, Codable, Identifiable {
    case app, song, artist, album
    var id: String { rawValue }
    var label: String { switch self { case .app: "App text"; case .song: "Song"; case .artist: "Artist"; case .album: "Album" } }
    var icon: String { switch self { case .app: "textformat"; case .song: "music.note"; case .artist: "person.fill"; case .album: "square.stack" } }
}
struct Layout: Codable, Equatable {
    var order: [PresenceField]
    var statusField: PresenceField
    var appText: String
    init(order: [PresenceField] = [.app, .song, .artist], statusField: PresenceField = .artist, appText: String = "Tidal") {
        self.order = order; self.statusField = statusField; self.appText = appText
    }
    private enum CodingKeys: String, CodingKey { case order, statusField, appText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decode([PresenceField].self, forKey: .order)
        statusField = try c.decode(PresenceField.self, forKey: .statusField)
        appText = try c.decodeIfPresent(String.self, forKey: .appText) ?? "Tidal"
    }
    // The former "Original" preset: original row order and status, keeping custom text.
    static func original(appText: String) -> Layout { Layout(order: [.app, .song, .artist], statusField: .app, appText: appText) }
    var textValid: Bool { !appText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && appText.count <= 128 }
}
struct DraftSettings: Codable, Equatable {
    var layout = Layout()
    var showButtons = true
    var includeYear = false
}
struct Track: Codable, Equatable {
    var title: String
    var artist: String
    var album: String?
    var artwork: String?
    var endTime: Double
}
struct Attention: Codable, Equatable {
    var message: String
    var action: String
    var buttonTitle: String { action == "allowTitles" ? "Allow Access…" : "Refresh Connection" }
}
struct Incoming: Decodable {
    var type: String
    var id: Int?
    var ok: Bool?
    var error: String?
    var settings: DraftSettings?
    var login: String?
    var attention: Attention?
    var song: Track?
}
struct Command: Encodable {
    var type: String
    var id: Int?
    var settings: DraftSettings?
    var enabled: Bool?
}
let appTextSuggestions = ["Tidal", "TIDAL", "Listening with Tidal", "Listening with TIDAL"]

@MainActor final class EditorModel: ObservableObject {
    static let shared = EditorModel()
    @Published var draft = DraftSettings()
    @Published private(set) var saved = DraftSettings()
    @Published var track: Track?
    @Published var attention: Attention?
    @Published var login = "disabled"
    @Published var loginError: String?
    @Published var saveError: String?
    @Published var loaded = false
    @Published var targeted: Int?
    @Published var moreOptions = false
    let undo = UndoManager()
    weak var window: NSWindow?
    var windowDelegate: WindowDelegate?
    private var lastSent = DraftSettings()
    private var sentID = 0, ackedID = 0, loginID = 0, loginAckedID = 0
    private var debounce: DispatchWorkItem?
    private var typing = false
    private var closing = false
    private(set) var quitting = false

    func text(_ field: PresenceField) -> String {
        switch field {
        // Invalid text is never published, so preview what Discord would actually show.
        case .app: return draft.layout.textValid ? draft.layout.appText : saved.layout.appText
        case .song: return track?.title ?? "CSIRAC"
        case .artist: return track?.artist ?? "Ninajirachi"
        // Matches the service: the title stands in when TIDAL has no album.
        case .album: return track.map { $0.album ?? $0.title } ?? "I Love My Computer"
        }
    }
    // Replaceable so scripts/ci.sh can inspect outgoing commands.
    var output: (Data) -> Void = { FileHandle.standardOutput.write($0) }
    func send(_ command: Command) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        output(data + Data([10]))
    }
    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let message = try? JSONDecoder().decode(Incoming.self, from: data) else { continue }
                Task { @MainActor [weak self] in self?.receive(message) }
            }
            // Parent closed the pipe: nothing can be saved any more.
            Task { @MainActor in EditorModel.shared.quitting = true; NSApp.terminate(nil) }
        }
        send(Command(type: "ready"))
    }
    func receive(_ message: Incoming) {
        switch message.type {
        case "saved":
            guard let id = message.id, id > ackedID else { return }  // Stale or duplicate acknowledgement.
            ackedID = id
            if let settings = message.settings { saved = settings }
            if message.ok == true {
                if id == sentID { saveError = nil }
                finishCloseIfReady()
            } else {
                saveFailed(message.error ?? "TidalRPC couldn’t save your changes.")
            }
        case "login":
            guard let id = message.id, id > loginAckedID else { return }
            loginAckedID = id
            guard id == loginID else { return }  // A newer request is still outstanding.
            login = message.login ?? login
            loginError = message.ok == true ? nil : message.error
        default:
            // Snapshots carry metadata and status; after the first one they never touch the draft.
            if !loaded, let settings = message.settings {
                saved = settings; draft = settings; lastSent = settings; loaded = true
            }
            track = message.song
            attention = message.attention
            if let login = message.login, loginAckedID == loginID { self.login = login }
            if message.type == "activate" { bringToFront() }
        }
    }

    // MARK: Editing and undo
    private func registerUndo(restoring old: DraftSettings, name: String) {
        undo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.set(old, name: name) }
        }
        undo.setActionName(name)
    }
    func set(_ next: DraftSettings, name: String) {
        typing = false
        guard next != draft else { return }
        registerUndo(restoring: draft, name: name)
        draft = next
        save()
    }
    func change(_ name: String, _ body: (inout DraftSettings) -> Void) {
        var next = draft; body(&next); set(next, name: name)
    }
    // Typing coalesces into one undo step until another action or the field ends editing.
    func type(_ text: String) {
        guard text != draft.layout.appText else { return }
        if !typing { typing = true; registerUndo(restoring: draft, name: "Typing") }
        draft.layout.appText = text
        debounce?.cancel(); debounce = nil
        guard draft.layout.textValid else { return }
        let work = DispatchWorkItem { MainActor.assumeIsolated { EditorModel.shared.save() } }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    func endTyping() {
        typing = false
        if debounce != nil { save() }
    }
    // Rows are addressed by position because any field may appear in several rows.
    func move(row from: Int, to: Int) {
        let order = draft.layout.order
        guard from != to, order.indices.contains(from), order.indices.contains(to) else { return }
        change("Move Row") { $0.layout.order.insert($0.layout.order.remove(at: from), at: to) }
    }
    func setField(_ field: PresenceField, row: Int) {
        guard draft.layout.order.indices.contains(row) else { return }
        change("Change Row") {
            $0.layout.order[row] = field
            // The status must name a shown field; follow the row the user just changed.
            if !$0.layout.order.contains($0.layout.statusField) { $0.layout.statusField = field }
        }
    }
    var statusChoices: [PresenceField] {
        draft.layout.order.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    func suggest(_ text: String) {
        window?.makeFirstResponder(nil)
        change("Change App Text") { $0.layout.appText = text }
    }

    // MARK: Saving
    // Invalid app text is never sent; other edits still save with the last saved text.
    private var savable: DraftSettings {
        var value = draft
        if !value.layout.textValid { value.layout.appText = saved.layout.appText }
        return value
    }
    var hasPendingWork: Bool { savable != saved || sentID > ackedID || debounce != nil }
    func save() {
        debounce?.cancel(); debounce = nil
        guard loaded else { return }
        let value = savable
        guard value != lastSent else { finishCloseIfReady(); return }
        sentID += 1; lastSent = value
        let id = sentID
        send(Command(type: "save", id: id, settings: value))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                let model = EditorModel.shared
                if model.ackedID < id && model.sentID == id { model.saveFailed("TidalRPC didn’t confirm your changes.") }
            }
        }
    }
    private func saveFailed(_ text: String) {
        lastSent = saved  // Allows Retry to resend the retained draft.
        saveError = text
        guard closing else { return }
        closing = false
        let alert = NSAlert()
        alert.messageText = "Your changes weren’t saved"
        alert.informativeText = text
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn { closing = true; retry() } else { quit() }
    }
    func retry() { saveError = nil; save() }
    func discard() {
        debounce?.cancel(); debounce = nil
        typing = false; saveError = nil
        draft = saved; lastSent = saved
    }
    func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
    func setLogin(_ enabled: Bool) {
        loginID += 1; loginError = nil
        login = enabled ? "enabled" : "disabled"
        send(Command(type: "login", id: loginID, enabled: enabled))
    }

    // MARK: Closing
    // Returns true when the editor can close now; otherwise flushes and closes after acknowledgement.
    func requestClose() -> Bool {
        if quitting || !loaded { return true }
        window?.makeFirstResponder(nil)
        if !draft.layout.textValid {
            let alert = NSAlert()
            alert.messageText = "App text can’t be saved"
            alert.informativeText = "Enter 1–128 characters, or discard this edit to keep “\(saved.layout.appText)”."
            alert.addButton(withTitle: "Fix")
            alert.addButton(withTitle: "Discard")
            if alert.runModal() == .alertFirstButtonReturn { return false }
            draft.layout.appText = saved.layout.appText
        }
        guard hasPendingWork else { return true }
        closing = true
        save()
        return false
    }
    private func finishCloseIfReady() {
        if closing && ackedID == sentID && debounce == nil && saveError == nil { quit() }
    }
    private func quit() { quitting = true; NSApp.terminate(nil) }
}

@MainActor final class WindowDelegate: NSObject, NSWindowDelegate {
    unowned let model: EditorModel
    // Typing undo is coalesced by the model, so the field editor keeps none of its own.
    private lazy var fieldEditor: NSTextView = {
        let view = NSTextView(); view.isFieldEditor = true; view.allowsUndo = false; return view
    }()
    init(_ model: EditorModel) { self.model = model }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.requestClose() }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { client is NSTextField ? fieldEditor : nil }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var endEditing: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        endEditing = NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EditorModel.shared.endTyping() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        EditorModel.shared.requestClose() ? .terminateNow : .terminateCancel
    }
}
@main struct PresenceEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private let model = EditorModel.shared
    var body: some Scene {
        Window("TidalRPC Settings", id: "settings") {
            EditorView(model: model)
        }
        .defaultSize(width: 620, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }
    private let labelWidth: CGFloat = 150
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let attention = model.attention {
                    notice(attention.message, systemImage: "exclamationmark.triangle.fill") {
                        Button(attention.buttonTitle) { model.send(Command(type: attention.action)) }
                    }
                }
                if let error = model.saveError {
                    notice(error, systemImage: "exclamationmark.circle.fill") {
                        Button("Discard") { model.discard() }
                        Button("Retry") { model.retry() }
                    }
                }
                Text("Presence preview").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    presenceCard
                    Text("Drag rows to reorder. Use each row’s arrows to choose what it shows.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Playing \(model.text(model.draft.layout.statusField))").lineLimit(1).truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status preview: Playing \(model.text(model.draft.layout.statusField))")
                Divider()
                controls
                Divider()
                DisclosureGroup("More options", isExpanded: $model.moreOptions) { moreOptions }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 460, minHeight: 420)
        .disabled(!model.loaded)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            model.start()
            DispatchQueue.main.async {
                let window = NSApp.windows.first { $0.canBecomeMain }
                let handler = WindowDelegate(model)
                model.windowDelegate = handler
                window?.delegate = handler
                model.window = window
                model.bringToFront()
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Show after “Playing”").frame(width: labelWidth, alignment: .leading)
                Spacer()
                Picker("Show after “Playing”", selection: Binding(
                    get: { model.draft.layout.statusField },
                    set: { value in model.change("Change Status Field") { $0.layout.statusField = value } })) {
                    ForEach(model.statusChoices) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("App text").frame(width: labelWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("App text", text: Binding(get: { model.draft.layout.appText }, set: { model.type($0) }), prompt: Text("Tidal"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { model.endTyping() }
                    if !model.draft.layout.textValid {
                        Text(model.draft.layout.appText.count > 128 ? "Use 128 characters or fewer." : "Enter some text.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Menu("Suggestions") {
                    ForEach(appTextSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { model.suggest(suggestion) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show track link", isOn: Binding(get: { model.draft.showButtons },
                                                    set: { value in model.change("Show Track Link") { $0.showButtons = value } }))
            Toggle("Include album year", isOn: Binding(get: { model.draft.includeYear },
                                                       set: { value in model.change("Include Album Year") { $0.includeYear = value } }))
            Toggle("Launch at login", isOn: Binding(get: { model.login == "enabled" || model.login == "requiresApproval" },
                                                    set: { model.setLogin($0) }))
            if model.login == "requiresApproval" {
                HStack {
                    Text("Approve TidalRPC in Login Items to finish.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items…") { model.send(Command(type: "openLoginSettings")) }.controlSize(.small)
                }
                .padding(.leading, 20)
            }
            if let error = model.loginError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 20)
            }
            Divider()
            Button("Reset presence layout") {
                withAnimation(motion) { model.change("Reset Presence Layout") { $0.layout = .original(appText: $0.layout.appText) } }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.top, 8)
    }

    private func notice<Actions: View>(_ text: String, systemImage: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Label(text, systemImage: systemImage).symbolRenderingMode(.multicolor)
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
            } else {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        }
    }

    // Opaque Discord-style card so the preview stays readable on any material.
    private var presenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Playing").font(.system(size: 15, weight: .semibold))
            HStack(alignment: .top, spacing: 18) {
                artwork.frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel("Album artwork")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.draft.layout.order.indices, id: \.self) { index in row(index) }
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        if let end = model.track?.endTime, end > Date().timeIntervalSince1970 {
                            Text(timerInterval: Date()...Date(timeIntervalSince1970: end), countsDown: true)
                                .monospacedDigit().frame(maxWidth: 85, alignment: .leading)
                        } else {
                            Text(model.track == nil ? "2:23" : "0:00")
                        }
                    }
                    .font(.system(size: 14).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    .padding(.leading, 8).padding(.top, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.track == nil ? "Example remaining time" : "Remaining time")
                }
            }
        }
        .foregroundStyle(.white.opacity(0.94))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.17, green: 0.18, blue: 0.20), in: .rect(cornerRadius: 16))
        .animation(motion, value: model.draft.layout.order)
        .environment(\.colorScheme, .dark)
    }
    private func row(_ index: Int) -> some View {
        let field = model.draft.layout.order[index], last = model.draft.layout.order.count - 1
        return HStack(spacing: 8) {
            Text(model.text(field)).font(.system(size: index == 0 ? 20 : 16, weight: index == 0 ? .bold : .regular))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Menu {
                fieldPicker(index)
            } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.white.opacity(0.45))
            .help("Choose what this row shows")
            .accessibilityLabel("Row \(index + 1) field")
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(model.targeted == index ? 0.14 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .draggable(String(index)) {
            Label(model.text(field), systemImage: field.icon)
                .font(.headline).padding(10).background(.regularMaterial, in: .rect(cornerRadius: 10))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let source = Int(raw) else { return false }
            withAnimation(motion) { model.move(row: source, to: index) }
            return true
        } isTargeted: { model.targeted = $0 ? index : (model.targeted == index ? nil : model.targeted) }
        .focusable()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            withAnimation(motion) { model.move(row: index, to: index + (press.key == .upArrow ? -1 : 1)) }
            return .handled
        }
        .contextMenu {
            Menu("Show") { fieldPicker(index) }
            Divider()
            Button("Move Up", systemImage: "arrow.up") { withAnimation(motion) { model.move(row: index, to: index - 1) } }
                .disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") { withAnimation(motion) { model.move(row: index, to: index + 1) } }
                .disabled(index == last)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Row \(index + 1) of 3, \(field.label): \(model.text(field))")
        .accessibilityHint("Option-Up or Option-Down arrow to reorder")
        .accessibilityAction(named: "Move Up") { withAnimation(motion) { model.move(row: index, to: index - 1) } }
        .accessibilityAction(named: "Move Down") { withAnimation(motion) { model.move(row: index, to: index + 1) } }
    }
    private func fieldPicker(_ index: Int) -> some View {
        Picker("Show", selection: Binding(get: { model.draft.layout.order[index] },
                                          set: { value in withAnimation(motion) { model.setField(value, row: index) } })) {
            ForEach(PresenceField.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
        }
        .pickerStyle(.inline).labelsHidden()
    }
    @ViewBuilder private var artwork: some View {
        if let string = model.track?.artwork, let url = URL(string: string), url.scheme == "https" {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
        } else { placeholder }
    }
    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.12)
            Image(systemName: "music.note").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.7))
        }
    }
}
