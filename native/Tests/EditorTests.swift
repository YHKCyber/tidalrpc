import Foundation

// Compiled with PresenceEditor.swift (its @main removed by scripts/ci.sh).
@MainActor final class Outbox {
    var commands: [[String: Any]] = []
    var saves: [[String: Any]] { commands.filter { $0["type"] as? String == "save" } }
    func attach(_ model: EditorModel) {
        model.output = { [unowned self] data in
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { commands.append(object) }
        }
        model.undo.groupsByEvent = false
    }
}
@MainActor func step(_ model: EditorModel, _ body: () -> Void) {
    model.undo.beginUndoGrouping(); body(); model.undo.endUndoGrouping()
}
@MainActor func snapshot(_ settings: DraftSettings, song: Track? = nil) -> Incoming {
    Incoming(type: "snapshot", settings: settings, login: "disabled", song: song)
}
@MainActor func ack(_ id: Int, _ settings: DraftSettings, ok: Bool = true) -> Incoming {
    Incoming(type: "saved", id: id, ok: ok, error: ok ? nil : "failed", settings: settings)
}

@main enum EditorTests {
    @MainActor static func main() {
        let initial = DraftSettings(layout: Layout(order: [.app, .song, .artist], statusField: .artist, appText: "Tidal"))

        // Snapshots seed the draft once; later ones only update metadata.
        do {
            let model = EditorModel(), box = Outbox(); box.attach(model)
            model.receive(snapshot(initial))
            var other = initial; other.layout.appText = "Elsewhere"
            step(model) { model.change("Move") { $0.layout.order = [.artist, .song, .app] } }
            model.receive(snapshot(other, song: Track(title: "T", artist: "A", album: nil, artwork: nil, endTime: 0)))
            check(model.draft.layout.order == [.artist, .song, .app], "snapshot does not reset the draft")
            check(model.draft.layout.appText == "Tidal", "snapshot does not replace app text")
            check(model.track?.title == "T", "snapshot updates the track")
            check(model.text(.album) == "T", "album falls back to the title")
        }

        // Out-of-order and stale acknowledgements never replace newer edits.
        do {
            let model = EditorModel(), box = Outbox(); box.attach(model)
            model.receive(snapshot(initial))
            step(model) { model.change("Move") { $0.layout.order = [.song, .app, .artist] } }
            let first = model.draft
            step(model) { model.change("Status") { $0.layout.statusField = .song } }
            let second = model.draft
            check(box.saves.map { $0["id"] as? Int } == [1, 2], "each change sends one save with increasing ids")
            model.receive(ack(2, second))
            model.receive(ack(1, first))
            check(model.saved == second, "stale acknowledgement is ignored")
            check(model.draft == second, "acknowledgements never touch the draft")
            check(!model.hasPendingWork, "nothing pending after the newest acknowledgement")
            model.receive(ack(2, second))
            check(model.saved == second, "duplicate acknowledgement is ignored")
        }

        // Failed saves keep the draft and can be retried.
        do {
            let model = EditorModel(), box = Outbox(); box.attach(model)
            model.receive(snapshot(initial))
            step(model) { model.change("Links") { $0.showButtons = false } }
            model.receive(ack(1, initial, ok: false))
            check(model.saveError != nil, "failure is reported")
            check(model.draft.showButtons == false, "failure keeps the draft")
            model.retry()
            check(box.saves.count == 2 && box.saves.last?["id"] as? Int == 2, "retry resends")
        }

        // Invalid app text is never sent; other edits still save with the saved text.
        do {
            let model = EditorModel(), box = Outbox(); box.attach(model)
            model.receive(snapshot(initial))
            step(model) { model.type("   ") }
            check(!model.draft.layout.textValid, "blank text is invalid")
            check(model.text(.app) == "Tidal", "preview shows the published text while invalid")
            step(model) { model.change("Year") { $0.includeYear = true } }
            let sent = (box.saves.last?["settings"] as? [String: Any])?["layout"] as? [String: Any]
            check(sent?["appText"] as? String == "Tidal", "invalid text is replaced by the saved text")
            step(model) { model.type(String(repeating: "x", count: 129)) }
            check(!model.draft.layout.textValid, "129 characters is invalid")
        }

        // Row fields: repeats, album and status following.
        do {
            let model = EditorModel(), box = Outbox(); box.attach(model)
            model.receive(snapshot(initial))
            step(model) { model.setField(.song, row: 2) }
            check(model.draft.layout.order == [.app, .song, .song], "rows may repeat")
            check(model.draft.layout.statusField == .song, "status follows when its field disappears")
            check(model.statusChoices == [.app, .song], "status choices are the unique shown fields")
            step(model) { model.setField(.album, row: 0) }
            check(model.draft.layout.order == [.album, .song, .song], "album can be chosen")
            step(model) { model.move(row: 0, to: 2) }
            check(model.draft.layout.order == [.song, .song, .album], "rows move by position")
            step(model) { model.change("Reset") { $0.layout = .original(appText: $0.layout.appText) } }
            check(model.draft.layout == Layout(order: [.app, .song, .artist], statusField: .app, appText: "Tidal"), "reset restores the original preset")
        }

        // Undo and redo restore whole steps and save each time.
        do {
            let model = EditorModel(), box = Outbox(); box.attach(model)
            model.receive(snapshot(initial))
            step(model) { model.move(row: 0, to: 2) }
            step(model) { model.type("L"); model.type("Li"); model.type("Lis") }
            check(model.draft.layout.appText == "Lis", "typing applies")
            model.undo.undo()
            check(model.draft.layout.appText == "Tidal", "typing undoes as one step")
            model.undo.undo()
            check(model.draft.layout.order == initial.layout.order, "move undoes")
            model.undo.redo()
            check(model.draft.layout.order == [.song, .artist, .app], "move redoes")
            check(box.saves.count >= 3, "undo and redo save")
        }
        finish("Editor")
    }
}
