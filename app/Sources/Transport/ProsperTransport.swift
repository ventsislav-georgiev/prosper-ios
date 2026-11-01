import Foundation
import Network
import CryptoKit

/// Talks to Prosper's `DchSessionServer` over the length-prefixed binary frame
/// protocol (see the server's `DchFrame`). One TCP connection per operation:
/// list/kill are request→response; attach/create return a live `ProsperStream`.
///
/// Trust: Tailscale is the boundary. No tokens — the server only binds to its
/// Tailscale address and re-checks the peer is on the tailnet.
final class ProsperTransport: SessionTransport {
    private let host: String
    private let port: UInt16

    init(host: String, port: UInt16 = 8771) {
        self.host = host
        self.port = port
    }

    // Mirror of the server's DchFrame type bytes.
    private enum F {
        static let attach: UInt8 = 0x01, create: UInt8 = 0x02, list: UInt8 = 0x03
        static let kill: UInt8 = 0x04, resize: UInt8 = 0x05, rename: UInt8 = 0x06
        static let machineInfo: UInt8 = 0x08, snapshot: UInt8 = 0x09, putClipboard: UInt8 = 0x0a
        static let history: UInt8 = 0x0b, revive: UInt8 = 0x0c, restart: UInt8 = 0x0d, stop: UInt8 = 0x0e
        static let library: UInt8 = 0x0f
        static let data: UInt8 = 0x10
        static let listResp: UInt8 = 0x11, exit: UInt8 = 0x12, error: UInt8 = 0x13, ok: UInt8 = 0x14
        static let machineInfoResp: UInt8 = 0x18, snapshotResp: UInt8 = 0x19, historyResp: UInt8 = 0x1b
        static let libraryResp: UInt8 = 0x1c
        static let pin: UInt8 = 0x24, forget: UInt8 = 0x25, forgetAll: UInt8 = 0x26   // #634
        // #646: the Mac's local-model chat.
        static let models: UInt8 = 0x1e, chat: UInt8 = 0x1f, chatDelta: UInt8 = 0x20, chatDone: UInt8 = 0x21
        static let modelsResp: UInt8 = 0x27
        // #615: the Mac's palette commands.
        static let commands: UInt8 = 0x28, runCommand: UInt8 = 0x29, commandsResp: UInt8 = 0x2a, commandResult: UInt8 = 0x2b
        // #621: clipboard history sync.
        static let clipboardList: UInt8 = 0x15, clipboardItem: UInt8 = 0x16
        static let addClipboardHistory: UInt8 = 0x22, clipboardUpload: UInt8 = 0x23
        static let clipboardItemResp: UInt8 = 0x1a, clipboardResp: UInt8 = 0x1d
    }

