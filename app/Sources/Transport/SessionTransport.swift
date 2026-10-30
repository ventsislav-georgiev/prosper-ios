import Foundation

/// A dch session as presented to the UI (PLAN §11). `name` is the real dch
/// session name (shared with standalone dch); `alias` is the optional display
/// label from dch's alias sidecar.
struct DchSession: Identifiable, Hashable {
    var name: String
    var alias: String?
    /// dch's agent state for the session — `working`, `idle`, `blocked` or `done`,
    /// resolved server-side from the session's rendered screen. Empty/nil when the
    /// Mac runs an older Prosper (no state in the list response).
    var state: String? = nil
    /// Live subagents on the session's Claude Code agent panel, as dch counts them.
    /// 0 when there are none, or the Mac's dch is too old to say.
    var agents: Int = 0
    var meta: SessionMeta? = nil     // PRs and tasks; nil draws the row as before
    var id: String { name }
    var title: String { alias ?? name }
}

/// Terminal byte streams for one attached session. Output is delivered in
/// arrival order, losslessly (PLAN §14.2 — the whole value prop). `input` and
/// `resize` flow back to the pty.
protocol TerminalStream: AnyObject {
    /// Async sequence of raw output bytes, in order, never dropped.
    var output: AsyncStream<ArraySlice<UInt8>> { get }
    /// True once the remote process exited (server sent the exit frame). Lets the
    /// reconnect loop tell a clean `exit` apart from a dropped link.
    var exited: Bool { get }
    /// Send keystrokes / pasted bytes to the pty. Returns false when the stream is
    /// already closed and did NOT take the bytes — the caller still owns them. True
    /// means handed to the transport; if the transport later finds they never reached
    /// the socket it hands them back through `onUnsent`.
    @discardableResult func send(_ bytes: ArraySlice<UInt8>) -> Bool
    /// Notify the pty of a new terminal size.
    func resize(cols: Int, rows: Int)
    /// Force the remote program to repaint (after a soft-keyboard relayout),
    /// without reattaching the socket.
    func requestRedraw()
    /// Ask the server for dch's own rendered screen (its VT mirror) and deliver it
    /// to `onScreen`. Unlike `requestRedraw` this needs nothing from the remote
    /// program: whatever dch has is authoritative, so the client can repaint from
    /// it even when the TUI refuses to redraw. Never fires when the session's
    /// master has no mirror (older dch).
    func requestSnapshot()
    /// Put an image on the CLIPBOARD OF THE MACHINE running the session, so the
    /// ctrl-V we send next pastes it. Claude Code reads its own machine's
    /// clipboard, and Universal Clipboard doesn't reliably carry phone images
    /// there, so the bytes travel with the request.
    /// Same contract as `send`.
    @discardableResult func putClipboard(_ image: Data) -> Bool
    /// Frames the transport accepted but could not hand to the socket (the send
    /// failed before reaching the kernel), in send order. Called before `output`
    /// finishes, on any thread.
    var onUnsent: ((Outbound) -> Void)? { get set }
    /// Sink for `requestSnapshot` replies — a full screen in ANSI, ready to feed.
    var onScreen: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// Detach this client (session keeps running).
    func close()
}

/// One user-originated write, queued by `SessionConnection` while no stream can take it.
enum Outbound: Equatable {
    case bytes([UInt8])
    case clipboard(Data)
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
    /// #590: the ended sessions dch recorded, newest first, at most 50.
    func history() async throws -> [DchHistoryRow]
    /// #590: bring a recorded session back (`nil` = every one dch can take). Returns the
    /// names it runs under: a live name comes back as a free `<name>-N`.
    func revive(name: String?) async throws -> [String]
    /// #590: restart live sessions' agents (`nil` = all). Every name must be live, or none runs.
    func restart(names: [String]?) async throws -> [String]
    /// #590: stop live sessions; dch records them, so `revive` can bring them back.
    func stop(names: [String]) async throws -> [String]
}

/// #590: the demo and the test stubs have no dch behind them. Their machine lists no
/// `ops`, so no control calls these.
extension SessionTransport {
    func history() async throws -> [DchHistoryRow] { throw TransportError.server("Not supported here.") }
    func revive(name: String?) async throws -> [String] { throw TransportError.server("Not supported here.") }
    func restart(names: [String]?) async throws -> [String] { throw TransportError.server("Not supported here.") }
    func stop(names: [String]) async throws -> [String] { throw TransportError.server("Not supported here.") }
}

/// #590: a verb the Mac's server answers beyond the base frames. machineInfo lists them in
/// `ops`; an older Mac sends no `ops`, and every control needing one stays hidden.
enum SessionVerb: String {
    case history, revive, restart, stop

    /// The verbs in a machineInfo `ops` value; unknown names and a missing key give none.
    static func offered(_ ops: Any?) -> Set<SessionVerb> {
        Set((ops as? [String] ?? []).compactMap(SessionVerb.init(rawValue:)))
    }
}

/// #590: one ended session from historyResp 0x1b.
struct DchHistoryRow: Equatable {
    var name: String
    var alias: String?
    var agentName: String?   // #593: the agent's session name; older Macs never send it
    var end: String          // dch's raw value: "signal 9", "exit 0", "killed"
    var lastSeen: Int        // epoch seconds
    var started: Int         // epoch seconds
    var runtime: Int         // seconds
    var cwd: String?
    var command: [String]?
    var takes: Bool
}

enum TransportError: Error, LocalizedError {
    case notConnected
    case hostUnreachable(String)
    case rejected(String)
    case protocolError(String)
    /// #590: the server's error 0x13 message, written to be shown as is.
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:            return "Not connected."
        case .hostUnreachable(let h):  return "Can't reach \(h) — check Tailscale."
        case .rejected(let r):         return "Connection rejected: \(r)"
        case .protocolError(let m):    return "Protocol error: \(m)"
        case .server(let m):           return m
        }
    }
}
