import Foundation

/// A dch session as presented to the UI (PLAN §11). `name` is the real dch
/// session name (shared with standalone dch); `alias` is the optional display
/// label from dch's alias sidecar.
struct DchSession: Identifiable, Hashable {
    var name: String
    var alias: String?
    var id: String { name }
    var title: String { alias ?? name }
}

/// Terminal byte streams for one attached session. Output is delivered in
/// arrival order, losslessly (PLAN §14.2 — the whole value prop). `input` and
/// `resize` flow back to the pty.
protocol TerminalStream: AnyObject {
    /// Async sequence of raw output bytes, in order, never dropped.
    var output: AsyncStream<ArraySlice<UInt8>> { get }
    /// Send keystrokes / pasted bytes to the pty.
    func send(_ bytes: ArraySlice<UInt8>)
    /// Notify the pty of a new terminal size.
    func resize(cols: Int, rows: Int)
    /// Force the remote program to repaint (after a soft-keyboard relayout),
    /// without reattaching the socket.
    func requestRedraw()
    /// Detach this client (session keeps running).
    func close()
}

/// Pluggable transport so SSH and the Prosper-hosted dch-server both fit behind
/// one surface (PLAN §11). The app is written against this; the concrete
/// transport is chosen at connect time.
protocol SessionTransport: AnyObject {
    func listSessions() async throws -> [DchSession]
    /// Attach (or create) a session and return its live byte stream.
    func attach(name: String, cols: Int, rows: Int) async throws -> TerminalStream
    /// Start a new session running `command` (default name when nil).
    func create(name: String?, command: [String], cols: Int, rows: Int) async throws -> TerminalStream
    func kill(name: String) async throws
    /// Set (or clear, when nil/empty) a session's display alias.
    func rename(name: String, alias: String?) async throws
}

enum TransportError: Error, LocalizedError {
    case notConnected
    case hostUnreachable(String)
    case rejected(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:            return "Not connected."
        case .hostUnreachable(let h):  return "Can't reach \(h) — check Tailscale."
        case .rejected(let r):         return "Connection rejected: \(r)"
        case .protocolError(let m):    return "Protocol error: \(m)"
        }
    }
}
