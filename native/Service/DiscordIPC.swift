import Foundation
import Network
import Darwin

// Only the app's own Rich Presence IPC commands are sent. No subscriptions,
// user tokens, channel queries, or logging of Discord response payloads.
@MainActor final class DiscordIPC {
    var onStatus: ((String) -> Void)?
    private var connection: NWConnection?
    private var input = Data()
    private var enabled = false
    private var ready = false
    private var desired: [String: Any]?
    private var desiredData = Data()
    private var accepted: Data?
    private var pending: (nonce: String, data: Data)?
    private var retry: Timer?
    private var deadline: Timer?
    private var flushTimer: Timer?
    private var backoff: Double = 1
    private var lastSend = Date.distantPast
    private var generation = 0

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value { connect() } else { reset(); onStatus?("Presence inactive") }
    }
    func update(_ activity: [String: Any]?) {
        desired = activity
        desiredData = (try? JSONSerialization.data(withJSONObject: activity ?? [:], options: [.sortedKeys])) ?? Data()
        flush()
    }
    private func reset() {
        generation += 1
        retry?.invalidate(); retry = nil
        deadline?.invalidate(); deadline = nil
        flushTimer?.invalidate(); flushTimer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        input.removeAll(keepingCapacity: false); ready = false; pending = nil; accepted = nil
    }
    private func fail() {
        guard enabled else { return }
        reset()
        onStatus?(Engine.disconnectedStatus)
        let delay = backoff; backoff = min(backoff * 2, 60)
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect() }
        }
        retry?.tolerance = delay * 0.2
    }
    private func connect() {
        guard enabled, connection == nil else { return }
        let env = ProcessInfo.processInfo.environment
        let roots = [env["XDG_RUNTIME_DIR"], env["TMPDIR"], NSTemporaryDirectory(), "/tmp"].compactMap { $0 }
        let paths = roots.flatMap { root in (0..<10).map { URL(fileURLWithPath: root).appendingPathComponent("discord-ipc-\($0)").path } }
        guard let path = paths.first(where: { path in
            var st = stat()
            return lstat(path, &st) == 0 && st.st_uid == getuid() && (st.st_mode & S_IFMT) == S_IFSOCK
        }) else { fail(); return }
        generation += 1; let token = generation
        let c = NWConnection(to: .unix(path: path), using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                switch state {
                case .ready:
                    let clientID = Bundle.main.object(forInfoDictionaryKey: "DiscordClientID") as? String ?? "793071505327652864"
                    self.send(op: 0, object: ["v": 1, "client_id": clientID])
                    self.receive(token)
                case .failed, .waiting: self.fail()
                default: break
                }
            }
        }
        c.start(queue: .main)
        deadline = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.generation == token { self?.fail() } }
        }
    }
    private func send(op: UInt32, object: Any) {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]), body.count <= 1_048_576 else { return }
        var op = op.littleEndian, size = UInt32(body.count).littleEndian
        var bytes = withUnsafeBytes(of: &op) { Data($0) }
        bytes.append(withUnsafeBytes(of: &size) { Data($0) }); bytes.append(body)
        let token = generation
        connection?.send(content: bytes, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated { if error != nil, self?.generation == token { self?.fail() } }
        })
    }
    private func receive(_ token: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                if let data { self.input.append(data); self.consume() }
                guard self.generation == token else { return }
                if complete || error != nil { self.fail() } else { self.receive(token) }
            }
        }
    }
    private func consume() {
        while input.count >= 8 {
            let header = [UInt8](input.prefix(8))
            func word(_ start: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(header[start + $1]) << UInt32(8 * $1) } }
            let op = word(0), length = Int(word(4))
            guard length <= 1_048_576 else { fail(); return }
            guard input.count >= 8 + length else { return }
            let body = input.subdata(in: 8..<(8 + length)); input = Data(input.dropFirst(8 + length))
            guard let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { fail(); return }
            if op == 3 { send(op: 4, object: json); continue }
            if op == 2 { fail(); return }
            guard op == 1, let object = json as? [String: Any] else { continue }
            if object["evt"] as? String == "READY" {
                ready = true; backoff = 1; deadline?.invalidate(); deadline = nil
                onStatus?("Connected to Discord"); flush()
            } else if let nonce = object["nonce"] as? String, nonce == pending?.nonce {
                deadline?.invalidate(); deadline = nil
                if object["evt"] as? String == "ERROR" { pending = nil; fail(); return }
                accepted = pending?.data; pending = nil
                onStatus?(desired == nil ? "Presence cleared" : "Active")
                flush()
            }
        }
    }
    private func flush() {
        guard enabled, ready, pending == nil, accepted != desiredData else { return }
        let delay = 5 - Date().timeIntervalSince(lastSend)
        if delay > 0 {
            guard flushTimer == nil else { return }
            flushTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushTimer = nil; self?.flush() }
            }
            flushTimer?.tolerance = 0.25
            return
        }
        let nonce = UUID().uuidString
        pending = (nonce, desiredData); lastSend = Date()
        var args: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]
        if let desired { args["activity"] = desired }
        send(op: 1, object: ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce])
        deadline = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail() }
        }
    }
}
