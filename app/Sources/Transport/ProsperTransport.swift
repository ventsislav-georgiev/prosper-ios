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
        static let kill: UInt8 = 0x04, resize: UInt8 = 0x05, rename: UInt8 = 0x06, data: UInt8 = 0x10
        static let listResp: UInt8 = 0x11, exit: UInt8 = 0x12, error: UInt8 = 0x13, ok: UInt8 = 0x14
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

    private func connect() async throws -> NWConnection {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume()
                case .failed(let e): resumed = true; cont.resume(throwing: TransportError.hostUnreachable("\(e)"))
                case .cancelled: resumed = true; cont.resume(throwing: TransportError.notConnected)
                default: break
                }
            }
            conn.start(queue: .global())
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

    /// Read frames off `conn` until one whole frame is assembled, return it.
    static func readOne(from conn: NWConnection) async throws -> (UInt8, Data) {
        var buf = Data()
        while true {
            if let frame = pop(&buf) { return frame }
            let chunk = try await receive(conn)
            if chunk.isEmpty { throw TransportError.protocolError("closed before a full frame") }
            buf.append(chunk)
        }
    }

    /// Pop one complete frame from `buf` if present (consumes it).
    static func pop(_ buf: inout Data) -> (UInt8, Data)? {
        guard buf.count >= 5 else { return nil }
        let type = buf[buf.startIndex]
        let len = buf.withUnsafeBytes { raw -> Int in
            let b = raw.baseAddress!.advanced(by: 1).assumingMemoryBound(to: UInt8.self)
            return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
        }
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
                while let (type, payload) = FrameCodec.pop(&self.buf) {
                    switch type {
                    case F.data: self.cont.yield(ArraySlice([UInt8](payload)))
                    case F.exit: self.close(); return
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