    /// One-shot identity handshake (PLAN §2a). Sends `0x08`, reads the `0x18` reply
    /// `{device_id, hostname, wakeId?}`. Bounded by `timeout` — a legacy Mac hits the
    /// server's `default: break` and never answers, so we return `nil` rather than
    /// block the connect path. wakeId may be absent (wake feature off / not configured).
    func machineInfo(timeout: TimeInterval = 2) async throws -> MachineInfo? {
        let conn = try await connect()
        defer { conn.cancel() }
        conn.send(content: FrameCodec.encode(F.machineInfo, Data()), completion: .contentProcessed { _ in })
        // Race the read against a timeout; legacy Macs simply never reply.
        let reply: (UInt8, Data)? = try? await withThrowingTaskGroup(of: (UInt8, Data)?.self) { group in
            group.addTask { try await FrameCodec.readOne(from: conn) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let (type, payload) = reply, type == F.machineInfoResp else { return nil }
        return Self.decodeMachineInfo(payload)
    }

    static func decodeMachineInfo(_ payload: Data) -> MachineInfo? {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let deviceId = o["device_id"] as? String else { return nil }
        return MachineInfo(deviceId: deviceId,
                           hostname: o["hostname"] as? String,
                           wakeId: o["wakeId"] as? String,
                           ops: SessionVerb.offered(o["ops"]))
    }

    func listSessions() async throws -> [DchSession] {
        let (type, payload) = try await oneShot(send: F.list, payload: Data())
        guard type == F.listResp else { throw TransportError.protocolError("expected list") }
        return try Self.decodeList(payload)
    }

    /// The list reply's rows. A payload that isn't a JSON array throws, so the screen keeps
    /// its rows and shows the error instead of reading it as "no sessions".
    static func decodeList(_ payload: Data) throws -> [DchSession] {
        guard let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] else {
            throw TransportError.protocolError("unreadable session list")
        }
        return arr.compactMap { o in
            (o["name"] as? String).map {
                DchSession(name: $0, alias: o["alias"] as? String, state: o["state"] as? String,
                           agents: o["agents"] as? Int ?? 0, meta: SessionMeta(json: o["meta"]))
            }
        }
    }

    func kill(name: String) async throws {
        _ = try await oneShot(send: F.kill, payload: json(["name": name]))
    }

    func rename(name: String, alias: String?) async throws {
        _ = try await oneShot(send: F.rename, payload: json(["name": name, "alias": alias ?? ""]))
    }

    func history() async throws -> [DchHistoryRow] {
        try Self.decodeHistory(try await verb(F.history, Data(), reply: F.historyResp))
    }

    /// #668: "no_message" goes only as true; without it the frame is the plain revive's.
    func revive(name: String?, noMessage: Bool = false) async throws -> [String] {
        var o: [String: Any] = name.map { ["name": $0] } ?? ["all": true]
        if noMessage { o["no_message"] = true }
        return try Self.decodeNames(try await verb(F.revive, json(o)))
    }

    func restart(names: [String]?) async throws -> [String] {
        try Self.decodeNames(try await verb(F.restart, json(names.map { ["names": $0] as [String: Any] } ?? ["all": true])))
    }

    func stop(names: [String]) async throws -> [String] {
        try Self.decodeNames(try await verb(F.stop, json(["names": names])))
    }

    func pin(name: String, pin: Bool) async throws -> [String] {
        try Self.passable(name)
        return try Self.decodeNames(try await verb(F.pin, json(["name": name, "pin": pin])))
    }

    func forget(name: String) async throws -> [String] {
        try Self.passable(name)
        return try Self.decodeNames(try await verb(F.forget, json(["name": name])))
    }

    func forgetAll() async throws -> HistoryCleared {
        try Self.decodeCleared(try await verb(F.forgetAll, json([:])))
    }

    /// #634: dch would read a dash-led name as a flag; refused here, nothing sent.
    static func passable(_ name: String) throws {
        if name.hasPrefix("-") { throw TransportError.server("a session name starting with - can't be passed to dch") }
    }

    /// #634: forgetAll's ok `{cleared, skipped, failed}`.
    static func decodeCleared(_ payload: Data) throws -> HistoryCleared {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let cleared = o["cleared"] as? Int else { throw TransportError.protocolError("unreadable reply") }
        return HistoryCleared(cleared: cleared, skipped: o["skipped"] as? Int ?? 0, failed: o["failed"] as? Int ?? 0)
    }

    func library(etag: String?) async throws -> LibraryReply {
        try Self.decodeLibrary(try await verb(F.library, Self.libraryRequest(etag), reply: F.libraryResp))
    }

    /// #614: empty without an etag, else `{"etag":…}`.
    static func libraryRequest(_ etag: String?) -> Data {
        etag.flatMap { try? JSONSerialization.data(withJSONObject: ["etag": $0]) } ?? Data()
    }

    /// #614: each file as the Mac stored it, re-serialised; a null or missing one is nil.
    static func decodeLibrary(_ payload: Data) throws -> LibraryReply {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let etag = o["etag"] as? String else { throw TransportError.protocolError("unreadable library") }
        func file(_ key: String) -> Data? {
            (o[key] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        }
        return LibraryReply(etag: etag, unchanged: o["unchanged"] as? Bool ?? false,
                            snippets: file("snippets"), quicklinks: file("quicklinks"),
                            errors: o["errors"] as? [String: String] ?? [:])
    }

    /// #590: one verb, one reply. No read deadline: dch answers a revive within 5 min and a
    /// restart or stop within 15, and the Mac never drops an idle link, so the connection
    /// waits as long as it takes (keepalive still ends a dead one). Error 0x13 throws its
    /// message as written.
    private func verb(_ type: UInt8, _ payload: Data, reply: UInt8 = F.ok) async throws -> Data {
        try Self.expect(try await oneShot(send: type, payload: payload), reply)
    }

    /// `frame`'s payload when it is a `type`; error 0x13 throws its message as written.
    private static func expect(_ frame: (UInt8, Data), _ type: UInt8) throws -> Data {
        let (t, p) = frame
        if t == type { return p }
        if t == F.error { throw TransportError.server(decodeMessage(p)) }
        throw TransportError.protocolError("unexpected reply 0x\(String(t, radix: 16))")
    }

    // MARK: - Clipboard history (#621)

    func clipboardList(limit: Int, before: String?, since: String?) async throws -> [ClipboardRow] {
        var o: [String: Any] = ["limit": limit]
        if let before { o["before"] = before }
        if let since { o["since"] = since }
        return try Self.decodeClipboardRows(try await verb(F.clipboardList, json(o), reply: F.clipboardResp))
    }

    /// A row missing its id, date or kind is left out.
    static func decodeClipboardRows(_ payload: Data) throws -> [ClipboardRow] {
        guard let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] else {
            throw TransportError.protocolError("unreadable clipboard list")
        }
        return arr.compactMap { o in
            guard let id = o["id"] as? String, let date = o["date"] as? String, let kind = o["kind"] as? String else { return nil }
            return ClipboardRow(id: id, date: date, kind: kind, source: o["source"] as? String ?? "Mac",
                                text: o["text"] as? String, size: o["size"] as? Int ?? 0)
        }
    }

    /// The 0x1a header, then 0x10 frames to its `size`, then ok. Over `max` is refused before
    /// any byte is held. ponytail: no `offset` resume; a dropped pull starts over next sync.
    func clipboardItem(id: String, max: Int) async throws -> (sha256: String, data: Data) {
        let conn = try await connect()
        defer { conn.cancel() }
        conn.send(content: FrameCodec.encode(F.clipboardItem, json(["id": id])), completion: .contentProcessed { _ in })
        var buf = Data()
        let header = try Self.expect(try await FrameCodec.read(from: conn, &buf), F.clipboardItemResp)
        guard let o = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any],
              let size = o["size"] as? Int, let sha = o["sha256"] as? String else {
            throw TransportError.protocolError("unreadable clipboard item")
        }
        guard (0...max).contains(size) else { throw TransportError.protocolError("clipboard item too large") }
        var data = Data(capacity: size)
        while true {
            let frame = try await FrameCodec.read(from: conn, &buf)
            if frame.0 == F.data {
                data.append(frame.1)
                guard data.count <= size else { throw TransportError.protocolError("clipboard item too long") }
                continue
            }
            _ = try Self.expect(frame, F.ok)
            guard data.count == size else { throw TransportError.protocolError("clipboard item short") }
            return (sha, data)
        }
    }

