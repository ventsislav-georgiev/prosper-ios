import Foundation
import Network

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
        static let machineInfo: UInt8 = 0x08, data: UInt8 = 0x10
        static let listResp: UInt8 = 0x11, exit: UInt8 = 0x12, error: UInt8 = 0x13, ok: UInt8 = 0x14
        static let machineInfoResp: UInt8 = 0x18
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
        guard let (type, payload) = reply, type == F.machineInfoResp,
              let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let deviceId = o["device_id"] as? String else { return nil }
        return MachineInfo(deviceId: deviceId,
                           hostname: o["hostname"] as? String,
                           wakeId: o["wakeId"] as? String)
    }

    func listSessions() async throws -> [DchSession] {
        let (type, payload) = try await oneShot(send: F.list, payload: Data())
        guard type == F.listResp else { throw TransportError.protocolError("expected list") }
        let arr = (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] ?? []
        return arr.compactMap { o in (o["name"] as? String).map { DchSession(name: $0, alias: o["alias"] as? String) } }
    }

    func kill(name: String) async throws {
        _ = try await oneShot(send: F.kill, payload: json(["name": name]))
    }

    func rename(name: String, alias: String?) async throws {
        _ = try await oneShot(send: F.rename, payload: json(["name": name, "alias": alias ?? ""]))
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
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
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
            conn.start(queue: .global())
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

/// A live attached session. Output is an `AsyncStream` of raw byte slices; input
/// and resize are sent as frames. ponytail: single connection — the auto-reconnect
/// wrapper (PLAN §15.1) lands with the terminal view, post-spike.
final class ProsperStream: TerminalStream {
    let output: AsyncStream<ArraySlice<UInt8>>
    private let conn: NWConnection
    private var cont: AsyncStream<ArraySlice<UInt8>>.Continuation!
    private var buf = Data()
    private var closed = false
    private(set) var exited = false

    private enum F { static let resize: UInt8 = 0x05, redraw: UInt8 = 0x07, data: UInt8 = 0x10, exit: UInt8 = 0x12 }

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
                    case F.exit: self.exited = true; self.close(); return
                    default: break
                    }
                }
            }
            if isComplete || error != nil { self.close(); return }
            if !self.closed { self.pump() }
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        conn.send(content: FrameCodec.encode(F.data, Data(bytes)), completion: .contentProcessed { _ in })
    }

    func resize(cols: Int, rows: Int) {
        let p = (try? JSONSerialization.data(withJSONObject: ["cols": cols, "rows": rows])) ?? Data()
        conn.send(content: FrameCodec.encode(F.resize, p), completion: .contentProcessed { _ in })
    }

    func requestRedraw() {
        conn.send(content: FrameCodec.encode(F.redraw, Data()), completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        closed = true
        cont.finish()
        conn.cancel()
    }
}