    func addClipboardHistory(_ items: [ClipboardText]) async throws -> ClipboardSent {
        let wire = items.map { ["id": $0.id.uuidString, "date": ClipboardRow.wire($0.date), "kind": "text", "text": $0.text] }
        return try Self.decodeSent(try await verb(F.addClipboardHistory, json(["items": wire])))
    }

    static func decodeSent(_ payload: Data) throws -> ClipboardSent {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw TransportError.protocolError("unreadable reply")
        }
        var sent = ClipboardSent(added: o["added"] as? [String] ?? [])
        for s in o["skipped"] as? [[String: Any]] ?? [] {
            if let id = s["id"] as? String { sent.skipped[id] = s["reason"] as? String ?? "" }
        }
        return sent
    }

    /// A Mac answers a duplicate, no_space or "off" right after the header: this long for that
    /// before the bytes go.
    static var earlyWait: TimeInterval = 0.5
    static let uploadChunk = 1 << 20

    /// Its own connection, as the Mac wants (one upload per connection, never an attached one):
    /// the header, then the bytes in 0x10 frames of at most `uploadChunk`, then one reply, read
    /// as it lands. Bytes stop once it has: the Mac drops data frames after its reply.
    func clipboardUpload(_ item: ClipboardUpload) async throws -> ClipboardSent {
        let conn = try await connect()
        defer { conn.cancel() }
        let landed = Landed()
        let reply = Task { () throws -> (UInt8, Data) in
            defer { landed.set() }
            return try await FrameCodec.readOne(from: conn)
        }
        try await Self.send(conn, FrameCodec.encode(F.clipboardUpload, json(Self.uploadHeader(item))))
        let early = Date().addingTimeInterval(Self.earlyWait)
        while !landed.done, Date() < early { try await Task.sleep(nanoseconds: 20_000_000) }
        let bytes = item.data
        var at = bytes.startIndex
        while at < bytes.endIndex, !landed.done {
            let next = min(at + Self.uploadChunk, bytes.endIndex)
            try await Self.send(conn, FrameCodec.encode(F.data, bytes.subdata(in: at..<next)))
            at = next
        }
        return try Self.decodeSent(try Self.expect(try await reply.value, F.ok))
    }

    /// Kind image, history only (no `live`).
    static func uploadHeader(_ item: ClipboardUpload) -> [String: Any] {
        var o: [String: Any] = ["id": item.id.uuidString, "date": ClipboardRow.wire(item.date), "kind": "image",
                                "source": "iPhone", "size": item.data.count,
                                "sha256": SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined()]
        if let mime = item.mime { o["mime"] = mime }
        return o
    }

    /// `frame` handed to the socket, waited on: an upload's bytes never pile up in NWConnection.
    private static func send(_ conn: NWConnection, _ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    // MARK: - Chat (#646)

    /// The Mac's models, `[]` when none is on disk. An empty request, as the Mac wants.
    func models() async throws -> [LocalModel] {
        try Self.decodeModels(try await verb(F.models, Data(), reply: F.modelsResp))
    }

    /// A row missing its id or name is left out; no `loaded` reads as not resident.
    static func decodeModels(_ payload: Data) throws -> [LocalModel] {
        guard let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] else {
            throw TransportError.protocolError("unreadable models")
        }
        return arr.compactMap { o in
            guard let id = o["id"] as? String, let name = o["name"] as? String else { return nil }
            return LocalModel(id: id, name: name, loaded: o["loaded"] as? Bool ?? false)
        }
    }

    /// Its own connection, never an attached one: the 0x1f request, then each 0x20's text as it
    /// lands, then chatDone ends the stream or error 0x13 throws its message. No read deadline:
    /// a cold model loads for 30 s or more before the first delta. The consumer going away
    /// closes the connection, and that is the Mac's Stop.
    func chat(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let conn = try await connect()
                    defer { conn.cancel() }
                    try await withTaskCancellationHandler {
                        conn.send(content: FrameCodec.encode(F.chat, Self.chatRequest(messages)), completion: .contentProcessed { _ in })
                        var buf = Data()
                        while true {
                            let frame = try await FrameCodec.read(from: conn, &buf)
                            if frame.0 != F.chatDelta { _ = try Self.expect(frame, F.chatDone); return }
                            if let text = ((try? JSONSerialization.jsonObject(with: frame.1)) as? [String: Any])?["text"] as? String {
                                cont.yield(text)
                            }
                        }
                    } onCancel: { conn.cancel() }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// `{"messages":[…]}` only: a null model or max_tokens is "malformed" to the Mac.
    static func chatRequest(_ messages: [ChatMessage]) -> Data {
        let o = ["messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    // MARK: - Commands (#615)

    /// The Mac's commands in its order, `[]` right at its launch. An empty request, as the Mac wants.
    func commands() async throws -> [MacCommand] {
        try Self.decodeCommands(try await verb(F.commands, Data(), reply: F.commandsResp))
    }

    /// A row missing its id, title or ext, or not an object, is left out.
    static func decodeCommands(_ payload: Data) throws -> [MacCommand] {
        guard let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [Any] else {
            throw TransportError.protocolError("unreadable commands")
        }
        return arr.compactMap { row in
            guard let o = row as? [String: Any], let id = o["id"] as? String, let title = o["title"] as? String, let ext = o["ext"] as? String else { return nil }
            return MacCommand(id: id, title: title, subtitle: o["subtitle"] as? String, ext: ext,
                              argument: o["argument"] as? String, icon: o["icon"] as? String)
        }
    }

    func runCommand(id: String, argument: String?) async throws -> CommandResult {
        try Self.decodeResult(try await verb(F.runCommand, Self.runRequest(id: id, argument: argument), reply: F.commandResult))
    }

    /// `{"id"}`, with `argument` only when there is one: a null is "malformed" to the Mac.
    static func runRequest(id: String, argument: String?) -> Data {
        var o = ["id": id]
        if let argument, !argument.isEmpty { o["argument"] = argument }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    static func decodeResult(_ payload: Data) throws -> CommandResult {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let text = o["text"] as? String else { throw TransportError.protocolError("unreadable result") }
        return CommandResult(text: text, detail: o["detail"] as? String)
    }

    static func decodeNames(_ payload: Data) throws -> [String] {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let names = o["names"] as? [String] else { throw TransportError.protocolError("unreadable reply") }
        return names
    }

    /// #634: dch's own pinned refusal (until Mac #633) carries a -f hint the phone can't use;
    /// it reads as the Mac's own words instead.
    static func decodeMessage(_ payload: Data) -> String {
        (((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["message"] as? String)?
            .replacingOccurrences(of: "pinned (-f forgets it anyway)", with: "pinned, unpin it first")
            ?? "The Mac refused the request."
    }

    static func decodeHistory(_ payload: Data) throws -> [DchHistoryRow] {
        guard let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] else {
            throw TransportError.protocolError("unreadable history")
        }
        return arr.compactMap { o in
            (o["name"] as? String).map {
                DchHistoryRow(name: $0, alias: (o["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              agentName: (o["agent_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              end: o["end"] as? String ?? "", lastSeen: o["last_seen"] as? Int ?? 0,
                              started: o["started"] as? Int ?? 0, runtime: o["runtime"] as? Int ?? 0,
                              cwd: o["cwd"] as? String, command: o["command"] as? [String],
                              takes: o["takes"] as? Bool ?? false, pinned: o["pinned"] as? Bool ?? false)
            }
        }
    }

    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream {
        try await openStream(F.attach, json(["name": name, "cols": cols, "rows": rows]))
    }

    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream {
        var o: [String: Any] = ["command": command, "cols": cols, "rows": rows]
        if let name { o["name"] = name }
        return try await openStream(F.create, json(o))
    }

    // MARK: - Helpers

    private func json(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    private func connect(timeout: TimeInterval = 6) async throws -> NWConnection {
        // A half-open link (roam, Mac asleep) otherwise stays `.ready` for minutes while
        // every keystroke sent into it is accepted by the stack and lost. Keepalive
        // notices an idle dead link in ~30s, the drop time a dead one with unacked
        // keystrokes in ~15s; either ends the stream, and SessionConnection queues
        // what's typed next and reattaches.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 15
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: NWParameters(tls: nil, tcp: tcp))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            /// Returns true if this call won the race and resumed the continuation.
            @discardableResult
            func finish(_ result: Result<Void, Error>) -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return false }
                resumed = true
                switch result {
                case .success:        cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
                return true
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:         finish(.success(()))
                case .failed(let e): finish(.failure(TransportError.hostUnreachable("\(e)")))
                case .cancelled:     finish(.failure(TransportError.notConnected))
                default: break       // .waiting (no route to an unreachable host) sits here — the timeout below resolves it
                }
            }
            // Serial: ProsperStream's receive and send completions must not race.
            conn.start(queue: DispatchQueue(label: "prosper.conn"))
            // NWConnection waits indefinitely for a path to an unreachable host; bound it
            // so listSessions surfaces hostUnreachable instead of spinning forever.
            // Only cancel if the connect is still pending — cancelling after .ready
            // would tear down the live connection (~6s reconnect loop regression).
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if finish(.failure(TransportError.hostUnreachable("timed out"))) {
                    conn.cancel()
                }
            }
        }
        return conn
    }

    /// Connect, send one request frame, read exactly one response frame, close.
    private func oneShot(send type: UInt8, payload: Data) async throws -> (UInt8, Data) {
        let conn = try await connect()
        defer { conn.cancel() }
        conn.send(content: FrameCodec.encode(type, payload), completion: .contentProcessed { _ in })
        return try await FrameCodec.readOne(from: conn)
    }

    private func openStream(_ type: UInt8, _ payload: Data) async throws -> TerminalStream {
        let conn = try await connect()
        conn.send(content: FrameCodec.encode(type, payload), completion: .contentProcessed { _ in })
        return ProsperStream(conn: conn)
    }
}

/// Length-prefixed frame codec shared by the request/response and stream paths.
enum FrameCodec {
    static func encode(_ type: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(type)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static let maxFrame = 8 << 20   // 8 MB — keeps a rogue tailnet peer from OOM-ing us

    /// Read frames off `conn` until one whole frame is assembled, return it.
    static func readOne(from conn: NWConnection) async throws -> (UInt8, Data) {
        var buf = Data()
        return try await read(from: conn, &buf)
    }

    /// The next frame, `buf` keeping what came past it: a reply of several frames (#621).
    static func read(from conn: NWConnection, _ buf: inout Data) async throws -> (UInt8, Data) {
        while true {
            if let frame = try pop(&buf) { return frame }
            let chunk = try await receive(conn)
            if chunk.isEmpty { throw TransportError.protocolError("closed before a full frame") }
            buf.append(chunk)
        }
    }

    /// Pop one complete frame from `buf` if present (consumes it). Throws on oversized frames.
    static func pop(_ buf: inout Data) throws -> (UInt8, Data)? {
        guard buf.count >= 5 else { return nil }
        let type = buf[buf.startIndex]
        let len = buf.withUnsafeBytes { raw -> Int in
            let b = raw.baseAddress!.advanced(by: 1).assumingMemoryBound(to: UInt8.self)
            return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
        }
        guard len <= maxFrame else { throw TransportError.protocolError("frame too large") }
        guard buf.count >= 5 + len else { return nil }
        let start = buf.index(buf.startIndex, offsetBy: 5)
        let payload = buf.subdata(in: start..<buf.index(start, offsetBy: len))
        buf.removeSubrange(buf.startIndex..<buf.index(start, offsetBy: len))
        return (type, payload)
    }

    static func receive(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                cont.resume(returning: Data())   // EOF
            }
        }
    }
}

/// #621: set once an upload's reply has landed, read by the task streaming its bytes.
private final class Landed: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var done: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A live attached session. Output is an `AsyncStream` of raw byte slices; input
/// and resize are sent as frames. Reconnecting is `SessionConnection`'s job.
final class ProsperStream: TerminalStream {
    let output: AsyncStream<ArraySlice<UInt8>>
    private let conn: NWConnection
    private var cont: AsyncStream<ArraySlice<UInt8>>.Continuation!
    private var buf = Data()
    private(set) var exited = false

    // `send` runs on main, completions and the pump on the connection's queue.
    private let lock = NSLock()
    private var closed = false
    /// Accepted writes whose completion hasn't reported yet, by send order.
    private var pending: [Int: Outbound] = [:]
    private var seq = 0
    private var finished = false

    /// Set by the terminal view; called on the network queue's callback thread.
    var onScreen: ((ArraySlice<UInt8>) -> Void)?
    var onUnsent: ((Outbound) -> Void)?

    private enum F {
        static let resize: UInt8 = 0x05, redraw: UInt8 = 0x07, snapshot: UInt8 = 0x09
        static let putClipboard: UInt8 = 0x0a
        static let data: UInt8 = 0x10, exit: UInt8 = 0x12, snapshotResp: UInt8 = 0x19
    }

    init(conn: NWConnection) {
        self.conn = conn
        var c: AsyncStream<ArraySlice<UInt8>>.Continuation!
        output = AsyncStream { c = $0 }
        cont = c
        cont.onTermination = { [weak self] _ in self?.close() }
        pump()
    }

    private func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buf.append(data)
                frameLoop: while true {
                    let frame: (UInt8, Data)?
                    do { frame = try FrameCodec.pop(&self.buf) }
                    catch { self.close(); return }   // oversized frame — kill the stream
                    guard let (type, payload) = frame else { break frameLoop }
                    switch type {
                    case F.data: self.cont.yield(ArraySlice([UInt8](payload)))
                    // Empty = the session's master has no VT mirror; nothing to paint.
                    case F.snapshotResp where !payload.isEmpty:
                        self.onScreen?(ArraySlice([UInt8](payload)))
                    case F.exit: self.exited = true; self.close(); return
                    default: break
                    }
                }
            }
            if isComplete || error != nil { self.close(); return }
            if !self.isClosed { self.pump() }
        }
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func send(_ bytes: ArraySlice<UInt8>) -> Bool {
        deliver(.bytes(Array(bytes)), FrameCodec.encode(F.data, Data(bytes)))
    }

    func putClipboard(_ image: Data) -> Bool {
        deliver(.clipboard(image), FrameCodec.encode(F.putClipboard, image))
    }

    /// A user write: refused outright once closed, and handed back through `onUnsent`
    /// when NWConnection reports the frame was not processed. `.contentProcessed`
    /// fires once the whole frame is in the TCP stack, so an error means it never got
    /// there in full — and the server drops a truncated trailing frame with the dead
    /// connection, so re-sending the WHOLE frame can't duplicate input. Frames that
    /// reported success but died in the kernel buffer are not retried: without an
    /// app-level ack they may have arrived, and a doubled keystroke in a shell is
    /// worse than a lost one.
    private func deliver(_ out: Outbound, _ frame: Data) -> Bool {
        lock.lock()
        if closed { lock.unlock(); return false }
        seq += 1
        let id = seq
        pending[id] = out
        lock.unlock()
        conn.send(content: frame, completion: .contentProcessed { [self] error in
            if error != nil { close() }   // a failed send means the link is gone; refuse the rest
            settle(id, unsent: error != nil)
        })
        return true
    }

    /// Output finishes only after every accepted write has reported, so all
    /// `onUnsent` hand-backs land before SessionConnection sees the stream end. A
    /// write the close failsafe already handed back is not handed back twice.
    private func settle(_ id: Int, unsent: Bool) {
        lock.lock()
        let out = pending.removeValue(forKey: id)
        let done = closed && pending.isEmpty
        lock.unlock()
        if unsent, let out { onUnsent?(out) }
        if done { finish() }
    }

    private func finish() {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { cont.finish() }
    }

    func resize(cols: Int, rows: Int) {
        let p = (try? JSONSerialization.data(withJSONObject: ["cols": cols, "rows": rows])) ?? Data()
        conn.send(content: FrameCodec.encode(F.resize, p), completion: .contentProcessed { _ in })
    }

    func requestRedraw() {
        conn.send(content: FrameCodec.encode(F.redraw, Data()), completion: .contentProcessed { _ in })
    }

    func requestSnapshot() {
        conn.send(content: FrameCodec.encode(F.snapshot, Data()), completion: .contentProcessed { _ in })
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let idle = pending.isEmpty
        lock.unlock()
        conn.cancel()   // pending sends complete with ECANCELED → onUnsent → settle
        if idle { finish() }
        // Failsafe: never let a completion that doesn't fire park the reconnect loop.
        // What it still holds never reported reaching the stack, so it goes back first,
        // in order, before output ends: handed back after the next stream took input it
        // would be dropped as late (#230), and a lost paste closer wedges bash/vim (#251).
        // ponytail: a success completion racing this exact moment gets its frame resent.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            let unsent = pending.sorted { $0.key < $1.key }.map(\.value)
            pending.removeAll()
            lock.unlock()
            unsent.forEach { onUnsent?($0) }
            finish()
        }
    }
}
